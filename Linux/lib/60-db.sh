#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
#  lib/60-db.sh —— 类 Db：MariaDB / MySQL 客户端统一封装
#
#  install-mariadb-lts.sh 与 uninstall-mariadb-lts.sh 各自实现了一套
#  write_client_cnf / sql_run_file / sql_query / test_root_password /
#  detect_service_name / detect_root_auth，这里收敛为一个对象。
#
#  字段:
#    service     服务名（mariadb / mysql / mysqld）
#    datadir     数据目录
#    conf_dir    配置目录（/etc/mysql/conf.d 等）
#    admin_user  管理账号（默认 root）
#    socket      unix socket 路径
#    cnf         当前使用的临时凭据文件路径
#
#  用法:
#     Db::new DB; Db::detect_service DB; Db::detect_paths DB
#     Db::sql DB "SELECT VERSION();"
# =============================================================================

[[ -n "${__LIB_DB_LOADED:-}" ]] && return 0
__LIB_DB_LOADED=1

Db::new() {
    local -n __self_Db_new=$1
    declare -gA "$1"
    __self_Db_new[service]=""; __self_Db_new[datadir]=""; __self_Db_new[conf_dir]=""
    __self_Db_new[admin_user]="root"; __self_Db_new[socket]=""; __self_Db_new[cnf]=""
    __self_Db_new[client]=""
}

# -----------------------------------------------------------------------------
# 服务名探测：mariadb → mysql → mysqld
# -----------------------------------------------------------------------------
Db::detect_service() {
    local -n __self_Db_detect_service=$1
    local c
    for c in mariadb mysql mysqld; do
        if sys::has_cmd systemctl && systemctl list-unit-files 2>/dev/null | grep -q "^${c}\.service"; then
            __self_Db_detect_service[service]="$c"; return 0
        fi
        if [[ -x "/etc/init.d/$c" ]]; then __self_Db_detect_service[service]="$c"; return 0; fi
    done
    # 没装服务但包还在（例如只装了客户端）
    for c in mariadb mysql mysqld; do
        if sys::has_cmd "$c" || sys::has_cmd "${c}d"; then __self_Db_detect_service[service]="$c"; return 0; fi
    done
    return 1
}

# -----------------------------------------------------------------------------
# 路径探测：datadir / conf_dir / socket
# -----------------------------------------------------------------------------
Db::detect_paths() {
    local -n __self_Db_detect_paths=$1
    local d=""

    # 数据目录：优先从运行中的实例问，其次查配置，最后取常见默认值
    if [[ -n "${__self_Db_detect_paths[service]:-}" ]]; then
        d="$(Db::query_scalar __self_Db_detect_paths "SELECT @@datadir;" 2>/dev/null || true)"
    fi
    if [[ -z "$d" ]]; then
        for f in /etc/mysql/mariadb.conf.d/50-server.cnf /etc/mysql/mysql.conf.d/mysqld.cnf \
                 /etc/my.cnf /etc/my.cnf.d/mariadb-server.cnf /etc/mysql/my.cnf; do
            [[ -r "$f" ]] || continue
            d="$(sed -n 's/^[[:space:]]*datadir[[:space:]]*=[[:space:]]*//p' "$f" 2>/dev/null | head -1)"
            [[ -n "$d" ]] && break
        done
    fi
    [[ -z "$d" ]] && d="/var/lib/mysql"
    __self_Db_detect_paths[datadir]="${d%/}"

    # 配置目录（自定义 .cnf 的落点）
    local c=""
    for c in /etc/mysql/mariadb.conf.d /etc/mysql/conf.d /etc/my.cnf.d /etc/mysql; do
        if [[ -d "$c" ]]; then __self_Db_detect_paths[conf_dir]="$c"; break; fi
    done
    [[ -z "${__self_Db_detect_paths[conf_dir]}" ]] && __self_Db_detect_paths[conf_dir]="/etc/mysql/conf.d"

    # socket
    local s=""
    s="$(Db::query_scalar __self_Db_detect_paths "SELECT @@socket;" 2>/dev/null || true)"
    if [[ -z "$s" ]]; then
        for s in /run/mysqld/mysqld.sock /var/run/mysqld/mysqld.sock /tmp/mysql.sock; do
            [[ -S "$s" ]] && break || s=""
        done
    fi
    __self_Db_detect_paths[socket]="$s"

    # 客户端可执行
    if sys::has_cmd mariadb; then __self_Db_detect_paths[client]="mariadb"
    elif sys::has_cmd mysql; then __self_Db_detect_paths[client]="mysql"
    else __self_Db_detect_paths[client]=""; fi

    return 0
}

# -----------------------------------------------------------------------------
# 生成临时凭据文件（600 权限，登记自动清理）
#   Db::write_cnf <对象> [密码] [主机] [端口]
#   输出：临时 cnf 路径
# -----------------------------------------------------------------------------
Db::write_cnf() {
    local -n __self_Db_write_cnf=$1
    local pass="${2:-}" host="${3:-}" port="${4:-}"
    local f; f="$(Tmp::make_file)"
    {
        printf '%s\n' '[client]'
        printf 'user=%s\n' "${__self_Db_write_cnf[admin_user]}"
        [[ -n "$pass" ]] && printf 'password=%s\n' "$(str::cnf_escape "$pass")"
        if [[ -z "$host" && -n "${__self_Db_write_cnf[socket]:-}" ]]; then
            printf 'socket=%s\n' "${__self_Db_write_cnf[socket]}"
        elif [[ -n "$host" ]]; then
            printf 'host=%s\n' "$host"
            [[ -n "$port" ]] && printf 'port=%s\n' "$port"
        fi
    } > "$f"
    chmod 600 "$f" 2>/dev/null || true
    __self_Db_write_cnf[cnf]="$f"
    printf '%s' "$f"
}
write_client_cnf() { Db::write_cnf DB "$@"; }

# -----------------------------------------------------------------------------
# 执行 SQL
#   Db::sql <对象> "<SQL>"            → 直接执行，返回码即结果
#   Db::query <对象> "<SQL>"          → 输出查询结果（失败只返回码）
#   Db::query_scalar <对象> "<SQL>"   → 输出单个值
#   Db::sql_file <对象> <文件>        → 执行 SQL 文件
# -----------------------------------------------------------------------------
Db::_client() {
    local -n __self_Db__client=$1
    if [[ -n "${__self_Db__client[client]:-}" ]]; then printf '%s' "${__self_Db__client[client]}"; return 0; fi
    if sys::has_cmd mariadb; then printf '%s' mariadb
    elif sys::has_cmd mysql; then printf '%s' mysql
    else printf '%s' ""; fi
}

Db::sql() {
    local -n __self_Db_sql=$1
    local sql="$2" cl; cl="$(Db::_client __self_Db_sql)"
    [[ -n "$cl" ]] || return 1
    if [[ -n "${__self_Db_sql[cnf]:-}" && -r "${__self_Db_sql[cnf]}" ]]; then
        "$cl" --defaults-extra-file="${__self_Db_sql[cnf]}" -e "$sql" 2>&1
    else
        "$cl" -u "${__self_Db_sql[admin_user]}" -e "$sql" 2>&1
    fi
}

Db::query() {
    local -n __self_Db_query=$1
    local sql="$2" cl; cl="$(Db::_client __self_Db_query)"
    [[ -n "$cl" ]] || return 1
    if [[ -n "${__self_Db_query[cnf]:-}" && -r "${__self_Db_query[cnf]}" ]]; then
        "$cl" --defaults-extra-file="${__self_Db_query[cnf]}" -N -B -e "$sql" 2>/dev/null
    else
        "$cl" -u "${__self_Db_query[admin_user]}" -N -B -e "$sql" 2>/dev/null
    fi
}
sql_query() { Db::query DB "$1"; }

Db::query_scalar() {
    local -n __self_Db_query_scalar=$1
    Db::query __self_Db_query_scalar "$2" | head -n1 | str::trim
}

Db::sql_file() {
    local -n __self_Db_sql_file=$1
    local file="$2" cl; cl="$(Db::_client __self_Db_sql_file)"
    [[ -n "$cl" && -r "$file" ]] || return 1
    if [[ -n "${__self_Db_sql_file[cnf]:-}" && -r "${__self_Db_sql_file[cnf]}" ]]; then
        "$cl" --defaults-extra-file="${__self_Db_sql_file[cnf]}" < "$file" 2>&1
    else
        "$cl" -u "${__self_Db_sql_file[admin_user]}" < "$file" 2>&1
    fi
}

# -----------------------------------------------------------------------------
# 连通性测试
#   Db::test_local <对象> [密码]     —— socket 本地登录
#   Db::test_tcp   <对象> <密码> <host> <port>
# -----------------------------------------------------------------------------
Db::test_local() {
    local -n __self_Db_test_local=$1
    local pass="${2:-}" f cl; cl="$(Db::_client __self_Db_test_local)"
    [[ -n "$cl" ]] || return 1
    f="$(Db::write_cnf __self_Db_test_local "$pass")"
    "$cl" --defaults-extra-file="$f" -e "SELECT 1;" >/dev/null 2>&1
}
test_root_password() { Db::test_local DB "$1"; }

Db::test_tcp() {
    local -n __self_Db_test_tcp=$1
    local pass="$2" host="$3" port="$4" f cl; cl="$(Db::_client __self_Db_test_tcp)"
    [[ -n "$cl" ]] || return 1
    f="$(Db::write_cnf __self_Db_test_tcp "$pass" "$host" "$port")"
    "$cl" --defaults-extra-file="$f" -e "SELECT 1;" >/dev/null 2>&1
}

# -----------------------------------------------------------------------------
# root 认证方式识别： unix_socket | mysql_native_password | 空口令 | 未知
# -----------------------------------------------------------------------------
Db::detect_root_auth() {
    local -n __self_Db_detect_root_auth=$1
    local cl; cl="$(Db::_client __self_Db_detect_root_auth)"
    [[ -n "$cl" ]] || { printf '%s' unknown; return 1; }

    # 免密能进 → 可能是 unix_socket 或空口令
    if "$cl" -u root -e "SELECT 1;" >/dev/null 2>&1; then
        local plugin
        plugin="$(Db::query __self_Db_detect_root_auth "SELECT plugin FROM mysql.user WHERE User='root' AND Host='localhost' LIMIT 1;" 2>/dev/null | head -1)"
        [[ -z "$plugin" ]] && plugin="$(Db::query __self_Db_detect_root_auth "SELECT plugin FROM mysql.global_priv WHERE User='root' LIMIT 1;" 2>/dev/null | head -1)"
        case "$plugin" in
            unix_socket|auth_socket) printf '%s' unix_socket; return 0 ;;
            '')                      printf '%s' empty;       return 0 ;;
            *)                       printf '%s' "$plugin";   return 0 ;;
        esac
    fi
    printf '%s' password
}

# -----------------------------------------------------------------------------
# 生成随机密码（不用 "… | head -c" 收尾：SIGPIPE + pipefail 会导致非 0）
# -----------------------------------------------------------------------------
Db::gen_password() {
    local len="${1:-20}"
    local pw=""
    # 一次性取足够字节再裁剪，避免管道被 SIGPIPE 打断（pipefail 下会整条失败）
    if [[ -r /dev/urandom ]]; then
        pw="$(LC_ALL=C tr -dc 'A-Za-z0-9!@#%^&*_-+=' < /dev/urandom 2>/dev/null \
             | dd bs=$(( len * 2 )) count=1 2>/dev/null)"
    fi
    if [[ ${#pw} -lt len ]]; then
        # urandom 不可用时的兜底（不保证密码学强度，仅保证可用）
        pw="${pw}$(date '+%s%N' 2>/dev/null)${RANDOM}${RANDOM}"
        pw="$(printf '%s' "$pw" | sha256sum 2>/dev/null | base64 2>/dev/null)"
        pw="${pw//[^A-Za-z0-9]/}"
    fi
    printf '%s' "${pw:0:len}"
}
generate_password() { Db::gen_password "${1:-20}"; }

# 密码强度提示
Db::strength_note() {
    local pw="$1" len=${#1} score=0 note
    # 注意：(( score++ )) 在 score=0 时返回 1，会被 set -e 判定为失败，故统一用 ++score
    (( len >= 12 )) && (( ++score ))
    (( len >= 16 )) && (( ++score ))
    [[ "$pw" == *[0-9]* ]]    && (( ++score ))
    [[ "$pw" == *[A-Za-z]* ]] && (( ++score ))
    [[ "$pw" != "${pw//[^A-Za-z0-9]/}" ]] && (( ++score ))
    case "$score" in
        0|1) note="${C_RED}弱${C_RESET}" ;;
        2|3) note="${C_YELLOW}中${C_RESET}" ;;
        *)   note="${C_GREEN}强${C_RESET}" ;;
    esac
    printf '%s（长度 %d）' "$note" "$len"
}
