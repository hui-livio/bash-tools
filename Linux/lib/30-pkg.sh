#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
#  lib/30-pkg.sh —— 类 Pkg：跨发行版包管理器统一接口
#
#  把 apt / dnf / yum / zypper / pacman / apk / xbps / emerge 的差异封装成
#  同一组方法，业务脚本只说「装什么」，不必各写一遍 case "$PM"。
#
#  字段: pm  runner(执行命令的前缀数组名，可空)  env(非交互环境变量)  assume_yes
#
#  用法:
#     Pkg::new PKG apt
#     Pkg::update PKG
#     Pkg::install PKG cmake git
#     Pkg::remove  PKG foo        # 卸载但保留配置
#     Pkg::purge   PKG foo        # 卸载并清配置
#     Pkg::installed PKG cmake && echo 已装
# =============================================================================

[[ -n "${__LIB_PKG_LOADED:-}" ]] && return 0
__LIB_PKG_LOADED=1

Pkg::new() {
    local -n __self_Pkg_new=$1
    declare -gA "$1"
    __self_Pkg_new[pm]="${2:-${OS_PM:-}}"
    if [[ -z "${__self_Pkg_new[pm]}" ]]; then
        local -A __tmp; OS::new __tmp 2>/dev/null && OS::detect __tmp && __self_Pkg_new[pm]="${__tmp[pm]}"
    fi
    __self_Pkg_new[assume_yes]="${ASSUME_YES:-0}"
    __self_Pkg_new[quiet]=0
}

# -----------------------------------------------------------------------------
# 非交互环境变量（不同包管理器各不相同）
# -----------------------------------------------------------------------------
Pkg::_env() {
    local -n __self_Pkg__env=$1; shift
    case "${__self_Pkg__env[pm]}" in
        apt)    printf -v DEBIAN_FRONTEND '%s' noninteractive; export DEBIAN_FRONTEND
                command env DEBIAN_FRONTEND=noninteractive "$@" ;;
        dnf|yum) command env -u LANG LC_ALL=C "$@" ;;
        zypper) command env ZYPP_NON_INTERACTIVE=1 "$@" ;;
        *)      command "$@" ;;
    esac
}

Pkg::_yes() {
    local -n __self_Pkg__yes=$1
    case "${__self_Pkg__yes[pm]}" in
        apt|dnf|yum) printf '%s' "-y" ;;
        zypper)      printf '%s' "-n" ;;
        pacman)      printf '%s' "--noconfirm" ;;
        apk)         printf '%s' "--no-cache" ;;
        *)           printf '%s' "" ;;
    esac
}

# -----------------------------------------------------------------------------
# 刷新索引
# -----------------------------------------------------------------------------
Pkg::update() {
    local -n __self_Pkg_update=$1
    local pm="${__self_Pkg_update[pm]}"
    case "$pm" in
        apt)    Pkg::_env __self_Pkg_update apt-get update ;;
        dnf)    Pkg::_env __self_Pkg_update dnf makecache ;;
        yum)    Pkg::_env __self_Pkg_update yum makecache ;;
        zypper) Pkg::_env __self_Pkg_update zypper refresh ;;
        pacman) Pkg::_env __self_Pkg_update pacman -Sy ;;
        apk)    Pkg::_env __self_Pkg_update apk update ;;
        xbps)   Pkg::_env __self_Pkg_update xbps-install -S ;;
        emerge) Pkg::_env __self_Pkg_update emerge --sync ;;
        *)      err "未知包管理器：${pm}"; return 1 ;;
    esac
}

# -----------------------------------------------------------------------------
# 安装： Pkg::install <对象> 包名...
# -----------------------------------------------------------------------------
Pkg::install() {
    local -n __self_Pkg_install=$1; shift
    local pm="${__self_Pkg_install[pm]}"; local yes; yes="$(Pkg::_yes __self_Pkg_install)"
    (($#)) || return 0
    case "$pm" in
        apt)    Pkg::_env __self_Pkg_install apt-get install ${yes:+$yes} "$@" ;;
        dnf)    Pkg::_env __self_Pkg_install dnf install ${yes:+$yes} "$@" ;;
        yum)    Pkg::_env __self_Pkg_install yum install ${yes:+$yes} "$@" ;;
        zypper) Pkg::_env __self_Pkg_install zypper install ${yes:+$yes} "$@" ;;
        pacman) Pkg::_env __self_Pkg_install pacman -S ${yes:+$yes} "$@" ;;
        apk)    Pkg::_env __self_Pkg_install apk add "$@" ;;
        xbps)   Pkg::_env __self_Pkg_install xbps-install ${yes:+$yes} "$@" ;;
        emerge) Pkg::_env __self_Pkg_install emerge "$@" ;;
        *)      err "未知包管理器：${pm}"; return 1 ;;
    esac
}

# -----------------------------------------------------------------------------
# 卸载： Pkg::remove（保留配置） / Pkg::purge（连配置一起清）
# -----------------------------------------------------------------------------
Pkg::remove() {
    local -n __self_Pkg_remove=$1; shift
    local pm="${__self_Pkg_remove[pm]}"; local yes; yes="$(Pkg::_yes __self_Pkg_remove)"
    (($#)) || return 0
    case "$pm" in
        apt)    Pkg::_env __self_Pkg_remove apt-get remove ${yes:+$yes} "$@" ;;
        dnf)    Pkg::_env __self_Pkg_remove dnf remove ${yes:+$yes} "$@" ;;
        yum)    Pkg::_env __self_Pkg_remove yum remove ${yes:+$yes} "$@" ;;
        zypper) Pkg::_env __self_Pkg_remove zypper remove ${yes:+$yes} "$@" ;;
        pacman) Pkg::_env __self_Pkg_remove pacman -R ${yes:+$yes} "$@" ;;
        apk)    Pkg::_env __self_Pkg_remove apk del "$@" ;;
        xbps)   Pkg::_env __self_Pkg_remove xbps-remove ${yes:+$yes} "$@" ;;
        emerge) Pkg::_env __self_Pkg_remove emerge --unmerge "$@" ;;
        *)      err "未知包管理器：${pm}"; return 1 ;;
    esac
}

Pkg::purge() {
    local -n __self_Pkg_purge=$1; shift
    local pm="${__self_Pkg_purge[pm]}"; local yes; yes="$(Pkg::_yes __self_Pkg_purge)"
    (($#)) || return 0
    case "$pm" in
        apt)    Pkg::_env __self_Pkg_purge apt-get purge ${yes:+$yes} "$@" ;;
        dnf)    Pkg::_env __self_Pkg_purge dnf remove ${yes:+$yes} "$@" ;;
        yum)    Pkg::_env __self_Pkg_purge yum remove ${yes:+$yes} "$@" ;;
        zypper) Pkg::_env __self_Pkg_purge zypper remove ${yes:+$yes} "$@" ;;
        pacman) Pkg::_env __self_Pkg_purge pacman -Rns ${yes:+$yes} "$@" ;;
        apk)    Pkg::_env __self_Pkg_purge apk del "$@" ;;
        xbps)   Pkg::_env __self_Pkg_purge xbps-remove -R ${yes:+$yes} "$@" ;;
        emerge) Pkg::_env __self_Pkg_purge emerge --unmerge "$@" ;;
        *)      err "未知包管理器：${pm}"; return 1 ;;
    esac
}

# -----------------------------------------------------------------------------
# 是否已安装
# -----------------------------------------------------------------------------
Pkg::installed() {
    local -n __self_Pkg_installed=$1
    local pkg="$2" pm="${__self_Pkg_installed[pm]}"
    case "$pm" in
        apt)    dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q 'install ok installed' ;;
        dnf|yum) rpm -q "$pkg" >/dev/null 2>&1 ;;
        zypper) rpm -q "$pkg" >/dev/null 2>&1 ;;
        pacman) pacman -Qi "$pkg" >/dev/null 2>&1 ;;
        apk)    apk info -e "$pkg" >/dev/null 2>&1 ;;
        xbps)   xbps-query "$pkg" >/dev/null 2>&1 ;;
        *)      sys::has_cmd "$pkg" ;;
    esac
}
pkg_installed() { local -A __pi=([pm]="${PM:-${OS_PM:-}}"); Pkg::installed __pi "$1"; }

# -----------------------------------------------------------------------------
# 升级
# -----------------------------------------------------------------------------
Pkg::upgrade() {
    local -n __self_Pkg_upgrade=$1
    local pm="${__self_Pkg_upgrade[pm]}"; local yes; yes="$(Pkg::_yes __self_Pkg_upgrade)"
    local full="${2:-0}"
    case "$pm" in
        apt)    if (( full )); then Pkg::_env __self_Pkg_upgrade apt-get full-upgrade ${yes:+$yes}
                else               Pkg::_env __self_Pkg_upgrade apt-get upgrade ${yes:+$yes}; fi ;;
        dnf|yum) Pkg::_env __self_Pkg_upgrade "$pm" upgrade ${yes:+$yes} ;;
        zypper) if (( full )); then Pkg::_env __self_Pkg_upgrade zypper dist-upgrade ${yes:+$yes}
                else               Pkg::_env __self_Pkg_upgrade zypper update ${yes:+$yes}; fi ;;
        pacman) Pkg::_env __self_Pkg_upgrade pacman -Syu ${yes:+$yes} ;;
        apk)    Pkg::_env __self_Pkg_upgrade apk upgrade ;;
        xbps)   Pkg::_env __self_Pkg_upgrade xbps-install -Su ${yes:+$yes} ;;
        emerge) Pkg::_env __self_Pkg_upgrade emerge -uDN @world ;;
        *)      err "未知包管理器：${pm}"; return 1 ;;
    esac
}

# -----------------------------------------------------------------------------
# 清理缓存
# -----------------------------------------------------------------------------
Pkg::clean() {
    local -n __self_Pkg_clean=$1
    local pm="${__self_Pkg_clean[pm]}"; local yes; yes="$(Pkg::_yes __self_Pkg_clean)"
    case "$pm" in
        apt)    Pkg::_env __self_Pkg_clean apt-get autoremove ${yes:+$yes}
                Pkg::_env __self_Pkg_clean apt-get clean ;;
        dnf)    Pkg::_env __self_Pkg_clean dnf autoremove ${yes:+$yes}; Pkg::_env __self_Pkg_clean dnf clean all ;;
        yum)    Pkg::_env __self_Pkg_clean yum autoremove ${yes:+$yes}; Pkg::_env __self_Pkg_clean yum clean all ;;
        zypper) Pkg::_env __self_Pkg_clean zypper clean -a ;;
        pacman) Pkg::_env __self_Pkg_clean pacman -Scc ${yes:+$yes} ;;
        apk)    rm -rf /var/cache/apk/* 2>/dev/null || true ;;
        *)      return 0 ;;
    esac
}

# -----------------------------------------------------------------------------
# 修复半配置状态（apt 专属高频故障，其它包管理器给出等价动作）
# -----------------------------------------------------------------------------
Pkg::fix_broken() {
    local -n __self_Pkg_fix_broken=$1
    local pm="${__self_Pkg_fix_broken[pm]}"
    case "$pm" in
        apt)    dpkg --configure -a || true
                Pkg::_env __self_Pkg_fix_broken apt-get -f install -y || true ;;
        dnf|yum) "$pm" distro-sync -y || true ;;
        zypper) zypper verify || true ;;
        pacman) pacman -Qkk || true ;;
        *)      return 0 ;;
    esac
}

# -----------------------------------------------------------------------------
# 按模式列出已安装包（卸载场景用）
# -----------------------------------------------------------------------------
Pkg::list_matching() {
    local -n __self_Pkg_list_matching=$1; shift
    local pm="${__self_Pkg_list_matching[pm]}"
    case "$pm" in
        apt)    dpkg-query -W -f='${Package}\n' "$@" 2>/dev/null | sort -u ;;
        dnf|yum) rpm -qa "$@" 2>/dev/null | sort -u ;;
        zypper) rpm -qa "$@" 2>/dev/null | sort -u ;;
        pacman) pacman -Qq 2>/dev/null | grep -E "$(IFS='|'; echo "$*")" || true ;;
        apk)    apk info 2>/dev/null | grep -E "$(IFS='|'; echo "$*")" || true ;;
        *)      : ;;
    esac
}
