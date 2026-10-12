#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
#  cuda-manager.sh — NVIDIA CUDA Toolkit 环境管理器（检测 / 列版本 / 安装 / 卸载）
#  版本: 1.0.6
#
#  设计要点
#    * 只安装 CUDA Toolkit，绝不安装、绝不升级、绝不卸载显卡驱动
#    * 自动识别环境：WSL1 / WSL2 / Ubuntu / Debian / RHEL / CentOS / Rocky /
#      AlmaLinux / Fedora / openSUSE / SLES / Arch 等，自动识别 x86_64 / aarch64
#    * 联网从 NVIDIA 官方源动态读取「全部可选版本」，交互式选择安装
#    * 支持安装任意指定版本（可精确到补丁号，如 12.6.3）
#    * 支持卸载指定版本或全部版本，并清理环境变量、软链、软件源
#    * 多版本可共存，支持一条命令切换默认版本
#
#  用法
#    sudo bash cuda-manager.sh                     交互菜单
#    bash cuda-manager.sh detect                   环境检测 + 已安装版本
#    bash cuda-manager.sh list                     列出全部可安装版本
#    sudo bash cuda-manager.sh install 12.6        安装 CUDA 12.6
#    sudo bash cuda-manager.sh install 12.6.3      安装精确补丁版本
#    sudo bash cuda-manager.sh uninstall 12.6      卸载 12.6
#    sudo bash cuda-manager.sh uninstall all       卸载全部
#    sudo bash cuda-manager.sh use 12.6            切换默认版本
#    bash cuda-manager.sh doctor                   环境体检（只读）
#    sudo bash cuda-manager.sh repair              修复安装失败 / dpkg 中断等故障
#
#  常用选项
#    -y, --yes             自动确认「是否继续」类提问（不影响破坏性操作确认）
#    --dry-run             只打印将要执行的命令，不做任何实际改动
#    --method repo|runfile 安装方式，默认 repo（官方软件源）
#    --runfile-url URL     runfile 模式下直接指定安装包地址
#    --mirror auto|cn|com  下载源，默认 auto（优先国内镜像）
#    --no-index            不联网拉取版本清单，使用内置参考版本列表
#    --log FILE            指定日志文件（默认 /var/log/cuda-manager.log）
#    --no-color            关闭彩色输出
#
#  排障说明
#    * 所有外部命令（apt/dnf/zypper/pacman/curl/dpkg…）的完整 stdout+stderr
#      都会写入日志文件，失败时还会自动做故障归类并打印「失败诊断」。
#    * 安装失败时优先查看日志末尾，或直接运行 repair 子命令。
#
#  注意：脚本内所有提示信息均为中文；卸载属破坏性操作，需逐字输入 DELETE 确认。
# =============================================================================

set -Eeuo pipefail

SCRIPT_VERSION="1.0.6"
SCRIPT_NAME="$(basename -- "$0")"
WORK_DIR=""
BACKUP_DIR=""
LOG_FILE="/dev/null"
KEEP_TMP="no"
_TOLERANT=0
CUDA_LIST_FILE=""     # 当前使用的 CUDA 软件源文件路径

# ---------------------------------------------------------------- 命令行参数
ACTION=""
ARG_VERSION=""
ARG_EXTRA=()
DRY_RUN="no"
ASSUME_YES="no"
FORCE_DESTRUCTIVE="no"
METHOD="repo"
RUNFILE_URL=""
MIRROR="auto"
USE_INDEX="yes"
REPO_FORCE=""      # --repo：强制指定官方仓库标识（默认按系统自动适配）

# ---------------------------------------------------------------- 运行期状态
WSL="no"
WSL_VER=""
OS_ID=""
OS_ID_LIKE=""
OS_VER=""
OS_NAME="未知发行版"
FAMILY="unknown"
PKG_MGR=""
ARCH=""
REPO_ARCH=""
REPO_TAG=""
REPO_BASE=""
REPO_FALLBACK="no"
IS_JETSON="no"
SUDO=""

DRIVER_VER=""
GPU_LIST=""
GPU_PRESENT="unknown"
NVCC_VER=""
CUDA_LINK=""
CUDA_LINK_TARGET=""
REPO_STATE=""

INSTALLED_BRANCHES=()
INSTALLED_DIRS=()
INSTALLED_ROWS=""
INSTALLED_HINT=""

declare -A BRANCH_VER=()       # 分支(13-4) → 该分支可安装的最新补丁版本
declare -A BRANCH_REPO=()      # 分支 → 提供该分支的仓库标识（按分支自动适配的源）
declare -A TAG_MIRROR=()       # 仓库标识 → 实际取到索引的镜像根地址
ALL_BRANCHES=()
REPO_TAGS_OK=()                # 本次真正取到索引的仓库标识（按优先级排列）
REPO_TAGS_SKIP=()              # 取索引失败而跳过的候选仓库
REPO_PRIMARY_TAG=""            # 首选仓库：按当前系统推导出的第一个可用官方源
REPO_PRIMARY_BASE=""
REPO_LIMIT=3                   # 单次最多查询的官方仓库个数（控制下载量）
INDEX_FILE=""
VERSION_SOURCE=""

# ---------------------------------------------------------------- 内置参考版本
# 仅在内网不可达 / 指定 --no-index 时使用，并非完整列表
BUILTIN_BRANCHES=(
  "11-1" "11-2" "11-3" "11-4" "11-5" "11-6" "11-7" "11-8"
  "12-0" "12-1" "12-2" "12-3" "12-4" "12-5" "12-6" "12-8" "12-9"
  "13-0" "13-1" "13-2" "13-3" "13-4"
)
# 各分支参考所需的最低显卡驱动（仅作提示，非硬性校验）
declare -A MIN_DRIVER=(
  ["11"]="450.80" ["12"]="525.60" ["13"]="580.65"
)

# =============================================================================
#  一、基础输出与工具函数
# =============================================================================

__OPS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# shellcheck source=/dev/null
source "${__OPS_DIR}/lib/lib.sh"
unset __OPS_DIR
Lib::bootstrap ""
Lib::install_err_trap

say()  { printf '%s\n' "$*"; }
hr()   { printf '%s\n' "--------------------------------------------------------------------------------"; }
# hint 保持本脚本原有的缩进风格（lib 默认带 [提示] 前缀）
hint() { printf '%s      %s%s\n' "$C_DIM" "$*" "$C_RESET"; }

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
}

_log_init() {
  local cand=""
  if [[ -n "${CUDA_MANAGER_LOG:-}" ]]; then
    cand="$CUDA_MANAGER_LOG"
  elif [[ "$(id -u 2>/dev/null || echo 1)" == "0" && -d /var/log && -w /var/log ]]; then
    cand="/var/log/cuda-manager.log"
  else
    cand="${TMPDIR:-/tmp}/cuda-manager.log"
  fi
  if ! { : >>"$cand"; } 2>/dev/null; then
    cand="${TMPDIR:-/tmp}/cuda-manager.log"
    : >>"$cand" 2>/dev/null || cand="/dev/null"
  fi
  LOG_FILE="$cand"
  # 同步给共享库的 Logger 对象，后续 _log_raw / Logger 系列都写同一个文件
  LOG[file]="$LOG_FILE"
}

_log_raw() { Logger::raw LOG "$*"; }

# 最近一次外部命令的完整输出（用于失败诊断）
_cmd_out_file() {
  printf '%s' "${WORK_DIR:-${TMPDIR:-/tmp}}/last-command.out"
}

# 从输出里挑出真正有价值的报错行
_critical_lines() {
  local f="$1"
  [[ -f "$f" && -s "$f" ]] || return 0
  grep -aE '(^E: |^W: |^dpkg: |^Errors were encountered|No space left|no space left|trying to overwrite|corrupted|Hash Sum mismatch|Failed to fetch|returned error exit status|dpkg was interrupted|Could not get lock|Permission denied|Read-only file system|not enough free space|Cannot create symlink|File exists|unable to |^update-alternatives:|^Setting alternatives|^Setting up |not ready for configuration|does not exist|is not a symbolic link)' "$f" 2>/dev/null | tail -n 20 || true
}

# 从输出里提取失败包名（dpkg / rpm）
_failing_pkgs() {
  local f="$1"
  [[ -f "$f" && -s "$f" ]] || return 0
  {
    { grep -aoE '^dpkg: error processing package [^ ]+' "$f" 2>/dev/null | awk '{print $5}'; } || true
    awk '/^Errors were encountered while processing:/{g=1;next} g&&/^[ \t]+[^ \t]/{s=$0;gsub(/^[ \t]+/,"",s);print s} g&&!/^[ \t]/{g=0}' "$f" 2>/dev/null || true
  } | sort -u | head -n 15 || true
  return 0
}

_has() { grep -qaE "$2" "$1" 2>/dev/null; }

# 挑选最有代表性的报错行：优先 apt 的 "E: " 致命行，再补末尾若干行
_err_summary() {
  local lines="$1" n="${2:-2}" maxe="${3:-2}"
  [[ -n "$lines" ]] || return 0
  {
    printf '%s\n' "$lines" | awk -v maxe="$maxe" '/^E: /{e[++n]=$0} {a[++m]=$0} END{ for (i=1; i<=n && i<=maxe; i++) print e[i] }'
    printf '%s\n' "$lines" | tail -n "$n"
  } | awk 'NF && !seen[$0]++' || true
  return 0
}

# 失败诊断：把 dpkg/apt 的常见故障翻译成人话 + 给出可执行修复命令
_analyze_failure() {
  local f="$1" rc="$2" advice=0 pkgs="" p="" n=0
  pkgs="$(_failing_pkgs "$f")"
  [[ -s "$f" ]] || return 0

  say ""
  say "${C_BOLD}失败诊断（退出码 ${rc}）${C_RESET}"
  hr
  _log_raw "===== 失败诊断（退出码 ${rc}）====="

  if [[ -n "$pkgs" ]]; then
    item "失败软件包" "$(printf '%s ' $pkgs)"
    _log_raw "失败软件包: $(printf '%s ' $pkgs)"
    n=0
    for p in $pkgs; do
      n=$(( n + 1 ))
      [[ $n -gt 3 ]] && break
      if [[ -f "/var/lib/dpkg/info/${p}.postinst" ]]; then
        hint "重跑 ${p} 的配置脚本： sudo dpkg --configure ${p}"
        hint "查看该脚本： cat /var/lib/dpkg/info/${p}.postinst"
      fi
    done
    advice=$(( advice + 1 ))
  fi

  if _has "$f" 'No space left on device|no space left on device|not enough free space|Broken pipe|paste subprocess'; then
    err "磁盘空间不足（dpkg 解包中途写满）"
    hint "CUDA Toolkit 13.x 完整安装约需 6~10GB，下载缓存另需 3~4GB。"
    hint "立即清理： sudo apt-get clean && sudo rm -rf /var/cache/apt/archives/*.deb"
    hint "查看空间： df -h / /var /usr/local"
    hint "WSL 扩容： PowerShell 执行 wsl --shutdown，再扩 ext4.vhdx（Windows 侧磁盘管理）"
    advice=$(( advice + 1 ))
  fi

  if _has "$f" 'trying to overwrite'; then
    err "文件覆盖冲突：本次要安装的文件已属于另一个包或来自旧的手工安装"
    hint "被占用的路径见上方 dpkg 提示中 '... which is also in package X' 一段。"
    hint "若是 runfile 残留，请先移走： sudo mv /usr/local/cuda-<版本> /root/cuda-old"
    advice=$(( advice + 1 ))
  fi

  if _has "$f" 'dpkg was interrupted|dpkg --configure -a'; then
    err "dpkg 处于中断状态（上次操作未完成）"
    hint "先修复再重试： sudo dpkg --configure -a"
    advice=$(( advice + 1 ))
  fi

  if _has "$f" 'Could not get lock|frontend lock|lock-frontend'; then
    err "apt/dpkg 已被其他进程占用"
    hint "等待或结束占用进程： ps aux | grep -E 'apt|dpkg'"
    advice=$(( advice + 1 ))
  fi

  if _has "$f" 'corrupted package archive|Hash Sum mismatch|unexpected end of file|Failed to fetch|Size mismatch|Unable to fetch'; then
    err "安装包下载不完整或校验失败（镜像源问题居多）"
    hint "清缓存后换官方源重试： sudo apt-get clean，再执行"
    hint "  sudo bash ${SCRIPT_NAME} --mirror com install <版本>"
    advice=$(( advice + 1 ))
  fi

  # ---- 最常见的 CUDA 专属故障：postinst 里的 update-alternatives 报错 ----
  if _has "$f" 'alternative path .* (does not|doesn.t) exist'; then
    err "postinst 里的 update-alternatives 失败：它要注册的目录不存在。"
    hint "NVIDIA 的 cuda-toolkit-X-Y-config-common.postinst 内容是："
    hint "  update-alternatives --install /usr/local/cuda cuda /usr/local/cuda-X.Y <优先级>"
    hint "update-alternatives 要求该路径必须先存在，否则直接退出 2；因为 postinst 带 set -e，"
    hint "整个配置阶段失败 → 包永久停留在 iF，之后任何 apt/dpkg 操作都会以同样错误失败。"
    hint "典型成因：卸载时删掉了 /usr/local/cuda-X.Y，但对应的 config-common 包没被一起卸载。"
    hint "修复（自动补目录解锁 + 清理残留）： sudo bash ${SCRIPT_NAME} repair"
    advice=$(( advice + 1 ))
  fi

  if _has "$f" "not ready for configuration|current status 'config-files'"; then
    err "该包只剩配置文件（dpkg 状态 ic），dpkg 想配置它却无从下手。"
    hint "处理方式： sudo dpkg --purge <包名>   然后重新安装"
    advice=$(( advice + 1 ))
  fi

  if _has "$f" 'post-installation script|postinst|maintainer script'; then
    err "某个包的安装/配置脚本自身报错（上方原文里已含具体那一行）"
    hint "看脚本内容： cat /var/lib/dpkg/info/<包名>.postinst"
    hint "逐行定位失败点： sudo bash -x /var/lib/dpkg/info/<包名>.postinst configure 2>&1 | tail -40"
    advice=$(( advice + 1 ))
  fi

  # WSL 下这句极易被误判成元凶，实际不会影响退出码（glibc 用 error(0,…) 打印）
  if _has "$f" 'is not a symbolic link|Can.t link .* to '; then
    info "（说明）ldconfig 在 WSL 的已知噪音：/usr/lib/wsl/lib 里的驱动库不是符号链接。"
    hint "经查 glibc 源码，这类消息走 error(0,…)，只打印、不改退出码——它不是本次失败的原因。"
  fi

  if _has "$f" 'No such file or directory'; then
    warn "存在找不到文件的错误，可能由残留配置或符号链接指向不存在的目录引起。"
  fi

  if [[ $advice -eq 0 ]]; then
    hint "未匹配到已知故障特征，请提供日志中本段完整输出："
    hint "$LOG_FILE"
  else
    say ""
    hint "一键修复尝试： sudo bash ${SCRIPT_NAME} repair"
    hint "完整日志（含原始输出）： $LOG_FILE"
  fi
  hr
  return 0
}

# 统一的外部命令执行入口
#   mode: strict   → 失败即中止（由 ERR 陷阱接管），并打印诊断
#         diag     → 失败不中止，但打印诊断
#         soft     → 失败静默忽略
# 注意：_TOLERANT 必须一直保持到本函数结束，否则内部子壳（命令替换/管道）里
#       任何非零退出都会被 ERR 陷阱直接杀掉，导致诊断数据丢失。
_exec_tee() {
  local mode="$1"; shift
  local out="" rc=0 crit=""
  out="$(_cmd_out_file)"
  : >"$out" 2>/dev/null || true
  _log_raw "----- 输出开始：$* -----"
  _TOLERANT=1
  set +e
  "$@" 2>&1 | tee -a "$out" | tee -a "$LOG_FILE"
  rc=${PIPESTATUS[0]}
  _log_raw "----- 退出码：${rc} -----"
  if [[ "$rc" -ne 0 ]]; then
    crit="$(_critical_lines "$out")"
    if [[ -n "$crit" ]]; then
      _log_raw "----- 关键报错行 -----"
      _log_raw "$crit"
    fi
    [[ "$mode" == "soft" ]] || _analyze_failure "$out" "$rc"
  fi
  set -e
  _TOLERANT=0
  if [[ "$rc" -ne 0 && "$mode" == "strict" ]]; then
    return "$rc"
  fi
  return 0
}

run() {
  local desc="$1"; shift
  if [[ "$DRY_RUN" == "yes" ]]; then
    info "[演练] $desc"
    hint "命令: $*"
    return 0
  fi
  info "$desc"
  _log_raw "EXEC: $*"
  _exec_tee strict "$@"
}

# 允许失败的命令（失败静默忽略）
run_ok() {
  local desc="$1"; shift
  if [[ "$DRY_RUN" == "yes" ]]; then
    info "[演练] $desc"
    hint "命令: $*"
    return 0
  fi
  info "$desc"
  _log_raw "EXEC(tolerant): $*"
  _exec_tee soft "$@" || true
  return 0
}

# 允许失败、但会打印诊断的命令（用于 repair 场景）
run_diag() {
  local desc="$1"; shift
  if [[ "$DRY_RUN" == "yes" ]]; then
    info "[演练] $desc"
    hint "命令: $*"
    return 0
  fi
  info "$desc"
  _log_raw "EXEC(diag): $*"
  _exec_tee diag "$@"
  return 0
}

# 交互读取（非交互环境安全）
read_line() {   # 打印式读取（本脚本大量用于命令替换）；内部走 lib 的 Ui::read_line
  local __v=""
  Ui::read_line UI __v "$1" || true
  printf '%s' "$__v"
}

# 是否继续类提问：受 -y 影响
confirm() {
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
}

# 功能开关类提问：不受 -y 影响，默认否
ask_feature() {   # 功能开关：不受 -y 影响，默认否
  [[ -t 0 ]] || return 1
  Ui::feature UI "$1" n
}

# 破坏性操作确认：必须逐字输入确认词，-y 不生效
ask_destructive() {
  local a=""
  if [[ "$FORCE_DESTRUCTIVE" == "yes" ]]; then
    warn "已通过 --force-destructive 跳过逐字确认。"
    return 0
  fi
  if [[ "$DRY_RUN" == "yes" ]]; then
    info "[演练] 跳过破坏性确认"
    return 0
  fi
  if [[ ! -t 0 ]]; then
    err "非交互终端下禁止执行破坏性操作。"
    err "如确认无误，请显式加上 --force-destructive。"
    return 1
  fi
  say ""
  warn "此操作会删除上述软件包与目录，且不可撤销。"
  a="$(read_line "请输入大写单词 DELETE 以确认执行（其他任意输入将取消）: ")"
  if [[ "$a" == "DELETE" ]]; then
    return 0
  fi
  info "已取消。"
  return 1
}

_write_file() {
  local path="$1" content="$2"
  if [[ "$DRY_RUN" == "yes" ]]; then
    info "[演练] 写入文件 $path"
    printf '%s\n' "$content" | sed 's/^/      | /'
    return 0
  fi
  _backup_file "$path"
  printf '%s\n' "$content" >"$path"
  _log_raw "WRITE: $path"
}

_backup_file() {
  local path="$1" b=""
  [[ -e "$path" ]] || return 0
  [[ -n "$BACKUP_DIR" ]] || return 0
  b="$BACKUP_DIR/$(printf '%s' "$path" | sed 's#^/##; s#/#__#g')"
  cp -a -- "$path" "$b" 2>/dev/null || true
  return 0
}

# 需要 root 的操作统一入口
require_root() {
  if [[ "$(id -u)" == "0" ]]; then
    SUDO=""
    return 0
  fi
  if command -v sudo >/dev/null 2>&1; then
    SUDO="sudo"
    return 0
  fi
  err "该操作需要 root 权限，且系统未安装 sudo。请用 root 用户运行。"
  exit 1
}

# =============================================================================
#  二、错误陷阱与清理
# =============================================================================

_ERR_DONE=0
_on_err() {
  local rc=$? last="" l=""
  [[ "$_TOLERANT" == "1" ]] && return 0
  if [[ "${BASH_SUBSHELL:-0}" -gt 0 ]]; then
    exit "$rc"
  fi
  [[ "$_ERR_DONE" == "1" ]] && return 0
  _ERR_DONE=1
  _TOLERANT=1
  # 主动 exit N（如参数错误、未知子命令）时调用方已说明原因，不重复报错
  if [[ "${BASH_COMMAND:-}" =~ ^exit[[:space:]]+[0-9]+$ ]]; then
    exit "$rc"
  fi
  printf '\n' >&2
  err "脚本已中止（退出码 ${rc}）。"
  last="$(_err_summary "$(_critical_lines "$(_cmd_out_file)" 2>/dev/null || true)" 2 2)"
  if [[ -n "$last" ]]; then
    while IFS= read -r l; do
      [[ -n "$l" ]] && err "失败原因：${l}"
    done <<<"$last"
  else
    err "最后失败的命令：${BASH_COMMAND}"
  fi
  [[ "$LOG_FILE" == "/dev/null" ]] || err "完整日志：${LOG_FILE}"
  case "$rc" in
    1) hint "常见原因：参数错误、目标版本不存在、权限不足，或软件包的安装脚本执行失败。" ;;
    100) hint "常见原因：软件包管理器返回错误，请检查上方输出。" ;;
    127) hint "常见原因：命令不存在，可能是发行版工具链差异。" ;;
  esac
  hint "安装类故障可尝试自动修复： sudo bash ${SCRIPT_NAME} repair"
  exit "$rc"
}

_on_exit() {
  local rc=$?
  set +e
  if [[ "$KEEP_TMP" != "yes" && -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
    rm -rf -- "$WORK_DIR" 2>/dev/null
  fi
  return "$rc"
}

trap '_on_err' ERR
trap '_on_exit' EXIT

# =============================================================================
#  三、环境检测
# =============================================================================

detect_wsl() {
  WSL="no"; WSL_VER=""
  if [[ "${SYS[wsl]}" == "1" ]]; then
    WSL="yes"
    if [[ "${SYS[wsl_version]}" == "2" ]]; then WSL_VER="WSL2"; else WSL_VER="WSL1"; fi
  fi
  return 0
}

# 读取 /etc/os-release 的字段（避免 source 带来的 set -u 风险）
_osrel() { OS::osrel "$1" "${2:-/etc/os-release}"; }

detect_os() {
  # 复用 lib/20-os.sh 的检测结果（os-release 解析规则全库统一）
  OS_ID="${SYS[id]}";     OS_ID_LIKE="${SYS[id_like]}"
  OS_VER="${SYS[version]}"; OS_NAME="${SYS[pretty]}"
  [[ -n "$OS_NAME" ]] || OS_NAME="${OS_ID:-未知发行版} ${OS_VER}"
  return 0
}

detect_family() {
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
}

detect_arch() {
  local m=""
  m="$(uname -m 2>/dev/null)" || m="unknown"
  ARCH="$m"
  case "$m" in
    x86_64|amd64) REPO_ARCH="x86_64" ;;
    aarch64|arm64) REPO_ARCH="sbsa" ;;
    *) REPO_ARCH="" ;;
  esac
  return 0
}

detect_jetson() {
  IS_JETSON="no"
  if [[ -e /etc/nv_tegra_release ]] || [[ -d /usr/lib/aarch64-linux-gnu/tegra ]]; then
    IS_JETSON="yes"
  fi
  return 0
}

# 生成可选的仓库标识（按优先级）
repo_tag_candidates() {
  local c=() v=""
  if [[ -n "$REPO_FORCE" ]]; then
    printf '%s\n' "$REPO_FORCE"
    return 0
  fi
  v="$OS_VER"
  case "$FAMILY" in
    debian)
      if [[ "$OS_ID" == "ubuntu" ]]; then
        # 26.04.1 → 2604；24.04 → 2404
        local umaj="${v%%.*}" umin=""
        umin="${v#*.}"; umin="${umin%%.*}"
        [[ -n "$umaj" && -n "$umin" ]] && c+=("ubuntu${umaj}${umin}")
        # WSL 专用源紧跟本系统原生源：它的新版本更新滞后（例如停在 CUDA 13.3），
        # 但老版本在 WSL 上比"给别的 Ubuntu 版本构建的仓库"更稳妥，故排在跨版本回退之前。
        [[ "$WSL" == "yes" ]] && c+=("wsl-ubuntu")
        c+=("ubuntu2604" "ubuntu2404" "ubuntu2204" "ubuntu2004")
      else
        local maj="${v%%.*}"
        [[ -n "$maj" ]] && c+=("debian${maj}")
        c+=("debian13" "debian12" "debian11" "ubuntu2404")
      fi
      ;;
    rhel)
      case "$OS_ID" in
        fedora)
          [[ -n "$v" ]] && c+=("fedora${v}")
          c+=("rhel9")
          ;;
        amzn)
          c+=("amazonlinux2023" "rhel9")
          ;;
        *)
          local maj="${v%%.*}"
          [[ -n "$maj" ]] && c+=("rhel${maj}")
          c+=("rhel9" "rhel8")
          ;;
      esac
      ;;
    suse)
      c+=("sles15" "opensuse15")
      ;;
  esac
  local x=""
  local seen=()
  for x in ${c[@]+"${c[@]}"}; do
    [[ -n "$x" ]] || continue
    local dup="no" s=""
    for s in ${seen[@]+"${seen[@]}"}; do
      [[ "$s" == "$x" ]] && dup="yes"
    done
    [[ "$dup" == "yes" ]] && continue
    seen+=("$x")
    printf '%s\n' "$x"
  done
  return 0
}

probe_url() {
  local u="$1" code=""
  [[ -n "$u" ]] || return 1
  [[ "$u" == *$'\n'* ]] && u="${u%%$'\n'*}"
  code="$(curl -sIL -o /dev/null -w '%{http_code}' --connect-timeout 6 --max-time 15 "$u" 2>/dev/null)" || code="000"
  if [[ ! "$code" =~ ^[23] ]]; then
    # 部分 CDN 不支持 HEAD，退化为范围 GET 探测
    code="$(curl -sL -o /dev/null -w '%{http_code}' -r 0-0 --connect-timeout 6 --max-time 15 "$u" 2>/dev/null)" || code="000"
  fi
  [[ "$code" =~ ^[23] ]]
}

# 索引文件相对路径
index_leaf() {
  case "$FAMILY" in
    debian) printf '%s' "Packages.gz" ;;
    rhel|suse) printf '%s' "repodata/repomd.xml" ;;
    *) printf '%s' "" ;;
  esac
}

# 选择可用的镜像源 + 仓库标识
resolve_repo() {
  REPO_TAG=""; REPO_BASE=""; REPO_FALLBACK="no"
  if [[ -z "$REPO_ARCH" ]]; then
    return 1
  fi
  local mirrors=()
  case "$MIRROR" in
    cn)  mirrors=("https://developer.download.nvidia.cn") ;;
    com) mirrors=("https://developer.download.nvidia.com") ;;
    *)   mirrors=("https://developer.download.nvidia.cn" "https://developer.download.nvidia.com") ;;
  esac

  local tags=()
  while IFS= read -r t; do tags+=("$t"); done < <(repo_tag_candidates)
  if [[ ${#tags[@]} -eq 0 ]]; then
    return 1
  fi

  local leaf="" m t url first="${tags[0]}"
  leaf="$(index_leaf)"
  for m in "${mirrors[@]}"; do
    for t in "${tags[@]}"; do
      url="$m/compute/cuda/repos/$t/$REPO_ARCH/$leaf"
      if probe_url "$url"; then
        REPO_BASE="$m"; REPO_TAG="$t"
        [[ "$t" == "$first" ]] || REPO_FALLBACK="yes"
        return 0
      fi
    done
  done
  return 1
}

_nvidia_smi_bin() {
  local p=""
  p="$(command -v nvidia-smi 2>/dev/null)" || p=""
  if [[ -n "$p" ]]; then printf '%s' "$p"; return 0; fi
  if [[ -x /usr/lib/wsl/lib/nvidia-smi ]]; then printf '%s' "/usr/lib/wsl/lib/nvidia-smi"; return 0; fi
  return 1
}

detect_gpu() {
  GPU_LIST=""
  GPU_PRESENT="unknown"

  local smi="" out=""
  smi="$(_nvidia_smi_bin)" || smi=""
  if [[ -n "$smi" ]]; then
    out="$("$smi" --query-gpu=name,driver_version --format=csv,noheader 2>/dev/null)" || out=""
    if [[ -n "$out" ]]; then
      GPU_LIST="$out"
      DRIVER_VER="$(printf '%s' "$out" | awk -F', ' 'NR==1{print $2}' 2>/dev/null)" || DRIVER_VER=""
      GPU_PRESENT="yes"
      return 0
    fi
  fi

  # 回退 1：内核驱动版本文件（不使用 gawk 专有的三参数 match，保证 mawk 兼容）
  if [[ -r /proc/driver/nvidia/version ]]; then
    DRIVER_VER="$(awk '{ for (i = 1; i <= NF; i++) if ($i == "Module") { print $(i + 1); exit } }' /proc/driver/nvidia/version 2>/dev/null)" || DRIVER_VER=""
    [[ -n "$DRIVER_VER" ]] && GPU_PRESENT="yes"
  fi

  # 回退 2：PCI 设备扫描
  if command -v lspci >/dev/null 2>&1; then
    GPU_LIST="$(lspci -nn 2>/dev/null | grep -i 'nvidia' || true)"
    if [[ -n "$GPU_LIST" ]]; then
      GPU_PRESENT="pci"
    elif [[ "$GPU_PRESENT" == "unknown" ]]; then
      GPU_PRESENT="no"
    fi
  fi

  # WSL 特有：/dev/dxg 由 Windows 驱动提供
  if [[ "$WSL" == "yes" && "$GPU_PRESENT" == "no" && -e /dev/dxg ]]; then
    GPU_PRESENT="pci"
    GPU_LIST="WSL 虚拟 GPU 直通设备 /dev/dxg（驱动由 Windows 提供）"
  fi
  return 0
}

branch_of_pkg() {
  local p="$1" b=""
  b="$(printf '%s' "$p" | sed -nE 's/.*-(1[0-9])-([0-9]+)$/\1.\2/p' 2>/dev/null)" || b=""
  printf '%s' "$b"
  return 0
}

add_branch() {
  local b="$1" s=""
  [[ -n "$b" ]] || return 0
  for s in ${INSTALLED_BRANCHES[@]+"${INSTALLED_BRANCHES[@]}"}; do
    [[ "$s" == "$b" ]] && return 0
  done
  INSTALLED_BRANCHES+=("$b")
  return 0
}

is_installed_branch() {
  local b="$1" s=""
  for s in ${INSTALLED_BRANCHES[@]+"${INSTALLED_BRANCHES[@]}"}; do
    [[ "$s" == "$b" ]] && return 0
  done
  return 1
}

detect_installed() {
  INSTALLED_BRANCHES=()
  INSTALLED_DIRS=()
  INSTALLED_ROWS=""
  INSTALLED_HINT=""
  CUDA_LINK=""
  CUDA_LINK_TARGET=""
  NVCC_VER=""

  local tmpf="${WORK_DIR}/pkgs_all.txt"

  # ---- 1) 包管理器
  case "$FAMILY" in
    debian)
      if command -v dpkg-query >/dev/null 2>&1; then
        dpkg-query -W -f='${db:Status-Abbrev}\t${binary:Package}\t${Version}\n' >"$tmpf" 2>/dev/null || true
        INSTALLED_ROWS="$(grep -E '^[[:space:]]*ii' "$tmpf" 2>/dev/null | grep -E '(cuda-|libcudnn|libnccl)' || true)"
      fi
      ;;
    rhel|suse)
      if command -v rpm >/dev/null 2>&1; then
        INSTALLED_ROWS="$(rpm -qa --qf '%{NAME}\t%{VERSION}-%{RELEASE}\n' 2>/dev/null | grep -E '^(cuda-|libcudnn|libnccl)' || true)"
      fi
      ;;
    arch)
      if command -v pacman >/dev/null 2>&1; then
        INSTALLED_ROWS="$(pacman -Q 2>/dev/null | grep -E '^(cuda|cudnn|nccl)' || true)"
      fi
      ;;
    alpine)
      if command -v apk >/dev/null 2>&1; then
        INSTALLED_ROWS="$(apk info -v 2>/dev/null | grep -E 'cuda' || true)"
      fi
      ;;
    *) : ;;
  esac

  # ---- 2) 解析分支号
  local line="" pkg=""
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    pkg="$(printf '%s' "$line" | awk '{print $1}')" || pkg=""
    # rpm/pacman 输出没有状态列，第一列就是包名
    case "$FAMILY" in
      debian) pkg="$(printf '%s' "$line" | awk '{print $2}')" || pkg="" ;;
      *) : ;;
    esac
    add_branch "$(branch_of_pkg "$pkg")"
  done <<<"$INSTALLED_ROWS"

  # Arch/Fedora 等单一 cuda 包，用包版本推断分支
  if [[ ${#INSTALLED_BRANCHES[@]} -eq 0 && -n "$INSTALLED_ROWS" ]]; then
    local fb=""
    fb="$(printf '%s' "$INSTALLED_ROWS" | sed -nE 's/^cuda[[:space:]]+([0-9]+\.[0-9]+).*/\1/p' | awk -F. 'NR==1{print $1"-"$2}')" || fb=""
    [[ -n "$fb" ]] && add_branch "$fb"
  fi

  # ---- 3) /usr/local/cuda-* 目录
  local d="" arr=() shopt_was=""
  shopt_was="$(shopt -p nullglob 2>/dev/null || true)"
  shopt -s nullglob
  arr=(/usr/local/cuda-[0-9]* )
  [[ -n "$shopt_was" ]] && eval "$shopt_was" || shopt -u nullglob
  for d in ${arr[@]+"${arr[@]}"}; do
    [[ -d "$d" ]] || continue
    INSTALLED_DIRS+=("$d")
    local bn="" mj=""
    bn="$(basename -- "$d")" || bn=""
    mj="${bn#cuda-}"
    if [[ "$mj" =~ ^([0-9]+)\.([0-9]+)$ ]]; then
      add_branch "${BASH_REMATCH[1]}.${BASH_REMATCH[2]}"
    fi
  done

  # ---- 4) /usr/local/cuda 软链
  if [[ -L /usr/local/cuda ]]; then
    CUDA_LINK="/usr/local/cuda"
    CUDA_LINK_TARGET="$(readlink -f /usr/local/cuda 2>/dev/null || true)"
  elif [[ -d /usr/local/cuda ]]; then
    CUDA_LINK="/usr/local/cuda"
    CUDA_LINK_TARGET="/usr/local/cuda（实体目录，非软链）"
  fi

  # ---- 5) nvcc
  local nvcc_bin=""
  nvcc_bin="$(command -v nvcc 2>/dev/null)" || nvcc_bin=""
  if [[ -z "$nvcc_bin" && -x /usr/local/cuda/bin/nvcc ]]; then
    nvcc_bin="/usr/local/cuda/bin/nvcc"
  fi
  if [[ -z "$nvcc_bin" && -x /usr/local/cuda-${INSTALLED_BRANCHES[0]:-x}/bin/nvcc ]]; then
    nvcc_bin="/usr/local/cuda-${INSTALLED_BRANCHES[0]}/bin/nvcc"
  fi
  if [[ -n "$nvcc_bin" ]]; then
    local vout=""
    vout="$("$nvcc_bin" --version 2>/dev/null)" || vout=""
    NVCC_VER="$(printf '%s\n' "$vout" | sed -nE 's/.*release ([0-9]+\.[0-9]+).*/\1/p' 2>/dev/null | awk 'NR==1{print}' 2>/dev/null)" || NVCC_VER=""
  fi

  return 0
}

detect_repo_state() {
  REPO_STATE=""
  case "$FAMILY" in
    debian)
      local f="" found=""
      for f in /etc/apt/sources.list.d/cuda*.list /etc/apt/sources.list.d/cuda*.sources; do
        [[ -f "$f" ]] && found="$found $f"
      done
      [[ -n "$found" ]] && REPO_STATE="APT 源:${found}"
      if [[ -f /usr/share/keyrings/cuda-archive-keyring.gpg ]]; then
        REPO_STATE="${REPO_STATE} 已装 cuda-keyring"
      fi
      ;;
    rhel|suse)
      local f2="" found2=""
      for f2 in /etc/yum.repos.d/cuda*.repo /etc/zypp/repos.d/cuda*.repo; do
        [[ -f "$f2" ]] && found2="$found2 $f2"
      done
      [[ -n "$found2" ]] && REPO_STATE="仓库文件:${found2}"
      ;;
    *) : ;;
  esac
  [[ -n "$REPO_STATE" ]] || REPO_STATE="未配置 NVIDIA 官方源"
  return 0
}

detect_all() {
  detect_wsl
  detect_os
  detect_family
  detect_arch
  detect_jetson
  detect_gpu
  detect_installed
  detect_repo_state
  return 0
}

# =============================================================================
#  四、检测报告输出
# =============================================================================

print_environment() {
  step "运行环境"
  local envkind="原生 Linux"
  [[ "$WSL" == "yes" ]] && envkind="Windows WSL（${WSL_VER}）"
  item "系统环境" "$envkind"
  item "发行版" "${OS_NAME}"
  item "发行版 ID" "${OS_ID:-未知}${OS_VER:+ ${OS_VER}}"
  item "系统族" "$FAMILY（包管理器：${PKG_MGR:-未知}）"
  item "处理器架构" "$ARCH${REPO_ARCH:+（仓库路径：$REPO_ARCH）}"
  [[ "$IS_JETSON" == "yes" ]] && item "特殊平台" "检测到 Jetson/Tegra，请改用 NVIDIA JetPack SDK 安装"
  return 0
}

print_gpu() {
  step "GPU 与驱动"
  case "$GPU_PRESENT" in
    yes) item "NVIDIA 驱动" "${DRIVER_VER:-未知}" ;;
    pci) item "NVIDIA 驱动" "已检测到设备但驱动未生效" ;;
    no)  item "NVIDIA 驱动" "未检测到 NVIDIA 设备" ;;
    *)   item "NVIDIA 驱动" "无法确定（缺少 nvidia-smi / lspci）" ;;
  esac
  if [[ -n "$GPU_LIST" ]]; then
    local l=""
    while IFS= read -r l; do
      [[ -n "$l" ]] && item "设备" "$l"
    done <<<"$GPU_LIST"
  fi
  if [[ "$WSL" == "yes" ]]; then
    if [[ -e /usr/lib/wsl/lib/libcuda.so.1 || -e /usr/lib/wsl/lib/libcuda.so ]]; then
      item "WSL 驱动库" "已挂载（/usr/lib/wsl/lib 由 Windows 驱动提供）"
    else
      item "WSL 驱动库" "未找到，请在 Windows 侧安装 NVIDIA 驱动"
    fi
    hint "WSL 下的驱动由 Windows 宿主提供，Linux 侧不可也不需要安装驱动。"
  fi
}

print_installed() {
  step "已安装的 CUDA Toolkit"
  if [[ ${#INSTALLED_BRANCHES[@]} -eq 0 && ${#INSTALLED_DIRS[@]} -eq 0 ]]; then
    item "已安装版本" "无"
  else
    local b="" n=0
    for b in ${INSTALLED_BRANCHES[@]+"${INSTALLED_BRANCHES[@]}"}; do
      n=$(( n + 1 ))
      item "版本 ${n}" "CUDA ${b}（软件包 cuda-toolkit-${b/./-}）"
    done
    if [[ ${#INSTALLED_BRANCHES[@]} -eq 0 ]]; then
      local d=""
      for d in ${INSTALLED_DIRS[@]+"${INSTALLED_DIRS[@]}"}; do
        item "目录" "$d"
      done
    fi
  fi
  if [[ ${#INSTALLED_DIRS[@]} -gt 0 ]]; then
    local d2="" dl=""
    for d2 in ${INSTALLED_DIRS[@]+"${INSTALLED_DIRS[@]}"}; do
      dl="${dl}${dl:+, }${d2}"
    done
    item "安装目录" "$dl"
  fi
  if [[ -n "$CUDA_LINK_TARGET" ]]; then
    item "默认软链" "/usr/local/cuda → $CUDA_LINK_TARGET"
  else
    item "默认软链" "/usr/local/cuda 不存在"
  fi
  if [[ -n "$NVCC_VER" ]]; then
    item "nvcc 版本" "$NVCC_VER"
  else
    item "nvcc 版本" "当前 PATH 中不可用"
  fi
  detect_repo_state
  item "软件源状态" "$REPO_STATE"
}

print_driver_compat() {
  local b="" maj="" need="" have=""
  have="${DRIVER_VER%%.*}"
  [[ -n "$have" ]] || return 0
  [[ ${#INSTALLED_BRANCHES[@]} -gt 0 ]] || return 0
  say ""
  info "驱动兼容性提示（仅供参考）"
  for b in ${INSTALLED_BRANCHES[@]+"${INSTALLED_BRANCHES[@]}"}; do
    maj="${b%%.*}"
    need="${MIN_DRIVER[$maj]:-}"
    if [[ -n "$need" ]]; then
      item "CUDA ${b}" "建议驱动 ≥ ${need}，当前为 ${DRIVER_VER}"
    fi
  done
  return 0
}

cmd_detect() {
  say ""
  say "${C_BOLD}NVIDIA CUDA Toolkit 环境检测报告${C_RESET}"
  say "脚本版本 ${SCRIPT_VERSION}    主机 $(hostname 2>/dev/null || echo '未知')    时间 $(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo '-')"
  hr
  print_environment
  print_gpu
  print_installed
  print_driver_compat
  hr
  return 0
}

# =============================================================================
#  五、版本清单获取与解析
# =============================================================================

fetch_index_apt() {
  local base="$1" out="$2" url="${1}/Packages.gz"
  url="$base/Packages.gz"
  _log_raw "索引下载: $url"
  if ! curl -fsSL --retry 2 --connect-timeout 10 --max-time 180 -o "${out}.gz" "$url" 2>/dev/null; then
    return 1
  fi
  gzip -dc "${out}.gz" >"$out" 2>/dev/null || return 1
  return 0
}

fetch_index_rpm() {
  local base="$1" out="$2" repomd="${WORK_DIR}/repomd.xml" href="" fn=""
  _log_raw "索引下载: ${base}/repodata/repomd.xml"
  if ! curl -fsSL --retry 2 --connect-timeout 10 --max-time 60 -o "$repomd" "$base/repodata/repomd.xml" 2>/dev/null; then
    return 1
  fi
  href="$(grep -oE 'href="[^"]*primary[^"]*"' "$repomd" 2>/dev/null | grep -m1 -oE 'repodata/[^"]+' || true)"
  [[ -n "$href" ]] || return 1
  fn="${href##*/}"
  _log_raw "索引下载: ${base}/${href}"
  if [[ "$fn" == *.gz ]]; then
    if ! curl -fsSL --retry 2 --connect-timeout 10 --max-time 180 -o "${out}.gz" "$base/$href" 2>/dev/null; then
      return 1
    fi
    gzip -dc "${out}.gz" >"$out" 2>/dev/null || return 1
  else
    if ! curl -fsSL --retry 2 --connect-timeout 10 --max-time 180 -o "$out" "$base/$href" 2>/dev/null; then
      return 1
    fi
  fi
  return 0
}

# 兜底用：从本地包管理器缓存取版本。
# 注意：它只反映"本机 apt/dnf 已拉到索引"的包名，源文件存在但索引从未成功拉取、
# 或残留 dpkg 状态时会严重残缺，因此仅作为联网失败后的次选来源。
load_versions_native() {
  local out="${WORK_DIR}/native_versions.txt"
  case "$FAMILY" in
    debian)
      command -v apt-cache >/dev/null 2>&1 || return 1
      apt-cache pkgnames cuda-toolkit 2>/dev/null | grep -E '^cuda-toolkit-[0-9]+-[0-9]+$' | sed 's/^cuda-toolkit-//' >"$out" 2>/dev/null || true
      ;;
    rhel|suse)
      [[ "$PKG_MGR" == "dnf" ]] || return 1
      command -v dnf >/dev/null 2>&1 || return 1
      dnf -q --disablerepo='*' --enablerepo='cuda-*' list available 'cuda-toolkit-*' 2>/dev/null \
        | awk '{print $1}' | grep -E '^cuda-toolkit-[0-9]+-[0-9]+\.' | sed -E 's/^cuda-toolkit-([0-9]+-[0-9]+)\..*/\1/' >"$out" 2>/dev/null || true
      ;;
    *) return 1 ;;
  esac
  [[ -s "$out" ]] || return 1
  sort -uV "$out" >"${out}.sorted" 2>/dev/null || return 1
  printf '%s\n' "${out}.sorted"
  return 0
}

# ------------------------------------------------------- 官方源自适应与索引合并
# 镜像根地址（由 --mirror 展开，国内镜像优先）
_mirror_list() {
  case "$MIRROR" in
    cn)  printf '%s\n' "https://developer.download.nvidia.cn" ;;
    com) printf '%s\n' "https://developer.download.nvidia.com" ;;
    *)   printf '%s\n' "https://developer.download.nvidia.cn" "https://developer.download.nvidia.com" ;;
  esac
  return 0
}

# 下载指定仓库标识的索引，成功时打印索引文件路径（失败返回 1）
fetch_index_for_tag() {
  local tag="$1" mirror="" base="" out="${WORK_DIR}/idx-${tag}.txt"
  [[ -n "$tag" && -n "$REPO_ARCH" ]] || return 1
  if [[ -s "$out" ]]; then printf '%s' "$out"; return 0; fi
  rm -f -- "$out" "${out}.gz" 2>/dev/null || true
  while IFS= read -r mirror; do
    [[ -n "$mirror" ]] || continue
    base="${mirror}/compute/cuda/repos/${tag}/${REPO_ARCH}"
    case "$FAMILY" in
      debian)    fetch_index_apt "$base" "$out" || continue ;;
      rhel|suse) fetch_index_rpm "$base" "$out" || continue ;;
      *)         return 1 ;;
    esac
    if [[ -s "$out" ]]; then
      TAG_MIRROR["$tag"]="$mirror"
      _log_raw "仓库 ${tag}：索引可用（${base}）"
      printf '%s' "$out"
      return 0
    fi
  done < <(_mirror_list)
  rm -f -- "$out" "${out}.gz" 2>/dev/null || true
  return 1
}

# 把仓库索引解析成 "分支 版本" 行，写入指定文件
parse_index_to_file() {
  local idx="$1" out="$2"
  [[ -s "$idx" ]] || return 1
  rm -f -- "$out" 2>/dev/null || true
  case "$FAMILY" in
    debian)
      awk '
        /^Package: cuda-toolkit-/ { p = $2; v = "" }
        /^Version: /             { if (p != "") { print substr(p, 14) " " $2; p = "" } }
      ' "$idx" 2>/dev/null | grep -E '^[0-9]+-[0-9]+ ' >"$out" 2>/dev/null || true
      ;;
    rhel|suse)
      awk 'BEGIN { RS = "</package>" }
        {
          if (match($0, /<name>cuda-toolkit-[0-9]+-[0-9]+<\/name>/)) {
            n = substr($0, RSTART + 6, RLENGTH - 13);
            sub(/^cuda-toolkit-/, "", n);
            if (match($0, /<version [^>]*ver="[^"]+"/)) {
              v = substr($0, RSTART, RLENGTH);
              sub(/.*ver="/, "", v);
              gsub(/"/, "", v);
              print n " " v;
            }
          }
        }' "$idx" 2>/dev/null >"$out" || true
      # 兜底：索引格式不符合预期时退化为只取分支名
      if [[ ! -s "$out" ]]; then
        grep -oE '<name>cuda-toolkit-[0-9]+-[0-9]+</name>' "$idx" 2>/dev/null \
          | sed -E 's:</?name>::g; s/^cuda-toolkit-//' | sort -uV \
          | awk '{ print $1 " —" }' >"$out" 2>/dev/null || true
      fi
      ;;
    *) return 1 ;;
  esac
  [[ -s "$out" ]]
}

# 合并某仓库的解析结果；先到先得 —— 优先级更高的仓库已有的分支不会被后备源覆盖
merge_index_file() {
  local tag="$1" file="$2" b="" v=""
  [[ -s "$file" ]] || return 0
  while IFS=' ' read -r b v; do
    [[ -n "$b" ]] || continue
    b="${b%$'\r'}"
    [[ -n "${BRANCH_VER[$b]+x}" ]] && continue
    BRANCH_VER["$b"]="$v"
    BRANCH_REPO["$b"]="$tag"
  done < <(sort -k1,1V -k2,2V "$file" 2>/dev/null | awk '{ a[$1] = $2 } END { for (k in a) print k, a[k] }')
  return 0
}

# 分支列表按版本号排序输出
_finalize_branches() {
  local b=""
  ALL_BRANCHES=()
  [[ ${#BRANCH_VER[@]} -gt 0 ]] || return 0
  while IFS= read -r b; do
    [[ -n "$b" ]] && ALL_BRANCHES+=("$b")
  done < <(printf '%s\n' "${!BRANCH_VER[@]}" | sort -V)
  return 0
}

_load_builtin_versions() {
  local note="${1:-}" b=""
  for b in "${BUILTIN_BRANCHES[@]}"; do
    [[ -n "${BRANCH_VER[$b]+x}" ]] && continue
    BRANCH_VER["$b"]="—"
    BRANCH_REPO["$b"]=""
  done
  VERSION_SOURCE="内置参考列表${note}（可能与官方源不一致）"
  return 0
}

# 读取本机已配置的 CUDA 源所指向的仓库标识（用于提示"本机源是否最优"）
local_cuda_source_tags() {
  local files=() f="" t="" line="" s="" dup="no"
  local seen=()
  # 允许通过环境变量改目录（便于测试 / chroot 场景）
  local aptdir="${CUDA_APT_DIR:-/etc/apt/sources.list.d}"
  local yumdir="${CUDA_YUM_DIR:-/etc/yum.repos.d}"
  local zypdir="${CUDA_ZYP_DIR:-/etc/zypp/repos.d}"
  case "$FAMILY" in
    debian)
      shopt -s nullglob
      files=("${aptdir}"/cuda*.list "${aptdir}"/cuda*.sources)
      shopt -u nullglob
      ;;
    rhel|suse)
      shopt -s nullglob
      files=("${yumdir}"/cuda*.repo "${zypdir}"/cuda*.repo)
      shopt -u nullglob
      ;;
    *) return 0 ;;
  esac
  for f in ${files[@]+"${files[@]}"}; do
    [[ -f "$f" ]] || continue
    while IFS= read -r line; do
      t="$(printf '%s' "$line" \
        | grep -oE '/(wsl-ubuntu|ubuntu[0-9]+|debian[0-9]+|rhel[0-9]+|sles[0-9]+|opensuse[0-9]+|fedora[0-9]+|amazonlinux[0-9]+)/' \
        | head -n 1 | tr -d '/' || true)"
      [[ -n "$t" ]] || continue
      dup="no"
      for s in ${seen[@]+"${seen[@]}"}; do
        [[ "$s" == "$t" ]] && dup="yes"
      done
      [[ "$dup" == "yes" ]] && continue
      seen+=("$t")
      printf '%s\n' "$t"
    done <"$f"
  done
  return 0
}

# 为指定分支挑选官方仓库：
# 不同版本可能只存在于不同仓库（例：WSL 的 wsl-ubuntu 停留在 CUDA 13.3，
# 而 ubuntu2604 已有 13.4），因此必须按分支逐个选源，而非全程绑定一个源。
repo_for_branch() {
  local branch="$1" tag="" base=""
  if [[ -z "${BRANCH_REPO[$branch]+x}" ]]; then
    load_versions || true
  fi
  tag="${BRANCH_REPO[$branch]:-}"
  if [[ -z "$tag" ]]; then
    # 清单里没有该分支：按系统推导顺序现场探测，具体报错交给后续索引校验
    REPO_TAG=""; REPO_BASE=""
    resolve_repo || return 1
    [[ -n "$REPO_PRIMARY_TAG" ]] || REPO_PRIMARY_TAG="$REPO_TAG"
    return 0
  fi
  base="${TAG_MIRROR[$tag]:-}"
  [[ -n "$base" ]] || base="${REPO_PRIMARY_BASE:-https://developer.download.nvidia.cn}"
  REPO_TAG="$tag"
  REPO_BASE="$base"
  if [[ -n "$REPO_PRIMARY_TAG" && "$tag" != "$REPO_PRIMARY_TAG" ]]; then
    REPO_FALLBACK="yes"
  else
    REPO_FALLBACK="no"
  fi
  return 0
}

# 获取可安装版本清单：
# 以「按当前系统推导出的官方源索引」为准（必要时合并多个源），
# 不再优先信任本机 apt/dnf 缓存 —— 后者在源文件存在但索引未成功拉取时会严重残缺，
# 表现为"只列出已安装过的那一个版本"。
load_versions() {
  # 用 -gA 重新声明：即使脚本被 source 进函数作用域，也能保证是全局关联数组
  declare -gA BRANCH_VER=()
  declare -gA BRANCH_REPO=()
  declare -gA TAG_MIRROR=()
  REPO_TAGS_OK=()
  REPO_TAGS_SKIP=()
  ALL_BRANCHES=()
  VERSION_SOURCE=""
  REPO_PRIMARY_TAG=""
  REPO_PRIMARY_BASE=""

  local tags=() tag="" idx="" parsed="" ok=0 b="" joined=""

  if [[ "$USE_INDEX" != "yes" || -z "$REPO_ARCH" ]]; then
    _load_builtin_versions "（--no-index 或架构未识别）"
    _finalize_branches
    return 0
  fi

  while IFS= read -r tag; do
    [[ -n "$tag" ]] && tags+=("$tag")
  done < <(repo_tag_candidates)

  if [[ ${#tags[@]} -eq 0 ]]; then
    _load_builtin_versions "（未识别到适用于当前系统的官方源）"
    _finalize_branches
    return 0
  fi

  for tag in ${tags[@]+"${tags[@]}"}; do
    [[ $ok -lt $REPO_LIMIT ]] || break
    idx="$(fetch_index_for_tag "$tag")" || { _log_raw "仓库 ${tag}：索引不可用，跳过"; REPO_TAGS_SKIP+=("$tag"); continue; }
    parsed="${WORK_DIR}/parsed-${tag}.txt"
    parse_index_to_file "$idx" "$parsed" || { _log_raw "仓库 ${tag}：索引解析为空，跳过"; REPO_TAGS_SKIP+=("$tag"); continue; }
    ok=$(( ok + 1 ))
    REPO_TAGS_OK+=("$tag")
    merge_index_file "$tag" "$parsed"
  done

  if [[ ${#REPO_TAGS_OK[@]} -gt 0 ]]; then
    REPO_PRIMARY_TAG="${REPO_TAGS_OK[0]}"
    REPO_PRIMARY_BASE="${TAG_MIRROR[$REPO_PRIMARY_TAG]:-}"
    REPO_TAG="$REPO_PRIMARY_TAG"
    REPO_BASE="$REPO_PRIMARY_BASE"
    INDEX_FILE="${WORK_DIR}/idx-${REPO_PRIMARY_TAG}.txt"
    for tag in ${REPO_TAGS_OK[@]+"${REPO_TAGS_OK[@]}"}; do
      joined="${joined:+${joined}+}${tag}"
    done
    VERSION_SOURCE="NVIDIA 官方源索引（${joined} / ${REPO_ARCH}）"
    _finalize_branches
    return 0
  fi

  # 兜底 1：本地包管理器缓存（可能残缺，仅在联网失败时使用）
  local native=""
  native="$(load_versions_native)" || native=""
  if [[ -n "$native" ]]; then
    while IFS= read -r b; do
      [[ -n "$b" ]] || continue
      [[ -n "${BRANCH_VER[$b]+x}" ]] && continue
      BRANCH_VER["$b"]="—"
      BRANCH_REPO["$b"]=""
    done <"$native"
    VERSION_SOURCE="本地包管理器缓存（未能联网获取官方索引，列表可能不完整）"
    _finalize_branches
    return 0
  fi

  # 兜底 2：内置参考列表
  _load_builtin_versions "（无法联网）"
  _finalize_branches
  return 0
}

# 分支号规范化：支持 12.6 / 12-6 / 12.6.3 / cuda-toolkit-12-6
normalize_version() {
  local raw="$1" b="" p=""
  raw="${raw#cuda-toolkit-}"
  raw="${raw#CUDA }"
  if [[ "$raw" =~ ^([0-9]+)[.-]([0-9]+)(\.([0-9]+))?$ ]]; then
    b="${BASH_REMATCH[1]}-${BASH_REMATCH[2]}"
    p="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}${BASH_REMATCH[3]:-}"
    printf '%s %s' "$b" "$p"
    return 0
  fi
  if [[ "$raw" =~ ^([0-9]+)$ ]]; then
    printf '%s %s' "${raw}-0" "${raw}.0"
    return 0
  fi
  return 1
}

find_exact_apt_version() {
  local idx="$1" branch="$2" patch="$3" res=""
  [[ -s "$idx" ]] || return 1
  res="$(awk -v want="cuda-toolkit-$branch" '
      /^Package: / { p = $2 }
      /^Version: / { if (p == want) print $2 }
    ' "$idx" 2>/dev/null | sort -V | tail -n 1)" || res=""
  [[ -n "$res" ]] || return 1
  if [[ -n "$patch" ]]; then
    local f=""
    f="$(awk -v want="cuda-toolkit-$branch" -v pv="$patch" '
        /^Package: / { p = $2 }
        /^Version: / { if (p == want && index($2, pv) == 1) print $2 }
      ' "$idx" 2>/dev/null | sort -V | tail -n 1)" || f=""
    [[ -n "$f" ]] || return 1
    res="$f"
  fi
  printf '%s' "$res"
  return 0
}

# =============================================================================
#  六、版本列表展示
# =============================================================================

cmd_list() {
  step "可安装的 CUDA Toolkit 版本"
  if [[ "$FAMILY" != "arch" ]]; then
    info "正在按当前系统解析官方源……"
  fi
  load_versions

  say ""
  item "版本来源" "$VERSION_SOURCE"
  if [[ -n "$REPO_PRIMARY_TAG" ]]; then
    item "系统适配源" "${REPO_PRIMARY_TAG}/${REPO_ARCH}"
  fi
  if [[ ${#REPO_TAGS_OK[@]} -gt 1 ]]; then
    local merged="" t=""
    for t in ${REPO_TAGS_OK[@]+"${REPO_TAGS_OK[@]}"}; do
      merged="${merged:+${merged}+}${t}"
    done
    item "已合并仓库" "$merged"
  fi
  local ltag="" lshow=""
  ltag="$(local_cuda_source_tags 2>/dev/null | sed -n '1p' || true)"
  if [[ -n "$ltag" ]]; then
    lshow="$(local_cuda_source_tags 2>/dev/null | tr '\n' '+' || true)"
    lshow="${lshow%+}"
    item "本机已配置" "$lshow"
    if [[ -n "$REPO_PRIMARY_TAG" && "$ltag" != "$REPO_PRIMARY_TAG" ]]; then
      hint "本机源（${ltag}）不是本系统的最优源，安装时会按所选版本自动切换到合适的官方源。"
    fi
  fi
  if [[ "$REPO_FALLBACK" == "yes" && -n "$REPO_TAG" ]]; then
    item "兼容模式" "已回退到最接近的源 ${REPO_TAG}（安装前请确认可用性）"
  fi
  if [[ ${#REPO_TAGS_SKIP[@]} -gt 0 ]]; then
    warn "以下候选仓库索引获取失败，已跳过：$(printf '%s ' ${REPO_TAGS_SKIP[@]+"${REPO_TAGS_SKIP[@]}"})"
    hint "可能是网络抖动或镜像未同步，结果可能少列部分版本；可重试或加 --mirror com。"
  fi

  say ""
  printf '%s\n' "$(pad "序号" 6)$(pad "CUDA 版本" 12)$(pad "包名" 24)$(pad "可用版本" 14)$(pad "来源" 16)$(pad "状态" 10)"
  hr
  local i=0 b="" bd="" st="" src="" mark=""
  for b in ${ALL_BRANCHES[@]+"${ALL_BRANCHES[@]}"}; do
    i=$(( i + 1 ))
    bd="${b/-/.}"
    if is_installed_branch "$bd"; then st="已安装"; else st="未安装"; fi
    src="${BRANCH_REPO[$b]:-—}"
    mark=""
    if [[ -n "$REPO_PRIMARY_TAG" && -n "${BRANCH_REPO[$b]:-}" && "${BRANCH_REPO[$b]}" != "$REPO_PRIMARY_TAG" ]]; then
      mark="*"
    fi
    printf '%s\n' "$(pad "$i" 6)$(pad "$bd" 12)$(pad "cuda-toolkit-${b}" 24)$(pad "${BRANCH_VER[$b]:-—}" 14)$(pad "${src}${mark}" 16)$(pad "$st" 10)"
  done
  hr
  if [[ "$VERSION_SOURCE" == NVIDIA* ]]; then
    say ""
    hint "* 表示该版本来自备用源（非本系统原生仓库），安装时会自动使用并提示兼容性。"
  fi

  say ""
  local last="" hbranch="" hd="" hfull=""
  if [[ ${#ALL_BRANCHES[@]} -gt 0 ]]; then
    last="${ALL_BRANCHES[${#ALL_BRANCHES[@]}-1]}"
  else
    last="${BUILTIN_BRANCHES[${#BUILTIN_BRANCHES[@]}-1]}"
  fi
  hd="${last/-/.}"
  hfull="${BRANCH_VER[$last]:-—}"
  hfull="${hfull%%-*}"
  [[ "$hfull" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || hfull="${hd}.0"
  hint "安装示例： sudo bash ${SCRIPT_NAME} install ${hd}"
  hint "精确安装： sudo bash ${SCRIPT_NAME} install ${hfull}   （指定补丁版本）"
  hint "卸载示例： sudo bash ${SCRIPT_NAME} uninstall all"
  [[ "$FAMILY" == "arch" ]] && hint "Arch 系发行版官方无版本化仓库，可用 runfile 方式安装指定版本（--method runfile）。"
  return 0
}

# =============================================================================
#  七、安装
# =============================================================================

install_env_apt() {
  local need=() c=""
  for c in curl gpg; do
    command -v "$c" >/dev/null 2>&1 || need+=("$c")
  done
  [[ -r /etc/ssl/certs/ca-certificates.crt ]] || need+=("ca-certificates")
  if [[ ${#need[@]} -gt 0 ]]; then
    info "缺少基础依赖，正在安装：${need[*]}"
    run "刷新软件源索引" $SUDO apt-get update -qq
    run "安装基础依赖" $SUDO apt-get install -y "${need[@]}"
  fi
  return 0
}

setup_repo_apt() {
  local tag="$1"
  local base="${REPO_BASE}/compute/cuda/repos/${tag}/${REPO_ARCH}"
  local deb="${WORK_DIR}/cuda-keyring_1.1-1_all.deb"

  if [[ "$DRY_RUN" == "yes" ]]; then
    CUDA_LIST_FILE="/etc/apt/sources.list.d/cuda-${tag}-${REPO_ARCH}.list"
    info "[演练] 下载并安装 CUDA 仓库密钥（cuda-keyring）"
    hint "来源: ${base}/cuda-keyring_1.1-1_all.deb"
    hint "将启用软件源文件：${CUDA_LIST_FILE}"
    return 0
  fi

  if curl -fsSL --retry 2 --connect-timeout 10 --max-time 120 -o "$deb" "${base}/cuda-keyring_1.1-1_all.deb" 2>/dev/null; then
    run "安装 CUDA 仓库密钥（cuda-keyring）" $SUDO dpkg -i "$deb"
    CUDA_LIST_FILE="$(locate_cuda_list "$tag")"
    [[ -n "$CUDA_LIST_FILE" ]] && info "已启用软件源文件：${CUDA_LIST_FILE}"
    return 0
  fi

  warn "cuda-keyring 包下载失败，改用公钥直装方式配置软件源。"
  local keyring="/usr/share/keyrings/cuda-archive-keyring.gpg"
  local tmpkey="${WORK_DIR}/cuda.pub"
  if ! curl -fsSL --retry 2 --connect-timeout 10 --max-time 60 -o "$tmpkey" "${base}/3bf863cc.pub" 2>/dev/null; then
    err "无法下载仓库公钥，请检查网络或使用 --mirror 切换下载源。"
    return 1
  fi
  _backup_file "$keyring"
  gpg --dearmor <"$tmpkey" >"$keyring"
  CUDA_LIST_FILE="/etc/apt/sources.list.d/cuda-${tag}-${REPO_ARCH}.list"
  _write_file "$CUDA_LIST_FILE" "deb [signed-by=${keyring}] ${base}/ /"
  return 0
}

# 列出系统上所有 CUDA 软件源文件
_cuda_list_files() {
  local f=""
  shopt -s nullglob
  for f in /etc/apt/sources.list.d/cuda*.list /etc/apt/sources.list.d/cuda*.sources; do
    [[ -f "$f" ]] && printf '%s\n' "$f"
  done
  shopt -u nullglob
  return 0
}

# 定位目标发行版对应的源文件（cuda-keyring 按 <发行版>-<架构> 命名）
locate_cuda_list() {
  local tag="$1" cand=""
  for cand in \
    "/etc/apt/sources.list.d/cuda-${tag}-${REPO_ARCH}.list" \
    "/etc/apt/sources.list.d/cuda-${tag}.list" \
    "/etc/apt/sources.list.d/cuda-${tag}-${REPO_ARCH}.sources" \
    "/etc/apt/sources.list.d/cuda-${tag}.sources" ; do
    if [[ -f "$cand" ]]; then printf '%s' "$cand"; return 0; fi
  done
  # 回退：名字里含 tag 的第一个文件
  local f=""
  while IFS= read -r f; do
    case "$f" in
      *"${tag}"*) printf '%s' "$f"; return 0 ;;
    esac
  done < <(_cuda_list_files)
  return 1
}

# 同机并存多个不同发行版的 CUDA 源会让 apt 解析到错误版本的软件包，
# 这里把非目标源禁用（改名而非删除，可随时恢复）
_prune_cuda_sources() {
  local keep="$1" f="" stale=() n=0
  local all=()
  while IFS= read -r f; do
    [[ -n "$f" ]] && all+=("$f")
  done < <(_cuda_list_files)
  [[ ${#all[@]} -eq 0 ]] && return 0

  # keep 为空（repair 等场景）：只保留一份，优先本系统应使用的仓库，否则保留第一份。
  # 关键：绝不能因为 keep 为空就把「唯一」的源也当成多余项禁用掉。
  if [[ -z "$keep" ]]; then
    if [[ ${#all[@]} -eq 1 ]]; then
      return 0
    fi
    if [[ -n "${REPO_TAG:-}" ]]; then
      for f in "${all[@]}"; do
        if [[ "$f" == *"-${REPO_TAG}-"* ]]; then keep="$f"; break; fi
      done
    fi
    [[ -z "$keep" ]] && keep="${all[0]}"
  fi

  for f in "${all[@]}"; do
    [[ "$f" == "$keep" ]] && continue
    case "$f" in
      */cuda-*) stale+=("$f") ;;
    esac
  done
  [[ ${#stale[@]} -eq 0 ]] && return 0

  n=${#stale[@]}
  item "保留的 CUDA 源" "$keep"
  item "其它 CUDA 源" "${n} 个"
  for f in ${stale[@]+"${stale[@]}"}; do
    hint "  ${f}"
  done
  warn "多个发行版版本的 CUDA 源同时启用时，apt 可能解析到不匹配的包版本（易造成 dpkg 安装失败）。"
  if [[ "$DRY_RUN" == "yes" ]]; then
    hint "[演练] 将禁用上述源文件"
    return 0
  fi
  if confirm "是否禁用这些源文件（改名为 .disabled-by-cuda-manager，可恢复）？"; then
    for f in ${stale[@]+"${stale[@]}"}; do
      run_ok "禁用 $f" $SUDO mv -f -- "$f" "${f}.disabled-by-cuda-manager"
    done
    ok "已禁用 ${n} 个多余源文件。"
  else
    warn "已保留，但安装可能因来源冲突而失败。"
  fi
  return 0
}

update_apt_index() {
  local listfile="$CUDA_LIST_FILE" f=""
  if [[ -z "$listfile" || ! -f "$listfile" ]]; then
    for f in "/etc/apt/sources.list.d/cuda-${REPO_TAG}-${REPO_ARCH}.list" "/etc/apt/sources.list.d/cuda-${REPO_TAG}.list" "/etc/apt/sources.list.d/cuda-${REPO_TAG}-${REPO_ARCH}.sources" "/etc/apt/sources.list.d/cuda-${REPO_TAG}.sources"; do
      if [[ -f "$f" ]]; then listfile="$f"; break; fi
    done
  fi
  if [[ -z "$listfile" ]]; then
    listfile="$(locate_cuda_list "$REPO_TAG" || true)"
  fi
  if [[ -n "$listfile" && -f "$listfile" ]]; then
    CUDA_LIST_FILE="$listfile"
    run "刷新 CUDA 软件源索引（仅使用 ${listfile##*/}）" $SUDO apt-get update \
      -o Dir::Etc::sourcelist="$listfile" \
      -o Dir::Etc::sourceparts="-" \
      -o APT::Get::List-Cleanup="0"
  else
    warn "未找到 CUDA 源文件，改为全量刷新源索引。"
    run "刷新软件源索引" $SUDO apt-get update
  fi
  return 0
}

# ---------------------------------------------------------------- 安装前预检
# 目标目录是否由 dpkg 之外的方式（多为 runfile）遗留
_dir_is_foreign() {
  local dir="$1" pkg="$2" st=""
  st="$(dpkg-query -W -f='${db:Status-Abbrev}' "$pkg" 2>/dev/null || true)"
  [[ "$st" == ii* ]] && return 1
  [[ -d "$dir" ]]
}

preflight_install_apt() {
  local branch="$1" pkg_branch="$2"
  local problems=0 dir="/usr/local/cuda-${branch}"
  local avail_kb="" avail_gb=0 audit="" f=""

  step "安装前预检"
  hr

  # 1) 磁盘空间
  avail_kb="$(df -Pk /usr/local 2>/dev/null | awk 'NR==2{print $4}')" || avail_kb=""
  if [[ -n "$avail_kb" ]]; then
    avail_gb=$(( avail_kb / 1024 / 1024 ))
    if [[ $avail_gb -lt 6 ]]; then
      item "磁盘空间 /usr/local" "${avail_gb}GB（严重不足）"
      err "可用空间不足 6GB，无法安装 CUDA Toolkit（完整安装约需 6~10GB）。"
      hint "清理下载缓存： sudo apt-get clean && sudo rm -rf /var/cache/apt/archives/*.deb"
      hint "查看占用： df -h / /var /usr/local"
      hint "WSL 扩容：PowerShell 执行 wsl --shutdown 后扩展 ext4.vhdx。"
      return 1
    elif [[ $avail_gb -lt 12 ]]; then
      item "磁盘空间 /usr/local" "${avail_gb}GB（偏紧）"
      warn "空间偏紧：完整安装约需 6~10GB，下载缓存还需 3~4GB。"
      problems=$(( problems + 1 ))
    else
      item "磁盘空间 /usr/local" "${avail_gb}GB（充足）"
    fi
  else
    item "磁盘空间" "无法检测"
  fi

  # 2) dpkg 是否处于中断状态
  _dpkg_audit
  audit="$_AUDIT_OUT"
  if [[ $_AUDIT_RC -ne 0 ]]; then
    case "$_AUDIT_ERR" in
      locked)
        item "dpkg 状态" "无法检查（数据库被占用）"
        err "检测到另一个 apt / dpkg 进程正在运行，此时安装必然互相干扰并失败。"
        hint "请等它结束后重试： ps aux | grep -E '[a]pt|[d]pkg'"
        return 1
        ;;
      missing)
        # 环境里根本没有 dpkg（例如在非 Debian 环境里被调用）：无法判断，不计为风险
        item "dpkg 状态" "无法检查（环境里没有 dpkg 命令）"
        ;;
      *)
        item "dpkg 状态" "检查失败（退出码 ${_AUDIT_RC}）"
        say "$audit"
        problems=$(( problems + 1 ))
        ;;
    esac
  elif [[ -n "$audit" ]]; then
    item "dpkg 状态" "存在未完成配置的软件包"
    say "$audit"
    warn "dpkg 处于中断状态时，任何安装都会直接失败。"
    if [[ "$DRY_RUN" == "yes" ]]; then
      hint "[演练] 将执行： sudo dpkg --configure -a"
    elif ask_feature "是否现在自动补完配置（dpkg --configure -a）？"; then
      run_diag "补完 dpkg 未完成的配置" $SUDO dpkg --configure -a
    fi
    problems=$(( problems + 1 ))
  else
    item "dpkg 状态" "正常"
  fi
  hr

  if [[ "$DRY_RUN" == "yes" ]]; then
    info "[演练] 跳过预检中的交互式修复动作。"
    return 0
  fi

  # 3) 非包管理器管理的残留目录（runfile 遗留）会与官方源安装冲突
  if _dir_is_foreign "$dir" "cuda-toolkit-${pkg_branch}"; then
    item "残留目录" "${dir}（非软件包管理）"
    warn "该目录已存在但并非由软件包安装（多为以往 runfile 安装的残留）。"
    warn "继续安装会出现 dpkg 文件覆盖冲突： trying to overwrite ..."
    if confirm "是否将其改名备份后继续安装？"; then
      local bk="${BACKUP_DIR}/residue-$(basename "$dir")"
      mkdir -p -- "$BACKUP_DIR" 2>/dev/null || true
      run "备份残留目录到 ${bk}" $SUDO mv -- "$dir" "$bk"
    else
      problems=$(( problems + 1 ))
    fi
  fi

  # 4) /usr/local/cuda 悬空软链会让安装包的 postinst 报错
  if [[ -L /usr/local/cuda && ! -e /usr/local/cuda ]]; then
    item "/usr/local/cuda" "悬空软链（指向已删除的目录）"
    warn "安装时创建的 /usr/local/cuda 软链会与此路径冲突，导致 postinst 失败。"
    if confirm "是否移除该悬空软链？"; then
      run "移除悬空软链 /usr/local/cuda" $SUDO rm -f -- /usr/local/cuda
    else
      problems=$(( problems + 1 ))
    fi
  fi

  # 5) 多个发行版版本共存的 CUDA 源
  _prune_cuda_sources "$CUDA_LIST_FILE"

  # 6) 残缺状态的 CUDA 包 —— 硬拦截：这类包会让本次安装必然以同样错误失败
  local rows="" st="" pk="" ver="" rcl=""
  rows="$(cuda_broken_rows)"
  if [[ -n "$rows" ]]; then
    item "残缺状态的 CUDA/NVIDIA 包" "见下"
    while IFS=' ' read -r st pk ver; do
      [[ -n "$pk" ]] || continue
      case "$st" in
        iF|iU) hint "  ${st}  ${pk} ${ver}   ← 半配置/半安装，dpkg 已被卡住" ;;
        ic)    hint "  ${st}  ${pk} ${ver}   ← 只剩配置文件，dpkg 仍想配置它" ;;
        *)     hint "  ${st}  ${pk} ${ver}" ;;
      esac
    done <<<"$rows"
    err "系统里存在残缺的 CUDA/NVIDIA 包，此时安装必然失败（dpkg 会在配置阶段反复报同一个错）。"
    hint "常见成因：cuda-toolkit-X-Y-config-common 的 postinst 要执行"
    hint "  update-alternatives --install /usr/local/cuda cuda /usr/local/cuda-X.Y <优先级>"
    hint "而 /usr/local/cuda-X.Y 已被删除 → update-alternatives 退出 2 → 包永久停在 iF。"
    hint "先修复（自动补目录解锁并清理残留）："
    hint "  sudo bash ${SCRIPT_NAME} repair"
    hint "修好后确认： dpkg --audit    （无输出即为正常）"
    return 1
  fi
  rcl="$(dpkg_state_rows | awk '$1 == "rc" && $2 ~ /^(cuda-|libcudnn|libnccl)/ {print $2}' | head -n 8 || true)"
  if [[ -n "$rcl" ]]; then
    info "以下包已卸载、仅剩配置文件（rc 状态，不影响安装）："
    while IFS= read -r pk; do [[ -n "$pk" ]] && hint "  $pk"; done <<<"$rcl"
  fi
  hr

  if [[ $problems -gt 0 ]]; then
    warn "预检发现 ${problems} 处风险，建议先执行 repair 再安装。"
    confirm "仍要继续安装？" || { info "已取消。"; return 1; }
  else
    ok "预检通过。"
  fi
  return 0
}

install_apt() {
  local branch="$1" patch="$2" spec="cuda-toolkit-${1}" idx="" ver="" base=""
  # 复用「按分支选源」阶段已下载的索引，避免重复下载
  idx="${WORK_DIR}/idx-${REPO_TAG}.txt"
  if [[ -s "$idx" ]] && ! grep -qa '^Package: cuda-toolkit-' "$idx" 2>/dev/null; then
    _log_raw "缓存索引格式不符（非 debian 索引），忽略：$idx"
    idx=""
  fi
  if [[ ! -s "$idx" && -n "$REPO_TAG" && "$USE_INDEX" == "yes" ]]; then
    base="${REPO_BASE}/compute/cuda/repos/${REPO_TAG}/${REPO_ARCH}"
    if fetch_index_apt "$base" "$idx"; then :; else idx=""; fi
  fi
  if [[ -s "$idx" ]]; then
    ver="$(find_exact_apt_version "$idx" "$branch" "$patch")" || ver=""
    if [[ -n "$patch" && -z "$ver" ]]; then
      err "仓库 ${REPO_TAG} 中不存在 cuda-toolkit-${branch} 的补丁版本 ${patch}。"
      local avail=""
      avail="$(awk -v want="cuda-toolkit-$branch" '/^Package: /{p=$2} /^Version: /{if(p==want) print $2}' "$idx" | sort -V | tail -n 5 | tr '\n' ' ' || true)"
      [[ -n "$avail" ]] && hint "该分支可用版本：${avail}"
      return 1
    fi
    if [[ -z "$ver" ]]; then
      err "CUDA ${branch} 在仓库 ${REPO_TAG} 中不存在。"
      hint "请先运行： bash ${SCRIPT_NAME} list  查看可用版本。"
      return 1
    fi
    info "目标安装版本：cuda-toolkit-${branch} = ${ver}"
    if [[ -n "$patch" ]]; then
      spec="cuda-toolkit-${branch}=${ver}"
    fi
  fi

  if [[ "$DRY_RUN" != "yes" ]]; then
    local cand=""
    cand="$(apt-cache policy "cuda-toolkit-${branch}" 2>/dev/null | awk '/Candidate:/{print $2}' || true)"
    if [[ -z "$cand" || "$cand" == "(none)" ]]; then
      err "软件源中仍找不到 cuda-toolkit-${branch}，可能是源索引未刷新或版本不被当前系统支持。"
      return 1
    fi
    info "apt 候选版本：${cand}"
  fi

  # --no-install-recommends：CUDA Toolkit 的依赖链里不含任何驱动包（已核对官方索引），
  # 这里再加一道保险，确保不会顺带拉入 nvidia-* / cuda-drivers 之类。
  run "安装 CUDA Toolkit ${branch}（仅工具包，不含驱动）" \
    $SUDO apt-get install -y --no-install-recommends "$spec"

  if [[ "$DRY_RUN" != "yes" ]]; then
    if ! dpkg-query -W -f='${db:Status-Abbrev}' "cuda-toolkit-${branch}" 2>/dev/null | grep -q '^ii'; then
      err "安装后校验失败：cuda-toolkit-${branch} 未处于已安装状态。"
      return 1
    fi
  fi
  return 0
}

setup_repo_rpm() {
  local tag="$1"
  local base="${REPO_BASE}/compute/cuda/repos/${tag}/${REPO_ARCH}"
  local url="${base}/cuda-${tag}.repo"
  local tmpf="${WORK_DIR}/cuda-${tag}.repo"
  local dest="/etc/yum.repos.d/cuda-${tag}.repo"
  [[ "$FAMILY" == "suse" ]] && dest="/etc/zypp/repos.d/cuda-${tag}.repo"

  if [[ -f "$dest" ]]; then
    info "检测到已存在的 CUDA 仓库文件：${dest}（将复用它）"
    return 0
  fi
  if ! curl -fsSL --retry 2 --connect-timeout 10 --max-time 60 -o "$tmpf" "$url" 2>/dev/null; then
    err "无法下载仓库定义文件：${url}"
    hint "可尝试 --mirror com 或手动配置软件源。"
    return 1
  fi
  if [[ "$DRY_RUN" == "yes" ]]; then
    info "[演练] 安装仓库文件 $dest"
    return 0
  fi
  _backup_file "$dest"
  install -m 0644 "$tmpf" "$dest"
  ok "已写入仓库文件：${dest}"
  return 0
}

install_rpm() {
  local branch="$1"
  if [[ "$PKG_MGR" == "dnf" ]]; then
    run_ok "清理软件源缓存" $SUDO dnf clean expire-cache
    local cand=""
    cand="$(dnf -q --disablerepo='*' --enablerepo='cuda-*' list available "cuda-toolkit-${branch}" 2>/dev/null | awk 'NR>1 && NF>=3 {print $2; exit}' || true)"
    if [[ "$DRY_RUN" != "yes" && -z "$cand" ]]; then
      err "软件源中找不到 cuda-toolkit-${branch}。"
      hint "请先运行： bash ${SCRIPT_NAME} list  查看可用版本。"
      return 1
    fi
    run "安装 CUDA Toolkit ${branch}（不含驱动）" $SUDO dnf install -y "cuda-toolkit-${branch}"
  else
    run_ok "清理软件源缓存" $SUDO yum clean expire-cache
    run "安装 CUDA Toolkit ${branch}（不含驱动）" $SUDO yum install -y "cuda-toolkit-${branch}"
  fi
  return 0
}

install_zypper() {
  local branch="$1"
  run_ok "刷新软件源元数据" $SUDO zypper -q --non-interactive refresh
  run "安装 CUDA Toolkit ${branch}（不含驱动）" $SUDO zypper --non-interactive install "cuda-toolkit-${branch}"
  return 0
}

install_pacman() {
  local branch="$1"
  if [[ "$branch" != "latest" ]]; then
    warn "Arch 系发行版没有版本化的 CUDA 仓库，无法安装指定的历史版本。"
    hint "如需指定版本，请使用 runfile 方式： --method runfile --runfile-url <地址>"
    return 1
  fi
  run "安装 CUDA Toolkit（Arch 官方仓库）" $SUDO pacman -S --needed --noconfirm cuda cuda-tools
  return 0
}

discover_runfile_url() {
  local full="$1" page="" raw="" found=""
  page="https://developer.nvidia.com/cuda-${full//./-}-download-archive"
  _log_raw "抓取归档页: $page"
  raw="$(curl -fsSL --retry 1 --connect-timeout 10 --max-time 40 -A 'Mozilla/5.0' "$page" 2>/dev/null)" || raw=""
  [[ -n "$raw" ]] || return 1
  # 注意：归档页是超长单行 HTML，同一文件名会重复出现，必须只取第一个并压成单行
  found="$(printf '%s\n' "$raw" \
    | grep -oE 'cuda_[0-9]+\.[0-9]+\.[0-9]+_[0-9]+\.[0-9]+\.[0-9]+_linux\.run' 2>/dev/null \
    | sed -n '1p' 2>/dev/null)" || found=""
  found="${found%%$'\n'*}"
  [[ -n "$found" ]] || return 1
  printf '%s' "https://developer.download.nvidia.com/compute/cuda/${full}/local_installers/${found}"
  return 0
}

# 推断某个分支对应的完整补丁版本（如 12-6 → 12.6.3）
guess_full_version() {
  local branch="$1" v=""
  v="${BRANCH_VER[$branch]:-}"
  if [[ -n "$v" && "$v" != "—" ]]; then
    v="${v%%-*}"
    if [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      printf '%s' "$v"
      return 0
    fi
  fi
  printf '%s' "${branch/-/.}.0"
  return 0
}

install_runfile() {
  local branch="$1" patch="$2"
  local series="${branch/-/.}"
  local full="$patch"
  [[ -n "$full" ]] || full="$(guess_full_version "$branch")"

  local url="$RUNFILE_URL"
  local full_try=("$full")
  if [[ -z "$url" && "$full" != "${series}.0" ]]; then
    full_try+=("${series}.0")
  fi

  local fv="" tmpurl=""
  if [[ -z "$url" ]]; then
    for fv in "${full_try[@]}"; do
      info "正在自动解析 CUDA ${fv} 的 runfile 下载地址……"
      tmpurl="$(discover_runfile_url "$fv")" || tmpurl=""
      if [[ -n "$tmpurl" ]]; then
        url="$tmpurl"; full="$fv"; break
      fi
    done
  fi
  if [[ -z "$url" ]]; then
    err "无法自动解析 runfile 地址（可能该版本未发布归档页）。"
    hint "请到以下页面获取下载链接后重试："
    hint "https://developer.nvidia.com/cuda-toolkit-archive"
    hint "用法： --method runfile --runfile-url https://.../cuda_12.6.0_560.28.03_linux.run"
    return 1
  fi
  if ! probe_url "$url"; then
    err "该 runfile 地址不可访问：$url"
    return 1
  fi
  info "安装包地址：$url"
  local f="${WORK_DIR}/${url##*/}"
  run "下载安装包（体积较大，请耐心等待）" curl -fL --retry 2 --connect-timeout 15 --max-time 3600 -o "$f" "$url"
  if [[ "$DRY_RUN" == "yes" ]]; then
    info "[演练] 执行 runfile 静默安装"
    return 0
  fi
  chmod +x -- "$f"
  # --toolkit 只装工具包（不含驱动）；--toolkitpath 装到独立目录便于多版本共存
  run "安装 Toolkit 到 /usr/local/cuda-${series}" \
    $SUDO "$f" --silent --toolkit --toolkitpath="/usr/local/cuda-${series}" --no-man-page
  return 0
}

# 配置环境变量与默认版本
configure_environment() {
  local dir="$1" branch="$2" prio=100
  # 分支号形如 12.6 时，用版本号生成 update-alternatives 优先级
  if [[ "$2" =~ ^([0-9]+)\.([0-9]+)$ ]]; then
    prio=$(( BASH_REMATCH[1] * 100 + BASH_REMATCH[2] ))
  fi
  local ldname="cuda"
  [[ "$branch" =~ ^[0-9]+\.[0-9]+$ ]] && ldname="cuda-${branch}"

  if [[ ! -d "$dir" && "$DRY_RUN" != "yes" ]]; then
    warn "未找到目录 ${dir}，跳过环境配置。"
    return 0
  fi

  # 1) /usr/local/cuda 软链
  if [[ -e /usr/local/cuda && ! -L /usr/local/cuda ]]; then
    warn "/usr/local/cuda 是实体目录（通常由 runfile 安装产生），不自动覆盖。"
    hint "如需切换，请先手动备份并删除该目录。"
  else
    if command -v update-alternatives >/dev/null 2>&1; then
      run "注册默认版本候选（update-alternatives）" \
        $SUDO update-alternatives --install /usr/local/cuda cuda "$dir" "$prio"
      run "切换 /usr/local/cuda → ${dir}" $SUDO update-alternatives --set cuda "$dir"
    else
      if [[ "$DRY_RUN" == "yes" ]]; then
        info "[演练] 建立软链 /usr/local/cuda → ${dir}"
      else
        $SUDO ln -sfn "$dir" /usr/local/cuda
        ok "已建立软链：/usr/local/cuda → ${dir}"
      fi
    fi
  fi

  # 2) 全局环境变量
  _write_file "/etc/profile.d/cuda.sh" "# 由 ${SCRIPT_NAME} 生成：CUDA 环境变量
if [ -d /usr/local/cuda/bin ]; then
  case \":\$PATH:\" in
    *\":/usr/local/cuda/bin:\"*) ;;
    *) PATH=\"/usr/local/cuda/bin:\$PATH\" ;;
  esac
  export PATH
  export CUDA_HOME=/usr/local/cuda
  export CUDA_PATH=/usr/local/cuda
fi
if [ -d /usr/local/cuda/lib64 ]; then
  case \":\${LD_LIBRARY_PATH:-}:\" in
    *\":/usr/local/cuda/lib64:\"*) ;;
    *) LD_LIBRARY_PATH=\"/usr/local/cuda/lib64\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}\" ;;
  esac
  export LD_LIBRARY_PATH
fi"

  # 3) 动态库路径
  if [[ ! -f "/etc/ld.so.conf.d/${ldname}.conf" ]]; then
    _write_file "/etc/ld.so.conf.d/${ldname}.conf" "${dir}/lib64"
    run_ok "刷新动态库缓存" $SUDO ldconfig
  fi
  return 0
}

verify_install() {
  local branch="$1"
  local dir="/usr/local/cuda-${branch}"
  local nvcc="" out=""
  if [[ "$DRY_RUN" == "yes" ]]; then
    info "[演练] 跳过安装校验"
    return 0
  fi
  if [[ -x "${dir}/bin/nvcc" ]]; then
    nvcc="${dir}/bin/nvcc"
  elif [[ -x /usr/local/cuda/bin/nvcc ]]; then
    nvcc="/usr/local/cuda/bin/nvcc"
  elif [[ -x /opt/cuda/bin/nvcc ]]; then
    nvcc="/opt/cuda/bin/nvcc"
  fi
  if [[ -z "$nvcc" ]]; then
    warn "未找到 nvcc，请手动检查安装结果（目录：${dir}）。"
    return 0
  fi
  local vout=""
  vout="$("$nvcc" --version 2>/dev/null)" || vout=""
  out="$(printf '%s\n' "$vout" | sed -nE 's/.*release ([0-9]+\.[0-9]+).*/\1/p' 2>/dev/null | awk 'NR==1{print}' 2>/dev/null)" || out=""
  ok "安装校验通过：nvcc release ${out:-未知}（${nvcc}）"
  say ""

  # nvcc 在 /usr/local/cuda/bin 下，而该目录【不在】系统默认 PATH 里
  # （对比：nsys 由包自己注册到 /usr/local/bin，所以它一直能被 which 找到）。
  # 这里主动验证「新开的登录 shell」是否真能解析到 nvcc，避免用户装完一脸茫然。
  local cur_sh="bash" probe="" probe_sh="" probe_bin="" probe_ran="no"
  case "${ZSH_VERSION:-}" in "") ;; *) cur_sh="zsh" ;; esac
  if command -v env >/dev/null 2>&1; then
    for probe_sh in "$cur_sh" bash zsh; do
      probe_bin="$(command -v "$probe_sh" 2>/dev/null || true)"
      [[ -n "$probe_bin" ]] || continue
      probe_ran="yes"
      # 用一个干净环境起「登录 shell」，看它能否解析到 nvcc（最权威的生效判定）
      probe="$(env -i HOME="${HOME:-/root}" "$probe_bin" -lc 'command -v nvcc' 2>/dev/null | tail -n 1 || true)"
      [[ -n "$probe" ]] && break
    done
  fi
  if [[ "$probe_ran" == "no" ]]; then
    hint "当前终端若仍找不到 nvcc，请执行： source /etc/profile.d/cuda.sh"
  elif [[ -n "$probe" ]]; then
    info "新开的登录 shell 已能解析到 nvcc（${probe}）。"
    hint "但【当前这个终端】还没加载新配置，所以 which nvcc 会失败。任选一条即可生效："
    hint "  source /etc/profile.d/cuda.sh     # 立刻生效，bash / zsh 通用"
    hint "  exec \$SHELL -l                     # 或者直接重开一个终端窗口"
  else
    warn "连新开的登录 shell 都找不到 nvcc——/etc/profile.d 可能没有被你的 shell 读取。"
    hint "nvcc 的绝对路径是：${nvcc}（现在就能用绝对路径跑）"
    hint "请把下面两行加到 ~/.bashrc 或 ~/.zshrc 末尾（按你实际用的 shell 二选一）："
    hint "  export PATH=/usr/local/cuda/bin:\$PATH"
    hint "  export LD_LIBRARY_PATH=/usr/local/cuda/lib64:\${LD_LIBRARY_PATH:-}"
  fi
  return 0
}

cmd_install() {
  local raw="$1"
  local norm="" pkg_branch="" branch="" patch=""
  local target="" arch_mode="no"
  norm="$(normalize_version "$raw")" || {
    err "无法识别的版本号：$raw"
    hint "正确写法示例： 12.6 / 12.6.3 / cuda-toolkit-12-6"
    return 1
  }
  # pkg_branch 为软件包后缀形式（12-6），branch 为对外展示与目录形式（12.6）
  pkg_branch="$(printf '%s' "$norm" | awk '{print $1}')"
  patch="$(printf '%s' "$norm" | awk '{print $2}')"
  if [[ "${patch//./-}" == "$pkg_branch" ]]; then patch=""; fi
  branch="${pkg_branch/-/.}"
  # Arch 系官方仓库无版本化包，repo 方式只能装最新版；runfile 方式仍按指定版本走
  if [[ "$FAMILY" == "arch" && "$METHOD" != "runfile" ]]; then
    branch="latest"
  fi

  require_root

  # 按目标版本自动适配官方源（不同分支可能只存在于不同仓库）
  if [[ "$METHOD" != "runfile" && "$FAMILY" != "arch" ]]; then
    step "解析官方软件源"
    if ! repo_for_branch "$pkg_branch"; then
      err "无法定位到可用的 NVIDIA 官方源（${OS_NAME} / ${ARCH}）。"
      hint "可尝试： --mirror com，或使用 --method runfile 方式安装。"
      return 1
    fi
    if [[ -z "${BRANCH_REPO[$pkg_branch]:-}" && ${#ALL_BRANCHES[@]} -gt 0 ]]; then
      err "官方源中不存在 CUDA ${branch}（对应软件包 cuda-toolkit-${pkg_branch}）。"
      local same=""
      same="$(printf '%s\n' ${ALL_BRANCHES[@]+"${ALL_BRANCHES[@]}"} | awk -F'-' -v m="${branch%%.*}" '$1 == m' | tr '\n' ' ' || true)"
      [[ -n "$same" ]] && hint "同一大版本下可用分支：${same//-/.}"
      hint "查看完整清单： bash ${SCRIPT_NAME} list"
      return 1
    fi
  fi

  say ""
  say "${C_BOLD}准备安装 CUDA Toolkit${C_RESET}"
  hr
  item "目标分支" "CUDA ${branch}"
  [[ -n "$patch" ]] && item "精确版本" "$patch"
  item "安装方式" "$METHOD"
  item "系统环境" "$OS_NAME / $ARCH"
  if [[ -n "$REPO_TAG" && "$METHOD" != "runfile" ]]; then
    item "软件源" "${REPO_TAG}/${REPO_ARCH}"
    if [[ "$REPO_FALLBACK" == "yes" ]]; then
      if [[ "$REPO_TAG" == "wsl-ubuntu" && "$WSL" == "yes" ]]; then
        hint "该版本取自 WSL 专用源（官方为 WSL 提供的仓库），安装方式仍然只装 Toolkit。"
      else
        hint "该版本位于备用源（非本系统原生仓库），兼容性未经验证。"
      fi
    fi
  fi
  item "驱动处理" "不安装、不升级、不修改（由你自行管理）"
  [[ "$WSL" == "yes" ]] && item "WSL 提示" "驱动来自 Windows 宿主，Linux 侧只装 Toolkit"
  hr
  confirm "确认开始安装？" || { info "已取消。"; return 0; }

  if [[ "$METHOD" == "runfile" ]]; then
    step "1/3 下载并安装 runfile"
    install_runfile "$pkg_branch" "$patch"
    step "2/3 配置环境变量"
    configure_environment "/usr/local/cuda-${branch}" "$branch"
    step "3/3 校验"
    verify_install "$branch"
    return 0
  fi

  case "$FAMILY" in
    debian|rhel|suse|arch) : ;;
    *) err "暂不支持的系统族：$FAMILY。"; hint "可改用 runfile 方式： --method runfile"; return 1 ;;
  esac

  step "1/6 安装前预检"
  if [[ "$FAMILY" == "debian" ]]; then
    if ! preflight_install_apt "$branch" "$pkg_branch"; then
      err "安装前预检未通过，已中止安装。"
      return 1
    fi
  else
    info "该发行版暂无额外预检项。"
  fi

  step "2/6 准备安装环境"
  case "$FAMILY" in
    debian) install_env_apt ;;
    rhel|suse)
      command -v curl >/dev/null 2>&1 || run "安装 curl" $SUDO "$PKG_MGR" install -y curl
      ;;
    arch) : ;;
  esac

  step "3/6 配置 NVIDIA 官方软件源"
  case "$FAMILY" in
    debian)
      setup_repo_apt "$REPO_TAG"
      # 目标源已就绪，禁用其它发行版版本的 CUDA 源，避免 apt 解析到不匹配的包
      _prune_cuda_sources "$CUDA_LIST_FILE"
      ;;
    rhel|suse) setup_repo_rpm "$REPO_TAG" ;;
    arch) info "Arch 系使用发行版自带仓库，跳过。" ;;
  esac

  step "4/6 刷新并校验版本可用性"
  case "$FAMILY" in
    debian) update_apt_index ;;
    rhel|suse) : ;;
    arch) : ;;
  esac

  step "5/6 安装 CUDA Toolkit ${branch}"
  case "$FAMILY" in
    debian) install_apt "$pkg_branch" "$patch" ;;
    rhel)   install_rpm "$pkg_branch" ;;
    suse)   install_zypper "$pkg_branch" ;;
    arch)   install_pacman "latest"; arch_mode="yes" ;;
  esac
  target="/usr/local/cuda-${branch}"
  if [[ "$arch_mode" == "yes" ]]; then
    target="/opt/cuda"
  fi

  step "6/6 配置环境并校验"
  configure_environment "$target" "$branch"
  verify_install "$branch"

  say ""
  ok "CUDA Toolkit ${branch} 安装流程结束。"
  hint "已安装版本： bash ${SCRIPT_NAME} detect"
  hint "切换默认版本： sudo bash ${SCRIPT_NAME} use 12.6"
  return 0
}

# =============================================================================
#  八、卸载
# =============================================================================

# 收集某分支在系统上安装的包名
collect_packages() {
  local branch="$1" out="${WORK_DIR}/uninstall_list.txt"
  local br="${1//./-}"          # 包名后缀使用短横线形式：12.6 → 12-6
  : >"$out"
  case "$FAMILY" in
    debian)
      local all="${WORK_DIR}/dpkg_all.txt"
      dpkg-query -W -f='${db:Status-Abbrev} ${binary:Package}\n' >"$all" 2>/dev/null || true
      awk '{print $2}' "$all" 2>/dev/null \
        | grep -E -- "^(cuda-|libcudnn|libnccl)" \
        | grep -E -- "-${br}$|-${br}-config-common$" \
        | sort -u >"$out" 2>/dev/null || true
      ;;
    rhel|suse)
      rpm -qa --qf '%{NAME}\n' 2>/dev/null \
        | grep -E -- "^(cuda-|libcudnn|libnccl)" \
        | grep -E -- "-${br}$|-${br}-config-common$" \
        | sort -u >"$out" 2>/dev/null || true
      ;;
    arch)
      pacman -Qq 2>/dev/null | grep -E '^(cuda|cuda-tools|cudnn|nccl)$' >"$out" 2>/dev/null || true
      ;;
    *) : ;;
  esac
  # 安全兜底：绝不允许驱动类包进入列表
  if grep -qE '^(nvidia-|libnvidia-|cuda-drivers)' "$out" 2>/dev/null; then
    warn "卸载列表中出现驱动类包，已自动剔除（本脚本不触碰驱动）。"
    grep -vE '^(nvidia-|libnvidia-|cuda-drivers)' "$out" >"${out}.clean" 2>/dev/null || true
    mv -f "${out}.clean" "$out" 2>/dev/null || true
  fi
  printf '%s' "$out"
  return 0
}

# 与大版本共享的包（同大版本还有其他分支时必须保留）
collect_major_shared() {
  local branch="$1" out="${WORK_DIR}/major_shared.txt"
  local major="${branch%%.*}"
  : >"$out"
  case "$FAMILY" in
    debian)
      local all="${WORK_DIR}/dpkg_all.txt"
      [[ -s "$all" ]] || dpkg-query -W -f='${db:Status-Abbrev} ${binary:Package}\n' >"$all" 2>/dev/null || true
      awk '{print $2}' "$all" 2>/dev/null \
        | grep -E -- "^(cuda-|libcudnn|libnccl)" \
        | grep -E -- "-${major}\$|-${major}-config-common\$|^cuda-(toolkit-)?config-common\$" \
        | sort -u >"$out" 2>/dev/null || true
      ;;
    rhel|suse)
      rpm -qa --qf '%{NAME}\n' 2>/dev/null \
        | grep -E -- "^(cuda-|libcudnn|libnccl)" \
        | grep -E -- "-${major}\$|-${major}-config-common\$|^cuda-(toolkit-)?config-common\$" \
        | sort -u >"$out" 2>/dev/null || true
      ;;
    *) : ;;
  esac
  printf '%s' "$out"
  return 0
}

other_branch_same_major() {
  local branch="$1" major="${1%%.*}" b=""
  for b in ${INSTALLED_BRANCHES[@]+"${INSTALLED_BRANCHES[@]}"}; do
    [[ "$b" == "$branch" ]] && continue
    [[ "${b%%.*}" == "$major" ]] && return 0
  done
  return 1
}

remove_files_for_branch() {
  local branch="$1"
  local d="/usr/local/cuda-${branch}" n=0 left="" lp=""
  local targets=()

  # 安全闸门：只要该分支还有包被安装，就绝不删目录。
  # 否则那些包的 postinst（update-alternatives --install ... /usr/local/cuda-X.Y）会因
  # 目录不存在而永久失败，包卡在 iF，之后**任何** apt 操作都会失败——本脚本 1.0.4 及
  # 之前正是漏掉了 cuda-toolkit-X-Y-config-common 才制造了这个死锁。
  left="$(branch_pkgs_left "$branch")"
  if [[ -n "$left" ]]; then
    say ""
    err "CUDA ${branch} 仍有软件包未卸载干净，已跳过目录清理："
    while IFS= read -r lp; do [[ -n "$lp" ]] && hint "  $lp"; done <<<"$left"
    hint "此刻删除 ${d} 会让这些包卡在 iF（dpkg 永久阻塞），所以拒绝执行。"
    hint "请先修复包状态： sudo bash ${SCRIPT_NAME} repair"
    hint "修复后再重新执行卸载即可。"
    return 1
  fi

  [[ -e "$d" ]] && targets+=("$d")
  [[ -f "/etc/ld.so.conf.d/cuda-${branch}.conf" ]] && targets+=("/etc/ld.so.conf.d/cuda-${branch}.conf")
  [[ -L /usr/local/cuda ]] && targets+=("/usr/local/cuda（软链）")
  if [[ ${#targets[@]} -gt 0 ]]; then
    say ""
    info "将删除以下目录 / 文件："
    local t=""
    for t in "${targets[@]}"; do
      item "·" "$t"
    done
  fi
  if [[ ! -t 0 && "$DRY_RUN" != "yes" ]]; then
    warn "非交互终端，跳过文件残留清理（包卸载已完成）。"
    return 0
  fi
  for t in "${targets[@]}"; do
    case "$t" in
      *"（软链）")
        if command -v update-alternatives >/dev/null 2>&1; then
          run_ok "移除默认版本候选" $SUDO update-alternatives --remove cuda "$d"
        fi
        if [[ -L /usr/local/cuda ]]; then
          run "删除软链 /usr/local/cuda" $SUDO rm -f -- /usr/local/cuda
        fi
        ;;
      *)
        run "删除 ${t}" $SUDO rm -rf -- "$t"
        n=$(( n + 1 ))
        ;;
    esac
  done
  [[ $n -gt 0 ]] && ok "已清理 ${n} 项残留。"
  return 0
}

do_uninstall_branch() {
  local branch="$1" listf="" pkgs=() p="" f=""

  step "准备卸载 CUDA ${branch}"
  listf="$(collect_packages "$branch")"
  while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    pkgs+=("$p")
  done <"$listf"

  # 同大版本还有其他分支 → 保留共享包
  if other_branch_same_major "$branch"; then
    local sharedf="" sp=""
    sharedf="$(collect_major_shared "$branch")"
    if [[ -s "$sharedf" ]]; then
      local keep=()
      local skip="no"
      for p in ${pkgs[@]+"${pkgs[@]}"}; do
        skip="no"
        while IFS= read -r sp; do
          [[ "$sp" == "$p" ]] && skip="yes"
        done <"$sharedf"
        [[ "$skip" == "yes" ]] || keep+=("$p")
      done
      if [[ ${#keep[@]} -gt 0 ]]; then
        pkgs=("${keep[@]}")
      else
        pkgs=()
      fi
      info "检测到同大版本（${branch%%.*}）的其他分支，已保留共享组件。"
    fi
  fi

  if [[ ${#pkgs[@]} -eq 0 ]]; then
    warn "未在包管理器中找到 CUDA ${branch} 的已安装软件包。"
  else
    say ""
    info "将卸载以下 ${#pkgs[@]} 个软件包（不会触碰任何驱动包）："
    local i=0
    for p in "${pkgs[@]}"; do
      i=$(( i + 1 ))
      printf '      %s\n' "$p"
      [[ $i -ge 60 ]] && { hint "……其余 $(( ${#pkgs[@]} - 60 )) 个已省略"; break; }
    done
  fi

  # 备份关键信息
  if [[ "$DRY_RUN" != "yes" ]]; then
    mkdir -p -- "$BACKUP_DIR" 2>/dev/null || true
    { printf '分支: %s\n时间: %s\n\n' "$branch" "$(date '+%Y-%m-%d %H:%M:%S')"; } >"$BACKUP_DIR/packages.txt" 2>/dev/null || true
    printf '%s\n' ${pkgs[@]+"${pkgs[@]}"} >>"$BACKUP_DIR/packages.txt" 2>/dev/null || true
    _backup_file /etc/profile.d/cuda.sh
    _backup_file "/etc/ld.so.conf.d/cuda-${branch}.conf"
    for f in /etc/apt/sources.list.d/cuda*.list /etc/yum.repos.d/cuda*.repo /etc/zypp/repos.d/cuda*.repo; do
      _backup_file "$f"
    done
    ok "已备份软件包清单至：${BACKUP_DIR}/packages.txt"
  fi

  ask_destructive || return 1

  if [[ ${#pkgs[@]} -gt 0 ]]; then
    local batch=() c=0
    for p in "${pkgs[@]}"; do
      batch+=("$p")
      c=$(( c + 1 ))
      if [[ $c -ge 50 ]]; then
        _purge_batch "$branch" "${batch[@]}"
        batch=(); c=0
      fi
    done
    [[ ${#batch[@]} -gt 0 ]] && _purge_batch "$branch" "${batch[@]}"
  fi

  remove_files_for_branch "$branch"
  return 0
}

_purge_batch() {
  local branch="$1"; shift
  case "$FAMILY" in
    debian)
      run "卸载软件包（${#} 个）" $SUDO apt-get purge -y "$@"
      ;;
    rhel)
      run "卸载软件包（${#} 个）" $SUDO "$PKG_MGR" remove -y "$@"
      ;;
    suse)
      run "卸载软件包（${#} 个）" $SUDO zypper --non-interactive remove "$@"
      ;;
    arch)
      run "卸载软件包（${#} 个）" $SUDO pacman -R --noconfirm "$@"
      ;;
    *) : ;;
  esac
  return 0
}

cleanup_after_uninstall() {
  local any_left="no"
  detect_installed
  [[ ${#INSTALLED_BRANCHES[@]} -gt 0 || ${#INSTALLED_DIRS[@]} -gt 0 ]] && any_left="yes"

  if [[ "$any_left" == "no" ]]; then
    info "系统中已无 CUDA Toolkit。"
    if ask_feature "是否同时移除 NVIDIA 软件源与全局环境变量配置？"; then
      case "$FAMILY" in
        debian)
          local f=""
          for f in /etc/apt/sources.list.d/cuda*.list /etc/apt/sources.list.d/cuda*.sources; do
            [[ -f "$f" ]] && run "移除源文件 ${f}" $SUDO rm -f -- "$f"
          done
          run_ok "卸载 cuda-keyring" $SUDO apt-get purge -y cuda-keyring
          run_ok "移除仓库公钥" $SUDO rm -f -- /usr/share/keyrings/cuda-archive-keyring.gpg
          run_ok "刷新源索引" $SUDO apt-get update
          ;;
        rhel|suse)
          for f in /etc/yum.repos.d/cuda*.repo /etc/zypp/repos.d/cuda*.repo; do
            [[ -f "$f" ]] && run "移除仓库文件 ${f}" $SUDO rm -f -- "$f"
          done
          ;;
        *) : ;;
      esac
      run_ok "移除全局环境变量" $SUDO rm -f -- /etc/profile.d/cuda.sh
      hint "如需清理当前终端的环境变量，请执行： unset CUDA_HOME CUDA_PATH"
      return 0
    fi
  else
    local b=""
    for b in ${INSTALLED_BRANCHES[@]+"${INSTALLED_BRANCHES[@]}"}; do
      if [[ "$CUDA_LINK_TARGET" == *"cuda-${b}"* ]]; then
        info "仍有其他版本，保持默认软链不变。"
        break
      fi
    done
  fi
  if [[ "$FAMILY" == "debian" ]]; then
    run_ok "刷新动态库缓存" $SUDO ldconfig
    if ask_feature "是否清理因卸载而不再需要的依赖包（apt-get autoremove）？"; then
      run "清理无用依赖" $SUDO apt-get autoremove --purge -y
    fi
  fi
  return 0
}

cmd_uninstall() {
  local arg="${1:-}"
  require_root
  say ""
  say "${C_BOLD}CUDA Toolkit 卸载${C_RESET}"
  hr

  if [[ ${#INSTALLED_BRANCHES[@]} -eq 0 && ${#INSTALLED_DIRS[@]} -eq 0 ]]; then
    warn "系统中未检测到已安装的 CUDA Toolkit。"
    if [[ ! -t 0 ]]; then
      return 0
    fi
    if ! ask_feature "是否仍要继续扫描并清理残留的安装目录？"; then
      return 0
    fi
  fi

  if [[ ${#INSTALLED_BRANCHES[@]} -gt 0 ]]; then
    item "已安装版本" "$(printf '%s ' ${INSTALLED_BRANCHES[@]+"${INSTALLED_BRANCHES[@]}"})"
  fi
  if [[ ${#INSTALLED_DIRS[@]} -gt 0 ]]; then
    item "安装目录" "$(printf '%s ' ${INSTALLED_DIRS[@]+"${INSTALLED_DIRS[@]}"})"
  fi
  hr

  local targets=()
  if [[ -z "$arg" || "$arg" == "all" ]]; then
    if [[ -z "$arg" ]]; then
      info "未指定版本，默认卸载全部已安装版本。"
      confirm "确认卸载全部版本？" || { info "已取消。"; return 0; }
    fi
    local b=""
    for b in ${INSTALLED_BRANCHES[@]+"${INSTALLED_BRANCHES[@]}"}; do
      targets+=("$b")
    done
    # 只有目录没有包的场景
    if [[ ${#targets[@]} -eq 0 && ${#INSTALLED_DIRS[@]} -gt 0 ]]; then
      local d=""
      for d in ${INSTALLED_DIRS[@]+"${INSTALLED_DIRS[@]}"}; do
        local bn="${d#/usr/local/cuda-}"
        [[ "$bn" =~ ^[0-9]+\.[0-9]+$ ]] && targets+=("$bn")
      done
    fi
  else
    local norm="" branch=""
    norm="$(normalize_version "$arg")" || {
      err "无法识别的版本号：$arg"
      hint "正确写法示例： 12.6 / uninstall all"
      return 1
    }
    branch="$(printf '%s' "$norm" | awk '{print $1}')"
    branch="${branch/-/.}"
    if ! is_installed_branch "$branch"; then
      warn "CUDA ${branch} 未在已安装列表中，仍将尝试清理其残留。"
    fi
    targets+=("$branch")
  fi

  if [[ ${#targets[@]} -eq 0 ]]; then
    warn "没有需要卸载的目标。"
    return 0
  fi

  local t=""
  for t in "${targets[@]}"; do
    do_uninstall_branch "$t" || warn "CUDA ${t} 的卸载未完成或已取消。"
  done

  cleanup_after_uninstall

  say ""
  ok "卸载流程结束。"
  hint "如需确认结果，请执行： bash ${SCRIPT_NAME} detect"
  return 0
}

# =============================================================================
#  九、切换默认版本
# =============================================================================

cmd_use() {
  local raw="${1:-}" norm="" branch="" dir=""
  if [[ -z "$raw" ]]; then
    err "请指定要切换到的版本，例如： use 12.6"
    hint "已安装版本： $(printf '%s ' ${INSTALLED_BRANCHES[@]+"${INSTALLED_BRANCHES[@]}"})"
    return 1
  fi
  norm="$(normalize_version "$raw")" || { err "无法识别的版本号：$raw"; return 1; }
  branch="$(printf '%s' "$norm" | awk '{print $1}')"
  branch="${branch/-/.}"
  require_root

  if [[ -d "/usr/local/cuda-${branch}" ]]; then
    dir="/usr/local/cuda-${branch}"
  elif [[ "$FAMILY" == "arch" && -d /opt/cuda ]]; then
    dir="/opt/cuda"
  fi
  if [[ -z "$dir" ]]; then
    if [[ "$DRY_RUN" == "yes" ]]; then
      dir="/usr/local/cuda-${branch}"
      info "[演练] 假定目录 ${dir} 存在"
    else
      err "未找到 CUDA ${branch} 的安装目录（/usr/local/cuda-${branch}）。"
      hint "请先确认已安装： bash ${SCRIPT_NAME} detect"
      return 1
    fi
  fi
  step "切换默认 CUDA 版本"
  item "目标目录" "$dir"
  configure_environment "$dir" "$branch"
  ok "默认版本已切换为 CUDA ${branch}"
  hint "新终端生效；当前终端请执行： source /etc/profile.d/cuda.sh"
  return 0
}

# =============================================================================
#  十、环境体检
# =============================================================================

cmd_doctor() {
  say ""
  say "${C_BOLD}CUDA 环境体检${C_RESET}"
  hr
  local problems=0

  print_environment
  print_gpu

  step "关键检查项"
  # 1) 磁盘空间
  local avail=""
  avail="$(df -Pk /usr/local 2>/dev/null | awk 'NR==2{print $4}')" || avail=""
  if [[ -n "$avail" ]]; then
    local availg=$(( avail / 1024 / 1024 ))
    if [[ $availg -lt 8 ]]; then
      item "磁盘空间" "仅剩 ${availg}GB，完整 Toolkit 通常需要 6~10GB"
      problems=$(( problems + 1 ))
    else
      item "磁盘空间" "可用 ${availg}GB（充足）"
    fi
  else
    item "磁盘空间" "无法检测"
  fi

  # 2) 编译器
  local gccv=""
  gccv="$(gcc -dumpfullversion -dumpversion 2>/dev/null || true)"
  if [[ -n "$gccv" ]]; then
    local gmaj="${gccv%%.*}"
    if [[ "$gmaj" -gt 14 ]]; then
      item "系统 gcc" "${gccv}（偏新，部分 CUDA 版本可能不兼容，必要时用 -ccbin 指定旧版）"
      problems=$(( problems + 1 ))
    else
      item "系统 gcc" "${gccv}"
    fi
  else
    item "系统 gcc" "未安装（仅影响编译，不影响安装）"
  fi

  # 3) Secure Boot / 驱动模块
  if command -v mokutil >/dev/null 2>&1; then
    local sb=""
    sb="$(mokutil --sb-state 2>/dev/null || true)"
    [[ -n "$sb" ]] && item "Secure Boot" "$sb"
  fi
  if command -v lsmod >/dev/null 2>&1; then
    if lsmod 2>/dev/null | grep -q '^nvidia'; then
      item "nvidia 内核模块" "已加载"
    else
      item "nvidia 内核模块" "未加载（驱动未生效或未安装）"
      [[ "$WSL" != "yes" ]] && problems=$(( problems + 1 ))
    fi
  fi

  # 4) 设备节点
  if [[ "$WSL" != "yes" ]]; then
    local ndev=0
    local sh=""
    sh="$(shopt -p nullglob 2>/dev/null || true)"
    shopt -s nullglob
    local devs=(/dev/nvidia*)
    [[ -n "$sh" ]] && eval "$sh" || shopt -u nullglob
    ndev=${#devs[@]}
    if [[ $ndev -gt 0 ]]; then
      item "设备节点" "/dev/nvidia* 共 ${ndev} 个"
    else
      item "设备节点" "无 /dev/nvidia*（驱动未正确加载）"
      problems=$(( problems + 1 ))
    fi
  fi

  # 5) 环境变量
  step "环境变量"
  item "PATH 中的 nvcc" "$(command -v nvcc 2>/dev/null || echo '未找到')"
  item "CUDA_HOME" "${CUDA_HOME:-未设置}"
  item "LD_LIBRARY_PATH" "${LD_LIBRARY_PATH:-未设置}"
  if [[ -f /etc/profile.d/cuda.sh ]]; then
    item "profile.d 配置" "/etc/profile.d/cuda.sh 已存在"
  else
    item "profile.d 配置" "未创建（安装后会自动生成）"
  fi

  print_installed
  print_driver_compat

  step "包管理器健康度"
  if command -v dpkg >/dev/null 2>&1; then
    local audit="" broken="" lists="" d2="" st2=""
    audit="$(dpkg --audit 2>/dev/null || true)"
    if [[ -n "$audit" ]]; then
      item "dpkg 状态" "存在未完成配置的软件包（会导致安装失败）"
      problems=$(( problems + 1 ))
    else
      item "dpkg 状态" "正常"
    fi
    broken="$(dpkg -l 2>/dev/null | awk '$1!="ii" && $2 ~ /^(cuda|libcudnn|libnccl)/ {print $2"("$1")"}' | tr '\n' ' ' || true)"
    if [[ -n "$broken" ]]; then
      item "异常 CUDA 包" "$broken"
      problems=$(( problems + 1 ))
    fi
    shopt -s nullglob
    local dirs2=(/usr/local/cuda-*)
    shopt -u nullglob
    for d2 in ${dirs2[@]+"${dirs2[@]}"}; do
      local pv="cuda-toolkit-${d2##*/cuda-}"
      pv="${pv//./-}"
      st2="$(dpkg-query -W -f='${db:Status-Abbrev}' "$pv" 2>/dev/null || true)"
      if [[ "$st2" != ii* ]]; then
        item "残留目录" "${d2}（无对应软件包，会与源安装冲突）"
        problems=$(( problems + 1 ))
      fi
    done
    if [[ -L /usr/local/cuda && ! -e /usr/local/cuda ]]; then
      item "/usr/local/cuda" "悬空软链"
      problems=$(( problems + 1 ))
    fi
    lists="$(_cuda_list_files | tr '\n' ' ' || true)"
    if [[ -n "$lists" ]]; then
      item "CUDA 软件源" "$lists"
    else
      item "CUDA 软件源" "未配置（安装时会自动创建）"
    fi
  else
    item "包管理器" "当前系统无 dpkg（非 Debian 系）"
  fi
  item "日志文件" "$LOG_FILE"

  step "体检结论"
  if [[ $problems -eq 0 ]]; then
    ok "未发现明显问题。"
  else
    warn "发现 ${problems} 处需要注意的地方，详见上方条目。"
    hint "可用以下命令尝试自动修复： sudo bash ${SCRIPT_NAME} repair"
  fi
  if [[ "$WSL" == "yes" ]]; then
    say ""
    info "WSL 常见问题速查"
    hint "1. 先确认 Windows 侧已装 NVIDIA 驱动，且 nvidia-smi.exe 可用"
    hint "2. Linux 侧不要安装驱动，只装 Toolkit"
    hint "3. 若 nvidia-smi 找不到，可执行： export PATH=/usr/lib/wsl/lib:\$PATH"
  fi
  hr
  return 0
}

# =============================================================================
#  十点五、故障修复
# =============================================================================

# =============================================================================
#  十点五、残缺包状态的识别与修复
# -----------------------------------------------------------------------------
#  iF / iU ：dpkg 尝试配置但维护者脚本失败 → **永久阻塞后续所有 apt/dpkg 操作**
#  ic      ：dpkg 期望安装，但只剩配置文件 → 配置时报 "not ready for configuration"
#  rc      ：已卸载、仅剩配置 → 无害
#
#  CUDA 特有的死锁成因：
#    cuda-toolkit-X-Y-config-common 的 postinst 会执行
#      update-alternatives --install /usr/local/cuda cuda /usr/local/cuda-X.Y <优先级>
#    而 update-alternatives 要求该路径**必须已存在**，否则退出 2；postinst 带 set -e，
#    于是配置失败、包停在 iF。此时任何 apt 操作都会重演同样的错误。
#    解锁办法：先 mkdir 补出该路径，再重新配置（已在真 dpkg 上验证）。
# =============================================================================

# dpkg --audit 的稳健包装：结果写入 _AUDIT_OUT，退出码写入 _AUDIT_RC。
# 必须区分三种失败，否则「锁被占用」会被误当成「状态正常」，
# 而「环境里没有 dpkg」又会被误当成「数据库被占用」。
_AUDIT_OUT=""
_AUDIT_RC=0
_AUDIT_ERR=""
_dpkg_audit() {
  _AUDIT_OUT=""
  _AUDIT_RC=0
  _AUDIT_ERR=""
  _AUDIT_OUT="$(dpkg --audit 2>&1)" || _AUDIT_RC=$?
  if [[ $_AUDIT_RC -ne 0 ]]; then
    case "$_AUDIT_OUT" in
      *"not found"*|*"未找到"*) _AUDIT_ERR="missing" ;;
      *lock*|*Lock*|*permission*|*Permission*|*denied*|*"无法锁定"*) _AUDIT_ERR="locked" ;;
      *) _AUDIT_ERR="other" ;;
    esac
    [[ $_AUDIT_RC -eq 127 ]] && _AUDIT_ERR="missing"
  fi
  return 0
}

# dpkg 状态表：状态缩写 + 包名 + 版本
dpkg_state_rows() {
  /usr/bin/dpkg-query -W -f='${db:Status-Abbrev} ${binary:Package} ${Version}\n' 2>/dev/null || true
}

# CUDA 相关的残缺包（ii 正常、rc 无害，均排除）
# 注意：NVIDIA 的东西不全是 cuda- 前缀——独立版 Nsight（nsight-systems-*、nsight-compute-*）
# 和 libnvidia-* 同样会阻塞 dpkg，所以一并纳入（否则 repair 会漏报，preflight 也拦不住）。
cuda_broken_rows() {
  dpkg_state_rows | awk '$1 ~ /^i[FUc]$/ && $2 ~ /^(cuda-|libcudnn|libnccl|nvidia-cuda|nsight|libnvidia)/ {print}' || true
}

# 指定分支在包管理器里仍处于「未卸载干净」状态的包（rc 不算）
branch_pkgs_left() {
  local br="${1//./-}"
  case "$FAMILY" in
    debian)
      dpkg_state_rows | awk -v br="$br" '
        $1 ~ /^i[iFUc]$/ && $2 ~ /^(cuda-|libcudnn|libnccl)/ &&
        ($2 ~ ("-" br "$") || $2 ~ ("-" br "-config-common$")) { print $1 " " $2 }'
      ;;
    rhel|suse)
      rpm -qa --qf '%{NAME} %{VERSION}\n' 2>/dev/null | awk -v br="$br" '
        $1 ~ /^(cuda-|libcudnn|libnccl)/ &&
        ($1 ~ ("-" br "$") || $1 ~ ("-" br "-config-common$")) { print "rpm " $1 }'
      ;;
    *) : ;;
  esac
  return 0
}

# 维护脚本（postinst/postrm）里引用的 /usr/local/cuda* 路径
pkg_script_targets() {
  local p="$1" f=""
  for f in "/var/lib/dpkg/info/${p}.postinst" "/var/lib/dpkg/info/${p}.postrm"; do
    [[ -r "$f" ]] || continue
    grep -aoE '/usr/local/cuda[0-9A-Za-z._-]*' "$f" 2>/dev/null || true
  done | sort -u | head -n 6
  return 0
}

# 清理指向已删除目录的 alternatives 条目（卸载后常见的失效残留）
prune_stale_alternatives() {
  local n=0 g="" a="" alts="" f=""
  shopt -s nullglob
  local files=(/var/lib/dpkg/alternatives/cuda* /var/lib/dpkg/alternatives/nvidia*)
  shopt -u nullglob
  for f in ${files[@]+"${files[@]}"}; do
    g="${f##*/}"
    alts="$(update-alternatives --query "$g" 2>/dev/null | awk '$1 == "Alternative:" {print $2}' || true)"
    for a in $alts; do
      [[ -e "$a" ]] && continue
      item "失效候选" "${g} → ${a}（目标已不存在）"
      run_ok "移除失效候选 ${g}" $SUDO update-alternatives --remove "$g" "$a"
      n=$(( n + 1 ))
    done
  done
  shopt -s nullglob
  for a in /etc/alternatives/cuda*; do
    if [[ -L "$a" && ! -e "$a" ]]; then
      run_ok "移除悬空链接 ${a}" $SUDO rm -f -- "$a"
      n=$(( n + 1 ))
    fi
  done
  shopt -u nullglob
  [[ $n -gt 0 ]] && ok "已清理 ${n} 项失效的 alternatives / 链接配置。"
  return 0
}

# 修复 CUDA 残缺包状态（解锁 iF/iU、清理 ic）；返回 0 表示已恢复正常
repair_broken_cuda_pkgs() {
  local rows="" st="" p="" v="" t="" fixedn=0
  local made=() iclist=() unlocked_pkgs=()
  rows="$(cuda_broken_rows)"
  if [[ -z "$rows" ]]; then
    ok "CUDA/NVIDIA 相关软件包状态正常（或系统上暂无相关软件包）。"
    return 0
  fi

  warn "发现处于残缺状态的 CUDA/NVIDIA 软件包："
  while IFS=' ' read -r st p v; do
    [[ -n "$p" ]] || continue
    case "$st" in
      iF|iU) hint "  ${st}  ${p} ${v}   ← 半配置/半安装，dpkg 已被卡住" ;;
      ic)    hint "  ${st}  ${p} ${v}   ← 只剩配置文件" ;;
      *)     hint "  ${st}  ${p} ${v}" ;;
    esac
  done <<<"$rows"

  # ---- 第一步：补出维护脚本需要的目录（解锁，不动任何包） ----
  say ""
  info "第一步：检查维护脚本需要的目录是否缺失……"
  while IFS=' ' read -r st p v; do
    [[ "$st" == "iF" || "$st" == "iU" ]] || continue
    while IFS= read -r t; do
      [[ -n "$t" ]] || continue
      # 只补版本目录形态的引用（/usr/local/cuda-13.1），跳过软链位置 /usr/local/cuda
      [[ "$t" =~ ^/usr/local/cuda-[0-9]+\.[0-9]+$ ]] || continue
      [[ -e "$t" ]] && continue
      err "${p} 卡住的直接原因：它要注册的目录 ${t} 已不存在。"
      if [[ "$DRY_RUN" == "yes" ]]; then
        info "[演练] 创建目录 ${t}"
      else
        run "补出缺失目录 ${t}（用于解锁 dpkg）" $SUDO mkdir -p -- "$t"
        made+=("$t")
      fi
      unlocked_pkgs+=("$p")
      fixedn=$(( fixedn + 1 ))
    done < <(pkg_script_targets "$p")
  done <<<"$rows"

  # ---- 第二步：重新配置 ----
  say ""
  info "第二步：重新执行这些包的配置……"
  while IFS=' ' read -r st p v; do
    [[ "$st" == "iF" || "$st" == "iU" ]] || continue
    run_diag "重新配置 ${p}" $SUDO dpkg --configure "$p"
    st="$(dpkg-query -W -f='${db:Status-Abbrev}' "$p" 2>/dev/null | tr -d ' ' || true)"
    if [[ "$st" == "ii" ]]; then
      ok "${p} 已恢复正常（ii）"
      fixedn=$(( fixedn + 1 ))
    else
      warn "${p} 仍为 ${st}，其维护脚本还有别的问题（见上方原文）。"
    fi
  done <<<"$rows"

  # ---- 第三步：清理那些「分支实际没装」的残留配置包 ----
  # 判据：它引用的 /usr/local/cuda-X.Y 本来是缺失的（说明该分支的文件早已不存在），
  # 这种包只是卸载后残留的配置包。此刻 alternatives 组已重建，postrm 能成功执行，
  # 所以可以干净地 purge 掉，彻底消除隐患（以后再装该分支时 apt 会自动重新拉回来）。
  if [[ ${#unlocked_pkgs[@]} -gt 0 ]]; then
    say ""
    info "以下包对应的 CUDA 分支其实并未安装（目录原本就是缺失的），它们只是残留配置包："
    for p in "${unlocked_pkgs[@]}"; do hint "  ${p}"; done
    if ask_feature "是否把它们彻底清掉（dpkg --purge）？这样 dpkg 状态最干净"; then
      for p in "${unlocked_pkgs[@]}"; do
        if [[ "$DRY_RUN" == "yes" ]]; then
          info "[演练] dpkg --purge ${p}"
        elif ! $SUDO dpkg --purge "$p" >/dev/null 2>&1; then
          run_ok "强制清理 ${p}" $SUDO dpkg --purge --force-all "$p"
        fi
        ok "${p} 已彻底清理"
        fixedn=$(( fixedn + 1 ))
      done
    fi
  fi

  # ---- 第四步：清理只剩配置文件的残留（ic） ----
  while IFS=' ' read -r st p v; do
    [[ "$st" == "ic" ]] && iclist+=("$p")
  done <<<"$rows"
  if [[ ${#iclist[@]} -gt 0 ]]; then
    say ""
    warn "以下软件包只剩配置文件，apt 会反复尝试配置它并失败："
    for p in "${iclist[@]}"; do hint "  ${p}"; done
    if ask_feature "是否清理这些残留（dpkg --purge）？"; then
      for p in "${iclist[@]}"; do
        if [[ "$DRY_RUN" == "yes" ]]; then
          info "[演练] dpkg --purge ${p}"
        elif ! $SUDO dpkg --purge "$p" >/dev/null 2>&1; then
          run_ok "强制清理 ${p}" $SUDO dpkg --purge --force-all "$p"
        fi
        ok "${p} 已清理"
        fixedn=$(( fixedn + 1 ))
      done
    fi
  fi

  # ---- 第五步：回收为解锁而补出的空目录、悬空软链与失效 alternatives ----
  if [[ ${#made[@]} -gt 0 ]]; then
    say ""
    for t in "${made[@]}"; do
      if [[ -d "$t" ]] && [[ -z "$(ls -A -- "$t" 2>/dev/null)" ]]; then
        run_ok "移除临时补出的空目录 ${t}" $SUDO rmdir -- "$t"
      elif [[ -d "$t" ]]; then
        info "目录 ${t} 已有内容，保留（看起来是真实安装）。"
      fi
    done
  fi
  if [[ -L /usr/local/cuda && ! -e /usr/local/cuda ]]; then
    run_ok "移除悬空软链 /usr/local/cuda" $SUDO rm -f -- /usr/local/cuda
    fixedn=$(( fixedn + 1 ))
  fi
  prune_stale_alternatives

  # ---- 第六步：复查 ----
  say ""
  rows="$(cuda_broken_rows)"
  if [[ -n "$rows" ]]; then
    warn "仍有残缺状态的 CUDA/NVIDIA 包："
    while IFS=' ' read -r st p v; do
      [[ -n "$p" ]] && hint "  ${st}  ${p} ${v}"
    done <<<"$rows"
    hint "把它的维护脚本原文发我即可精确定位："
    hint "  cat /var/lib/dpkg/info/<包名>.postinst"
    hint "  sudo bash -x /var/lib/dpkg/info/<包名>.postinst configure 2>&1 | tail -40"
    return 1
  fi
  ok "CUDA/NVIDIA 软件包状态已恢复正常（共处理 ${fixedn} 项）。"
  return 0
}

cmd_repair() {
  require_root
  say ""
  say "${C_BOLD}CUDA 安装故障修复${C_RESET}"
  hr
  local fixed=0 audit="" f="" p="" st="" broken="" d="" res=0

  # 1) dpkg 中断状态（此处只报告：真正的解锁在下一步——盲目 dpkg --configure -a
  #    只是在重演同一个失败，因为维护脚本引用的目录仍然是缺的）
  step "1/6 检查 dpkg 是否处于中断状态"
  _dpkg_audit
  audit="$_AUDIT_OUT"
  if [[ $_AUDIT_RC -ne 0 ]]; then
    case "$_AUDIT_ERR" in
      locked)
        err "无法检查 dpkg 状态：数据库被另一个进程占用。"
        hint "常见原因：另一个 apt / dpkg 进程正在运行（或权限不足）。"
        hint "请等它结束后再执行 repair，否则两边会互相干扰："
        hint "  ps aux | grep -E '[a]pt|[d]pkg'"
        return 1
        ;;
      missing)
        err "本环境找不到 dpkg 命令，repair 无法工作（仅适用于 Debian/Ubuntu 系）。"
        return 1
        ;;
      *)
        err "无法检查 dpkg 状态：$(printf '%s' "$audit" | head -n 2 | tr '\n' ' ')"
        hint "将跳过状态检查继续，但结果可能不完整。"
        ;;
    esac
  fi
  if [[ -n "$audit" ]]; then
    err "dpkg 存在未完成配置的软件包："
    say "$audit"
    hint "第 2 步会先补出维护脚本缺失的目录，再重新配置——顺序反了会一直失败。"
    fixed=$(( fixed + 1 ))
  else
    ok "dpkg 状态正常。"
  fi

  # 2) 残缺的 CUDA 包：iF/iU 补目录解锁后重配，ic 清理残留
  step "2/6 修复残缺状态的 CUDA 软件包"
  if ! repair_broken_cuda_pkgs; then
    res=$(( res + 1 ))
  fi
  audit="$(dpkg --audit 2>/dev/null || true)"
  if [[ -n "$audit" ]]; then
    run_diag "收尾：补完其余未完成的配置" $SUDO dpkg --configure -a
    audit="$(dpkg --audit 2>/dev/null || true)"
  fi
  if [[ -z "$audit" ]]; then
    ok "dpkg 已无未完成项。"
  else
    warn "仍有未完成项，请查看上方具体报错。"
    res=$(( res + 1 ))
  fi

  # 3) 文件残留与失效配置
  step "3/6 检查文件残留与失效配置"
  shopt -s nullglob
  local dirs=(/usr/local/cuda-*)
  shopt -u nullglob
  for d in ${dirs[@]+"${dirs[@]}"}; do
    local pkgv="cuda-toolkit-${d##*/cuda-}"
    pkgv="${pkgv//./-}"
    st="$(dpkg-query -W -f='${db:Status-Abbrev}' "$pkgv" 2>/dev/null || true)"
    if [[ "$st" == ii* ]]; then
      item "${d}" "由软件包 ${pkgv} 管理（正常）"
    else
      item "${d}" "无对应软件包（疑似 runfile / 手工安装残留）"
      warn "该目录会让官方源安装出现文件覆盖冲突。"
      if confirm "是否改名备份到 ${BACKUP_DIR} ？"; then
        mkdir -p -- "$BACKUP_DIR" 2>/dev/null || true
        run "备份 ${d}" $SUDO mv -- "$d" "${BACKUP_DIR}/residue-$(basename "$d")"
        fixed=$(( fixed + 1 ))
      fi
      res=$(( res + 1 ))
    fi
  done

  if [[ -L /usr/local/cuda && ! -e /usr/local/cuda ]]; then
    item "/usr/local/cuda" "悬空软链（指向已删除的目录）"
    if confirm "是否移除该悬空软链？"; then
      run "移除悬空软链" $SUDO rm -f -- /usr/local/cuda
      fixed=$(( fixed + 1 ))
    fi
    res=$(( res + 1 ))
  fi

  # 失效的动态库路径配置（含 000_cuda.conf / 987_cuda-13.conf / gds-*.conf 这些命名）
  shopt -s nullglob
  local cands=(/etc/ld.so.conf.d/*cuda*.conf /etc/ld.so.conf.d/gds-*.conf)
  shopt -u nullglob
  for f in ${cands[@]+"${cands[@]}"}; do
    local tgts="" live="no" t=""
    tgts="$(grep -ahoE '/usr/local/cuda[0-9A-Za-z._-]*' -- "$f" 2>/dev/null | sort -u || true)"
    [[ -n "$tgts" ]] || continue
    while IFS= read -r t; do
      [[ -e "$t" ]] && live="yes"
    done <<<"$tgts"
    [[ "$live" == "yes" ]] && continue
    if dpkg -S -- "$f" >/dev/null 2>&1; then
      item "${f##*/}" "指向已不存在的路径（由软件包管理，保留）"
    else
      item "${f##*/}" "指向已不存在的路径（无软件包管理，可安全移除）"
      if confirm "是否移除该无效配置？"; then
        run "移除 ${f}" $SUDO rm -f -- "$f"
        fixed=$(( fixed + 1 ))
      fi
    fi
    res=$(( res + 1 ))
  done

  if [[ -f /etc/profile.d/cuda.sh ]]; then
    local pdir=""
    pdir="$(grep -oE '/usr/local/(cuda|cuda-[0-9.]+)' /etc/profile.d/cuda.sh 2>/dev/null | head -n 1 || true)"
    if [[ -n "$pdir" && ! -d "$pdir" ]]; then
      item "/etc/profile.d/cuda.sh" "指向不存在的目录 ${pdir}"
      if confirm "是否移除该环境变量配置？"; then
        run "移除 /etc/profile.d/cuda.sh" $SUDO rm -f -- /etc/profile.d/cuda.sh
        fixed=$(( fixed + 1 ))
      fi
      res=$(( res + 1 ))
    fi
  fi
  # 失效的 alternatives 条目（卸载后残留的 /usr/local/cuda-13.3 之类）
  prune_stale_alternatives

  [[ $res -eq 0 ]] && ok "未发现残留目录或失效配置。"

  # 4) 软件源
  step "4/6 检查 CUDA 软件源配置"
  local lists=""
  lists="$(_cuda_list_files || true)"
  if [[ -z "$lists" ]]; then
    warn "未找到 CUDA 软件源文件（可能已被卸载流程移除），下次安装会自动重建。"
  else
    while IFS= read -r f; do
      [[ -n "$f" ]] && item "源文件" "$f"
    done <<<"$lists"
  fi
  _prune_cuda_sources "$CUDA_LIST_FILE"

  # 5) 磁盘空间与缓存
  step "5/6 检查磁盘空间与 apt 下载缓存"
  local avail_kb="" avail_gb=0 cache=""
  avail_kb="$(df -Pk /usr/local 2>/dev/null | awk 'NR==2{print $4}')" || avail_kb=""
  if [[ -n "$avail_kb" ]]; then
    avail_gb=$(( avail_kb / 1024 / 1024 ))
    item "可用空间 /usr/local" "${avail_gb}GB"
    if [[ $avail_gb -lt 6 ]]; then
      err "空间不足 6GB，安装必然失败。"
      hint "WSL 扩容：PowerShell 执行 wsl --shutdown 后扩展 ext4.vhdx。"
    fi
  fi
  cache="$(du -sh /var/cache/apt/archives 2>/dev/null | awk '{print $1}' || true)"
  [[ -n "$cache" ]] && item "apt 下载缓存" "$cache"
  if [[ -n "$cache" ]] && ask_feature "是否清理 apt 下载缓存释放空间（apt-get clean）？"; then
    run_ok "清理 apt 下载缓存" $SUDO apt-get clean
    fixed=$(( fixed + 1 ))
  fi

  # 6) dpkg 日志
  step "6/6 查看 dpkg 最近失败记录"
  if [[ -r /var/log/dpkg.log ]]; then
    local lines=""
    lines="$(grep -aE 'status (half-configured|half-installed|error|triggers-pending)| conffile ' /var/log/dpkg.log 2>/dev/null | tail -n 10 || true)"
    if [[ -n "$lines" ]]; then
      while IFS= read -r f; do
        [[ -n "$f" ]] && hint "$f"
      done <<<"$lines"
      warn "以上为 dpkg 记录的异常操作时刻。"
    else
      ok "dpkg 日志中未发现异常记录。"
    fi
  else
    info "无法读取 /var/log/dpkg.log。"
  fi

  say ""
  hr
  if [[ $fixed -gt 0 ]]; then
    ok "本次共执行 ${fixed} 项修复。"
  else
    info "未做任何改动（没发现需要修复的问题，或你选择了跳过）。"
  fi
  say ""
  say "${C_BOLD}建议下一步${C_RESET}"
  hint "1) 确认 dpkg 已干净： sudo dpkg --audit    （无输出即为正常）"
  hint "2) 重新安装目标版本： sudo bash ${SCRIPT_NAME} install <版本>"
  hint "3) 若仍然失败，把日志最后 100 行发我： tail -n 100 ${LOG_FILE}"
  hr
  return 0
}

# =============================================================================
#  十一、交互菜单
# =============================================================================

interactive_menu() {
  if [[ ! -t 0 ]]; then
    err "当前不是交互终端，无法进入菜单。"
    hint "请使用子命令，例如： bash ${SCRIPT_NAME} detect / list / install 12.6"
    return 1
  fi
  while true; do
    printf '\n%s\n' "================ NVIDIA CUDA Toolkit 管理器 ================"
    printf ' %s\n' "1) 检测环境与已安装版本"
    printf ' %s\n' "2) 列出全部可安装版本"
    printf ' %s\n' "3) 安装指定版本"
    printf ' %s\n' "4) 卸载指定版本"
    printf ' %s\n' "5) 切换默认版本"
    printf ' %s\n' "6) 环境体检"
    printf ' %s\n' "7) 修复安装故障 / dpkg 中断"
    printf ' %s\n' "0) 退出"
    printf '%s\n' "==========================================================="
    local choice=""
    choice="$(read_line "请输入选项 [0-7]: ")"
    case "$choice" in
      1) cmd_detect ;;
      2) cmd_list ;;
      3)
        cmd_list
        local v=""
        v="$(read_line $'\n请输入要安装的版本（如 12.6 / 12.6.3，回车取消）: ')"
        if [[ -n "$v" ]]; then cmd_install "$v"; fi
        ;;
      4)
        cmd_detect
        local v2=""
        v2="$(read_line $'\n请输入要卸载的版本（如 12.6，输入 all 卸载全部，回车取消）: ')"
        if [[ -n "$v2" ]]; then cmd_uninstall "$v2"; fi
        ;;
      5)
        cmd_detect
        local v3=""
        v3="$(read_line $'\n请输入要设为默认的版本（如 12.6，回车取消）: ')"
        if [[ -n "$v3" ]]; then cmd_use "$v3"; fi
        ;;
      6) cmd_doctor ;;
      7) cmd_repair ;;
      0|"") info "已退出。"; return 0 ;;
      *) warn "无效选项：$choice" ;;
    esac
  done
}

# =============================================================================
#  十二、帮助与入口
# =============================================================================

usage() {
  cat <<'EOF'
cuda-manager.sh — NVIDIA CUDA Toolkit 环境管理器

用法:
  sudo bash cuda-manager.sh [选项] <子命令> [参数]

子命令:
  detect                  检测运行环境、GPU/驱动、已安装的 CUDA 版本
  list                    联网列出官方源中全部可安装版本
  install   <版本>        安装指定版本（如 12.6 / 12.6.3 / cuda-toolkit-12-6）
  uninstall <版本|all>    卸载指定版本或全部版本
  use       <版本>        切换 /usr/local/cuda 默认指向
  doctor                  环境体检（只读，不做任何改动）
  repair                  一键修复：残缺包状态(iF/iU/ic)、dpkg 中断、残留文件、失效源配置
  menu                    进入交互菜单（默认行为）

选项:
  -y, --yes               自动确认「是否继续」类提问
      --dry-run           只打印将执行的命令，不做任何实际改动
      --method repo|runfile
                          安装方式，repo = 官方软件源（默认），runfile = 官方离线包
      --runfile-url URL   runfile 模式下直接指定安装包地址
      --mirror auto|cn|com
                          下载源，auto 优先国内镜像（默认）
      --repo <仓库标识>   强制使用指定官方仓库（默认按当前系统自动适配，
                          例如 wsl-ubuntu / ubuntu2604 / ubuntu2404 / rhel9）
      --no-index          不联网拉取版本清单，改用内置参考列表
      --log FILE          指定日志文件（默认 /var/log/cuda-manager.log）
      --no-color          关闭彩色输出
      --force-destructive 跳过卸载时的逐字确认（危险，谨慎使用）
  -h, --help              显示本帮助
  -V, --version           显示脚本版本

示例:
  bash cuda-manager.sh detect
  bash cuda-manager.sh list
  bash cuda-manager.sh --repo wsl-ubuntu list   # 强制用某个官方仓库查看版本
  sudo bash cuda-manager.sh install 12.6
  sudo bash cuda-manager.sh install 12.6.3
  sudo bash cuda-manager.sh uninstall 12.6
  sudo bash cuda-manager.sh uninstall all
  sudo bash cuda-manager.sh use 13.4
  sudo bash cuda-manager.sh repair
  sudo bash cuda-manager.sh --log /mnt/d/share/cuda-manager.log install 13.1
  sudo bash cuda-manager.sh --method runfile --runfile-url https://.../cuda_12.6.0_560.28.03_linux.run install 12.6.0

说明:
  * 本脚本只安装 CUDA Toolkit，不会安装、升级或卸载显卡驱动。
  * WSL 环境下的驱动由 Windows 宿主提供，Linux 侧只需安装 Toolkit。
  * 版本清单与安装源按当前系统自动适配：逐个版本从最合适的官方仓库取源
    （例如 WSL 的 wsl-ubuntu 更新滞后时，会自动改用发行版原生仓库获取新版本）。
  * 支持多版本共存，切换默认版本请使用 use 子命令。
  * 所有外部命令的完整输出都会写入日志，安装失败会自动打印「失败诊断」。
  * 若 dpkg 卡在 iF（多为 cuda-toolkit-X-Y-config-common），repair 会先补出维护脚本
    缺失的 /usr/local/cuda-X.Y 再重新配置；直接 dpkg --configure -a 会一直反复失败。
  * 卸载为破坏性操作，需逐字输入 DELETE 确认。
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help) usage; exit 0 ;;
      -V|--version) printf '%s %s\n' "$SCRIPT_NAME" "$SCRIPT_VERSION"; exit 0 ;;
      -y|--yes) ASSUME_YES="yes" ;;
      --dry-run) DRY_RUN="yes" ;;
      --no-color)
        C_RESET=''; C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''; C_BOLD=''; C_DIM=''
        ;;
      --no-index) USE_INDEX="no" ;;
      --repo)
        shift; REPO_FORCE="${1:-}"
        [[ -n "$REPO_FORCE" ]] || { err "--repo 需要指定仓库标识，例如 ubuntu2404"; exit 2; }
        ;;
      --repo=*)
        REPO_FORCE="${1#*=}"
        [[ -n "$REPO_FORCE" ]] || { err "--repo 需要指定仓库标识，例如 ubuntu2404"; exit 2; }
        ;;
      --log)
        shift; CUDA_MANAGER_LOG="${1:-}"
        [[ -n "$CUDA_MANAGER_LOG" ]] || { err "--log 需要指定文件路径"; exit 2; }
        ;;
      --log=*)
        CUDA_MANAGER_LOG="${1#*=}"
        [[ -n "$CUDA_MANAGER_LOG" ]] || { err "--log 需要指定文件路径"; exit 2; }
        ;;
      --force-destructive) FORCE_DESTRUCTIVE="yes" ;;
      --method)
        shift
        METHOD="${1:-}"
        case "$METHOD" in
          repo|runfile) : ;;
          *) err "--method 只支持 repo 或 runfile"; exit 2 ;;
        esac
        ;;
      --method=*)
        METHOD="${1#*=}"
        case "$METHOD" in
          repo|runfile) : ;;
          *) err "--method 只支持 repo 或 runfile"; exit 2 ;;
        esac
        ;;
      --runfile-url)
        shift; RUNFILE_URL="${1:-}"
        ;;
      --runfile-url=*)
        RUNFILE_URL="${1#*=}"
        ;;
      --mirror)
        shift
        MIRROR="${1:-}"
        case "$MIRROR" in
          auto|cn|com) : ;;
          *) err "--mirror 只支持 auto / cn / com"; exit 2 ;;
        esac
        ;;
      --mirror=*)
        MIRROR="${1#*=}"
        ;;
      -*)
        err "未知选项：$1"
        hint "使用 -h 查看帮助。"
        exit 2
        ;;
      *)
        if [[ -z "$ACTION" && "$1" =~ ^[a-zA-Z]+$ ]]; then
          ACTION="$1"
        else
          ARG_EXTRA+=("$1")
        fi
        ;;
    esac
    shift || true
  done

  # 位置参数中的第一个非子命令词视为版本号
  if [[ ${#ARG_EXTRA[@]} -gt 0 && -z "$ARG_VERSION" ]]; then
    ARG_VERSION="${ARG_EXTRA[0]}"
  fi
  return 0
}

main() {
  parse_args "$@"
  _log_init
  _log_raw "=== ${SCRIPT_NAME} ${SCRIPT_VERSION} 启动：$* ==="

  WORK_DIR="$(mktemp -d -t cuda-manager.XXXXXX 2>/dev/null)" || WORK_DIR="/tmp/cuda-manager.$$"
  mkdir -p -- "$WORK_DIR" 2>/dev/null || true
  BACKUP_DIR="${CUDA_MANAGER_BACKUP:-/var/backups/cuda-manager}/$(date '+%Y%m%d-%H%M%S' 2>/dev/null || echo 0)"

  detect_all

  case "${ACTION:-menu}" in
    ""|menu)
      interactive_menu
      ;;
    detect|status|info) cmd_detect ;;
    list|versions) cmd_list ;;
    install)
      if [[ -z "$ARG_VERSION" ]]; then
        err "install 需要指定版本，例如： install 12.6"
        exit 2
      fi
      cmd_install "$ARG_VERSION"
      ;;
    uninstall|remove|purge)
      cmd_uninstall "${ARG_VERSION:-all}"
      ;;
    use|switch|set)
      cmd_use "${ARG_VERSION:-}"
      ;;
    doctor|check)
      cmd_doctor
      ;;
    repair|fix)
      cmd_repair
      ;;
    *)
      err "未知子命令：${ACTION}"
      hint "使用 -h 查看帮助。"
      exit 2
      ;;
  esac
}

main "$@"


# =============================================================================
#  面板声明（供 panel.sh 自动发现，不参与脚本执行）
# =============================================================================
# PANEL: CUDA 管理 | 开发环境 | 1 | 只装 Toolkit，不动显卡驱动
# PANEL-CMD: 环境检测 | detect | 系统 / GPU / 驱动 / 已装版本
# PANEL-CMD: 列出可安装版本 | list | 联网读取官方源全部版本
# PANEL-CMD: 安装指定版本 | install {{CUDA 版本:12.6}} | 可精确到补丁号，如 12.6.3
# PANEL-CMD: 卸载指定版本或全部 | uninstall {{版本或 all:all}} | 需逐字输入 DELETE 确认
# PANEL-CMD: 切换默认版本 | use {{CUDA 版本:12.6}} | 改变 /usr/local/cuda 指向
# PANEL-CMD: 环境体检 | doctor | 只读诊断
# PANEL-CMD: 一键修复 | repair | 修复 dpkg 中断 / 残缺包 / 失效源
