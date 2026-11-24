#!/bin/bash
# =========================================================
# 项目: NatSnell (专为 NAT / LXC 优化版)
# 仓库: Nullwhy/NatSnell
# 描述: 用于快速部署与管理 Snell + ShadowTLS 节点，集成 BBR 管理
# =========================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

current_version="1.3"
SNELL_VERSION="5"

BBR_SYSCTL="/etc/sysctl.d/99-snell-bbr.conf"
BBR_MODULES="/etc/modules-load.d/snell-bbr.conf"
XANMOD_KEY_URL="https://dl.xanmod.org/archive.key"
XANMOD_REPO="http://deb.xanmod.org"
XANMOD_KEYRING="/etc/apt/keyrings/xanmod-archive-keyring.gpg"
XANMOD_LIST="/etc/apt/sources.list.d/xanmod-release.list"
CPUINFO="${BBR_CPUINFO:-/proc/cpuinfo}"
BBR_KEYS="net.core.default_qdisc net.ipv4.tcp_congestion_control net.core.rmem_max net.core.wmem_max net.ipv4.tcp_rmem net.ipv4.tcp_wmem"

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

current_cc()    { sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "未知"; }
current_qdisc() { sysctl -n net.core.default_qdisc 2>/dev/null; }
available_cc()  { cat /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null || echo "未知"; }
bbr_available() { available_cc | grep -qw bbr; }

kernel_at_least() {
    local v maj min
    v=$(uname -r)
    maj=${v%%.*}
    v=${v#*.}
    min=${v%%[!0-9]*}
    [ "${maj:-0}" -gt "$1" ] || { [ "${maj:-0}" -eq "$1" ] && [ "${min:-0}" -ge "$2" ]; }
}

in_container() {
    if command -v systemd-detect-virt >/dev/null 2>&1; then
        systemd-detect-virt -c -q && return 0
        [ "$(systemd-detect-virt 2>/dev/null)" = "openvz" ] && return 0
        return 1
    fi
    [ -f /.dockerenv ] || [ -f /run/.containerenv ] && return 0
    grep -qa 'container=' /proc/1/environ 2>/dev/null && return 0
    [ -d /proc/vz ] && [ ! -d /proc/bc ]
}

secure_boot_on() {
    local f
    for f in /sys/firmware/efi/efivars/SecureBoot-*; do
        [ -r "$f" ] || continue
        [ "$(od -An -t u1 "$f" 2>/dev/null | awk '{print $NF}')" = "1" ] && return 0
    done
    return 1
}

xanmod_suite_ok() {
    [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "${XANMOD_REPO}/dists/$1/Release")" = "200" ]
}

xanmod_running() {
    uname -r | grep -qi xanmod
}

xanmod_installed() {
    command -v dpkg-query >/dev/null 2>&1 && \
        dpkg-query -W -f='${Status} ${Package}\n' 'linux-image-*xanmod*' 2>/dev/null | grep -q '^install ok installed'
}

fix_legacy_xanmod_repo() {
    [ -f "$XANMOD_LIST" ] && grep -q '^deb .*deb\.xanmod\.org releases' "$XANMOD_LIST" || return 0
    local codename
    codename=$( [ -f /etc/os-release ] && . /etc/os-release && echo "${VERSION_CODENAME:-}" )
    if xanmod_installed && [ -n "$codename" ] && command -v curl >/dev/null 2>&1 && xanmod_suite_ok "$codename"; then
        sed -i "s#deb\.xanmod\.org releases#deb.xanmod.org ${codename}#" "$XANMOD_LIST"
        echo -e "  ${YELLOW}旧版 XanMod 软件源（releases）已失效，已自动改为 ${codename}。${RESET}"
    else
        rm -f "$XANMOD_LIST"
        echo -e "  ${YELLOW}旧版 XanMod 软件源（releases）已失效且未生效，已移除以防 apt 报错。${RESET}"
    fi
}

get_bbr_menu_status() {
    local cc q
    cc=$(current_cc)
    q=$(current_qdisc)
    if [ "$cc" = "bbr" ]; then
        if [ -n "$q" ]; then
            echo -e "${GREEN}● bbr (队列: ${q})${RESET}"
        else
            echo -e "${GREEN}● bbr${RESET}"
        fi
    else
        echo -e "${YELLOW}○ ${cc:-未知}${RESET}"
    fi
}

show_bbr_status() {
    local mine="无" kern q
    [ -f "$BBR_SYSCTL" ] && mine="已写入 ${BBR_SYSCTL}"
    kern=$(uname -r)
    if xanmod_running; then
        kern="${kern}（XanMod）"
    elif xanmod_installed; then
        kern="${kern}（已装 XanMod，重启后生效）"
    fi
    q=$(current_qdisc)
    q=${q:+   默认队列 $q}
    echo -e "  内核        ${kern}"
    if [ "$(current_cc)" = "bbr" ]; then
        echo -e "  拥塞控制    ${GREEN}bbr${RESET}${q}"
    else
        echo -e "  拥塞控制    ${YELLOW}$(current_cc)${RESET}${q}   可用：$(available_cc)"
    fi
    echo -e "  本脚本设置  ${mine}"
}

write_bbr_sysctl() {
    local orig="" k v
    if [ -f "$BBR_SYSCTL" ] && grep -q '^# 原值 ' "$BBR_SYSCTL"; then
        orig=$(grep '^# 原值 ' "$BBR_SYSCTL")
    elif [ -f "$BBR_SYSCTL" ]; then
        cp -a "$BBR_SYSCTL" "${BBR_SYSCTL}.bak_$(date +%Y%m%d_%H%M%S)"
    else
        for k in $BBR_KEYS; do
            v=$(sysctl -n "$k" 2>/dev/null | tr -s '\t ' '  ')
            [ -n "$v" ] && orig="${orig:+$orig
}# 原值 ${k} = ${v}"
        done
    fi
    mkdir -p "$(dirname "$BBR_SYSCTL")" "$(dirname "$BBR_MODULES")"
    {
        echo "# 由 NatSnell 的 BBR 管理写入。删除本文件并重启（或在菜单里选「恢复默认」）即恢复原来的设置。"
        [ -n "$orig" ] && printf '%s\n' "$orig"
        cat <<'SYSCTL_EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
net.ipv4.tcp_rmem = 4096 131072 33554432
net.ipv4.tcp_wmem = 4096 16384 33554432
SYSCTL_EOF
    } > "$BBR_SYSCTL"
    chmod 600 "$BBR_SYSCTL" 2>/dev/null || true
    echo "tcp_bbr" > "$BBR_MODULES"
}

apply_bbr_sysctl() {
    local out
    if ! out=$(sysctl -p "$BBR_SYSCTL" 2>&1); then
        echo -e "  ${YELLOW}部分参数未能在当前环境生效（容器或受限内核）：${RESET}"
        printf '%s\n' "$out" | grep -i -E 'error|denied|cannot|read-only|invalid' | sed 's/^/    /'
    fi
}

cleanup_legacy_sysctl() {
    local f=/etc/sysctl.conf keys ans fixed=""
    keys='net\.ipv4\.conf\.all\.route_localnet|net\.ipv4\.ip_forward|net\.ipv4\.conf\.(all|default)\.forwarding|net\.ipv6\.conf\.(all|default)\.forwarding|net\.ipv4\.tcp_fack'
    if [ -f "$BBR_SYSCTL" ] && grep -q '^net\.ipv4\.conf\.all\.route_localnet = 1' "$BBR_SYSCTL"; then
        echo -e "  ${YELLOW}旧版 ${BBR_SYSCTL} 曾修改转发/route_localnet，将替换为纯 BBR 配置（原文件会备份）。${RESET}"
        fixed=1
    fi
    if [ -f "$f" ] && grep -q '^net\.ipv4\.conf\.all\.route_localnet = 1' "$f"; then
        echo -e "  ${YELLOW}/etc/sysctl.conf 含旧版 BBR 写入的转发或 route_localnet 设置。${RESET}"
        read -rp "  是否注释掉这些旧配置？（原文件将自动备份）[Y/n]: " ans
        case "$ans" in
            [nN]*) ;;
            *)
                cp -a "$f" "${f}.bak_$(date +%Y%m%d_%H%M%S)"
                sed -i -E "s/^(($keys)[[:space:]]*=.*)$/# 已由 NatSnell BBR 管理注释：\1/" "$f"
                fixed=1
                ;;
        esac
    fi
    [ -n "$fixed" ] || return 0
    sysctl -w net.ipv4.conf.all.route_localnet=0 >/dev/null 2>&1 || true
    echo -e "  ${GREEN}✓ 已清理 route_localnet 隐患；转发项将在下次重启后恢复默认。${RESET}"
}

enable_bbr() {
    if ! command -v sysctl >/dev/null 2>&1; then
        echo -e "  ${RED}❌ 缺少 sysctl 命令，请先安装 procps 或 procps-ng${RESET}"
        return 1
    fi
    if ! kernel_at_least 4 9; then
        echo -e "  ${RED}❌ 当前内核 $(uname -r) 过旧（BBR 需要 4.9+）；Debian / Ubuntu 可选「2」安装 XanMod 内核。${RESET}"
        return 1
    fi
    command -v modprobe >/dev/null 2>&1 && modprobe tcp_bbr 2>/dev/null || true
    if ! bbr_available; then
        if in_container; then
            echo -e "  ${RED}❌ 当前处于容器/OpenVZ 环境，可用拥塞控制：$(available_cc)${RESET}"
            echo -e "  ${YELLOW}容器无法直接加载内核模块，请在宿主机执行 modprobe tcp_bbr 或联系服务商。${RESET}"
        else
            echo -e "  ${RED}❌ 当前内核不支持 BBR，可用拥塞控制：$(available_cc)${RESET}"
        fi
        return 1
    fi
    cleanup_legacy_sysctl
    write_bbr_sysctl
    apply_bbr_sysctl
    if [ "$(current_cc)" = "bbr" ]; then
        echo -e "  ${GREEN}✓ BBR 已启用（拥塞控制 bbr，默认队列 $(current_qdisc)）${RESET}"
    else
        echo -e "  ${RED}❌ 切换 BBR 失败，当前拥塞控制仍为 $(current_cc)${RESET}"
        return 1
    fi
}

cpu_level() {
    local flags f
    flags=" $(grep -m1 '^flags' "$CPUINFO" 2>/dev/null | cut -d: -f2) "
    has() { for f in "$@"; do case "$flags" in *" $f "*) ;; *) return 1 ;; esac; done; }
    has cx16 lahf_lm popcnt pni sse4_1 sse4_2 ssse3 || { echo 1; return; }
    has avx avx2 bmi1 bmi2 f16c fma abm movbe xsave || { echo 2; return; }
    has avx512f avx512bw avx512cd avx512dq avx512vl || { echo 3; return; }
    echo 4
}

xanmod_packages() {
    curl -fsSL --retry 2 --max-time 60 "${XANMOD_REPO}/dists/$1/main/binary-amd64/Packages.gz" | gzip -dc 2>/dev/null |
        sed -n 's/^Package: \(linux-xanmod-[a-z0-9-]*\)$/\1/p' | sort -u
}

xanmod_package() {
    local c want
    case "$1" in
        1) want="lts-x64v1" ;;
        2) want="x64v2 lts-x64v2 lts-x64v1" ;;
        *) want="x64v3 lts-x64v3 x64v2 lts-x64v2 lts-x64v1" ;;
    esac
    for c in $want; do
        printf '%s\n' "$2" | grep -qx "linux-xanmod-$c" && { echo "linux-xanmod-$c"; return 0; }
    done
    return 1
}

install_xanmod() {
    if [ "$(uname -m)" != "x86_64" ]; then
        echo -e "  ${RED}❌ XanMod 仅支持 x86_64 架构，当前为 $(uname -m)。${RESET}"
        return 1
    fi
    if ! command -v apt-get >/dev/null 2>&1 || [ ! -f /etc/os-release ]; then
        echo -e "  ${RED}❌ XanMod 仅支持 Debian / Ubuntu 系统。${RESET}"
        return 1
    fi
    local os_id
    os_id=$(. /etc/os-release && echo "${ID:-} ${ID_LIKE:-}" | tr '[:upper:]' '[:lower:]')
    case " $os_id " in
        *" debian "*|*" ubuntu "*) ;;
        *) echo -e "  ${RED}❌ XanMod 仅支持 Debian / Ubuntu 系统。${RESET}"; return 1 ;;
    esac
    if in_container && [ "${BBR_APT_SIMULATE:-}" != "1" ]; then
        echo -e "  ${RED}❌ 当前处于容器或 OpenVZ 环境，无法更换宿主机内核。${RESET}"
        return 1
    fi
    if secure_boot_on; then
        echo -e "  ${RED}❌ 检测到已开启 Secure Boot，安装未签名 XanMod 内核可能导致无法启动。${RESET}"
        return 1
    fi
    for cmd in curl gpg gzip; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            echo -e "  ${RED}❌ 缺少命令: $cmd，请先安装。${RESET}"
            return 1
        fi
    done

    local codename level pkg ans
    codename=$(. /etc/os-release && echo "${VERSION_CODENAME:-}")
    if [ -z "$codename" ] || ! xanmod_suite_ok "$codename"; then
        echo -e "  ${RED}❌ XanMod 源不支持当前系统版本（${codename:-未知}）。${RESET}"
        return 1
    fi
    level=$(cpu_level)
    if ! pkg=$(xanmod_package "$level" "$(xanmod_packages "$codename")"); then
        echo -e "  ${RED}❌ 未找到适配当前 CPU（x86-64-v${level}）的 XanMod 内核包。${RESET}"
        return 1
    fi

    echo -e "  ${CYAN}检测到 CPU 级别：x86-64-v${level} → 准备安装 ${pkg} (${codename})${RESET}"
    read -rp "  确认安装并设为默认启动内核吗？[y/N]: " ans
    case "$ans" in [yY]*) ;; *) echo -e "  已取消。"; return 0 ;; esac

    mkdir -p "$(dirname "$XANMOD_KEYRING")"
    if ! curl -fsSL --retry 3 --max-time 60 "$XANMOD_KEY_URL" | gpg --dearmor --yes -o "$XANMOD_KEYRING"; then
        echo -e "  ${RED}❌ 下载 XanMod 签名密钥失败。${RESET}"
        return 1
    fi
    echo "deb [signed-by=${XANMOD_KEYRING}] ${XANMOD_REPO} ${codename} main" > "$XANMOD_LIST"
    apt-get update -qq || { echo -e "  ${RED}❌ apt-get update 失败。${RESET}"; return 1; }

    local sim=""
    [ "${BBR_APT_SIMULATE:-}" = "1" ] && sim="-s"
    if ! DEBIAN_FRONTEND=noninteractive apt-get install -y $sim "$pkg"; then
        echo -e "  ${RED}❌ 安装 ${pkg} 失败。${RESET}"
        return 1
    fi
    if [ -n "$sim" ]; then
        echo -e "  ${YELLOW}（模拟安装完成，未实际修改内核）${RESET}"
        return 0
    fi

    cleanup_legacy_sysctl
    write_bbr_sysctl
    echo -e "  ${GREEN}✓ ${pkg} 安装完成，重启后启用新内核与 BBR v3。${RESET}"
    read -rp "  是否立即重启系统？[y/N]: " ans
    case "$ans" in [yY]*) reboot ;; esac
}

reset_bbr() {
    if [ ! -f "$BBR_SYSCTL" ] && [ ! -f "$BBR_MODULES" ]; then
        echo -e "  ${YELLOW}本脚本尚未写入过 BBR 配置。${RESET}"
        return 0
    fi
    local orig="" line
    [ -f "$BBR_SYSCTL" ] && orig=$(sed -n 's/^# 原值 //p' "$BBR_SYSCTL")
    rm -f "$BBR_SYSCTL" "$BBR_MODULES"
    if [ -n "$orig" ]; then
        printf '%s\n' "$orig" | while IFS= read -r line; do
            sysctl -w "${line%% = *}=${line#* = }" >/dev/null 2>&1 || true
        done
    else
        sysctl -w net.ipv4.tcp_congestion_control=cubic >/dev/null 2>&1 || true
    fi
    sysctl --system >/dev/null 2>&1 || true
    echo -e "  ${GREEN}✓ 已移除本脚本的 BBR 配置，当前拥塞控制：$(current_cc)${RESET}"
}

bbr_menu() {
    local b_choice
    fix_legacy_xanmod_repo
    while true; do
        echo -e "\n${CYAN}── BBR 管理 ──────────────────────────────────────────${RESET}"
        show_bbr_status
        echo -e "${CYAN}──────────────────────────────────────────────────────${RESET}"
        echo -e "  ${GREEN}1.${RESET} 启用 BBR（内核自带）"
        echo -e "  ${GREEN}2.${RESET} 安装 XanMod 内核（BBR v3，Debian / Ubuntu x86_64）"
        echo -e "  ${GREEN}3.${RESET} 恢复默认（移除本脚本写入的 BBR 配置）"
        echo -e "  ${RED}0.${RESET} 返回主菜单"
        read -rp "  请选择操作 [0-3]: " b_choice
        case "$b_choice" in
            1) enable_bbr; read -rp "  按回车键继续..." ;;
            2) install_xanmod; read -rp "  按回车键继续..." ;;
            3) reset_bbr; read -rp "  按回车键继续..." ;;
            0) return 0 ;;
            *) echo -e "  ${RED}❌ 请输入有效数字！${RESET}"; sleep 1 ;;
        esac
    done
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
        cat <<RESOLV_EOF > /etc/resolv.conf
nameserver $dns1
RESOLV_EOF
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

    cat <<CONF_EOF > "$SNELL_CONF_DIR/snell-server.conf"
[snell-server]
listen = ${LISTEN_ADDR}:${SNELL_PORT}
psk = ${SNELL_PSK}
version = ${SNELL_VERSION}
CONF_EOF

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

    cat <<SERVICE_EOF > /etc/systemd/system/snell.service
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
SERVICE_EOF

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

    cat <<STLS_EOF > /etc/systemd/system/shadowtls.service
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
STLS_EOF

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
    printf "  %-22s : " "TCP BBR" ; get_bbr_menu_status
    printf "  %-22s : ${YELLOW}%s${RESET}\n" "系统 DNS" "$(get_current_dns)"

    echo -e "${CYAN}---------------------------------------------------------${RESET}"
    echo -e "  ${GREEN}1.${RESET} 安装 / 重置 Snell"
    echo -e "  ${GREEN}2.${RESET} 安装 / 配置 ShadowTLS"
    echo -e "  ${GREEN}3.${RESET} ${BOLD}修改 / 优化系统 DNS${RESET}"
    echo -e "  ${GREEN}4.${RESET} 卸载管理 (Snell / ShadowTLS)"
    echo -e "  ${GREEN}5.${RESET} 查看配置 / 导出节点字符串"
    echo -e "  ${GREEN}6.${RESET} 重启所有服务"
    echo -e "  ${GREEN}7.${RESET} 检查脚本更新"
    echo -e "  ${GREEN}8.${RESET} ${BOLD}BBR 管理 (启用 BBR / XanMod)${RESET}"
    echo -e "  ${RED}0.${RESET} 退出面板"
    echo -e "${CYAN}=========================================================${RESET}"
    read -rp "  请选择操作 [0-8]: " num
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
        8) bbr_menu ;;
        0) echo -e "\n  ${GREEN}感谢使用 NatSnell，再见！${RESET}\n"; exit 0 ;;
        *) echo -e "  ${RED}❌ 请输入有效数字！${RESET}"; sleep 1 ;;
    esac
done
