#!/usr/bin/env bash
# Shoes single-process manager for Ubuntu + systemd.
# TCP/443: VLESS + REALITY + Vision. UDP/443: Shoes' built-in Hysteria2.
# Certificate choices: self-signed local CA, trusted ACME domain certificate, or trusted short-lived IP certificate.
# Current public Shoes config does not expose configurable Hysteria2 masquerade or Salamander obfs.

set -uo pipefail
umask 077

SHOES_REPO="cfal/shoes"
SHOES_BIN="/usr/local/bin/shoes"
CONF_DIR="/etc/shoes"
CONF_FILE="$CONF_DIR/config.yaml"
LINK_FILE="$CONF_DIR/links.txt"
STATE_FILE="$CONF_DIR/manager.env"
CERT_FILE="$CONF_DIR/hy2-cert.pem"
KEY_FILE="$CONF_DIR/hy2-key.pem"
CA_FILE="$CONF_DIR/hy2-ca.pem"
CA_KEY_FILE="$CONF_DIR/hy2-ca-key.pem"
UNIT_FILE="/etc/systemd/system/shoes.service"
RENEW_SCRIPT="/usr/local/sbin/shoes-certbot-renew"
RENEW_UNIT="/etc/systemd/system/shoes-certbot-renew.service"
RENEW_TIMER="/etc/systemd/system/shoes-certbot-renew.timer"
LOCK_FILE="/run/lock/shoes-manager.lock"

# Neon terminal UI (automatically disabled when stdout is not a TTY).
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
    C_CYAN=$'\033[38;5;51m'; C_BLUE=$'\033[38;5;39m'; C_PURPLE=$'\033[38;5;141m'
    C_GREEN=$'\033[38;5;82m'; C_YELLOW=$'\033[38;5;220m'; C_RED=$'\033[38;5;196m'
    C_WHITE=$'\033[97m'; C_LINE=$'\033[38;5;45m'
else
    C_RESET=''; C_BOLD=''; C_DIM=''; C_CYAN=''; C_BLUE=''; C_PURPLE=''
    C_GREEN=''; C_YELLOW=''; C_RED=''; C_WHITE=''; C_LINE=''
fi

say() { printf '%b%s%b\n' "$C_WHITE" "$*" "$C_RESET"; }
ok() { printf '%b✔%b %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '%b⚠%b %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
err() { printf '%b✖ 错误：%s%b\n' "$C_RED" "$*" "$C_RESET" >&2; }
line() { printf '%b━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%b\n' "$C_LINE" "$C_RESET"; }
need_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || { err '请使用 sudo -i 后再运行。'; return 1; }; }

check_platform() {
    [[ -r /etc/os-release ]] || { err '无法识别操作系统。'; return 1; }
    . /etc/os-release
    [[ "${ID:-}" == ubuntu ]] || { err '此脚本仅针对 Ubuntu + systemd。'; return 1; }
    command -v systemctl >/dev/null 2>&1 || { err '未发现 systemctl。'; return 1; }
    [[ -d /run/systemd/system ]] || { err '当前环境没有运行 systemd。'; return 1; }
}

ensure_deps() {
    local need=0 c
    for c in curl jq openssl tar sha256sum timeout flock ss awk sed; do
        command -v "$c" >/dev/null 2>&1 || need=1
    done
    if (( need )); then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update || return 1
        apt-get install -y ca-certificates curl jq openssl tar coreutils util-linux iproute2 || return 1
    fi
    for c in curl jq openssl tar sha256sum timeout flock ss; do
        command -v "$c" >/dev/null 2>&1 || { err "缺少依赖：$c"; return 1; }
    done
}

lock_operation() {
    exec 9>"$LOCK_FILE" || return 1
    flock -n 9 || { err '另一个管理操作正在执行。'; return 1; }
}

new_workdir() {
    WORK_DIR=$(mktemp -d /usr/local/bin/.shoes-manager.XXXXXX) || return 1
    chmod 700 "$WORK_DIR"
}
cleanup_workdir() { [[ -z "${WORK_DIR:-}" || ! -d "$WORK_DIR" ]] || rm -rf -- "$WORK_DIR"; }

check_arch() {
    case "$(uname -m)" in
        x86_64) ARCH=x86_64 ;;
        aarch64|arm64) ARCH=aarch64 ;;
        *) err "不支持的 CPU 架构：$(uname -m)，目前支持 x86_64 / ARM64。"; return 1 ;;
    esac
}

fetch_https() {
    curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
        --connect-timeout 10 --max-time 180 --retry 2 -o "$2" "$1"
}

download_latest_shoes() {
    local release_json asset url digest archive member version
    check_arch || return 1
    release_json="$WORK_DIR/release.json"
    fetch_https "https://api.github.com/repos/${SHOES_REPO}/releases/latest" "$release_json" || { err '读取 Shoes 最新 Release 失败。'; return 1; }
    RELEASE_TAG=$(jq -er '.tag_name | select(test("^v?[0-9]+\\.[0-9]+\\.[0-9]+([.-][A-Za-z0-9.-]+)?$"))' "$release_json") || { err '无法识别 Shoes 最新版本号。'; return 1; }
    asset="shoes-${ARCH}-unknown-linux-gnu.tar.gz"
    url=$(jq -er --arg name "$asset" '.assets[] | select(.name == $name) | .browser_download_url' "$release_json") || {
        err "最新 Release 没有 GNU Linux 资产：$asset"; return 1;
    }
    [[ "$url" == "https://github.com/${SHOES_REPO}/releases/download/${RELEASE_TAG}/${asset}" ]] || { err 'Release 下载地址不符合预期。'; return 1; }
    digest=$(jq -er --arg name "$asset" '.assets[] | select(.name == $name) | .digest // empty' "$release_json") || digest=''
    [[ "$digest" =~ ^sha256:[0-9a-fA-F]{64}$ ]] || { err '上游没有提供有效 SHA-256 摘要，拒绝安装。'; return 1; }
    archive="$WORK_DIR/$asset"
    say "下载 Shoes ${RELEASE_TAG}（${ARCH}/GNU）..."
    fetch_https "$url" "$archive" || return 1
    printf '%s  %s\n' "${digest#sha256:}" "$archive" | sha256sum -c - >/dev/null || { err 'Shoes 压缩包 SHA-256 校验失败。'; return 1; }
    tar -tzf "$archive" > "$WORK_DIR/members" || { err 'Shoes 压缩包损坏。'; return 1; }
    member=$(grep -Ex '(\./)?shoes' "$WORK_DIR/members" | head -n 1) || { err '压缩包里没有预期的 shoes 可执行文件。'; return 1; }
    tar -xOzf "$archive" "$member" > "$WORK_DIR/shoes.new" || return 1
    chmod 755 "$WORK_DIR/shoes.new" || return 1
    version=$(timeout 15 "$WORK_DIR/shoes.new" --version 2>/dev/null) || { err '下载的 Shoes 无法执行。'; return 1; }
    [[ "$version" == "shoes ${RELEASE_TAG#v}" ]] || { err "版本校验不匹配：$version / $RELEASE_TAG"; return 1; }
    timeout 15 "$WORK_DIR/shoes.new" generate-reality-keypair >/dev/null 2>&1 || { err 'Shoes REALITY 密钥生成功能自检失败。'; return 1; }
    say "Shoes 二进制校验通过：$version"
}

valid_domain() {
    [[ ${#1} -le 253 && "$1" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]
}
valid_ipv4() {
    local ip="$1" part
    local -a parts
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    IFS=. read -r -a parts <<< "$ip"
    for part in "${parts[@]}"; do ((10#$part <= 255)) || return 1; done
    [[ "$ip" != 0.0.0.0 && "$ip" != 127.* && "$ip" != 169.254.* ]]
}
is_ipv4() { valid_ipv4 "$1"; }

valid_connect_host() {
    local h="$1"
    [[ "$h" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && {
        local IFS=. p; read -r -a _octets <<< "$h"
        for p in "${_octets[@]}"; do ((10#$p <= 255)) || return 1; done
        return 0
    }
    valid_domain "$h"
}
valid_dest() {
    local h p
    [[ "$1" == *:* ]] || return 1
    h=${1%:*}; p=${1##*:}
    valid_domain "$h" || return 1
    [[ "$p" =~ ^[0-9]{1,5}$ ]] && ((10#$p >= 1 && 10#$p <= 65535))
}

get_default_public_host() {
    SERVER_IPV4=$(curl -4fsSL --connect-timeout 5 --max-time 10 https://api.ipify.org 2>/dev/null | tr -d '\r\n') || SERVER_IPV4=''
    valid_connect_host "${SERVER_IPV4:-}" || SERVER_IPV4=''
    PUBLIC_HOST="$SERVER_IPV4"
}


prompt_initial_settings() {
    local ans default_cert_domain='' cert_kind_choice
    get_default_public_host
    if [[ -n "$PUBLIC_HOST" ]]; then
        read -r -p "客户端连接地址（公网 IPv4/域名，默认 ${PUBLIC_HOST}）: " ans || return 1
        [[ -n "$ans" ]] && PUBLIC_HOST="$ans"
    else
        read -r -p '无法自动获取公网 IPv4，请输入客户端连接用公网 IPv4 或域名: ' PUBLIC_HOST || return 1
    fi
    valid_connect_host "$PUBLIC_HOST" || { err '连接地址无效；请输入公网 IPv4 或普通域名（不带端口）。'; return 1; }

    read -r -p 'REALITY 伪装 SNI（默认 www.microsoft.com）: ' ans || return 1
    SNI=${ans:-www.microsoft.com}
    valid_domain "$SNI" || { err 'REALITY SNI 必须是有效域名，不要带协议、端口或路径。'; return 1; }

    read -r -p "REALITY 回落目标（默认 ${SNI}:443）: " ans || return 1
    DEST=${ans:-${SNI}:443}
    valid_dest "$DEST" || { err '回落目标格式应为域名:端口，例如 www.microsoft.com:443。'; return 1; }

    printf '\n%bHysteria2 证书方案%b\n' "$C_CYAN" "$C_RESET"
    printf '  %b1%b) Let’s Encrypt 可信证书（支持域名或公网 IPv4）\n' "$C_GREEN" "$C_RESET"
    printf '  %b2%b) 生成自签根 CA + 服务器证书（可绑定 IP/域名；客户端默认跳过验证）\n' "$C_YELLOW" "$C_RESET"
    read -r -p '请选择 [2]: ' ans || return 1
    case "$ans" in
        1)
            CERT_MODE=letsencrypt
            printf '\n  1) 域名证书（默认，90 天标准证书）\n  2) 公网 IP 证书（约 160 小时有效，自动续期）\n'
            read -r -p '证书标识类型 [1]: ' cert_kind_choice || return 1
            case "$cert_kind_choice" in
                2)
                    CERT_KIND=ip
                    local default_ip="${SERVER_IPV4:-}"
                    read -r -p "证书公网 IPv4${default_ip:+（默认 ${default_ip}）}: " ans || return 1
                    CERT_DOMAIN=${ans:-$default_ip}
                    valid_ipv4 "$CERT_DOMAIN" || { err 'IP 证书只能填写有效 IPv4。'; return 1; }
                    [[ "$CERT_DOMAIN" == "$default_ip" ]] || { warn '证书 IP 与自动检测到的服务器公网 IPv4 不同；请确认此 IP 确实绑定在本机。'; }
                    PUBLIC_HOST="$CERT_DOMAIN"
                    HY2_SNI=''
                    ;;
                1|'')
                    CERT_KIND=domain
                    valid_domain "$PUBLIC_HOST" && default_cert_domain="$PUBLIC_HOST"
                    read -r -p "证书域名（A 记录需指向本机公网 IPv4${default_cert_domain:+，默认 ${default_cert_domain}}）: " ans || return 1
                    CERT_DOMAIN=${ans:-$default_cert_domain}
                    valid_domain "$CERT_DOMAIN" || { err '证书域名无效。'; return 1; }
                    HY2_SNI="$CERT_DOMAIN"
                    ;;
                *) err '证书标识类型无效。'; return 1 ;;
            esac
            read -r -p '证书联系邮箱（用于 ACME 账户及提醒）: ' CERT_EMAIL || return 1
            [[ "$CERT_EMAIL" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]] || { err '邮箱格式无效。'; return 1; }
            ;;
        2|'')
            CERT_MODE=selfsigned_ca; CERT_DOMAIN=''; CERT_EMAIL=''; CERT_KIND=host
            if valid_domain "$PUBLIC_HOST"; then HY2_SNI="$PUBLIC_HOST"; else HY2_SNI="$SNI"; fi
            ;;
        *) err '证书方案无效。'; return 1 ;;
    esac
}



load_state() {
    [[ -s "$STATE_FILE" ]] || { err '没有管理状态文件，安装不完整或配置已被删除。'; return 1; }
    PUBLIC_HOST=$(sed -n 's/^PUBLIC_HOST=//p' "$STATE_FILE" | head -n 1)
    SNI=$(sed -n 's/^SNI=//p' "$STATE_FILE" | head -n 1)
    DEST=$(sed -n 's/^DEST=//p' "$STATE_FILE" | head -n 1)
    HY2_SNI=$(sed -n 's/^HY2_SNI=//p' "$STATE_FILE" | head -n 1)
    CERT_MODE=$(sed -n 's/^CERT_MODE=//p' "$STATE_FILE" | head -n 1)
    CERT_DOMAIN=$(sed -n 's/^CERT_DOMAIN=//p' "$STATE_FILE" | head -n 1)
    CERT_EMAIL=$(sed -n 's/^CERT_EMAIL=//p' "$STATE_FILE" | head -n 1)
    CERT_KIND=$(sed -n 's/^CERT_KIND=//p' "$STATE_FILE" | head -n 1)
    # Backward compatibility with previous manager state files.
    [[ -n "$CERT_MODE" ]] || CERT_MODE=selfsigned
    if [[ -z "$HY2_SNI" && "$CERT_MODE" != letsencrypt ]]; then HY2_SNI="$SNI"; fi
    [[ -n "$CERT_KIND" ]] || { if [[ "$CERT_MODE" == letsencrypt ]]; then CERT_KIND=domain; else CERT_KIND=host; fi; }
    valid_connect_host "$PUBLIC_HOST" && valid_domain "$SNI" && valid_dest "$DEST" || { err '管理状态文件无效。'; return 1; }
    case "$CERT_MODE" in
        selfsigned|selfsigned_ca)
            valid_domain "$HY2_SNI" || { err '自签证书 SNI 状态无效。'; return 1; }
            ;;
        letsencrypt)
            [[ "$CERT_EMAIL" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]] || { err 'Let’s Encrypt 状态邮箱无效。'; return 1; }
            case "$CERT_KIND" in
                domain) valid_domain "$CERT_DOMAIN" && valid_domain "$HY2_SNI" || { err 'Let’s Encrypt 域名证书状态无效。'; return 1; } ;;
                ip) valid_ipv4 "$CERT_DOMAIN" && [[ -z "$HY2_SNI" && "$PUBLIC_HOST" == "$CERT_DOMAIN" ]] || { err 'Let’s Encrypt IP 证书状态无效。'; return 1; } ;;
                *) err 'Let’s Encrypt 证书类型无效。'; return 1 ;;
            esac
            ;;
        *) err '证书模式无效。'; return 1 ;;
    esac
}


is_installed() { [[ -x "$SHOES_BIN" && -s "$CONF_FILE" && -s "$STATE_FILE" && -f "$UNIT_FILE" ]]; }
is_active() { systemctl is-active --quiet shoes; }

ports_are_free_for_first_install() {
    local tcp udp
    tcp=$(ss -H -lnt 'sport = :443' 2>/dev/null) || { err '检查 TCP/443 端口失败。'; return 1; }
    udp=$(ss -H -lnu 'sport = :443' 2>/dev/null) || { err '检查 UDP/443 端口失败。'; return 1; }
    if [[ -n "$tcp" || -n "$udp" ]]; then
        err 'TCP/443 或 UDP/443 已被其他服务占用。请先确认并释放端口；本脚本不会自动停掉 nginx、旧 Xray 等服务。'
        [[ -z "$tcp" ]] || printf 'TCP/443：\n%s\n' "$tcp" >&2
        [[ -z "$udp" ]] || printf 'UDP/443：\n%s\n' "$udp" >&2
        return 1
    fi
}

make_credentials() {
    local pair
    UUID=$(cat /proc/sys/kernel/random/uuid) || return 1
    SHORT_ID=$(openssl rand -hex 8) || return 1
    HY2_PASSWORD=$(openssl rand -hex 24) || return 1
    pair=$(timeout 15 "$1" generate-reality-keypair) || return 1
    REALITY_PRIVATE=$(printf '%s\n' "$pair" | awk '/^REALITY private key: / {print $4; exit}')
    REALITY_PUBLIC=$(printf '%s\n' "$pair" | awk '/^REALITY public key: / {print $4; exit}')
    [[ "$UUID" =~ ^[a-f0-9-]{36}$ && "$SHORT_ID" =~ ^[a-f0-9]{16}$ && \
       "$HY2_PASSWORD" =~ ^[a-f0-9]{48}$ && "$REALITY_PRIVATE" =~ ^[A-Za-z0-9_-]{43}$ && \
       "$REALITY_PUBLIC" =~ ^[A-Za-z0-9_-]{43}$ ]] || { err '生成代理凭据失败。'; return 1; }
}

make_self_signed_cert() {
    local cert="$1" key="$2" ca_cert="$WORK_DIR/hy2-ca.pem" ca_key="$WORK_DIR/hy2-ca-key.pem"
    local csr="$WORK_DIR/hy2-server.csr" ext="$WORK_DIR/hy2-server.ext" san_csv
    local -a sans=()
    if is_ipv4 "$PUBLIC_HOST"; then sans+=("IP:${PUBLIC_HOST}"); else sans+=("DNS:${PUBLIC_HOST}"); fi
    if [[ -n "$HY2_SNI" && "$HY2_SNI" != "$PUBLIC_HOST" ]] && valid_domain "$HY2_SNI"; then
        sans+=("DNS:${HY2_SNI}")
    fi
    san_csv=$(IFS=,; printf '%s' "${sans[*]}")

    # Generate a self-signed root CA, then sign a server leaf with an IP/DNS SAN.
    openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:prime256v1 -out "$ca_key" >/dev/null 2>&1 || { err '生成自签 CA 私钥失败。'; return 1; }
    openssl req -x509 -new -key "$ca_key" -sha256 -days 3650 -out "$ca_cert" \
        -subj '/CN=Shoes Hysteria2 Local CA' \
        -addext 'basicConstraints=critical,CA:TRUE' \
        -addext 'keyUsage=critical,keyCertSign,cRLSign' \
        -addext 'subjectKeyIdentifier=hash' >/dev/null 2>&1 || { err '生成自签 CA 证书失败。'; return 1; }
    openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
        -keyout "$key" -out "$csr" -subj "/CN=${HY2_SNI:-$PUBLIC_HOST}" >/dev/null 2>&1 || { err '生成 Hysteria2 服务器证书请求失败。'; return 1; }
    cat > "$ext" <<EOF2
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=${san_csv}
subjectKeyIdentifier=hash
authorityKeyIdentifier=keyid,issuer
EOF2
    openssl x509 -req -in "$csr" -CA "$ca_cert" -CAkey "$ca_key" -CAcreateserial \
        -out "$cert" -days 825 -sha256 -extfile "$ext" >/dev/null 2>&1 || { err '生成 CA 签发的 Hysteria2 服务器证书失败。'; return 1; }
    openssl verify -CAfile "$ca_cert" "$cert" >/dev/null 2>&1 || { err '自签 CA 证书链验证失败。'; return 1; }
    if is_ipv4 "$PUBLIC_HOST"; then
        openssl x509 -in "$cert" -noout -checkip "$PUBLIC_HOST" >/dev/null 2>&1 || { err '自签证书 IP SAN 校验失败。'; return 1; }
    else
        openssl x509 -in "$cert" -noout -checkhost "$PUBLIC_HOST" >/dev/null 2>&1 || { err '自签证书域名 SAN 校验失败。'; return 1; }
    fi
    chmod 600 "$cert" "$key" "$ca_cert" "$ca_key"
    ok '已生成自签根 CA，并签发带 IP/域名 SAN 的 Hysteria2 服务器证书。'
}



certbot_version_supported() {
    local binary="$1" ver major minor patch
    ver=$("$binary" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1) || ver=''
    [[ -n "$ver" ]] || return 1
    IFS=. read -r major minor patch <<< "$ver"
    (( major > 5 || (major == 5 && minor >= 3) ))
}

ensure_certbot_for_mode() {
    local current=''
    export DEBIAN_FRONTEND=noninteractive
    if ! command -v certbot >/dev/null 2>&1; then
        apt-get update && apt-get install -y certbot || { err 'Certbot 安装失败。'; return 1; }
    fi
    CERTBOT_BIN=$(command -v certbot)
    if [[ "$CERT_KIND" == ip ]] && ! certbot_version_supported "$CERTBOT_BIN"; then
        warn '当前 Certbot 版本不支持公网 IP 证书，尝试安装官方 Snap 版 Certbot（需要 snapd）。'
        if ! command -v snap >/dev/null 2>&1; then
            apt-get update && apt-get install -y snapd || { err '安装 snapd 失败，无法获得支持 IP 证书的 Certbot。'; return 1; }
            systemctl enable --now snapd.socket >/dev/null 2>&1 || true
        fi
        if [[ ! -x /snap/bin/certbot ]]; then
            snap install certbot --classic || { err '官方 Snap Certbot 安装失败。'; return 1; }
        elif ! certbot_version_supported /snap/bin/certbot; then
            snap refresh certbot || { err '刷新官方 Snap Certbot 失败。'; return 1; }
        fi
        CERTBOT_BIN=/snap/bin/certbot
        certbot_version_supported "$CERTBOT_BIN" || { err 'Certbot 版本仍低于 IP 证书所需的 5.3.0。'; return 1; }
    fi
    current=$("$CERTBOT_BIN" --version 2>/dev/null || true)
    say "使用 ${current:-Certbot} (${CERTBOT_BIN})"
}

obtain_lets_encrypt_cert() {
    local dns_ips cert_dir busy
    command -v getent >/dev/null 2>&1 || { err '缺少 getent，无法验证域名解析。'; return 1; }
    [[ -n "${SERVER_IPV4:-}" ]] || SERVER_IPV4=$(curl -4fsSL --connect-timeout 5 --max-time 10 https://api.ipify.org 2>/dev/null | tr -d '\r\n') || SERVER_IPV4=''
    valid_ipv4 "${SERVER_IPV4:-}" || { err '无法确认服务器公网 IPv4，请检查出站网络。'; return 1; }

    if [[ "$CERT_KIND" == domain ]]; then
        dns_ips=$(getent ahostsv4 "$CERT_DOMAIN" 2>/dev/null | awk '{print $1}' | sort -u || true)
        printf '%s\n' "$dns_ips" | grep -Fxq "$SERVER_IPV4" || {
            err "域名 ${CERT_DOMAIN} 的 A 记录尚未指向本机公网 IPv4 ${SERVER_IPV4}。当前解析：${dns_ips:-无}"
            err '请先配置 DNS A 记录并等待生效。'
            return 1
        }
    else
        valid_ipv4 "$CERT_DOMAIN" || { err 'IP 证书类型要求有效公网 IPv4。'; return 1; }
        [[ "$CERT_DOMAIN" == "$SERVER_IPV4" ]] || { err "IP 证书地址 ${CERT_DOMAIN} 与本机出口检测地址 ${SERVER_IPV4} 不一致。"; return 1; }
    fi
    busy=$(ss -H -lnt 'sport = :80' 2>/dev/null) || { err '无法检测 TCP/80 端口。'; return 1; }
    [[ -z "$busy" ]] || { err "TCP/80 已被占用，Certbot standalone 无法完成验证：$busy"; return 1; }
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
        ufw allow 80/tcp || { err 'UFW 未能放行 TCP/80，无法申请证书。'; return 1; }
    fi
    warn '请确认云平台安全组也放行 TCP/80；HTTP-01 签发与后续续期都需要它。'
    ensure_certbot_for_mode || return 1
    say '通过 ACME HTTP-01 申请/复用可信证书...'
    if [[ "$CERT_KIND" == ip ]]; then
        "$CERTBOT_BIN" certonly --standalone --preferred-challenges http --preferred-profile shortlived \
            --ip-address "$CERT_DOMAIN" --non-interactive --agree-tos --email "$CERT_EMAIL" \
            --cert-name "$CERT_DOMAIN" --keep-until-expiring || {
            err 'IP 证书申请失败。它要求 Certbot >=5.3.0、TCP/80 公网可达，且有效期只有约 160 小时。'; return 1;
        }
    else
        "$CERTBOT_BIN" certonly --standalone --preferred-challenges http --non-interactive --agree-tos \
            --email "$CERT_EMAIL" --cert-name "$CERT_DOMAIN" --keep-until-expiring -d "$CERT_DOMAIN" || {
            err '域名证书申请失败。确认 DNS 正确、TCP/80 的云安全组和防火墙已放行，然后重试。'; return 1;
        }
    fi
    cert_dir="/etc/letsencrypt/live/${CERT_DOMAIN}"
    [[ -s "$cert_dir/fullchain.pem" && -s "$cert_dir/privkey.pem" ]] || { err 'Certbot 没有生成预期的证书文件。'; return 1; }
    if [[ "$CERT_KIND" == ip ]]; then
        openssl x509 -in "$cert_dir/fullchain.pem" -noout -checkip "$CERT_DOMAIN" >/dev/null 2>&1 || { err '签发证书的 IP SAN 校验失败。'; return 1; }
    else
        openssl x509 -in "$cert_dir/fullchain.pem" -noout -checkhost "$CERT_DOMAIN" >/dev/null 2>&1 || { err '签发证书的域名校验失败。'; return 1; }
    fi
    openssl x509 -in "$cert_dir/fullchain.pem" -noout -checkend 86400 >/dev/null 2>&1 || { err '签发的证书将在 24 小时内过期。'; return 1; }
    install -m 600 "$cert_dir/fullchain.pem" "$WORK_DIR/hy2-cert.pem" || return 1
    install -m 600 "$cert_dir/privkey.pem" "$WORK_DIR/hy2-key.pem" || return 1
    ok "可信证书已签发/复用：${CERT_DOMAIN}"
}


prepare_certificate() {
    if [[ "$CERT_MODE" == letsencrypt ]]; then
        obtain_lets_encrypt_cert
    else
        make_self_signed_cert "$WORK_DIR/hy2-cert.pem" "$WORK_DIR/hy2-key.pem"
    fi
}

install_certbot_deploy_hook() {
    [[ "$CERT_MODE" == letsencrypt ]] || return 0
    local hook_dir=/etc/letsencrypt/renewal-hooks/deploy hook
    hook="$hook_dir/shoes-cert-renew.sh"
    install -d -m 755 "$hook_dir" || return 1
    cat > "$WORK_DIR/shoes-cert-renew.sh" <<EOF2
#!/usr/bin/env bash
set -euo pipefail
EXPECTED_LINEAGE='/etc/letsencrypt/live/${CERT_DOMAIN}'
[[ "\${RENEWED_LINEAGE:-}" == "\$EXPECTED_LINEAGE" ]] || exit 0
install -m 600 "\$RENEWED_LINEAGE/fullchain.pem" '${CERT_FILE}.renewing'
install -m 600 "\$RENEWED_LINEAGE/privkey.pem" '${KEY_FILE}.renewing'
mv -f '${CERT_FILE}.renewing' '${CERT_FILE}'
mv -f '${KEY_FILE}.renewing' '${KEY_FILE}'
systemctl restart shoes
EOF2
    install -m 700 "$WORK_DIR/shoes-cert-renew.sh" "$hook" || return 1

    # Use a manager-owned renewal timer, so both apt- and snap-installed Certbot work.
    cat > "$WORK_DIR/shoes-certbot-renew" <<'EOF2'
#!/usr/bin/env bash
set -euo pipefail
if [[ -x /snap/bin/certbot ]]; then
  exec /snap/bin/certbot renew --quiet
elif [[ -x /usr/bin/certbot ]]; then
  exec /usr/bin/certbot renew --quiet
else
  exit 127
fi
EOF2
    chmod 700 "$WORK_DIR/shoes-certbot-renew"
    install -m 700 "$WORK_DIR/shoes-certbot-renew" "$RENEW_SCRIPT" || return 1
    cat > "$WORK_DIR/shoes-certbot-renew.service" <<EOF2
[Unit]
Description=Renew Shoes Hysteria2 ACME certificate
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${RENEW_SCRIPT}
EOF2
    cat > "$WORK_DIR/shoes-certbot-renew.timer" <<'EOF2'
[Unit]
Description=Periodic ACME renewal check for Shoes Hysteria2

[Timer]
OnCalendar=*-*-* 00,06,12,18:00:00
Persistent=true
RandomizedDelaySec=300

[Install]
WantedBy=timers.target
EOF2
    install -m 644 "$WORK_DIR/shoes-certbot-renew.service" "$RENEW_UNIT" || return 1
    install -m 644 "$WORK_DIR/shoes-certbot-renew.timer" "$RENEW_TIMER" || return 1
    systemctl daemon-reload || return 1
    systemctl enable --now shoes-certbot-renew.timer >/dev/null 2>&1 || { warn '自动续期定时器启用失败，请检查 systemctl status shoes-certbot-renew.timer。'; return 1; }
    ok '已配置 ACME 自动续期检查（每 6 小时检查一次；证书需要续期时再执行续签）。'
}

remove_certbot_deploy_hook() {
    systemctl disable --now shoes-certbot-renew.timer >/dev/null 2>&1 || true
    rm -f /etc/letsencrypt/renewal-hooks/deploy/shoes-cert-renew.sh "$RENEW_SCRIPT" "$RENEW_UNIT" "$RENEW_TIMER"
    systemctl daemon-reload >/dev/null 2>&1 || true
}


write_config() {
    local out="$1" cert="$2" key="$3"
    cat > "$out" <<EOF2
- address: "0.0.0.0:443"
  protocol:
    type: tls
    reality_targets:
      "${SNI}":
        private_key: "${REALITY_PRIVATE}"
        short_ids: ["${SHORT_ID}"]
        dest: "${DEST}"
        vision: true
        protocol:
          type: vless
          user_id: "${UUID}"
          udp_enabled: true
- address: "0.0.0.0:443"
  transport: quic
  quic_settings:
    cert: "${cert}"
    key: "${key}"
    alpn_protocols: ["h3"]
  protocol:
    type: hysteria2
    password: "${HY2_PASSWORD}"
    udp_enabled: true
EOF2
    chmod 600 "$out"
}

write_links() {
    local out="$1" link_host="$PUBLIC_HOST" hy2_security='' hy2_sni_param=''
    if [[ "$PUBLIC_HOST" == *:* ]]; then link_host="[$PUBLIC_HOST]"; fi
    if [[ "$CERT_MODE" == selfsigned || "$CERT_MODE" == selfsigned_ca ]]; then hy2_security='&insecure=1'; fi
    if [[ -n "$HY2_SNI" ]]; then hy2_sni_param="&sni=${HY2_SNI}"; fi
    cat > "$out" <<EOF2
# VLESS + REALITY + Vision (TCP/443)
vless://${UUID}@${link_host}:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&pbk=${REALITY_PUBLIC}&sid=${SHORT_ID}&type=tcp#Shoes-Reality-Vision

# Hysteria2 (UDP/443); TLS mode: ${CERT_MODE}${CERT_KIND:+/${CERT_KIND}}
hysteria2://${HY2_PASSWORD}@${link_host}:443/?alpn=h3${hy2_sni_param}${hy2_security}#Shoes-Hysteria2-UDP
EOF2
    chmod 600 "$out"
}


write_state() {
    local out="$1"
    printf 'PUBLIC_HOST=%s\nSNI=%s\nDEST=%s\nHY2_SNI=%s\nCERT_MODE=%s\nCERT_KIND=%s\nCERT_DOMAIN=%s\nCERT_EMAIL=%s\n' \
        "$PUBLIC_HOST" "$SNI" "$DEST" "$HY2_SNI" "$CERT_MODE" "$CERT_KIND" "$CERT_DOMAIN" "$CERT_EMAIL" > "$out"
    chmod 600 "$out"
}


validate_config() {
    local bin="$1" cfg="$2" log="$WORK_DIR/dry-run.log"
    if ! timeout 30 "$bin" --dry-run "$cfg" >"$log" 2>&1; then
        err 'Shoes 配置检查失败：'
        cat "$log" >&2
        return 1
    fi
}

write_unit() {
    cat > "$WORK_DIR/shoes.service" <<EOF2
[Unit]
Description=Shoes Proxy Server (VLESS Reality Vision + Hysteria2)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
UMask=0077
WorkingDirectory=${CONF_DIR}
ExecStartPre=${SHOES_BIN} --dry-run ${CONF_FILE}
ExecStart=${SHOES_BIN} ${CONF_FILE}
Restart=on-failure
RestartSec=2
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF2
    chmod 644 "$WORK_DIR/shoes.service"
}

open_ufw_ports_if_active() {
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
        ufw allow 443/tcp || return 1
        ufw allow 443/udp || return 1
        if [[ "$CERT_MODE" == letsencrypt ]]; then ufw allow 80/tcp || return 1; fi
        say '已在 UFW 放行所需端口。云平台安全组仍需单独放行。'
    else
        say '请确认云平台安全组/上游防火墙放行 TCP/443 与 UDP/443。'
    fi
    if [[ "$CERT_MODE" == letsencrypt ]]; then
        warn 'Let’s Encrypt 自动续期需要 TCP/80 可从公网访问；请在云安全组中放行 TCP/80。'
    fi
}


show_links() {
    [[ -s "$LINK_FILE" ]] || { err '尚无链接，请先执行安装。'; return 1; }
    line
    cat "$LINK_FILE"
    if [[ -s "$CA_FILE" ]]; then
        say ''
        say "自签根 CA 公共证书：${CA_FILE}"
        say '客户端若支持自定义 CA，可导入此文件并移除 Hysteria2 链接中的 insecure=1；否则保持 insecure=1 才能直接连接。'
    fi
    line
}

install_fresh() {
    local failed=0
    ensure_deps || return 1
    lock_operation || return 1
    new_workdir || return 1
    download_latest_shoes || { cleanup_workdir; return 1; }
    prompt_initial_settings || { cleanup_workdir; return 1; }
    ports_are_free_for_first_install || { cleanup_workdir; return 1; }
    make_credentials "$WORK_DIR/shoes.new" || { cleanup_workdir; return 1; }
    prepare_certificate || { cleanup_workdir; return 1; }
    write_config "$WORK_DIR/config.stage.yaml" "$WORK_DIR/hy2-cert.pem" "$WORK_DIR/hy2-key.pem"
    validate_config "$WORK_DIR/shoes.new" "$WORK_DIR/config.stage.yaml" || { cleanup_workdir; return 1; }

    install -d -m 700 "$CONF_DIR" || { cleanup_workdir; return 1; }
    install -m 600 "$WORK_DIR/hy2-cert.pem" "$CERT_FILE" || failed=1
    install -m 600 "$WORK_DIR/hy2-key.pem" "$KEY_FILE" || failed=1
    if [[ -s "$WORK_DIR/hy2-ca.pem" && -s "$WORK_DIR/hy2-ca-key.pem" ]]; then
        install -m 600 "$WORK_DIR/hy2-ca.pem" "$CA_FILE" || failed=1
        install -m 600 "$WORK_DIR/hy2-ca-key.pem" "$CA_KEY_FILE" || failed=1
    fi
    if (( failed )); then rm -rf -- "$CONF_DIR"; cleanup_workdir; return 1; fi
    write_config "$WORK_DIR/config.final.yaml" "$CERT_FILE" "$KEY_FILE"
    validate_config "$WORK_DIR/shoes.new" "$WORK_DIR/config.final.yaml" || { rm -rf -- "$CONF_DIR"; cleanup_workdir; return 1; }
    write_links "$WORK_DIR/links.txt"
    write_state "$WORK_DIR/manager.env"
    install -m 600 "$WORK_DIR/config.final.yaml" "$CONF_FILE" || failed=1
    install -m 600 "$WORK_DIR/links.txt" "$LINK_FILE" || failed=1
    install -m 600 "$WORK_DIR/manager.env" "$STATE_FILE" || failed=1
    install -m 755 "$WORK_DIR/shoes.new" "$SHOES_BIN" || failed=1
    write_unit || failed=1
    install -m 644 "$WORK_DIR/shoes.service" "$UNIT_FILE" || failed=1
    if (( failed )); then
        rm -rf -- "$CONF_DIR"; rm -f -- "$SHOES_BIN" "$UNIT_FILE"; cleanup_workdir; return 1
    fi
    systemctl daemon-reload || failed=1
    systemctl enable shoes || failed=1
    if (( ! failed )); then systemctl start shoes || failed=1; fi
    if (( ! failed )); then systemctl is-active --quiet shoes || failed=1; fi
    if (( failed )); then
        err '首次启动失败，正在清理本次新安装。'
        systemctl stop shoes >/dev/null 2>&1 || true
        systemctl disable shoes >/dev/null 2>&1 || true
        rm -f -- "$SHOES_BIN" "$UNIT_FILE"
        rm -rf -- "$CONF_DIR"
        systemctl daemon-reload >/dev/null 2>&1 || true
        journalctl -u shoes -n 40 --no-pager >&2 2>/dev/null || true
        cleanup_workdir
        return 1
    fi
    install_certbot_deploy_hook || warn '自动续期钩子安装失败，请检查 /etc/letsencrypt/renewal-hooks/deploy。'
    open_ufw_ports_if_active || warn '自动配置 UFW 失败，请检查防火墙。'
    say ''
    line
    printf '%b%b  SHOES CORE · INSTALLED%b\n' "$C_BOLD" "$C_GREEN" "$C_RESET"
    say "  Shoes 版本：${RELEASE_TAG}"
    say '  VLESS + REALITY + Vision  : TCP/443'
    say '  Hysteria2 + HTTP/3        : UDP/443'
    say "  Hysteria2 证书模式       : ${CERT_MODE}${CERT_KIND:+/${CERT_KIND}}"
    [[ ! -s "$CA_FILE" ]] || say "  自签根 CA                 : ${CA_FILE}"
    line
    say '以下是新链接，请立即复制保存：'
    cat "$LINK_FILE"
    say ''
    warn '可信证书只解决证书验证问题，不会自动增加 Hysteria2 主动探测伪装。'
    warn 'Shoes 当前公开版未提供可配置的 Hysteria2 masquerade 回落；仅使用 Shoes 无法伪装成真实 HTTP/3 网站。'
    cleanup_workdir
}


update_existing() {
    local was_active=0 failed=0
    ensure_deps || return 1
    lock_operation || return 1
    new_workdir || return 1
    if is_active; then was_active=1; fi
    download_latest_shoes || { cleanup_workdir; return 1; }
    validate_config "$WORK_DIR/shoes.new" "$CONF_FILE" || { cleanup_workdir; return 1; }
    cp -p "$SHOES_BIN" "$WORK_DIR/shoes.old" || { cleanup_workdir; return 1; }
    install -m 755 "$WORK_DIR/shoes.new" "${SHOES_BIN}.new" || { cleanup_workdir; return 1; }
    mv -f "${SHOES_BIN}.new" "$SHOES_BIN" || { cleanup_workdir; return 1; }
    if (( was_active )); then
        systemctl restart shoes || failed=1
    else
        systemctl start shoes || failed=1
    fi
    if (( ! failed )); then systemctl is-active --quiet shoes || failed=1; fi
    if (( failed )); then
        err '更新后的 Shoes 启动失败，恢复旧二进制。'
        install -m 755 "$WORK_DIR/shoes.old" "$SHOES_BIN" || { err '旧二进制恢复失败，请从备份恢复。'; cleanup_workdir; return 1; }
        systemctl restart shoes >/dev/null 2>&1 || true
        journalctl -u shoes -n 40 --no-pager >&2 2>/dev/null || true
        cleanup_workdir
        return 1
    fi
    say "Shoes 已更新到 ${RELEASE_TAG}；现有 UUID、REALITY 密钥、HY2 密码和链接均保留。"
    cleanup_workdir
}

install_or_update() {
    if is_installed; then update_existing; else
        if [[ -e "$SHOES_BIN" || -e "$CONF_DIR" || -e "$UNIT_FILE" ]]; then
            err '发现残留或不完整安装。为避免误删配置，请先检查 /etc/shoes 与 shoes.service。'
            return 1
        fi
        install_fresh
    fi
}

rotate_links() {
    local failed=0 was_active=0 cert_choice default_domain=''
    is_installed || { err '请先执行菜单 1 安装 Shoes。'; return 1; }
    ensure_deps || return 1
    lock_operation || return 1
    new_workdir || return 1
    load_state || { cleanup_workdir; return 1; }
    if is_active; then was_active=1; fi

    # Backups make credential rotation transactional.
    mkdir -p "$WORK_DIR/backup" || { cleanup_workdir; return 1; }
    for f in "$CONF_FILE" "$LINK_FILE" "$STATE_FILE" "$CERT_FILE" "$KEY_FILE" "$CA_FILE" "$CA_KEY_FILE"; do
        [[ ! -e "$f" ]] || cp -p "$f" "$WORK_DIR/backup/$(basename "$f")" || { cleanup_workdir; return 1; }
    done

    printf '\n当前 Hysteria2 证书模式：%s/%s\n' "$CERT_MODE" "${CERT_KIND:-unknown}"
    printf '  0) 保持当前证书设置（默认）\n'
    printf '  1) Let’s Encrypt 可信证书（域名或公网 IPv4）\n'
    printf '  2) 重新生成自签根 CA + IP/域名 SAN 服务器证书\n'
    read -r -p '证书设置 [0]: ' cert_choice || { cleanup_workdir; return 1; }
    case "$cert_choice" in
        1)
            CERT_MODE=letsencrypt
            printf '  1) 域名证书\n  2) 公网 IPv4 证书（约 160 小时有效，自动续期）\n'
            read -r -p '证书标识类型 [1]: ' cert_kind_choice || { cleanup_workdir; return 1; }
            case "$cert_kind_choice" in
                2)
                    CERT_KIND=ip
                    SERVER_IPV4=$(curl -4fsSL --connect-timeout 5 --max-time 10 https://api.ipify.org 2>/dev/null | tr -d '\r\n') || SERVER_IPV4=''
                    read -r -p "证书公网 IPv4${SERVER_IPV4:+（默认 ${SERVER_IPV4}）}: " ans || { cleanup_workdir; return 1; }
                    CERT_DOMAIN=${ans:-$SERVER_IPV4}
                    valid_ipv4 "$CERT_DOMAIN" || { err 'IP 证书只能填写有效 IPv4。'; cleanup_workdir; return 1; }
                    PUBLIC_HOST="$CERT_DOMAIN"; HY2_SNI=''
                    ;;
                1|'')
                    CERT_KIND=domain
                    valid_domain "$PUBLIC_HOST" && default_domain="$PUBLIC_HOST"
                    valid_domain "$CERT_DOMAIN" && default_domain="$CERT_DOMAIN"
                    read -r -p "证书域名（A 记录需指向本机公网 IPv4${default_domain:+，默认 ${default_domain}}）: " ans || { cleanup_workdir; return 1; }
                    CERT_DOMAIN=${ans:-$default_domain}
                    valid_domain "$CERT_DOMAIN" || { err '证书域名无效。'; cleanup_workdir; return 1; }
                    HY2_SNI="$CERT_DOMAIN"
                    ;;
                *) err '证书标识类型无效。'; cleanup_workdir; return 1 ;;
            esac
            read -r -p "证书联系邮箱${CERT_EMAIL:+（默认 ${CERT_EMAIL}）}: " ans || { cleanup_workdir; return 1; }
            CERT_EMAIL=${ans:-$CERT_EMAIL}
            [[ "$CERT_EMAIL" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]] || { err '邮箱格式无效。'; cleanup_workdir; return 1; }
            prepare_certificate || { cleanup_workdir; return 1; }
            ;;
        2)
            CERT_MODE=selfsigned_ca; CERT_KIND=host; CERT_DOMAIN=''; CERT_EMAIL=''
            if valid_domain "$PUBLIC_HOST"; then HY2_SNI="$PUBLIC_HOST"; else HY2_SNI="$SNI"; fi
            make_self_signed_cert "$WORK_DIR/hy2-cert.pem" "$WORK_DIR/hy2-key.pem" || { cleanup_workdir; return 1; }
            ;;
        0|'')
            cp -p "$CERT_FILE" "$WORK_DIR/hy2-cert.pem" && cp -p "$KEY_FILE" "$WORK_DIR/hy2-key.pem" || { cleanup_workdir; return 1; }
            [[ ! -s "$CA_FILE" ]] || cp -p "$CA_FILE" "$WORK_DIR/hy2-ca.pem" || { cleanup_workdir; return 1; }
            [[ ! -s "$CA_KEY_FILE" ]] || cp -p "$CA_KEY_FILE" "$WORK_DIR/hy2-ca-key.pem" || { cleanup_workdir; return 1; }
            ;;
        *) err '选项无效。'; cleanup_workdir; return 1 ;;
    esac

    make_credentials "$SHOES_BIN" || { cleanup_workdir; return 1; }
    write_config "$WORK_DIR/config.stage.yaml" "$WORK_DIR/hy2-cert.pem" "$WORK_DIR/hy2-key.pem"
    validate_config "$SHOES_BIN" "$WORK_DIR/config.stage.yaml" || { cleanup_workdir; return 1; }
    write_config "$WORK_DIR/config.final.yaml" "$CERT_FILE" "$KEY_FILE"
    write_links "$WORK_DIR/links.txt"
    write_state "$WORK_DIR/manager.env"

    install -m 600 "$WORK_DIR/hy2-cert.pem" "$CERT_FILE.new" || { cleanup_workdir; return 1; }
    install -m 600 "$WORK_DIR/hy2-key.pem" "$KEY_FILE.new" || { rm -f "$CERT_FILE.new"; cleanup_workdir; return 1; }
    if [[ -s "$WORK_DIR/hy2-ca.pem" && -s "$WORK_DIR/hy2-ca-key.pem" ]]; then
        install -m 600 "$WORK_DIR/hy2-ca.pem" "$CA_FILE.new" || { cleanup_workdir; return 1; }
        install -m 600 "$WORK_DIR/hy2-ca-key.pem" "$CA_KEY_FILE.new" || { rm -f "$CA_FILE.new"; cleanup_workdir; return 1; }
    fi
    install -m 600 "$WORK_DIR/config.final.yaml" "$CONF_FILE.new" || { rm -f "$CERT_FILE.new" "$KEY_FILE.new" "$CA_FILE.new" "$CA_KEY_FILE.new"; cleanup_workdir; return 1; }
    install -m 600 "$WORK_DIR/links.txt" "$LINK_FILE.new" || { rm -f "$CERT_FILE.new" "$KEY_FILE.new" "$CA_FILE.new" "$CA_KEY_FILE.new" "$CONF_FILE.new"; cleanup_workdir; return 1; }
    install -m 600 "$WORK_DIR/manager.env" "$STATE_FILE.new" || { rm -f "$CERT_FILE.new" "$KEY_FILE.new" "$CA_FILE.new" "$CA_KEY_FILE.new" "$CONF_FILE.new" "$LINK_FILE.new"; cleanup_workdir; return 1; }
    mv -f "$CERT_FILE.new" "$CERT_FILE" && mv -f "$KEY_FILE.new" "$KEY_FILE" || failed=1
    if (( ! failed )) && [[ -f "$CA_FILE.new" && -f "$CA_KEY_FILE.new" ]]; then
        mv -f "$CA_FILE.new" "$CA_FILE" && mv -f "$CA_KEY_FILE.new" "$CA_KEY_FILE" || failed=1
    fi
    if (( ! failed )); then mv -f "$CONF_FILE.new" "$CONF_FILE" && mv -f "$LINK_FILE.new" "$LINK_FILE" && mv -f "$STATE_FILE.new" "$STATE_FILE" || failed=1; fi
    if (( ! failed )); then validate_config "$SHOES_BIN" "$CONF_FILE" || failed=1; fi
    if (( ! failed )); then
        if (( was_active )); then systemctl restart shoes || failed=1; else systemctl start shoes || failed=1; fi
        systemctl is-active --quiet shoes || failed=1
    fi
    if (( failed )); then
        err '新凭据应用失败，恢复旧配置、证书、链接和状态。'
        for f in config.yaml links.txt manager.env hy2-cert.pem hy2-key.pem hy2-ca.pem hy2-ca-key.pem; do
            if [[ -e "$WORK_DIR/backup/$f" ]]; then
                install -m 600 "$WORK_DIR/backup/$f" "$CONF_DIR/$f" || true
            else
                rm -f -- "$CONF_DIR/$f"
            fi
        done
        systemctl restart shoes >/dev/null 2>&1 || true
        journalctl -u shoes -n 40 --no-pager >&2 2>/dev/null || true
        cleanup_workdir
        return 1
    fi
    if [[ "$CERT_MODE" == letsencrypt ]]; then
        rm -f "$CA_FILE" "$CA_KEY_FILE"
        install_certbot_deploy_hook || warn '证书更新钩子/定时器安装失败。'
    else
        remove_certbot_deploy_hook
    fi
    open_ufw_ports_if_active || warn '自动配置 UFW 失败，请检查防火墙。'
    ok '新链接已生成，旧 VLESS UUID/REALITY 密钥和旧 HY2 密码已轮换。'
    say '请在下面复制新链接；已经建立的旧会话可能直到断开才结束。'
    cat "$LINK_FILE"
    cleanup_workdir
}




show_shoes_logs() {
    say '显示最近 100 行 Shoes 服务日志，随后持续跟踪；按 Ctrl+C 返回菜单。'
    journalctl -u shoes -n 100 -f --no-pager
}

uninstall_all() {
    local ans
    if [[ ! -e "$SHOES_BIN" && ! -e "$CONF_DIR" && ! -e "$UNIT_FILE" ]]; then
        err '没有发现 Shoes 安装或残留文件。'; return 1
    fi
    read -r -p '确认卸载 Shoes 并删除所有代理凭据/链接？输入 yes 继续：' ans || return 1
    [[ "$ans" == yes ]] || { say '已取消。'; return 0; }
    lock_operation || return 1
    if [[ -e "$UNIT_FILE" ]]; then
        systemctl stop shoes || { err '停止服务失败，已取消卸载。'; return 1; }
        systemctl disable shoes || { err '禁用服务失败，已取消卸载。'; return 1; }
    fi
    rm -f -- "$UNIT_FILE" "$SHOES_BIN" "${SHOES_BIN}.new" || return 1
    remove_certbot_deploy_hook
    rm -rf -- "$CONF_DIR" || return 1
    systemctl daemon-reload || return 1
    systemctl reset-failed shoes >/dev/null 2>&1 || true
    say 'Shoes、VLESS/REALITY 凭据、Hysteria2 密码、证书和链接已删除。'
    say '未卸载 XanMod 内核、未移除 APT 仓库，也未删除系统基础依赖。UFW 已放行的 443/80 规则不会自动删除。'
}

show_menu() {
    local version='未安装' state='停止'
    [[ ! -x "$SHOES_BIN" ]] || version=$(timeout 3 "$SHOES_BIN" --version 2>/dev/null || echo '版本未知')
    if is_active 2>/dev/null; then state="${C_GREEN}● 运行中${C_RESET}"; else state="${C_RED}● 未运行${C_RESET}"; fi
    printf '\n%b' "$C_PURPLE"
    cat <<'BANNER'
  ███████╗██╗  ██╗ ██████╗ ███████╗███████╗
  ██╔════╝██║  ██║██╔═══██╗██╔════╝██╔════╝
  ███████╗███████║██║   ██║█████╗  ███████╗
  ╚════██║██╔══██║██║   ██║██╔══╝  ╚════██║
  ███████║██║  ██║╚██████╔╝██║     ███████║
  ╚══════╝╚═╝  ╚═╝ ╚═════╝ ╚═╝     ╚══════╝
BANNER
    printf '%b' "$C_RESET"
    line
    printf '  %b版本%b  %-24s %b服务%b  %b\n' "$C_CYAN" "$C_RESET" "$version" "$C_CYAN" "$C_RESET" "$state"
    printf '  %b链路%b  %bTCP/443 REALITY%b  ·  %bUDP/443 Hysteria2%b\n' "$C_CYAN" "$C_RESET" "$C_GREEN" "$C_RESET" "$C_PURPLE" "$C_RESET"
    line
    printf '  %b[1]%b 一键安装 / 更新 Shoes\n' "$C_GREEN" "$C_RESET"
    printf '  %b[2]%b 重新生成链接\n' "$C_GREEN" "$C_RESET"
    printf '  %b[3]%b 查看当前链接\n' "$C_CYAN" "$C_RESET"
    printf '  %b[4]%b 卸载 Shoes 和代理配置\n' "$C_RED" "$C_RESET"
    printf '  %b[5]%b 查看 Shoes 实时日志（Ctrl+C 返回）\n' "$C_PURPLE" "$C_RESET"
    printf '  %b[0]%b 退出\n' "$C_DIM" "$C_RESET"
    line
}


main() {
    local choice
    need_root || return 1
    check_platform || return 1
    while true; do
        show_menu
        read -r -p "${C_CYAN}选择功能 › ${C_RESET}" choice || { printf '\n'; return 0; }
        case "$choice" in
            1) install_or_update || warn '操作失败，请查看上方错误或日志。' ;;
            2) rotate_links || warn '链接轮换失败；脚本会尝试恢复旧配置。' ;;
            3) show_links || true ;;
            4) uninstall_all || true ;;
            5) show_shoes_logs || true ;;
            0) return 0 ;;
            *) warn '无效选项。' ;;
        esac
        read -r -p '按 Enter 返回主菜单...' _ || { printf '\n'; return 0; }
    done
}
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
