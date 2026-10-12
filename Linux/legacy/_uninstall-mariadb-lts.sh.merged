#!/usr/bin/env bash
# =============================================================================
#  uninstall-mariadb-lts.sh — MariaDB 卸载与残留清理（交互式）
#  Version: 1.1.0
#
#  支持的发行版
#    Debian / Ubuntu / Deepin / UOS / 银河麒麟（apt purge）
#    RHEL / CentOS / Rocky / Alma / Fedora / AmazonLinux / openEuler / Anolis（dnf|yum remove）
#    openSUSE / SLES（zypper remove）
#    Arch Linux / Manjaro（pacman -R，LTS 包 mariadb-lts 同样支持）
#
#  功能一览
#    1. 自动盘点本机已安装的 MariaDB：软件包、服务、数据目录、配置、日志、系统用户
#    2. 卸载前可选自动备份：逻辑全库导出（SQL）+ 数据目录物理打包（tar.gz）
#    3. 停止服务并取消开机自启（systemctl disable --now）
#    4. 卸载软件包（Debian/Ubuntu: apt purge；RHEL/CentOS: dnf|yum remove；
#       openSUSE/SLES: zypper remove；Arch/Manjaro: pacman -R）
#    5. 可选清理数据目录、配置、日志、官方仓库配置、/root/.my.cnf、mysql 系统用户
#    6. 卸载后残留复核，并打印数据恢复步骤
#
#  用法
#    sudo bash uninstall-mariadb-lts.sh                 # 全交互向导（推荐）
#    sudo bash uninstall-mariadb-lts.sh --help
#    sudo bash uninstall-mariadb-lts.sh -y --keep-data          # 卸软件、留数据（最常用）
#    sudo bash uninstall-mariadb-lts.sh -y --purge-data          # 连数据一起删（危险）
#
#  安全设计要点
#    · 默认【不删除】数据目录，只卸软件包；删数据必须显式选择并逐字输入 DELETE
#    · 删除数据前强制先备份（逻辑导出 + 数据目录打包），备份失败则中止删除
#    · 所有被删除的配置文件都会先复制到备份目录
#    · 全面支持 --dry-run 预览，--non-interactive 静默执行
# =============================================================================

set -Eeuo pipefail

SCRIPT_NAME="${0##*/}"
SCRIPT_VERSION="1.1.0"
LOG_FILE="/var/log/uninstall-mariadb-lts.log"
BACKUP_DIR="/var/backups/mariadb-uninstall"
DEFAULT_DATA_DIR="/var/lib/mysql"
MYCNF_PATH="/root/.my.cnf"

# ---------------------------------------------------------------------------
# 选项默认值
# ---------------------------------------------------------------------------
NON_INTERACTIVE="no"
ASSUME_YES="no"
DRY_RUN="no"

BACKUP="yes";            BACKUP_EXPLICIT="no"
PURGE_DATA="no";         PURGE_DATA_EXPLICIT="no"
REMOVE_CONFIG="yes";     REMOVE_CONFIG_EXPLICIT="no"
REMOVE_REPO="yes";       REMOVE_REPO_EXPLICIT="no"
REMOVE_MYCNF="yes";      REMOVE_MYCNF_EXPLICIT="no"
REMOVE_EXTRAS="no";      REMOVE_EXTRAS_EXPLICIT="no"
REMOVE_USER="follow"     # follow | yes | no

ADMIN_PASSWORD=""
ADMIN_AUTH_MODE="socket"
SQL_CLIENT=""
DUMP_CLIENT=""

# ---------------------------------------------------------------------------
# 运行时状态
# ---------------------------------------------------------------------------
OS_ID="unknown"
OS_FAMILY="unknown"
OS_PRETTY=""
PKG=""
SERVICE_NAME=""
SERVICE_EXISTS="no"
DATA_DIR=""
DATA_DIR_EXISTS="no"
DATA_SIZE=""
MARIADB_FOUND="no"

PKG_LIST=()         # 待卸载软件包
EXTRA_LIST=()       # 可选公共包 / 共享库
CONFIG_PATHS=()     # 待删除的配置与日志路径
REPO_PATHS=()       # 待删除的仓库配置
RUNTIME_PATHS=()    # 运行时残留（socket / pid / lock）
BACKUP_FILES=()     # 备份产物

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
info() { printf '%s\n' "${C_BLUE}[信息]${C_RESET} $*"; _log_raw "[INFO] $*"; }
ok()   { printf '%s\n' "${C_GREEN}[成功]${C_RESET} $*"; _log_raw "[OK] $*"; }
warn() { printf '%s\n' "${C_YELLOW}[警告]${C_RESET} $*" >&2; _log_raw "[WARN] $*"; }
err()  { printf '%s\n' "${C_RED}[错误]${C_RESET} $*" >&2; _log_raw "[ERR] $*"; }
die()  { err "$*"; exit 1; }

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
  err "排查顺序：1) 是否有进程占用文件  2) ${LOG_FILE}  3) systemctl status ${SERVICE_NAME:-mariadb}"
  exit "$code"
}
trap 'on_error "$LINENO" "$?"' ERR

cleanup() {
  local f
  for f in "${TMP_FILES[@]:-}"; do
    if [[ -n "$f" && -f "$f" ]]; then rm -f "$f"; fi
  done
  return 0
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# 工具函数
# ---------------------------------------------------------------------------
usage() {
  cat <<EOF
${C_BOLD}${SCRIPT_NAME} v${SCRIPT_VERSION}${C_RESET} — MariaDB 卸载与残留清理

支持的发行版：
  Debian / Ubuntu / Deepin / UOS / 银河麒麟（apt purge）
  RHEL / CentOS / Rocky / Alma / Fedora / AmazonLinux / openEuler / Anolis（dnf|yum remove）
  openSUSE / SLES（zypper remove）
  Arch Linux / Manjaro（pacman -R，含 mariadb-lts 包）

用法：
  sudo bash ${SCRIPT_NAME} [选项]

卸载范围：
  --keep-data                只卸软件包，保留数据目录（默认行为）
  --purge-data               同时删除数据目录（危险，需逐字确认）
  --purge-all                等同 --purge-data + 删配置 + 删仓库 + 删 .my.cnf + 删系统用户
  --keep-config              保留配置文件（默认删除，删除前会先备份）
  --keep-repo                保留 MariaDB 官方仓库配置（默认删除）
  --keep-mycnf               保留 /root/.my.cnf（默认删除）
  --remove-extras            同时移除公共包与共享库（Debian: mysql-common / libmariadb*；Arch: mariadb-libs）
  --keep-user                保留 mysql 系统用户/组（默认随数据目录一起处理）

备份选项：
  --no-backup                不自动备份（危险，仅当你已有备份时使用）
  --backup-dir <目录>        备份目录，默认 ${BACKUP_DIR}

连接选项（用于卸载前导出全库逻辑备份）：
  --admin-pass <密码>        当前 root 密码；不填则优先尝试 unix_socket 免密

其他：
  -y, --yes                  自动确认"是否继续"类询问（不会自动删数据）
  -n, --non-interactive      非交互模式，未指定项取默认值
      --dry-run              只打印将要执行的操作，不做任何变更
  -h, --help                 显示本帮助

常用示例：
  # 只卸载软件，保留数据（最常用、最安全）
  sudo bash ${SCRIPT_NAME}

  # 彻底清理，连数据一起删（务必确认已有可用备份）
  sudo bash ${SCRIPT_NAME} --purge-all

  # 先看会删什么
  sudo bash ${SCRIPT_NAME} --purge-all --dry-run
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

# systemctl is-active 会自己输出状态（inactive/disabled 等）并返回非 0，
# 因此只能"取输出、忽略退出码"，既不能再用 || echo unknown（会多一行），也不能 || s=""（会把状态清空）
svc_is_active() {
  local s=""
  s="$(systemctl is-active "$1" 2>/dev/null)" || true
  if [[ -z "$s" ]]; then s="unknown"; fi
  printf '%s' "$s"
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

cnf_escape() { local s="$1"; s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; printf '%s' "$s"; }

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

path_size() {  # 人类可读大小，失败返回 "-"
  local p="$1" s=""
  if [[ -e "$p" ]]; then
    s="$(du -sh "$p" 2>/dev/null | awk '{print $1}')" || s=""
  fi
  if [[ -z "$s" ]]; then printf '-'; else printf '%s' "$s"; fi
}

print_paths() {
  local p
  for p in "$@"; do
    if [[ -e "$p" ]]; then printf '    %s  (%s)\n' "$p" "$(path_size "$p")"; fi
  done
  return 0
}

# ---------------------------------------------------------------------------
# 交互原语
# ---------------------------------------------------------------------------
ask_yes_no() {  # 受 -y 影响
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

ask_feature() {  # 不受 -y 影响（高风险开关）
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

confirm_typed() {  # 不受 -y 影响
  local label="$1" phrase="$2" ans=""
  if [[ "$NON_INTERACTIVE" == "yes" ]]; then return 0; fi
  read -r -p "$(printf '%s（输入 %s 继续）: ' "$label" "$phrase")" ans || true
  if [[ "$ans" == "$phrase" ]]; then return 0; else return 1; fi
}

# ---------------------------------------------------------------------------
# 参数解析
# ---------------------------------------------------------------------------
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --keep-data)     PURGE_DATA="no"; PURGE_DATA_EXPLICIT="yes"; shift ;;
      --purge-data)    PURGE_DATA="yes"; PURGE_DATA_EXPLICIT="yes"; shift ;;
      --purge-all)     PURGE_DATA="yes"; PURGE_DATA_EXPLICIT="yes"
                       REMOVE_CONFIG="yes"; REMOVE_CONFIG_EXPLICIT="yes"
                       REMOVE_REPO="yes"; REMOVE_REPO_EXPLICIT="yes"
                       REMOVE_MYCNF="yes"; REMOVE_MYCNF_EXPLICIT="yes"
                       REMOVE_USER="yes"; shift ;;
      --keep-config)   REMOVE_CONFIG="no"; REMOVE_CONFIG_EXPLICIT="yes"; shift ;;
      --keep-repo)     REMOVE_REPO="no"; REMOVE_REPO_EXPLICIT="yes"; shift ;;
      --keep-mycnf)    REMOVE_MYCNF="no"; REMOVE_MYCNF_EXPLICIT="yes"; shift ;;
      --keep-user)     REMOVE_USER="no"; shift ;;
      --remove-extras) REMOVE_EXTRAS="yes"; REMOVE_EXTRAS_EXPLICIT="yes"; shift ;;
      --no-backup)     BACKUP="no"; BACKUP_EXPLICIT="yes"; shift ;;
      --backup-dir)    BACKUP_DIR="${2:?--backup-dir 需要值}"; shift 2 ;;
      --admin-pass)    ADMIN_PASSWORD="${2:?--admin-pass 需要值}"; shift 2 ;;
      -y|--yes)        ASSUME_YES="yes"; shift ;;
      -n|--non-interactive) NON_INTERACTIVE="yes"; ASSUME_YES="yes"; shift ;;
      --dry-run)       DRY_RUN="yes"; shift ;;
      -h|--help)       usage; exit 0 ;;
      *) die "未知参数：$1（用 --help 查看用法）" ;;
    esac
  done
  return 0
}

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    die "请以 root 身份运行：sudo bash ${SCRIPT_NAME}"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# 环境识别
# ---------------------------------------------------------------------------
detect_os() {
  step "识别操作系统"
  if [[ ! -r /etc/os-release ]]; then die "找不到 /etc/os-release，无法识别发行版"; fi
  # shellcheck disable=SC1091
  . /etc/os-release
  OS_ID="${ID:-unknown}"
  OS_PRETTY="${PRETTY_NAME:-$OS_ID ${VERSION_ID:-}}"
  local like=" ${ID_LIKE:-} ${OS_ID} "

  if [[ "$like" == *" debian "* || "$like" == *" ubuntu "* ]]; then
    OS_FAMILY="debian"; PKG="apt"
  elif [[ "$like" == *" rhel "* || "$like" == *" fedora "* || "$like" == *" centos "* \
      || "$like" == *" amzn "* || "$like" == *" openEuler "* || "$like" == *" anolis "* \
      || "$like" == *" kylin "* || "$like" == *" uos "* ]]; then
    OS_FAMILY="rhel"
    if need_cmd dnf; then PKG="dnf"; else PKG="yum"; fi
  elif [[ "$like" == *" suse "* || "$like" == *" opensuse "* ]]; then
    OS_FAMILY="suse"; PKG="zypper"
  elif [[ "$like" == *" arch "* ]]; then
    OS_FAMILY="arch"; PKG="pacman"
  elif need_cmd apt-get; then
    OS_FAMILY="debian"; PKG="apt"
  elif need_cmd dnf || need_cmd yum; then
    OS_FAMILY="rhel"
    if need_cmd dnf; then PKG="dnf"; else PKG="yum"; fi
  elif need_cmd zypper; then
    OS_FAMILY="suse"; PKG="zypper"
  elif need_cmd pacman; then
    OS_FAMILY="arch"; PKG="pacman"
  else
    die "暂不支持的发行版：${OS_PRETTY}"
  fi
  info "发行版：${OS_PRETTY}（family=${OS_FAMILY}, 包管理器=${PKG}）"
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

detect_packages() {
  local p
  PKG_LIST=(); EXTRA_LIST=()
  case "$OS_FAMILY" in
    debian)
      if need_cmd dpkg-query; then
        while IFS= read -r p; do
          if [[ -n "$p" ]]; then PKG_LIST+=("$p"); fi
        done < <(dpkg-query -W -f='${Package} ${Status}\n' 'mariadb*' 2>/dev/null \
                 | awk '/install ok installed/{print $1}' | sort -u)
        while IFS= read -r p; do
          if [[ -n "$p" ]]; then EXTRA_LIST+=("$p"); fi
        done < <(dpkg-query -W -f='${Package} ${Status}\n' 'libmariadb*' 'mysql-common' 2>/dev/null \
                 | awk '/install ok installed/{print $1}' | sort -u)
      fi
      ;;
    arch)
      if need_cmd pacman; then
        while IFS= read -r p; do
          if [[ -n "$p" && "$p" != mariadb-libs ]]; then PKG_LIST+=("$p"); fi
        done < <(pacman -Qq 2>/dev/null | grep -E '^(mariadb|mariadb-lts)' | sort -u)
        while IFS= read -r p; do
          if [[ -n "$p" ]]; then EXTRA_LIST+=("$p"); fi
        done < <(pacman -Qq 2>/dev/null | grep -E '^(mariadb-libs|libmariadb)' | sort -u)
      fi
      ;;
    *)
      if need_cmd rpm; then
        while IFS= read -r p; do
          if [[ -n "$p" ]]; then PKG_LIST+=("$p"); fi
        done < <(rpm -qa --qf '%{NAME}\n' 2>/dev/null | grep -E '^(MariaDB|mariadb)' | sort -u)
      fi
      ;;
  esac
  return 0
}

detect_data_dir() {
  local d=""
  if need_cmd grep; then
    d="$(grep -rhsE '^[[:space:]]*datadir[[:space:]]*=' \
          /etc/my.cnf /etc/mysql/my.cnf /etc/mysql/mariadb.conf.d /etc/my.cnf.d 2>/dev/null \
          | tail -n1 | sed -E 's/^[^=]*=[[:space:]]*//; s/[[:space:]]*$//' | tr -d '"' )" || d=""
  fi
  if [[ -z "$d" ]]; then d="$DEFAULT_DATA_DIR"; fi
  DATA_DIR="$d"
  if [[ -d "$DATA_DIR" ]]; then DATA_DIR_EXISTS="yes"; else DATA_DIR_EXISTS="no"; fi
  DATA_SIZE="$(path_size "$DATA_DIR")"
  return 0
}

collect_paths() {
  local p
  CONFIG_PATHS=() REPO_PATHS=() RUNTIME_PATHS=()
  for p in /etc/mysql /etc/my.cnf /etc/my.cnf.d /etc/my.cnf.pacsave /etc/my.cnf.d.pacsave \
           /etc/logrotate.d/mariadb /etc/logrotate.d/mysql /etc/apparmor.d/usr.sbin.mysqld \
           /var/log/mysql /var/log/mariadb /var/log/mysqld.log; do
    if [[ -e "$p" ]]; then CONFIG_PATHS+=("$p"); fi
  done
  for p in /etc/apt/sources.list.d/mariadb.sources /etc/apt/sources.list.d/mariadb.list \
           /etc/apt/sources.list.d/mariadb.list.old_* /etc/apt/keyrings/mariadb-keyring*.gpg \
           /etc/apt/trusted.gpg.d/mariadb-keyring*.gpg /etc/apt/trusted.gpg.d/mariadb.gpg \
           /etc/yum.repos.d/mariadb.repo /etc/yum.repos.d/MariaDB.repo \
           /etc/yum.repos.d/mariadb.repo.disabled; do
    if [[ -e "$p" ]]; then REPO_PATHS+=("$p"); fi
  done
  for p in /run/mysqld /run/mariadb /var/lock/subsys/mariadb /var/lock/subsys/mysql; do
    if [[ -e "$p" ]]; then RUNTIME_PATHS+=("$p"); fi
  done
  return 0
}

detect_installed() {
  step "盘点已安装的 MariaDB"
  detect_service_name
  detect_packages
  detect_data_dir
  collect_paths

  local bin_found=""
  for b in mariadbd mysqld mariadb mysql mariadb-dump mysqldump; do
    if need_cmd "$b"; then bin_found="${bin_found}${b} "; fi
  done

  if [[ ${#PKG_LIST[@]} -gt 0 || -n "$bin_found" || "$DATA_DIR_EXISTS" == "yes" ]]; then
    MARIADB_FOUND="yes"
  else
    MARIADB_FOUND="no"
  fi

  if [[ "$MARIADB_FOUND" == "no" ]]; then
    info "未检测到 MariaDB/MySQL 的软件包、可执行文件或数据目录，无需卸载"
    return 0
  fi

  printf '%s\n' "${C_BOLD}已发现以下内容：${C_RESET}"
  if [[ ${#PKG_LIST[@]} -gt 0 ]]; then
    printf '  软件包（%d 个）：\n' "${#PKG_LIST[@]}"
    printf '    %s\n' "${PKG_LIST[*]}"
  else
    printf '  软件包：未从包管理器检出\n'
  fi
  if [[ -n "$bin_found" ]]; then printf '  可执行文件：%s\n' "$bin_found"; fi
  if [[ "$SERVICE_EXISTS" == "yes" ]]; then
    printf '  服务：%s（当前 %s）\n' "$SERVICE_NAME" "$(svc_is_active "$SERVICE_NAME")"
  else
    printf '  服务：未找到 systemd 单元\n'
  fi
  if [[ "$DATA_DIR_EXISTS" == "yes" ]]; then
    printf '  数据目录：%s  (%s)\n' "$DATA_DIR" "$DATA_SIZE"
  else
    printf '  数据目录：%s 不存在\n' "$DATA_DIR"
  fi
  if [[ ${#CONFIG_PATHS[@]} -gt 0 ]]; then
    printf '  配置与日志：\n'
    print_paths "${CONFIG_PATHS[@]}"
  fi
  if [[ ${#EXTRA_LIST[@]} -gt 0 ]]; then
    printf '  公共包/共享库（默认可保留）：%s\n' "${EXTRA_LIST[*]}"
  fi
  if [[ ${#REPO_PATHS[@]} -gt 0 ]]; then
    printf '  仓库配置：\n'
    print_paths "${REPO_PATHS[@]}"
  fi
  if [[ -f "$MYCNF_PATH" ]]; then printf '  %s 存在\n' "$MYCNF_PATH"; fi
  if id mysql >/dev/null 2>&1; then printf '  系统用户：mysql 存在\n'; fi
  return 0
}

# ---------------------------------------------------------------------------
# SQL 连接（用于备份前导出）
# ---------------------------------------------------------------------------
init_clients() {
  SQL_CLIENT="$(command -v mariadb || command -v mysql || true)"
  DUMP_CLIENT="$(command -v mariadb-dump || command -v mysqldump || true)"
  return 0
}

write_client_cnf() {
  local pw="$1" f
  f="$(mktemp_tracked)"
  {
    printf '[client]\n'
    printf 'user=root\n'
    printf 'password="%s"\n' "$(cnf_escape "$pw")"
  } >"$f"
  printf '%s' "$f"
}

test_root_password() {
  local pw="$1" cnf rc=0
  cnf="$(write_client_cnf "$pw")"
  "$SQL_CLIENT" --defaults-extra-file="$cnf" --protocol=socket -e 'SELECT 1' >/dev/null 2>&1 || rc=$?
  rm -f "$cnf"
  return $rc
}

detect_admin_auth() {
  if [[ -z "$SQL_CLIENT" ]]; then return 1; fi
  if "$SQL_CLIENT" --protocol=socket -u root -e 'SELECT 1' >/dev/null 2>&1; then
    ADMIN_AUTH_MODE="socket"; ADMIN_PASSWORD=""
    return 0
  fi
  if [[ -n "$ADMIN_PASSWORD" ]]; then
    if test_root_password "$ADMIN_PASSWORD"; then
      ADMIN_AUTH_MODE="password"
      return 0
    fi
    warn "--admin-pass 提供的密码无法登录，逻辑备份将跳过"
    return 1
  fi
  if [[ "$NON_INTERACTIVE" == "yes" ]]; then
    warn "无法免密登录 root，逻辑备份将跳过（物理打包备份不受影响）"
    return 1
  fi
  local i pw
  for i in 1 2 3; do
    read -r -s -p "请输入当前 root 密码以便导出全库备份（第 ${i}/3 次，回车跳过）: " pw || true
    printf '\n'
    if [[ -z "$pw" ]]; then return 1; fi
    if test_root_password "$pw"; then
      ADMIN_PASSWORD="$pw"; ADMIN_AUTH_MODE="password"
      return 0
    fi
    warn "密码不正确"
  done
  return 1
}

sql_query() {
  local sql="$1" out="" rc=0 f cnf=""
  f="$(mktemp_tracked)"
  printf '%s\n' "$sql" >"$f"
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

# ---------------------------------------------------------------------------
# 交互向导
# ---------------------------------------------------------------------------
wizard() {
  step "第 1 步 / 备份"
  if [[ "$DATA_DIR_EXISTS" == "yes" || "$SERVICE_EXISTS" == "yes" ]]; then
    if [[ "$BACKUP_EXPLICIT" != "yes" && "$NON_INTERACTIVE" != "yes" ]]; then
      if ask_feature "卸载前自动备份数据（推荐：逻辑导出 + 数据目录打包）？" y; then
        BACKUP="yes"
      else
        BACKUP="no"
      fi
    fi
  else
    BACKUP="no"
  fi
  if [[ "$BACKUP" == "yes" ]]; then
    info "备份目录：${BACKUP_DIR}"
  else
    warn "已选择不自动备份；若同时删除数据目录，将无法恢复"
  fi

  step "第 2 步 / 卸载范围"
  if [[ "$DATA_DIR_EXISTS" == "yes" && "$PURGE_DATA_EXPLICIT" != "yes" ]]; then
    if [[ "$NON_INTERACTIVE" == "yes" ]]; then
      PURGE_DATA="no"
    else
      printf '%s\n' "${C_YELLOW}数据目录 ${DATA_DIR}（${DATA_SIZE}）内含全部数据库文件。${C_RESET}"
      if ask_feature "是否连数据目录一起删除？（默认保留，仅卸载软件）" n; then
        PURGE_DATA="yes"
      else
        PURGE_DATA="no"
      fi
    fi
  fi

  if [[ "$REMOVE_CONFIG_EXPLICIT" != "yes" && "$NON_INTERACTIVE" != "yes" ]]; then
    if ask_feature "删除配置文件与数据库日志？（删除前会先备份到 ${BACKUP_DIR}）" y; then
      REMOVE_CONFIG="yes"
    else
      REMOVE_CONFIG="no"
    fi
  fi

  if [[ "$REMOVE_REPO_EXPLICIT" != "yes" && "$NON_INTERACTIVE" != "yes" ]]; then
    if [[ ${#REPO_PATHS[@]} -gt 0 ]]; then
      if ask_feature "移除 MariaDB 官方仓库配置？" y; then
        REMOVE_REPO="yes"
      else
        REMOVE_REPO="no"
      fi
    else
      REMOVE_REPO="no"
    fi
  fi

  if [[ "$REMOVE_MYCNF_EXPLICIT" != "yes" && "$NON_INTERACTIVE" != "yes" ]]; then
    if [[ -f "$MYCNF_PATH" ]]; then
      if ask_feature "删除 ${MYCNF_PATH}（其中可能保存了 root 密码）？" y; then
        REMOVE_MYCNF="yes"
      else
        REMOVE_MYCNF="no"
      fi
    else
      REMOVE_MYCNF="no"
    fi
  fi

  if [[ "$REMOVE_EXTRAS_EXPLICIT" != "yes" && "$NON_INTERACTIVE" != "yes" ]]; then
    if [[ "$OS_FAMILY" == "debian" || "$OS_FAMILY" == "arch" ]]; then
      if ask_feature "同时移除公共包与共享库（mysql-common / libmariadb* / mariadb-libs）？可能被 php、python 连接器等依赖，默认保留" n; then
        REMOVE_EXTRAS="yes"
      else
        REMOVE_EXTRAS="no"
      fi
    fi
  fi

  if [[ "$REMOVE_USER" == "follow" ]]; then
    if [[ "$PURGE_DATA" == "yes" ]]; then REMOVE_USER="yes"; else REMOVE_USER="no"; fi
  fi
  if [[ "$REMOVE_USER" == "yes" && "$PURGE_DATA" == "no" ]]; then
    warn "数据目录将保留，建议同时保留 mysql 系统用户（否则数据属主会变成数字 UID）"
    if [[ "$NON_INTERACTIVE" != "yes" ]]; then
      if ask_feature "仍要删除 mysql 系统用户？" n; then REMOVE_USER="yes"; else REMOVE_USER="no"; fi
    else
      REMOVE_USER="no"
    fi
  fi
  return 0
}

show_plan() {
  step "执行计划确认"
  local scope_data scope_cfg scope_repo scope_mycnf scope_user scope_backup scope_extra
  if [[ "$PURGE_DATA" == "yes" ]]; then
    scope_data="${C_RED}删除${C_RESET} ${DATA_DIR}（${DATA_SIZE}）"
  else
    scope_data="保留 ${DATA_DIR}"
  fi
  if [[ "$REMOVE_CONFIG" == "yes" ]]; then scope_cfg="删除（先备份）"; else scope_cfg="保留"; fi
  if [[ "$REMOVE_REPO" == "yes" ]]; then scope_repo="删除"; else scope_repo="保留"; fi
  if [[ "$REMOVE_MYCNF" == "yes" ]]; then scope_mycnf="删除"; else scope_mycnf="保留"; fi
  if [[ "$REMOVE_USER" == "yes" ]]; then scope_user="删除"; else scope_user="保留"; fi
  if [[ "$BACKUP" == "yes" ]]; then scope_backup="开启 → ${BACKUP_DIR}"; else scope_backup="${C_RED}关闭${C_RESET}"; fi
  if [[ "$REMOVE_EXTRAS" == "yes" ]]; then scope_extra="移除"; else scope_extra="保留"; fi

  printf '%s\n' "${C_BOLD}即将执行的操作：${C_RESET}"
  item "操作系统"   "${OS_PRETTY}" 2 18
  item "卸载软件包" "$(if [[ ${#PKG_LIST[@]} -gt 0 ]]; then printf '%d 个' "${#PKG_LIST[@]}"; else printf '未检出'; fi)" 2 18
  item "停止并禁用服务" "systemctl disable --now ${SERVICE_NAME:-mariadb}" 2 18
  item "数据目录"   "$scope_data" 2 18
  item "配置与日志" "$scope_cfg" 2 18
  item "仓库配置"   "$scope_repo" 2 18
  item "${MYCNF_PATH}" "$scope_mycnf" 2 18
  item "mysql 用户" "$scope_user" 2 18
  item "公共包/共享库" "$scope_extra" 2 18
  item "卸载前备份" "$scope_backup" 2 18
  item "日志"       "$LOG_FILE" 2 18
  return 0
}

confirm_plan() {
  if [[ "$DRY_RUN" == "yes" ]]; then info "dry-run 模式：不做任何变更"; return 0; fi

  # 危险操作：删除数据目录，需逐字确认
  if [[ "$PURGE_DATA" == "yes" && "$DATA_DIR_EXISTS" == "yes" ]]; then
    printf '\n%s\n' "${C_RED}${C_BOLD}⚠️ 此操作非常危险，可能导致不可逆的数据丢失！${C_RESET}"
    printf '%s\n' "  将被永久删除的路径："
    printf '    %s\n' "${DATA_DIR}"
    printf '%s\n' "  影响：${DATA_DIR} 下所有数据库、表、用户与授权信息全部消失。"
    if [[ "$BACKUP" == "yes" ]]; then
      printf '%s\n' "  已开启自动备份，删除前会先导出到 ${BACKUP_DIR}。"
    else
      printf '%s\n' "${C_RED}  当前未开启备份，删除后无法恢复！${C_RESET}"
    fi
    printf '\n'
    if [[ "$PURGE_DATA_EXPLICIT" != "yes" ]]; then
      if ! confirm_typed "确认删除数据目录" "DELETE"; then die "已取消，未做任何变更"; fi
    fi
  fi

  if [[ "$ASSUME_YES" == "yes" || "$NON_INTERACTIVE" == "yes" ]]; then return 0; fi
  if ! ask_yes_no "确认按以上计划执行？" y; then die "已取消，未做任何变更"; fi
  return 0
}

# ---------------------------------------------------------------------------
# 备份
# ---------------------------------------------------------------------------
service_active() {
  if [[ "$SERVICE_EXISTS" != "yes" ]]; then return 1; fi
  if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then return 0; fi
  return 1
}

dump_logical_backup() {
  local ts="$1" out="${BACKUP_DIR}/all-databases-${ts}.sql.gz" rc=0
  if [[ -z "$DUMP_CLIENT" ]]; then
    warn "未找到 mariadb-dump/mysqldump，跳过逻辑备份"
    return 0
  fi
  if ! service_active; then
    warn "服务未运行，跳过逻辑备份（物理打包备份仍会执行）"
    return 0
  fi
  if [[ "$ADMIN_AUTH_MODE" == "password" ]]; then
    local cnf; cnf="$(write_client_cnf "$ADMIN_PASSWORD")"
    "$DUMP_CLIENT" --defaults-extra-file="$cnf" --all-databases --single-transaction \
      --events --routines --triggers 2>"${BACKUP_DIR}/dump-error.log" | gzip >"$out" || rc=$?
    rm -f "$cnf"
  else
    "$DUMP_CLIENT" --protocol=socket -u root --all-databases --single-transaction \
      --events --routines --triggers 2>"${BACKUP_DIR}/dump-error.log" | gzip >"$out" || rc=$?
  fi

  if [[ $rc -ne 0 || ! -s "$out" ]]; then
    warn "逻辑备份未成功，详见 ${BACKUP_DIR}/dump-error.log（物理备份仍会执行）"
    rm -f "$out"
    return 0
  fi
  if ! gzip -t "$out" 2>/dev/null; then
    warn "逻辑备份文件完整性校验失败，已删除"
    rm -f "$out"
    return 0
  fi
  BACKUP_FILES+=("$out")
  ok "逻辑备份完成：${out}（$(path_size "$out")）"
  return 0
}

physical_backup() {
  local ts="$1" parent base out
  if [[ "$DATA_DIR_EXISTS" != "yes" ]]; then
    info "无数据目录，跳过物理打包备份"
    return 0
  fi
  parent="$(dirname "$DATA_DIR")"
  base="${DATA_DIR##*/}"
  out="${BACKUP_DIR}/mysql-datadir-${ts}.tar.gz"

  if [[ "$DRY_RUN" == "yes" ]]; then
    printf '%s\n' "${C_DIM}[dry-run] tar czf ${out} -C ${parent} ${base}${C_RESET}"
    return 0
  fi

  tar czf "$out" -C "$parent" "$base" 2>"${BACKUP_DIR}/tar-error.log" || {
    warn "数据目录打包失败，详见 ${BACKUP_DIR}/tar-error.log"
    return 1
  }
  if ! tar tzf "$out" >/dev/null 2>&1; then
    warn "备份包完整性校验失败：${out}"
    return 1
  fi
  BACKUP_FILES+=("$out")
  ok "数据目录已打包：${out}（$(path_size "$out")）"
  return 0
}

do_backup() {
  if [[ "$BACKUP" != "yes" ]]; then return 0; fi
  step "备份数据"
  if [[ "$DRY_RUN" != "yes" ]]; then
    mkdir -p "$BACKUP_DIR"
    chmod 700 "$BACKUP_DIR"
  fi
  local ts; ts="$(date +%Y%m%d%H%M%S)"

  if [[ "$DRY_RUN" == "yes" ]]; then
    printf '%s\n' "${C_DIM}[dry-run] mkdir -p ${BACKUP_DIR}${C_RESET}"
    return 0
  fi

  # 记录当前库与账号清单，便于事后核对
  if service_active && [[ -n "$SQL_CLIENT" ]]; then
    {
      printf '# MariaDB 卸载前清单  %s\n\n' "$(date '+%F %T')"
      printf '## SHOW DATABASES\n'
      sql_query "SHOW DATABASES;" 2>/dev/null || true
      printf '\n## mysql.user\n'
      sql_query "SELECT CONCAT(User,'@',Host), plugin FROM mysql.user ORDER BY 1;" 2>/dev/null || true
    } >"${BACKUP_DIR}/inventory-${ts}.txt" 2>/dev/null || true
    ok "已记录库/账号清单：${BACKUP_DIR}/inventory-${ts}.txt"
  fi

  dump_logical_backup "$ts"

  step "停止服务（保证数据目录一致）"
  stop_service
  if ! physical_backup "$ts"; then
    if [[ "$PURGE_DATA" == "yes" ]]; then
      die "数据备份失败，为避免不可逆丢失，已中止删除数据目录的操作"
    fi
    warn "备份失败，但未选择删除数据，可继续卸载软件包"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# 执行动作
# ---------------------------------------------------------------------------
stop_service() {
  if [[ "$SERVICE_EXISTS" == "yes" ]]; then
    run systemctl disable --now "$SERVICE_NAME" || true
    if [[ "$DRY_RUN" != "yes" ]]; then
      sleep 1
      if service_active; then
        warn "服务仍在运行，尝试强制停止"
        systemctl kill -s TERM "$SERVICE_NAME" 2>/dev/null || true
        sleep 2
      fi
    fi
  else
    info "未发现 systemd 单元，跳过服务停止"
  fi

  if [[ "$DRY_RUN" != "yes" ]]; then
    local pids=""
    pids="$(pgrep -f 'mariadbd|mysqld' 2>/dev/null || true)"
    if [[ -n "$pids" ]]; then
      warn "仍有残留进程：${pids//$'\n'/ }，尝试结束"
      pkill -TERM -f 'mariadbd|mysqld' 2>/dev/null || true
      sleep 2
      if pgrep -f 'mariadbd|mysqld' >/dev/null 2>&1; then
        pkill -KILL -f 'mariadbd|mysqld' 2>/dev/null || true
        sleep 1
      fi
    fi
  fi
  return 0
}

remove_packages() {
  step "卸载软件包"
  local all=()
  if [[ ${#PKG_LIST[@]} -gt 0 ]]; then all+=("${PKG_LIST[@]}"); fi
  if [[ "$REMOVE_EXTRAS" == "yes" && ${#EXTRA_LIST[@]} -gt 0 ]]; then all+=("${EXTRA_LIST[@]}"); fi

  if [[ ${#all[@]} -eq 0 ]]; then
    info "未从包管理器检出相关软件包，跳过"
    return 0
  fi

  printf '  待卸载：%s\n' "${all[*]}"
  case "$OS_FAMILY" in
    debian)
      # apt purge 会按依赖顺序卸载并同时清除配置文件
      if ! run env DEBIAN_FRONTEND=noninteractive apt-get purge -y "${all[@]}"; then
        warn "apt purge 未完全成功，请用 dpkg -l | grep -i mariadb 复核"
      fi
      ;;
    arch)
      # 不加 -s（不递归卸载依赖），避免误删被其他软件依赖的包
      if ! run pacman -R --noconfirm "${all[@]}"; then
        warn "pacman -R 未完全成功（可能有其他软件依赖待删包），请用 pacman -Qq | grep -i mariadb 复核"
      fi
      ;;
    suse)
      if ! run zypper -n remove "${all[@]}"; then
        warn "zypper remove 未完全成功，请用 rpm -qa | grep -i mariadb 复核"
      fi
      ;;
    *)
      if ! run "$PKG" remove -y "${all[@]}"; then
        warn "$PKG remove 未完全成功，请用 rpm -qa | grep -i mariadb 复核"
      fi
      ;;
  esac
  ok "软件包卸载完成"
  return 0
}

remove_paths() {  # remove_paths <说明> <路径...>
  local desc="$1"; shift
  local p
  for p in "$@"; do
    if [[ ! -e "$p" ]]; then continue; fi
    if [[ "$DRY_RUN" == "yes" ]]; then
      printf '%s\n' "${C_DIM}[dry-run] 备份并删除 ${p}${C_RESET}"
      continue
    fi
    mkdir -p "$BACKUP_DIR/configs" 2>/dev/null || true
    cp -a "$p" "${BACKUP_DIR}/configs/${p##*/}.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
    rm -rf -- "$p"
    _log_raw "[DEL] ${desc}: ${p}"
  done
  if [[ "$DRY_RUN" != "yes" ]]; then ok "${desc}已清理"; fi
  return 0
}

remove_configs() {
  if [[ "$REMOVE_CONFIG" != "yes" ]]; then
    info "按选择保留配置文件"
    return 0
  fi
  step "清理配置与日志"
  if [[ ${#CONFIG_PATHS[@]} -gt 0 ]]; then
    remove_paths "配置与日志" "${CONFIG_PATHS[@]}"
  else
    info "未发现配置文件与日志"
  fi
  return 0
}

remove_repo() {
  if [[ "$REMOVE_REPO" != "yes" ]]; then
    info "按选择保留仓库配置"
    return 0
  fi
  step "移除 MariaDB 官方仓库配置"
  if [[ ${#REPO_PATHS[@]} -gt 0 ]]; then
    remove_paths "仓库配置" "${REPO_PATHS[@]}"
    if [[ "$OS_FAMILY" == "debian" && "$DRY_RUN" != "yes" ]]; then
      run apt-get update -qq || true
    fi
  else
    info "未发现 MariaDB 官方仓库配置"
  fi
  return 0
}

remove_data() {
  if [[ "$PURGE_DATA" != "yes" ]]; then
    info "按选择保留数据目录 ${DATA_DIR}"
    return 0
  fi
  step "删除数据目录"
  if [[ "$DATA_DIR_EXISTS" != "yes" ]]; then
    info "${DATA_DIR} 不存在，跳过"
    return 0
  fi
  if [[ "$BACKUP" == "yes" && ${#BACKUP_FILES[@]} -eq 0 && "$DRY_RUN" != "yes" ]]; then
    die "未找到任何有效备份产物，拒绝删除数据目录"
  fi
  if [[ "$DRY_RUN" == "yes" ]]; then
    printf '%s\n' "${C_DIM}[dry-run] rm -rf ${DATA_DIR}${C_RESET}"
    return 0
  fi
  rm -rf -- "$DATA_DIR"
  if [[ -e "$DATA_DIR" ]]; then die "删除 ${DATA_DIR} 失败，请检查是否仍有进程占用"; fi
  DATA_DIR_EXISTS="no"
  ok "数据目录已删除：${DATA_DIR}"
  return 0
}

remove_runtime_and_user() {
  step "清理运行时残留"
  if [[ ${#RUNTIME_PATHS[@]} -gt 0 ]]; then
    remove_paths "运行时残留" "${RUNTIME_PATHS[@]}"
  else
    info "无运行时残留"
  fi

  if [[ "$REMOVE_MYCNF" == "yes" && -f "$MYCNF_PATH" ]]; then
    if [[ "$DRY_RUN" == "yes" ]]; then
      printf '%s\n' "${C_DIM}[dry-run] 备份并删除 ${MYCNF_PATH}${C_RESET}"
    else
      cp -a "$MYCNF_PATH" "${BACKUP_DIR}/root-my.cnf.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
      umask 077
      shred -u "$MYCNF_PATH" 2>/dev/null || rm -f "$MYCNF_PATH"
      ok "${MYCNF_PATH} 已删除（副本存于 ${BACKUP_DIR}）"
    fi
  fi

  if [[ "$REMOVE_USER" == "yes" ]]; then
    if id mysql >/dev/null 2>&1; then
      run userdel mysql 2>/dev/null || warn "删除 mysql 用户失败（可能有进程占用）"
    fi
    if getent group mysql >/dev/null 2>&1; then
      run groupdel mysql 2>/dev/null || true
    fi
    if [[ "$DRY_RUN" != "yes" ]]; then ok "mysql 系统用户/组已处理"; fi
  else
    info "按选择保留 mysql 系统用户/组"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# 复核与总结
# ---------------------------------------------------------------------------
verify() {
  step "卸载结果复核"
  if [[ "$DRY_RUN" == "yes" ]]; then info "dry-run 模式，跳过复核"; return 0; fi

  local left_pkg="" left_bin="" left_data="no"
  case "$OS_FAMILY" in
    debian)
      left_pkg="$(dpkg-query -W -f='${Package} ${Status}\n' 'mariadb*' 2>/dev/null \
                  | awk '/install ok installed/{print $1}' | tr '\n' ' ')" || left_pkg=""
      ;;
    arch)
      left_pkg="$(pacman -Qq 2>/dev/null | grep -E '^(mariadb|mariadb-lts)' | tr '\n' ' ')" || left_pkg=""
      ;;
    *)
      left_pkg="$(rpm -qa --qf '%{NAME}\n' 2>/dev/null | grep -E '^(MariaDB|mariadb)' | tr '\n' ' ')" || left_pkg=""
      ;;
  esac
  local b
  for b in mariadbd mysqld mariadb mysql; do
    if need_cmd "$b"; then left_bin="${left_bin}${b} "; fi
  done
  if [[ -d "$DATA_DIR" ]]; then left_data="yes"; fi

  if [[ -n "$left_pkg" ]]; then
    warn "仍存在相关软件包：${left_pkg}"
  else
    ok "已无相关软件包"
  fi
  if [[ -n "$left_bin" ]]; then
    warn "仍存在可执行文件：${left_bin}（若来自其他安装方式，如源码编译，请手动清理）"
  else
    ok "已无可执行文件"
  fi
  if [[ "$left_data" == "yes" ]]; then
    info "数据目录保留：${DATA_DIR}（$(path_size "$DATA_DIR")）"
  else
    ok "数据目录已不存在"
  fi
  if need_cmd ss; then
    if ss -lntp 2>/dev/null | grep -qE ':(3306|3307) '; then
      warn "检测到 3306/3307 端口仍有监听，请确认是否为本机其他数据库服务"
      ss -lntp 2>/dev/null | grep -E ':(3306|3307) ' || true
    else
      ok "3306 端口已无监听"
    fi
  fi
  return 0
}

summary() {
  printf '\n%s\n' "${C_BOLD}${C_GREEN}================ 卸载完成 ================${C_RESET}"
  item "已卸载软件包" "$(if [[ ${#PKG_LIST[@]} -gt 0 ]]; then printf '%d 个' "${#PKG_LIST[@]}"; else printf '无'; fi)" 2 16
  item "系统服务"     "已停止并取消开机自启（${SERVICE_NAME:-mariadb}）" 2 16
  item "数据目录"     "$(if [[ "$PURGE_DATA" == "yes" ]]; then printf '已删除 %s' "$DATA_DIR"; else printf '保留 %s' "$DATA_DIR"; fi)" 2 16
  item "配置与日志"   "$(if [[ "$REMOVE_CONFIG" == "yes" ]]; then printf '已清理'; else printf '保留'; fi)" 2 16
  item "仓库配置"     "$(if [[ "$REMOVE_REPO" == "yes" ]]; then printf '已移除'; else printf '保留'; fi)" 2 16
  item "日志"         "$LOG_FILE" 2 16

  if [[ ${#BACKUP_FILES[@]} -gt 0 ]]; then
    printf '\n%s\n' "${C_BOLD}备份产物（请确认可用后再做其他清理）${C_RESET}"
    local f
    for f in "${BACKUP_FILES[@]}"; do printf '  %s\n' "$f"; done
  fi

  if [[ "$PURGE_DATA" != "yes" && "$DATA_DIR_EXISTS" == "yes" ]]; then
    printf '\n%s\n' "${C_BOLD}数据仍在，如需彻底清理${C_RESET}"
    printf '  sudo rm -rf %s\n' "$DATA_DIR"
    printf '  %s\n' "（先确认已有可用备份，再执行）"
  fi

  if [[ ${#BACKUP_FILES[@]} -gt 0 ]]; then
    printf '\n%s\n' "${C_BOLD}恢复步骤${C_RESET}"
    if [[ "$OS_FAMILY" == "debian" ]]; then
      printf '  1) 重新安装：apt-get update && apt-get install -y mariadb-server\n'
    else
      printf '  1) 重新安装：%s install -y MariaDB-server MariaDB-client\n' "$PKG"
    fi
    printf '  2) 停止服务：systemctl stop mariadb\n'
    printf '  3) 恢复数据：rm -rf %s && tar xzf <备份包> -C %s\n' "$DATA_DIR" "$(dirname "$DATA_DIR")"
    printf '  4) 修属主　：chown -R mysql:mysql %s\n' "$DATA_DIR"
    printf '  5) 启动服务：systemctl start mariadb\n'
    printf '  %s\n' "逻辑备份恢复：zcat <all-databases-*.sql.gz> | mariadb -u root -p"
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
  if ! : >>"$LOG_FILE" 2>/dev/null; then LOG_FILE="/tmp/uninstall-mariadb-lts.log"; fi

  printf '%s\n' "${C_BOLD}MariaDB 卸载脚本 v${SCRIPT_VERSION}${C_RESET}   |   日志：${LOG_FILE}"
  if [[ "$DRY_RUN" == "yes" ]]; then warn "dry-run 模式：仅打印操作，不做任何变更"; fi

  detect_os
  detect_installed
  if [[ "$MARIADB_FOUND" == "no" ]]; then
    printf '\n'
    info "本机未安装 MariaDB/MySQL，无需卸载。若你确认装过，请检查是否为源码编译安装（可用 which mariadbd 排查）。"
    return 0
  fi

  init_clients
  if service_active && [[ -n "$SQL_CLIENT" ]]; then
    detect_admin_auth || true
  fi

  wizard
  show_plan
  confirm_plan

  do_backup
  if [[ "$BACKUP" != "yes" ]]; then stop_service; fi
  remove_packages
  remove_configs
  remove_repo
  remove_data
  remove_runtime_and_user
  verify
  summary
  return 0
}

main "$@"
