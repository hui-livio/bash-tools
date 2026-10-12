#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
#  lib/40-exec.sh —— 类 Runner：命令执行封装（dry-run / 提权 / 日志 / 退出码）
#
#  历史脚本里出现过 6 套 run()，语义各不相同（有的 tee 日志、有的自动 sudo、
#  有的失败即中断、有的只返回码）。这里统一成一个可配置对象：
#
#  字段: dry_run(0|1)  sudo("" 或 sudo)  logref(日志对象名)
#        fatal(0|1 失败是否中止脚本)   show(0|1 是否回显命令)  rc(上次退出码)
#
#  用法:
#     Runner::new R; R[dry_run]=$DRY_RUN; R[fatal]=1
#     Runner::exec R apt-get install -y cmake      # 失败按 fatal 处理
#     Runner::try  R ls /notexist                  # 失败只返回码
#     echo "${R[rc]}"
# =============================================================================

[[ -n "${__LIB_EXEC_LOADED:-}" ]] && return 0
__LIB_EXEC_LOADED=1

Runner::new() {
    local -n __self_Runner_new=$1
    declare -gA "$1"
    __self_Runner_new[dry_run]="${DRY_RUN:-0}"
    __self_Runner_new[sudo]=""
    __self_Runner_new[logref]="LOG"
    __self_Runner_new[fatal]=0
    __self_Runner_new[show]=1
    __self_Runner_new[rc]=0
    __self_Runner_new[prefix]=""
}

Runner::_render() {
    local out="" a
    for a in "$@"; do
        if [[ "$a" == *" "* || -z "$a" ]]; then out+="'$a' "; else out+="$a "; fi
    done
    printf '%s' "${out% }"
}

# -----------------------------------------------------------------------------
# 核心执行：Runner::exec <对象> 命令...
# -----------------------------------------------------------------------------
Runner::exec() {
    local -n __self_Runner_exec=$1; shift
    local -a cmd=()
    [[ -n "${__self_Runner_exec[sudo]}" ]]  && cmd+=("${__self_Runner_exec[sudo]}")
    [[ -n "${__self_Runner_exec[prefix]}" ]] && cmd+=("${__self_Runner_exec[prefix]}")
    cmd+=("$@")

    local rendered; rendered="$(Runner::_render "${cmd[@]}")"

    if [[ "${__self_Runner_exec[dry_run]}" == "1" ]]; then
        printf '%s[dry-run]%s %s\n' "$C_DIM" "$C_RESET" "$rendered"
        __self_Runner_exec[rc]=0
        return 0
    fi

    Logger::raw "${__self_Runner_exec[logref]}" "[$(Logger::stamp)] CMD: $rendered"
    [[ "${__self_Runner_exec[show]}" == "1" ]] && printf '%s$ %s%s\n' "$C_DIM" "$rendered" "$C_RESET"

    "${cmd[@]}"
    local rc=$?
    __self_Runner_exec[rc]=$rc
    Logger::raw "${__self_Runner_exec[logref]}" "[$(Logger::stamp)] EXIT($rc): $rendered"
    if (( rc != 0 )); then
        if [[ "${__self_Runner_exec[fatal]}" == "1" ]]; then
            Logger::die "${__self_Runner_exec[logref]}" "命令失败（退出码 ${rc}）：${rendered}" "$rc"
        fi
        return $rc
    fi
    return 0
}

# 失败不中断，只返回码
Runner::try() {
    local -n __self_Runner_try=$1; shift
    local old="${__self_Runner_try[fatal]}"; __self_Runner_try[fatal]=0
    Runner::exec __self_Runner_try "$@"
    local rc=$?
    __self_Runner_try[fatal]="$old"
    return $rc
}

# 失败即中止（等价 fatal=1 的一次性调用）
Runner::must() {
    local -n __self_Runner_must=$1; shift
    local old="${__self_Runner_must[fatal]}"; __self_Runner_must[fatal]=1
    Runner::exec __self_Runner_must "$@"
    local rc=$?
    __self_Runner_must[fatal]="$old"
    return $rc
}

# -----------------------------------------------------------------------------
# 兼容历史 run() 语义：dry-run 打印、失败返回码不中断
# -----------------------------------------------------------------------------
Runner::run() {
    local -n __self_Runner_run=$1; shift
    Runner::exec __self_Runner_run "$@"
}

# -----------------------------------------------------------------------------
# Runner::tee <对象> <日志对象名> 命令...
#   输出同时进终端和日志文件，并以真实退出码返回（不被管道掩盖）。
#   历史脚本 update-system.sh / cuda-manager.sh 都各自实现过这套 tee 逻辑。
# -----------------------------------------------------------------------------
Runner::tee() {
    local -n __self_Runner_tee=$1; shift
    local logref="$1"; shift
    local -n __lg="$logref" 2>/dev/null || true
    local logfile="${__lg[file]:-}"
    local rendered; rendered="$(Runner::_render "$@")"

    if [[ "${__self_Runner_tee[dry_run]}" == "1" ]]; then
        printf '%s[dry-run]%s %s\n' "$C_DIM" "$C_RESET" "$rendered"
        __self_Runner_tee[rc]=0
        return 0
    fi

    Logger::raw "$logref" "[$(Logger::stamp)] EXEC: $rendered"
    local rc=0
    if [[ -n "$logfile" ]]; then
        "$@" 2>&1 | tee -a "$logfile"
        rc=${PIPESTATUS[0]}
    else
        "$@" 2>&1
        rc=$?
    fi
    __self_Runner_tee[rc]=$rc
    Logger::raw "$logref" "[$(Logger::stamp)] EXIT($rc): $rendered"
    return $rc
}

# -----------------------------------------------------------------------------
# 全局默认 Runner（兼容脚本里裸调 run()）
#   run / run_priv 保持原语义：run 打印+执行，run_priv 自动 sudo
# -----------------------------------------------------------------------------
Runner::new RUN
RUN[fatal]=0
RUN[dry_run]="${DRY_RUN:-0}"

run() { Runner::exec RUN "$@"; }
run_priv() {
    local s; s="$(Sys::sudo_prefix)"
    local old="${RUN[sudo]}"; RUN[sudo]="$s"
    Runner::exec RUN "$@"
    local rc=$?
    RUN[sudo]="$old"
    return $rc
}

# -----------------------------------------------------------------------------
# 类：Fs —— 文件写入与备份回滚（历史脚本里 5 套 backup_file/write_file）
#   字段: suffix(备份后缀)  keep(保留份数)  logref
# -----------------------------------------------------------------------------
Fs::new() {
    local -n __self_Fs_new=$1
    declare -gA "$1"
    __self_Fs_new[suffix]="${BACKUP_SUFFIX:-bak}"
    __self_Fs_new[logref]="LOG"
    __self_Fs_new[dry_run]="${DRY_RUN:-0}"
    # 备份登记表放在文件里：backup 常在命令替换（子 shell）中调用，
    # 用数组登记会随子 shell 一起消失，导致 rollback 空转。
    __self_Fs_new[registry]="${FS_REGISTRY:-${TMPDIR:-/tmp}/.linux-ops-backup-$$}"
    : >> "${__self_Fs_new[registry]}" 2>/dev/null || true
    declare -ga "${1}_BACKUPS=()"
}

# Fs::backup <对象> <文件>  → 生成 <文件>.<suffix>-<时间戳>，失败返回 1
Fs::backup() {
    local -n __self_Fs_backup=$1
    local target="$2" dest
    if [[ ! -e "$target" ]]; then
        Logger::raw "${__self_Fs_backup[logref]}" "备份跳过（不存在）：$target"
        return 0
    fi
    dest="${target}.${__self_Fs_backup[suffix]}-$(date '+%Y%m%d-%H%M%S')"
    local n=1
    while [[ -e "$dest" ]]; do dest="${target}.${__self_Fs_backup[suffix]}-$(date '+%Y%m%d-%H%M%S')-$((n++))"; done
    if [[ "${__self_Fs_backup[dry_run]}" == "1" ]]; then
        printf '%s[dry-run]%s cp -a %s %s\n' "$C_DIM" "$C_RESET" "$target" "$dest"
        printf '%s' "$dest"; return 0
    fi
    if cp -a -- "$target" "$dest" 2>/dev/null; then
        printf '%s\t%s\n' "$dest" "$target" >> "${__self_Fs_backup[registry]}" 2>/dev/null || true
        local -n bl="${1}_BACKUPS"; bl+=("$dest")
        Logger::raw "${__self_Fs_backup[logref]}" "已备份：$target -> $dest"
        printf '%s' "$dest"
        return 0
    fi
    Logger::_emit "${__self_Fs_backup[logref]}" "警告" "yellow" 2 "备份失败（只读文件系统？）：$target"
    return 1
}

# Fs::write <对象> <目标文件> <<< 内容（从 stdin 读）
Fs::write() {
    local -n __self_Fs_write=$1
    local target="$2" tmp
    if [[ "${__self_Fs_write[dry_run]}" == "1" ]]; then
        printf '%s[dry-run]%s 写入 %s（内容 %d 字节）\n' "$C_DIM" "$C_RESET" "$target" "$(wc -c 2>/dev/null || echo 0)"
        cat >/dev/null
        return 0
    fi
    Fs::backup __self_Fs_write "$target" >/dev/null || true
    tmp="$(Tmp::make_file)"
    cat > "$tmp"
    mkdir -p -- "$(dirname -- "$target")" 2>/dev/null || true
    if mv -f -- "$tmp" "$target" 2>/dev/null; then
        chmod 644 -- "$target" 2>/dev/null || true
        Logger::raw "${__self_Fs_write[logref]}" "已写入：$target"
        return 0
    fi
    Logger::_emit "${__self_Fs_write[logref]}" "错误" "red" 2 "写入失败：$target"
    return 1
}

# Fs::rollback <对象>  → 把登记过的备份全部还原
Fs::rollback() {
    local -n __self_Fs_rollback=$1
    local reg="${__self_Fs_rollback[registry]:-}"
    # 形如 "<备份路径>\t<原路径>" 的条目；同时从登记表文件（跨子 shell）和内存数组收集
    local -a dests=() origs=()
    local d o
    if [[ -n "$reg" && -r "$reg" ]]; then
        while IFS=$'\t' read -r d o; do
            [[ -n "${d:-}" && -n "${o:-}" ]] || continue
            dests+=("$d"); origs+=("$o")
        done < "$reg"
    fi
    local -n bl="${1}_BACKUPS"
    local b
    for b in "${bl[@]:-}"; do
        [[ -n "$b" ]] || continue
        dests+=("$b"); origs+=("${b%.*-*-*}")
    done

    local restored=0 i
    local -A __seen=()
    for (( i=0; i<${#dests[@]}; i++ )); do
        d="${dests[i]}"; o="${origs[i]}"
        [[ -n "$d" && -e "$d" && -n "$o" ]] || continue
        # 同一原文件可能被备份多次（backup + write 各一次），只还原最早的那份
        [[ -n "${__seen[$d]:-}" || -n "${__seen[orig:$o]:-}" ]] && continue
        __seen[$d]=1; __seen[orig:$o]=1
        if mv -f -- "$d" "$o" 2>/dev/null || cp -a -- "$d" "$o" 2>/dev/null; then
            Logger::_emit "${__self_Fs_rollback[logref]}" "信息" "blue" 1 "已还原：$o"
            restored=$(( restored + 1 ))
        fi
    done
    bl=()
    [[ -n "$reg" ]] && : > "$reg" 2>/dev/null
    if (( restored == 0 )); then
        Logger::_emit "${__self_Fs_rollback[logref]}" "警告" "yellow" 2 "没有可还原的备份"
        return 1
    fi
    return 0
}

# 默认全局 Fs 对象与历史兼容函数
Fs::new FS
backup_file() { Fs::backup FS "$1"; }
write_file()  { Fs::write  FS "$1"; }
