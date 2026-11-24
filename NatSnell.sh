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
}# 原值 ${k} =${v}"
        done
    fi
    mkdir -p "$(dirname "$BBR_SYSCTL")" "$(dirname "$BBR_MODULES")"
    {
        echo "# 由 NatSnell 的 BBR 管理写入。删除本文件并重启（或在菜单里选「恢复默认」）即恢复原来的设置。"
        [ -n "$orig" ] && printf '%s\n' "$orig"
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
    if [ "$(uname -m)" != "x86_64" ]; then
        echo -e "  ${RED}❌ XanMod 仅支持 x86_64 架构，当前为 $(uname -m)。${RESET}"
        return 1
    fi
    if ! command -v apt-get >/dev/null 2>&1 || [ ! -f /etc/os-release ]; then
        echo -e "  ${RED}❌ XanMod 仅支持 Debian / Ubuntu 系统。${RESET}"
        return 1
    fi
    local os_id
    os_id=$(. /etc/os-release && echo "${ID:-}${ID_LIKE:-}" | tr '[:upper:]' '[:lower:]')
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
    echo "deb [signed-by=${XANMOD_KEYRING}]${XANMOD_REPO} ${codename} main" > "$XANMOD_LIST"
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
    echo -e "  ${GREEN}✓${pkg} 安装完成，重启后启用新内核与 BBR v3。${RESET}"
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

# ------------------------------------------------------------------------------
# 同网段 / 同 ASN 邻居域名扫描与延迟排名（输出 Top 3）
# ------------------------------------------------------------------------------
apply_sni_to_shadowtls() {
    local chosen_sni="$1"
    [ -z "$chosen_sni" ] && return 1
    LAST_BEST_SNI="$chosen_sni"

    if [ -f "/etc/systemd/system/shadowtls.service" ]; then
        local current_exec new_exec
        current_exec=$(grep -E '^ExecStart=' /etc/systemd/system/shadowtls.service | sed 's/^ExecStart=//')
        if echo "$current_exec" | grep -qE -- '--tls [^ ]+:443'; then
            new_exec=$(echo "$current_exec" | sed -E "s#--tls [^ :]+:443#--tls ${chosen_sni}:443#")
            cp -a /etc/systemd/system/shadowtls.service "/etc/systemd/system/shadowtls.service.bak_$(date +%Y%m%d_%H%M%S)"
            sed -i "s#^ExecStart=.*#ExecStart=${new_exec}#" /etc/systemd/system/shadowtls.service
            systemctl daemon-reload
            systemctl restart shadowtls >/dev/null 2>&1 || true
            echo -e "  ${GREEN}✓ 已更新 ShadowTLS SNI 为 ${chosen_sni} 并重启服务！${RESET}"
            return 0
        fi
    fi

    echo -e "  ${GREEN}✓ 已记录推荐 SNI：${chosen_sni}${RESET}"
    echo -e "  ${YELLOW}在「2. 安装 / 配置 ShadowTLS」中可直接输入该域名作为伪装 SNI。${RESET}"
}

scan_neighbor_top3() {
    echo -e "\n${CYAN}[+] 正在扫描同网段/同 ASN 可用邻居域名（低内存安全模式，输出 Top 3）...${RESET}"

    if ! command -v python3 >/dev/null 2>&1; then
        echo -e "  ${YELLOW}未检测到 python3，尝试自动安装...${RESET}"
        if command -v apt-get >/dev/null 2>&1; then
            apt-get update -y >/dev/null 2>&1 && apt-get install -y -qq python3 ca-certificates >/dev/null 2>&1 || true
        elif command -v apk >/dev/null 2>&1; then
            apk add --no-cache python3 ca-certificates >/dev/null 2>&1 || true
        fi
    fi

    if ! command -v python3 >/dev/null 2>&1; then
        echo -e "  ${RED}❌ 缺少 python3，无法执行邻居域名扫描。${RESET}"
        return 1
    fi

    local top3_json
    top3_json=$(mktemp)

    if ! python3 - "$NEIGHBOR_MAX_CANDIDATES" "$NEIGHBOR_TOP_N" "$top3_json" <<'PYEOF'
import sys
import re
import json
import time
import socket
import ssl
import ipaddress
import urllib.request
import urllib.parse
from concurrent.futures import ThreadPoolExecutor, as_completed

MAX_CANDIDATES = int(sys.argv[1]) if len(sys.argv) > 1 else 50
TOP_N = int(sys.argv[2]) if len(sys.argv) > 2 else 3
OUT_FILE = sys.argv[3] if len(sys.argv) > 3 else ""

UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"

CF_NETS = [ipaddress.ip_network(cidr) for cidr in [
    "173.245.48.0/20", "103.21.244.0/22", "103.22.200.0/22", "103.31.4.0/22",
    "141.101.64.0/18", "108.162.192.0/18", "190.93.240.0/20", "188.114.96.0/20",
    "197.234.240.0/22", "198.41.128.0/17", "162.158.0.0/15", "104.16.0.0/13",
    "104.24.0.0/14", "172.64.0.0/13", "131.0.72.0/22"
]]

def get_safe_workers():
    try:
        avail_kb = 0
        with open("/proc/meminfo", "r", encoding="utf-8") as f:
            for line in f:
                if line.startswith("MemAvailable:"):
                    avail_kb = int(line.split()[1])
                    break
        avail_mb = avail_kb / 1024.0 if avail_kb > 0 else 128.0
        if avail_mb < 256:
            return 2
        elif avail_mb < 512:
            return 4
        else:
            return 8
    except Exception:
        return 2

def http_get(url, timeout=8):
    req = urllib.request.Request(url, headers={"User-Agent": UA, "Accept": "application/json, text/html, */*"})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return resp.read().decode("utf-8", errors="ignore")

def get_public_ipv4():
    for url in ["https://api.ipify.org", "https://ipv4.icanhazip.com", "https://v4.ident.me", "https://ip.sb"]:
        try:
            ip_str = http_get(url, timeout=5).strip()
            ip_obj = ipaddress.ip_address(ip_str)
            if isinstance(ip_obj, ipaddress.IPv4Address):
                return ip_str
        except Exception:
            continue
    return ""

def get_asn_and_prefixes(ip_str):
    asns = []
    prefixes = []
    asn_descs = {}

    try:
        html = http_get(f"https://bgp.he.net/ip/{ip_str}", timeout=9)
        row_pattern = re.compile(
            r'href="/AS(\d+)"[^>]*>AS\d+</a>.*?href="/net/([0-9\./]+)"[^>]*>[0-9\./]+</a>.*?</td>\s*<td>([^<]+)</td>',
            re.S
        )
        for m in row_pattern.finditer(html):
            asn, pfx, desc = m.group(1), m.group(2).strip(), m.group(3).strip()
            if asn not in asns:
                asns.append(asn)
            if pfx not in prefixes:
                prefixes.append(pfx)
            asn_descs[asn] = desc
    except Exception:
        pass

    try:
        ripe_json = json.loads(http_get(f"https://stat.ripe.net/data/network-info/data.json?resource={ip_str}", timeout=8))
        data = ripe_json.get("data", {})
        for a in data.get("asns", []):
            if str(a) not in asns:
                asns.append(str(a))
        pfx = data.get("prefix")
        if pfx and pfx not in prefixes:
            prefixes.append(pfx)
    except Exception:
        pass

    net24 = str(ipaddress.ip_network(f"{ip_str}/24", strict=False))
    if net24 not in prefixes:
        prefixes.insert(0, net24)
    prefixes.sort(key=lambda x: ipaddress.ip_network(x, strict=False).prefixlen, reverse=True)
    return asns, asn_descs, prefixes

def fetch_neighbor_domains(prefixes):
    found = set()
    for pfx in prefixes:
        try:
            net_obj = ipaddress.ip_network(pfx, strict=False)
            if net_obj.prefixlen < 18:
                continue
        except Exception:
            continue
        try:
            api_url = f"https://bgp.he.net/certs/api/ip-search?ip={urllib.parse.quote(pfx)}"
            raw = http_get(api_url, timeout=10)
            data = json.loads(raw)
            for entry in data.get("entries", []):
                for h in entry.get("hostnames", []):
                    h = h.strip().lower().lstrip("*.")
                    if h and "." in h:
                        found.add(h)
        except Exception:
            continue
        if len(found) >= 120:
            break
    return list(found)

def is_good_domain(domain):
    if not re.match(r'^[a-z0-9][a-z0-9\.\-]{1,61}[a-z0-9]\.[a-z]{2,}$', domain):
        return False
    bad_kw = [
        "nip.io", "sslip.io", "xip.io", "local", "localhost", "arpa",
        "cpanel", "webmail", "whm.", "autodiscover", "autoconfig",
        "mail.", "smtp.", "pop.", "imap.", "mx.", "ns1.", "ns2."
    ]
    if any(k in domain for k in bad_kw):
        return False
    if re.search(r'\d{1,3}[\-\.]\d{1,3}[\-\.]\d{1,3}', domain):
        return False
    return True

def domain_rank_key(domain):
    tld_rank = 0 if domain.endswith(".com") else (1 if domain.endswith(".net") else (2 if domain.endswith(".org") else 3))
    return (tld_rank, len(domain.split(".")), len(domain))

def is_cf_ip(ip_str):
    try:
        ip_obj = ipaddress.ip_address(ip_str)
        return any(ip_obj in net for net in CF_NETS)
    except Exception:
        return False

def check_domain(domain, allowed_nets, my_ip):
    try:
        infos = socket.getaddrinfo(domain, 443, socket.AF_INET, socket.SOCK_STREAM)
        ips = []
        for info in infos:
            ip_val = info[4][0]
            if ip_val not in ips:
                ips.append(ip_val)
    except Exception:
        return None

    target_ip = ""
    for ip_val in ips:
        if ip_val == my_ip or is_cf_ip(ip_val):
            continue
        try:
            ip_obj = ipaddress.ip_address(ip_val)
            if any(ip_obj in net for net in allowed_nets):
                target_ip = ip_val
                break
        except Exception:
            continue

    if not target_ip:
        return None

    try:
        ctx = ssl.create_default_context()
        ctx.minimum_version = ssl.TLSVersion.TLSv1_3
        ctx.maximum_version = ssl.TLSVersion.TLSv1_3
        ctx.set_alpn_protocols(["h2"])

        t0 = time.monotonic()
        with socket.create_connection((target_ip, 443), timeout=3.0) as sock:
            with ctx.wrap_socket(sock, server_hostname=domain) as ssock:
                handshake_ms = (time.monotonic() - t0) * 1000.0
                if ssock.version() != "TLSv1.3" or ssock.selected_alpn_protocol() != "h2":
                    return None

                req = (
                    f"HEAD / HTTP/1.1\r\n"
                    f"Host: {domain}\r\n"
                    f"User-Agent: {UA}\r\n"
                    f"Connection: close\r\n\r\n"
                ).encode("ascii")
                ssock.sendall(req)
                resp = ssock.recv(1024).decode("latin-1", errors="ignore")

                first_line = resp.splitlines()[0] if resp.splitlines() else ""
                if not re.search(r"\b200\b", first_line):
                    return None
                if re.search(r"^server:\s*cloudflare\b", resp, re.I | re.M):
                    return None
    except Exception:
        return None

    return {
        "domain": domain,
        "ip": target_ip,
        "latency_ms": round(handshake_ms, 2),
        "is_com_net": domain.endswith(".com") or domain.endswith(".net")
    }

def main():
    my_ip = get_public_ipv4()
    if not my_ip:
        print("  \033[0;31m❌ 无法获取本机公网 IPv4 地址\033[0m")
        sys.exit(1)

    asns, asn_descs, prefixes = get_asn_and_prefixes(my_ip)
    asn_display = ", ".join([f"AS{a} ({asn_descs.get(a, 'Unknown')})" for a in asns]) if asns else "未知 ASN"
    print(f"  本机公网 IP : \033[1;32m{my_ip}\033[0m")
    print(f"  所属 ASN    : \033[1;32m{asn_display}\033[0m")
    print(f"  关联网段    : \033[1;33m{', '.join(prefixes[:4])}\033[0m")

    raw_domains = fetch_neighbor_domains(prefixes)
    candidates = [d for d in raw_domains if is_good_domain(d)]
    candidates.sort(key=domain_rank_key)
    candidates = candidates[:MAX_CANDIDATES]

    print(f"  原始邻居域名: {len(raw_domains)} 个 | 筛选后探测: {len(candidates)} 个")
    if not candidates:
        print("  \033[0;31m❌ 未检索到可用候选域名\033[0m")
        sys.exit(2)

    allowed_nets = []
    for p in prefixes:
        try:
            allowed_nets.append(ipaddress.ip_network(p, strict=False))
        except Exception:
            continue

    workers = get_safe_workers()
    print(f"  探测并发数  : {workers} 线程 (TLSv1.3 + ALPN h2 + HTTP 200 + 非CDN)")

    passed = []
    with ThreadPoolExecutor(max_workers=workers) as ex:
        futs = {ex.submit(check_domain, d, allowed_nets, my_ip): d for d in candidates}
        for fut in as_completed(futs):
            res = fut.result()
            if res:
                passed.append(res)

    if not passed:
        print("  \033[0;31m❌ 当前网段未筛出满足 TLSv1.3 + h2 + 200 + 非CDN 的域名\033[0m")
        sys.exit(3)

    passed.sort(key=lambda x: (x["latency_ms"], 0 if x["is_com_net"] else 1, len(x["domain"])))
    top3 = passed[:TOP_N]

    print(f"\n  \033[1;32m✓ 同网段可用邻居域名延迟排名 (Top {len(top3)}):\033[0m")
    print("  " + "-" * 68)
    print(f"  {'排名':<6} {'域名 (SNI)':<30} {'解析 IP':<16} {'握手延迟'}")
    print("  " + "-" * 68)
    for idx, item in enumerate(top3, 1):
        medal = "★ #1" if idx == 1 else f"  #{idx}"
        print(f"  {medal:<6} {item['domain']:<30} {item['ip']:<16} {item['latency_ms']} ms")
    print("  " + "-" * 68)

    if OUT_FILE:
        with open(OUT_FILE, "w", encoding="utf-8") as f:
            json.dump(top3, f, ensure_ascii=False)

if __name__ == "__main__":
    main()
PYEOF
    then
        local d1 d2 d3 pick
        d1=$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d[0]["domain"] if len(d)>0 else "")' "$top3_json" 2>/dev/null || true)
        d2=$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d[1]["domain"] if len(d)>1 else "")' "$top3_json" 2>/dev/null || true)
        d3=$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d[2]["domain"] if len(d)>2 else "")' "$top3_json" 2>/dev/null || true)
        [ -n "$d1" ] && LAST_BEST_SNI="$d1"

        echo ""
        read -rp "  是否直接将其中一个域名设为 ShadowTLS SN
