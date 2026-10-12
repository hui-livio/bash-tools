#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
#  lib/10-ui.sh —— 交互层：显示宽度、对齐表格、输入提示、确认、菜单
#
#  类：
#    Ui     —— 终端交互对象，持有 ASSUME_YES / NON_INTERACTIVE 等状态
#    Menu   —— 通用菜单对象（选项表 + 渲染 + 选择）
#
#  历史兼容函数（本目录脚本里出现过 6 套重复实现，统一收敛到这里）：
#    disp_width / item / prompt / confirm / ask_yes_no / ask_feature
#    confirm_typed / read_line / pause_for_confirm
# =============================================================================

[[ -n "${__LIB_UI_LOADED:-}" ]] && return 0
__LIB_UI_LOADED=1
[[ -n "${__LIB_CORE_LOADED:-}" ]] || { echo "10-ui.sh 需要先加载 00-core.sh" >&2; return 1; }

# -----------------------------------------------------------------------------
# 类：Ui —— 交互状态对象
#   字段: assume_yes(0|1)  非破坏性询问自动同意
#         non_interactive(0|1) 完全非交互（用默认值，危险操作默认拒绝）
#         logref         日志对象名
# -----------------------------------------------------------------------------
Ui::new() {
    local -n __self_Ui_new=$1
    declare -gA "$1"
    __self_Ui_new[assume_yes]="${ASSUME_YES:-0}"
    __self_Ui_new[non_interactive]="${NON_INTERACTIVE:-0}"
    __self_Ui_new[logref]="${2:-LOG}"
}

# 归一化布尔：yes/y/1/true/是 → 0；其它 → 1
Ui::_bool() {
    case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
        y|yes|1|true|on|是) return 0 ;;
        *)                  return 1 ;;
    esac
}

# -----------------------------------------------------------------------------
# 显示宽度：ASCII 计 1，非 ASCII（中文等）计 2 —— 避免中文标签列错位
# -----------------------------------------------------------------------------
Ui::disp_width() {
    local s="$1" i n w=0 b
    local LC_ALL=C
    n=${#s}
    for (( i=0; i<n; i++ )); do
        b="${s:i:1}"
        if [[ "$b" < $'\200' ]]; then
            w=$(( w + 1 ))
        else
            w=$(( w + 2 ))
            i=$(( i + 2 ))
        fi
    done
    printf '%s' "$w"
}
disp_width() { Ui::disp_width "$1"; }

# -----------------------------------------------------------------------------
# 同上，但结果写回变量而不是标准输出：Ui::disp_width_var <变量名> <字符串>
#   用于表格/补位这类高频调用，避免每行都 fork 一个子 shell
# -----------------------------------------------------------------------------
Ui::disp_width_var() {
    # 内部变量加 __ 前缀：nameref 按名字解析，若与调用方变量同名会写错地方
    local -n __self_Ui_disp_width_var=$1
    local __s="$2" __i __n __w=0 __b
    local LC_ALL=C
    __n=${#__s}
    for (( __i=0; __i<__n; __i++ )); do
        __b="${__s:__i:1}"
        if [[ "$__b" < $'\200' ]]; then
            __w=$(( __w + 1 ))
        else
            __w=$(( __w + 2 )); __i=$(( __i + 2 ))
        fi
    done
    printf -v __self_Ui_disp_width_var '%s' "$__w"
}

# -----------------------------------------------------------------------------
# 对齐的「标签: 值」行。 Ui::item <ui对象> <标签> <值> [缩进] [列宽]
# -----------------------------------------------------------------------------
Ui::item() {
    local -n __self_Ui_item=$1
    local label="$2" value="$3" indent="${4:-2}" width="${5:-20}"
    [[ "${__self_Ui_item[quiet]:-0}" == "1" ]] && return 0
    local __w=0 __pad
    Ui::disp_width_var __w "$label"
    __pad=$(( width - __w ))
    (( __pad < 1 )) && __pad=1
    printf '%*s%s%*s%s\n' "$indent" "" "$label" "$__pad" "" "$value"
}
item() { Ui::item UI "$1" "$2" "${3:-2}" "${4:-20}"; }

# -----------------------------------------------------------------------------
# 按显示宽度左对齐补位： Ui::pad <ui对象> <字符串> <目标宽度>
#   printf 的 %-Ns 按字节补位，中文会错位，这里按显示宽度算
# -----------------------------------------------------------------------------
Ui::pad() {
    local -n __self_Ui_pad=$1
    local __s="$2" __w="$3" __dw=0 __p
    Ui::disp_width_var __dw "$__s"
    __p=$(( __w - __dw ))
    (( __p < 1 )) && __p=1
    printf '%s%*s' "$__s" "$__p" ""
}
pad() { Ui::pad UI "$1" "$2"; }

# 写回变量版：Ui::pad_var <变量名> <字符串> <目标宽度>
#   表格渲染常在同一行里补位多次，用打印版会产生大量命令替换（每次一个子 shell）
Ui::pad_var() {
    local -n __self_Ui_pad_var=$1
    local __s="$2" __w="$3" __dw=0 __p
    Ui::disp_width_var __dw "$__s"
    __p=$(( __w - __dw ))
    (( __p < 1 )) && __p=1
    printf -v __self_Ui_pad_var '%s%*s' "$__s" "$__p" ""
}

# -----------------------------------------------------------------------------
# 两列表格（批量打印，自动算列宽）
#   Ui::table <ui对象> "标题" "标签1|值1" "标签2|值2" ...
# -----------------------------------------------------------------------------
Ui::table() {
    local -n __self_Ui_table=$1
    local title="$2"; shift 2
    local -a rows=("$@")
    local __maxw=0 __w=0 __r __label
    for __r in "${rows[@]:-}"; do
        [[ -n "$__r" ]] || continue
        __label="${__r%%|*}"
        Ui::disp_width_var __w "$__label"
        (( __w > __maxw )) && __maxw=$__w
    done
    [[ -n "$title" ]] && printf '%s%s%s\n' "$C_BOLD" "$title" "$C_RESET"
    for __r in "${rows[@]:-}"; do
        [[ -n "$__r" ]] || continue
        Ui::item __self_Ui_table "${__r%%|*}" "${__r#*|}" 2 $(( __maxw + 2 ))
    done
}

# -----------------------------------------------------------------------------
# 文本输入： Ui::prompt <ui对象> <变量名> <提示语> [默认值]
# -----------------------------------------------------------------------------
Ui::prompt() {
    local -n __self_Ui_prompt=$1
    local __var="$2" __label="$3" __default="${4:-}" __answer=""
    if [[ "${__self_Ui_prompt[non_interactive]}" == "1" ]]; then
        printf -v "$__var" '%s' "$__default"
        return 0
    fi
    if [[ -n "$__default" ]] && [[ -o emacs ]] 2>/dev/null; then
        read -r -e -i "$__default" -p "$(printf '%s [%s]: ' "$__label" "$__default")" __answer || true
    else
        if [[ -n "$__default" ]]; then
            read -r -p "$(printf '%s [%s]: ' "$__label" "$__default")" __answer || true
        else
            read -r -p "$(printf '%s: ' "$__label")" __answer || true
        fi
    fi
    [[ -z "$__answer" ]] && __answer="$__default"
    printf -v "$__var" '%s' "$(str::trim "$__answer")"
    return 0
}
prompt() { Ui::prompt UI "$1" "$2" "${3:-}"; }

# -----------------------------------------------------------------------------
# 是否类确认： Ui::confirm <ui对象> <提示语> [默认值 y|n]
#   受 assume_yes 影响（用于「是否继续」这类非破坏性询问）
# -----------------------------------------------------------------------------
Ui::confirm() {
    local -n __self_Ui_confirm=$1
    local label="$2" def="${3:-n}" ans="" hint
    if [[ "${__self_Ui_confirm[assume_yes]}" == "1" ]]; then return 0; fi
    if [[ "${__self_Ui_confirm[non_interactive]}" == "1" ]]; then
        Ui::_bool "$def" && return 0 || return 1
    fi
    if Ui::_bool "$def"; then hint="Y/n"; else hint="y/N"; fi
    while true; do
        read -r -p "$(printf '%s [%s]: ' "$label" "$hint")" ans || true
        [[ -z "$ans" ]] && ans="$def"
        case "$(str::lower "$ans")" in
            y|yes|是) return 0 ;;
            n|no|否)  return 1 ;;
            *) warn "请输入 y 或 n" ;;
        esac
    done
}
confirm()     { Ui::confirm UI "$1" "${2:-n}"; }
ask_yes_no()  { Ui::confirm UI "$1" "${2:-n}"; }

# -----------------------------------------------------------------------------
# 功能开关： Ui::feature <ui对象> <提示语> [默认值]
#   不受 assume_yes 影响 —— 用于远程 root、开放防火墙等高风险开关
# -----------------------------------------------------------------------------
Ui::feature() {
    local -n __self_Ui_feature=$1
    local label="$2" def="${3:-n}" ans="" hint
    if [[ "${__self_Ui_feature[non_interactive]}" == "1" ]]; then
        Ui::_bool "$def" && return 0 || return 1
    fi
    if Ui::_bool "$def"; then hint="Y/n"; else hint="y/N"; fi
    while true; do
        read -r -p "$(printf '%s [%s]: ' "$label" "$hint")" ans || true
        [[ -z "$ans" ]] && ans="$def"
        case "$(str::lower "$ans")" in
            y|yes|是) return 0 ;;
            n|no|否)  return 1 ;;
            *) warn "请输入 y 或 n" ;;
        esac
    done
}
ask_feature() { Ui::feature UI "$1" "${2:-n}"; }

# -----------------------------------------------------------------------------
# 危险操作确认： Ui::typed <ui对象> <提示语> <确认词>
#   必须逐字输入确认词（如 DELETE）；非交互下默认拒绝
# -----------------------------------------------------------------------------
Ui::typed() {
    local -n __self_Ui_typed=$1
    local label="$2" phrase="$3" ans=""
    if [[ "${__self_Ui_typed[non_interactive]}" == "1" ]]; then
        warn "非交互模式，已拒绝需要逐字确认的危险操作：${label}"
        return 1
    fi
    read -r -p "$(printf '%s（输入 %s 继续）: ' "$label" "$phrase")" ans || true
    [[ "$ans" == "$phrase" ]]
}
confirm_typed() { Ui::typed UI "$1" "$2"; }

# 单行读取： Ui::read_line <ui对象> <变量名> <提示语>
#   返回 1 表示 EOF / 用户中断；结果自动 trim
Ui::read_line() {
    local -n __self_Ui_read_line=$1
    local __var="$2" __prompt="${3:-}" __val=""
    if [[ -t 0 ]]; then
        read -r -p "$__prompt" __val || return 1
    else
        read -r __val || return 1
    fi
    printf -v "$__var" '%s' "$(str::trim "$__val")"
    return 0
}
read_line() { Ui::read_line UI "$1" "$2"; }

# 回车继续
pause_for_confirm() {
    local __dummy
    [[ "${UI[non_interactive]:-0}" == "1" ]] && return 0
    printf '\n'
    read -r -p "按回车继续，Ctrl+C 取消…" __dummy || true
    return 0
}

# -----------------------------------------------------------------------------
# 类：Menu —— 通用菜单
#   字段: title / prompt / items(数组) / cmds(数组) / choice
#   用法:
#     Menu::new M "主菜单" "请选择"
#     Menu::add M "安装 CUDA" "cuda-manager.sh install"
#     Menu::run M        → 选中项写入 M[choice]（1 基序号，0=退出）
# -----------------------------------------------------------------------------
Menu::new() {
    local -n __self_Menu_new=$1
    declare -gA "$1"
    __self_Menu_new[title]="${2:-菜单}"
    __self_Menu_new[prompt]="${3:-请选择}"
    __self_Menu_new[choice]=0
    declare -ga "${1}_ITEMS=()" "${1}_CMDS=()" "${1}_DESC=()"
}

Menu::add() {
    local -n __self_Menu_add=$1
    local label="$2" cmd="${3:-}" desc="${4:-}"
    local -n items="${1}_ITEMS" cmds="${1}_CMDS" descs="${1}_DESC"
    items+=("$label"); cmds+=("$cmd"); descs+=("$desc")
}

Menu::count() {
    local -n items="${1}_ITEMS"
    printf '%s' "${#items[@]}"
}

Menu::render() {
    local -n __self_Menu_render=$1
    local -n items="${1}_ITEMS" descs="${1}_DESC"
    local i n="${#items[@]}"
    printf '\n%s%s%s\n' "$C_BOLD" "${__self_Menu_render[title]}" "$C_RESET"
    printf '%s\n' "----------------------------------------------------------------"
    for (( i=0; i<n; i++ )); do
        printf '  %s%2d)%s %s' "$C_CYAN" "$((i+1))" "$C_RESET" "${items[i]}"
        [[ -n "${descs[i]:-}" ]] && printf '  %s%s%s' "$C_DIM" "${descs[i]}" "$C_RESET"
        printf '\n'
    done
    printf '  %s%2d)%s %s\n' "$C_CYAN" 0 "$C_RESET" "退出"
    printf '%s\n' "----------------------------------------------------------------"
}

# 返回 0=已选择（序号写入 M[choice]），1=用户选择退出
Menu::run() {
    local -n __self_Menu_run=$1
    local -n items="${1}_ITEMS"
    local n="${#items[@]}" ans
    (( n == 0 )) && { warn "菜单为空"; return 1; }
    Menu::render "$1"
    while true; do
        read -r -p "$(printf '%s [0-%d]: ' "${__self_Menu_run[prompt]}" "$n")" ans || return 1
        ans="$(str::trim "$ans")"
        [[ -z "$ans" ]] && ans="0"
        if [[ "$ans" =~ ^[0-9]+$ ]] && (( ans >= 0 && ans <= n )); then
            __self_Menu_run[choice]=$(( 10#$ans ))
            (( __self_Menu_run[choice] == 0 )) && return 1
            return 0
        fi
        warn "请输入 0 到 ${n} 之间的数字"
    done
}

# -----------------------------------------------------------------------------
# 默认全局 Ui 对象（历史脚本直接调用 confirm / prompt 时走它）
# -----------------------------------------------------------------------------
Ui::new UI
