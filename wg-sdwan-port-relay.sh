#!/usr/bin/env bash
set -euo pipefail

WG_IF="${WG_IF:-wg-sdwan}"
WG_PORT="${WG_PORT:-51820}"
WG_NET_V4="${WG_NET_V4:-10.233.233.0/24}"
RELAY_WG_IP_CIDR="${RELAY_WG_IP_CIDR:-10.233.233.1/24}"
ENTRY_WG_IP_CIDR="${ENTRY_WG_IP_CIDR:-10.233.233.2/24}"
RELAY_WG_IP="${RELAY_WG_IP:-10.233.233.1}"
ENTRY_WG_IP="${ENTRY_WG_IP:-10.233.233.2}"

# Relay runtime defaults. Can be overridden in /etc/wg-sdwan-port-relay/config.env
MAX_TCP_CONNECTIONS="${MAX_TCP_CONNECTIONS:-1024}"
MAX_UDP_CLIENTS="${MAX_UDP_CLIENTS:-4096}"
TCP_IDLE_TIMEOUT="${TCP_IDLE_TIMEOUT:-300}"
UDP_IDLE_TIMEOUT="${UDP_IDLE_TIMEOUT:-180}"
CONNECT_TIMEOUT="${CONNECT_TIMEOUT:-15}"
LOG_LEVEL="${LOG_LEVEL:-info}"
TARGET_FAMILY="${TARGET_FAMILY:-ipv4}"

CONF_DIR="/etc/wg-sdwan-port-relay"
KEY_DIR="${CONF_DIR}/keys"
FORWARDS="${CONF_DIR}/forwards.csv"
WG_CONF="/etc/wireguard/${WG_IF}.conf"
RELAY_BIN="/usr/local/bin/wg-sdwan-port-relay.py"
RELAY_SERVICE="/etc/systemd/system/wg-sdwan-port-relay.service"
STATE_DIR="/var/lib/wg-sdwan-port-relay"
BACKUP_DIR="/var/backups/wg-sdwan-port-relay"
MANIFEST="${STATE_DIR}/manifest.tsv"
CONFIG_ENV="${CONF_DIR}/config.env"
IPT_COMMENT="wg-sdwan-port-relay"

need_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "请使用 root 权限运行，例如：sudo bash $0 ..." >&2
    exit 1
  fi
}

refresh_wg_conf() {
  WG_CONF="/etc/wireguard/${WG_IF}.conf"
}

load_config() {
  if [ -f "$CONFIG_ENV" ]; then
    # shellcheck disable=SC1090
    . "$CONFIG_ENV"
  fi
  refresh_wg_conf
}

state_init() {
  mkdir -p "$STATE_DIR" "$BACKUP_DIR"
  chmod 700 "$STATE_DIR" "$BACKUP_DIR"
  touch "$MANIFEST"
  chmod 600 "$MANIFEST"
}

manifest_seen() {
  [ -f "$MANIFEST" ] && awk -F '\t' -v k="$1" -v v="$2" '
    $1 == k && $2 == v { found = 1 }
    END { exit found ? 0 : 1 }
  ' "$MANIFEST"
}

backup_path() {
  local path="$1" hash="" dest=""
  state_init

  manifest_seen RESTORE "$path" && return 0
  manifest_seen DELETE "$path" && return 0

  if [ -e "$path" ] || [ -L "$path" ]; then
    hash="$(printf '%s' "$path" | sha256sum | awk '{print $1}')"
    dest="${BACKUP_DIR}/${hash}"
    rm -rf "$dest"
    cp -a "$path" "$dest"
    printf 'RESTORE\t%s\t%s\n' "$path" "$dest" >> "$MANIFEST"
  else
    printf 'DELETE\t%s\t-\n' "$path" >> "$MANIFEST"
  fi
}

meta_once() {
  local key="$1" value="$2"
  state_init
  awk -F '\t' -v key="$key" '
    $1 == "META" && $2 == key { found = 1 }
    END { exit found ? 0 : 1 }
  ' "$MANIFEST" && return 0
  printf 'META\t%s\t%s\n' "$key" "$value" >> "$MANIFEST"
}

meta_get() {
  local key="$1" default_value="${2:-}"
  if [ ! -f "$MANIFEST" ]; then
    echo "$default_value"
    return 0
  fi
  awk -F '\t' -v key="$key" -v default_value="$default_value" '
    $1 == "META" && $2 == key { print $3; found = 1; exit }
    END { if (!found) print default_value }
  ' "$MANIFEST"
}

record_unit() {
  local unit="$1"
  meta_once "UNIT_${unit}_ENABLED" "$(systemctl is-enabled "$unit" 2>/dev/null || true)"
  meta_once "UNIT_${unit}_ACTIVE" "$(systemctl is-active "$unit" 2>/dev/null || true)"
}

restore_unit() {
  local unit="$1" enabled_state="" active_state=""
  enabled_state="$(meta_get "UNIT_${unit}_ENABLED" unknown)"
  active_state="$(meta_get "UNIT_${unit}_ACTIVE" unknown)"

  if [ "$enabled_state" = "enabled" ]; then
    systemctl enable "$unit" >/dev/null 2>&1 || true
  else
    systemctl disable "$unit" >/dev/null 2>&1 || true
  fi

  if [ "$active_state" = "active" ]; then
    systemctl start "$unit" >/dev/null 2>&1 || true
  else
    systemctl stop "$unit" >/dev/null 2>&1 || true
  fi
}

record_runtime() {
  local wg_if="$1" net="$2"
  meta_once WG_IF "$wg_if"
  meta_once WG_NET_V4 "$net"
  meta_once SYSCTL_NET_IPV4_IP_FORWARD "$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo unknown)"
}

ensure_dirs() {
  state_init
  backup_path "$CONF_DIR"
  mkdir -p "$CONF_DIR" "$KEY_DIR" /etc/wireguard
  chmod 700 "$KEY_DIR"
  touch "$FORWARDS"
}

save_config() {
  ensure_dirs
  backup_path "$CONFIG_ENV"
  cat > "$CONFIG_ENV" <<EOF
WG_IF=$(printf '%q' "$WG_IF")
WG_NET_V4=$(printf '%q' "$WG_NET_V4")
MAX_TCP_CONNECTIONS=$(printf '%q' "$MAX_TCP_CONNECTIONS")
MAX_UDP_CLIENTS=$(printf '%q' "$MAX_UDP_CLIENTS")
TCP_IDLE_TIMEOUT=$(printf '%q' "$TCP_IDLE_TIMEOUT")
UDP_IDLE_TIMEOUT=$(printf '%q' "$UDP_IDLE_TIMEOUT")
CONNECT_TIMEOUT=$(printf '%q' "$CONNECT_TIMEOUT")
LOG_LEVEL=$(printf '%q' "$LOG_LEVEL")
TARGET_FAMILY=$(printf '%q' "$TARGET_FAMILY")
EOF
}

ensure_key() {
  ensure_dirs
  if [ ! -f "${KEY_DIR}/privatekey" ]; then
    wg genkey | tee "${KEY_DIR}/privatekey" | wg pubkey > "${KEY_DIR}/publickey"
    chmod 600 "${KEY_DIR}/privatekey"
  fi
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }

missing_deps() {
  local missing=0
  for cmd in wg ip iptables python3 systemctl sha256sum awk; do
    if ! have_cmd "$cmd"; then
      echo "缺少依赖命令: $cmd"
      missing=1
    fi
  done
  return "$missing"
}

require_deps() {
  if ! missing_deps >/tmp/wg_sdw_relay_missing.$$; then
    echo "缺少以下依赖：" >&2
    cat /tmp/wg_sdw_relay_missing.$$ >&2
    rm -f /tmp/wg_sdw_relay_missing.$$
    echo >&2
    echo "请手动安装依赖，或运行：" >&2
    echo "  sudo bash $0 install-deps" >&2
    exit 1
  fi
  rm -f /tmp/wg_sdw_relay_missing.$$
}

cmd_check() {
  if missing_deps; then
    echo
    echo "检测到依赖缺失。请运行：sudo bash $0 install-deps"
    exit 1
  fi
  echo "所有必需依赖均已安装。"
}

cmd_install_deps() {
  need_root
  echo "即将安装 wg-sdwan-port-relay 所需的系统软件包。"
  echo "此命令不会修改现有配置。"
  read -rp "输入 YES 继续: " confirm
  if [ "$confirm" != "YES" ]; then
    echo "已取消。"
    exit 0
  fi

  if have_cmd apt-get; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y wireguard-tools iproute2 iptables python3 coreutils gawk
  elif have_cmd dnf; then
    dnf install -y wireguard-tools iproute iptables python3 coreutils gawk
  elif have_cmd yum; then
    yum install -y wireguard-tools iproute iptables python3 coreutils gawk
  else
    echo "不支持当前包管理器。请手动安装：wireguard-tools, iproute2/iproute, iptables, python3, coreutils, awk" >&2
    exit 1
  fi
}

validate_port() {
  local p="$1" label="${2:-port}"
  if ! [[ "$p" =~ ^[0-9]+$ ]] || [ "$p" -lt 1 ] || [ "$p" -gt 65535 ]; then
    echo "无效的 ${label}：必须是 1 到 65535 之间的整数" >&2
    exit 1
  fi
}

validate_int_range() {
  local value="$1" label="$2" min="$3" max="$4"
  if ! [[ "$value" =~ ^[0-9]+$ ]] || [ "$value" -lt "$min" ] || [ "$value" -gt "$max" ]; then
    echo "无效的 ${label}：必须是 ${min} 到 ${max} 之间的整数" >&2
    exit 1
  fi
}

validate_iface() {
  local name="$1"
  if ! [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,14}$ ]]; then
    echo "无效的网卡接口名称：${name}" >&2
    echo "接口名需为 1-15 个字符：字母、数字、点、下划线、短横线；必须以字母或数字开头。" >&2
    exit 1
  fi
}

validate_target_name() {
  local name="$1"
  if ! [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$ ]]; then
    echo "无效的目标名称：${name}" >&2
    exit 1
  fi
}

validate_host() {
  local host="$1"
  python3 - "$host" <<'PY'
import ipaddress, re, sys
host = sys.argv[1].strip()
if not host or len(host) > 253:
    raise SystemExit("invalid host: empty or too long")
try:
    h = host.strip("[]")
    ipaddress.ip_address(h)
    raise SystemExit(0)
except ValueError:
    pass
label = r"[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?"
if not re.fullmatch(label + r"(?:\." + label + r")*", host):
    raise SystemExit("invalid host: must be an IP address or DNS hostname")
PY
}

validate_cidr() {
  local cidr="$1" label="${2:-CIDR}"
  python3 - "$cidr" "$label" <<'PY'
import ipaddress, sys
cidr, label = sys.argv[1], sys.argv[2]
try:
    ipaddress.ip_network(cidr, strict=False)
except Exception as exc:
    raise SystemExit(f"invalid {label}: {exc}")
PY
}

validate_ipv4_cidr() {
  local cidr="$1" label="${2:-IPv4 CIDR}"
  python3 - "$cidr" "$label" <<'PY'
import ipaddress, sys
cidr, label = sys.argv[1], sys.argv[2]
try:
    net = ipaddress.ip_network(cidr, strict=False)
except Exception as exc:
    raise SystemExit(f"invalid {label}: {exc}")
if net.version != 4:
    raise SystemExit(f"invalid {label}: must be IPv4")
PY
}

validate_ip() {
  local ip="$1" label="${2:-IP}"
  python3 - "$ip" "$label" <<'PY'
import ipaddress, sys
ip, label = sys.argv[1], sys.argv[2]
try:
    ipaddress.ip_address(ip)
except Exception as exc:
    raise SystemExit(f"invalid {label}: {exc}")
PY
}

validate_wg_pubkey() {
  local key="$1" label="${2:-WireGuard public key}"
  python3 - "$key" "$label" <<'PY'
import base64, sys
key, label = sys.argv[1], sys.argv[2]
try:
    raw = base64.b64decode(key, validate=True)
except Exception:
    raise SystemExit(f"invalid {label}: not valid base64")
if len(raw) != 32:
    raise SystemExit(f"invalid {label}: decoded length must be 32 bytes")
PY
}

validate_allowed_ips() {
  local value="$1"
  python3 - "$value" <<'PY'
import ipaddress, sys
value = sys.argv[1]
items = [x.strip() for x in value.split(',')]
if not items or any(not x for x in items):
    raise SystemExit("invalid AllowedIPs: empty item")
for item in items:
    try:
        ipaddress.ip_network(item, strict=False)
    except Exception as exc:
        raise SystemExit(f"invalid AllowedIPs item {item}: {exc}")
PY
}

validate_runtime_limits() {
  validate_int_range "$MAX_TCP_CONNECTIONS" MAX_TCP_CONNECTIONS 1 1048576
  validate_int_range "$MAX_UDP_CLIENTS" MAX_UDP_CLIENTS 1 1048576
  validate_int_range "$TCP_IDLE_TIMEOUT" TCP_IDLE_TIMEOUT 1 86400
  validate_int_range "$UDP_IDLE_TIMEOUT" UDP_IDLE_TIMEOUT 1 86400
  validate_int_range "$CONNECT_TIMEOUT" CONNECT_TIMEOUT 1 3600
  case "$LOG_LEVEL" in debug|info|warning|error) :;; *) echo "无效的 LOG_LEVEL：${LOG_LEVEL}，可用值：debug/info/warning/error" >&2; exit 1;; esac
  case "$TARGET_FAMILY" in ipv4|any) :;; *) echo "无效的 TARGET_FAMILY：${TARGET_FAMILY}，可用值：ipv4/any" >&2; exit 1;; esac
}

ask() {
  local var="$1" prompt="$2" default_value="${3:-}" __wg_sdw_reply=""
  read -rp "${prompt}${default_value:+ [$default_value]}: " __wg_sdw_reply
  printf -v "$var" '%s' "${__wg_sdw_reply:-$default_value}"
}

ask_required() {
  local var="$1" prompt="$2" __wg_sdw_reply=""
  while true; do
    read -rp "${prompt}: " __wg_sdw_reply
    if [ -n "$__wg_sdw_reply" ]; then
      printf -v "$var" '%s' "$__wg_sdw_reply"
      return 0
    fi
    echo "该项不能为空。"
  done
}

ask_port() {
  local var="$1" prompt="$2" default_value="$3" __wg_sdw_reply=""
  while true; do
    read -rp "${prompt}${default_value:+ [$default_value]}: " __wg_sdw_reply
    __wg_sdw_reply="${__wg_sdw_reply:-$default_value}"
    if [[ "$__wg_sdw_reply" =~ ^[0-9]+$ ]] && [ "$__wg_sdw_reply" -ge 1 ] && [ "$__wg_sdw_reply" -le 65535 ]; then
      printf -v "$var" '%s' "$__wg_sdw_reply"
      return 0
    fi
    echo "端口必须是 1 到 65535 之间的整数。"
  done
}

endpoint() {
  local host="$1" port="$2"
  if [[ "$host" == \[*\] ]]; then
    echo "${host}:${port}"
  elif [[ "$host" == *:* ]]; then
    echo "[${host}]:${port}"
  else
    echo "${host}:${port}"
  fi
}

install_relay() {
  validate_iface "$WG_IF"
  validate_runtime_limits
  backup_path "$RELAY_BIN"

  cat > "$RELAY_BIN" <<'PY'
#!/usr/bin/env python3
import csv
import os
import select
import signal
import socket
import subprocess
import sys
import threading
import time

CONFIG = sys.argv[1] if len(sys.argv) > 1 else "/etc/wg-sdwan-port-relay/forwards.csv"
WG_IF = os.environ.get("WG_IF", "wg-sdwan")
TARGET_FAMILY = os.environ.get("TARGET_FAMILY", "ipv4")
MAX_TCP_CONNECTIONS = int(os.environ.get("MAX_TCP_CONNECTIONS", "1024"))
MAX_UDP_CLIENTS = int(os.environ.get("MAX_UDP_CLIENTS", "4096"))
TCP_IDLE_TIMEOUT = int(os.environ.get("TCP_IDLE_TIMEOUT", "300"))
UDP_IDLE_TIMEOUT = int(os.environ.get("UDP_IDLE_TIMEOUT", "180"))
CONNECT_TIMEOUT = int(os.environ.get("CONNECT_TIMEOUT", "15"))
LOG_LEVEL = os.environ.get("LOG_LEVEL", "info").lower()

LEVELS = {"debug": 10, "info": 20, "warning": 30, "error": 40}
LOG_THRESHOLD = LEVELS.get(LOG_LEVEL, 20)
stop_event = threading.Event()
tcp_sem = threading.BoundedSemaphore(MAX_TCP_CONNECTIONS)
udp_total_lock = threading.Lock()
udp_total_clients = 0


def log(level, message):
    if LEVELS.get(level, 20) >= LOG_THRESHOLD:
        print(time.strftime("[%F %T]"), level.upper(), message, flush=True)


def validate_runtime():
    if MAX_TCP_CONNECTIONS < 1 or MAX_UDP_CLIENTS < 1:
        raise SystemExit("MAX_TCP_CONNECTIONS and MAX_UDP_CLIENTS must be positive")
    if TCP_IDLE_TIMEOUT < 1 or UDP_IDLE_TIMEOUT < 1 or CONNECT_TIMEOUT < 1:
        raise SystemExit("timeouts must be positive")
    if TARGET_FAMILY not in {"ipv4", "any"}:
        raise SystemExit("TARGET_FAMILY must be ipv4 or any")


def route_v4(ip):
    subprocess.run(
        ["ip", "route", "replace", f"{ip}/32", "dev", WG_IF],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )


def resolve_target(host, port, socktype):
    family = socket.AF_INET if TARGET_FAMILY == "ipv4" else socket.AF_UNSPEC
    infos = socket.getaddrinfo(host, port, family, socktype)
    if not infos:
        raise RuntimeError(f"cannot resolve target {host}:{port}")
    infos.sort(key=lambda x: 0 if x[0] == socket.AF_INET else 1)
    af, _, _, _, sockaddr = infos[0]
    if af == socket.AF_INET:
        route_v4(sockaddr[0])
    return af, sockaddr, sockaddr[0]


def load_forwards():
    rows = []
    if not os.path.exists(CONFIG):
        return rows
    with open(CONFIG, newline="") as f:
        for row in csv.reader(f):
            if not row or row[0].strip().startswith("#"):
                continue
            if len(row) != 4:
                log("warning", f"skip invalid row: {row}")
                continue
            name, target_host, target_port, listen_port = [x.strip() for x in row]
            rows.append((name, target_host, int(target_port), int(listen_port)))
    return rows


def recv_with_timeout(sock, size, timeout):
    readable, _, _ = select.select([sock], [], [], timeout)
    if not readable:
        raise TimeoutError("idle timeout")
    return sock.recv(size)


def tcp_pipe(client, target_host, target_port):
    upstream = None
    try:
        af, sockaddr, resolved_ip = resolve_target(target_host, target_port, socket.SOCK_STREAM)
        upstream = socket.socket(af, socket.SOCK_STREAM)
        upstream.settimeout(CONNECT_TIMEOUT)
        upstream.connect(sockaddr)
        upstream.settimeout(None)
        client.settimeout(None)
        log("info", f"TCP -> {target_host}:{target_port} resolved={resolved_ip}")

        sockets = [client, upstream]
        while not stop_event.is_set():
            readable, _, _ = select.select(sockets, [], [], TCP_IDLE_TIMEOUT)
            if not readable:
                raise TimeoutError("tcp idle timeout")
            for sock in readable:
                data = sock.recv(65536)
                if not data:
                    return
                peer = upstream if sock is client else client
                peer.sendall(data)
    except Exception as exc:
        log("debug", f"TCP end {target_host}:{target_port}: {exc}")
    finally:
        try:
            client.close()
        except Exception:
            pass
        if upstream is not None:
            try:
                upstream.close()
            except Exception:
                pass
        tcp_sem.release()


def tcp_listener(target_host, target_port, listen_port):
    server = socket.socket(socket.AF_INET6, socket.SOCK_STREAM)
    server.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(("::", listen_port))
    server.listen(1024)
    server.settimeout(1)
    log("info", f"TCP listen [::]:{listen_port} -> {target_host}:{target_port}")

    while not stop_event.is_set():
        try:
            client, addr = server.accept()
        except socket.timeout:
            continue
        except OSError:
            break
        if not tcp_sem.acquire(blocking=False):
            log("warning", f"TCP limit reached, reject {addr}")
            try:
                client.close()
            except Exception:
                pass
            continue
        threading.Thread(target=tcp_pipe, args=(client, target_host, target_port), daemon=True).start()


class UDPRelay:
    def __init__(self, target_host, target_port, listen_port):
        self.target_host = target_host
        self.target_port = target_port
        self.listen_port = listen_port
        self.clients = {}
        self.lock = threading.Lock()
        self.server = socket.socket(socket.AF_INET6, socket.SOCK_DGRAM)
        self.server.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
        self.server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.server.bind(("::", listen_port))
        self.server.settimeout(1)

    def reserve_udp_client(self):
        global udp_total_clients
        with udp_total_lock:
            if udp_total_clients >= MAX_UDP_CLIENTS:
                return False
            udp_total_clients += 1
            return True

    def release_udp_client(self):
        global udp_total_clients
        with udp_total_lock:
            if udp_total_clients > 0:
                udp_total_clients -= 1

    def start(self):
        log("info", f"UDP listen [::]:{self.listen_port} -> {self.target_host}:{self.target_port}")
        threading.Thread(target=self.cleanup_loop, daemon=True).start()
        while not stop_event.is_set():
            try:
                data, client_addr = self.server.recvfrom(65535)
            except socket.timeout:
                continue
            except OSError:
                break
            entry = self.get_or_create_client(client_addr)
            if entry is None:
                continue
            upstream = entry[0]
            try:
                upstream.send(data)
            except Exception as exc:
                log("debug", f"UDP send error {client_addr}: {exc}")
                self.drop_client(client_addr)

    def get_or_create_client(self, client_addr):
        with self.lock:
            entry = self.clients.get(client_addr)
            if entry is not None:
                entry[1] = time.time()
                return entry
        if not self.reserve_udp_client():
            log("warning", f"UDP limit reached, drop {client_addr}")
            return None
        try:
            af, sockaddr, resolved_ip = resolve_target(self.target_host, self.target_port, socket.SOCK_DGRAM)
            upstream = socket.socket(af, socket.SOCK_DGRAM)
            upstream.settimeout(1)
            upstream.connect(sockaddr)
            entry = [upstream, time.time()]
        except Exception as exc:
            self.release_udp_client()
            log("debug", f"UDP create upstream failed {client_addr}: {exc}")
            return None
        with self.lock:
            old = self.clients.get(client_addr)
            if old is not None:
                try:
                    upstream.close()
                except Exception:
                    pass
                self.release_udp_client()
                old[1] = time.time()
                return old
            self.clients[client_addr] = entry
        log("info", f"UDP {client_addr} -> {self.target_host}:{self.target_port} resolved={resolved_ip}")
        threading.Thread(target=self.reply_loop, args=(client_addr, upstream), daemon=True).start()
        return entry

    def reply_loop(self, client_addr, upstream):
        try:
            while not stop_event.is_set():
                try:
                    data = upstream.recv(65535)
                except socket.timeout:
                    continue
                if not data:
                    break
                self.server.sendto(data, client_addr)
        except Exception:
            pass
        self.drop_client(client_addr)

    def drop_client(self, client_addr):
        with self.lock:
            entry = self.clients.pop(client_addr, None)
        if entry is not None:
            try:
                entry[0].close()
            except Exception:
                pass
            self.release_udp_client()

    def cleanup_loop(self):
        while not stop_event.is_set():
            time.sleep(30)
            now = time.time()
            with self.lock:
                stale = [addr for addr, entry in self.clients.items() if now - entry[1] > UDP_IDLE_TIMEOUT]
            for addr in stale:
                self.drop_client(addr)
            if stale:
                log("debug", f"UDP cleaned {len(stale)} stale clients on :{self.listen_port}")


def metrics_loop():
    while not stop_event.is_set():
        time.sleep(60)
        with udp_total_lock:
            udp_count = udp_total_clients
        tcp_used = MAX_TCP_CONNECTIONS - tcp_sem._value  # best-effort runtime metric
        log("info", f"health tcp_active={tcp_used} udp_clients={udp_count} max_tcp={MAX_TCP_CONNECTIONS} max_udp={MAX_UDP_CLIENTS}")


def handle_signal(signum, frame):
    log("info", f"received signal {signum}, shutting down")
    stop_event.set()


def main():
    validate_runtime()
    signal.signal(signal.SIGTERM, handle_signal)
    signal.signal(signal.SIGINT, handle_signal)
    rows = load_forwards()
    if not rows:
        log("warning", f"no forwarding config found: {CONFIG}")
        while not stop_event.is_set():
            time.sleep(60)
        return
    used_ports = set()
    for _, target_host, target_port, listen_port in rows:
        if listen_port in used_ports:
            raise SystemExit(f"duplicate listen port: {listen_port}")
        used_ports.add(listen_port)
    for _, target_host, target_port, listen_port in rows:
        threading.Thread(target=tcp_listener, args=(target_host, target_port, listen_port), daemon=True).start()
        threading.Thread(target=UDPRelay(target_host, target_port, listen_port).start, daemon=True).start()
    threading.Thread(target=metrics_loop, daemon=True).start()
    while not stop_event.is_set():
        time.sleep(1)


if __name__ == "__main__":
    main()
PY

  chmod +x "$RELAY_BIN"

  backup_path "$RELAY_SERVICE"
  record_unit wg-sdwan-port-relay.service

  cat > "$RELAY_SERVICE" <<EOF
[Unit]
Description=IPv6 TCP/UDP relay over WireGuard
After=network-online.target wg-quick@${WG_IF}.service
Wants=network-online.target wg-quick@${WG_IF}.service

[Service]
Type=simple
Environment=WG_IF=${WG_IF}
Environment=TARGET_FAMILY=${TARGET_FAMILY}
Environment=MAX_TCP_CONNECTIONS=${MAX_TCP_CONNECTIONS}
Environment=MAX_UDP_CLIENTS=${MAX_UDP_CLIENTS}
Environment=TCP_IDLE_TIMEOUT=${TCP_IDLE_TIMEOUT}
Environment=UDP_IDLE_TIMEOUT=${UDP_IDLE_TIMEOUT}
Environment=CONNECT_TIMEOUT=${CONNECT_TIMEOUT}
Environment=LOG_LEVEL=${LOG_LEVEL}
ExecStart=/usr/bin/python3 ${RELAY_BIN} ${FORWARDS}
Restart=always
RestartSec=2
LimitNOFILE=1048576
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true
ReadWritePaths=${CONF_DIR}
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
}

cmd_keygen() {
  need_root
  require_deps
  ensure_key
  echo
  echo "WireGuard 公钥："
  cat "${KEY_DIR}/publickey"
  echo
}

cmd_init_relay() {
  need_root
  require_deps
  ensure_key

  local entry_pub="" listen_port="$WG_PORT" wg_if="$WG_IF" relay_ip_cidr="$RELAY_WG_IP_CIDR" entry_ip="$ENTRY_WG_IP" wg_net="$WG_NET_V4"

  while [ $# -gt 0 ]; do
    case "$1" in
      --entry-pub) entry_pub="$2"; shift 2;;
      --listen-port) listen_port="$2"; shift 2;;
      --wg-if) wg_if="$2"; shift 2;;
      --relay-wg-ip-cidr) relay_ip_cidr="$2"; shift 2;;
      --entry-wg-ip) entry_ip="$2"; shift 2;;
      --wg-net-v4) wg_net="$2"; shift 2;;
      --max-tcp-connections) MAX_TCP_CONNECTIONS="$2"; shift 2;;
      --max-udp-clients) MAX_UDP_CLIENTS="$2"; shift 2;;
      --log-level) LOG_LEVEL="$2"; shift 2;;
      *) echo "未知参数：$1" >&2; exit 1;;
    esac
  done

  if [ -t 0 ]; then
    echo
    echo "=== 中继节点初始化 ==="
    ask wg_if "WireGuard 接口名称" "$wg_if"
    ask_port listen_port "WireGuard UDP 监听端口" "$listen_port"
    ask relay_ip_cidr "中继节点 WireGuard 地址 CIDR" "$relay_ip_cidr"
    ask entry_ip "入口节点 WireGuard IP（不含 CIDR）" "$entry_ip"
    ask wg_net "用于 NAT 的 WireGuard IPv4 子网" "$wg_net"
    [ -n "$entry_pub" ] || ask_required entry_pub "入口节点 WireGuard 公钥"
  elif [ -z "$entry_pub" ]; then
    echo "缺少参数 --entry-pub" >&2
    exit 1
  fi

  validate_iface "$wg_if"
  validate_port "$listen_port" "监听端口"
  validate_cidr "$relay_ip_cidr" "中继 WireGuard 地址 CIDR"
  validate_ip "$entry_ip" "入口 WireGuard IP"
  validate_ipv4_cidr "$wg_net" "WireGuard IPv4 子网"
  validate_wg_pubkey "$entry_pub" "入口节点公钥"
  validate_runtime_limits

  WG_IF="$wg_if"
  WG_PORT="$listen_port"
  RELAY_WG_IP_CIDR="$relay_ip_cidr"
  ENTRY_WG_IP="$entry_ip"
  WG_NET_V4="$wg_net"
  refresh_wg_conf

  save_config
  backup_path "$WG_CONF"
  record_runtime "$WG_IF" "$WG_NET_V4"
  record_unit "wg-quick@${WG_IF}.service"

  cat > "$WG_CONF" <<EOF
[Interface]
Address = ${RELAY_WG_IP_CIDR}
ListenPort = ${WG_PORT}
PrivateKey = $(cat "${KEY_DIR}/privatekey")
PostUp = sysctl -w net.ipv4.ip_forward=1; iptables -t nat -C POSTROUTING -s ${WG_NET_V4} -m comment --comment ${IPT_COMMENT} -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -s ${WG_NET_V4} -m comment --comment ${IPT_COMMENT} -j MASQUERADE
PostDown = iptables -t nat -D POSTROUTING -s ${WG_NET_V4} -m comment --comment ${IPT_COMMENT} -j MASQUERADE 2>/dev/null || true

[Peer]
PublicKey = ${entry_pub}
AllowedIPs = ${ENTRY_WG_IP}/32
PersistentKeepalive = 25
EOF

  chmod 600 "$WG_CONF"
  systemctl enable "wg-quick@${WG_IF}" >/dev/null
  systemctl restart "wg-quick@${WG_IF}"

  echo
  echo "中继节点 WireGuard 已启动：${WG_IF} UDP/${WG_PORT}"
  echo "中继节点公钥："
  cat "${KEY_DIR}/publickey"
  echo
}

cmd_init_entry() {
  need_root
  require_deps
  ensure_key

  local relay_host="" relay_pub="" relay_port="$WG_PORT" wg_if="$WG_IF" entry_ip_cidr="$ENTRY_WG_IP_CIDR" allowed_ips="0.0.0.0/0"

  while [ $# -gt 0 ]; do
    case "$1" in
      --relay-host) relay_host="$2"; shift 2;;
      --relay-pub) relay_pub="$2"; shift 2;;
      --relay-port) relay_port="$2"; shift 2;;
      --wg-if) wg_if="$2"; shift 2;;
      --entry-wg-ip-cidr) entry_ip_cidr="$2"; shift 2;;
      --allowed-ips) allowed_ips="$2"; shift 2;;
      --max-tcp-connections) MAX_TCP_CONNECTIONS="$2"; shift 2;;
      --max-udp-clients) MAX_UDP_CLIENTS="$2"; shift 2;;
      --tcp-idle-timeout) TCP_IDLE_TIMEOUT="$2"; shift 2;;
      --udp-idle-timeout) UDP_IDLE_TIMEOUT="$2"; shift 2;;
      --connect-timeout) CONNECT_TIMEOUT="$2"; shift 2;;
      --log-level) LOG_LEVEL="$2"; shift 2;;
      --target-family) TARGET_FAMILY="$2"; shift 2;;
      *) echo "未知参数：$1" >&2; exit 1;;
    esac
  done

  if [ -t 0 ]; then
    echo
    echo "=== 入口节点初始化 ==="
    ask wg_if "WireGuard 接口名称" "$wg_if"
    ask entry_ip_cidr "入口节点 WireGuard 地址 CIDR" "$entry_ip_cidr"
    [ -n "$relay_host" ] || ask_required relay_host "中继节点地址或 DDNS 域名"
    ask_port relay_port "中继 WireGuard UDP 端口" "$relay_port"
    [ -n "$relay_pub" ] || ask_required relay_pub "中继节点 WireGuard 公钥"
    ask allowed_ips "AllowedIPs，通常建议使用默认值" "$allowed_ips"
  elif [ -z "$relay_host" ] || [ -z "$relay_pub" ]; then
    echo "缺少参数 --relay-host 或 --relay-pub" >&2
    exit 1
  fi

  validate_iface "$wg_if"
  validate_host "$relay_host"
  validate_port "$relay_port" "中继端口"
  validate_cidr "$entry_ip_cidr" "入口 WireGuard 地址 CIDR"
  validate_wg_pubkey "$relay_pub" "中继节点公钥"
  validate_allowed_ips "$allowed_ips"
  validate_runtime_limits

  WG_IF="$wg_if"
  WG_PORT="$relay_port"
  ENTRY_WG_IP_CIDR="$entry_ip_cidr"
  refresh_wg_conf

  save_config
  install_relay
  backup_path "$WG_CONF"
  record_runtime "$WG_IF" "$WG_NET_V4"
  record_unit "wg-quick@${WG_IF}.service"

  cat > "$WG_CONF" <<EOF
[Interface]
Address = ${ENTRY_WG_IP_CIDR}
PrivateKey = $(cat "${KEY_DIR}/privatekey")
Table = off

[Peer]
PublicKey = ${relay_pub}
Endpoint = $(endpoint "$relay_host" "$relay_port")
AllowedIPs = ${allowed_ips}
PersistentKeepalive = 25
EOF

  chmod 600 "$WG_CONF"
  systemctl enable "wg-quick@${WG_IF}" >/dev/null
  systemctl restart "wg-quick@${WG_IF}"

  echo
  echo "入口节点 WireGuard 已启动：${WG_IF} -> $(endpoint "$relay_host" "$relay_port")"
  echo "入口节点公钥："
  cat "${KEY_DIR}/publickey"
  echo
}

cmd_add_target() {
  need_root
  require_deps
  ensure_dirs
  load_config
  validate_runtime_limits
  install_relay

  [ $# -eq 4 ] || {
    echo "用法：bash $0 add-target <名称> <目标主机或IPv4> <目标端口> <入口监听端口>" >&2
    echo "示例：bash $0 add-target target1 203.0.113.10 54677 54677" >&2
    echo "示例：bash $0 add-target target2 exit.example.com 54677 54678" >&2
    exit 1
  }

  local name="$1" target_host="$2" target_port="$3" listen_port="$4" tmp=""

  validate_target_name "$name"
  validate_host "$target_host"
  validate_port "$target_port" "目标端口"
  validate_port "$listen_port" "监听端口"

  python3 - "$target_host" "$target_port" <<'PY'
import socket, sys
host = sys.argv[1]
port = int(sys.argv[2])
try:
    socket.getaddrinfo(host, port, socket.AF_INET, socket.SOCK_STREAM)
except socket.gaierror as exc:
    print(
        f"警告：无法解析 {host} 的 IPv4 A 记录：{exc}\n"
        "配置仍会保存。中继服务会在新连接到来时再次尝试解析。",
        file=sys.stderr,
    )
PY

  tmp="$(mktemp)"
  awk -F, -v name="$name" '$1 != name { print }' "$FORWARDS" > "$tmp"
  mv "$tmp" "$FORWARDS"
  echo "${name},${target_host},${target_port},${listen_port}" >> "$FORWARDS"

  systemctl enable --now wg-sdwan-port-relay.service
  systemctl restart wg-sdwan-port-relay.service

  echo
  echo "已添加目标："
  echo "  名称: ${name}"
  echo "  监听: [::]:${listen_port}"
  echo "  目标: ${target_host}:${target_port}"
  echo
}

cmd_del_target() {
  need_root
  ensure_dirs
  load_config
  [ $# -eq 1 ] || { echo "用法：bash $0 del-target <名称>" >&2; exit 1; }
  validate_target_name "$1"

  local tmp=""
  tmp="$(mktemp)"
  awk -F, -v name="$1" '$1 != name { print }' "$FORWARDS" > "$tmp"
  mv "$tmp" "$FORWARDS"
  systemctl restart wg-sdwan-port-relay.service >/dev/null 2>&1 || true
  echo "已删除目标：$1"
}

cmd_list() {
  ensure_dirs
  echo
  echo "当前目标列表："
  if [ -s "$FORWARDS" ]; then
    column -s, -t "$FORWARDS" 2>/dev/null || cat "$FORWARDS"
  else
    echo "无"
  fi
  echo
}

cmd_status() {
  load_config
  echo
  echo "WireGuard 状态："
  wg show "$WG_IF" || true
  echo
  echo "中继服务状态："
  systemctl status wg-sdwan-port-relay.service --no-pager || true
  echo
  echo "目标列表："
  if [ -f "$FORWARDS" ]; then
    cat "$FORWARDS"
  else
    echo "无：${FORWARDS}"
  fi
  echo
}

cmd_rollback() {
  need_root
  local yes=0 force=0 wg_if="$WG_IF" net="$WG_NET_V4" old_ip_forward=""

  while [ $# -gt 0 ]; do
    case "$1" in
      -y|--yes) yes=1; shift;;
      --force-clean) force=1; shift;;
      --wg-if) wg_if="$2"; shift 2;;
      --wg-net-v4) net="$2"; shift 2;;
      *) echo "未知参数：$1" >&2; exit 1;;
    esac
  done

  validate_iface "$wg_if"
  validate_ipv4_cidr "$net" "WireGuard IPv4 subnet"

  if [ -s "$MANIFEST" ]; then
    wg_if="$(meta_get WG_IF "$wg_if")"
    net="$(meta_get WG_NET_V4 "$net")"
  elif [ "$force" -ne 1 ]; then
    echo "未找到回滚清单：$MANIFEST" >&2
    echo "如果是没有备份清单的旧安装，请使用：" >&2
    echo "  sudo bash $0 rollback --force-clean" >&2
    exit 1
  fi

  echo
  echo "将在本机执行回滚："
  echo "  WG_IF=${wg_if}"
  echo "  WG_NET_V4=${net}"
  echo

  if [ "$yes" -ne 1 ]; then
    read -rp "输入 YES 继续: " confirm
    if [ "$confirm" != "YES" ]; then
      echo "已取消。"
      exit 0
    fi
  fi

  systemctl disable --now wg-sdwan-port-relay.service >/dev/null 2>&1 || true
  systemctl disable --now "wg-quick@${wg_if}.service" >/dev/null 2>&1 || true
  wg-quick down "$wg_if" >/dev/null 2>&1 || true
  ip link del "$wg_if" >/dev/null 2>&1 || true

  if [ -s "$MANIFEST" ]; then
    while iptables -t nat -D POSTROUTING -s "$net" -m comment --comment "$IPT_COMMENT" -j MASQUERADE >/dev/null 2>&1; do :; done
    old_ip_forward="$(meta_get SYSCTL_NET_IPV4_IP_FORWARD unknown)"
    if [ "$old_ip_forward" != "unknown" ]; then
      sysctl -w "net.ipv4.ip_forward=${old_ip_forward}" >/dev/null 2>&1 || true
    fi
    tac "$MANIFEST" | while IFS=$'\t' read -r action path backup; do
      case "$action" in
        RESTORE)
          rm -rf "$path"
          mkdir -p "$(dirname "$path")"
          cp -a "$backup" "$path"
          echo "已恢复：$path"
          ;;
        DELETE)
          rm -rf "$path"
          echo "已删除：$path"
          ;;
      esac
    done
  fi

  if [ "$force" -eq 1 ]; then
    rm -f "$RELAY_BIN" "$RELAY_SERVICE" "/etc/wireguard/${wg_if}.conf"
    rm -rf "$CONF_DIR"
    while iptables -t nat -D POSTROUTING -s "$net" -m comment --comment "$IPT_COMMENT" -j MASQUERADE >/dev/null 2>&1; do :; done
  fi

  systemctl daemon-reload >/dev/null 2>&1 || true

  if [ -s "$MANIFEST" ]; then
    restore_unit wg-sdwan-port-relay.service
    restore_unit "wg-quick@${wg_if}.service"
  fi

  rm -rf "$STATE_DIR" "$BACKUP_DIR"
  echo "回滚完成。"
}

usage() {
  cat <<EOF
用法：
  bash $0 check                 检查依赖是否安装
  bash $0 install-deps          安装依赖
  bash $0 keygen                生成/显示本机 WireGuard 公钥

  bash $0 init-relay            初始化中继节点
  bash $0 init-entry            初始化入口节点

  bash $0 add-target target1 203.0.113.10 54677 54677
  bash $0 add-target target2 exit.example.com 54677 54678
  bash $0 del-target target1
  bash $0 list-targets          列出转发目标
  bash $0 status                查看运行状态

  bash $0 rollback              按备份清单回滚
  bash $0 rollback --force-clean 强制清理安装内容

非交互示例：
  bash $0 init-relay \\
    --entry-pub <入口节点公钥> \\
    --listen-port 51820 \\
    --wg-if wg-sdwan \\
    --relay-wg-ip-cidr 10.233.233.1/24 \\
    --entry-wg-ip 10.233.233.2 \\
    --wg-net-v4 10.233.233.0/24

  bash $0 init-entry \\
    --relay-host sdwan.example.com \\
    --relay-pub <中继节点公钥> \\
    --relay-port 51820 \\
    --wg-if wg-sdwan \\
    --entry-wg-ip-cidr 10.233.233.2/24 \\
    --allowed-ips 0.0.0.0/0

入口节点上的可选中继限制：
  --max-tcp-connections 1024    最大 TCP 连接数
  --max-udp-clients 4096        最大 UDP 客户端数
  --tcp-idle-timeout 300        TCP 空闲超时秒数
  --udp-idle-timeout 180        UDP 空闲超时秒数
  --connect-timeout 15          连接超时秒数
  --log-level info              日志级别：debug/info/warning/error
  --target-family ipv4          目标地址族：ipv4/any

兼容别名：
  init-sdwan      -> init-relay
  init-a          -> init-entry
  add-exit        -> add-target
  del-exit        -> del-target
  list-exits      -> list-targets
EOF
}

cmd="${1:-}"
shift || true

case "$cmd" in
  check) cmd_check "$@";;
  install-deps) cmd_install_deps "$@";;
  keygen) cmd_keygen "$@";;
  init-relay|init-sdwan) cmd_init_relay "$@";;
  init-entry|init-a) cmd_init_entry "$@";;
  add-target|add-exit) cmd_add_target "$@";;
  del-target|del-exit) cmd_del_target "$@";;
  list-targets|list-exits) cmd_list "$@";;
  status) cmd_status "$@";;
  rollback) cmd_rollback "$@";;
  *) usage;;
esac
