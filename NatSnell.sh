#!/bin/bash
# =========================================================
# 项目: NatSnell (专为 NAT / LXC 优化版)
# 仓库: Nullwhy/NatSnell
# 描述: 用于快速部署与管理 Snell + ShadowTLS 节点，集成 BBR 管理与同网段邻居域名 Top 3 扫描
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
NEIGHBOR_TOP_N=3
NEIGHBOR_MAX_CANDIDATES=50
LAST_BEST_SNI=""

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
    [ "${maj:-0}" -gt "$1" ] \vert{}\vert{} { [ "${maj:-0}" -eq "$1" ] && [ "${min:-0}" -ge "$2" ]; }
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
        [ "$(od -An -t u1 "$f" 2>/dev/null \vert{} awk '{print $NF}')" = "1" ] && return 0
    done
    return 1
}

xanmod_suite_ok() {
    [ "$(curl -s -o /dev/null -w '\%{http_code}' --max-time 15 "${XANMOD_REPO}/dists/$1/Release")" = "200" ]
}

xanmod_running() {
    uname -r | grep -qi xanmod
}

xanmod_installed() {
    command -v dpkg-query >/dev/null 2>&1 && \
        dpkg-query -W -f='${Status}${Package}\n' 'linux-image-*xanmod*' 2>/dev/null | grep -q '^install ok installed'
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
}# 原值 ${k} =${v}"
        done
    fi
    mkdir -p "$(dirname "$BBR_SYSCTL")" "$(dirname "$BBR_MODULES")"
    {
        echo "# 由 NatSnell 的 BBR 管理写入。删除本文件并重启（或在菜单里选「恢复默认」）即恢复原来的设置。"
        [ -n "$orig" ] && printf '\%s\n' "$orig"
        cat <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
net.ipv4.tcp_rmem = 4096 131072 33554432
net.ipv4.tcp_wmem = 4096 16384 33554432
EOF
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
