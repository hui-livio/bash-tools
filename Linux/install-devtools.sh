#!/usr/bin/env bash
# =============================================================================
#  install-devtools.sh  --  跨发行版 Linux 开发工具一键安装脚本
#
#  自动检测发行版 / 包管理器，安装常用开发工具链:
#    cmake  make  gcc/g++  gdb  clang  llvm  python3  nodejs  npm  git ...
#
#  支持的包管理器: apt / dnf / yum / zypper / pacman / apk / xbps / emerge
#
#  重点适配三大家族（含各家的包名差异与额外软件源处理）:
#    - Debian 系 : Debian / Ubuntu / Linux Mint / Deepin / UOS / Kali / Raspbian
#                  (build-essential, python3-dev, fd-find, 老版本 nodejs 偏旧可用 --node-lts)
#    - RHEL 系   : CentOS 7/8/9、RHEL、Rocky、AlmaLinux、Oracle Linux、
#                  OpenCloudOS、TencentOS、Anolis、Fedora
#                  (自动装 epel-release、启用 CRB/PowerTools、启用 nodejs 模块流；
#                   CentOS 7 自动改用 pkgconfig 而非 pkgconf-pkg-config)
#    - Arch 系   : Arch Linux / Manjaro / EndeavourOS / Artix
#                  (base-devel, python/pip 无 3 后缀, clang-tools-extra)
#    其余: openSUSE/SLES、Alpine、Void、Gentoo 也已覆盖。
#
#  环境变量:
#    NODEJS_STREAM=20   RHEL8+ 上启用的 Node.js 模块流版本（默认 20）
#
#  用法:
#    bash install-devtools.sh [选项]
#    curl -fsSL <url> | bash -s -- [选项]
#
#  选项:
#    -y, --yes              非交互模式，自动确认（默认会先询问一次）
#    -n, --dry-run          只打印将要执行的命令，不实际安装
#    -m, --minimal          最小集：编译 + 调试（cmake/make/gcc/g++/gdb/python3/git）
#    -f, --full             完整集：额外含 clang-tools/valgrind/静态检查/常用 CLI、
#                           以及 nmap/mtr/iperf3/socat 等进阶网络工具
#    -u, --no-update        跳过软件源索引刷新
#    -l, --list             仅列出将要安装的软件包，不安装
#        --node-lts         从 NodeSource 安装 Node.js LTS（默认用发行版仓库）
#        --with-go          额外安装 Go
#        --with-rust        额外通过 rustup 安装 Rust
#        --with-net          minimal 档也装网络工具（standard/full 默认已含）
#
#  网络工具（standard 及以上默认安装）:
#    net-tools(ifconfig/netstat/arp)  iproute2/iproute(ip/ss)
#    iputils(ping/arping)             dnsutils|bind-utils|bind-tools(dig/nslookup)
#    traceroute  inetutils(telnet/ftp)  lsof  ethtool  tcpdump  whois  wget  rsync
#    full 档追加: nmap  iperf3  socat  mtr  netcat
#        --pm=NAME          强制指定包管理器
#    -h, --help             显示帮助
#    -V, --version          显示版本
#
#  示例:
#    bash install-devtools.sh                 # 标准安装
#    bash install-devtools.sh -m -y           # 最小集，非交互
#    bash install-devtools.sh --pm=apt -n     # 演练，看会执行什么
# =============================================================================

set -euo pipefail

readonly SCRIPT_VERSION="1.3.0"

# ----------------------------- 默认选项 --------------------------------------
DRY_RUN=0
ASSUME_YES=0
DO_UPDATE=1
PROFILE="standard"
NODE_LTS=0
WITH_GO=0
WITH_RUST=0
WITH_NET=0      # minimal 档也要装网络工具时加 --with-net
LIST_ONLY=0
FORCE_PM=""

__OPS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# shellcheck source=/dev/null
source "${__OPS_DIR}/lib/lib.sh"
unset __OPS_DIR
Lib::bootstrap ""
Lib::install_err_trap

log() { info "$*"; }      # 本脚本把 log 当作主输出通道，覆盖 lib 的静默 log

usage() {
    cat <<'EOF'
用法: bash install-devtools.sh [选项]

重点适配: Debian 系(apt) / RHEL 系(dnf,yum: 自动 EPEL+CRB+nodejs 模块流)
          / Arch 系(pacman)；另支持 openSUSE(zypper)、Alpine(apk)、Void(xbps)、Gentoo(emerge)

选项:
  -y, --yes          非交互模式，自动确认
  -n, --dry-run      只打印将要执行的命令，不实际安装
  -m, --minimal      最小集：编译 + 调试
  -f, --full         完整集：额外含 clang-tools / valgrind / 常用 CLI
  -u, --no-update    跳过软件源索引刷新
  -l, --list         仅列出将要安装的软件包
      --node-lts     从 NodeSource 安装 Node.js LTS
      --with-go      额外安装 Go
      --with-rust    额外通过 rustup 安装 Rust
      --with-net     minimal 档也装网络工具（standard/full 默认已含）
      --pm=NAME      强制指定包管理器: apt|dnf|yum|zypper|pacman|apk|xbps|emerge
  -h, --help         显示帮助
  -V, --version      显示版本

示例:
  bash install-devtools.sh                 # 标准安装
  bash install-devtools.sh -m -y           # 最小集，非交互
  bash install-devtools.sh --pm=apt -n     # 演练，看会执行什么
EOF
    exit 0
}

# ----------------------------- 参数解析 --------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)      usage ;;
        -V|--version)   echo "install-devtools.sh v$SCRIPT_VERSION"; exit 0 ;;
        -y|--yes)       ASSUME_YES=1; shift ;;
        -n|--dry-run)   DRY_RUN=1;    shift ;;
        -m|--minimal)   PROFILE="minimal";  shift ;;
        -f|--full)      PROFILE="full";     shift ;;
        -u|--no-update) DO_UPDATE=0;  shift ;;
        -l|--list)      LIST_ONLY=1;  shift ;;
        --node-lts)     NODE_LTS=1;   shift ;;
        --with-go)      WITH_GO=1;    shift ;;
        --with-rust)    WITH_RUST=1;  shift ;;
        --with-net)     WITH_NET=1;   shift ;;
        --pm)           [[ $# -ge 2 ]] || die "--pm 缺少参数"; FORCE_PM="$2"; shift 2 ;;
        --pm=*)         FORCE_PM="${1#--pm=}"; shift ;;
        --)             shift; break ;;
        *)              die "未知参数: $1 （用 -h 查看帮助）" ;;
    esac
done

# ----------------------------- 环境检查 --------------------------------------
[[ "$(uname -s)" == "Linux" ]] || die "本脚本仅支持 Linux，当前系统: $(uname -s)"

if [[ ${EUID} -eq 0 ]]; then
    SUDO=""
elif command -v sudo >/dev/null 2>&1; then
    SUDO="sudo"
else
    die "需要 root 权限，且系统未安装 sudo。请以 root 身份运行。"
fi

# apt/dpkg 在非交互下不要弹配置界面
export DEBIAN_FRONTEND=noninteractive

# ----------------------------- 发行版探测 ------------------------------------
# 注意：这里刻意不 source /etc/os-release。
# 该文件含 VERSION / NAME 等字段，source 会污染脚本变量，
# 甚至与同名 readonly 变量冲突而直接报错（例如 Debian/Ubuntu 上的 VERSION）。
# 改为纯读取解析，安全且无副作用。
os_field() { OS::osrel "$1" "${2:-/etc/os-release}"; }

OS_NAME="unknown"; OS_VERSION=""; OS_ID=""; OS_ID_LIKE=""; OS_MAJOR=""
detect_os() {
    # os-release 解析统一走 lib/20-os.sh 的 OS 对象（不再各自 source /etc/os-release）
    OS_ID="${SYS[id]}";       OS_ID_LIKE="${SYS[id_like]}"
    OS_NAME="${SYS[name]}";   OS_VERSION="${SYS[version]}"
    OS_MAJOR="${SYS[major]}"; OS_FAMILY="${SYS[family]}"
}

OS_NAME="unknown"; OS_VERSION=""; OS_ID=""; OS_ID_LIKE=""; OS_MAJOR=""
detect_os() {
    if [[ -r /etc/os-release ]]; then
        OS_NAME="$(os_field NAME || echo unknown)"
        OS_VERSION="$(os_field VERSION_ID || true)"
        OS_ID="$(os_field ID || true)"
        OS_ID_LIKE="$(os_field ID_LIKE || true)"
    elif command -v lsb_release >/dev/null 2>&1; then
        OS_NAME="$(lsb_release -si)"
        OS_VERSION="$(lsb_release -sr)"
        OS_ID="$(printf '%s' "$OS_NAME" | tr '[:upper:]' '[:lower:]')"
        OS_ID_LIKE=""
    elif [[ -r /etc/redhat-release ]]; then
        OS_NAME="$(cat /etc/redhat-release)"
        OS_ID="rhel"; OS_ID_LIKE="rhel fedora"
    fi
    OS_MAJOR="${OS_VERSION%%.*}"          # 24.04 -> 24 ; 9.3 -> 9 ; rolling -> rolling
}

# 是否属于 RHEL 系（CentOS / Rocky / Alma / Oracle / OpenCloudOS / TencentOS / Anolis 等）
# 注意排除 Fedora：Fedora 自带这些包，无需 EPEL / 模块流
is_rhel_family() {
    # Fedora 的 ID_LIKE 也含 rhel，但它自带这些包，必须先排除
    [[ "$OS_ID" == "fedora" || "$OS_ID" == "nobara" ]] && return 1
    case " $OS_ID $OS_ID_LIKE " in
        *" rhel "*|*" centos "*) return 0 ;;
    esac
    case "$OS_ID" in
        rocky|almalinux|ol|oracle*|scientific|virtuozzo|cloudlinux|opencloudos|tencentos|anolis|openanolis)
            return 0 ;;
    esac
    return 1
}

# ----------------------------- 包管理器探测 ----------------------------------
PM=""
detect_pm() {
    if [[ -n "$FORCE_PM" ]]; then
        case "$FORCE_PM" in
            apt|dnf|yum|zypper|pacman|apk|xbps|emerge) ;;
            *) die "不支持的 --pm 值: $FORCE_PM（可选: apt|dnf|yum|zypper|pacman|apk|xbps|emerge）" ;;
        esac
        PM="$FORCE_PM"
        sys::has_cmd "$PM" || sys::has_cmd "${PM}-get" \
            || warn "强制指定的包管理器 $PM 似乎不存在，仍按指定执行"
        return 0
    fi
    PM="$(OS::detect_pm "${OS_FAMILY:-unknown}" "")"
    if [[ -z "$PM" ]]; then die "未识别到受支持的包管理器"; fi
}

# ----------------------------- 命令执行封装 ----------------------------------
# run: 打印并执行；dry-run 时只打印
run() {
    # dry-run 渲染 + 命令日志统一走 lib/40-exec.sh 的 Runner
    RUN[dry_run]="${DRY_RUN:-0}"
    Runner::exec RUN "$@"
}
# run_priv: 需要权限时自动加 sudo
run_priv() {
    if [[ -z "$SUDO" ]]; then run "$@"; else run "$SUDO" "$@"; fi
}

# ----------------------------- 软件包清单 ------------------------------------
declare -a PKGS=()

build_pkgs() {
    local -a base=() std=() extra=() net=() netfull=() gopkg=""

    case "$PM" in
    # ---------------- Debian / Ubuntu / 衍生版 ----------------
    apt)
        base=(build-essential cmake make gdb git)
        std=(clang llvm lldb lld
             python3 python3-pip python3-venv python3-dev
             nodejs npm
             pkg-config ninja-build ccache curl ca-certificates)
        extra=(valgrind strace doxygen graphviz
               clang-tools clang-format clang-tidy clangd
               autoconf automake libtool flex bison patch
               jq zip unzip ripgrep fd-find tmux tree file rsync)
        # 网络工具（注意避开互斥包：iputils-ping 与 inetutils-ping 冲突、
        # traceroute 与 inetutils-traceroute 冲突，这里各选其一）
        net=(net-tools iproute2 iputils-ping iputils-arping
             dnsutils traceroute
             inetutils-telnet inetutils-ftp
             lsof ethtool tcpdump whois wget rsync)
        netfull=(nmap iperf3 socat mtr-tiny netcat-openbsd httping)
        gopkg="golang-go"
        ;;
    # ---------------- RHEL 系：CentOS / RHEL / Rocky / Alma / Oracle / Fedora ----------------
    dnf|yum)
        # CentOS 7 / RHEL 7 及更老：pkg-config 包名不同，且 llvm-tools / nodejs 需 EPEL
        local pkgcfg="pkgconf-pkg-config"
        local llvm_tools="llvm-tools"
        if [[ "$PM" == "yum" ]]; then
            pkgcfg="pkgconfig"
            llvm_tools="llvm"
        fi
        base=(gcc gcc-c++ make cmake gdb git)
        std=(clang llvm "$llvm_tools" lldb lld
             python3 python3-pip python3-devel
             nodejs nodejs-npm
             "$pkgcfg" ninja-build ccache curl ca-certificates)
        extra=(valgrind strace doxygen graphviz
               clang-tools-extra clang-devel
               autoconf automake libtool flex bison patch
               jq zip unzip ripgrep fd-find tmux tree file rsync)
        # RHEL 系：iproute（不是 iproute2）、bind-utils（dig）、telnet/ftp 独立成包
        net=(net-tools iproute iputils bind-utils traceroute
             telnet ftp lsof ethtool tcpdump whois wget rsync)
        netfull=(nmap iperf3 socat mtr nmap-ncat)
        gopkg="golang"
        ;;
    # ---------------- openSUSE / SLES ----------------
    zypper)
        base=(gcc gcc-c++ make cmake gdb git)
        std=(clang llvm llvm-tools lldb lld
             python3 python3-pip python3-devel
             nodejs nodejs-npm
             pkg-config ninja ccache curl ca-certificates)
        extra=(valgrind strace doxygen graphviz
               clang-tools
               autoconf automake libtool flex bison patch
               jq zip unzip ripgrep fd tmux tree file rsync)
        net=(net-tools iproute2 iputils bind-utils traceroute
             telnet ftp lsof ethtool tcpdump whois wget rsync)
        netfull=(nmap iperf3 socat mtr netcat-openbsd)
        gopkg="go"
        ;;
    # ---------------- Arch / Manjaro ----------------
    pacman)
        base=(gcc make cmake gdb git)
        std=(clang llvm lldb lld
             python python-pip
             nodejs npm
             pkgconf ninja ccache curl ca-certificates)
        extra=(valgrind strace doxygen graphviz
               clang-tools-extra
               autoconf automake libtool flex bison patch
               jq zip unzip ripgrep fd tmux tree file rsync)
        # Arch：inetutils 提供 ftp/telnet/hostname，bind-tools 提供 dig
        net=(net-tools iproute2 iputils bind-tools traceroute inetutils
             lsof ethtool tcpdump whois wget rsync)
        netfull=(nmap iperf3 socat mtr gnu-netcat)
        gopkg="go"
        ;;
    # ---------------- Alpine ----------------
    apk)
        base=(gcc g++ make cmake gdb git)
        std=(clang llvm lldb lld
             python3 py3-pip py3-virtualenv python3-dev
             nodejs npm
             pkgconf ninja ccache curl ca-certificates)
        extra=(valgrind strace doxygen graphviz
               clang-extra-tools
               autoconf automake libtool flex bison patch
               jq zip unzip ripgrep fd tmux tree file rsync)
        net=(net-tools iproute2 iputils bind-tools traceroute
             lsof ethtool tcpdump whois wget rsync netcat-openbsd)
        netfull=(nmap iperf3 socat mtr)
        gopkg="go"
        ;;
    # ---------------- Void Linux ----------------
    xbps)
        base=(gcc make cmake gdb git)
        std=(clang llvm lldb lld
             python3 python3-pip python3-devel
             nodejs
             pkg-config ninja ccache curl ca-certificates)
        extra=(valgrind strace doxygen graphviz
               clang-tools-extra
               autoconf automake libtool flex bison patch
               jq zip unzip ripgrep fd tmux tree file rsync)
        net=(net-tools iproute2 iputils bind-tools traceroute inetutils
             lsof ethtool tcpdump whois wget rsync)
        netfull=(nmap iperf3 socat mtr gnu-netcat)
        gopkg="go"
        ;;
    # ---------------- Gentoo ----------------
    emerge)
        base=(sys-devel/gcc sys-devel/make dev-util/cmake sys-devel/gdb dev-vcs/git)
        std=(sys-devel/clang sys-devel/llvm sys-devel/lldb sys-devel/lld
             dev-lang/python dev-lang/nodejs
             dev-util/pkgconf dev-util/ninja dev-util/ccache net-misc/curl)
        extra=(dev-util/valgrind dev-util/strace app-doc/doxygen media-gfx/graphviz
               sys-devel/clang-tools-extra
             sys-devel/autoconf sys-devel/automake sys-devel/libtool
             sys-devel/flex sys-devel/bison sys-devel/patch
             jq zip unzip ripgrep fd tmux tree file rsync)
        net=(net-misc/net-tools net-misc/iproute2 net-misc/iputils
             net-dns/bind-tools net-analyzer/traceroute net-misc/telnet-bsd
             net-misc/whois net-analyzer/tcpdump net-misc/wget net-misc/rsync)
        netfull=(net-analyzer/nmap net-misc/iperf3 net-misc/socat net-analyzer/mtr)
        gopkg="dev-lang/go"
        ;;
    *)
        die "暂不支持的包管理器: ${PM:-未检测到}" ;;
    esac

    PKGS=("${base[@]}")
    if [[ "$PROFILE" == "standard" || "$PROFILE" == "full" ]]; then
        PKGS+=("${std[@]}" "${net[@]}")
    fi
    if [[ "$PROFILE" == "full" ]]; then
        PKGS+=("${extra[@]}" "${netfull[@]}")
    fi
    if [[ "$WITH_NET" == "1" ]]; then   # minimal 档也想装网络工具时用
        PKGS+=("${net[@]}")
    fi
    if [[ "$WITH_GO" == "1" && -n "$gopkg" ]]; then
        PKGS+=("$gopkg")
    fi

    # 去重（保持原有顺序，例如 yum 分支下 llvm 可能出现两次）
    local -a uniq_pkgs=()
    local seen=" " q
    for q in "${PKGS[@]}"; do
        [[ "$seen" == *" $q "* ]] && continue
        seen+="$q "
        uniq_pkgs+=("$q")
    done
    PKGS=("${uniq_pkgs[@]}")

    # --node-lts 时从发行版仓库中移除 nodejs/npm，改走 NodeSource
    if [[ "$NODE_LTS" == "1" ]]; then
        local -a filtered=()
        local p
        for p in "${PKGS[@]}"; do
            [[ "$p" == "nodejs" || "$p" == "npm" || "$p" == "nodejs-npm" ]] || filtered+=("$p")
        done
        PKGS=("${filtered[@]}")
    fi
}

# ----------------------------- 已安装检测 ------------------------------------
pkg_installed() {
    if [[ "$DRY_RUN" == "1" ]]; then return 1; fi
    local p="$1"
    case "$PM" in
        apt)            dpkg -s "$p" >/dev/null 2>&1 ;;
        dnf|yum|zypper) rpm -q  "$p" >/dev/null 2>&1 ;;
        pacman)         pacman -Qi "$p" >/dev/null 2>&1 ;;
        apk)            apk info -e "$p" >/dev/null 2>&1 ;;
        xbps)           xbps-query "$p" >/dev/null 2>&1 ;;
        *)              return 1 ;;   # emerge 等不做预检
    esac
}

# ----------------------------- 刷新软件源 ------------------------------------
pm_update() {
    log "刷新软件源索引 ..."
    case "$PM" in
        apt)    run_priv apt-get update -y || warn "apt-get update 失败，继续尝试安装" ;;
        dnf)    run_priv dnf -y check-update || true ;;
        yum)    run_priv yum -y check-update || true ;;
        zypper) run_priv zypper --non-interactive refresh || warn "zypper refresh 失败，继续尝试安装" ;;
        pacman) run_priv pacman -Sy --noconfirm || warn "pacman -Sy 失败，继续尝试安装" ;;
        apk)    run_priv apk update || warn "apk update 失败，继续尝试安装" ;;
        xbps)   run_priv xbps-install -S || warn "xbps-install -S 失败，继续尝试安装" ;;
        emerge) warn "Gentoo 上跳过 emerge --sync（耗时很长），请自行同步 portage" ;;
    esac
}

# ----------------------------- 额外软件源准备 --------------------------------
# RHEL 系默认源里没有 ninja-build / nodejs / 部分开发包，需要 EPEL；
# RHEL 8+ 还需要 CRB(PowerTools) 仓库，并且 Node.js 走 dnf module 流。
prepare_repos() {
    is_rhel_family || return 0
    [[ "$NODE_LTS" == "1" ]] && return 0      # 走 NodeSource 就不需要模块流了

    local stream="${NODEJS_STREAM:-20}"
    case "$PM" in
        dnf)
            log "RHEL 系：启用 EPEL / CRB 源 ..."
            run_priv dnf -y install epel-release || warn "epel-release 安装失败，ninja-build / nodejs 等可能不可用"
            run_priv dnf -y install dnf-plugins-core || true
            run_priv dnf config-manager --set-enabled crb        || true   # RHEL9 / CentOS9
            run_priv dnf config-manager --set-enabled powertools || true   # RHEL8 / CentOS8
            log "RHEL 系：启用 Node.js ${stream} 模块流 ..."
            run_priv dnf -y module reset nodejs  || true
            run_priv dnf -y module enable "nodejs:${stream}" \
                || warn "nodejs:${stream} 模块启用失败，将安装仓库默认版本"
            ;;
        yum)
            log "RHEL 7 系：安装 EPEL 源 ..."
            run_priv yum -y install epel-release || warn "epel-release 安装失败，ninja-build / nodejs 等可能不可用"
            ;;
    esac
}

# ----------------------------- 安装工具组 ------------------------------------
install_groups() {
    local -a gcmd=()
    case "$PM" in
        dnf)    gcmd=(dnf -y install @"Development Tools") ;;
        yum)    gcmd=(yum -y groupinstall "Development Tools") ;;
        pacman) gcmd=(pacman -S --needed --noconfirm base-devel) ;;
        zypper) gcmd=(zypper -n install -t pattern devel_basis) ;;
        apk)    gcmd=(apk add build-base) ;;
        xbps)   gcmd=(xbps-install -Sy base-devel) ;;
        *)      return 0 ;;   # apt 的 build-essential 已在包列表中
    esac
    log "安装开发工具组 ..."
    if ! run_priv "${gcmd[@]}"; then
        warn "工具组安装未完全成功，将继续安装具体软件包"
    fi
}

# ----------------------------- 构建安装命令 ----------------------------------
CMD=()
build_install_cmd() {
    case "$PM" in
        apt)    CMD=(apt-get install -y "$@") ;;
        dnf)    CMD=(dnf install -y "$@") ;;
        yum)    CMD=(yum install -y "$@") ;;
        zypper) CMD=(zypper --non-interactive install "$@") ;;
        pacman) CMD=(pacman -S --needed --noconfirm "$@") ;;
        apk)    CMD=(apk add "$@") ;;
        xbps)   CMD=(xbps-install -Sy "$@") ;;
        emerge) CMD=(emerge -n "$@") ;;
        *)      return 1 ;;
    esac
}

# ----------------------------- 批量安装 + 逐个回退 ----------------------------
FAILED_PKGS=()
install_pkgs() {
    local -a pkgs=("$@")
    [[ ${#pkgs[@]} -eq 0 ]] && return 0

    build_install_cmd "${pkgs[@]}"
    log "安装 ${#pkgs[@]} 个软件包 ..."
    if run_priv "${CMD[@]}"; then
        ok "批量安装完成"
        return 0
    fi

    warn "批量安装失败，改为逐个安装（单个包失败不会中断其余安装）"
    local p
    for p in "${pkgs[@]}"; do
        if pkg_installed "$p"; then
            ok "已安装: $p"
            continue
        fi
        build_install_cmd "$p"
        if run_priv "${CMD[@]}"; then
            ok "$p"
        else
            err "$p 安装失败（可能是该仓库无此包名）"
            FAILED_PKGS+=("$p")
        fi
    done
}

# ----------------------------- Node.js LTS -----------------------------------
install_node_lts() {
    log "从 NodeSource 安装 Node.js LTS ..."
    case "$PM" in
        apt)
            run_priv bash -c 'curl -fsSL https://deb.nodesource.com/setup_lts.x | bash -'
            build_install_cmd nodejs
            run_priv "${CMD[@]}" || FAILED_PKGS+=("nodejs(NodeSource)")
            ;;
        dnf|yum)
            run_priv bash -c 'curl -fsSL https://rpm.nodesource.com/setup_lts.x | bash -'
            build_install_cmd nodejs
            run_priv "${CMD[@]}" || FAILED_PKGS+=("nodejs(NodeSource)")
            ;;
        *)
            warn "当前包管理器(${PM})未内置 NodeSource 源，改为安装发行版仓库的 nodejs"
            build_install_cmd nodejs
            run_priv "${CMD[@]}" || FAILED_PKGS+=("nodejs")
            ;;
    esac
}

# ----------------------------- Rust (可选) -----------------------------------
install_rust() {
    log "通过 rustup 安装 Rust ..."
    if [[ "$DRY_RUN" == "1" ]]; then
        printf '%s$ curl https://sh.rustup.rs | sh -s -- -y%s\n' "$C_GRAY" "$C_RESET"
        return 0
    fi
    # rustup 必须以普通用户身份安装（装到 $HOME），不要 sudo
    run bash -c 'curl --proto "=https" --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y'
    # shellcheck disable=SC1091
    [[ -r "$HOME/.cargo/env" ]] && . "$HOME/.cargo/env"
}

# ----------------------------- 版本校验 --------------------------------------
verify() {
    local -a bins=(cmake make gcc g++ gdb clang python3 node git curl)
    local b v
    printf '\n%s=============== 版本校验 ===============%s\n' "$C_BLUE" "$C_RESET"
    for b in "${bins[@]}"; do
        if command -v "$b" >/dev/null 2>&1; then
            case "$b" in
                make)   v="$(make --version      2>/dev/null | head -n1 || true)" ;;
                node)   v="node $(node --version 2>/dev/null || true)" ;;
                python3) v="python3 $(python3 --version 2>&1 | awk '{print $2}' || true)" ;;
                *)      v="$("$b" --version     2>/dev/null | head -n1 || true)" ;;
            esac
            printf '  %s%-8s%s %s\n' "$C_GREEN" "$b" "$C_RESET" "${v:-已安装}"
        else
            printf '  %s%-8s%s %s\n' "$C_YELLOW" "$b" "$C_RESET" "未安装 / 不在 PATH"
        fi
    done

    # 网络工具：只报有无，版本信息意义不大
    if [[ "$PROFILE" != "minimal" || "$WITH_NET" == "1" ]]; then
        printf '%s---- 网络工具 ----%s\n' "$C_BLUE" "$C_RESET"
        local -a netbins=(ip ifconfig netstat ss ping arping dig nslookup
                          traceroute telnet ftp lsof ethtool tcpdump whois wget nc nmap)
        local nb
        for nb in "${netbins[@]}"; do
            if command -v "$nb" >/dev/null 2>&1; then
                printf '  %s%-10s%s %s\n' "$C_GREEN" "$nb" "$C_RESET" "$(command -v "$nb")"
            else
                printf '  %s%-10s%s %s\n' "$C_YELLOW" "$nb" "$C_RESET" "未安装"
            fi
        done
    fi
    printf '%s======================================%s\n' "$C_BLUE" "$C_RESET"
}

# ============================== 主流程 =======================================
main() {
    detect_os
    detect_pm || die "未能检测到受支持的包管理器（apt/dnf/yum/zypper/pacman/apk/xbps/emerge）"

    build_pkgs

    printf '%s\n' "-----------------------------------------------"
    printf ' 系统      : %s %s\n' "$OS_NAME" "$OS_VERSION"
    printf ' 内核      : %s (%s)\n' "$(uname -r)" "$(uname -m)"
    printf ' 包管理器  : %s\n' "$PM"
    printf ' 安装档位  : %s\n' "$PROFILE"
    printf ' 软件包(%d) : %s\n' "${#PKGS[@]}" "${PKGS[*]}"
    printf '%s\n' "-----------------------------------------------"

    if [[ "$LIST_ONLY" == "1" ]]; then
        printf '%s\n' "${PKGS[@]}"
        exit 0
    fi

    if [[ "$ASSUME_YES" == "0" && "$DRY_RUN" == "0" ]]; then
        printf '确认开始安装？[y/N] '
        read -r ans
        [[ "$ans" == "y" || "$ans" == "Y" || "$ans" == "yes" ]] || { log "已取消"; exit 0; }
    fi

    # 预检：过滤掉已安装的包
    local -a todo=() skipped=() p
    for p in "${PKGS[@]}"; do
        if pkg_installed "$p"; then skipped+=("$p"); else todo+=("$p"); fi
    done
    if [[ ${#skipped[@]} -gt 0 ]]; then
        log "已安装，跳过 ${#skipped[@]} 个: ${skipped[*]}"
    fi

    if [[ "$DO_UPDATE" == "1" ]]; then pm_update; fi

    prepare_repos
    install_groups

    if [[ ${#todo[@]} -gt 0 ]]; then
        install_pkgs "${todo[@]}"
    else
        ok "所有软件包均已安装"
    fi

    if [[ "$NODE_LTS" == "1" ]]; then install_node_lts; fi
    if [[ "$WITH_RUST" == "1" ]];  then install_rust;    fi

    verify

    if [[ ${#FAILED_PKGS[@]} -gt 0 ]]; then
        warn "以下软件包安装失败: ${FAILED_PKGS[*]}"
        warn "可手动确认该发行版下的正确包名后重试"
        exit 1
    fi

    ok "全部完成！建议重新打开终端或执行: source ~/.bashrc"
}

main "$@"


# =============================================================================
#  面板声明（供 panel.sh 自动发现，不参与脚本执行）
# =============================================================================
# PANEL: 开发工具 | 开发环境 | 1 | cmake/gcc/clang/python/node 等工具链
# PANEL-CMD: 标准集 |  | 编译 + 调试 + 常用 CLI + 网络工具
# PANEL-CMD: 最小集 | -m | cmake/make/gcc/g++/gdb/python3/git
# PANEL-CMD: 完整集 | -f | 追加静态检查、valgrind、nmap/iperf3 等
# PANEL-CMD: 仅列出将要安装的包 | -l | 只读预览
# PANEL-CMD: 额外装 Node.js LTS | --node-lts | 走 NodeSource 而非发行版仓库
