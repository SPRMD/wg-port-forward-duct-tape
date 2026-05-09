# wg-sdwan-port-relay

一个基于 Bash + Python 的 WireGuard TCP/UDP 端口转发辅助脚本。

它适用于这样的网络结构：一台拥有公网 IPv6 入口的机器对外暴露端口，通过 WireGuard 隧道把流量转发到一台中转机器，再由中转机器使用 IPv4 出口访问一个或多个目标服务。

本项目适用于个人服务器和小规模自用场景，不是生产级代理或 SDWAN 系统。

## 功能特性

- 自动配置入口节点与中转节点之间的 WireGuard 隧道
- 入口节点支持公网 IPv6 监听
- 支持 TCP 和 UDP 转发
- 支持通过中转节点访问 IPv4 目标服务
- 支持 DDNS 目标域名
- 支持添加多个目标服务
- 支持交互式初始化
- 支持非交互式初始化
- 支持回退脚本操作
- 保留旧命令别名，兼容早期用法

## 网络拓扑

```text
客户端
  |
  | 访问 entry.example.com:54677
  v
入口节点 Entry Node
  |
  | WireGuard 隧道
  v
中转节点 Relay Node
  |
  | IPv4 NAT 出口
  v
目标服务 Target Service
```

示例：

```text
客户端
  |
  | entry.example.com:54677
  v
入口节点
  |
  | wg-sdwan
  v
中转节点
  |
  | IPv4 出口
  v
203.0.113.10:54677
```

## 节点说明

### 入口节点 Entry Node

入口节点负责：

- 对外提供 IPv6 访问入口
- 监听公网 TCP/UDP 端口
- 将流量通过 WireGuard 隧道转发到中转节点
- 通常不需要公网 IPv4

### 中转节点 Relay Node

中转节点负责：

- 接收入口节点的 WireGuard 连接
- 提供 IPv4 出口
- 为 WireGuard 网段做 IPv4 NAT

### 目标服务 Target Service

目标服务可以是：

- IPv4 地址
- DDNS 域名
- 任意 TCP/UDP 服务

目标服务会通过中转节点的 IPv4 出口访问。

## 系统要求

支持的 Linux 发行版：

- Debian / Ubuntu
- Fedora
- CentOS / RHEL 兼容发行版

脚本会在可能的情况下自动安装以下依赖：

- `wireguard-tools`
- `iproute2` 或 `iproute`
- `iptables`
- `python3`

脚本需要使用 root 权限运行。

## 安装

将脚本复制到入口节点和中转节点：

```bash
sudo install -m 700 wg-sdwan-port-relay.sh /root/wg-sdwan-port-relay.sh
```

或者：

```bash
chmod +x wg-sdwan-port-relay.sh
sudo mv wg-sdwan-port-relay.sh /root/wg-sdwan-port-relay.sh
```

## 快速开始

### 1. 生成 WireGuard 公钥

在入口节点和中转节点都执行：

```bash
sudo bash /root/wg-sdwan-port-relay.sh keygen
```

分别保存两台机器输出的公钥。

你需要准备：

- 入口节点公钥
- 中转节点公钥

## 2. 初始化中转节点

在中转节点执行：

```bash
sudo bash /root/wg-sdwan-port-relay.sh init-relay
```

脚本会询问：

```text
WireGuard interface name [wg-sdwan]:
WireGuard UDP listen port [51820]:
Relay node WireGuard address CIDR [10.233.233.1/24]:
Entry node WireGuard IP without CIDR [10.233.233.2]:
WireGuard IPv4 subnet for NAT [10.233.233.0/24]:
Entry node WireGuard public key:
```

请确保中转节点防火墙允许 WireGuard UDP 端口入站，例如：

```text
UDP 51820
```

## 3. 初始化入口节点

在入口节点执行：

```bash
sudo bash /root/wg-sdwan-port-relay.sh init-entry
```

脚本会询问：

```text
WireGuard interface name [wg-sdwan]:
Entry node WireGuard address CIDR [10.233.233.2/24]:
Relay node address or DDNS hostname:
Relay WireGuard UDP port [51820]:
Relay node WireGuard public key:
AllowedIPs, default is usually recommended [0.0.0.0/0]:
```

中转节点地址可以是：

- 普通域名
- DDNS 域名
- IPv6 地址
- 可访问的 IPv4 地址

示例：

```text
sdwan.example.com
```

## 4. 添加目标服务

在入口节点添加目标服务：

```bash
sudo bash /root/wg-sdwan-port-relay.sh add-target target1 203.0.113.10 54677 54677
```

含义是：

```text
入口节点监听地址: [::]:54677
目标服务地址:     203.0.113.10:54677
```

之后客户端可以访问：

```text
entry.example.com:54677
```

流量会经过 WireGuard 隧道，并从中转节点出口访问目标服务。

## DDNS 目标示例

也可以使用 DDNS 域名作为目标服务地址：

```bash
sudo bash /root/wg-sdwan-port-relay.sh add-target target2 exit.example.com 54677 54678
```

含义是：

```text
入口节点监听地址: [::]:54678
目标服务地址:     exit.example.com:54677
```

目标域名会在新的 TCP 或 UDP 会话创建时解析。

默认情况下，转发程序只解析 IPv4 A 记录。这样可以避免目标域名同时存在 AAAA 记录时，流量绕过中转节点直接走 IPv6。

## 管理目标服务

### 查看目标列表

```bash
sudo bash /root/wg-sdwan-port-relay.sh list-targets
```

### 删除目标

```bash
sudo bash /root/wg-sdwan-port-relay.sh del-target target1
```

### 查看状态

```bash
sudo bash /root/wg-sdwan-port-relay.sh status
```

该命令会显示：

- WireGuard 状态
- 转发服务状态
- 当前目标服务列表

## 非交互式用法

### 初始化中转节点

```bash
sudo bash /root/wg-sdwan-port-relay.sh init-relay \
  --entry-pub <ENTRY_PUBLIC_KEY> \
  --listen-port 51820 \
  --wg-if wg-sdwan \
  --relay-wg-ip-cidr 10.233.233.1/24 \
  --entry-wg-ip 10.233.233.2 \
  --wg-net-v4 10.233.233.0/24
```

### 初始化入口节点

```bash
sudo bash /root/wg-sdwan-port-relay.sh init-entry \
  --relay-host sdwan.example.com \
  --relay-pub <RELAY_PUBLIC_KEY> \
  --relay-port 51820 \
  --wg-if wg-sdwan \
  --entry-wg-ip-cidr 10.233.233.2/24 \
  --allowed-ips 0.0.0.0/0
```

### 添加 IPv4 目标

```bash
sudo bash /root/wg-sdwan-port-relay.sh add-target target1 203.0.113.10 54677 54677
```

### 添加 DDNS 目标

```bash
sudo bash /root/wg-sdwan-port-relay.sh add-target target2 exit.example.com 54677 54678
```

## 兼容命令别名

脚本保留了旧命令别名：

```text
init-sdwan   -> init-relay
init-a       -> init-entry
add-exit     -> add-target
del-exit     -> del-target
list-exits   -> list-targets
```

例如：

```bash
sudo bash /root/wg-sdwan-port-relay.sh init-sdwan
```

等价于：

```bash
sudo bash /root/wg-sdwan-port-relay.sh init-relay
```

## 回退操作

脚本在修改文件前会记录备份。

回退当前机器上的脚本操作：

```bash
sudo bash /root/wg-sdwan-port-relay.sh rollback
```

跳过确认提示：

```bash
sudo bash /root/wg-sdwan-port-relay.sh rollback --yes
```

如果是旧版本安装，没有回退清单，可以使用强制清理：

```bash
sudo bash /root/wg-sdwan-port-relay.sh rollback --force-clean
```

如果使用了自定义 WireGuard 接口名：

```bash
sudo bash /root/wg-sdwan-port-relay.sh rollback --force-clean --wg-if wg-custom
```

如果使用了自定义 WireGuard IPv4 网段：

```bash
sudo bash /root/wg-sdwan-port-relay.sh rollback --force-clean --wg-net-v4 10.88.88.0/24
```

## 脚本创建的文件

脚本可能会创建或修改以下路径：

```text
/etc/wg-sdwan-port-relay/
/etc/wg-sdwan-port-relay/keys/privatekey
/etc/wg-sdwan-port-relay/keys/publickey
/etc/wg-sdwan-port-relay/forwards.csv
/etc/wg-sdwan-port-relay/config.env
/etc/wireguard/<interface>.conf
/usr/local/bin/wg-sdwan-port-relay.py
/etc/systemd/system/wg-sdwan-port-relay.service
/var/lib/wg-sdwan-port-relay/
/var/backups/wg-sdwan-port-relay/
```

## 防火墙说明

### 中转节点

需要允许 WireGuard UDP 端口入站：

```text
UDP 51820
```

### 入口节点

需要允许对外暴露的监听端口入站，例如：

```text
TCP 54677
UDP 54677
```

如果添加了另一个目标，监听端口为 `54678`，则需要允许：

```text
TCP 54678
UDP 54678
```

## DDNS 解析机制

当目标服务使用域名时：

```bash
sudo bash /root/wg-sdwan-port-relay.sh add-target target2 exit.example.com 54677 54678
```

转发程序会在新的 TCP 或 UDP 会话创建时解析该域名。

解析到 IPv4 地址后，会添加类似下面的路由：

```text
ip route replace <resolved-ip>/32 dev <wireguard-interface>
```

这样可以确保访问目标 IPv4 的流量走 WireGuard 隧道。

## 安全建议

不要将运行时生成的配置文件或密钥提交到 Git 仓库。

推荐 `.gitignore`：

```gitignore
# Runtime configs and generated secrets
*.conf
*.key
privatekey
publickey
forwards.csv
config.env
manifest.tsv

# Runtime state
wg-sdwan-port-relay/
var/
backups/

# Logs
*.log
```

发布前建议扫描敏感信息：

```bash
grep -RInE 'PrivateKey|PublicKey|Endpoint|password|passwd|secret|token|key' .
```

扫描 IP 地址和域名：

```bash
grep -RInE '([a-zA-Z0-9-]+\.)+[a-zA-Z]{2,}|([0-9]{1,3}\.){3}[0-9]{1,3}' .
```

## 注意事项

- 脚本在中转节点使用 `iptables` 做 IPv4 NAT。
- NAT 规则会带有 `wg-sdwan-port-relay` comment 标记。
- 在存在回退清单时，rollback 只删除脚本创建的 NAT 规则。
- rollback 不会自动卸载已安装的软件包。
- 请仅在你拥有或被授权管理的服务器和网络中使用本脚本。

## License

MIT License
