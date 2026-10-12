#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""按「起始行正则 → 结束行正则」把各脚本里重复的 helper 块替换为共享库调用。

之所以用脚本而不是手工编辑：这些块里含 \\033 转义，直接做文本替换容易出错。
"""
import re
from pathlib import Path

BASE = Path(__file__).resolve().parent


def replace_block(path: Path, start_re: str, end_re: str, new_text: str,
                  end_after: int = 0) -> str:
    """返回 'ok' | 'skip'（已打过补丁）。end_after=结束行之后再吞掉的行数"""
    text = path.read_text(encoding='utf-8')
    lines = text.split('\n')
    s_pat = re.compile(start_re)
    e_pat = re.compile(end_re)
    out, i, n, done = [], 0, len(lines), False
    while i < n:
        if not done and s_pat.search(lines[i]):
            j = i
            while j < n and not e_pat.search(lines[j]):
                j += 1
            if j >= n:
                raise SystemExit(f'未找到结束块 [{end_re}] @ {path.name}')
            out.extend(new_text.rstrip('\n').split('\n'))
            i, done = j + 1 + end_after, True
            continue
        out.append(lines[i])
        i += 1
    if not done:
        # 已经替换过（标记存在）就跳过，保证可重复执行
        first = new_text.strip('\n').split('\n')[0]
        if first and first in text:
            return 'skip'
        raise SystemExit(f'未找到起始块 [{start_re}] @ {path.name}')
    path.write_text('\n'.join(out), encoding='utf-8')
    return 'ok'


def lib_block(logfile='""', extra=''):
    # 用 __OPS_DIR 而不是 SCRIPT_DIR：部分脚本已把 SCRIPT_DIR 声明为 readonly
    return f'''__OPS_DIR="$(cd -- "$(dirname -- "${{BASH_SOURCE[0]}}")" >/dev/null 2>&1 && pwd)"
# shellcheck source=/dev/null
source "${{__OPS_DIR}}/lib/lib.sh"
unset __OPS_DIR
Lib::bootstrap {logfile}
Lib::install_err_trap
{extra}'''.rstrip('\n')


SPECS = []

# ===========================================================================
# setup_vimrc.sh
# ===========================================================================
SPECS.append(dict(
    file='setup_vimrc.sh',
    start=r'^info\(\) \{ printf .%s\[INFO\]',
    end=r'^\}$',
    new=lib_block('""', '''
dry()  { [ "${DRY_RUN:-0}" -eq 1 ] && printf '%s[dry-run]%s %s\\n' "$C_DIM" "$C_RESET" "$*" || true; }

run() {  # dry-run 包装 + 命令日志，统一走 lib/40-exec.sh 的 Runner
  RUN[dry_run]="${DRY_RUN:-0}"
  Runner::exec RUN "$@"
}'''),
))
SPECS.append(dict(
    file='setup_vimrc.sh',
    start=r'^osrel_get\(\) \{$',
    end=r'^\}$',
    new='''osrel_get() { OS::osrel "$1" "${2:-/etc/os-release}"; }''',
))
SPECS.append(dict(
    file='setup_vimrc.sh',
    start=r'^  local key=" \$\{OS_ID\} \$\{OS_LIKE\} "$',
    end=r'^  esac$',
    new='''  # 家族判定统一走 lib/20-os.sh（判定表与其余脚本共用一份）
  OS_FAMILY="$(OS::family_of "$OS_ID" "$OS_LIKE")"
  case "$OS_FAMILY" in unknown|"") OS_FAMILY="other" ;; esac''',
))
SPECS.append(dict(
    file='setup_vimrc.sh',
    start=r'^require_root\(\) \{$',
    end=r'^\}$',
    new='''require_root() {
  [ "$(Sys::euid)" -eq 0 ] && return 0
  if sys::has_cmd sudo; then
    info "需要 root 权限，改用 sudo 重新执行…"
    exec sudo -E bash "$0" "$@"
  fi
  die "请以 root 运行：sudo $0"
}''',
))

# ===========================================================================
# setup-zsh.sh
# ===========================================================================
SPECS.append(dict(
    file='setup-zsh.sh',
    start=r'^# ----------------------------- 彩色输出 --------------------------------------$',
    end=r'^die\(\)  \{ err "\$\*"; exit 1; \}$',
    new=lib_block('""', '''
log() { info "$*"; }      # 本脚本把 log 当作主输出通道，覆盖 lib 的静默 log'''),
))
SPECS.append(dict(
    file='setup-zsh.sh',
    start=r'^os_field\(\) \{$',
    end=r'^    return 1$',
    new='''os_field() { OS::osrel "$1" "${2:-/etc/os-release}"; }
detect_pm() {
    # 包管理器判定统一走 lib/20-os.sh（与 install-devtools / update-system 共用一份）
    PM="$(OS::detect_pm "" "${FORCE_PM:-}")"
    if [[ -z "$PM" ]]; then err "未识别到受支持的包管理器"; return 1; fi
    log "包管理器：$PM"
}''',
))
SPECS.append(dict(
    file='setup-zsh.sh',
    start=r'^run\(\) \{$',
    end=r'^\}$',
    new='''run() { RUN[dry_run]="${DRY_RUN:-0}"; Runner::exec RUN "$@"; }''',
))

# ===========================================================================
# install-devtools.sh
# ===========================================================================
SPECS.append(dict(
    file='install-devtools.sh',
    start=r'^# ----------------------------- 彩色输出 --------------------------------------$',
    end=r'^die\(\)  \{ err "\$\*"; exit 1; \}$',
    new=lib_block('""', '''
log() { info "$*"; }      # 本脚本把 log 当作主输出通道，覆盖 lib 的静默 log'''),
))
SPECS.append(dict(
    file='install-devtools.sh',
    start=r'^os_field\(\) \{$',
    end=r'^}$',
    new='''os_field() { OS::osrel "$1" "${2:-/etc/os-release}"; }

OS_NAME="unknown"; OS_VERSION=""; OS_ID=""; OS_ID_LIKE=""; OS_MAJOR=""
detect_os() {
    # os-release 解析统一走 lib/20-os.sh 的 OS 对象（不再各自 source /etc/os-release）
    OS_ID="${SYS[id]}";       OS_ID_LIKE="${SYS[id_like]}"
    OS_NAME="${SYS[name]}";   OS_VERSION="${SYS[version]}"
    OS_MAJOR="${SYS[major]}"; OS_FAMILY="${SYS[family]}"
}''',
))
SPECS.append(dict(
    file='install-devtools.sh',
    start=r'^detect_pm\(\) \{$',
    end=r'^}$',
    new='''detect_pm() {
    if [[ -n "$FORCE_PM" ]]; then
        case "$FORCE_PM" in
            apt|dnf|yum|zypper|pacman|apk|xbps|emerge) ;;
            *) die "不支持的 --pm 值: $FORCE_PM（可选: apt|dnf|yum|zypper|pacman|apk|xbps|emerge）" ;;
        esac
        PM="$FORCE_PM"
        sys::has_cmd "$PM" || sys::has_cmd "${PM}-get" \\
            || warn "强制指定的包管理器 $PM 似乎不存在，仍按指定执行"
        return 0
    fi
    PM="$(OS::detect_pm "${OS_FAMILY:-unknown}" "")"
    if [[ -z "$PM" ]]; then die "未识别到受支持的包管理器"; fi
}''',
))
SPECS.append(dict(
    file='install-devtools.sh',
    start=r'^run\(\) \{$',
    end=r'^\}$',
    new='''run() {
    # dry-run 渲染 + 命令日志统一走 lib/40-exec.sh 的 Runner
    RUN[dry_run]="${DRY_RUN:-0}"
    Runner::exec RUN "$@"
}''',
))

# ===========================================================================
# configure-mirrors.sh
# ===========================================================================
SPECS.append(dict(
    file='configure-mirrors.sh',
    start=r'^if \[\[ -t 1 \]\]; then$',
    end=r'^trap _on_err ERR$',
    new=lib_block('"${MIRROR_LOG_FILE:-/var/log/china-mirrors.log}"', '''
# 说明：颜色、info/warn/die、日志落盘、ERR 陷阱全部由 lib/ 提供。
#       下面的 init_log 只在日志文件不可写时把它降级到 /tmp。'''),
))
SPECS.append(dict(
    file='configure-mirrors.sh',
    start=r'^# 中文表格对齐: 按显示宽度\(中文一字算 2\)补空格$',
    end=r'^\}$',
    new='''# 中文表格对齐（disp_width / item）沿用 lib/10-ui.sh 的实现，此处不再重复定义''',
))
SPECS.append(dict(
    file='configure-mirrors.sh',
    start=r'^item\(\) \{ # 标签 值 \[缩进\] \[列宽\]$',
    end=r'^\}$',
    new='''# item() 由 lib/10-ui.sh 提供，列宽默认 26 与此处不同，统一到 26：
item() { Ui::item UI "$1" "$2" "${3:-2}" "${4:-26}"; }''',
))
SPECS.append(dict(
    file='configure-mirrors.sh',
    start=r'^confirm\(\) \{ # 提示语; 返回 0 = 是$',
    end=r'^\}$',
    new='''confirm() { # 提示语; 返回 0 = 是（统一走 lib/10-ui.sh 的 Ui::confirm）
  local prompt="$1"
  if [[ "${ASSUME_YES:-0}" == "1" ]]; then
    info "$prompt —— 已通过 --yes 自动确认为[是]"
    return 0
  fi
  if [[ ! -t 0 ]]; then
    die "非交互环境无法确认「$prompt」, 请追加 --yes 参数"
  fi
  Ui::confirm UI "$prompt" n
}''',
))
SPECS.append(dict(
    file='configure-mirrors.sh',
    start=r'^init_log\(\) \{$',
    end=r'^\}$',
    new='''init_log() {
  if [[ -z "${LOG_FILE:-}" ]]; then
    LOG_FILE="/tmp/china-mirrors.log"
    touch "$LOG_FILE" 2>/dev/null || LOG_FILE=""
    if [[ -n "$LOG_FILE" ]]; then LOG[file]="$LOG_FILE"; fi
  fi
  Logger::raw LOG "===== configure-mirrors.sh v${VERSION} 启动 ====="
  return 0
}''',
))

# ===========================================================================
# env_deploy.sh
# ===========================================================================
SPECS.append(dict(
    file='env_deploy.sh',
    start=r'^if \[\[ -t 1 \]\]; then$',
    end=r'^confirm\(\)\{',
    new=lib_block('"$LOG_FILE"', '''
need(){ command -v "$1" >/dev/null 2>&1 || die "缺少命令：$1"; }
confirm(){ ((ASSUME_YES)) && return 0; Ui::confirm UI "$1" n; }
log(){ Logger::raw LOG "$*"; }'''),
))

# ===========================================================================
# cuda-manager.sh —— 只替换「通用型」helper，业务相关的诊断/安装逻辑一律保留
# ===========================================================================
SPECS.append(dict(
    file='cuda-manager.sh',
    start=r"^C_RESET=''; C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''; C_BOLD=''; C_DIM=''$",
    end=r'"\$l" "\$p" "" "\$v"$',
    end_after=1,
    new=lib_block('""', '''
say()  { printf '%s\\n' "$*"; }
hr()   { printf '%s\\n' "--------------------------------------------------------------------------------"; }

# info / ok / warn / err / step / hint / disp_width / item 由 lib/ 提供：
#   * info/ok/warn/err/step/hint → lib/00-core.sh 的 Logger
#   * disp_width                 → lib/10-ui.sh 的 Ui::disp_width
#   * item                       → lib/10-ui.sh 的 Ui::item（列宽默认取本脚本的 22）
item() { Ui::item UI "$1" "$2" "${3:-2}" "${4:-22}"; }

# 左对齐补位（本脚本自有的排版需求）
pad() {
  local s="$1" w="$2" dw p
  dw="$(Ui::disp_width "$s")" || dw=0
  p=$(( w - dw ))
  [[ $p -lt 1 ]] && p=1
  printf '%s%*s' "$s" "$p" ""
}'''),
))
SPECS.append(dict(
    file='cuda-manager.sh',
    start=r'^_log_raw\(\) \{$',
    end=r'^\}$',
    new='''_log_raw() { Logger::raw LOG "$*"; }''',
))
SPECS.append(dict(
    file='cuda-manager.sh',
    start=r'^read_line\(\) \{$',
    end=r'^\}$',
    new='''read_line() {   # 打印式读取（本脚本大量用于命令替换）；内部走 lib 的 Ui::read_line
  local __v=""
  Ui::read_line UI __v "$1" || true
  printf '%s' "$__v"
}''',
))
SPECS.append(dict(
    file='cuda-manager.sh',
    start=r'^confirm\(\) \{$',
    end=r'^\}$',
    new='''confirm() {
  # 是否继续类提问：受 -y 影响（本脚本用 yes/no 字符串，这里做一次映射）
  local msg="$1"
  if [[ "$ASSUME_YES" == "yes" ]]; then
    info "$msg → 已由 -y 自动确认"
    return 0
  fi
  if [[ ! -t 0 ]]; then
    err "当前不是交互终端，无法提问：$msg"
    err "请在终端中运行，或显式加上 -y 参数。"
    return 1
  fi
  UI[assume_yes]=0
  Ui::confirm UI "$msg" n
}''',
))
SPECS.append(dict(
    file='cuda-manager.sh',
    start=r'^ask_feature\(\) \{$',
    end=r'^\}$',
    new='''ask_feature() {   # 功能开关：不受 -y 影响，默认否
  [[ -t 0 ]] || return 1
  Ui::feature UI "$1" n
}''',
))
SPECS.append(dict(
    file='cuda-manager.sh',
    start=r'^_osrel\(\) \{$',
    end=r'^\}$',
    new='''_osrel() { OS::osrel "$1" "${2:-/etc/os-release}"; }''',
))
SPECS.append(dict(
    file='cuda-manager.sh',
    start=r'^detect_os\(\) \{$',
    end=r'^\}$',
    new='''detect_os() {
  # 复用 lib/20-os.sh 的检测结果（os-release 解析规则全库统一）
  OS_ID="${SYS[id]}";     OS_ID_LIKE="${SYS[id_like]}"
  OS_VER="${SYS[version]}"; OS_NAME="${SYS[pretty]}"
  [[ -n "$OS_NAME" ]] || OS_NAME="${OS_ID:-未知发行版} ${OS_VER}"
  return 0
}''',
))
SPECS.append(dict(
    file='cuda-manager.sh',
    start=r'^detect_wsl\(\) \{$',
    end=r'^\}$',
    new='''detect_wsl() {
  WSL="no"; WSL_VER=""
  if [[ "${SYS[wsl]}" == "1" ]]; then
    WSL="yes"
    if [[ "${SYS[wsl_version]}" == "2" ]]; then WSL_VER="WSL2"; else WSL_VER="WSL1"; fi
  fi
  return 0
}''',
))
SPECS.append(dict(
    file='cuda-manager.sh',
    start=r'^detect_family\(\) \{$',
    end=r'^\}$',
    new='''detect_family() {
  # 家族判定表统一在 lib/20-os.sh（已做大小写归一），这里只补 CUDA 需要的包管理器映射
  FAMILY="$(OS::family_of "$OS_ID" "$OS_ID_LIKE")"
  case "$FAMILY" in
    debian) PKG_MGR="apt" ;;
    rhel)   PKG_MGR="dnf" ;;
    suse)   PKG_MGR="zypper" ;;
    arch)   PKG_MGR="pacman" ;;
    alpine) PKG_MGR="apk" ;;
    *)      FAMILY="unknown"; PKG_MGR="" ;;
  esac
  # dnf 不存在时退回 yum
  if [[ "$PKG_MGR" == "dnf" ]] && ! sys::has_cmd dnf; then PKG_MGR="yum"; fi
  return 0
}''',
))

if __name__ == '__main__':
    for spec in SPECS:
        r = replace_block(BASE / spec['file'], spec['start'], spec['end'], spec['new'],
                          end_after=spec.get('end_after', 0))
        print(f"[{r:4s}] {spec['file']:24s} <- {spec['start'][:48]}")
