#!/usr/bin/env bash
# =============================================================================
#  panel.sh —— Linux 运维脚本箱 · 交互式总控面板
#
#  本目录下所有脚本共用一个 lib/ 共享库（日志 / 交互 / 发行版识别 / 包管理器 /
#  服务 / MariaDB 客户端 / 备份），本面板负责把它们统一呈现在一个菜单里。
#
#  用法：
#    bash panel.sh                 进入交互式面板
#    bash panel.sh <脚本名> [参数]  直接转发给对应脚本（等价手敲，便于写别名）
#    bash panel.sh --list          列出所有可用脚本
#    bash panel.sh --dry-run-on    全局打开演练模式（只打印命令，不改动系统）
#
#  面板能力：
#    · 自动发现目录里的 *.sh（排除 lib/ 与 legacy/），无需手工登记
#    · 每个脚本可声明子命令：在脚本里写一行
#        # PANEL: <标题> | <分类> | <是否需要root 0|1> | <说明>
#      再写若干行
#        # PANEL-CMD: <显示名> | <参数模板> | <说明>
#      面板就会把它们渲染成可直接执行的菜单项
#    · 选择后会展示完整命令行，可二次编辑参数再执行
#    · 支持全局演练开关、sudo 自动提权、实时显示运行环境
# =============================================================================
set -Eeuo pipefail

PANEL_VERSION="1.0.0"
PANEL_NAME="${0##*/}"
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

# shellcheck source=/dev/null
source "${ROOT_DIR}/lib/lib.sh"
Lib::bootstrap ""
Lib::install_err_trap
# 说明：这里不安装 EXIT 清理陷阱 —— bash 的子 shell（命令替换）会继承 EXIT 陷阱，
#       导致临时文件在父进程还在用时就被删掉。临时文件改在退出前显式回收。

PANEL_DRY=0          # 1 = 全局附加 --dry-run
PANEL_SUDO=1         # 1 = 需要 root 的条目自动加 sudo
PANEL_LOG="${TMPDIR:-/tmp}/linux-panel.log"

# ===========================================================================
#  类：Module —— 一个被面板管理的脚本
#    字段: file / title / category / need_root / desc
#    子命令: CMDS 数组，元素形如 "显示名|参数模板|说明"
# ===========================================================================
declare -ga MODULES=()          # 模块名（用于派生数组名）

Module::new() {
    local -n __self_Module_new=$1; declare -gA "$1"
    __self_Module_new[file]="$2"
    __self_Module_new[title]="${3:-$2}"
    __self_Module_new[category]="${4:-其他}"
    __self_Module_new[need_root]="${5:-0}"
    __self_Module_new[desc]="${6:-}"
    declare -ga "${1}_NAME=()" "${1}_ARGS=()" "${1}_NOTE=()"
}

Module::add_cmd() {
    local -n __self_Module_add_cmd=$1
    local -n names="${1}_NAME" args="${1}_ARGS" notes="${1}_NOTE"
    names+=("$2"); args+=("$3"); notes+=("${4:-}")
}

Module::cmd_count() { local -n c="${1}_NAME"; printf '%s' "${#c[@]}"; }

# ---------------------------------------------------------------------------
# 扫描目录，识别可管理的脚本（跳过大共享库、legacy 备份与本面板自身）
# ---------------------------------------------------------------------------
discover() {
    local f base
    local -a found=()
    while IFS= read -r f; do
        [[ -n "$f" ]] || continue
        base="${f##*/}"                       # 等价于 basename，但不起子 shell
        [[ "$base" == "panel.sh" ]] && continue
        [[ "$base" == "lib.sh"   ]] && continue
        found+=("$f")
    done < <(find "$ROOT_DIR" -maxdepth 1 -name '*.sh' -type f 2>/dev/null | sort)

    # 一次性抓取所有脚本的面板声明（一次 grep 搞定，不逐文件 fork）
    local -A panel_line=()
    local -a panel_cmds=()
    local line key
    if ((${#found[@]})); then
        while IFS= read -r line; do
            [[ -n "$line" ]] || continue
            key="${line%%:*}"
            if [[ "${line#*:}" == "# PANEL:"* ]]; then
                panel_line["${key##*/}"]="${line#*:}"
            elif [[ "${line#*:}" == "# PANEL-CMD:"* ]]; then
                panel_cmds+=("${key##*/}||${line#*:}")
            fi
        done < <(grep -H '^# PANEL' "${found[@]}" 2>/dev/null || true)
    fi

    for f in "${found[@]:-}"; do
        [[ -n "$f" ]] || continue
        base="${f##*/}"
        local title="$base" cat="其他" need=0 desc=""
        if [[ -n "${panel_line[$base]:-}" ]]; then
            local body="${panel_line[$base]#\# PANEL:}"
            IFS='|' read -r title cat need desc <<< "$body"
            str::trim_var title; str::trim_var cat; str::trim_var need; str::trim_var desc
            [[ -n "$title" ]] || title="$base"
            [[ -n "$cat"   ]] || cat="其他"
            [[ -n "$need"  ]] || need=0
        fi
        local mname="MOD_${base//[^A-Za-z0-9]/_}"
        Module::new "$mname" "$f" "$title" "$cat" "$need" "$desc"
        MODULES+=("$mname")
    done

    # 归入各自模块
    local entry owner cb n a d
    for entry in "${panel_cmds[@]:-}"; do
        [[ -n "$entry" ]] || continue
        owner="${entry%%||*}"; cb="${entry#*||}"
        cb="${cb#\# PANEL-CMD:}"
        IFS='|' read -r n a d <<< "$cb"
        str::trim_var n; str::trim_var a; str::trim_var d
        Module::add_cmd "MOD_${owner//[^A-Za-z0-9]/_}" "$n" "$a" "$d"
    done
}

# ===========================================================================
#  面板界面
# ===========================================================================
panel_banner() {
    printf '\n'
    printf '%s%s%s\n' "$C_BOLD" "╔══════════════════════════════════════════════════════════════════════╗" "$C_RESET"
    printf '%s%s%s\n' "$C_BOLD" "║            Linux 运维脚本箱 · 交互式总控面板  v${PANEL_VERSION}                ║" "$C_RESET"
    printf '%s%s%s\n' "$C_BOLD" "╚══════════════════════════════════════════════════════════════════════╝" "$C_RESET"
    printf '\n'
    Ui::table UI "当前环境" \
        "发行版|${SYS[pretty]}" \
        "系统族|${SYS[family]}（包管理器：${SYS[pm]:-未识别}）" \
        "架构|${SYS[arch]}" \
        "当前用户|$(id -un 2>/dev/null || echo '?')（uid $(Sys::euid)）" \
        "脚本目录|${ROOT_DIR}" \
        "演练模式|$([[ "$PANEL_DRY" == "1" ]] && echo '开（只打印不执行）' || echo '关')"
    printf '\n'
}

# 执行一条命令（含 sudo / dry-run / 回显）
exec_cmd() {
    local need_root="$1"; shift
    local -a cmd=(bash "$@")
    if [[ "$need_root" == "1" && "$PANEL_SUDO" == "1" && "$(Sys::euid)" != "0" ]]; then
        if sys::has_cmd sudo; then cmd=(sudo bash "$@"); else cmd=(bash "$@"); fi
    fi
    printf '\n%s将执行：%s\n' "$C_BOLD" "$C_RESET"
    printf '  %s\n' "$(Runner::_render "${cmd[@]}")"
    printf '%s\n' "----------------------------------------------------------------"
    Logger::raw LOG "[$(date '+%F %T')] PANEL EXEC: $(Runner::_render "${cmd[@]}")"
    printf '\n'
    "${cmd[@]}" || {
        local rc=$?
        printf '\n'
        warn "命令退出码 ${rc}"
        return $rc
    }
    return 0
}

# 渲染某个模块的子菜单并让用户挑一项
module_menu() {
    local m="$1"
    local -n mf="$m"
    local n; n="$(Module::cmd_count "$m")"
    local -n names="${m}_NAME" args="${m}_ARGS" notes="${m}_NOTE"

    if (( n == 0 )); then
        # 没有声明子命令：直接以「手工输入参数」方式运行
        local ans=""
        printf '\n%s%s%s\n' "$C_BOLD" "${mf[title]}" "$C_RESET"
        [[ -n "${mf[desc]}" ]] && printf '  %s\n' "${mf[desc]}"
        printf '  脚本：%s\n' "${mf[file]}"
        printf '\n'
        if Ui::confirm UI "直接执行（不加参数，脚本自带交互向导）" y; then
            exec_cmd "${mf[need_root]}" "${mf[file]}"
        fi
        return 0
    fi

    Menu::new SUB "${mf[title]}" "请选择要执行的操作"
    local i
    for (( i=0; i<n; i++ )); do
        Menu::add SUB "${names[i]}" "${args[i]}" "${notes[i]}"
    done
    if ! Menu::run SUB; then return 0; fi

    local idx=$(( SUB[choice] - 1 ))
    local tmpl="${args[idx]}"
    local shown
    shown="$(printf '%s' "$tmpl" | sed 's/{{[^}]*}}/<参数>/g')"
    printf '\n%s将执行：%s bash %s %s\n' "$C_BOLD" "$C_RESET" "${mf[file]##*/}" "$shown"

    # 参数模板里 {{提示}} 占位符会逐个询问
    local final="$tmpl" ph label val
    while [[ "$final" == *'{{'*'}}' ]]; do
        ph="${final#*\{\{}"; ph="${ph%%\}\}*}"
        label="${ph%%:*}"
        Ui::prompt UI val "$label" "${ph#*:}"
        final="${final/\{\{$ph\}\}/$val}"
    done

    if [[ "$PANEL_DRY" == "1" ]]; then
        final="${final:+$final }--dry-run"
    fi

    printf '\n'
    # 预填参数供编辑；直接回车 / 非交互 EOF 都保留模板里的默认值
    local input="$final"
    read -r -e -i "$final" -p "确认参数（可直接编辑，回车执行，Ctrl+C 取消）: " input || input="$final"
    [[ -z "$(str::trim "$input")" ]] && input="$final"
    final="$input"

    # shellcheck disable=SC2086
    exec_cmd "${mf[need_root]}" "${mf[file]}" $final
}

# 主菜单：按分类分组
main_menu() {
    local -a cats=() seen_cat=""
    local m
    for m in "${MODULES[@]}"; do
        local -n mm="$m"
        local c="${mm[category]}"
        if [[ " $seen_cat " != *" $c "* ]]; then cats+=("$c"); seen_cat+=" $c"; fi
    done

    Menu::new MAIN "主菜单" "请选择分类"
    local c
    for c in "${cats[@]}"; do Menu::add MAIN "$c" "__CAT__:$c"; done
    Menu::add MAIN "全局开关" "__OPTS__"
    Menu::add MAIN "刷新环境信息" "__REFRESH__"
    if ! Menu::run MAIN; then return 1; fi

    local -n mcmd="MAIN_CMDS"
    local pick="${mcmd[$(( MAIN[choice] - 1 ))]}"

    case "$pick" in
        __OPTS__)
            options_menu
            return 0 ;;
        __REFRESH__)
            OS::detect SYS
            info "环境信息已刷新"
            return 0 ;;
        __CAT__:*)
            local cat="${pick#__CAT__:}"
            category_menu "$cat"
            return 0 ;;
    esac
}

category_menu() {
    local cat="$1" m
    Menu::new CATM "分类：$cat" "请选择脚本"
    local -a in_cat=()
    for m in "${MODULES[@]}"; do
        local -n mm="$m"
        if [[ "${mm[category]}" == "$cat" ]]; then in_cat+=("$m"); Menu::add CATM "${mm[title]}" "$m" "${mm[desc]}"; fi
    done
    if ! Menu::run CATM; then return 0; fi
    local -n ccmd="CATM_CMDS"
    module_menu "${ccmd[$(( CATM[choice] - 1 ))]}"
}

options_menu() {
    Menu::new OM "全局开关" "请选择"
    Menu::add OM "演练模式（--dry-run）：$([[ $PANEL_DRY == 1 ]] && echo 开 || echo 关)" "dry"
    Menu::add OM "自动 sudo 提权：$([[ $PANEL_SUDO == 1 ]] && echo 开 || echo 关)" "sudo"
    Menu::add OM "查看面板日志：$PANEL_LOG" "log"
    if ! Menu::run OM; then return 0; fi
    local -n ocmd="OM_CMDS"
    case "${ocmd[$(( OM[choice] - 1 ))]}" in
        dry)  if [[ $PANEL_DRY == 1 ]]; then PANEL_DRY=0; else PANEL_DRY=1; fi ;;
        sudo) if [[ $PANEL_SUDO == 1 ]]; then PANEL_SUDO=0; else PANEL_SUDO=1; fi ;;
        log)  [[ -f "$PANEL_LOG" ]] && tail -n 40 "$PANEL_LOG" || info "暂无日志" ;;
    esac
}

list_modules() {
    local m
    local c1 c2 c3
    Ui::pad_var c1 "标题" 16; Ui::pad_var c2 "分类" 12; Ui::pad_var c3 "需root" 8
    printf '%s %s %s %s\n' "$c1" "$c2" "$c3" "脚本"
    printf '%s\n' "------------------------------------------------------------------------"
    local m
    for m in "${MODULES[@]}"; do
        local -n mm="$m"
        Ui::pad_var c1 "${mm[title]}" 16
        Ui::pad_var c2 "${mm[category]}" 12
        Ui::pad_var c3 "$([[ "${mm[need_root]}" == "1" ]] && echo 是 || echo 否)" 8
        printf '%s %s %s %s\n' "$c1" "$c2" "$c3" "${mm[file]##*/}"
    done
}

# ===========================================================================
#  入口
# ===========================================================================
main() {
    case "${1:-}" in
        -h|--help)
            awk 'NR==1 {next} /^#/ {sub(/^#[ \t]?/, ""); print; next} {exit}' "$0"
            exit 0 ;;
        --list)
            discover; list_modules; exit 0 ;;
        --dry-run-on)
            PANEL_DRY=1; shift || true ;;
    esac

    # 直接转发：panel.sh <脚本名或关键字> [参数...]
    if [[ -n "${1:-}" && "${1:0:2}" != "--" ]]; then
        local target="$1"; shift || true
        discover
        local m hit=""
        for m in "${MODULES[@]}"; do
            local -n mm="$m"
            if [[ "$(basename -- "${mm[file]}")" == "$target" || "${mm[title]}" == "$target" ]]; then
                hit="$m"; break
            fi
        done
        if [[ -n "$hit" ]]; then
            local -n hm="$hit"
            exec_cmd "${hm[need_root]}" "${hm[file]}" "$@"
            exit $?
        fi
        err "未找到脚本：$target（用 --list 查看可用脚本）"
        exit 1
    fi

    discover
    if (( ${#MODULES[@]} == 0 )); then
        die "在 ${ROOT_DIR} 下没有发现任何 .sh 脚本"
    fi

    while true; do
        panel_banner
        main_menu || break
        printf '\n'
        Ui::confirm UI "继续停留在面板" y || break
    done
    Tmp::cleanup
    ok "已退出面板。面板日志：${PANEL_LOG}"
}

main "$@"
