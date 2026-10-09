# Shoes Shell Manager

一个面向 Ubuntu Server 的 Shoes 一体化安装与管理脚本。使用 Bash + systemd 管理服务，通过交互式终端菜单完成安装、更新、代理链接轮换、查看链接、日志查看和卸载。

**单进程、双协议、统一端口：**

* **TCP/443：** VLESS + REALITY + XTLS Vision
* **UDP/443：** Hysteria2 + QUIC + HTTP/3
* **服务管理：** systemd
* **终端界面：** 霓虹风格菜单，非交互输出时自动关闭颜色
* **CPU 架构：** x86_64、ARM64（aarch64）

## 功能特性

### 一键安装与更新

* 自动识别 CPU 架构并获取 Shoes 上游最新正式 Release。
* 下载后校验 SHA-256 摘要、可执行文件版本和 REALITY 密钥生成能力。
* 自动安装运行依赖，生成 REALITY 密钥、Short ID、VLESS UUID 和 Hysteria2 密码。
* 生成 Shoes 配置文件、客户端连接链接及 systemd 服务。
* 安装或更新后检查服务状态，更新失败时尝试恢复旧版本。

### VLESS + REALITY + Vision

* 使用 Shoes 内置 REALITY 服务端。
* 支持自定义连接地址、REALITY SNI 和回落目标。
* 使用 XTLS Vision 流控。
* VLESS UUID、REALITY 密钥对及 Short ID 由管理脚本生成。

### Hysteria2 + QUIC

* 使用 UDP/443 提供 Hysteria2 服务。
* 使用 QUIC 和 HTTP/3 ALPN（`h3`）。
* 支持 Let's Encrypt 可信证书。
* 支持公网 IPv4 或域名场景下的自签根 CA 与服务器证书方案。
* 证书续期任务由 systemd timer 管理，并通过部署钩子更新服务所用证书。

### 安全的链接轮换

重新生成链接时，会重新生成代理凭据，并在应用新配置成功后使原凭据失效。

轮换内容包括：

* VLESS UUID
* REALITY 密钥对
* REALITY Short ID
* Hysteria2 密码
* 客户端链接文件

操作前会备份相关配置。若新配置校验或服务重启失败，脚本会尝试恢复旧配置、证书及链接。

注意：已经建立的旧连接可能持续到会话断开，但旧凭据不应继续用于建立新的有效连接。

## 环境要求

* Ubuntu Server
* systemd 正常运行
* root 权限
* x86_64 或 ARM64 CPU
* 公网 IPv4 地址或普通域名
* TCP/443、UDP/443 可用
* 能够访问 GitHub Releases 及所需的依赖软件源

使用 Let's Encrypt 域名证书时，需要域名解析指向服务器，并满足证书签发所需的网络验证条件。使用公网 IP 证书时，需要当前 ACME 客户端及签发机构支持 IP 地址证书。

如果服务器使用 UFW，应确保相关端口规则允许所需的入站流量。证书签发方式不同，可能还需要开放 TCP/80。

## 快速开始

### 1. 下载管理脚本

以 root 身份执行：

```bash
curl -fsSL \
  https://raw.githubusercontent.com/kwrum1/shoes-shell/main/shoes-manager.sh \
  -o /usr/local/sbin/shoes-manager

chmod 0755 /usr/local/sbin/shoes-manager
```

也可以一次性复制执行：

```bash
sudo -i

curl -fsSL \
  https://raw.githubusercontent.com/kwrum1/shoes-shell/main/shoes-manager.sh \
  -o /usr/local/sbin/shoes-manager \
&& chmod 0755 /usr/local/sbin/shoes-manager \
&& /usr/local/sbin/shoes-manager
```

请确保第一条命令成功下载文件后再运行第二条命令。脚本需要交互式终端，因此不要直接使用 `curl ... | bash` 代替下载步骤。

### 2. 启动管理菜单

```bash
sudo /usr/local/sbin/shoes-manager
```

进入菜单后，选择对应的功能。

### 3. 首次安装

选择菜单中的：

`1. 一键安装 / 更新 Shoes`

按提示输入连接地址、REALITY SNI、回落目标和 Hysteria2 证书方案。

安装完成后，脚本会显示生成的 VLESS 和 Hysteria2 链接。将相应链接导入兼容的客户端即可使用。

### 4. 更新管理脚本

重新下载仓库最新版本，再执行：

```bash
sudo /usr/local/sbin/shoes-manager
```

随后在菜单中选择安装 / 更新 Shoes。

更新管理脚本与更新 Shoes 服务端程序是两个独立步骤。

## 菜单说明

| 菜单  | 功能              |
| --- | --------------- |
| `1` | 一键安装 / 更新 Shoes |
| `2` | 重新生成链接及代理凭据     |
| `3` | 查看当前客户端链接       |
| `4` | 卸载 Shoes 和代理配置  |
| `5` | 查看 Shoes 实时日志   |
| `0` | 退出              |

日志界面按 `Ctrl+C` 退出跟踪，再按提示返回菜单。

卸载前会要求输入 `yes` 确认，避免误删。卸载会删除 Shoes 服务、代理凭据、链接及相关配置，但不会卸载 XanMod 内核、移除 APT 仓库或自动删除已经放行的 UFW 规则。

## 配置与文件位置

| 文件 / 路径                             | 用途              |
| ----------------------------------- | --------------- |
| `/usr/local/bin/shoes`              | Shoes 主程序       |
| `/etc/shoes/config.yaml`            | 服务端配置           |
| `/etc/shoes/links.txt`              | 当前客户端链接         |
| `/etc/shoes/manager.env`            | 管理器状态           |
| `/etc/shoes/hy2-cert.pem`           | Hysteria2 服务器证书 |
| `/etc/shoes/hy2-key.pem`            | Hysteria2 服务器私钥 |
| `/etc/systemd/system/shoes.service` | systemd 服务单元    |
| `/usr/local/sbin/shoes-manager`     | 管理脚本（按上述方式安装时）  |

证书轮换相关的 CA 文件、续期脚本和定时器文件也由管理器维护。

**安全提示：** `links.txt`、`manager.env`、REALITY 私钥、Hysteria2 密码及证书私钥包含敏感信息。请勿上传至公开仓库、粘贴到公开问题单或分享给不可信人员。

## 服务管理

查看服务状态：

```bash
systemctl status shoes --no-pager -l
```

查看最近日志：

```bash
journalctl -u shoes -n 100 --no-pager
```

实时跟踪日志：

```bash
journalctl -u shoes -n 100 -f --no-pager
```

查看版本：

```bash
shoes --version
```

检查监听端口：

```bash
ss -lntup | grep ':443'
```

TCP/443 应提供 VLESS + REALITY 服务，UDP/443 应提供 Hysteria2 服务。

## 关于伪装能力

REALITY 和 Hysteria2 是两套不同的传输机制。

* REALITY 的目标选择、握手处理与回落行为取决于 Shoes 的具体实现及服务端配置。
* Hysteria2 的可信 TLS 证书、QUIC 和 `h3` ALPN 不等于真实网站回落。
* 当前公开版 Shoes 的 Hysteria2 配置未提供可配置的 `masquerade` 网站回落后端，也未暴露 Salamander 混淆配置。
* `EOF`、`Connection reset`、HTTP/3 数据流被对端关闭等日志，不能单独证明伪装失效。
* 代理能够正常上网，也不能单独证明服务器对所有主动探测请求都呈现为真实网站。

本项目不承诺无法验证的伪装效果。请根据实际客户端兼容性、线路表现及服务端日志进行验证。

## 故障排查

如果服务不能正常启动，首先查看：

```bash
systemctl status shoes --no-pager -l

journalctl -u shoes -n 100 --no-pager
```

如果客户端无法连接，依次核对：

1. 客户端连接地址和端口是否正确。
2. VLESS 的 SNI、Public Key、Short ID 和 Flow 是否与服务端一致。
3. Hysteria2 密码、SNI、证书验证模式及 ALPN 是否匹配。
4. TCP/443 和 UDP/443 的入站防火墙规则。
5. 服务端配置校验结果及启动日志。
6. DNS 上游是否错误地指向服务器自身的回环地址。

请勿仅为了消除日志中的错误字样就随意更换 REALITY 密钥、SNI 或回落目标。

## 项目地址

* GitHub：https://github.com/kwrum1/shoes-shell
* Shoes 上游：https://github.com/cfal/shoes

## 免责声明

本项目是用于安装和管理 Shoes 服务端的 Shell 工具，不隶属于 Shoes 上游项目。

使用者应自行遵守所在地区的法律法规，并负责服务器安全、密钥保管、证书续期、防火墙配置及服务运维。

本项目按现有实现提供功能，不保证特定网络环境下的连接成功率、传输性能或主动探测表现。
