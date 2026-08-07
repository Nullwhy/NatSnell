#!/bin/bash
# =========================================================
# 项目: NatSnell (专为 NAT / LXC 优化版)
# 仓库: Nullwhy/NatSnell
# 描述: 用于快速部署与管理 Snell + ShadowTLS 节点
# =========================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

current_version="1.0"
SNELL_VERSION_CHOICE=""
SNELL_VERSION=""

check_status() {
    local service_name=$1
    if systemctl is-active --quiet "$service_name" 2>/dev/null; then
        echo -e "${GREEN}● 运行中${RESET}"
    elif systemctl is-enabled --quiet "$service_name" 2>/dev/null; then
        echo -e "${RED}○ 已停止${RESET}"
    else
        echo -e "${YELLOW}◌ 未安装${RESET}"
    fi
}

select_snell_version() {
    echo -e "\n${CYAN}${BOLD}[+] 请选择要安装的 Snell 版本：${RESET}"
    echo -e "  ${GREEN}1.${RESET} Snell v4"
    echo -e "  ${GREEN}2.${RESET} Snell v5"
    echo -e "  ${GREEN}3.${RESET} Snell v6 (Beta)"

    while true; do
        read -rp "  请选择 [1-3]: " version_choice
        case "$version_choice" in
            1) SNELL_VERSION_CHOICE="v4"; SNELL_VERSION="4"; echo -e "  ${GREEN}✓ 已选择 Snell v4${RESET}"; break ;;
            2) SNELL_VERSION_CHOICE="v5"; SNELL_VERSION="5"; echo -e "  ${GREEN}✓ 已选择 Snell v5${RESET}"; break ;;
            3) SNELL_VERSION_CHOICE="v6"; SNELL_VERSION="6"; echo -e "  ${GREEN}✓ 已选择 Snell v6 (Beta)${RESET}"; break ;;
            *) echo -e "  ${RED}❌ 无效选项，请重新输入${RESET}" ;;
        esac
    done
}

create_shortcut() {
    echo '#!/bin/bash' > /usr/local/bin/nsl
    echo 'bash <(curl -fsSL https://raw.githubusercontent.com/Nullwhy/NatSnell/main/NatSnell.sh)' >> /usr/local/bin/nsl
    chmod +x /usr/local/bin/nsl
}

auto_update_script() {
    echo -e "\n${CYAN}正在检查脚本更新...${RESET}"
    TMP_SCRIPT=$(mktemp)
    if curl -sL https://raw.githubusercontent.com/Nullwhy/NatSnell/main/NatSnell.sh -o "$TMP_SCRIPT"; then
        new_version=$(grep "current_version=" "$TMP_SCRIPT" | head -n1 | cut -d'"' -f2)
        if [ "$new_version" != "$current_version" ] && [ -n "$new_version" ]; then
            echo -e "  ${GREEN}★ 发现新版本：v${new_version}${RESET}"
            cp "$0" "${0}.backup"
            mv "$TMP_SCRIPT" "$0"
            chmod +x "$0"
            create_shortcut
            echo -e "  ${GREEN}✓ 脚本已更新完成，请重新运行${RESET}"
            exit 0
        else
            echo -e "  ${GREEN}✓ 当前已是最新版本 (v${current_version})${RESET}"
            rm -f "$TMP_SCRIPT"
        fi
    else
        echo -e "  ${RED}❌ 检查更新失败，请检查网络${RESET}"
        rm -f "$TMP_SCRIPT"
    fi
}

get_ipv6_choice() {
    IPV6_ENABLE="false"
    LISTEN_ADDR="0.0.0.0"
    echo -e "\n${CYAN}[+] 配置网络监听：${RESET}"
    read -rp "  是否启用 IPv6 监听? [y/N] (默认关闭，适合 NAT/LXC 小鸡): " ipv6_choice
    case "$ipv6_choice" in
        [yY]|[yY][eE][sS]) IPV6_ENABLE="true"; LISTEN_ADDR="::0"; echo -e "  ${GREEN}✓ 已启用 IPv6 监听${RESET}" ;;
        *) IPV6_ENABLE="false"; LISTEN_ADDR="0.0.0.0"; echo -e "  ${GREEN}✓ 已锁定 IPv4 监听 (0.0.0.0)${RESET}" ;;
    esac
}

install_dependencies() {
    echo -e "\n${CYAN}正在安装基本依赖...${RESET}"
    if command -v apt-get &>/dev/null; then
        apt-get update -y >/dev/null 2>&1 && apt-get install -y wget unzip curl jq >/dev/null 2>&1
    elif command -v yum &>/dev/null; then
        yum install -y wget unzip curl jq >/dev/null 2>&1
    fi
}

get_public_ip() {
    PUB_IP=$(curl -s4 https://api.ipify.org || curl -s4 https://ip.sb || echo "你的公网IP")
}

install_snell() {
    auto_update_script
    install_dependencies
    select_snell_version
    get_ipv6_choice

    SNELL_CONF_DIR="/etc/snell"
    mkdir -p "$SNELL_CONF_DIR"

    echo -e "\n${CYAN}[+] 配置 Snell 参数：${RESET}"
    read -rp "  请输入 Snell 内部监听端口 [默认 50001]: " SNELL_PORT
    [ -z "$SNELL_PORT" ] && SNELL_PORT="50001"

    SNELL_PSK=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 16)

    cat <<EOF > "$SNELL_CONF_DIR/snell-server.conf"
[snell-server]
listen = ${LISTEN_ADDR}:${SNELL_PORT}
psk = ${SNELL_PSK}
ipv6 = ${IPV6_ENABLE}
version = ${SNELL_VERSION:-5}
EOF

    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64) ARCH_TYPE="amd64" ;;
        aarch64) ARCH_TYPE="aarch64" ;;
        *) echo -e "  ${RED}❌ 不支持的架构: $ARCH${RESET}"; return 1 ;;
    esac

    echo -e "  ${CYAN}下载 Snell 服务端...${RESET}"
    DOWNLOAD_URL="https://dl.nssurge.com/snell/snell-server-v4.0.1-linux-${ARCH_TYPE}.zip"
    wget -q -O /tmp/snell.zip "$DOWNLOAD_URL" || { echo -e "  ${RED}❌ 下载失败${RESET}"; return 1; }
    
    unzip -q -o /tmp/snell.zip -d /usr/local/bin/
    chmod +x /usr/local/bin/snell-server
    rm -f /tmp/snell.zip

    cat <<EOF > /etc/systemd/system/snell.service
[Unit]
Description=Snell Server Service
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/snell-server -c /etc/snell/snell-server.conf
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-
