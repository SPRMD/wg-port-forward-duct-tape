#!/usr/bin/env bash
set -euo pipefail

WG_IF="${WG_IF:-wg-sdwan}"
WG_PORT="${WG_PORT:-51820}"
WG_NET_V4="${WG_NET_V4:-10.233.233.0/24}"
RELAY_WG_IP_CIDR="${RELAY_WG_IP_CIDR:-10.233.233.1/24}"
ENTRY_WG_IP_CIDR="${ENTRY_WG_IP_CIDR:-10.233.233.2/24}"
RELAY_WG_IP="${RELAY_WG_IP:-10.233.233.1}"
ENTRY_WG_IP="${ENTRY_WG_IP:-10.233.233.2}"

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
  [ "$(id -u)" -eq 0 ] || {
    echo "Please run as root, for example: sudo bash $0 ..."
    exit 1
  }
}

refresh_wg_conf() {
  WG_CONF="/etc/wireguard/${WG_IF}.conf"
}

load_config() {
  [ -f "$CONFIG_ENV" ] && . "$CONFIG_ENV" || true
  refresh_wg_conf
}

save_config() {
  ensure_dirs
  printf "WG_IF=%q\nWG_NET_V4=%q\n" "$WG_IF" "$WG_NET_V4" > "$CONFIG_ENV"
}

install_pkgs() {
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y wireguard-tools iproute2 iptables python3
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y wireguard-tools iproute iptables python3
  elif command -v yum >/dev/null 2>&1; then
    yum install -y wireguard-tools iproute iptables python3
  else
    echo "Unsupported package manager. Please install: wireguard-tools, iproute2/iproute, iptables, python3"
    exit 1
  fi
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
  local path="$1"
  local hash=""
  local dest=""

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
  local key="$1"
  local value="$2"

  state_init

  awk -F '\t' -v key="$key" '
    $1 == "META" && $2 == key { found = 1 }
    END { exit found ? 0 : 1 }
  ' "$MANIFEST" && return 0

  printf 'META\t%s\t%s\n' "$key" "$value" >> "$MANIFEST"
}

meta_get() {
  local key="$1"
  local default_value="${2:-}"

  [ -f "$MANIFEST" ] || {
    echo "$default_value"
    return
  }

  awk -F '\t' -v key="$key" -v default_value="$default_value" '
    $1 == "META" && $2 == key {
      print $3
      found = 1
      exit
    }
    END {
      if (!found) print default_value
    }
  ' "$MANIFEST"
}

record_unit() {
  local unit="$1"

  meta_once "UNIT_${unit}_ENABLED" "$(systemctl is-enabled "$unit" 2>/dev/null || true)"
  meta_once "UNIT_${unit}_ACTIVE" "$(systemctl is-active "$unit" 2>/dev/null || true)"
}

restore_unit() {
  local unit="$1"
  local enabled_state=""
  local active_state=""

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
  local wg_if="$1"
  local net="$2"

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

ensure_key() {
  ensure_dirs

  if [ ! -f "${KEY_DIR}/privatekey" ]; then
    wg genkey | tee "${KEY_DIR}/privatekey" | wg pubkey > "${KEY_DIR}/publickey"
    chmod 600 "${KEY_DIR}/privatekey"
  fi
}

ask() {
  local var="$1"
  local prompt="$2"
  local default_value="${3:-}"
  local input=""

  read -rp "${prompt}${default_value:+ [$default_value]}: " input
  printf -v "$var" '%s' "${input:-$default_value}"
}

ask_required() {
  local var="$1"
  local prompt="$2"
  local input=""

  while true; do
    read -rp "${prompt}: " input

    if [ -n "$input" ]; then
      printf -v "$var" '%s' "$input"
      return
    fi

    echo "Value cannot be empty."
  done
}

ask_port() {
  local var="$1"
  local prompt="$2"
  local default_value="$3"
  local input=""

  while true; do
    ask input "$prompt" "$default_value"

    if [[ "$input" =~ ^[0-9]+$ ]] && [ "$input" -ge 1 ] && [ "$input" -le 65535 ]; then
      printf -v "$var" '%s' "$input"
      return
    fi

    echo "Port must be an integer between 1 and 65535."
  done
}

endpoint() {
  local host="$1"
  local port="$2"

  if [[ "$host" == \[*\] ]]; then
    echo "${host}:${port}"
  elif [[ "$host" == *:* ]]; then
    echo "[${host}]:${port}"
  else
    echo "${host}:${port}"
  fi
}

install_relay() {
  backup_path "$RELAY_BIN"

  cat > "$RELAY_BIN" <<'PY'
#!/usr/bin/env python3
import csv
import os
import select
import socket
import subprocess
import sys
import threading
import time

CONFIG = sys.argv[1] if len(sys.argv) > 1 else "/etc/wg-sdwan-port-relay/forwards.csv"
WG_IF = os.environ.get("WG_IF", "wg-sdwan")
TARGET_FAMILY = os.environ.get("TARGET_FAMILY", "ipv4")

def log(message):
    print(time.strftime("[%F %T]"), message, flush=True)

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

    infos.sort(key=lambda x: 0 if x[0] == socket.AF_INET else 1)

    af, _, _, _, sockaddr = infos[0]

    if af == socket.AF_INET:
        route_v4(sockaddr[0])

    return af, sockaddr, sockaddr[0]

def load_forwards():
    if not os.path.exists(CONFIG):
        return []

    rows = []

    with open(CONFIG, newline="") as f:
        for row in csv.reader(f):
            if not row or row[0].strip().startswith("#"):
                continue

            if len(row) != 4:
                log(f"Skip invalid row: {row}")
                continue

            name, target_host, target_port, listen_port = [x.strip() for x in row]

            rows.append((
                name,
                target_host,
                int(target_port),
                int(listen_port),
            ))

    return rows

def tcp_pipe(client, target_host, target_port):
    upstream = None

    try:
        af, sockaddr, resolved_ip = resolve_target(
            target_host,
            target_port,
            socket.SOCK_STREAM,
        )

        upstream = socket.socket(af, socket.SOCK_STREAM)
        upstream.settimeout(15)
        upstream.connect(sockaddr)
        upstream.settimeout(None)

        log(f"TCP -> {target_host}:{target_port} resolved={resolved_ip}")

        sockets = [client, upstream]

        while True:
            readable, _, _ = select.select(sockets, [], [], 300)

            for sock in readable:
                data = sock.recv(65536)

                if not data:
                    return

                peer = upstream if sock is client else client
                peer.sendall(data)

    except Exception as exc:
        log(f"TCP end {target_host}:{target_port}: {exc}")
    finally:
        try:
            client.close()
        except Exception:
            pass

        try:
            if upstream:
                upstream.close()
        except Exception:
            pass

def tcp_listener(target_host, target_port, listen_port):
    server = socket.socket(socket.AF_INET6, socket.SOCK_STREAM)
    server.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(("::", listen_port))
    server.listen(1024)

    log(f"TCP listen [::]:{listen_port} -> {target_host}:{target_port}")

    while True:
        client, _ = server.accept()

        threading.Thread(
            target=tcp_pipe,
            args=(client, target_host, target_port),
            daemon=True,
        ).start()

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

    def start(self):
        log(f"UDP listen [::]:{self.listen_port} -> {self.target_host}:{self.target_port}")

        threading.Thread(target=self.cleanup_loop, daemon=True).start()

        while True:
            data, client_addr = self.server.recvfrom(65535)

            with self.lock:
                entry = self.clients.get(client_addr)

                if entry is None:
                    af, sockaddr, resolved_ip = resolve_target(
                        self.target_host,
                        self.target_port,
                        socket.SOCK_DGRAM,
                    )

                    upstream = socket.socket(af, socket.SOCK_DGRAM)
                    upstream.settimeout(180)
                    upstream.connect(sockaddr)

                    entry = [upstream, time.time()]
                    self.clients[client_addr] = entry

                    log(
                        f"UDP {client_addr} -> "
                        f"{self.target_host}:{self.target_port} resolved={resolved_ip}"
                    )

                    threading.Thread(
                        target=self.reply_loop,
                        args=(client_addr, upstream),
                        daemon=True,
                    ).start()

                entry[1] = time.time()
                upstream = entry[0]

            try:
                upstream.send(data)
            except Exception as exc:
                log(f"UDP send error {client_addr}: {exc}")
                self.drop_client(client_addr)

    def reply_loop(self, client_addr, upstream):
        try:
            while True:
                data = upstream.recv(65535)

                if not data:
                    break

                self.server.sendto(data, client_addr)
        except Exception:
            pass

        self.drop_client(client_addr)

    def drop_client(self, client_addr):
        with self.lock:
            entry = self.clients.pop(client_addr, None)

        if entry:
            try:
                entry[0].close()
            except Exception:
                pass

    def cleanup_loop(self):
        while True:
            time.sleep(60)
            now = time.time()

            with self.lock:
                stale_clients = [
                    addr for addr, entry in self.clients.items()
                    if now - entry[1] > 180
                ]

            for addr in stale_clients:
                self.drop_client(addr)

def main():
    rows = load_forwards()

    if not rows:
        log(f"No forwarding config found: {CONFIG}")

        while True:
            time.sleep(3600)

    used_ports = set()

    for _, target_host, target_port, listen_port in rows:
        if listen_port in used_ports:
            raise SystemExit(f"Duplicate listen port: {listen_port}")

        used_ports.add(listen_port)

        threading.Thread(
            target=tcp_listener,
            args=(target_host, target_port, listen_port),
            daemon=True,
        ).start()

        threading.Thread(
            target=UDPRelay(target_host, target_port, listen_port).start,
            daemon=True,
        ).start()

    while True:
        time.sleep(3600)

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
Environment=TARGET_FAMILY=ipv4
ExecStart=/usr/bin/python3 ${RELAY_BIN} ${FORWARDS}
Restart=always
RestartSec=2
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
}

cmd_keygen() {
  need_root
  install_pkgs
  ensure_key

  echo
  echo "WireGuard public key:"
  cat "${KEY_DIR}/publickey"
  echo
}

cmd_init_relay() {
  need_root
  install_pkgs
  ensure_key

  local entry_pub=""
  local listen_port="$WG_PORT"
  local wg_if="$WG_IF"
  local relay_ip_cidr="$RELAY_WG_IP_CIDR"
  local entry_ip="$ENTRY_WG_IP"
  local wg_net="$WG_NET_V4"

  while [ $# -gt 0 ]; do
    case "$1" in
      --entry-pub)
        entry_pub="$2"
        shift 2
        ;;
      --listen-port)
        listen_port="$2"
        shift 2
        ;;
      --wg-if)
        wg_if="$2"
        shift 2
        ;;
      --relay-wg-ip-cidr)
        relay_ip_cidr="$2"
        shift 2
        ;;
      --entry-wg-ip)
        entry_ip="$2"
        shift 2
        ;;
      --wg-net-v4)
        wg_net="$2"
        shift 2
        ;;
      *)
        echo "Unknown argument: $1"
        exit 1
        ;;
    esac
  done

  if [ -t 0 ]; then
    echo
    echo "=== Relay node initialization ==="

    ask wg_if "WireGuard interface name" "$wg_if"
    ask_port listen_port "WireGuard UDP listen port" "$listen_port"
    ask relay_ip_cidr "Relay node WireGuard address CIDR" "$relay_ip_cidr"
    ask entry_ip "Entry node WireGuard IP without CIDR" "$entry_ip"
    ask wg_net "WireGuard IPv4 subnet for NAT" "$wg_net"

    [ -n "$entry_pub" ] || ask_required entry_pub "Entry node WireGuard public key"
  elif [ -z "$entry_pub" ]; then
    echo "Missing --entry-pub"
    exit 1
  fi

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
  echo "Relay WireGuard started: ${WG_IF} UDP/${WG_PORT}"
  echo "Relay public key:"
  cat "${KEY_DIR}/publickey"
  echo
}

cmd_init_entry() {
  need_root
  install_pkgs
  ensure_key

  local relay_host=""
  local relay_pub=""
  local relay_port="$WG_PORT"
  local wg_if="$WG_IF"
  local entry_ip_cidr="$ENTRY_WG_IP_CIDR"
  local allowed_ips="0.0.0.0/0"

  while [ $# -gt 0 ]; do
    case "$1" in
      --relay-host)
        relay_host="$2"
        shift 2
        ;;
      --relay-pub)
        relay_pub="$2"
        shift 2
        ;;
      --relay-port)
        relay_port="$2"
        shift 2
        ;;
      --wg-if)
        wg_if="$2"
        shift 2
        ;;
      --entry-wg-ip-cidr)
        entry_ip_cidr="$2"
        shift 2
        ;;
      --allowed-ips)
        allowed_ips="$2"
        shift 2
        ;;
      *)
        echo "Unknown argument: $1"
        exit 1
        ;;
    esac
  done

  if [ -t 0 ]; then
    echo
    echo "=== Entry node initialization ==="

    ask wg_if "WireGuard interface name" "$wg_if"
    ask entry_ip_cidr "Entry node WireGuard address CIDR" "$entry_ip_cidr"

    [ -n "$relay_host" ] || ask_required relay_host "Relay node address or DDNS hostname"

    ask_port relay_port "Relay WireGuard UDP port" "$relay_port"

    [ -n "$relay_pub" ] || ask_required relay_pub "Relay node WireGuard public key"

    ask allowed_ips "AllowedIPs, default is usually recommended" "$allowed_ips"
  elif [ -z "$relay_host" ] || [ -z "$relay_pub" ]; then
    echo "Missing --relay-host or --relay-pub"
    exit 1
  fi

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
  echo "Entry WireGuard started: ${WG_IF} -> $(endpoint "$relay_host" "$relay_port")"
  echo "Entry public key:"
  cat "${KEY_DIR}/publickey"
  echo
}

cmd_add_target() {
  need_root
  ensure_dirs
  load_config
  install_relay

  [ $# -eq 4 ] || {
    echo "Usage: bash $0 add-target <name> <target-host-or-ipv4> <target-port> <entry-listen-port>"
    echo "Example: bash $0 add-target target1 203.0.113.10 54677 54677"
    echo "Example: bash $0 add-target target2 exit.example.com 54677 54678"
    exit 1
  }

  local name="$1"
  local target_host="$2"
  local target_port="$3"
  local listen_port="$4"
  local tmp=""

  [[ "$name$target_host" != *","* ]] || {
    echo "Name and target host must not contain comma."
    exit 1
  }

  python3 - "$target_host" "$target_port" "$listen_port" <<'PY'
import socket
import sys

host = sys.argv[1]
target_port = int(sys.argv[2])
listen_port = int(sys.argv[3])

assert 1 <= target_port <= 65535, "target port must be between 1 and 65535"
assert 1 <= listen_port <= 65535, "listen port must be between 1 and 65535"

try:
    socket.getaddrinfo(host, target_port, socket.AF_INET, socket.SOCK_STREAM)
except socket.gaierror as exc:
    print(
        f"Warning: cannot resolve IPv4 A record for {host}: {exc}\n"
        "Config will still be saved. The relay will try resolving on new connections.",
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
  echo "Added target:"
  echo "  name: ${name}"
  echo "  listen: [::]:${listen_port}"
  echo "  target: ${target_host}:${target_port}"
  echo
}

cmd_del_target() {
  need_root
  ensure_dirs
  load_config

  [ $# -eq 1 ] || {
    echo "Usage: bash $0 del-target <name>"
    exit 1
  }

  local tmp=""
  tmp="$(mktemp)"

  awk -F, -v name="$1" '$1 != name { print }' "$FORWARDS" > "$tmp"
  mv "$tmp" "$FORWARDS"

  systemctl restart wg-sdwan-port-relay.service >/dev/null 2>&1 || true

  echo "Deleted target: $1"
}

cmd_list() {
  ensure_dirs

  echo
  echo "Current targets:"

  if [ -s "$FORWARDS" ]; then
    column -s, -t "$FORWARDS" 2>/dev/null || cat "$FORWARDS"
  else
    echo "None"
  fi

  echo
}

cmd_status() {
  load_config

  echo
  echo "WireGuard status:"
  wg show "$WG_IF" || true

  echo
  echo "Relay service status:"
  systemctl status wg-sdwan-port-relay.service --no-pager || true

  echo
  echo "Targets:"

  if [ -f "$FORWARDS" ]; then
    cat "$FORWARDS"
  else
    echo "None: ${FORWARDS}"
  fi

  echo
}

cmd_rollback() {
  need_root

  local yes=0
  local force=0
  local wg_if="$WG_IF"
  local net="$WG_NET_V4"
  local old_ip_forward=""

  while [ $# -gt 0 ]; do
    case "$1" in
      -y|--yes)
        yes=1
        shift
        ;;
      --force-clean)
        force=1
        shift
        ;;
      --wg-if)
        wg_if="$2"
        shift 2
        ;;
      --wg-net-v4)
        net="$2"
        shift 2
        ;;
      *)
        echo "Unknown argument: $1"
        exit 1
        ;;
    esac
  done

  if [ -s "$MANIFEST" ]; then
    wg_if="$(meta_get WG_IF "$wg_if")"
    net="$(meta_get WG_NET_V4 "$net")"
  elif [ "$force" -ne 1 ]; then
    echo "No rollback manifest found: $MANIFEST"
    echo "For old installations without backup manifest, use:"
    echo "  sudo bash $0 rollback --force-clean"
    exit 1
  fi

  echo
  echo "Rollback will be performed on this machine:"
  echo "  WG_IF=${wg_if}"
  echo "  WG_NET_V4=${net}"
  echo

  if [ "$yes" -ne 1 ]; then
    read -rp "Type YES to continue: " confirm

    if [ "$confirm" != "YES" ]; then
      echo "Cancelled."
      exit 0
    fi
  fi

  systemctl disable --now wg-sdwan-port-relay.service >/dev/null 2>&1 || true
  systemctl disable --now "wg-quick@${wg_if}.service" >/dev/null 2>&1 || true
  wg-quick down "$wg_if" >/dev/null 2>&1 || true
  ip link del "$wg_if" >/dev/null 2>&1 || true

  if [ -s "$MANIFEST" ]; then
    while iptables -t nat -D POSTROUTING -s "$net" -m comment --comment "$IPT_COMMENT" -j MASQUERADE >/dev/null 2>&1; do
      :
    done

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
          echo "Restored: $path"
          ;;
        DELETE)
          rm -rf "$path"
          echo "Deleted: $path"
          ;;
      esac
    done
  fi

  if [ "$force" -eq 1 ]; then
    rm -f "$RELAY_BIN" "$RELAY_SERVICE" "/etc/wireguard/${wg_if}.conf"
    rm -rf "$CONF_DIR"

    while iptables -t nat -D POSTROUTING -s "$net" -m comment --comment "$IPT_COMMENT" -j MASQUERADE >/dev/null 2>&1; do
      :
    done

    while iptables -t nat -D POSTROUTING -s "$net" -j MASQUERADE >/dev/null 2>&1; do
      :
    done
  fi

  systemctl daemon-reload >/dev/null 2>&1 || true

  if [ -s "$MANIFEST" ]; then
    restore_unit wg-sdwan-port-relay.service
    restore_unit "wg-quick@${wg_if}.service"
  fi

  rm -rf "$STATE_DIR" "$BACKUP_DIR"

  echo "Rollback completed."
}

usage() {
  cat <<EOF
Usage:
  bash $0 keygen

  bash $0 init-relay
      Initialize the relay node. This node accepts WireGuard connections
      from the entry node and provides IPv4 NAT egress.

  bash $0 init-entry
      Initialize the entry node. This node listens on IPv6 and forwards
      TCP/UDP traffic to configured targets through the relay node.

  bash $0 add-target target1 203.0.113.10 54677 54677
  bash $0 add-target target2 exit.example.com 54677 54678

  bash $0 del-target target1
  bash $0 list-targets
  bash $0 status

  bash $0 rollback
  bash $0 rollback --force-clean

Non-interactive examples:

  bash $0 init-relay \\
    --entry-pub <ENTRY_PUBLIC_KEY> \\
    --listen-port 51820 \\
    --wg-if wg-sdwan \\
    --relay-wg-ip-cidr 10.233.233.1/24 \\
    --entry-wg-ip 10.233.233.2 \\
    --wg-net-v4 10.233.233.0/24

  bash $0 init-entry \\
    --relay-host sdwan.example.com \\
    --relay-pub <RELAY_PUBLIC_KEY> \\
    --relay-port 51820 \\
    --wg-if wg-sdwan \\
    --entry-wg-ip-cidr 10.233.233.2/24 \\
    --allowed-ips 0.0.0.0/0

Compatibility aliases:
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
  keygen)
    cmd_keygen "$@"
    ;;
  init-relay|init-sdwan)
    cmd_init_relay "$@"
    ;;
  init-entry|init-a)
    cmd_init_entry "$@"
    ;;
  add-target|add-exit)
    cmd_add_target "$@"
    ;;
  del-target|del-exit)
    cmd_del_target "$@"
    ;;
  list-targets|list-exits)
    cmd_list "$@"
    ;;
  status)
    cmd_status "$@"
    ;;
  rollback)
    cmd_rollback "$@"
    ;;
  *)
    usage
    ;;
esac
