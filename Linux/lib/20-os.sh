#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
#  lib/20-os.sh —— 类 OS：发行版 / 家族 / 包管理器 / 架构 / WSL / 容器 检测
#
#  本目录下原有 7 份几乎相同的 detect_os / detect_pm / os_field / osrel_get，
#  全部收敛为这一个对象。
#
#  字段:
#    id            ubuntu / debian / rhel / arch ...（os-release 的 ID）
#    id_like       os-release 的 ID_LIKE
#    name          PRETTY_NAME
#    version       VERSION_ID
#    major         主版本号（24.04→24，9.3→9）
#    codename      Debian/Ubuntu 代号（bookworm / noble ...）
#    family        debian | rhel | suse | arch | alpine | void | gentoo | unknown
#    pm            apt | dnf | yum | zypper | pacman | apk | xbps | emerge
#    arch          x86_64 / aarch64 ...
#    wsl           0|1（含版本 1/2）
#    wsl_version   空 | 1 | 2
#    container     none | docker | lxc | systemd-nspawn ...
#    init          systemd | openrc | sysv | unknown
#    virt          none | kvm | ...
#
#  用法:
#    OS::new SYS            ; OS::detect SYS
#    echo "${SYS[family]} ${SYS[pm]}"
# =============================================================================

[[ -n "${__LIB_OS_LOADED:-}" ]] && return 0
__LIB_OS_LOADED=1

# -----------------------------------------------------------------------------
# 读取 /etc/os-release 的键（去引号、去 CR）。找不到返回 1。
# -----------------------------------------------------------------------------
# os-release 解析结果缓存：OS::detect 会连续查 7 个字段，
# 每次都重读文件在网络文件系统 / WSL 下会明显拖慢启动，这里读一次存进关联数组。
declare -gA OS_OSREL=()
declare -g  OS_OSREL_FILE=""
declare -g  OS_OSREL_LOADED=0

OS::osrel_load() {
    local file="${1:-/etc/os-release}" line key val
    [[ -r "$file" ]] || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" == *=* ]] || continue
        key="${line%%=*}"; val="${line#*=}"
        val="${val%$'\r'}"
        [[ "$val" == '"'*'"' ]] && val="${val:1:${#val}-2}"
        [[ "$val" == "'"*"'" ]] && val="${val:1:${#val}-2}"
        OS_OSREL["$key"]="$val"
    done < "$file"
    OS_OSREL_FILE="$file"; OS_OSREL_LOADED=1
    return 0
}

# 写回变量版：OS::osrel_var <变量名> <键> [文件]
#   与 OS::osrel 的区别是不用命令替换，省一次 fork（OS::detect 里要查 7 个字段）
OS::osrel_var() {
    local -n __self_OS_osrel_var=$1
    local key="$2" file="${3:-/etc/os-release}" val=""
    case "$file" in
        /etc/os-release|/usr/lib/os-release)
            if [[ "$OS_OSREL_LOADED" != "1" || "$OS_OSREL_FILE" != "$file" ]]; then
                OS_OSREL=(); OS::osrel_load "$file" || return 1
            fi
            val="${OS_OSREL[$key]:-}"
            [[ -n "$val" ]] || return 1 ;;
        *)
            local line
            [[ -r "$file" ]] || return 1
            while IFS= read -r line || [[ -n "$line" ]]; do
                [[ "$line" == "$key="* ]] || continue
                val="${line#*=}"
                val="${val%$'\r'}"
                [[ "$val" == '"'*'"' ]] && val="${val:1:${#val}-2}"
                [[ "$val" == "'"*"'" ]] && val="${val:1:${#val}-2}"
                break
            done < "$file" ;;
    esac
    printf -v __self_OS_osrel_var '%s' "$val"
    return 0
}

OS::osrel() {
    local key="$1" file="${2:-/etc/os-release}"
    case "$file" in
        /etc/os-release|/usr/lib/os-release)
            if [[ "$OS_OSREL_LOADED" != "1" || "$OS_OSREL_FILE" != "$file" ]]; then
                OS_OSREL=(); OS::osrel_load "$file" || return 1
            fi
            if [[ -n "${OS_OSREL[$key]:-}" ]]; then
                printf '%s' "${OS_OSREL[$key]}"
                return 0
            fi
            return 1 ;;
    esac
    # 非标准路径（调试/测试用）：退回逐行解析
    local line val
    [[ -r "$file" ]] || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" == "$key="* ]] || continue
        val="${line#*=}"
        val="${val%$'\r'}"
        [[ "$val" == '"'*'"' ]] && val="${val:1:${#val}-2}"
        [[ "$val" == "'"*"'" ]] && val="${val:1:${#val}-2}"
        printf '%s' "$val"
        return 0
    done < "$file"
    return 1
}
os_field()  { OS::osrel "$1" "${2:-/etc/os-release}"; }   # 历史别名
osrel_get() { OS::osrel "$1" "${2:-/etc/os-release}"; }   # 历史别名

# -----------------------------------------------------------------------------
# 构造函数
# -----------------------------------------------------------------------------
OS::new() {
    local -n __self_OS_new=$1
    declare -gA "$1"
    __self_OS_new[id]="unknown";  __self_OS_new[id_like]="";   __self_OS_new[name]="未知"
    __self_OS_new[version]="";    __self_OS_new[major]="";     __self_OS_new[codename]=""
    __self_OS_new[family]="unknown"; __self_OS_new[pm]="";     __self_OS_new[arch]=""
    __self_OS_new[wsl]=0;         __self_OS_new[wsl_version]=""
    __self_OS_new[container]="none"; __self_OS_new[init]="unknown"; __self_OS_new[virt]="none"
    __self_OS_new[pretty]="未知 Linux"
}

# -----------------------------------------------------------------------------
# 家族判定： OS::family_of <id> <id_like>  → 输出家族名
# -----------------------------------------------------------------------------
OS::family_of_var() {
    # 注意：内部变量一律加 __ 前缀。nameref 按「名字」动态解析，
    # 若这里再声明一个与调用方同名的局部变量（如 fam），会把结果写回局部变量而不是调用方的。
    local -n __self_OS_family_of_var=$1
    local __id __like __sig __fam="unknown"
    __id="${2:-}"; __like="${3:-}"
    __id="${__id,,}"; __like="${__like,,}"   # 统一小写，避免 Ubuntu / openSUSE 这类大小写差异漏判
    __sig=" ${__id} ${__like} "
    __sig="${__sig//  / }"
    local __sig2="$__sig"
    case "$__sig2" in
        *" debian "*|*" ubuntu "*|*" mint "*|*" raspbian "*|*" kali "*|*" deepin "*|*" uos "*|*" devuan "*)
            __fam=debian ;;
        *" rhel "*|*" fedora "*|*" centos "*|*" amzn "*|*" openeuler "*|*" anolis "*|*" kylin "*|*" opencloudos "*|*" tencentos "*|*" nobara "*|*" rocky "*|*" almalinux "*)
            __fam=rhel ;;
        *" suse "*|*" opensuse "*|*" sles "*)
            __fam=suse ;;
        *" arch "*|*" manjaro "*|*" artix "*|*" endeavouros "*|*" garuda "*|*" cachyos "*)
            __fam=arch ;;
        *" alpine "*)   __fam=alpine ;;
        *" void "*)     __fam=void   ;;
        *" gentoo "*)   __fam=gentoo ;;
        *)              __fam=unknown ;;
    esac
    printf -v __self_OS_family_of_var '%s' "$__fam"
    return 0
}

# 打印版（供命令替换使用；新代码建议用 OS::family_of_var 省一次 fork）
OS::family_of() {
    local __fam_p=""
    OS::family_of_var __fam_p "${1:-}" "${2:-}"
    printf '%s' "$__fam_p"
}

# -----------------------------------------------------------------------------
# 包管理器探测（可强制指定）
# -----------------------------------------------------------------------------
OS::detect_pm_var() {
    # 内部变量加 __ 前缀，避免与调用方传进来的变量名撞车（nameref 按名字解析）
    local -n __self_OS_detect_pm_var=$1
    local __fam="${2:-unknown}" __force="${3:-}"
    local __pm="" __p
    if [[ -n "$__force" ]]; then
        case "$__force" in
            apt|dnf|yum|zypper|pacman|apk|xbps|emerge) __pm="$__force" ;;
            *) return 1 ;;
        esac
        printf -v __self_OS_detect_pm_var '%s' "$__pm"
        return 0
    fi

    # 1) 优先按家族选，避免多包管理器共存时选错
    case "$__fam" in
        debian) sys::has_cmd apt-get && __pm="apt" ;;
        rhel)   if sys::has_cmd dnf; then __pm="dnf"; elif sys::has_cmd yum; then __pm="yum"; fi ;;
        suse)   sys::has_cmd zypper && __pm="zypper" ;;
        arch)   sys::has_cmd pacman && __pm="pacman" ;;
        alpine) sys::has_cmd apk && __pm="apk" ;;
        void)   sys::has_cmd xbps-install && __pm="xbps" ;;
        gentoo) sys::has_cmd emerge && __pm="emerge" ;;
    esac

    # 2) 兜底：按可执行文件探测
    if [[ -z "$__pm" ]]; then
        for __p in apt-get dnf yum zypper pacman apk xbps-install emerge; do
            if sys::has_cmd "$__p"; then
                case "$__p" in
                    apt-get)      __pm="apt"  ;;
                    xbps-install) __pm="xbps" ;;
                    *)            __pm="$__p" ;;
                esac
                break
            fi
        done
    fi
    [[ -n "$__pm" ]] || return 1
    printf -v __self_OS_detect_pm_var '%s' "$__pm"
    return 0
}

# 打印版（供命令替换使用）
OS::detect_pm() {
    local __pm_p=""
    if OS::detect_pm_var __pm_p "${1:-unknown}" "${2:-}"; then printf '%s' "$__pm_p"; return 0; fi
    return 1
}

# -----------------------------------------------------------------------------
# 主检测
# -----------------------------------------------------------------------------
OS::detect() {
    local -n __self_OS_detect=$1
    local force_pm="${2:-${FORCE_PM:-}}"

    # —— os-release ——
    # 全部走 osrel_var（写回变量）而不是命令替换：省掉 6~7 次 fork
    local _id="" _like="" _name="" _ver="" _code="" _pretty=""
    if [[ -r /etc/os-release ]]; then
        OS::osrel_var _id    ID        || _id="unknown"
        OS::osrel_var _like  ID_LIKE   || true
        OS::osrel_var _name  NAME      || true
        OS::osrel_var _ver   VERSION_ID || true
        if ! OS::osrel_var _code UBUNTU_CODENAME; then OS::osrel_var _code DEBIAN_CODENAME || true; fi
        if ! OS::osrel_var _pretty PRETTY_NAME; then _pretty="${_name} ${_ver}"; fi
        __self_OS_detect[id]="$_id";   __self_OS_detect[id_like]="$_like"
        __self_OS_detect[name]="$_name"; __self_OS_detect[version]="$_ver"
        __self_OS_detect[codename]="$_code"; __self_OS_detect[pretty]="$_pretty"
    elif sys::has_cmd lsb_release; then
        __self_OS_detect[name]="$(lsb_release -si 2>/dev/null || true)"
        __self_OS_detect[version]="$(lsb_release -sr 2>/dev/null || true)"
        __self_OS_detect[id]="$(str::lower "${__self_OS_detect[name]}")"
    elif [[ -r /etc/redhat-release ]]; then
        __self_OS_detect[name]="$(< /etc/redhat-release)"
        __self_OS_detect[id]="rhel"; __self_OS_detect[id_like]="rhel fedora"
    fi
    [[ -n "${__self_OS_detect[name]}" ]] || __self_OS_detect[name]="未知"
    __self_OS_detect[major]="${__self_OS_detect[version]%%.*}"

    # —— 家族 ——
    local fam=""
    OS::family_of_var fam "${__self_OS_detect[id]}" "${__self_OS_detect[id_like]}"
    if [[ "$fam" == "unknown" ]]; then
        # 家族判不出就按包管理器反推（兼容极简镜像）
        local p
        for p in apt-get:debian dnf:rhel yum:rhel zypper:suse pacman:arch apk:alpine; do
            if sys::has_cmd "${p%%:*}"; then fam="${p##*:}"; break; fi
        done
    fi
    __self_OS_detect[family]="$fam"

    # —— 包管理器 ——
    local pm=""
    OS::detect_pm_var pm "$fam" "$force_pm" || true
    __self_OS_detect[pm]="$pm"

    # —— 架构 ——
    __self_OS_detect[arch]="$(uname -m 2>/dev/null || echo unknown)"

    # —— WSL ——
    __self_OS_detect[wsl]=0; __self_OS_detect[wsl_version]=""
    local kv="" osr="" rel=""
    [[ -r /proc/version ]] && kv="$(< /proc/version)"
    [[ -r /proc/sys/kernel/osrelease ]] && osr="$(< /proc/sys/kernel/osrelease)"
    if [[ "$kv" == *icrosoft* || "$kv" == *WSL* || "$osr" == *icrosoft* || "$osr" == *WSL* \
       || -n "${WSL_DISTRO_NAME:-}" || -n "${WSLENV:-}" ]]; then
        # 只有疑似 WSL 时才去查内核版本（uname 是一次 fork，能省则省）
        rel="$(uname -r 2>/dev/null || true)"
        __self_OS_detect[wsl]=1
        # WSL2 判定：内核名带 WSL2 / 5.x 以上 / 存在 /run/WSL / 有 WSL_INTEROP
        if [[ "$rel" == *WSL2* || "$osr" == *WSL2* || "$rel" =~ ^[5-9]\. \
           || -d /run/WSL || -n "${WSL_INTEROP:-}" ]]; then
            __self_OS_detect[wsl_version]=2
        else
            __self_OS_detect[wsl_version]=1
        fi
    fi

    # —— 容器 ——
    __self_OS_detect[container]="none"
    if [[ -r /.dockerenv ]]; then __self_OS_detect[container]="docker"
    elif [[ -r /run/.containerenv ]]; then __self_OS_detect[container]="podman"
    elif [[ -r /proc/1/cgroup ]] && grep -qE '(docker|lxc|kubepods|containerd)' /proc/1/cgroup 2>/dev/null; then
        __self_OS_detect[container]="other"
    fi

    # —— init 系统 ——
    if sys::has_cmd systemctl && [[ -d /run/systemd/system ]]; then __self_OS_detect[init]="systemd"
    elif sys::has_cmd rc-service; then  __self_OS_detect[init]="openrc"
    elif [[ -d /etc/init.d ]]; then     __self_OS_detect[init]="sysv"
    fi

    # —— 虚拟化 ——
    __self_OS_detect[virt]="none"
    if sys::has_cmd systemd-detect-virt; then
        __self_OS_detect[virt]="$(systemd-detect-virt 2>/dev/null || echo none)"
    fi

    return 0
}

# -----------------------------------------------------------------------------
# 便利：是否 RHEL 系但非 Fedora（Fedora 自带包，不需要 EPEL / 模块流）
# -----------------------------------------------------------------------------
OS::is_rhel_nonfedora() {
    local -n __self_OS_is_rhel_nonfedora=$1
    [[ "${__self_OS_is_rhel_nonfedora[id]}" == "fedora" || "${__self_OS_is_rhel_nonfedora[id]}" == "nobara" ]] && return 1
    case " ${__self_OS_is_rhel_nonfedora[id]} ${__self_OS_is_rhel_nonfedora[id_like]} " in
        *" rhel "*|*" centos "*) return 0 ;;
    esac
    case "${__self_OS_is_rhel_nonfedora[id]}" in
        rocky|almalinux|ol|oracle*|scientific|virtuozzo|cloudlinux|opencloudos|tencentos|anolis|openanolis)
            return 0 ;;
    esac
    return 1
}

# 便利：是否 Debian 系
OS::is_debian_family() { [[ "${1}" == "debian" ]]; }

# -----------------------------------------------------------------------------
# 打印摘要（OS::summary <对象> [缩进]）
# -----------------------------------------------------------------------------
OS::summary() {
    local -n __self_OS_summary=$1
    local indent="${2:-2}"
    local wsl_txt=""
    [[ "${__self_OS_summary[wsl]}" == "1" ]] && wsl_txt="WSL${__self_OS_summary[wsl_version]}"
    Ui::table UI "运行环境" \
        "发行版|${__self_OS_summary[pretty]}" \
        "家族|${__self_OS_summary[family]}" \
        "包管理器|${__self_OS_summary[pm]:-未识别}" \
        "架构|${__self_OS_summary[arch]}" \
        "环境|${wsl_txt:-${__self_OS_summary[container]}}" \
        "init|${__self_OS_summary[init]}"
}

# -----------------------------------------------------------------------------
# 权限： Sys::require_root / 自动 sudo
# -----------------------------------------------------------------------------
Sys::euid() { printf '%s' "${EUID:-$(id -u)}"; }

Sys::require_root() {
    if [[ "$(Sys::euid)" != "0" ]]; then
        if sys::has_cmd sudo; then
            err "本操作需要 root 权限，请改用：sudo $0 $*"
        else
            err "本操作需要 root 权限，请以 root 用户运行"
        fi
        exit 1
    fi
}
require_root() { Sys::require_root "$@"; }
ensure_root()  { Sys::require_root "$@"; }
need_root()    { Sys::require_root "$@"; }

# 组装 sudo 前缀数组（已是 root 则为空）
Sys::sudo_prefix() {
    if [[ "$(Sys::euid)" == "0" ]]; then
        printf '%s' ""
    elif sys::has_cmd sudo; then
        printf '%s' "sudo"
    else
        printf '%s' ""
    fi
}
