#!/usr/bin/env bash
# =============================================================================
#  setup_vimrc.sh —— 一条命令给系统上「所有用户」装好通用 Vim 配置
#
#  支持的发行版（自动识别，无需手动指定；其它发行版按 vim 自报路径自适应）：
#    · Debian 系 : Debian / Ubuntu / Kali / Linux Mint / Deepin /
#                  统信 UOS / Raspbian / Devuan
#    · RedHat 系 : RHEL / CentOS / Fedora / Rocky / AlmaLinux / Oracle Linux /
#                  openEuler / 麒麟 Kylin / Anolis / TencentOS / 龙蜥
#    · Arch   系 : Arch / Manjaro / EndeavourOS / Garuda / CachyOS
#    · SUSE   系 : openSUSE Leap / Tumbleweed / SLES
#    · Alpine    : Alpine Linux（需先 apk add bash）
#
#  工作原理：
#    1) 把配置正文写到跨发行版统一位置 /etc/vim/vimrc.local
#    2) 找到「vim 真正会加载的」system vimrc（由 `vim --version` 报告），
#       并在其中注入一段带标记的 source 引用（幂等，可重复执行）
#    3) 写入 /etc/skel/.vimrc，使之后新建的用户自动继承
#    4) 可选：为已存在的用户（含 root）创建 ~/.vimrc 软链接
#
#  用法：
#    sudo ./setup_vimrc.sh                 # 安装（全局 + 新用户）
#    sudo ./setup_vimrc.sh --all-users     # 同时覆盖已存在的用户（含 root）
#    sudo ./setup_vimrc.sh --nvim          # 额外配置 Neovim 系统级 sysinit.vim
#    sudo ./setup_vimrc.sh --install-vim   # 未装完整版 vim 时自动用包管理器安装
#    sudo ./setup_vimrc.sh --dry-run       # 只打印将做什么，不落任何改动
#    sudo ./setup_vimrc.sh --uninstall     # 卸载脚本所做的一切改动
#    sudo ./setup_vimrc.sh -h | --help
#
#  卸载后想彻底还原：备份都在 /etc/vim/.workbuddy-backup-<时间戳>/ 里
#
#  维护说明：脚本内嵌了一份配置正文（VIMRC_EOF 标记之间）供「单文件分发」使用。
#  脚本优先使用同目录下的 vimrc 文件；内嵌版本由该 vimrc 自动生成，两者保持一致。
#  改动配置时请改 vimrc（或直接改 /etc/vim/vimrc.local），无需重跑脚本。
# =============================================================================

set -euo pipefail

# ----------------------------- 常量 ------------------------------------------
# 注意：自定义变量一律加前缀。切勿使用 VERSION / NAME / ID / VERSION_ID 这类
# 通用名 —— 它们与 /etc/os-release 的字段同名，早期版本因 `readonly VERSION`
# 与 os-release 的 VERSION 冲突，导致脚本启动即报
#   "/etc/os-release: line 4: VERSION: readonly variable"
readonly SCRIPT_VERSION="1.0.1"
readonly GLOBAL_VIMRC="/etc/vim/vimrc.local"    # 配置正文的唯一落地位置
readonly NVIM_SYSINIT="/etc/xdg/nvim/sysinit.vim"
readonly SKEL_DIR="/etc/skel"
readonly STAMP="$(date +%Y%m%d-%H%M%S)"
readonly BACKUP_DIR="/etc/vim/.workbuddy-backup-${STAMP}"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly MARK_BEGIN='" >>> workbuddy-global-vimrc >>>'
readonly MARK_END='" <<< workbuddy-global-vimrc <<<'

# ----------------------------- 开关 ------------------------------------------
DRY_RUN=0
ALL_USERS=0
WITH_NVIM=0
INSTALL_VIM=0
FORCE=0
DO_UNINSTALL=0

# ----------------------------- 运行时变量 ------------------------------------
OS_ID="unknown"; OS_LIKE=""; OS_PRETTY="Linux"; OS_FAMILY="other"
VIM_BIN=""; VIM_VERSION=""; VIM_FEATURES=""; VIM_FULL=0
SYSTEM_VIMRC=""; VIM_HOME=""; VIM_RUNTIME=""
PATCHED_FILES=(); SKIPPED_FILES=(); USER_LINKS=0 USER_SKIPS=0 USER_MISSING=0

# ----------------------------- 输出 ------------------------------------------
if [ -t 1 ] && [ "${NO_COLOR:-}" = "" ]; then
  C_RST=$'\033[0m'; C_B=$'\033[1m'; C_R=$'\033[31m'
  C_G=$'\033[32m'; C_Y=$'\033[33m'; C_BL=$'\033[34m'; C_D=$'\033[2m'
else
  C_RST=""; C_B=""; C_R=""; C_G=""; C_Y=""; C_BL=""; C_D=""
fi
__OPS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# shellcheck source=/dev/null
source "${__OPS_DIR}/lib/lib.sh"
unset __OPS_DIR
Lib::bootstrap ""
Lib::install_err_trap

dry()  { [ "${DRY_RUN:-0}" -eq 1 ] && printf '%s[dry-run]%s %s\n' "$C_DIM" "$C_RESET" "$*" || true; }

run() {  # dry-run 包装 + 命令日志，统一走 lib/40-exec.sh 的 Runner
  RUN[dry_run]="${DRY_RUN:-0}"
  Runner::exec RUN "$@"
}

usage() { sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

# ----------------------------- 参数解析 --------------------------------------
parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run|-n)      DRY_RUN=1 ;;
      --all-users|-a)    ALL_USERS=1 ;;
      --nvim)            WITH_NVIM=1 ;;
      --install-vim)     INSTALL_VIM=1 ;;
      --force|-f)        FORCE=1 ;;
      --uninstall|-u)    DO_UNINSTALL=1 ;;
      -h|--help)         usage ;;
      *) die "未知参数：$1（用 --help 查看用法）" ;;
    esac
    shift
  done
}

require_root() {
  [ "$(Sys::euid)" -eq 0 ] && return 0
  if sys::has_cmd sudo; then
    info "需要 root 权限，改用 sudo 重新执行…"
    exec sudo -E bash "$0" "$@"
  fi
  die "请以 root 运行：sudo $0"
}

# ----------------------------- 系统识别 --------------------------------------
# 只解析需要的字段，**绝不 source** /etc/os-release：
#   1) source 会污染当前命名空间，可能撞上只读变量（VERSION/NAME/ID 都是常见名）
#   2) 某些系统的 os-release 含更复杂的写法，直接 source 有风险
osrel_get() { OS::osrel "$1" "${2:-/etc/os-release}"; }

detect_os() {
  local f=""
  for f in /etc/os-release /usr/lib/os-release; do
    if [ -r "$f" ]; then break; fi
  done
  [ -r "$f" ] || f=""

  if [ -n "$f" ]; then
    OS_ID="$(osrel_get ID "$f")"
    OS_LIKE="$(osrel_get ID_LIKE "$f")"
    OS_PRETTY="$(osrel_get PRETTY_NAME "$f")"
    OS_ID="${OS_ID:-unknown}"
    OS_PRETTY="${OS_PRETTY:-$OS_ID}"
  else
    # 兜底：没有 os-release 的老系统 / 精简容器镜像
    OS_ID="unknown"; OS_LIKE=""; OS_PRETTY="Linux"
    if   [ -r /etc/redhat-release ];  then OS_ID="rhel";   OS_LIKE="rhel";   OS_PRETTY="$(head -n1 /etc/redhat-release 2>/dev/null)"
    elif [ -r /etc/debian_version ];  then OS_ID="debian"; OS_LIKE="debian"; OS_PRETTY="Debian $(head -n1 /etc/debian_version 2>/dev/null)"
    elif [ -r /etc/arch-release ];    then OS_ID="arch";   OS_LIKE="arch";   OS_PRETTY="Arch Linux"
    elif [ -r /etc/alpine-release ];  then OS_ID="alpine"; OS_LIKE="alpine"; OS_PRETTY="Alpine Linux $(head -n1 /etc/alpine-release 2>/dev/null)"
    elif [ -r /etc/SuSE-release ];    then OS_ID="suse";   OS_LIKE="suse";   OS_PRETTY="SUSE Linux"
    fi
    OS_PRETTY="${OS_PRETTY:-Linux}"
  fi

  # 家族判定统一走 lib/20-os.sh（判定表与其余脚本共用一份）
  OS_FAMILY="$(OS::family_of "$OS_ID" "$OS_LIKE")"
  case "$OS_FAMILY" in unknown|"") OS_FAMILY="other" ;; esac
}

pkg_install_vim() {
  step "安装完整版 vim"
  if command -v dnf >/dev/null 2>&1; then
    run dnf install -y vim-enhanced
  elif command -v yum >/dev/null 2>&1; then
    run yum install -y vim-enhanced
  elif command -v apt-get >/dev/null 2>&1; then
    run apt-get update
    run env DEBIAN_FRONTEND=noninteractive apt-get install -y vim vim-runtime ||
      run env DEBIAN_FRONTEND=noninteractive apt-get install -y vim-nox
  elif command -v pacman >/dev/null 2>&1; then
    run pacman -Sy --needed --noconfirm vim
  elif command -v zypper >/dev/null 2>&1; then
    run zypper --non-interactive install vim
  elif command -v apk >/dev/null 2>&1; then
    run apk add --no-cache vim vim-vimrc
  else
    warn "未识别包管理器，请手动安装完整版 vim（需含 +eval +syntax +persistent_undo）"
    return 1
  fi
}

# ----------------------------- vim 探测 --------------------------------------
expand_vim_path() {  # 把 "$VIM/vimrc" 这类表达式展开为真实路径
  case "$1" in
    '$VIM'/*)        printf '%s' "${VIM_HOME}${1#\$VIM}" ;;
    '$VIMRUNTIME'/*) printf '%s' "${VIM_RUNTIME}${1#\$VIMRUNTIME}" ;;
    *)               printf '%s' "$1" ;;
  esac
}

_read_vim_info() {  # 解析某个 vim 可执行文件的版本与路径信息
  local bin="$1" vv
  vv="$("$bin" --version 2>/dev/null || true)"
  VIM_VERSION="$(printf '%s\n' "$vv" | sed -n '1s/^VIM - Vi IMproved \([0-9.]*\).*/\1/p')"
  VIM_HOME="$(printf '%s\n' "$vv" | sed -n 's/^ *fallback for \$VIM: *"\(.*\)".*/\1/p' | head -n1)"
  VIM_RUNTIME="$(printf '%s\n' "$vv" | sed -n 's/^ *fallback for \$VIMRUNTIME: *"\(.*\)".*/\1/p' | head -n1)"
  VIM_FEATURES="$(printf '%s\n' "$vv" | grep -E '^ *[+-]' | tr -d ' \n' || true)"

  # vim 自己报告的 system vimrc —— 最权威的来源，跨发行版通吃
  local sysraw
  sysraw="$(printf '%s\n' "$vv" | sed -n 's/^ *system vimrc file: *"\(.*\)".*/\1/p' | head -n1)"
  SYSTEM_VIMRC="$(expand_vim_path "$sysraw")"

  case "$VIM_FEATURES" in
    *+eval*+syntax*) VIM_FULL=1 ;;
    *)               VIM_FULL=0 ;;
  esac
  return 0
}

detect_vim() {
  local retry="${1:-0}"

  VIM_BIN="$(command -v vim 2>/dev/null || true)"
  if [ -z "$VIM_BIN" ]; then
    warn "系统未安装 vim"
    if [ "$INSTALL_VIM" -eq 1 ] && [ "$retry" -eq 0 ]; then
      pkg_install_vim || true
      detect_vim 1; return $?
    fi
    die "请先安装 vim（或使用 --install-vim 自动安装）"
  fi

  _read_vim_info "$VIM_BIN"

  # Debian 系常有 vim.tiny / vim.basic 多实现，优先切换到完整版
  if [ "$VIM_FULL" -eq 0 ]; then
    local cand
    for cand in /usr/bin/vim.basic /usr/bin/vim.nox /usr/bin/vim.gtk3 /usr/bin/vim.gtk; do
      [ -x "$cand" ] || continue
      _read_vim_info "$cand"
      if [ "$VIM_FULL" -eq 1 ]; then VIM_BIN="$cand"; break; fi
    done
  fi

  # 精简版且允许自动安装 → 装完整版后重试一次
  if [ "$VIM_FULL" -eq 0 ] && [ "$INSTALL_VIM" -eq 1 ] && [ "$retry" -eq 0 ]; then
    warn "当前为精简版 vim，尝试安装完整版…"
    pkg_install_vim || true
    detect_vim 1; return $?
  fi

  info "vim 路径     : $VIM_BIN"
  info "vim 版本     : ${VIM_VERSION:-未知}"
  info "system vimrc : ${SYSTEM_VIMRC:-<vim 未报告>}"
  info "\$VIM         : ${VIM_HOME:-未知}"
  case "$VIM_FEATURES" in
    *+persistent_undo*) : ;;
    *) warn "当前 vim 不支持 +persistent_undo，撤销历史不跨会话保留" ;;
  esac
  if [ "$VIM_FULL" -eq 0 ]; then
    warn "当前 vim 是精简版（vim-tiny / -eval 或 -syntax 缺失），配置将降级为最小模式"
    warn "建议安装完整版：$(case "$OS_FAMILY" in
      debian) echo 'apt-get install -y vim vim-runtime （或 vim-nox）';;
      rhel)   echo 'dnf install -y vim-enhanced';;
      arch)   echo 'pacman -S vim';;
      suse)   echo 'zypper install vim';;
      alpine) echo 'apk add vim vim-vimrc';;
      *)      echo '使用发行版包管理器安装完整版 vim';;
    esac)"
  fi
  return 0
}

# ----------------------------- 备份 / 注入 -----------------------------------
ensure_dir() { [ -d "$1" ] || run mkdir -p "$1"; }

# 容错读取用户列表（getent 优先，退回 /etc/passwd；任何失败都不中断脚本）
read_passwd_list() {
  local out=""
  if command -v getent >/dev/null 2>&1; then
    out="$(getent passwd 2>/dev/null || true)"
  fi
  if [ -z "$out" ] && [ -r /etc/passwd ]; then
    out="$(cat /etc/passwd 2>/dev/null || true)"
  fi
  printf '%s' "$out"
}

backup_file() {
  local f="$1"
  [ -e "$f" ] || return 0
  if [ "$DRY_RUN" -eq 1 ]; then dry "备份 $f → $BACKUP_DIR/"; return 0; fi
  mkdir -p "$BACKUP_DIR"
  local safe; safe="$(printf '%s' "$f" | tr '/' '_')"
  cp -a "$f" "${BACKUP_DIR}/${safe}.bak"
  ok "已备份 $f → ${BACKUP_DIR}/${safe}.bak"
}

# 在目标文件里只做一件事：确保它会 source /etc/vim/vimrc.local
inject_source_block() {
  local f="$1"

  case "$f" in
    *vimrc.tiny|*vimrc.tiny.vim) return 0 ;;
  esac
  [ -r "$f" ] || return 0

  if grep -qF "$MARK_BEGIN" "$f" 2>/dev/null; then
    SKIPPED_FILES+=("$f"); ok "已注入过，跳过：$f"; return 0
  fi
  if grep -q 'vimrc\.local' "$f" 2>/dev/null; then
    SKIPPED_FILES+=("$f"); ok "该文件已自行引入 vimrc.local，跳过：$f"; return 0
  fi

  backup_file "$f"
  if [ "$DRY_RUN" -eq 1 ]; then dry "向 $f 追加引用块"; PATCHED_FILES+=("$f"); return 0; fi

  if ! { printf '\n%s\n' "$MARK_BEGIN"
         printf "if filereadable('%s')\n  source %s\nendif\n" "$GLOBAL_VIMRC" "$GLOBAL_VIMRC"
         printf '%s\n' "$MARK_END"; } >> "$f" 2>/dev/null; then
    warn "无法写入 $f（可能位于只读文件系统或不可变系统），跳过"
    return 0
  fi
  PATCHED_FILES+=("$f")
  ok "已注入引用块：$f"
}

# 收集「vim 可能会加载的」所有全局 vimrc 候选，逐个幂等注入
sysvimrc_candidates() {
  local -a list=()
  local p
  for p in "$SYSTEM_VIMRC" "/etc/vim/vimrc" "/etc/vimrc" "/usr/share/vim/vimrc" "${VIM_HOME:-/nonexistent}/vimrc"; do
    case "$p" in
      ""|"/vimrc"|/nonexistent/*) continue ;;
      *vimrc.tiny) continue ;;
    esac
    local seen=0 q
    for q in "${list[@]:-}"; do [ "$q" = "$p" ] && seen=1 && break; done
    [ "$seen" -eq 1 ] && continue
    list+=("$p")
  done
  printf '%s\n' "${list[@]:-}"
}

install_global() {
  step "部署全局配置"
  ensure_dir "/etc/vim"

  local src="$SCRIPT_DIR/vimrc"
  if [ -r "$src" ]; then
    info "使用同目录下的 vimrc 作为配置源：$src"
    backup_file "$GLOBAL_VIMRC"
    if [ "$DRY_RUN" -eq 0 ]; then
      cp -f "$src" "$GLOBAL_VIMRC"
      chmod 644 "$GLOBAL_VIMRC"
    else
      dry "拷贝 $src → $GLOBAL_VIMRC"
    fi
  else
    info "未找到同目录 vimrc，写入内置版本（内容与 vimrc 文件一致）"
    backup_file "$GLOBAL_VIMRC"
    [ "$DRY_RUN" -eq 1 ] || write_builtin_vimrc
  fi
  ok "全局配置：$GLOBAL_VIMRC"

  # 逐个候选文件注入引用
  local f
  while IFS= read -r f; do
    if [ -n "$f" ]; then inject_source_block "$f"; fi
  done < <(sysvimrc_candidates)

  if [ "${#PATCHED_FILES[@]}" -eq 0 ] && [ "${#SKIPPED_FILES[@]}" -eq 0 ]; then
    # 一个可注入的全局 vimrc 都没找到 —— 用 vim 自报的路径兜底创建
    local fallback="$SYSTEM_VIMRC"
    case "$fallback" in
      /etc/*) : ;;
      *) fallback="/etc/vim/vimrc" ;;
    esac
    warn "未找到任何已存在的 system vimrc 文件（vim 报告：${SYSTEM_VIMRC:-<空>}）"
    warn "将创建兜底 system vimrc：$fallback"
    if [ "$DRY_RUN" -eq 1 ]; then
      dry "创建 $fallback 并注入引用块"
    else
      mkdir -p "$(dirname "$fallback")"
      if [ ! -e "$fallback" ]; then : > "$fallback"; fi
      inject_source_block "$fallback"
    fi
  fi

  # RHEL 系 SELinux 上下文修正
  if command -v restorecon >/dev/null 2>&1 && [ "$DRY_RUN" -eq 0 ]; then
    restorecon -F "$GLOBAL_VIMRC" 2>/dev/null || true
  fi
}

# ----------------------------- skel / 已有用户 -------------------------------
install_skel() {
  step "配置 /etc/skel（对之后新建的用户生效）"
  ensure_dir "$SKEL_DIR"
  local target="$SKEL_DIR/.vimrc"

  if [ -L "$target" ] && [ "$(readlink "$target")" = "$GLOBAL_VIMRC" ]; then
    ok "已存在软链接，跳过：$target"
  elif [ -e "$target" ] && [ "$FORCE" -eq 0 ]; then
    warn "$target 已存在且非本脚本创建，未改动（加 --force 可覆盖备份后替换）"
  else
    if [ -e "$target" ]; then backup_file "$target"; fi
    run ln -sfn "$GLOBAL_VIMRC" "$target"
    ok "已创建软链接：$target → $GLOBAL_VIMRC"
  fi

  # 为 skel 预建运行时目录（新用户首次登录即就位）
  run mkdir -p "$SKEL_DIR/.vim/undo" "$SKEL_DIR/.vim/backup" "$SKEL_DIR/.vim/swap"
  [ "$DRY_RUN" -eq 1 ] || chmod 700 "$SKEL_DIR/.vim" "$SKEL_DIR/.vim/undo" "$SKEL_DIR/.vim/backup" "$SKEL_DIR/.vim/swap" 2>/dev/null || true
  ok "已准备 $SKEL_DIR/.vim/{undo,backup,swap}"
}

link_user() {
  local uname="$1" home="$2" target="$home/.vimrc"

  if [ -L "$target" ] && [ "$(readlink "$target")" = "$GLOBAL_VIMRC" ]; then
    ok "已是目标软链，跳过：$uname ($target)"; return 0
  fi
  if [ -e "$target" ]; then
    if [ "$FORCE" -eq 0 ]; then
      warn "用户 $uname 已有 $target，为免覆盖其个人配置而跳过（--force 可备份后替换）"
      USER_SKIPS=$((USER_SKIPS + 1)); return 0
    fi
    backup_file "$target"
  fi
  if run ln -sfn "$GLOBAL_VIMRC" "$target"; then
    [ "$DRY_RUN" -eq 1 ] || chown -h "$uname" "$target" 2>/dev/null || true
    ok "已为用户 $uname 创建 $target"
    USER_LINKS=$((USER_LINKS + 1))
  else
    warn "为用户 $uname 创建 $target 失败"; USER_SKIPS=$((USER_SKIPS + 1))
  fi
}

install_all_users() {
  step "为已存在的用户创建 ~/.vimrc"
  local pwlist; pwlist="$(read_passwd_list)"
  if [ -z "$pwlist" ]; then warn "无法读取用户列表（getent /etc/passwd 均不可用），跳过"; return 0; fi

  local uname _pw uid _gid _gecos home shell
  while IFS=: read -r uname _pw uid _gid _gecos home shell; do
    [ -n "${uid:-}" ] || continue
    case "$uid" in *[!0-9]*) continue ;; esac
    # 只处理 root 与 UID>=1000 的普通用户
    if [ "$uid" -ne 0 ] && [ "$uid" -lt 1000 ]; then continue; fi
    # 排除系统账户
    case "$shell" in */nologin|*/false|"") continue ;; esac
    if [ ! -d "$home" ]; then
      USER_MISSING=$((USER_MISSING + 1)); continue
    fi
    if [ ! -w "$home" ]; then
      warn "用户 $uname 的家目录不可写，跳过：$home"; USER_SKIPS=$((USER_SKIPS + 1)); continue
    fi
    link_user "$uname" "$home"
    run mkdir -p "$home/.vim/undo" "$home/.vim/backup" "$home/.vim/swap"
    if [ "$DRY_RUN" -eq 0 ]; then
      chmod 700 "$home/.vim" "$home/.vim"/undo "$home/.vim"/backup "$home/.vim"/swap 2>/dev/null || true
      chown -R "$uname" "$home/.vim" 2>/dev/null || true
    fi
  done <<< "$pwlist"

  ok "用户软链：新建 ${USER_LINKS} 个，跳过 ${USER_SKIPS} 个，家目录缺失 ${USER_MISSING} 个"
}

# ----------------------------- Neovim ----------------------------------------
install_nvim() {
  step "配置 Neovim（系统级 sysinit.vim）"
  local nvim_bin; nvim_bin="$(command -v nvim 2>/dev/null || true)"
  if [ -z "$nvim_bin" ]; then
    warn "未安装 nvim，跳过（配置本身对 nvim 基本兼容，装好后可重跑 --nvim）"
    return 0
  fi
  ensure_dir "$(dirname "$NVIM_SYSINIT")"
  inject_source_block "$NVIM_SYSINIT" || true
  if [ ! -e "$NVIM_SYSINIT" ] && [ "$DRY_RUN" -eq 0 ]; then
    # 文件不存在时 inject 会跳过，这里直接创建并注入
    : > "$NVIM_SYSINIT"
    inject_source_block "$NVIM_SYSINIT"
  fi
  ok "Neovim：$NVIM_SYSINIT"
}

# ----------------------------- 校验 ------------------------------------------
verify() {
  step "校验配置可正常加载"
  if [ "$DRY_RUN" -eq 1 ]; then dry "跳过校验"; return 0; fi

  local out=""
  out="$("$VIM_BIN" -u NONE -N -es -c "source $GLOBAL_VIMRC" -c 'qall!' </dev/null 2>&1 || true)"
  out="$(printf '%s' "$out" | grep -v '^[[:space:]]*$' || true)"
  if [ -n "$out" ]; then
    warn "加载 $GLOBAL_VIMRC 时出现输出/错误："
    printf '%s\n' "$out" | sed 's/^/       /' >&2
  else
    ok "vim 加载全局配置无任何报错"
  fi

  # 抽查关键选项是否真的生效
  local probe
  probe="$("$VIM_BIN" -u NONE -N -es -c "source $GLOBAL_VIMRC" \
        -c 'echo "number=".string(&number)." cursorline=".string(&cursorline)." expandtab=".string(&expandtab)." encoding=".&encoding' \
        -c 'qall!' </dev/null 2>/dev/null | tr -d '\r' || true)"
  if [ -n "$probe" ]; then info "生效检查：$probe"; else warn "未能获取选项状态，请手动执行 vim 验证"; fi

  # 后缀识别抽查
  if [ -w /tmp ]; then
    local t="/tmp/.setup_vimrc_probe.py" p2
    printf 'print(1)\n' > "$t"
    p2="$("$VIM_BIN" -u NONE -N -es -c "source $GLOBAL_VIMRC" -c "edit $t" \
          -c 'echo "ft=".&filetype." shiftwidth=".string(&shiftwidth)' -c 'qall!' </dev/null 2>/dev/null | tr -d '\r' || true)"
    rm -f "$t"
    if [ -n "$p2" ]; then info "后缀识别抽查（.py）：$p2"; fi
  fi

  if command -v nvim >/dev/null 2>&1 && [ "$WITH_NVIM" -eq 1 ]; then
    local nout=""
    nout="$(nvim --headless -u NONE -c "source $GLOBAL_VIMRC" -c 'qa!' 2>&1 || true)"
    if [ -n "$nout" ]; then warn "Neovim 加载输出：$nout"; else ok "Neovim 加载无报错"; fi
  fi
  return 0
}

# ----------------------------- 内置配置正文 ----------------------------------
write_builtin_vimrc() {
  cat > "$GLOBAL_VIMRC" <<'VIMRC_EOF'
" ============================================================================
"  通用 Vim 配置（系统级）—— 安装位置：/etc/vim/vimrc.local
"  由 setup_vimrc.sh 自动部署；被各发行版的 system vimrc 在启动时 source，
"  因此对系统上所有用户生效。用户可在 ~/.vimrc 中覆盖任意设置。
"
"  适用：Vim 7.4+ / Vim 8 / Vim 9 / Neovim
"  发行版：Debian/Ubuntu/Kali/Deepin/UOS、RHEL/CentOS/Fedora/Rocky/Alma/
"          openEuler/麒麟/Anolis、Arch/Manjaro、openSUSE/SLES、Alpine
" ============================================================================

" ---------------------------------------------------------------------------
" 0. 前置保护
" ---------------------------------------------------------------------------
" vim-tiny / 精简版（无 +eval 或 +syntax）功能太弱，降级为最基本设置后退出，
" 避免 :if / has() 之类不可用时刷屏报错。请安装完整版 vim 以启用全部功能。
if exists('*has') && (!has('eval') || !has('syntax'))
  set nocompatible
  set number
  set backspace=indent,eol,start
  finish
endif

if &compatible
  set nocompatible
endif

" ---------------------------------------------------------------------------
" 1. 行号 / 光标 / 滚动
" ---------------------------------------------------------------------------
set number                  " 显示绝对行号
set relativenumber          " 显示相对行号（5j / 12k 跳转更直观）
set cursorline              " 高亮当前行
set nocursorcolumn          " 不整列高亮光标所在列（终端下是一道贯穿竖带，太抢眼）
                            " 想开启可改为 set cursorcolumn
set scrolloff=5             " 光标上下各保留 5 行上下文
set sidescrolloff=8
set wrap                    " 超长行自动折行
set linebreak               " 折行按单词边界，不切断单词
set listchars=tab:>\ ,trail:.,extends:>,precedes:<,nbsp:+
set nolist                  " 默认不显示不可见字符（:set list 手动开）

" ---------------------------------------------------------------------------
" 2. 高亮配色（按终端明暗自动切换，兼容 256 色）
" ---------------------------------------------------------------------------
if &background ==# 'dark'
  highlight CursorLine    cterm=NONE ctermbg=236 guibg=#2d2d2d
  highlight CursorLineNr  cterm=bold ctermfg=214 gui=bold guifg=#ffaf00
  highlight LineNr        ctermfg=243 guifg=#6c6c6c
  highlight NonText       ctermfg=238 guifg=#4a4a4a
  highlight VertSplit     cterm=NONE ctermfg=240 guifg=#4e4e4e
else
  highlight CursorLine    cterm=NONE ctermbg=253 guibg=#e8e8e8
  highlight CursorLineNr  cterm=bold ctermfg=130 gui=bold guifg=#af5f00
  highlight LineNr        ctermfg=246 guifg=#8a8a8a
  highlight NonText       ctermfg=250 guifg=#bcbcbc
  highlight VertSplit     cterm=NONE ctermfg=250 guifg=#c6c6c6
endif
" CursorColumn 已停用（见 §1）；此处清掉底色，避免残留访客主题留下竖带
highlight CursorColumn  cterm=NONE ctermbg=NONE guibg=NONE
highlight Search        cterm=reverse ctermfg=16 ctermbg=214 gui=reverse
highlight IncSearch     cterm=reverse ctermfg=16 ctermbg=199 gui=reverse
highlight Visual        cterm=NONE ctermbg=237 guibg=#3a3a3a
highlight MatchParen    cterm=bold ctermfg=16 ctermbg=51 gui=bold
highlight ColorColumn   cterm=NONE ctermbg=236 guibg=#2d2d2d
set colorcolumn=100         " 100 列参考线（不需要可 set colorcolumn=）

" ---------------------------------------------------------------------------
" 3. 缩进与制表符（通用默认 4 空格；各语言在 §7 覆盖）
" ---------------------------------------------------------------------------
set expandtab               " Tab 展开为空格
set shiftwidth=4
set tabstop=4
set softtabstop=4
set shiftround
set autoindent              " 新行继承上一行缩进
set smartindent
set copyindent
set preserveindent
set backspace=indent,eol,start

" ---------------------------------------------------------------------------
" 4. 搜索
" ---------------------------------------------------------------------------
set incsearch               " 边输入边高亮
set hlsearch                " 高亮全部匹配
set ignorecase              " 忽略大小写……
set smartcase               " ……但含大写时区分大小写
set wrapscan
set gdefault                " :s 默认替换行内全部匹配
if has('nvim')
  set inccommand=nosplit    " Neovim：实时预览替换结果
endif

" ---------------------------------------------------------------------------
" 5. 界面 / 状态栏
" ---------------------------------------------------------------------------
set showcmd
set showmode
set ruler
set laststatus=2            " 总是显示状态栏
set statusline=%<%f\ %h%m%r%=\ [%{&fileformat}][%{&fileencoding}][%{&filetype}]\ %l/%L:%c\ %P
set wildmenu
set wildmode=longest:full,full
set wildignore=*.o,*.obj,*.pyc,*.class,*.swp,*.bak,*.zip,*.tar,*.gz,*/node_modules/*,*/__pycache__/*,*/.git/*
set completeopt=menuone,noinsert,noselect
set noerrorbells
if !has('nvim')
  set visualbell
  set t_vb=
endif
set timeoutlen=500
set ttimeoutlen=50          " 终端下 Esc 更跟手
set updatetime=300
set history=1000
set confirm
set hidden
set autoread                " 外部修改后自动重载
let g:netrw_banner = 0

" ---------------------------------------------------------------------------
" 6. 编码 / 换行符（中文环境防乱码）
" ---------------------------------------------------------------------------
set encoding=utf-8
if !has('nvim')
  set termencoding=utf-8
endif
set fileencodings=ucs-bom,utf-8,gb18030,gbk,big5,latin1
set fileformats=unix,dos,mac
set ambiwidth=double        " 全角字符按双宽显示，避免错位

" ---------------------------------------------------------------------------
" 7. 按文件类型（后缀）差异化配置 —— 语法高亮 / 缩进 / 换行
" ---------------------------------------------------------------------------
filetype plugin indent on
syntax enable

augroup WorkBuddyFileType
  autocmd!
  " ---- 空格缩进 ----
  autocmd FileType python,cython,pyrex  setlocal expandtab shiftwidth=4 tabstop=4 softtabstop=4 textwidth=0
  autocmd FileType ruby,eruby           setlocal expandtab shiftwidth=2 tabstop=2 softtabstop=2
  autocmd FileType sh,bash,zsh,ksh      setlocal expandtab shiftwidth=2 tabstop=2 softtabstop=2
  autocmd FileType dockerfile           setlocal expandtab shiftwidth=2 tabstop=2 softtabstop=2
  autocmd FileType yaml,yml,json,jsonc  setlocal expandtab shiftwidth=2 tabstop=2 softtabstop=2
  autocmd FileType html,xhtml,xml,css,scss,less,vue,svelte
        \ setlocal expandtab shiftwidth=2 tabstop=2 softtabstop=2
  autocmd FileType javascript,typescript,javascriptreact,typescriptreact
        \ setlocal expandtab shiftwidth=2 tabstop=2 softtabstop=2
  autocmd FileType lua,vim,perl,tcl,sql setlocal expandtab shiftwidth=2 tabstop=2 softtabstop=2
  " ---- 必须用 Tab 的 ----
  autocmd FileType go                   setlocal noexpandtab shiftwidth=4 tabstop=4 softtabstop=4
  autocmd FileType make,makefile        setlocal noexpandtab tabstop=8 shiftwidth=8 softtabstop=0
  " ---- C 系 ----
  autocmd FileType c,cpp,objc,objcpp,cs,java,rust
        \ setlocal expandtab shiftwidth=4 tabstop=4 softtabstop=4 cindent
  " ---- 文本类 ----
  autocmd FileType markdown,text,gitcommit
        \ setlocal wrap linebreak spell spelllang=en_us nolist
  autocmd FileType tex                  setlocal wrap linebreak expandtab shiftwidth=2
  " ---- 特殊缓冲 ----
  autocmd FileType help,qf,man          setlocal nonumber norelativenumber nocursorline
augroup END

" 补充后缀映射：部分发行版自带 filetype.vim 较旧，按后缀/文件名兜底识别
augroup WorkBuddyFileExt
  autocmd!
  autocmd BufNewFile,BufRead *.conf,*.cfg,*.ini,*.toml,*.properties,*.env,*.service,*.repo setfiletype conf
  autocmd BufNewFile,BufRead *.md,*.markdown                                             setfiletype markdown
  autocmd BufNewFile,BufRead *.tpl,*.j2,*.jinja2,*.yaml.j2                               setfiletype yaml
  autocmd BufNewFile,BufRead *.ts,*.tsx                                                  setfiletype typescript
  autocmd BufNewFile,BufRead *.vue                                                       setfiletype vue
  autocmd BufNewFile,BufRead Dockerfile*,*.dockerfile,Containerfile*                     setfiletype dockerfile
  autocmd BufNewFile,BufRead Jenkinsfile,Vagrantfile,Berksfile                           setfiletype groovy
  autocmd BufNewFile,BufRead *.rasi,*.sls                                                setfiletype yaml
  autocmd BufNewFile,BufRead .bashrc,.bash_profile,.bash_aliases,.profile,.zshrc  setfiletype sh
  autocmd BufNewFile,BufRead .gitconfig,.gitignore                                       setfiletype gitconfig
augroup END

" ---------------------------------------------------------------------------
" 8. 撤销历史 / 备份 / 交换文件（统一收纳到 ~/.vim，首次自动创建）
" ---------------------------------------------------------------------------
silent! call mkdir(expand('~/.vim/undo'),   'p', 0700)
silent! call mkdir(expand('~/.vim/backup'), 'p', 0700)
silent! call mkdir(expand('~/.vim/swap'),   'p', 0700)

set backup
set writebackup
set backupext=.bak
let &backupdir = expand('~/.vim/backup') . '//'
let &directory = expand('~/.vim/swap')   . '//'
if has('persistent_undo')
  set undofile               " 关闭文件后仍可撤销
  let &undodir = expand('~/.vim/undo') . '//'
  set undolevels=1000
endif

" ---------------------------------------------------------------------------
" 9. 自动命令：记忆光标位置 / 外部改动检测
" ---------------------------------------------------------------------------
augroup WorkBuddyAutoCmd
  autocmd!
  " 恢复上次编辑位置
  autocmd BufReadPost *
        \ if line("'\"") > 0 && line("'\"") <= line("$") |
        \   execute 'normal! g`"' |
        \ endif
  " 切回终端时检查文件是否被外部修改
  autocmd FocusGained,BufEnter,CursorHold,CursorHoldI *
        \ if mode() =~# '^[nV]' | silent! checktime | endif
  " 新建文件不自动插入注释头
  autocmd BufNewFile * setlocal noformatoptions
augroup END

" ---------------------------------------------------------------------------
" 10. 快捷键（leader = 逗号）
" ---------------------------------------------------------------------------
let mapleader = ','
let maplocalleader = '\\'

nnoremap <silent> <leader>w :update<CR>
nnoremap <silent> <leader>q :q<CR>
nnoremap <silent> <leader>Q :qa!<CR>
cnoremap w!! w !sudo tee % >/dev/null<CR>      " 以 sudo 权限保存只读文件

nnoremap <silent> <leader>h :nohlsearch<CR>                            " 清搜索高亮
nnoremap <silent> <leader>n :setlocal number! relativenumber!<CR>      " 切行号
nnoremap <silent> <leader>z :setlocal wrap!<CR>                        " 切折行

nnoremap <C-h> <C-w>h
nnoremap <C-j> <C-w>j
nnoremap <C-k> <C-w>k
nnoremap <C-l> <C-w>l
nnoremap <silent> <C-Up>    :resize +2<CR>
nnoremap <silent> <C-Down>  :resize -2<CR>
nnoremap <silent> <C-Left>  :vertical resize -2<CR>
nnoremap <silent> <C-Right> :vertical resize +2<CR>

vnoremap < <gv                                 " 缩进后保持选中
vnoremap > >gv
nnoremap Y y$
nnoremap n nzzzv                               " n/N 结果居中
nnoremap N Nzzzv
nnoremap <A-j> :m .+1<CR>==                    " 上下移动当前行
nnoremap <A-k> :m .-2<CR>==
vnoremap <A-j> :m '>+1<CR>gv=gv
vnoremap <A-k> :m '<-2<CR>gv=gv

" ---------------------------------------------------------------------------
" 11. 鼠标 / 剪贴板 / 真彩色（能力检测，缺失时自动跳过）
" ---------------------------------------------------------------------------
if has('mouse')
  set mouse=a                " 需要选择复制时按住 Shift 拖选
endif
if has('nvim')
  set clipboard=unnamedplus
elseif has('clipboard')
  set clipboard=unnamed      " ssh 下可能略慢，可注释掉
endif
if has('termguicolors')
  set termguicolors
endif

" ---------------------------------------------------------------------------
" 12. 配色主题（存在则启用，否则静默跳过）
" ---------------------------------------------------------------------------
silent! colorscheme desert
" 想要更暗： silent! colorscheme torte
" 想要浅色： silent! colorscheme morning
VIMRC_EOF
  chmod 644 "$GLOBAL_VIMRC"
}

# ----------------------------- 卸载 ------------------------------------------
remove_source_block() {
  local f="$1"
  [ -r "$f" ] || return 0
  grep -qF "$MARK_BEGIN" "$f" 2>/dev/null || return 0
  backup_file "$f"
  if [ "$DRY_RUN" -eq 1 ]; then dry "从 $f 移除引用块"; return 0; fi

  local tmp; tmp="$(mktemp 2>/dev/null || echo "/tmp/.setup_vimrc.$$")"
  # 1) 删掉整个引用块；2) 去掉因此残留的尾部空行（GNU/BSD/BusyBox sed 通用写法）
  if ! sed "\|${MARK_BEGIN}|,\|${MARK_END}|d" "$f" 2>/dev/null \
       | sed -e :a -e '/^[[:space:]]*$/{$d;N;ba' -e '}' > "$tmp" 2>/dev/null; then
    warn "处理 $f 失败，未改动"; rm -f "$tmp" 2>/dev/null || true; return 0
  fi
  if ! cat "$tmp" > "$f" 2>/dev/null; then
    warn "写回 $f 失败（只读挂载？），未改动"; rm -f "$tmp" 2>/dev/null || true; return 0
  fi
  rm -f "$tmp" 2>/dev/null || true        # 保留原 inode 与权限
  ok "已移除引用块：$f"
  return 0
}

uninstall_all() {
  step "卸载：移除本脚本所做的全部改动"

  local f
  for f in "$SYSTEM_VIMRC" /etc/vim/vimrc /etc/vimrc /usr/share/vim/vimrc "${VIM_HOME:-/nonexistent}/vimrc" "$NVIM_SYSINIT"; do
    case "$f" in ""|/nonexistent/*|*vimrc.tiny) continue ;; esac
    if [ -n "$f" ]; then remove_source_block "$f"; fi
  done

  if [ -L "$SKEL_DIR/.vimrc" ]; then
    run rm -f "$SKEL_DIR/.vimrc" || true; ok "已移除 $SKEL_DIR/.vimrc"
  fi

  if [ "$ALL_USERS" -eq 1 ]; then
    local pwlist uname _pw uid _gid _gecos home shell
    pwlist="$(read_passwd_list)"
    if [ -z "$pwlist" ]; then warn "无法读取用户列表，跳过"; return 0; fi
    while IFS=: read -r uname _pw uid _gid _gecos home shell; do
      case "${uid:-x}" in *[!0-9]*) continue ;; esac
      case "${home:-}" in ""|/) continue ;; esac
      [ -L "$home/.vimrc" ] && [ "$(readlink "$home/.vimrc")" = "$GLOBAL_VIMRC" ] || continue
      run rm -f "$home/.vimrc" || true; ok "已移除 $home/.vimrc"
    done <<< "$pwlist"
  else
    info "提示：已存在用户的 ~/.vimrc 软链未被处理，如需一并清理请加 --uninstall --all-users"
  fi

  if [ -e "$GLOBAL_VIMRC" ]; then
    backup_file "$GLOBAL_VIMRC"
    run rm -f "$GLOBAL_VIMRC" || true; ok "已移除 $GLOBAL_VIMRC"
  fi

  ok "卸载完成。备份目录：$BACKUP_DIR"
}

# ----------------------------- 汇总 ------------------------------------------
summary() {
  step "完成"
  printf '  发行版      : %s (%s / family=%s)\n' "$OS_PRETTY" "$OS_ID" "$OS_FAMILY"
  printf '  vim         : %s  版本 %s  %s\n' "$VIM_BIN" "${VIM_VERSION:-?}" \
         "$([ "$VIM_FULL" -eq 1 ] && echo '[完整版]' || echo '[精简版]')"
  printf '  配置正文    : %s\n' "$GLOBAL_VIMRC"
  printf '  已注入引用  : %s\n' "${PATCHED_FILES[*]:-<无>}"
  printf '  已跳过      : %s\n' "${SKIPPED_FILES[*]:-<无>}"
  printf '  备份目录    : %s\n' "$BACKUP_DIR"
  printf '\n%s生效范围%s\n' "$C_B" "$C_RST"
  printf '  · 立即      : 所有用户下次打开 vim 时生效（已在用的 vim 需重开）\n'
  printf '  · 新用户    : 自动继承（来自 %s/.vimrc）\n' "$SKEL_DIR"
  if [ "$ALL_USERS" -eq 1 ]; then
    printf '  · 已有用户  : 已创建 ~/.vimrc 软链（%d 个）\n' "$USER_LINKS"
  else
    printf '  · 已有用户  : 未创建个人 ~/.vimrc（全局 system vimrc 已注入，同样生效）\n'
  fi
  printf '\n%s自检%s\n' "$C_B" "$C_RST"
  printf '  vim -c "echo &number &cursorline" -c q\n'
  printf '  在 vim 内执行 :set ft?  可确认后缀识别结果\n'
}

# ----------------------------- 主流程 ----------------------------------------
main() {
  parse_args "$@"
  printf '%s\n' "=================================================================="
  printf '  setup_vimrc.sh v%s  ——  跨发行版通用 Vim 配置部署\n' "$SCRIPT_VERSION"
  printf '%s\n' "=================================================================="
  require_root "$@"
  detect_os
  detect_vim

  if [ "$DO_UNINSTALL" -eq 1 ]; then
    uninstall_all
    exit 0
  fi

  install_global
  install_skel
  if [ "$ALL_USERS" -eq 1 ]; then install_all_users; fi
  if [ "$WITH_NVIM" -eq 1 ]; then install_nvim; fi
  verify
  summary
  return 0
}

main "$@"


# =============================================================================
#  面板声明（供 panel.sh 自动发现，不参与脚本执行）
# =============================================================================
# PANEL: vim 配置 | Shell 环境 | 1 | 全用户通用 vim 配置
# PANEL-CMD: 安装（全局 + 新用户） |  | 写入 /etc/vim/vimrc.local + /etc/skel
# PANEL-CMD: 覆盖已存在的用户 | --all-users | 含 root 在内的所有已有用户
# PANEL-CMD: 额外配置 Neovim | --nvim | 写入系统级 sysinit.vim
# PANEL-CMD: 卸载脚本所做改动 | --uninstall | 还原所有备份
