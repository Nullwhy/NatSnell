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

current_version="1.1"
SNELL_VERSION="5"

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

get_current_dns() {
    grep -m1 '^nameserver' /etc/resolv.conf 2>/dev/null | awk '{print $2}' || echo "未知"
}

create_shortcut() {
    cat << 'INNER_EOF' > /usr/local/bin/nsl
#!/bin/bash
bash <(curl -fsSL https://raw.githubusercontent.com/Nullwhy/NatSnell/main/NatSnell.sh)
INNER_EOF
    chmod +x /usr/local/bin/nsl
}

auto_update_script() {
    echo -e "\n${CYAN}正在检查脚本更新...${RESET}"
    TMP_SCRIPT=$(mktemp)
    if curl -sL https://raw.githubusercontent.com/Nullwhy/NatSnell/main/NatSnell.sh -o "$TMP_SCRIPT"; then
        new_version=$(grep "current_version=" "$TMP_SCRIPT" | head -n1 | cut -d'"' -f2)
        if [ "$new_version" != "$current_version" ] && [ -n "$new_version" ]; then
            echo -e "  ${GREEN}★ 发现新版本：v${new_version}${RESET}"
            cp "$0" "${0}.backup" 2>/dev/null
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

install_dependencies() {
    echo -e "\n${CYAN}正在安装基本依赖...${RESET}"
    if command -v apt-get &>/dev/null; then
        apt-get update -y >/dev/null 2>&1
        apt-get install -y wget unzip curl jq >/dev/null 2>&1
    elif command -v yum &>/dev/null; then
        yum install -y wget unzip curl jq >/dev/null 2>&1
    fi
}

get_public_ip() {
    PUB_IP=$(curl -s4 https://api.ipify.org || curl -s4 https://ip.sb || echo "你的公网IP")
}

set_system_dns() {
    echo -e "\n${CYAN}[+] 修改系统 DNS 解析服务器：${RESET}"
    echo -e "  1. Google DNS (8.8.8.8 / 8.8.4.4)"
    echo -e "  2. Cloudflare DNS (1.1.1.1 / 1.0.0.1)"
    echo -e "  3. Quad9 DNS (9.9.9.9 / 149.112.112.112)"
    echo -e "  4. 自定义 DNS"
    echo -e "  0. 返回主菜单"
    read -rp "  请选择 [0-4]: " dns_choice

    case "$dns_choice" in
        1) dns1="8.8.8.8"; dns2="8.8.4.4" ;;
        2) dns1="1.1.1.1"; dns2="1.0.0.1" ;;
        3) dns1="9.9.9.9"; dns2="149.112.112.112" ;;
        4)
            read -rp "  请输入首选 DNS (例如 8.8.8.8): " dns1
            read -rp "  请输入备用 DNS (可选，留空跳过): " dns2
            ;;
        0) return ;;
        *) echo -e "  ${RED}❌ 输入无效${RESET}"; return ;;
    esac

    if [ -n "$dns1" ]; then
        chattr -i /etc/resolv.conf 2>/dev/null
        cat <<EOF > /etc/resolv.conf
nameserver $dns1
EOF
        [ -n "$dns2" ] && echo "nameserver $dns2" >> /etc/resolv.conf
        echo -e "  ${GREEN}✓ 系统 DNS 已成功修改为: $dns1 ${dns2:+$dns2}${RESET}"
    fi
}

install_snell() {
    auto_update_script
    install_dependencies

    echo -e "\n${CYAN}[+] 请选择要安装的 Snell 版本：${RESET}"
    echo -e "  1. Snell v4"
    echo -e "  2. Snell v5 (推荐)"
    echo -e "  3. Snell v6 (Beta)"
    read -rp "  请选择 [1-3, 默认 2]: " v_choice
    case "$v_choice" in
        1) SNELL_VERSION="4" ;;
        3) SNELL_VERSION="6" ;;
        *) SNELL_VERSION="5" ;;
    esac

    IPV6_ENABLE="false"
    LISTEN_ADDR="0.0.0.0"
    echo -e "\n${CYAN}[+] 配置网络监听：${RESET}"
    read -rp "  是否启用 IPv6 监听? [y/N] (默认关闭，适合 NAT/LXC): " ipv6_choice
    if [[ "$ipv6_choice" =~ ^[yY]$ ]]; then
        IPV6_ENABLE="true"
        LISTEN_ADDR="::0"
    fi

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
version = ${SNELL_VERSION}
EOF

    if [ "$SNELL_VERSION" != "6" ]; then
        echo "ipv6 = ${IPV6_ENABLE}" >> "$SNELL_CONF_DIR/snell-server.conf"
    fi

    ARCH=$(uname -m)
    ARCH_TYPE="amd64"
    [ "$ARCH" = "aarch64" ] && ARCH_TYPE="aarch64"

    if [ "$SNELL_VERSION" = "4" ]; then
        DOWNLOAD_URL="https://dl.nssurge.com/snell/snell-server-v4.0.1-linux-${ARCH_TYPE}.zip"
    elif [ "$SNELL_VERSION" = "5" ]; then
        DOWNLOAD_URL="https://dl.nssurge.com/snell/snell-server-v5.0.1-linux-${ARCH_TYPE}.zip"
    elif [ "$SNELL_VERSION" = "6" ]; then
        DOWNLOAD_URL="https://dl.nssurge.com/snell/snell-server-v6.0.0b4-linux-${ARCH_TYPE}.zip"
    fi

    echo -e "  ${CYAN}下载 Snell v${SNELL_VERSION} 服务端...${RESET}"
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

    systemctl daemon-reload
    systemctl enable snell >/dev/null 2>&1
    systemctl restart snell

    create_shortcut

    echo -e "\n${GREEN}=========================================================${RESET}"
    echo -e "${GREEN}  ✓ Snell v${SNELL_VERSION} 服务安装并启动成功！${RESET}"
    echo -e "  端口: ${YELLOW}${SNELL_PORT}${RESET} | PSK: ${YELLOW}${SNELL_PSK}${RESET}"
    echo -e "${GREEN}=========================================================${RESET}"
}

do_uninstall_snell() {
    echo -e "  ${YELLOW}正在清理并卸载 Snell...${RESET}"
    systemctl stop snell 2>/dev/null
    systemctl disable snell 2>/dev/null
    rm -f /etc/systemd/system/snell.service
    rm -rf /etc/snell
    rm -f /usr/local/bin/snell-server
    echo -e "  ${GREEN}✓ Snell 卸载完成！${RESET}"
}

do_uninstall_shadowtls() {
    echo -e "  ${YELLOW}正在清理并卸载 ShadowTLS...${RESET}"
    systemctl stop shadowtls 2>/dev/null
    systemctl disable shadowtls 2>/dev/null
    rm -f /etc/systemd/system/shadowtls.service
    rm -f /usr/local/bin/shadow-tls
    echo -e "  ${GREEN}✓ ShadowTLS 卸载完成！${RESET}"
}

uninstall_menu() {
    echo -e "\n${CYAN}卸载管理选项：${RESET}"
    echo -e "  1. 仅卸载 Snell"
    echo -e "  2. 仅卸载 ShadowTLS"
    echo -e "  3. 全部彻底卸载"
    echo -e "  0. 返回"
    read -rp "  请选择 [0-3]: " un_choice

    if [ "$un_choice" = "1" ]; then
        do_uninstall_snell
    elif [ "$un_choice" = "2" ]; then
        do_uninstall_shadowtls
    elif [ "$un_choice" = "3" ]; then
        do_uninstall_snell
        do_uninstall_shadowtls
        rm -f /usr/local/bin/nsl /usr/local/bin/snell
        echo -e "  ${GREEN}✓ 已完全清理所有脚本和服务！${RESET}"
    fi
    systemctl daemon-reload
}

view_snell_config() {
    if [ ! -f "/etc/snell/snell-server.conf" ]; then
        echo -e "\n${RED}❌ 未找到 Snell 配置文件，请先安装 Snell！${RESET}"
        return 1
    fi

    SNELL_PSK=$(grep -E '^psk' /etc/snell/snell-server.conf | awk -F'=' '{print $2}' | tr -d ' ')
    SNELL_PORT=$(grep -E '^listen' /etc/snell/snell-server.conf | sed -n 's/.*:\([0-9]*\)/\1/p')
    SNELL_VER=$(grep -E '^version' /etc/snell/snell-server.conf | awk -F'=' '{print $2}' | tr -d ' ')
    [ -z "$SNELL_VER" ] && SNELL_VER="5"

    get_public_ip

    echo -e "\n${CYAN}┌───────────────────────────────────────────────────────┐${RESET}"
    echo -e "${CYAN}│               📊 当前节点配置卡片                     │${RESET}"
    echo -e "${CYAN}├───────────────────────────────────────────────────────┤${RESET}"
    echo -e "  公网 IP 地址     : ${BOLD}${PUB_IP}${RESET}"
    echo -e "  Snell 内部端口   : ${YELLOW}${SNELL_PORT}${RESET}"
    echo -e "  Snell PSK 密钥   : ${YELLOW}${SNELL_PSK}${RESET}"
    echo -e "  Snell 协议版本   : ${YELLOW}v${SNELL_VER}${RESET}"

    if [ -f "/etc/systemd/system/shadowtls.service" ]; then
        STLS_CMD=$(grep -E '^ExecStart' /etc/systemd/system/shadowtls.service)
        STLS_PORT=$(echo "$STLS_CMD" | sed -n 's/.*--listen [^:]*:\([0-9]*\).*/\1/p')
        STLS_PWD=$(echo "$STLS_CMD" | sed -n 's/.*--password \([^ ]*\).*/\1/p')
        STLS_SNI=$(echo "$STLS_CMD" | sed -n 's/.*--tls \([^:]*\):.*/\1/p')
        [ -z "$STLS_SNI" ] && STLS_SNI="microsoft.com"

        echo -e "${CYAN}├───────────────────────────────────────────────────────┤${RESET}"
        echo -e "  ShadowTLS 端口   : ${YELLOW}${STLS_PORT}${RESET} ${PURPLE}(NAT小鸡映射此端口)${RESET}"
        echo -e "  ShadowTLS 密码   : ${YELLOW}${STLS_PWD}${RESET}"
        echo -e "  ShadowTLS SNI    : ${YELLOW}${STLS_SNI}${RESET}"
        echo -e "${CYAN}├───────────────────────────────────────────────────────┤${RESET}"
        echo -e "  ${GREEN}${BOLD}📦 Sub-Store 配置字符串:${RESET}"
        echo -e "  ${YELLOW}NatSnell = snell, ${PUB_IP}, ${STLS_PORT}, version=${SNELL_VER}, psk=${SNELL_PSK}, shadow-tls-password=${STLS_PWD}, shadow-tls-version=3, shadow-tls-sni=${STLS_SNI}, tfo=true${RESET}"
    else
        echo -e "${CYAN}├───────────────────────────────────────────────────────┤${RESET}"
        echo -e "  ${YELLOW}直连配置：${RESET}"
        echo -e "  ${YELLOW}NatSnell = snell, ${PUB_IP}, ${SNELL_PORT}, version=${SNELL_VER}, psk=${SNELL_PSK}, tfo=true${RESET}"
    fi

    echo -e "${CYAN}├───────────────────────────────────────────────────────┤${RESET}"
    echo -e "  终端管理快捷指令 : ${GREEN}${BOLD}nsl${RESET} ${PURPLE}(在 VPS 任何位置输入此命令调出菜单)${RESET}"
    echo -e "${CYAN}└───────────────────────────────────────────────────────┘${RESET}\n"
}

restart_snell() {
    systemctl restart snell 2>/dev/null
    systemctl restart shadowtls 2>/dev/null
    echo -e "\n  ${GREEN}✓ 所有服务均已正常重启！${RESET}"
}

setup_shadowtls() {
    echo -e "\n${CYAN}[+] 配置 ShadowTLS 伪装层：${RESET}"
    read -rp "  请输入 ShadowTLS 监听端口 [默认 50002]: " STLS_PORT
    [ -z "$STLS_PORT" ] && STLS_PORT="50002"

    read -rp "  请输入转发的目标 Snell 内部端口 [默认 50001]: " SNELL_PORT
    [ -z "$SNELL_PORT" ] && SNELL_PORT="50001"

    read -rp "  请输入伪装域名 (SNI) [默认 microsoft.com]: " TLS_DOMAIN
    [ -z "$TLS_DOMAIN" ] && TLS_DOMAIN="microsoft.com"

    DEFAULT_STLS_PWD=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 16)
    read -rp "  请输入 ShadowTLS 密码 [默认随机: ${DEFAULT_STLS_PWD}]: " STLS_PWD
    [ -z "$STLS_PWD" ] && STLS_PWD="$DEFAULT_STLS_PWD"

    ARCH=$(uname -m)
    STLS_ARCH="x86_64-unknown-linux-musl"
    [ "$ARCH" = "aarch64" ] && STLS_ARCH="aarch64-unknown-linux-musl"

    echo -e "  ${CYAN}下载 ShadowTLS 服务端...${RESET}"
    wget -q -O /usr/local/bin/shadow-tls "https://github.com/ihciah/shadow-tls/releases/latest/download/shadow-tls-${STLS_ARCH}" || { echo -e "  ${RED}❌ 下载失败${RESET}"; return 1; }
    chmod +x /usr/local/bin/shadow-tls

    cat <<EOF > /etc/systemd/system/shadowtls.service
[Unit]
Description=Shadow-TLS Service for Snell
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/shadow-tls --v3 server --listen 0.0.0.0:${STLS_PORT} --server 127.0.0.1:${SNELL_PORT} --tls ${TLS_DOMAIN}:443 --password ${STLS_PWD} --wildcard-sni authed
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable shadowtls >/dev/null 2>&1
    systemctl restart shadowtls

    echo -e "  ${GREEN}✓ ShadowTLS 配置成功并已启动！${RESET}"
    view_snell_config
}

show_menu() {
    clear
    echo -e "${CYAN}=========================================================${RESET}"
    echo -e "${BOLD}${GREEN}          NatSnell 管理面板 v${current_version} (LXC / NAT)${RESET}"
    echo -e "${PURPLE}          GitHub: Nullwhy/NatSnell${RESET}"
    echo -e "${CYAN}=========================================================${RESET}"
    
    printf "  %-22s : " "Snell 服务" ; check_status "snell"
    printf "  %-22s : " "ShadowTLS 伪装" ; check_status "shadowtls"
    printf "  %-22s : ${YELLOW}%s${RESET}\n" "系统 DNS" "$(get_current_dns)"
    
    echo -e "${CYAN}---------------------------------------------------------${RESET}"
    echo -e "  ${GREEN}1.${RESET} 安装 / 重置 Snell"
    echo -e "  ${GREEN}2.${RESET} 安装 / 配置 ShadowTLS"
    echo -e "  ${GREEN}3.${RESET} ${BOLD}修改 / 优化系统 DNS${RESET}"
    echo -e "  ${GREEN}4.${RESET} 卸载管理 (Snell / ShadowTLS)"
    echo -e "  ${GREEN}5.${RESET} 查看配置 / 导出节点字符串"
    echo -e "  ${GREEN}6.${RESET} 重启所有服务"
    echo -e "  ${GREEN}7.${RESET} 检查脚本更新"
    echo -e "  ${RED}0.${RESET} 退出面板"
    echo -e "${CYAN}=========================================================${RESET}"
    read -rp "  请选择操作 [0-7]: " num
}

while true; do
    show_menu
    case "$num" in
        1) install_snell; read -rp "  按回车键返回菜单..." ;;
        2) setup_shadowtls; read -rp "  按回车键返回菜单..." ;;
        3) set_system_dns; read -rp "  按回车键返回菜单..." ;;
        4) uninstall_menu; read -rp "  按回车键返回菜单..." ;;
        5) view_snell_config; read -rp "  按回车键返回菜单..." ;;
        6) restart_snell; read -rp "  按回车键返回菜单..." ;;
        7) auto_update_script; read -rp "  按回车键返回菜单..." ;;
        0) echo -e "\n  ${GREEN}感谢使用 NatSnell，再见！${RESET}\n"; exit 0 ;;
        *) echo -e "  ${RED}❌ 请输入有效数字！${RESET}"; sleep 1 ;;
    esac
done
