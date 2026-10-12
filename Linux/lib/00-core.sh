#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
#  lib/00-core.sh —— 核心层：终端颜色、日志器对象 Logger、错误处理、临时文件
#
#  面向对象约定（全库统一）：
#    · 「类」= 一组以 <Class>:: 为前缀的函数
#    · 「对象」= 一个关联数组，通过 nameref（local -n self=$1）传入方法
#    · 「构造函数」= <Class>::new <对象名> [参数...]，内部 declare -gA 并初始化字段
#  例：
#       Logger::new LOG "/var/log/foo.log"
#       Logger::info LOG "开始安装"
#
#  本文件只依赖 bash 4.3+，不含任何业务逻辑。
# =============================================================================

[[ -n "${__LIB_CORE_LOADED:-}" ]] && return 0
__LIB_CORE_LOADED=1

# -----------------------------------------------------------------------------
# 类：Term —— 终端颜色能力探测与颜色常量
#   字段: has_color(0|1)
# -----------------------------------------------------------------------------
Term::new() {
    local -n __self_Term_new=$1
    declare -gA "$1"
    __self_Term_new[has_color]=0
    if [[ -t 1 && -z "${NO_COLOR:-}" && "${TERM:-dumb}" != "dumb" ]]; then
        __self_Term_new[has_color]=1
    fi
}

# 根据 has_color 输出颜色/取消色序列
Term::color() {
    local -n __self_Term_color=$1
    local name="$2" code=""
    case "$name" in
        reset)   code='\033[0m'   ;;
        bold)    code='\033[1m'   ;;
        dim)     code='\033[2m'   ;;
        red)     code='\033[31m'  ;;
        green)   code='\033[32m'  ;;
        yellow)  code='\033[33m'  ;;
        blue)    code='\033[34m'  ;;
        magenta) code='\033[35m'  ;;
        cyan)    code='\033[36m'  ;;
        gray)    code='\033[90m'  ;;
        *)       code=''          ;;
    esac
    if [[ "${__self_Term_color[has_color]}" == "1" ]]; then printf '%b' "$code"; fi
}

# -----------------------------------------------------------------------------
# 全局颜色常量（兼容历史脚本的 C_RED / C_GREEN / C_BLUE / C_GRAY 等写法）
# 首次 source 时按当前终端能力初始化一次。
# -----------------------------------------------------------------------------
_term_init_globals() {
    local -A __tg
    Term::new __tg
    # 刻意不起子 shell（不用 $(tr ...) / $(printf ...)）：
    # 库被十几个脚本 source，每次都 fork 一轮会明显拖慢启动（WSL / Windows 尤甚）
    local n upper esc
    for n in reset bold dim red green yellow blue magenta cyan gray; do
        case "$n" in
            reset)   esc='\033[0m'   ;;
            bold)    esc='\033[1m'   ;;
            dim)     esc='\033[2m'   ;;
            red)     esc='\033[31m'  ;;
            green)   esc='\033[32m'  ;;
            yellow)  esc='\033[33m'  ;;
            blue)    esc='\033[34m'  ;;
            magenta) esc='\033[35m'  ;;
            cyan)    esc='\033[36m'  ;;
            gray)    esc='\033[90m'  ;;
            *)       esc=''          ;;
        esac
        upper="${n^^}"
        if [[ "${__tg[has_color]}" == "1" ]]; then
            printf -v "C_${upper}" '%b' "$esc"
        else
            printf -v "C_${upper}" '%s' ""
        fi
    done
    # 历史脚本用过的短别名，统一指向同一批常量，避免再出现 8 套颜色定义
    C_RST="${C_RESET}"; C_R="${C_RED}";   C_G="${C_GREEN}"; C_Y="${C_YELLOW}"
    C_B="${C_BLUE}";    C_BL="${C_BLUE}"; C_D="${C_DIM}";   C_0="${C_RESET}"
}
_term_init_globals
unset -f _term_init_globals

# -----------------------------------------------------------------------------
# 类：Logger —— 统一日志（屏幕 + 文件）
#   字段: file(日志路径，空=不落盘)  quiet(0|1)  verbose(0|1)
#   用法: Logger::new LOG "/var/log/x.log"; Logger::info LOG "消息"
# -----------------------------------------------------------------------------
Logger::new() {
    local -n __self_Logger_new=$1
    declare -gA "$1"
    __self_Logger_new[file]="${2:-${LOG_FILE:-}}"
    __self_Logger_new[quiet]=0
    __self_Logger_new[verbose]=0
    __self_Logger_new[tag]=""
    # 日志文件不可写时自动降级为「仅屏幕」，不阻断脚本
    if [[ -n "${__self_Logger_new[file]}" ]]; then
        if ! : >>"${__self_Logger_new[file]}" 2>/dev/null; then
            printf '%s[警告]%s 日志文件不可写，已降级为仅屏幕输出：%s\n' \
                "$C_YELLOW" "$C_RESET" "${__self_Logger_new[file]}" >&2
            __self_Logger_new[file]=""
        fi
    fi
}

Logger::raw() {
    local -n __self_Logger_raw=$1
    local msg="$2"
    [[ -n "${__self_Logger_raw[file]}" ]] || return 0
    printf '%s\n' "$msg" 2>/dev/null >>"${__self_Logger_raw[file]}" || true
}

Logger::stamp() { date '+%Y-%m-%d %H:%M:%S'; }

Logger::_emit() {
    # $1=对象 $2=级别标签 $3=颜色名 $4=目标(fd 1 或 2) $5=消息
    local -n __self_Logger__emit=$1
    local label="$2" cname="$3" fd="$4" msg="$5"
    # 颜色统一取自全局常量（由 Term 在加载时按终端能力初始化）
    local color
    case "$cname" in
        red)    color="$C_RED"    ;;
        green)  color="$C_GREEN"  ;;
        yellow) color="$C_YELLOW" ;;
        blue)   color="$C_BLUE"   ;;
        cyan)   color="$C_CYAN"   ;;
        dim)    color="$C_DIM"    ;;
        *)      color=""          ;;
    esac
    [[ "${__self_Logger__emit[quiet]}" == "1" ]] || printf '%s[%s]%s %s\n' "$color" "$label" "$C_RESET" "$msg" >&$fd
    Logger::raw __self_Logger__emit "[$(Logger::stamp)] $label: $msg"
}

Logger::info()   { Logger::_emit "$1" "信息" "blue"   1 "$2"; }
Logger::ok()     { Logger::_emit "$1" "完成" "green"  1 "$2"; }
Logger::warn()   { Logger::_emit "$1" "警告" "yellow" 2 "$2"; }
Logger::err()    { Logger::_emit "$1" "错误" "red"    2 "$2"; }
Logger::hint()   { Logger::_emit "$1" "提示" "dim"    1 "$2"; }

Logger::step() {
    local -n __self_Logger_step=$1
    [[ "${__self_Logger_step[quiet]}" == "1" ]] || printf '\n%s%s==> %s%s\n' "$C_BOLD" "$C_CYAN" "$2" "$C_RESET"
    Logger::raw __self_Logger_step "[$(Logger::stamp)] ---- $2 ----"
}

Logger::section() {
    local -n __self_Logger_section=$1
    [[ "${__self_Logger_section[quiet]}" == "1" ]] || printf '\n%s===== %s =====%s\n\n' "$C_CYAN" "$2" "$C_RESET"
    Logger::raw __self_Logger_section "[$(Logger::stamp)] ======== $2 ========"
}

Logger::die() {
    local -n __self_Logger_die=$1
    Logger::_emit __self_Logger_die "错误" "red" 2 "$2"
    Logger::_emit __self_Logger_die "错误" "red" 2 "脚本已中止（退出码 ${3:-1}）"
    exit "${3:-1}"
}

# -----------------------------------------------------------------------------
# 默认全局日志对象 LOG —— 兼容历史脚本直接调用 info/warn/err/die/step 的写法
# -----------------------------------------------------------------------------
Logger::new LOG "${LOG_FILE:-}"
LOG_FILE="${LOG[file]}"

# 历史脚本的全局短函数（保留语义：info/ok/warn/err/die/step/log）
info() { Logger::_emit LOG "信息" "blue"   1 "$*"; }
ok()   { Logger::_emit LOG "完成" "green"  1 "$*"; }
warn() { Logger::_emit LOG "警告" "yellow" 2 "$*"; }
err()  { Logger::_emit LOG "错误" "red"    2 "$*"; }
hint() { Logger::_emit LOG "提示" "dim"    1 "$*"; }
step() { Logger::step LOG "$*"; }
log()  { Logger::raw LOG "[$(Logger::stamp)] $*"; }
die()  { Logger::_emit LOG "错误" "red" 2 "$*"; exit 1; }

# -----------------------------------------------------------------------------
# 类：Tmp —— 临时文件/目录的登记与自动回收（替代各脚本里的 mktemp_tracked）
#   字段: files(数组)
# -----------------------------------------------------------------------------
declare -ga __TMP_REGISTRY=()

Tmp::make_file() {
    local f
    f="$(mktemp)" || return 1
    chmod 600 "$f" 2>/dev/null || true
    __TMP_REGISTRY+=("$f")
    printf '%s' "$f"
}

Tmp::make_dir() {
    local d
    d="$(mktemp -d)" || return 1
    chmod 700 "$d" 2>/dev/null || true
    __TMP_REGISTRY+=("$d")
    printf '%s' "$d"
}

Tmp::cleanup() {
    local f
    for f in "${__TMP_REGISTRY[@]:-}"; do
        [[ -n "$f" ]] || continue
        rm -rf -- "$f" 2>/dev/null || true
    done
    __TMP_REGISTRY=()
    return 0
}

# 兼容历史函数名
mktemp_tracked() { Tmp::make_file; }

# -----------------------------------------------------------------------------
# 类：Err —— 统一 ERR 陷阱（替代各脚本里 4 份几乎相同的 on_error / _on_err）
#   字段: script(脚本名) logref(日志对象名) tolerant(0|1)
# -----------------------------------------------------------------------------
Err::new() {
    local -n __self_Err_new=$1
    declare -gA "$1"
    local __src="${BASH_SOURCE[1]:-$0}"
    __self_Err_new[script]="${2:-${__src##*/}}"
    __self_Err_new[logref]="${3:-LOG}"
    __self_Err_new[tolerant]=0     # 置 1 时临时忽略错误（可容忍段落）
    __self_Err_new[exit]=0
}

Err::handler() {
    local -n __self_Err_handler=$1
    local line="$2" code="$3"
    # 兼容历史脚本直接改全局变量 _TOLERANT 的写法
    [[ "${_TOLERANT:-0}" == "1" ]] && return 0
    [[ "${__self_Err_handler[tolerant]}" == "1" ]] && return 0
    # 只处理主 shell 的错误：子 shell 会因 set -E 继承陷阱，避免同一错误重复打印
    [[ "${BASHPID:-$$}" != "$$" ]] && return 0
    local -n __lg="${__self_Err_handler[logref]}"
    Logger::_emit __lg "错误" "red" 2 "${__self_Err_handler[script]} 在第 ${line} 行附近意外中止（退出码 ${code}）"
    if [[ -n "${__lg[file]:-}" ]]; then
        Logger::_emit __lg "错误" "red" 2 "完整日志：${__lg[file]}"
    fi
    exit "$code"
}

# 安装陷阱。用法： Err::new ERRCTX "脚本名"; Err::install ERRCTX
Err::install() {
    local -n __self_Err_install=$1
    local self="$1"
    trap "Err::handler $self \"\$LINENO\" \"\$?\"" ERR
}

# 兼容历史写法的容忍开关（老脚本用 _TOLERANT 全局变量）
Err::tolerate()    { local -n __self_Err_install=$1; __e[tolerant]=1; _TOLERANT=1; }
Err::strict()      { local -n __self_Err_install=$1; __e[tolerant]=0; _TOLERANT=0; }

# -----------------------------------------------------------------------------
# 字符串小工具（被 5 个脚本重复实现过）
# -----------------------------------------------------------------------------
str::trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}
retrim() { str::trim "$1"; }   # 历史别名

# 原地裁剪：str::trim_var <变量名>
#   与 str::trim 的区别是不需要命令替换，避免每次裁剪都 fork 一个子 shell
#   （批量解析元数据时逐条 fork 会明显变慢）。
str::trim_var() {
    local -n __tv=$1
    __tv="${__tv#"${__tv%%[![:space:]]*}"}"
    __tv="${__tv%"${__tv##*[![:space:]]}"}"
}

str::lower() { printf '%s' "${1,,}"; }
str::upper() { printf '%s' "${1^^}"; }

# SQL / option 文件转义（MariaDB 相关脚本共用）
str::sql_escape()   { local s="$1"; s="${s//\'/\'\'}";   printf '%s' "$s"; }
str::cnf_escape()   { local s="$1"; s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; printf '%s' "$s"; }
sql_escape() { str::sql_escape "$1"; }
cnf_escape() { str::cnf_escape "$1"; }

# 命令是否存在
sys::has_cmd() { command -v "$1" >/dev/null 2>&1; }
need_cmd() { command -v "$1" >/dev/null 2>&1 && return 0 || return 1; }
need()     { command -v "$1" >/dev/null 2>&1 || die "缺少命令：$1"; }
