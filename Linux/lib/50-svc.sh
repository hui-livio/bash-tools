#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
#  lib/50-svc.sh —— 类 Svc：服务管理（systemd / openrc / sysv 统一接口）
#
#  字段: name(服务名)  init(systemd|openrc|sysv|auto)  runner(可空)
#
#  用法:
#     Svc::new SVC mariadb
#     Svc::exists SVC && Svc::enable SVC && Svc::start SVC
#     Svc::active SVC && echo 运行中
# =============================================================================

[[ -n "${__LIB_SVC_LOADED:-}" ]] && return 0
__LIB_SVC_LOADED=1

Svc::new() {
    local -n __self_Svc_new=$1
    declare -gA "$1"
    __self_Svc_new[name]="${2:-}"
    __self_Svc_new[init]="${3:-auto}"
}

Svc::_init() {
    local -n __self_Svc__init=$1
    if [[ "${__self_Svc__init[init]}" != "auto" ]]; then printf '%s' "${__self_Svc__init[init]}"; return 0; fi
    if sys::has_cmd systemctl && [[ -d /run/systemd/system ]]; then printf '%s' systemd
    elif sys::has_cmd rc-service; then printf '%s' openrc
    elif [[ -x /etc/init.d/${__self_Svc__init[name]} ]]; then printf '%s' sysv
    elif sys::has_cmd systemctl; then printf '%s' systemd
    else printf '%s' none; fi
}

Svc::exists() {
    local -n __self_Svc_exists=$1
    local init; init="$(Svc::_init __self_Svc_exists)"
    case "$init" in
        systemd) systemctl list-unit-files 2>/dev/null | grep -q "^${__self_Svc_exists[name]}\.service" ;;
        openrc)  [[ -e "/etc/init.d/${__self_Svc_exists[name]}" ]] ;;
        sysv)    [[ -x "/etc/init.d/${__self_Svc_exists[name]}" ]] ;;
        *)       return 1 ;;
    esac
}

Svc::active() {
    local -n __self_Svc_active=$1
    local init; init="$(Svc::_init __self_Svc_active)"
    case "$init" in
        systemd) systemctl is-active --quiet "${__self_Svc_active[name]}" 2>/dev/null ;;
        openrc)  rc-service "${__self_Svc_active[name]}" status >/dev/null 2>&1 ;;
        sysv)    "/etc/init.d/${__self_Svc_active[name]}" status >/dev/null 2>&1 ;;
        *)       return 1 ;;
    esac
}
svc_is_active() { local -A __sa=([name]="$1" [init]="auto"); Svc::active __sa; }

Svc::enabled() {
    local -n __self_Svc_enabled=$1
    local init; init="$(Svc::_init __self_Svc_enabled)"
    case "$init" in
        systemd) systemctl is-enabled --quiet "${__self_Svc_enabled[name]}" 2>/dev/null ;;
        openrc)  [[ -e "/etc/runlevels/default/${__self_Svc_enabled[name]}" ]] ;;
        sysv)    ls /etc/rc*.d/S*"${__self_Svc_enabled[name]}" >/dev/null 2>&1 ;;
        *)       return 1 ;;
    esac
}
svc_is_enabled() { local -A __se=([name]="$1" [init]="auto"); Svc::enabled __se; }

Svc::enable() {
    local -n __self_Svc_enable=$1
    local init; init="$(Svc::_init __self_Svc_enable)"
    case "$init" in
        systemd) systemctl enable "${__self_Svc_enable[name]}" ;;
        openrc)  rc-update add "${__self_Svc_enable[name]}" default ;;
        sysv)    sys::has_cmd update-rc.d && update-rc.d "${__self_Svc_enable[name]}" defaults
                 sys::has_cmd chkconfig   && chkconfig "${__self_Svc_enable[name]}" on ;;
        *)       return 1 ;;
    esac
}

Svc::disable() {
    local -n __self_Svc_disable=$1
    local init; init="$(Svc::_init __self_Svc_disable)"
    case "$init" in
        systemd) systemctl disable "${__self_Svc_disable[name]}" ;;
        openrc)  rc-update del "${__self_Svc_disable[name]}" default ;;
        sysv)    sys::has_cmd update-rc.d && update-rc.d "${__self_Svc_disable[name]}" remove
                 sys::has_cmd chkconfig   && chkconfig "${__self_Svc_disable[name]}" off ;;
        *)       return 1 ;;
    esac
}

Svc::start() {
    local -n __self_Svc_start=$1
    local init; init="$(Svc::_init __self_Svc_start)"
    case "$init" in
        systemd) systemctl start "${__self_Svc_start[name]}" ;;
        openrc)  rc-service "${__self_Svc_start[name]}" start ;;
        sysv)    "/etc/init.d/${__self_Svc_start[name]}" start ;;
        *)       return 1 ;;
    esac
}

Svc::stop() {
    local -n __self_Svc_stop=$1
    local init; init="$(Svc::_init __self_Svc_stop)"
    case "$init" in
        systemd) systemctl stop "${__self_Svc_stop[name]}" ;;
        openrc)  rc-service "${__self_Svc_stop[name]}" stop ;;
        sysv)    "/etc/init.d/${__self_Svc_stop[name]}" stop ;;
        *)       return 1 ;;
    esac
}

Svc::restart() {
    local -n __self_Svc_restart=$1
    local init; init="$(Svc::_init __self_Svc_restart)"
    case "$init" in
        systemd) systemctl restart "${__self_Svc_restart[name]}" ;;
        openrc)  rc-service "${__self_Svc_restart[name]}" restart ;;
        sysv)    "/etc/init.d/${__self_Svc_restart[name]}" restart ;;
        *)       return 1 ;;
    esac
}

# 人类可读状态串
Svc::status_line() {
    local -n __self_Svc_status_line=$1
    local run="" boot=""
    if Svc::active __self_Svc_status_line;  then run="${C_GREEN}运行中${C_RESET}";  else run="${C_DIM}已停止${C_RESET}"; fi
    if Svc::enabled __self_Svc_status_line; then boot="${C_GREEN}开机自启${C_RESET}"; else boot="${C_DIM}未自启${C_RESET}"; fi
    printf '%s / %s' "$run" "$boot"
}
