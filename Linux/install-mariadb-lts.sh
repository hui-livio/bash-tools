#!/usr/bin/env bash
# =============================================================================
#  install-mariadb-lts.sh — MariaDB LTS 交互式安装与初始化脚本
#  Version: 1.2.0
#
#  功能一览
#    1. 自动识别发行版：Debian/Ubuntu/Deepin/UOS/银河麒麟(apt)、
#       RHEL/CentOS/Rocky/Alma/Fedora/AmazonLinux/openEuler/Anolis(dnf|yum)、
#       openSUSE/SLES(zypper)、Arch/Manjaro(pacman)
#    2. 可选从 MariaDB 官方仓库安装指定 LTS 系列（12.3 / 11.8 / 11.4 / 10.11）
#    3. 交互式设置 root 密码（手动输入 / 自动生成强密码 / 命令行直传）
#    4. 一键开启 root 远程访问，可限定来源网段或 IP，并自动放行本机防火墙
#    5. 可选创建业务数据库与业务账号（权限仅限该库）
#    6. 安装后自检：版本、监听地址、账号清单、连接示例、应急重置指引
#
#  用法
#    sudo bash install-mariadb-lts.sh                    # 全交互向导（推荐）
#    sudo bash install-mariadb-lts.sh --help
#    sudo bash install-mariadb-lts.sh -y --series 12.3 --root-pass 'Xxx!12345' \
#         --remote-root yes --remote-host '10.0.0.%' --open-firewall yes \
#         --firewall-source 10.0.0.0/24
#
#  安全设计要点
#    · 密码只经临时文件（0600）传给客户端，绝不出现在命令行参数或进程列表
#    · 本地 root 默认保留 unix_socket 与密码双认证，避免把自己锁在库外
#    · -y 只自动确认"是否继续"，不会自动开启远程 root 等高风险功能（须显式给参数）
#    · 仅"重新配置"模式不会动数据目录；安装前会提示备份 /var/lib/mysql
#
#  说明
#    · 需要 root 权限；脚本可重复执行（已安装时会询问是"仅重新配置"还是继续安装）
#    · 全部输出写入 /var/log/install-mariadb-lts.log
#    · 被覆盖的配置备份到 /var/backups/mariadb-install/
# =============================================================================

set -Eeuo pipefail

SCRIPT_NAME="${0##*/}"
SCRIPT_VERSION="1.2.0"
LOG_FILE="/var/log/install-mariadb-lts.log"
BACKUP_DIR="/var/backups/mariadb-install"
REPO_SETUP_URL="https://r.mariadb.com/downloads/mariadb_repo_setup"
MYCNF_PATH="/root/.my.cnf"

# ---------------------------------------------------------------------------
# 默认值 / 全局配置
# ---------------------------------------------------------------------------
SERIES="12.3"                 # 12.3 | 11.8 | 11.4 | 10.11
REPO_SOURCE="official"        # official（MariaDB 官方仓库）| distro（系统自带仓库）
ARCH_PKG="mariadb-lts"        # 仅 Arch Linux 生效：mariadb-lts（LTS）| mariadb（最新稳定）
PORT="3306"
BIND_ADDRESS=""               # 留空则按"是否开启远程"自动决定

NON_INTERACTIVE="no"
ASSUME_YES="no"
DRY_RUN="no"
AUTO_PASSWORD="no"
RECONFIGURE_ONLY="no"

START_NOW="yes";              # 安装后是否立即启动服务
START_NOW_EXPLICIT="no"
AUTOSTART="yes";              # 是否注册为系统服务并开机自启（systemctl enable）
AUTOSTART_EXPLICIT="no"
SERVICE_ONLY="no"             # 仅调整服务的启动/自启状态后退出

ROOT_PASSWORD=""
KEEP_SOCKET="yes"             # 本地 root 是否同时保留 unix_socket 免密登录
REMOTE_ROOT="no"
REMOTE_ROOT_HOST="%"
REMOTE_ROOT_SAME_PASS="yes"
REMOTE_ROOT_PASSWORD=""
REMOTE_ROOT_EXPLICIT="no"
WRITE_MYCNF="no"

CREATE_APP_DB="no"
APP_DB_NAME=""
APP_DB_USER=""
APP_DB_PASSWORD=""
APP_DB_HOST="%"

OPEN_FIREWALL="no"
FIREWALL_SOURCE=""
OPEN_FIREWALL_EXPLICIT="no"

ADMIN_PASSWORD=""             # 当前用于管理连接的 root 密码；为空则走 socket
ADMIN_AUTH_MODE="socket"      # socket | password
SQL_CLIENT=""

OS_ID="unknown"
OS_FAMILY="unknown"
OS_VERSION=""
OS_PRETTY=""
PKG=""
ARCH=""
SERVICE_NAME="mariadb"
SERVICE_EXISTS="no"
CONF_DROPIN=""
INSTALLED="no"

TMP_FILES=()

# ---------------------------------------------------------------------------
# 输出 / 日志
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_RED=$'\033[31m'
  C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_BLUE=$'\033[36m'; C_DIM=$'\033[2m'
else
  C_RESET=""; C_BOLD=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_DIM=""
fi

_log_raw() { printf '[%s] %s\n' "$(date '+%F %T')" "$*" 2>/dev/null >>"$LOG_FILE" || true; }

log()  { printf '%s\n' "$*"; _log_raw "$*"; }
info() { printf '%s\n' "${C_BLUE}[信息]${C_RESET} $*"; _log_raw "[INFO] $*"; }
ok()   { printf '%s\n' "${C_GREEN}[成功]${C_RESET} $*"; _log_raw "[OK] $*"; }
warn() { printf '%s\n' "${C_YELLOW}[警告]${C_RESET} $*" >&2; _log_raw "[WARN] $*"; }
err()  { printf '%s\n' "${C_RED}[错误]${C_RESET} $*" >&2; _log_raw "[ERR] $*"; }

die() { err "$*"; exit 1; }

step() {
  printf '\n%s\n' "${C_BOLD}==> $*${C_RESET}"
  _log_raw "=== $* ==="
}

on_error() {
  local line="$1" code="$2"
  # 只在主 shell 报错：命令替换等子 shell 会因 set -E 继承本陷阱，避免同一条错误被打印多次
  if [[ "${BASHPID:-$$}" != "$$" ]]; then return 0; fi
  err "脚本第 ${line} 行执行失败（退出码 ${code}）"
  err "详细日志：${LOG_FILE}"
  err "排查顺序：1) 网络与仓库可达性  2) ${LOG_FILE}  3) systemctl status ${SERVICE_NAME}"
  exit "$code"
}
trap 'on_error "$LINENO" "$?"' ERR

LOCK_FILE="/var/lock/install-mariadb-lts.lock"

cleanup() {
  local f
  for f in "${TMP_FILES[@]:-}"; do
    if [[ -n "$f" && -f "$f" ]]; then rm -f "$f"; fi
  done
  rm -f "$LOCK_FILE" 2>/dev/null || true
  return 0
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# 工具函数
# ---------------------------------------------------------------------------
usage() {
  cat <<EOF
${C_BOLD}${SCRIPT_NAME} v${SCRIPT_VERSION}${C_RESET} — MariaDB LTS 交互式安装与初始化

支持的发行版：
  Debian / Ubuntu / Deepin / UOS / 银河麒麟（apt）
  RHEL / CentOS / Rocky / AlmaLinux / Oracle Linux / Fedora / Amazon Linux / openEuler / Anolis（dnf|yum）
  openSUSE / SLES（zypper）
  Arch Linux / Manjaro（pacman，安装 mariadb-lts 或 mariadb）
  说明：Arch 不在 MariaDB 官方仓库支持范围内，脚本会自动改用 pacman；
        Arch 的数据目录由脚本执行 mariadb-install-db 初始化。

用法：
  sudo bash ${SCRIPT_NAME} [选项]

安装选项：
  --series <12.3|11.8|11.4|10.11>    MariaDB LTS 系列，默认 12.3（Arch 不适用）
  --repo <official|distro>           安装源，默认 official（官方仓库）
  --arch-pkg <mariadb-lts|mariadb>   Arch 专用：装 LTS 包还是最新稳定包，默认 mariadb-lts
  --port <3306>                      监听端口，默认 3306
  --bind <地址>                      强制指定 bind-address（如 0.0.0.0 / 10.0.0.5）

root 账号选项：
  --root-pass <密码>                 直接指定 root 密码（跳过交互询问）
  --auto-pass                        自动生成高强度 root 密码
  --no-keep-socket                   不保留 unix_socket，本地 root 也强制走密码
  --write-mycnf                      把 root 密码写入 ${MYCNF_PATH}（0600）便于本机免密

远程访问选项：
  --remote-root <yes|no>             是否开启 root 远程访问，默认 no
  --remote-host <%|10.0.0.%|1.2.3.4> 远程 root 允许来源，默认 %
  --remote-pass <密码>               远程 root 单独密码；不填则与本地 root 一致
  --open-firewall <yes|no>           是否放行本机防火墙端口，默认 no
  --firewall-source <网段>           防火墙放行来源，如 10.0.0.0/24；留空为任意来源

系统服务选项：
  --start-now <yes|no>               安装后是否立即启动服务，默认 yes
  --autostart <yes|no>               是否注册为系统服务并开机自启，默认 yes
  --no-autostart                     等同 --autostart no
  --service-only                     只调整服务的启动/自启状态后退出（不装不配库）

业务库选项：
  --db <库名>                        创建业务数据库（utf8mb4）
  --db-user <用户名>                 业务账号名，默认 <库名>_user
  --db-pass <密码>                   业务账号密码
  --db-host <host>                   业务账号来源，默认 %

其他：
  -y, --yes                          自动确认"是否继续"类询问（不会自动开启远程 root）
  -n, --non-interactive              非交互模式，未指定项取默认值（密码自动生成）
      --dry-run                      只打印将要执行的操作，不做任何变更
  -h, --help                         显示本帮助

常用示例：
  # 全交互（推荐）
  sudo bash ${SCRIPT_NAME}

  # 静默安装 12.3、设置 root 密码、开放远程 root（限内网网段）并放行防火墙
  sudo bash ${SCRIPT_NAME} -y --series 12.3 --root-pass 'Str0ng!Pass' \\
       --remote-root yes --remote-host '10.0.0.%' \\
       --open-firewall yes --firewall-source 10.0.0.0/24

  # 仅查看会做什么
  sudo bash ${SCRIPT_NAME} --dry-run

  # 安装但不设开机自启（临时测试机常用）
  sudo bash ${SCRIPT_NAME} -y --root-pass 'Str0ng!Pass' --no-autostart

  # 已安装环境：只切换开机自启状态，不碰数据库
  sudo bash ${SCRIPT_NAME} --service-only --autostart no
EOF
}

run() {  # 所有产生变更的命令都经由此函数，便于 --dry-run 预览
  if [[ "$DRY_RUN" == "yes" ]]; then
    printf '%s\n' "${C_DIM}[dry-run] $*${C_RESET}"
    return 0
  fi
  _log_raw "[CMD] $*"
  "$@"
}

need_cmd() { command -v "$1" >/dev/null 2>&1 && return 0 || return 1; }

# systemctl is-active/enabled 会自己输出状态（inactive/disabled 等）并返回非 0，
# 因此只能"取输出、忽略退出码"，既不能再用 || echo unknown（会多一行），也不能 || s=""（会把状态清空）
svc_is_active() {
  local s=""
  s="$(systemctl is-active "$1" 2>/dev/null)" || true
  if [[ -z "$s" ]]; then s="unknown"; fi
  printf '%s' "$s"
  return 0
}

svc_is_enabled() {
  local s=""
  s="$(systemctl is-enabled "$1" 2>/dev/null)" || true
  if [[ -z "$s" ]]; then s="unknown"; fi
  printf '%s' "$s"
  return 0
}

first_ip() {  # 取本机第一个可用 IPv4；兼容不支持 -I 的 hostname（inetutils）
  local out="" ip=""
  if out="$(hostname -I 2>/dev/null)"; then ip="${out%% *}"; fi
  if [[ -z "$ip" ]] && need_cmd ip; then
    # 用 awk NR==1 取首行，避免 head 提前退出引发 SIGPIPE（pipefail 下会让整条管道非 0）
    out="$(ip -4 -o addr show scope global 2>/dev/null | awk 'NR==1{print $4}')" || out=""
    ip="${out%%/*}"
  fi
  if [[ -z "$ip" ]] && need_cmd hostname; then
    out="$(hostname 2>/dev/null)" || out=""
    ip="$out"
  fi
  if [[ -z "$ip" ]]; then ip="<服务器IP>"; fi
  printf '%s' "$ip"
  return 0
}

mktemp_tracked() {
  local f
  f="$(mktemp)"
  chmod 600 "$f"
  TMP_FILES+=("$f")
  printf '%s' "$f"
}

retrim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

cnf_escape() { local s="$1"; s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; printf '%s' "$s"; }   # option 文件转义
sql_escape() { local s="$1"; s="${s//\'/\'\'}"; printf '%s' "$s"; }                     # SQL 字面量转义

disp_width() {  # 估算显示宽度：ASCII=1，非 ASCII（UTF-8 三字节，如中文）按 2 计
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

item() {  # item <标签> <值> [缩进] [列宽] —— 按显示宽度对齐，避免中文错位
  local label="$1" value="$2" indent="${3:-2}" width="${4:-20}"
  local w pad
  w="$(disp_width "$label")"
  pad=$(( width - w ))
  if [[ $pad -lt 1 ]]; then pad=1; fi
  printf '%*s%s%*s%s\n' "$indent" "" "$label" "$pad" "" "$value"
}

# ---------------------------------------------------------------------------
# 交互原语
#     prompt        —— 带默认值的文本输入
#     ask_yes_no    —— "是否继续"类确认，受 -y 影响
#     ask_feature   —— 功能开关（远程 root / 建库 / 防火墙等），不受 -y 影响，更安全
#     confirm_typed —— 危险操作需逐字输入确认词
# ---------------------------------------------------------------------------
prompt() {  # prompt <变量名> <提示语> [默认值]
  local __var="$1" __label="$2" __default="${3:-}" __answer=""
  if [[ "$NON_INTERACTIVE" == "yes" ]]; then
    printf -v "$__var" '%s' "$__default"
    return 0
  fi
  if [[ -n "$__default" ]]; then
    read -r -e -i "$__default" -p "$(printf '%s [%s]: ' "$__label" "$__default")" __answer || true
  else
    read -r -p "$(printf '%s: ' "$__label")" __answer || true
  fi
  if [[ -z "$__answer" ]]; then __answer="$__default"; fi
  printf -v "$__var" '%s' "$(retrim "$__answer")"
  return 0
}

ask_yes_no() {  # ask_yes_no <提示语> <y|n> —— 受 -y 影响
  local label="$1" def="${2:-n}" ans="" hint
  if [[ "$ASSUME_YES" == "yes" ]]; then return 0; fi
  if [[ "$NON_INTERACTIVE" == "yes" ]]; then
    if [[ "$def" == y* ]]; then return 0; else return 1; fi
  fi
  if [[ "$def" == y* ]]; then hint="Y/n"; else hint="y/N"; fi
  while true; do
    read -r -p "$(printf '%s [%s]: ' "$label" "$hint")" ans || true
    if [[ -z "$ans" ]]; then ans="$def"; fi
    case "${ans,,}" in
      y|yes|是) return 0 ;;
      n|no|否)  return 1 ;;
      *) warn "请输入 y 或 n" ;;
    esac
  done
}

ask_feature() {  # ask_feature <提示语> <y|n> —— 不受 -y 影响
  local label="$1" def="${2:-n}" ans="" hint
  if [[ "$NON_INTERACTIVE" == "yes" ]]; then
    if [[ "$def" == y* ]]; then return 0; else return 1; fi
  fi
  if [[ "$def" == y* ]]; then hint="Y/n"; else hint="y/N"; fi
  while true; do
    read -r -p "$(printf '%s [%s]: ' "$label" "$hint")" ans || true
    if [[ -z "$ans" ]]; then ans="$def"; fi
    case "${ans,,}" in
      y|yes|是) return 0 ;;
      n|no|否)  return 1 ;;
      *) warn "请输入 y 或 n" ;;
    esac
  done
}

confirm_typed() {  # confirm_typed <提示语> <确认词> —— 不受 -y 影响
  local label="$1" phrase="$2" ans=""
  if [[ "$NON_INTERACTIVE" == "yes" ]]; then return 0; fi
  read -r -p "$(printf '%s（输入 %s 继续）: ' "$label" "$phrase")" ans || true
  if [[ "$ans" == "$phrase" ]]; then return 0; else return 1; fi
}

generate_password() {
  # 刻意不用 "… | head -c 20" 收尾：上游会被 SIGPIPE 打断，pipefail 下整条管道可能非 0
  local raw="" pw=""
  if need_cmd openssl; then
    raw="$(openssl rand -base64 48 2>/dev/null)" || raw=""
    if [[ -n "$raw" ]]; then
      pw="$(printf '%s' "$raw" | tr -dc 'A-Za-z0-9!@%^*_+=')" || pw=""
    fi
  fi
  if [[ -z "$pw" && -r /dev/urandom ]]; then
    raw="$(head -c 256 /dev/urandom 2>/dev/null | base64)" || raw=""
    if [[ -n "$raw" ]]; then
      pw="$(printf '%s' "$raw" | tr -dc 'A-Za-z0-9')" || pw=""
    fi
  fi
  pw="${pw:0:20}"
  if [[ -z "$pw" ]]; then pw="MbLts$(date +%s)"; fi
  printf '%s' "$pw"
  return 0
}

password_strength_note() {
  local pw="$1" note=""
  if [[ ${#pw} -lt 12 ]]; then note="${note}长度偏短(建议>=12)；"; fi
  if [[ ! "$pw" =~ [0-9] ]]; then note="${note}无数字；"; fi
  if [[ ! "$pw" =~ [A-Za-z] ]]; then note="${note}无字母；"; fi
  if [[ ! "$pw" =~ [^A-Za-z0-9] ]]; then note="${note}无特殊字符；"; fi
  if [[ -n "$note" ]]; then warn "密码强度提示：${note}（仅提示，不强制）"; fi
  return 0
}

prompt_password() {  # prompt_password <变量名> <提示语> [已有值]
  local __var="$1" __label="$2" __cur="${3:-}" __p1="" __p2=""
  if [[ "$NON_INTERACTIVE" == "yes" ]]; then
    if [[ -z "$__cur" ]]; then __cur="$(generate_password)"; fi
    printf -v "$__var" '%s' "$__cur"
    return 0
  fi
  if [[ "$AUTO_PASSWORD" == "yes" ]]; then
    __cur="$(generate_password)"
    printf -v "$__var" '%s' "$__cur"
    printf '%s\n' "${C_GREEN}[成功]${C_RESET} 已自动生成密码：${C_BOLD}${__cur}${C_RESET}"
    return 0
  fi
  if [[ -n "$__cur" ]]; then
    printf -v "$__var" '%s' "$__cur"
    return 0
  fi
  while true; do
    read -r -s -p "$(printf '%s: ' "$__label")" __p1 || true
    printf '\n'
    if [[ ${#__p1} -lt 8 ]]; then warn "密码至少 8 位，请重试"; continue; fi
    read -r -s -p "请再次输入确认: " __p2 || true
    printf '\n'
    if [[ "$__p1" != "$__p2" ]]; then warn "两次输入不一致，请重试"; continue; fi
    password_strength_note "$__p1"
    break
  done
  printf -v "$__var" '%s' "$__p1"
  return 0
}

prompt_port() {
  prompt PORT "数据库监听端口" "$PORT"
  case "$PORT" in
    ''|*[!0-9]*) die "端口必须是数字" ;;
  esac
  return 0
}

# ---------------------------------------------------------------------------
# 参数解析
# ---------------------------------------------------------------------------
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --series)          SERIES="${2:?--series 需要值}"; shift 2 ;;
      --repo)            REPO_SOURCE="${2:?--repo 需要值}"; shift 2 ;;
      --arch-pkg)        ARCH_PKG="${2:?--arch-pkg 需要值}"; shift 2 ;;
      --port)            PORT="${2:?--port 需要值}"; shift 2 ;;
      --bind)            BIND_ADDRESS="${2:?--bind 需要值}"; shift 2 ;;
      --root-pass)       ROOT_PASSWORD="${2:?--root-pass 需要值}"; shift 2 ;;
      --admin-pass)      ADMIN_PASSWORD="${2:?--admin-pass 需要值}"; shift 2 ;;
      --remote-root)     if [[ "${2:-no}" == y* ]]; then REMOTE_ROOT="yes"; else REMOTE_ROOT="no"; fi; REMOTE_ROOT_EXPLICIT="yes"; shift 2 ;;
      --remote-host)     REMOTE_ROOT_HOST="${2:?--remote-host 需要值}"; REMOTE_ROOT_EXPLICIT="yes"; shift 2 ;;
      --remote-pass)     REMOTE_ROOT_PASSWORD="${2:?--remote-pass 需要值}"; REMOTE_ROOT_SAME_PASS="no"; shift 2 ;;
      --open-firewall)   if [[ "${2:-no}" == y* ]]; then OPEN_FIREWALL="yes"; else OPEN_FIREWALL="no"; fi; OPEN_FIREWALL_EXPLICIT="yes"; shift 2 ;;
      --firewall-source) FIREWALL_SOURCE="${2:-}"; shift 2 ;;
      --db)              APP_DB_NAME="${2:?--db 需要值}"; CREATE_APP_DB="yes"; shift 2 ;;
      --db-user)         APP_DB_USER="${2:?--db-user 需要值}"; CREATE_APP_DB="yes"; shift 2 ;;
      --db-pass)         APP_DB_PASSWORD="${2:?--db-pass 需要值}"; shift 2 ;;
      --db-host)         APP_DB_HOST="${2:?--db-host 需要值}"; shift 2 ;;
      --auto-pass)       AUTO_PASSWORD="yes"; shift ;;
      --start-now)       if [[ "${2:-yes}" == y* ]]; then START_NOW="yes"; else START_NOW="no"; fi; START_NOW_EXPLICIT="yes"; shift 2 ;;
      --autostart)       if [[ "${2:-yes}" == y* ]]; then AUTOSTART="yes"; else AUTOSTART="no"; fi; AUTOSTART_EXPLICIT="yes"; shift 2 ;;
      --no-autostart)    AUTOSTART="no"; AUTOSTART_EXPLICIT="yes"; shift ;;
      --service-only)    SERVICE_ONLY="yes"; shift ;;
      --no-keep-socket)  KEEP_SOCKET="no"; shift ;;
      --write-mycnf)     WRITE_MYCNF="yes"; shift ;;
      -y|--yes)          ASSUME_YES="yes"; shift ;;
      -n|--non-interactive) NON_INTERACTIVE="yes"; ASSUME_YES="yes"; shift ;;
      --dry-run)         DRY_RUN="yes"; shift ;;
      -h|--help)         usage; exit 0 ;;
      *) die "未知参数：$1（用 --help 查看用法）" ;;
    esac
  done

  case "$SERIES" in
    12.3|11.8|11.4|10.11) : ;;
    *) die "--series 仅支持 12.3 / 11.8 / 11.4 / 10.11（当前维护中的 LTS 系列）" ;;
  esac
  case "$REPO_SOURCE" in
    official|distro) : ;;
    *) die "--repo 仅支持 official 或 distro" ;;
  esac
  case "$ARCH_PKG" in
    mariadb-lts|mariadb) : ;;
    *) die "--arch-pkg 仅支持 mariadb-lts 或 mariadb" ;;
  esac
  case "$PORT" in
    ''|*[!0-9]*) die "端口必须是数字" ;;
  esac
  if [[ "$CREATE_APP_DB" == "yes" ]]; then
    if [[ -z "$APP_DB_NAME" ]]; then die "--db 已指定但数据库名为空"; fi
    if [[ -z "$APP_DB_USER" ]]; then APP_DB_USER="${APP_DB_NAME}_user"; fi
  fi
}

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    die "请以 root 身份运行：sudo bash ${SCRIPT_NAME}"
  fi
}

# ---------------------------------------------------------------------------
# 系统识别
# ---------------------------------------------------------------------------
detect_os() {
  step "识别操作系统"
  if [[ ! -r /etc/os-release ]]; then die "找不到 /etc/os-release，无法识别发行版"; fi
  # shellcheck disable=SC1091
  . /etc/os-release
  OS_ID="${ID:-unknown}"
  OS_VERSION="${VERSION_ID:-}"
  OS_PRETTY="${PRETTY_NAME:-$OS_ID $OS_VERSION}"
  local like=" ${ID_LIKE:-} ${OS_ID} "

  if [[ "$like" == *" debian "* || "$like" == *" ubuntu "* ]]; then
    OS_FAMILY="debian"
  elif [[ "$like" == *" rhel "* || "$like" == *" fedora "* || "$like" == *" centos "* \
      || "$like" == *" amzn "* || "$like" == *" openEuler "* || "$like" == *" anolis "* \
      || "$like" == *" kylin "* || "$like" == *" uos "* ]]; then
    OS_FAMILY="rhel"
  elif [[ "$like" == *" suse "* || "$like" == *" opensuse "* ]]; then
    OS_FAMILY="suse"
  elif [[ "$like" == *" arch "* ]]; then
    OS_FAMILY="arch"
  elif need_cmd apt-get; then
    OS_FAMILY="debian"
  elif need_cmd dnf || need_cmd yum; then
    OS_FAMILY="rhel"
  elif need_cmd zypper; then
    OS_FAMILY="suse"
  elif need_cmd pacman; then
    OS_FAMILY="arch"
  else
    die "暂不支持的发行版：${OS_PRETTY}"
  fi

  case "$OS_FAMILY" in
    debian) PKG="apt" ;;
    rhel)   if need_cmd dnf; then PKG="dnf"; else PKG="yum"; fi ;;
    suse)   PKG="zypper" ;;
    arch)   PKG="pacman" ;;
  esac

  ARCH="$(uname -m)"
  info "发行版：${OS_PRETTY}（family=${OS_FAMILY}, 包管理器=${PKG}, 架构=${ARCH}）"

  case "$ARCH" in
    x86_64|amd64|aarch64|arm64) : ;;
    *) warn "架构 ${ARCH} 可能不在 MariaDB 官方仓库支持范围内；若仓库配置失败请改用 --repo distro" ;;
  esac
  return 0
}

install_prereqs() {
  step "安装基础依赖（curl / gnupg / ca-certificates）"
  case "$OS_FAMILY" in
    debian)
      run apt-get update -qq
      run env DEBIAN_FRONTEND=noninteractive apt-get install -y curl gnupg ca-certificates
      ;;
    rhel)
      run "$PKG" install -y curl gnupg2 ca-certificates
      ;;
    suse)
      run zypper -n install curl gpg2 ca-certificates
      ;;
    arch)
      run pacman -Sy --noconfirm --needed curl gnupg ca-certificates
      ;;
  esac
  return 0
}

mariadb_installed() {
  if need_cmd mariadbd || need_cmd mysqld || [[ -d /var/lib/mysql ]]; then
    INSTALLED="yes"
  else
    INSTALLED="no"
  fi
  return 0
}

detect_service_name() {
  if systemctl list-unit-files 2>/dev/null | grep -q '^mariadb\.service'; then
    SERVICE_NAME="mariadb"; SERVICE_EXISTS="yes"
  elif systemctl list-unit-files 2>/dev/null | grep -q '^mysql\.service'; then
    SERVICE_NAME="mysql"; SERVICE_EXISTS="yes"
  else
    SERVICE_NAME="mariadb"; SERVICE_EXISTS="no"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# 仓库与安装
# ---------------------------------------------------------------------------
add_official_repo() {
  step "配置 MariaDB 官方仓库（series=${SERIES}）"
  local setup
  setup="$(mktemp_tracked)"
  run curl -fsSL "$REPO_SETUP_URL" -o "$setup"
  if [[ "$DRY_RUN" == "yes" ]]; then
    printf '%s\n' "${C_DIM}[dry-run] bash mariadb_repo_setup --mariadb-server-version=mariadb-${SERIES} --skip-maxscale${C_RESET}"
    return 0
  fi
  if bash "$setup" --mariadb-server-version="mariadb-${SERIES}" --skip-maxscale; then
    ok "MariaDB 官方仓库已配置"
    return 0
  fi
  warn "官方仓库配置失败（该发行版/版本可能已超出 MariaDB 支持范围）"
  if [[ "$NON_INTERACTIVE" == "yes" ]]; then
    die "请改用 --repo distro 安装系统仓库版本"
  fi
  if ask_yes_no "是否改用系统自带仓库安装（版本可能偏旧）？" y; then
    REPO_SOURCE="distro"
    return 0
  fi
  die "已取消"
}

install_packages() {
  step "安装 MariaDB Server / Client（安装源：${REPO_SOURCE}）"
  if [[ "$OS_FAMILY" == "rhel" && "$REPO_SOURCE" == "official" && "$PKG" == "dnf" ]]; then
    # RHEL8/9 自带 mariadb/mysql 模块会干扰官方仓库，先禁用
    run "$PKG" module disable mariadb -y || true
    run "$PKG" module disable mysql -y || true
  fi

  case "$OS_FAMILY:$REPO_SOURCE" in
    debian:official|debian:distro)
      run apt-get update -qq
      run env DEBIAN_FRONTEND=noninteractive apt-get install -y mariadb-server mariadb-client
      ;;
    rhel:official)
      run "$PKG" install -y MariaDB-server MariaDB-client
      ;;
    rhel:distro)
      run "$PKG" install -y mariadb-server mariadb
      ;;
    suse:official|suse:distro)
      run zypper -n install mariadb mariadb-client
      ;;
    arch:official|arch:distro)
      # Arch 不走官方仓库脚本，直接用 pacman 安装 LTS 包
      run pacman -Sy --noconfirm --needed "$ARCH_PKG"
      if [[ "$DRY_RUN" != "yes" ]] && ! need_cmd mariadb; then
        run pacman -S --noconfirm --needed mariadb-clients || warn "未找到 mariadb-clients 包；若客户端缺失请手动安装"
      fi
      ;;
  esac
  ok "MariaDB 软件包安装完成"
  return 0
}

ensure_datadir_initialized() {
  # Arch 的 mariadb 包不会自动初始化数据目录，必须先执行 mariadb-install-db
  if [[ "$OS_FAMILY" != "arch" ]]; then return 0; fi
  local dd="/var/lib/mysql"
  if [[ -d "$dd" && -n "$(ls -A "$dd" 2>/dev/null)" ]]; then
    info "数据目录已存在且非空，跳过初始化"
    return 0
  fi
  if [[ "$DRY_RUN" == "yes" ]]; then
    printf '%s\n' "${C_DIM}[dry-run] mariadb-install-db --user=mysql --basedir=/usr --datadir=${dd}${C_RESET}"
    return 0
  fi
  if ! need_cmd mariadb-install-db; then
    warn "未找到 mariadb-install-db，请手动初始化：mariadb-install-db --user=mysql --basedir=/usr --datadir=${dd}"
    return 0
  fi
  step "初始化数据目录（Arch 需手动初始化）"
  mariadb-install-db --user=mysql --basedir=/usr --datadir="$dd"
  ok "数据目录已初始化"
  return 0
}

apply_service_state() {  # 按 START_NOW / AUTOSTART 配置 systemd 服务
  detect_service_name
  if [[ "$AUTOSTART" == "yes" ]]; then
    run systemctl enable "$SERVICE_NAME"
    ok "已设置开机自启：systemctl enable ${SERVICE_NAME}"
  else
    run systemctl disable "$SERVICE_NAME" 2>/dev/null || true
    info "已关闭开机自启：systemctl disable ${SERVICE_NAME}"
  fi
  if [[ "$START_NOW" == "yes" ]]; then
    run systemctl start "$SERVICE_NAME"
    info "已启动服务：systemctl start ${SERVICE_NAME}"
  else
    info "按选择未启动服务，稍后可执行：sudo systemctl start ${SERVICE_NAME}"
  fi
  return 0
}

service_status_line() {
  printf '运行=%s  开机自启=%s' "$(svc_is_active "$SERVICE_NAME")" "$(svc_is_enabled "$SERVICE_NAME")"
  return 0
}

start_service() {
  step "启动服务并配置开机自启"
  apply_service_state
  if [[ "$DRY_RUN" == "yes" ]]; then return 0; fi

  SQL_CLIENT="$(command -v mariadb || command -v mysql || true)"
  if [[ -z "$SQL_CLIENT" ]]; then die "未找到 mariadb/mysql 客户端命令"; fi
  if [[ "$START_NOW" != "yes" ]]; then return 0; fi

  sleep 2
  if systemctl is-active --quiet "$SERVICE_NAME"; then
    ok "服务 ${SERVICE_NAME} 正在运行"
  else
    err "服务 ${SERVICE_NAME} 启动失败，最近日志："
    journalctl -u "$SERVICE_NAME" -n 30 --no-pager >&2 || true
    die "请排查数据目录权限或磁盘空间后重试"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# SQL 执行（密码仅通过 0600 临时文件传递）
# ---------------------------------------------------------------------------
write_client_cnf() {  # write_client_cnf <密码> [host] [port] → 输出临时 cnf 路径
  local pw="$1" host="${2:-}" port="${3:-}" f
  f="$(mktemp_tracked)"
  {
    printf '[client]\n'
    printf 'user=root\n'
    printf 'password="%s"\n' "$(cnf_escape "$pw")"
    if [[ -n "$host" ]]; then printf 'host=%s\n' "$host"; fi
    if [[ -n "$port" ]]; then printf 'port=%s\n' "$port"; fi
  } >"$f"
  printf '%s' "$f"
}

sql_run_file() {  # sql_run_file <sql文件> [quiet]
  local sql_file="$1" quiet="${2:-no}" rc=0 cnf=""
  if [[ "$ADMIN_AUTH_MODE" == "password" ]]; then
    cnf="$(write_client_cnf "$ADMIN_PASSWORD")"
    if [[ "$quiet" == "yes" ]]; then
      "$SQL_CLIENT" --defaults-extra-file="$cnf" <"$sql_file" >/dev/null 2>&1 || rc=$?
    else
      "$SQL_CLIENT" --defaults-extra-file="$cnf" <"$sql_file" || rc=$?
    fi
  else
    if [[ "$quiet" == "yes" ]]; then
      "$SQL_CLIENT" --protocol=socket -u root <"$sql_file" >/dev/null 2>&1 || rc=$?
    else
      "$SQL_CLIENT" --protocol=socket -u root <"$sql_file" || rc=$?
    fi
  fi
  if [[ -n "$cnf" ]]; then rm -f "$cnf"; fi
  return $rc
}

sql_apply() {  # sql_apply <sql字符串> → 返回执行码
  local f rc=0
  f="$(mktemp_tracked)"
  printf '%s\n' "$1" >"$f"
  sql_run_file "$f" || rc=$?
  rm -f "$f"
  return $rc
}

sql_query() {  # sql_query <sql字符串> → stdout（失败只返回码，不中断）
  local f cnf="" out="" rc=0
  f="$(mktemp_tracked)"
  printf '%s\n' "$1" >"$f"
  if [[ "$ADMIN_AUTH_MODE" == "password" ]]; then
    cnf="$(write_client_cnf "$ADMIN_PASSWORD")"
    out="$("$SQL_CLIENT" --defaults-extra-file="$cnf" -B -N <"$f" 2>&1)" || rc=$?
  else
    out="$("$SQL_CLIENT" --protocol=socket -u root -B -N <"$f" 2>&1)" || rc=$?
  fi
  if [[ -n "$cnf" ]]; then rm -f "$cnf"; fi
  rm -f "$f"
  printf '%s\n' "$out"
  return $rc
}

test_root_password() {  # 用密码通过 socket 登录 root
  local pw="$1" cnf rc=0
  cnf="$(write_client_cnf "$pw")"
  "$SQL_CLIENT" --defaults-extra-file="$cnf" --protocol=socket -e 'SELECT 1' >/dev/null 2>&1 || rc=$?
  rm -f "$cnf"
  return $rc
}

test_tcp_login() {  # test_tcp_login <密码> <host> <port>
  local pw="$1" host="$2" port="$3" cnf rc=0
  cnf="$(write_client_cnf "$pw" "$host" "$port")"
  "$SQL_CLIENT" --defaults-extra-file="$cnf" --protocol=tcp -e 'SELECT 1' >/dev/null 2>&1 || rc=$?
  rm -f "$cnf"
  return $rc
}

detect_root_auth() {
  if [[ -z "$SQL_CLIENT" ]]; then SQL_CLIENT="$(command -v mariadb || command -v mysql || true)"; fi
  if [[ -z "$SQL_CLIENT" ]]; then die "未找到 mariadb/mysql 客户端命令"; fi

  if "$SQL_CLIENT" --protocol=socket -u root -e 'SELECT 1' >/dev/null 2>&1; then
    ADMIN_AUTH_MODE="socket"; ADMIN_PASSWORD=""
    ok "本地 root 可通过 unix_socket 免密登录"
    return 0
  fi

  warn "无法通过 unix_socket 免密登录 root，需要提供现有 root 密码"
  if [[ -n "$ADMIN_PASSWORD" ]]; then
    if test_root_password "$ADMIN_PASSWORD"; then
      ADMIN_AUTH_MODE="password"
      ok "使用 --admin-pass 提供的密码登录成功"
      return 0
    fi
    die "--admin-pass 提供的密码校验失败"
  fi

  if [[ "$NON_INTERACTIVE" == "yes" ]]; then
    die "请用 --admin-pass 提供现有 root 密码"
  fi

  local i pw
  for i in 1 2 3; do
    read -r -s -p "请输入当前 root 密码（第 ${i}/3 次）: " pw || true
    printf '\n'
    if test_root_password "$pw"; then
      ADMIN_PASSWORD="$pw"; ADMIN_AUTH_MODE="password"
      ok "登录成功"
      return 0
    fi
    warn "密码不正确"
  done
  die "连续 3 次登录失败；可参考脚本输出的 skip-grant-tables 应急重置流程"
}

# ---------------------------------------------------------------------------
# 交互向导
# ---------------------------------------------------------------------------
wizard_install_options() {
  step "第 1 步 / 安装选项"

  # ---- Arch Linux：没有官方仓库，用 pacman 装，可选 LTS 包 ----
  if [[ "$OS_FAMILY" == "arch" ]]; then
    REPO_SOURCE="distro"
    if [[ "$NON_INTERACTIVE" != "yes" ]]; then
      cat <<'EOF'
Arch Linux 通过官方仓库（pacman）安装，可选择两个包：
  1) mariadb-lts —— LTS 分支（11.4 系列），长期稳定              【推荐】
  2) mariadb     —— 最新稳定分支，版本更新但变更更频繁
EOF
      local achoice
      prompt achoice "输入序号（回车=1）" "1"
      case "$achoice" in
        2) ARCH_PKG="mariadb" ;;
        *) ARCH_PKG="mariadb-lts" ;;
      esac
      prompt_port
    fi
    info "软件包=${ARCH_PKG}  安装源=distro(pacman)  端口=${PORT}"
    return 0
  fi

  # ---- Debian / RHEL / SUSE：可选官方仓库与 LTS 系列 ----
  if [[ "$NON_INTERACTIVE" != "yes" ]]; then
    cat <<'EOF'
请选择要安装的 MariaDB LTS 系列（截至 2026-09 仍在维护的版本）：
  1) 12.3   —— 最新 LTS，2026-05 GA，社区维护至 2029          【推荐】
  2) 11.8   —— LTS，社区维护至 2028
  3) 11.4   —— LTS，社区维护至 2029（生态成熟、案例最多）
  4) 10.11  —— LTS，社区维护至 2028（兼容老系统/老应用）
  5) 10.6   —— 已于 2026-07-06 EOL，不建议新部署
EOF
    local choice
    prompt choice "输入序号（回车=1）" "1"
    case "$choice" in
      2) SERIES="11.8" ;;
      3) SERIES="11.4" ;;
      4) SERIES="10.11" ;;
      5) SERIES="10.6"; warn "10.6 已 EOL，新部署请优先选择 12.3 / 11.8" ;;
      *) SERIES="12.3" ;;
    esac

    if ask_feature "使用 MariaDB 官方仓库安装（版本新、可控）？选 n 用系统自带仓库" y; then
      REPO_SOURCE="official"
    else
      REPO_SOURCE="distro"
    fi

    prompt_port
  fi
  info "系列=${SERIES}  安装源=${REPO_SOURCE}  端口=${PORT}"
  return 0
}

wizard_security_options() {
  step "第 2 步 / root 密码与远程访问"

  if [[ -z "$ROOT_PASSWORD" ]]; then
    if [[ "$NON_INTERACTIVE" != "yes" && "$AUTO_PASSWORD" != "yes" ]]; then
      if ask_feature "是否自动生成一个高强度 root 密码？" n; then AUTO_PASSWORD="yes"; fi
    fi
    prompt_password ROOT_PASSWORD "请设置 root 密码（至少 8 位，输入不回显）"
  else
    info "已通过命令行指定 root 密码"
  fi

  if [[ "$NON_INTERACTIVE" != "yes" ]]; then
    if ask_feature "本地 root 同时保留 unix_socket 免密登录（sudo mariadb 直接进入，防止自锁）？" y; then
      KEEP_SOCKET="yes"
    else
      KEEP_SOCKET="no"
    fi
  fi

  if [[ "$REMOTE_ROOT_EXPLICIT" != "yes" ]]; then
    if ask_feature "是否开启 root 远程访问？" n; then
      REMOTE_ROOT="yes"
    else
      REMOTE_ROOT="no"
    fi
  fi

  if [[ "$REMOTE_ROOT" == "yes" ]]; then
    printf '%s\n' "${C_RED}${C_BOLD}"
    cat <<'EOF'
  ⚠️  安全提醒：开放 root 远程访问会显著扩大攻击面。
      · 生产环境更推荐创建受限运维账号，仅在必要时开放 root
      · 请务必限定来源（具体 IP 或内网网段），并同步收敛云安全组规则
      · 条件允许时建议后续启用 TLS 加密连接
EOF
    printf '%s\n' "${C_RESET}"

    prompt REMOTE_ROOT_HOST "允许远程 root 的来源（% = 任意主机，或 10.0.0.% / 1.2.3.4）" "$REMOTE_ROOT_HOST"
    if [[ -z "$REMOTE_ROOT_HOST" ]]; then REMOTE_ROOT_HOST="%"; fi
    if [[ "$REMOTE_ROOT_HOST" == "%" ]]; then
      warn "你选择了任意主机（%）来源，请确认已有网络层防护"
      if [[ "$NON_INTERACTIVE" != "yes" ]]; then
        if ! confirm_typed "继续将放开全部来源" "YES"; then die "已取消"; fi
      fi
    fi

    if [[ "$REMOTE_ROOT_SAME_PASS" == "yes" && "$NON_INTERACTIVE" != "yes" ]]; then
      if ask_feature "远程 root 使用与本地 root 相同的密码？" y; then
        REMOTE_ROOT_SAME_PASS="yes"
      else
        REMOTE_ROOT_SAME_PASS="no"
      fi
    fi
    if [[ "$REMOTE_ROOT_SAME_PASS" == "yes" ]]; then
      REMOTE_ROOT_PASSWORD="$ROOT_PASSWORD"
    else
      prompt_password REMOTE_ROOT_PASSWORD "请设置远程 root 专用密码"
    fi
  fi

  if [[ "$NON_INTERACTIVE" != "yes" ]]; then
    if ask_feature "把 root 密码写入 ${MYCNF_PATH}（0600）方便本机免密运维？" n; then
      WRITE_MYCNF="yes"
    else
      WRITE_MYCNF="no"
    fi
  fi
  return 0
}

wizard_app_db() {
  step "第 3 步 / 业务库与账号（可全部跳过）"
  if [[ "$CREATE_APP_DB" != "yes" ]]; then
    if [[ "$NON_INTERACTIVE" == "yes" ]]; then return 0; fi
    if ask_feature "是否顺便创建业务数据库与业务账号？" n; then
      CREATE_APP_DB="yes"
    else
      return 0
    fi
  fi
  prompt APP_DB_NAME "业务数据库名（字符集 utf8mb4）" "$APP_DB_NAME"
  if [[ -z "$APP_DB_NAME" ]]; then die "数据库名不能为空"; fi
  if [[ -z "$APP_DB_USER" ]]; then APP_DB_USER="${APP_DB_NAME}_user"; fi
  prompt APP_DB_USER "业务账号名" "$APP_DB_USER"
  prompt APP_DB_HOST "业务账号允许来源（%/10.0.0.%/localhost）" "$APP_DB_HOST"
  prompt_password APP_DB_PASSWORD "请设置业务账号密码"
  return 0
}

wizard_service_and_firewall() {
  step "第 4 步 / 服务、开机自启与防火墙"
  detect_service_name

  if [[ "$START_NOW_EXPLICIT" != "yes" && "$NON_INTERACTIVE" != "yes" ]]; then
    if ask_feature "安装完成后立即启动 ${SERVICE_NAME} 服务？" y; then
      START_NOW="yes"
    else
      START_NOW="no"
    fi
  fi

  if [[ "$AUTOSTART_EXPLICIT" != "yes" && "$NON_INTERACTIVE" != "yes" ]]; then
    if ask_feature "注册为系统服务并设置开机自启（systemctl enable）？" y; then
      AUTOSTART="yes"
    else
      AUTOSTART="no"
    fi
  fi

  if [[ "$START_NOW" == "yes" ]]; then
    info "启动服务：安装后立即启动"
  else
    warn "启动服务：不立即启动（root 密码 / 远程账号 / 业务库的初始化会被跳过）"
  fi
  if [[ "$AUTOSTART" == "yes" ]]; then
    info "开机自启：开启（systemctl enable ${SERVICE_NAME}）"
  else
    info "开机自启：关闭（之后可用 sudo systemctl enable ${SERVICE_NAME} 重新开启）"
  fi

  if [[ "$OPEN_FIREWALL_EXPLICIT" != "yes" ]]; then
    if [[ "$NON_INTERACTIVE" == "yes" ]]; then return 0; fi
    local def="n"
    if [[ "$REMOTE_ROOT" == "yes" || "$CREATE_APP_DB" == "yes" ]]; then def="y"; fi
    if ask_feature "是否自动放行本机防火墙的 ${PORT}/tcp 端口？" "$def"; then
      OPEN_FIREWALL="yes"
    else
      OPEN_FIREWALL="no"
      return 0
    fi
  fi
  if [[ "$OPEN_FIREWALL" == "yes" && -z "$FIREWALL_SOURCE" && "$NON_INTERACTIVE" != "yes" ]]; then
    prompt FIREWALL_SOURCE "放行来源（留空 = 任意来源，或填 10.0.0.0/24）" ""
  fi
  return 0
}

show_plan() {
  step "执行计划确认"
  local bind="127.0.0.1（仅本机）"
  local socket_state db_state remote_state fw_state mycnf_state
  if [[ -n "$BIND_ADDRESS" ]]; then
    bind="$BIND_ADDRESS"
  elif [[ "$REMOTE_ROOT" == "yes" || "$CREATE_APP_DB" == "yes" ]]; then
    bind="0.0.0.0（监听全部网卡）"
  fi
  if [[ "$KEEP_SOCKET" == "yes" ]]; then socket_state="是"; else socket_state="否"; fi
  if [[ "$REMOTE_ROOT" == "yes" ]]; then remote_state="开启（来源 ${REMOTE_ROOT_HOST}）"; else remote_state="关闭"; fi
  if [[ "$CREATE_APP_DB" == "yes" ]]; then db_state="${APP_DB_NAME} / ${APP_DB_USER}@${APP_DB_HOST}"; else db_state="跳过"; fi
  if [[ "$OPEN_FIREWALL" == "yes" ]]; then fw_state="${PORT}/tcp ${FIREWALL_SOURCE:-任意来源}"; else fw_state="否"; fi
  if [[ "$WRITE_MYCNF" == "yes" ]]; then mycnf_state="写入"; else mycnf_state="不写入"; fi

  local start_state auto_state root_state
  if [[ "$START_NOW" == "yes" ]]; then start_state="安装后立即启动"; else start_state="不启动"; fi
  if [[ "$AUTOSTART" == "yes" ]]; then auto_state="开启（systemctl enable ${SERVICE_NAME}）"; else auto_state="关闭"; fi
  if [[ -n "$ROOT_PASSWORD" ]]; then root_state="已设置（不回显）"; else root_state="保持现状"; fi

  printf '%s\n' "${C_BOLD}即将执行的操作：${C_RESET}"
  item "操作系统"       "${OS_PRETTY} (${ARCH})" 2 22
  if [[ "$OS_FAMILY" == "arch" ]]; then
    item "安装源/软件包" "distro(pacman) / ${ARCH_PKG}" 2 22
  else
    item "安装源/系列"   "${REPO_SOURCE} / MariaDB ${SERIES}" 2 22
  fi
  item "监听端口"       "${PORT}" 2 22
  item "监听地址"       "${bind}" 2 22
  item "启动服务"       "$start_state" 2 22
  item "开机自启"       "$auto_state" 2 22
  item "root 密码"      "$root_state" 2 22
  item "保留 socket 登录" "$socket_state" 2 22
  item "root 远程访问"  "$remote_state" 2 22
  item "业务库"         "$db_state" 2 22
  item "放行防火墙"     "$fw_state" 2 22
  item "${MYCNF_PATH}"  "$mycnf_state" 2 22
  item "日志"           "$LOG_FILE" 2 22
  return 0
}

pause_for_confirm() {
  if [[ "$DRY_RUN" == "yes" ]]; then info "dry-run 模式：不做任何变更"; return 0; fi
  if [[ "$ASSUME_YES" == "yes" || "$NON_INTERACTIVE" == "yes" ]]; then return 0; fi
  if ! ask_yes_no "确认按以上计划执行？" y; then die "已取消，未做任何变更"; fi
  return 0
}

# ---------------------------------------------------------------------------
# 服务端配置
# ---------------------------------------------------------------------------
find_conf_dir() {
  local d
  for d in /etc/mysql/mariadb.conf.d /etc/mysql/conf.d /etc/my.cnf.d; do
    if [[ -d "$d" ]]; then printf '%s' "$d"; return 0; fi
  done
  printf ''
  return 0
}

configure_server_conf() {
  step "写入服务端配置"
  local dir; dir="$(find_conf_dir)"
  mkdir -p "$BACKUP_DIR"

  local want_bind="127.0.0.1"
  if [[ -n "$BIND_ADDRESS" ]]; then
    want_bind="$BIND_ADDRESS"
  elif [[ "$REMOTE_ROOT" == "yes" ]]; then
    want_bind="0.0.0.0"
  elif [[ "$CREATE_APP_DB" == "yes" && "$APP_DB_HOST" != "localhost" ]]; then
    want_bind="0.0.0.0"
  fi

  local conf="# Managed by ${SCRIPT_NAME} v${SCRIPT_VERSION} — $(date '+%F %T')
[mysqld]
bind-address = ${want_bind}
port = ${PORT}
"

  if [[ -n "$dir" ]]; then
    CONF_DROPIN="${dir}/99-mariadb-lts-managed.cnf"
    if [[ -f "$CONF_DROPIN" ]]; then
      run cp -a "$CONF_DROPIN" "${BACKUP_DIR}/99-mariadb-lts-managed.cnf.$(date +%Y%m%d%H%M%S)"
    fi
    if [[ "$DRY_RUN" == "yes" ]]; then
      printf '%s\n%s' "${C_DIM}[dry-run] 将写入 ${CONF_DROPIN}：${C_RESET}" "$conf"
    else
      printf '%s' "$conf" >"$CONF_DROPIN"
      chmod 644 "$CONF_DROPIN"
      ok "已写入 ${CONF_DROPIN}"
    fi
  else
    CONF_DROPIN="/etc/my.cnf"
    if grep -qi 'bind-address' /etc/my.cnf 2>/dev/null; then
      warn "/etc/my.cnf 已存在 bind-address 配置，请手动确认是否需要改为 ${want_bind}"
    else
      run cp -a /etc/my.cnf "${BACKUP_DIR}/my.cnf.$(date +%Y%m%d%H%M%S)" || true
      if [[ "$DRY_RUN" == "yes" ]]; then
        printf '%s\n%s' "${C_DIM}[dry-run] 将追加到 /etc/my.cnf：${C_RESET}" "$conf"
      else
        printf '\n%s\n' "$conf" >>/etc/my.cnf
        ok "已追加配置到 /etc/my.cnf"
      fi
    fi
  fi

  # skip-networking 会直接让远程访问失效，这里统一注释掉
  local f
  for f in /etc/my.cnf /etc/mysql/my.cnf; do
    if [[ ! -f "$f" ]]; then continue; fi
    if grep -qiE '^[[:space:]]*skip-networking' "$f"; then
      warn "${f} 中启用了 skip-networking，会禁用 TCP 监听"
      if [[ "$DRY_RUN" != "yes" ]]; then
        run cp -a "$f" "${BACKUP_DIR}/$(basename "$f").$(date +%Y%m%d%H%M%S)"
        sed -i -E 's/^([[:space:]]*)(skip-networking.*)$/\1# \2  # disabled by install-mariadb-lts.sh/' "$f"
        ok "已注释 ${f} 中的 skip-networking"
      fi
    fi
  done

  if [[ -n "$dir" ]]; then
    for f in "$dir"/*.cnf; do
      if [[ ! -f "$f" ]]; then continue; fi
      if grep -qiE '^[[:space:]]*skip-networking' "$f"; then
        warn "${f} 中启用了 skip-networking，会禁用 TCP 监听"
        if [[ "$DRY_RUN" != "yes" ]]; then
          run cp -a "$f" "${BACKUP_DIR}/$(basename "$f").$(date +%Y%m%d%H%M%S)"
          sed -i -E 's/^([[:space:]]*)(skip-networking.*)$/\1# \2  # disabled by install-mariadb-lts.sh/' "$f"
          ok "已注释 ${f} 中的 skip-networking"
        fi
      fi
    done
  fi
  return 0
}

restart_service() {
  detect_service_name
  if [[ "$DRY_RUN" == "yes" ]]; then
    printf '%s\n' "${C_DIM}[dry-run] systemctl restart ${SERVICE_NAME}${C_RESET}"
    return 0
  fi
  step "重启服务使配置生效"
  systemctl restart "$SERVICE_NAME"
  sleep 2
  if ! systemctl is-active --quiet "$SERVICE_NAME"; then
    journalctl -u "$SERVICE_NAME" -n 30 --no-pager >&2 || true
    die "服务重启失败，请检查配置：${CONF_DROPIN:-/etc/my.cnf}"
  fi
  ok "配置已生效"
  return 0
}

# ---------------------------------------------------------------------------
# 账号与安全加固
# ---------------------------------------------------------------------------
harden_and_create_users() {
  step "清理默认不安全项（匿名账号 / test 库）"
  sql_apply "DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
FLUSH PRIVILEGES;" >/dev/null 2>&1 || warn "清理 test 库时出现非致命错误（通常可忽略）"

  sql_apply "DROP USER IF EXISTS ''@'localhost';
DROP USER IF EXISTS ''@'$(hostname 2>/dev/null || echo localhost)';
FLUSH PRIVILEGES;" >/dev/null 2>&1 || true
  ok "匿名账号与 test 库已处理"

  set_root_password
  if [[ "$REMOTE_ROOT" == "yes" ]]; then set_remote_root; fi
  if [[ "$CREATE_APP_DB" == "yes" ]]; then create_app_database; fi
  sql_apply "FLUSH PRIVILEGES;" >/dev/null 2>&1 || true

  if [[ "$WRITE_MYCNF" == "yes" ]]; then
    if [[ "$DRY_RUN" == "yes" ]]; then
      printf '%s\n' "${C_DIM}[dry-run] 写入 ${MYCNF_PATH}（权限 0600）${C_RESET}"
    else
      if [[ -f "$MYCNF_PATH" ]]; then
        cp -a "$MYCNF_PATH" "${BACKUP_DIR}/root-my.cnf.$(date +%Y%m%d%H%M%S)"
      fi
      umask 077
      {
        printf '[client]\n'
        printf 'user=root\n'
        printf 'password="%s"\n' "$(cnf_escape "$ROOT_PASSWORD")"
      } >"$MYCNF_PATH"
      chmod 600 "$MYCNF_PATH"
      ok "已写入 ${MYCNF_PATH}（权限 600）"
    fi
  fi
  return 0
}

set_root_password() {
  step "设置 root 本地密码"
  if [[ -z "$ROOT_PASSWORD" ]]; then
    warn "未提供 root 密码，跳过"
    return 0
  fi
  if [[ "$DRY_RUN" == "yes" ]]; then
    printf '%s\n' "${C_DIM}[dry-run] ALTER USER 'root'@'localhost' 设置密码${C_RESET}"
    return 0
  fi

  local pw_sql; pw_sql="$(sql_escape "$ROOT_PASSWORD")"
  local done_ok="no"

  if [[ "$KEEP_SOCKET" == "yes" ]]; then
    # MariaDB 支持多插件并用：socket 免密 + 密码同时可用，避免把自己锁在库外
    if sql_apply "ALTER USER 'root'@'localhost' IDENTIFIED VIA unix_socket OR mysql_native_password USING PASSWORD('${pw_sql}');
FLUSH PRIVILEGES;" >/dev/null 2>&1; then
      done_ok="yes"
    fi
  fi

  if [[ "$done_ok" == "no" ]]; then
    if sql_apply "ALTER USER 'root'@'localhost' IDENTIFIED BY '${pw_sql}';
FLUSH PRIVILEGES;" >/dev/null 2>&1; then
      done_ok="yes"
      if [[ "$KEEP_SOCKET" == "yes" ]]; then
        warn "该环境不支持 socket+密码双认证，本地 root 已切换为纯密码认证"
      fi
    elif sql_apply "CREATE USER IF NOT EXISTS 'root'@'localhost' IDENTIFIED BY '${pw_sql}';
ALTER USER 'root'@'localhost' IDENTIFIED BY '${pw_sql}';
GRANT ALL PRIVILEGES ON *.* TO 'root'@'localhost' WITH GRANT OPTION;
FLUSH PRIVILEGES;" >/dev/null 2>&1; then
      done_ok="yes"
    fi
  fi

  if [[ "$done_ok" != "yes" ]]; then
    die "root 密码设置失败，请查看 ${LOG_FILE}"
  fi

  if test_tcp_login "$ROOT_PASSWORD" "127.0.0.1" "$PORT" || test_root_password "$ROOT_PASSWORD"; then
    ADMIN_PASSWORD="$ROOT_PASSWORD"; ADMIN_AUTH_MODE="password"
    ok "root 密码已生效并通过验证"
  else
    warn "密码已写入但验证未通过，后续操作沿用原管理通道，请手动复核"
  fi

  cat <<EOF

  若后续无法登录 root，可按以下步骤应急重置：
    1) systemctl stop ${SERVICE_NAME}
    2) mariadbd --skip-grant-tables --skip-networking &
    3) mariadb -e "FLUSH PRIVILEGES; ALTER USER 'root'@'localhost' IDENTIFIED BY '新密码';"
    4) kill 掉临时进程后 systemctl start ${SERVICE_NAME}
EOF
  return 0
}

set_remote_root() {
  step "开启 root 远程访问（来源：${REMOTE_ROOT_HOST}）"
  if [[ -z "$REMOTE_ROOT_PASSWORD" ]]; then REMOTE_ROOT_PASSWORD="$ROOT_PASSWORD"; fi
  if [[ -z "$REMOTE_ROOT_PASSWORD" ]]; then die "远程 root 密码为空"; fi

  local pw_sql host_sql
  pw_sql="$(sql_escape "$REMOTE_ROOT_PASSWORD")"
  host_sql="$(sql_escape "$REMOTE_ROOT_HOST")"

  if [[ "$DRY_RUN" == "yes" ]]; then
    printf '%s\n' "${C_DIM}[dry-run] CREATE USER 'root'@'${REMOTE_ROOT_HOST}' + GRANT ALL ... WITH GRANT OPTION${C_RESET}"
    return 0
  fi

  sql_apply "CREATE USER IF NOT EXISTS 'root'@'${host_sql}' IDENTIFIED BY '${pw_sql}';
ALTER USER 'root'@'${host_sql}' IDENTIFIED BY '${pw_sql}';
GRANT ALL PRIVILEGES ON *.* TO 'root'@'${host_sql}' WITH GRANT OPTION;
FLUSH PRIVILEGES;" >/dev/null 2>&1 || die "创建远程 root 账号失败"

  ok "已创建 root@'${REMOTE_ROOT_HOST}' 并授予全部权限（含 GRANT OPTION）"
  warn "远程 root 攻击面较大，建议后续改用受限运维账号或启用 TLS"
  return 0
}

create_app_database() {
  step "创建业务库与业务账号"
  local db_sql user_sql host_sql pw_sql
  db_sql="$(sql_escape "$APP_DB_NAME")"
  user_sql="$(sql_escape "$APP_DB_USER")"
  host_sql="$(sql_escape "$APP_DB_HOST")"
  pw_sql="$(sql_escape "$APP_DB_PASSWORD")"

  if [[ "$DRY_RUN" == "yes" ]]; then
    printf '%s\n' "${C_DIM}[dry-run] CREATE DATABASE ${APP_DB_NAME}; CREATE USER '${APP_DB_USER}'@'${APP_DB_HOST}'${C_RESET}"
    return 0
  fi

  sql_apply "CREATE DATABASE IF NOT EXISTS \`${db_sql}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${user_sql}'@'${host_sql}' IDENTIFIED BY '${pw_sql}';
ALTER USER '${user_sql}'@'${host_sql}' IDENTIFIED BY '${pw_sql}';
GRANT ALL PRIVILEGES ON \`${db_sql}\`.* TO '${user_sql}'@'${host_sql}';
FLUSH PRIVILEGES;" >/dev/null 2>&1 || die "创建业务库/账号失败"

  ok "业务库 ${APP_DB_NAME} 与账号 ${APP_DB_USER}@${APP_DB_HOST} 已创建（权限仅限本库）"
  return 0
}

# ---------------------------------------------------------------------------
# 防火墙
# ---------------------------------------------------------------------------
configure_firewall() {
  if [[ "$OPEN_FIREWALL" != "yes" ]]; then return 0; fi
  step "放行防火墙端口 ${PORT}/tcp"
  local src="${FIREWALL_SOURCE:-}" did="no"

  if need_cmd firewall-cmd && systemctl is-active --quiet firewalld; then
    if [[ -n "$src" ]]; then
      run firewall-cmd --permanent --add-rich-rule="rule family=\"ipv4\" source address=\"${src}\" port port=\"${PORT}\" protocol=\"tcp\" accept"
    else
      run firewall-cmd --permanent --add-port="${PORT}/tcp"
    fi
    run firewall-cmd --reload
    did="yes"
  fi

  if need_cmd ufw && ufw status 2>/dev/null | grep -qi '^Status: active'; then
    if [[ -n "$src" ]]; then
      run ufw allow from "$src" to any port "$PORT" proto tcp
    else
      run ufw allow "${PORT}/tcp"
    fi
    did="yes"
  fi

  if [[ "$did" == "no" ]]; then
    warn "未检测到运行中的 firewalld / ufw；请自行确认 iptables/nftables 与云厂商安全组已放行 ${PORT}/tcp"
  else
    ok "防火墙规则已更新"
  fi

  if need_cmd getenforce; then
    if [[ "$(getenforce 2>/dev/null)" == "Enforcing" ]]; then
      info "SELinux 处于 Enforcing；如需 Web 服务连库可执行：setsebool -P httpd_can_network_connect_db on"
    fi
  fi
  return 0
}

# ---------------------------------------------------------------------------
# 自检与总结
# ---------------------------------------------------------------------------
verify() {
  step "安装自检"
  if [[ "$DRY_RUN" == "yes" ]]; then info "dry-run 模式，跳过自检"; return 0; fi
  if [[ "$START_NOW" != "yes" ]]; then
    info "服务未启动，跳过数据库层自检"
    ok "服务状态：$(service_status_line)"
    return 0
  fi

  local ver=""
  ver="$(sql_query "SELECT VERSION();" 2>/dev/null | tr -d '\r' | tail -n1)" || ver=""
  if [[ -z "$ver" ]]; then ver="未知（无法查询服务端版本，请检查 root 认证）"; fi
  ok "服务端版本：${ver}"
  ok "服务状态：运行=$(svc_is_active "$SERVICE_NAME")  开机自启=$(svc_is_enabled "$SERVICE_NAME")"

  printf '%s\n' "${C_BOLD}监听情况：${C_RESET}"
  if ss -lntp 2>/dev/null | grep -q ":${PORT} "; then
    ss -lntp 2>/dev/null | grep ":${PORT} " || true
  else
    warn "未在监听列表中看到端口 ${PORT}，请检查 bind-address / skip-networking 配置"
  fi

  printf '%s\n' "${C_BOLD}账号清单：${C_RESET}"
  local extra=""
  if [[ "$CREATE_APP_DB" == "yes" ]]; then extra=", '$(sql_escape "$APP_DB_USER")'"; fi
  sql_query "SELECT CONCAT(User,'@',Host) AS account, plugin FROM mysql.user WHERE User IN ('root'${extra}) ORDER BY 1;" | tr -d '\r' || true

  if [[ "$REMOTE_ROOT" == "yes" ]]; then
    printf '%s\n' "${C_BOLD}root 远程授权：${C_RESET}"
    sql_query "SHOW GRANTS FOR 'root'@'$(sql_escape "$REMOTE_ROOT_HOST")';" | tr -d '\r' || true
    if test_tcp_login "$ROOT_PASSWORD" "127.0.0.1" "$PORT"; then
      ok "本机 TCP 回环连接测试通过（真实远程连通性需从另一台机器验证）"
    else
      warn "本机 TCP 回环连接测试未通过，请检查 bind-address 与防火墙"
    fi
  fi
  return 0
}

summary() {
  local ip="" svc_state
  ip="$(first_ip)"
  if [[ "$DRY_RUN" == "yes" ]]; then
    svc_state="（dry-run 未变更）"
  else
    svc_state="$(service_status_line)"
  fi
  printf '\n%s\n' "${C_BOLD}${C_GREEN}================ 安装完成 ================${C_RESET}"
  if [[ "$OS_FAMILY" == "arch" ]]; then
    item "MariaDB"  "${ARCH_PKG}（pacman 仓库）" 2 18
  else
    item "MariaDB"  "${SERIES} 系列" 2 18
  fi
  item "服务名"    "$SERVICE_NAME" 2 18
  item "服务状态"  "$svc_state" 2 18
  item "开机自启"  "$(if [[ "$AUTOSTART" == "yes" ]]; then printf '已开启'; else printf '已关闭'; fi)" 2 18
  item "配置文件"  "${CONF_DROPIN:-/etc/mysql 或 /etc/my.cnf.d}" 2 18
  item "日志"      "$LOG_FILE" 2 18
  item "备份目录"  "$BACKUP_DIR" 2 18

  if [[ -n "$ROOT_PASSWORD" && "$DRY_RUN" != "yes" ]]; then
    if [[ "$START_NOW" == "yes" ]]; then
      printf '\n%s\n' "${C_BOLD}凭据（请立即妥善保存，脚本不会二次输出）${C_RESET}"
    else
      printf '\n%s\n' "${C_YELLOW}${C_BOLD}以下为待生效的凭据（服务尚未启动，密码/账号还未写入数据库）${C_RESET}"
    fi
    item "root@localhost" "$ROOT_PASSWORD" 2 22
    if [[ "$REMOTE_ROOT" == "yes" ]]; then
      item "root@${REMOTE_ROOT_HOST}" "$REMOTE_ROOT_PASSWORD" 2 22
    fi
    if [[ "$CREATE_APP_DB" == "yes" ]]; then
      item "${APP_DB_USER}@${APP_DB_HOST}" "$APP_DB_PASSWORD" 2 22
    fi
  fi

  if [[ "$START_NOW" != "yes" && "$DRY_RUN" != "yes" ]]; then
    printf '\n%s\n' "${C_BOLD}下一步：完成账号初始化${C_RESET}"
    printf '  1) 启动服务        sudo systemctl start %s\n' "$SERVICE_NAME"
    printf '  2) 重新运行脚本    sudo bash %s\n' "$SCRIPT_NAME"
    printf '     %s\n' '在提示「是否仅执行配置…」时选择 y，即可完成 root 密码 / 远程访问 / 业务库的初始化'
  fi

  printf '\n%s\n' "${C_BOLD}常用命令${C_RESET}"
  if [[ "$KEEP_SOCKET" == "yes" ]]; then
    item "本地登录" "sudo mariadb            # unix_socket 免密" 2 14
  else
    item "本地登录" "mariadb -u root -p" 2 14
  fi
  item "密码登录" "mariadb -u root -p" 2 14
  if [[ "$CREATE_APP_DB" == "yes" ]]; then
    item "业务库连接" "mariadb -h 127.0.0.1 -P ${PORT} -u ${APP_DB_USER} -p ${APP_DB_NAME}" 2 14
  fi
  if [[ "$REMOTE_ROOT" == "yes" ]]; then
    item "远程连接" "mariadb -h ${ip:-<服务器IP>} -P ${PORT} -u root -p" 2 14
  fi
  item "启动服务" "sudo systemctl start ${SERVICE_NAME}" 2 14
  item "重启服务" "sudo systemctl restart ${SERVICE_NAME}" 2 14
  item "停止服务" "sudo systemctl stop ${SERVICE_NAME}" 2 14
  if [[ "$AUTOSTART" == "yes" ]]; then
    item "关闭自启" "sudo systemctl disable ${SERVICE_NAME}" 2 14
  else
    item "开启自启" "sudo systemctl enable ${SERVICE_NAME}" 2 14
  fi
  item "改自启"   "sudo bash ${SCRIPT_NAME} --service-only --autostart yes|no    # 用 yes 或 no 替换末尾" 2 14

  if [[ "$REMOTE_ROOT" == "yes" ]]; then
    printf '\n%s\n' "${C_YELLOW}${C_BOLD}务必确认：云服务器安全组 / 上游网络 ACL 已按来源收敛放行 ${PORT}，否则远程依旧不可达。${C_RESET}"
  fi
  printf '\n'
  return 0
}

# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------
main() {
  parse_args "$@"
  require_root
  mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
  if ! : >>"$LOG_FILE" 2>/dev/null; then LOG_FILE="/tmp/install-mariadb-lts.log"; fi

  printf '%s\n' "${C_BOLD}MariaDB LTS 安装脚本 v${SCRIPT_VERSION}${C_RESET}   |   日志：${LOG_FILE}"
  if [[ "$DRY_RUN" == "yes" ]]; then warn "dry-run 模式：仅打印操作，不做任何变更"; fi

  detect_os
  if [[ "$OS_FAMILY" == "arch" && "$REPO_SOURCE" == "official" ]]; then
    warn "Arch Linux 不在 MariaDB 官方仓库支持范围内，已自动切换为系统仓库（pacman）"
    REPO_SOURCE="distro"
  fi

  # 仅调整服务的启动/开机自启状态，不做其他任何变更
  if [[ "$SERVICE_ONLY" == "yes" ]]; then
    detect_service_name
    if [[ "$SERVICE_EXISTS" != "yes" ]]; then
      die "未找到 mariadb/mysql 的 systemd 单元，无法配置服务（可先执行安装）"
    fi
    step "仅配置服务启动与开机自启"
    apply_service_state
    if [[ "$DRY_RUN" != "yes" ]]; then
      ok "当前状态：$(service_status_line)"
      info "手动切换自启：sudo systemctl enable ${SERVICE_NAME} / sudo systemctl disable ${SERVICE_NAME}"
    fi
    return 0
  fi

  mariadb_installed
  if [[ "$INSTALLED" == "yes" ]]; then
    detect_service_name
    info "检测到本机已存在 MariaDB/MySQL 数据目录或服务"
    if [[ "$NON_INTERACTIVE" == "yes" ]]; then
      RECONFIGURE_ONLY="yes"
    elif ask_yes_no "是否仅执行配置（设置密码 / 开启远程访问），跳过安装？" y; then
      RECONFIGURE_ONLY="yes"
    else
      RECONFIGURE_ONLY="no"
      warn "将执行安装/升级流程；已有数据会保留，但强烈建议先备份 /var/lib/mysql"
    fi
  fi

  if [[ "$RECONFIGURE_ONLY" == "yes" ]]; then
    SQL_CLIENT="$(command -v mariadb || command -v mysql || true)"
    if [[ -z "$SQL_CLIENT" ]]; then die "已安装但找不到 mariadb/mysql 客户端命令"; fi
    detect_root_auth
    wizard_security_options
    wizard_app_db
    configure_server_conf
    # 仅在命令行显式指定时调整服务的启动/自启状态，避免误改现有配置
    if [[ "$START_NOW_EXPLICIT" == "yes" || "$AUTOSTART_EXPLICIT" == "yes" ]]; then
      apply_service_state
    fi
    restart_service
    harden_and_create_users
    configure_firewall
    verify
    summary
    return 0
  fi

  wizard_install_options
  wizard_security_options
  wizard_app_db
  wizard_service_and_firewall
  show_plan
  pause_for_confirm

  install_prereqs
  if [[ "$REPO_SOURCE" == "official" ]]; then add_official_repo; fi
  install_packages
  ensure_datadir_initialized
  start_service

  if [[ "$START_NOW" == "yes" ]]; then
    detect_root_auth
    configure_server_conf
    restart_service
    harden_and_create_users
  else
    configure_server_conf
    warn "服务未启动，已跳过 root 密码、远程账号与业务库的初始化"
    info "稍后完成初始化：sudo systemctl start ${SERVICE_NAME} 后重新运行本脚本并选择「仅重新配置」"
  fi
  configure_firewall
  verify
  summary
  return 0
}

main "$@"
