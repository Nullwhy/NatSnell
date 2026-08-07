#!/bin/bash
# =========================================
# 项目: NatSnell (专为 NAT / LXC 优化版)
# 仓库: Nullwhy/NatSnell
# 描述: 用于快速部署与管理 Snell + ShadowTLS 节点
# =========================================

# 定义颜色代码
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
RESET='\033[0m'

# 当前版本号
current_version="1.0"

# 全局变量：选择的 Snell 版本
SNELL_VERSION_CHOICE=""
SNELL_VERSION=""

# === 选择 Snell 版本 ===
select_snell_version() {
    echo -e "${CYAN}请选择要安装的 Snell 版本：${RESET}"
    echo -e "${GREEN}1.${RESET} Snell v4"
    echo -e "${GREEN}2.${RESET} Snell v5"
    echo -e "${GREEN}3.${RESET} Snell v6 (Beta)"

    while true; do
        read -rp "请输入选项 [1-3]: " version_choice
        case "$version_choice" in
            1)
                SNELL_VERSION_CHOICE="v4"
                echo -e "${GREEN}已选择 Snell v4${RESET}"
                break
                ;;
            2)
                SNELL_VERSION_CHOICE="v5"
                echo -e "${GREEN}已选择 Snell v5${RESET}"
                break
                ;;
            3)
                SNELL_VERSION_CHOICE="v6"
                echo -e "${GREEN}已选择 Snell v6 (Beta)${RESET}"
                break
                ;;
            *)
                echo -e "${RED}无效选项，请重新输入${RESET}"
                ;;
        esac
    done
}

# === 自动更新脚本 ===
auto_update_script() {
    echo -e "${CYAN}正在检查脚本更新...${RESET}"
    
    TMP_SCRIPT=$(mktemp)
    
    if curl -sL https://raw.githubusercontent.com/Nullwhy/NatSnell/main/NatSnell.sh -o "$TMP_SCRIPT"; then
        new_version=$(grep "current_version=" "$TMP_SCRIPT" | head -n1 | cut -d'"' -f2)
        
        if [ "$new_version" != "$current_version" ] && [ -n "$new_version" ]; then
            echo -e "${GREEN}发现新版本：${new_version}${RESET}"
            echo -e "${YELLOW}当前版本：${current_version}${RESET}"
            
            cp "$0" "${0}.backup"
            mv "$TMP_SCRIPT" "$0"
            chmod +x "$0"
            
            echo -e "${GREEN}脚本已更新到最新版本，请重新运行脚本${RESET}"
            exit 0
        else
            echo -e "${GREEN}当前已是最新版本 (${current_version})${RESET}"
            rm -f "$TMP_SCRIPT"
        fi
    else
        echo -e "${RED}检查更新失败，请检查网络连接${RESET}"
        rm -f "$TMP_SCRIPT"
    fi
}

# === 检查网络环境（默认纯 IPv4） ===
get_ipv6_choice() {
    IPV6_ENABLE="false"
    LISTEN_ADDR="0.0.0.0"
    read -rp "是否启用 IPv6 监听? [y/N] (默认关闭，适合 NAT 小鸡): " ipv6_choice
    case "$ipv6_choice" in
        [yY]|[yY][eE][sS])
            IPV6_ENABLE="true"
            LISTEN_ADDR="::0"
            echo -e "${GREEN}已启用 IPv6 监听${RESET}"
            ;;
        *)
            IPV6_ENABLE="false"
            LISTEN_ADDR="0.0.0.0"
            echo -e "${GREEN}已锁定纯 IPv4 监听 (0.0.0.0)${RESET}"
            ;;
    esac
}

# === 安装依赖项 ===
install_dependencies() {
    echo -e "${CYAN}正在安装基本依赖包...${RESET}"
    if command -v apt-get &>/dev/null; then
        apt-get update -y && apt-get install -y wget unzip curl jq
    elif command -v yum &>/dev/null; then
        yum install -y wget unzip curl jq
    fi
}

# === 安装 Snell 主程序 ===
install_snell() {
    auto_update_script
    install_dependencies
    select_snell_version
    get_ipv6_choice

    # 简单生成随机密码和端口设置
    SNELL_CONF_DIR="/etc/snell"
    mkdir -p "$SNELL_CONF_DIR"

    read -rp "请输入 Snell 内部监听端口 [默认 50001]: " SNELL_PORT
    [ -z "$SNELL_PORT" ] && SNELL_PORT="50001"

    SNELL_PSK=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 16)

    cat <<EOF > "$SNELL_CONF_DIR/snell-server.conf"
[snell-server]
listen = ${LISTEN_ADDR}:${SNELL_PORT}
psk = ${SNELL_PSK}
ipv6 = ${IPV6_ENABLE}
EOF

    # 获取对应架构下载链接
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64)  ARCH_TYPE="amd64" ;;
        aarch64) ARCH_TYPE="aarch64" ;;
        *) echo -e "${RED}不支持的架构: $ARCH${RESET}"; return 1 ;;
    esac

    echo -e "${CYAN}正在下载 Snell 服务端...${RESET}"
    DOWNLOAD_URL="https://dl.nssurge.com/snell/snell-server-v4.0.1-linux-${ARCH_TYPE}.zip"
    wget -O /tmp/snell.zip "$DOWNLOAD_URL" || { echo -e "${RED}下载失败${RESET}"; return 1; }
    
    unzip -o /tmp/snell.zip -d /usr/local/bin/
    chmod +x /usr/local/bin/snell-server
    rm -f /tmp/snell.zip

    # 写入干净无 CPUAffinity 限制的 Systemd 服务
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
    systemctl enable snell
    systemctl restart snell

    # 写入快捷指令，指向个人仓库
    cat << 'EOFSCRIPT' > /usr/local/bin/snell
#!/bin/bash
bash <(curl -fsSL https://raw.githubusercontent.com/Nullwhy/NatSnell/main/NatSnell.sh)
EOFSCRIPT
    chmod +x /usr/local/bin/snell

    echo -e "${GREEN}========================================${RESET}"
    echo -e "${GREEN}Snell 安装并启动成功！${RESET}"
    echo -e "监听端口: ${GREEN}${SNELL_PORT}${RESET}"
    echo -e "密钥 PSK:  ${GREEN}${SNELL_PSK}${RESET}"
    echo -e "快捷指令: 输入 ${CYAN}snell${RESET} 即可随时唤出管理菜单"
    echo -e "${GREEN}========================================${RESET}"
}

# === 卸载 Snell ===
uninstall_snell() {
    echo -e "${YELLOW}正在清理并卸载 Snell...${RESET}"
    systemctl stop snell 2>/dev/null
    systemctl disable snell 2>/dev/null
    rm -f /etc/systemd/system/snell.service
    rm -rf /etc/snell
    rm -f /usr/local/bin/snell-server /usr/local/bin/snell
    systemctl daemon-reload
    echo -e "${GREEN}Snell 卸载完成！${RESET}"
}

# === 查看配置 ===
view_snell_config() {
    if [ -f "/etc/snell/snell-server.conf" ]; then
        echo -e "${CYAN}--- 当前 Snell 配置文件 ---${RESET}"
        cat /etc/snell/snell-server.conf
        echo -e "${CYAN}--------------------------${RESET}"
    else
        echo -e "${RED}未找到 Snell 配置文件，请先安装！${RESET}"
    fi
}

# === 重启服务 ===
restart_snell() {
    systemctl restart snell
    echo -e "${GREEN}Snell 服务已重启！${RESET}"
}

# === 安装 ShadowTLS ===
setup_shadowtls() {
    echo -e "${CYAN}正在配置 ShadowTLS 伪装层...${RESET}"
    read -rp "请输入 ShadowTLS 监听公网/NAT内部端口 [默认 50002]: " STLS_PORT
    [ -z "$STLS_PORT" ] && STLS_PORT="50002"

    read -rp "请输入转发的目标 Snell 内部端口 [默认 50001]: " SNELL_PORT
    [ -z "$SNELL_PORT" ] && SNELL_PORT="50001"

    read -rp "请输入伪装域名 (SNI) [默认 one-piece.com]: " TLS_DOMAIN
    [ -z "$TLS_DOMAIN" ] && TLS_DOMAIN="one-piece.com"

    STLS_PWD=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 16)

    # 下载 ShadowTLS 二进制文件
    ARCH=$(uname -m)
    [ "$ARCH" = "x86_64" ] && STLS_ARCH="x86_64-unknown-linux-musl"
    [ "$ARCH" = "aarch64" ] && STLS_ARCH="aarch64-unknown-linux-musl"

    wget -O /usr/local/bin/shadow-tls "https://github.com/ihciah/shadow-tls/releases/latest/download/shadow-tls-${STLS_ARCH}"
    chmod +x /usr/local/bin/shadow-tls

    # 写入适用于 NAT/LXC 的干净 Systemd 服务配置 (彻底移除 CPUAffinity 与 --fastopen)
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
    systemctl enable shadowtls
    systemctl restart shadowtls

    echo -e "${GREEN}========================================${RESET}"
    echo -e "${GREEN}ShadowTLS 配置成功并已启动！${RESET}"
    echo -e "监听端口: ${GREEN}${STLS_PORT}${RESET} (须在 NAT 控制面板映射此端口)"
    echo -e "伪装密码: ${GREEN}${STLS_PWD}${RESET}"
    echo -e "伪装域名: ${GREEN}${TLS_DOMAIN}${RESET}"
    echo -e "${GREEN}========================================${RESET}"
}

# === 菜单交互 ===
show_menu() {
    clear
    echo -e "${CYAN}========================================${RESET}"
    echo -e "${GREEN}   NatSnell 管理脚本 v${current_version} (LXC/NAT 优化版)${RESET}"
    echo -e "   仓库: Nullwhy/NatSnell"
    echo -e "${CYAN}========================================${RESET}"
    echo -e "${GREEN}1.${RESET} 安装 Snell"
    echo -e "${GREEN}2.${RESET} 卸载 Snell"
    echo -e "${GREEN}3.${RESET} 查看 Snell 配置"
    echo -e "${GREEN}4.${RESET} 重启 Snell 服务"
    echo -e "${GREEN}5.${RESET} 安装/配置 ShadowTLS"
    echo -e "${GREEN}6.${RESET} 检查脚本更新"
    echo -e "${GREEN}0.${RESET} 退出脚本"
    echo -e "${CYAN}========================================${RESET}"
    read -rp "请输入数字 [0-6]: " num
}

# === 主循环 ===
while true; do
    show_menu
    case "$num" in
        1) install_snell; read -rp "按回车键继续..." ;;
        2) uninstall_snell; read -rp "按回车键继续..." ;;
        3) view_snell_config; read -rp "按回车键继续..." ;;
        4) restart_snell; read -rp "按回车键继续..." ;;
        5) setup_shadowtls; read -rp "按回车键继续..." ;;
        6) auto_update_script; read -rp "按回车键继续..." ;;
        0) exit 0 ;;
        *) echo -e "${RED}请输入有效选项！${RESET}"; sleep 1 ;;
    esac
done
