#!/usr/bin/env bash
# =============================================================================
#  mariadb-manager.sh —— MariaDB LTS 一体化管理脚本（安装 / 卸载 / 体检）
#
#  由原来的 install-mariadb-lts.sh + uninstall-mariadb-lts.sh 合并而来：
#    两个脚本曾各自实现一套日志、颜色、确认、备份、SQL 客户端、服务探测，
#    现已全部收敛进 lib/，本文件只保留各自的业务逻辑。
#
#  用法：
#    sudo bash mariadb-manager.sh install    [安装选项]   安装并初始化 MariaDB LTS
#    sudo bash mariadb-manager.sh uninstall  [卸载选项]   卸载（可先做逻辑备份）
#    bash  mariadb-manager.sh status                     只读体检：版本 / 服务 / 数据目录
#    sudo bash mariadb-manager.sh menu                   交互式向导
#    bash  mariadb-manager.sh help [install|uninstall]   帮助
#
#  常用选项（install）：
#    --series 12.3|11.8|11.4|10.11     版本系列（默认 12.3）
#    --repo official|distro            软件源（默认官方仓库）
#    --port 3306                       监听端口
#    --root-password <密码>            root 口令（不给则交互询问/自动生成）
#    --remote-root                     允许 root 远程登录（默认否）
#    --create-app-db                   额外创建业务库与专用账号
#    --open-firewall                   放行防火墙端口
#    --no-start --no-autostart         不立即启动 / 不开机自启
#    --service-only                    只调整服务启停状态
#    --reconfigure-only                只改配置，不装包
#    -y  --yes                         自动确认非破坏性询问
#    -n  --dry-run                     只预览，不做任何改动
#        --non-interactive             完全非交互
#
#  常用选项（uninstall）：
#    --purge-data                      连同数据目录一起删除（默认保留）
#    --no-backup                       卸载前不做逻辑备份（默认做）
#    --keep-config --keep-repo         保留配置 / 保留官方仓库
#    --remove-extras                   一并移除可选的公共包与共享库
#    --remove-user yes|no|follow       是否删除 mysql 系统用户（默认 follow）
#    -y  --yes                         自动确认非破坏性询问
#    -n  --dry-run                     只预览
#
#  安全约定：
#    * 卸载属破坏性操作，必须逐字输入 DELETE 确认；--yes 不会跳过这道确认。
#    * 所有被覆盖/删除的文件都会先备份到 $BACKUP_DIR。
#    * 完整日志见 $LOG_FILE。
# =============================================================================
set -Eeuo pipefail

SCRIPT_NAME="${0##*/}"
SCRIPT_VERSION="2.0.0"
ORIG_ARGS=("$@")          # 供 require_root 提权后原样重放

# ---------------------------------------------------------------------------
# 共享库（日志 / 颜色 / 交互 / 发行版识别 / 服务 / MariaDB 客户端 / 备份）
# ---------------------------------------------------------------------------
__OPS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# shellcheck source=/dev/null
source "${__OPS_DIR}/lib/lib.sh"
unset __OPS_DIR

# ---------------------------------------------------------------------------
# 全局默认值（安装 / 卸载共用）
# ---------------------------------------------------------------------------
ACTION=""
LOG_FILE="/var/log/mariadb-manager.log"
BACKUP_DIR="/var/backups/mariadb-manager"
MYCNF_PATH="/root/.my.cnf"
DEFAULT_DATA_DIR="/var/lib/mysql"
LOCK_FILE="/var/lock/mariadb-manager.lock"
TMP_FILES=()

NON_INTERACTIVE="no"
ASSUME_YES="no"
DRY_RUN="no"

# —— 安装侧 ——
REPO_SETUP_URL="https://r.mariadb.com/downloads/mariadb_repo_setup"
SERIES="12.3"
REPO_SOURCE="official"
ARCH_PKG="mariadb-lts"
PORT="3306"
BIND_ADDRESS=""
AUTO_PASSWORD="no"
RECONFIGURE_ONLY="no"
START_NOW="yes";      START_NOW_EXPLICIT="no"
AUTOSTART="yes";      AUTOSTART_EXPLICIT="no"
SERVICE_ONLY="no"
ROOT_PASSWORD=""
KEEP_SOCKET="yes"
REMOTE_ROOT="no";     REMOTE_ROOT_HOST="%"; REMOTE_ROOT_SAME_PASS="yes"
REMOTE_ROOT_PASSWORD=""; REMOTE_ROOT_EXPLICIT="no"
WRITE_MYCNF="no"
CREATE_APP_DB="no";   APP_DB_NAME=""; APP_DB_USER=""; APP_DB_PASSWORD=""; APP_DB_HOST="%"
OPEN_FIREWALL="no";   FIREWALL_SOURCE=""; OPEN_FIREWALL_EXPLICIT="no"

# —— 卸载侧 ——
BACKUP="yes";         BACKUP_EXPLICIT="no"
PURGE_DATA="no";      PURGE_DATA_EXPLICIT="no"
REMOVE_CONFIG="yes";  REMOVE_CONFIG_EXPLICIT="no"
REMOVE_REPO="yes";    REMOVE_REPO_EXPLICIT="no"
REMOVE_MYCNF="yes";   REMOVE_MYCNF_EXPLICIT="no"
REMOVE_EXTRAS="no";   REMOVE_EXTRAS_EXPLICIT="no"
REMOVE_USER="follow"

# —— 运行时状态 ——
ADMIN_PASSWORD=""
ADMIN_AUTH_MODE="socket"
SQL_CLIENT=""
DUMP_CLIENT=""
OS_ID="unknown"; OS_FAMILY="unknown"; OS_VERSION=""; OS_PRETTY=""
PKG=""; ARCH=""
SERVICE_NAME="mariadb"; SERVICE_EXISTS="no"
CONF_DROPIN=""; INSTALLED="no"
DATA_DIR=""; DATA_DIR_EXISTS="no"; DATA_SIZE=""
MARIADB_FOUND="no"
PKG_LIST=(); EXTRA_LIST=(); CONFIG_PATHS=(); REPO_PATHS=(); RUNTIME_PATHS=(); BACKUP_FILES=()

# ---------------------------------------------------------------------------
# 兼容层：把历史函数名映射到共享库
#   这样安装/卸载两侧的业务代码可以原样保留，不做大改
# ---------------------------------------------------------------------------
Db::new DB                      # MariaDB 客户端对象（安装 / 卸载共用）

_log_raw() { Logger::raw LOG "$*"; }
log()      { Logger::raw LOG "$*"; }

# 初始化：日志对象、错误陷阱、交互开关、临时文件回收
mdb_init() {
  Lib::bootstrap "$LOG_FILE"
  LOG_FILE="${LOG[file]:-$LOG_FILE}"
  Lib::install_err_trap
  if [[ "$ASSUME_YES" == "yes" ]]; then UI[assume_yes]=1; else UI[assume_yes]=0; fi
  if [[ "$NON_INTERACTIVE" == "yes" ]]; then UI[non_interactive]=1; else UI[non_interactive]=0; fi
  trap 'Tmp::cleanup' EXIT
  return 0
}

run() {   # dry-run 预览 + 命令日志；与合并前行为一致
  if [[ "$DRY_RUN" == "yes" ]]; then
    printf '%s\n' "${C_DIM}[dry-run] $*${C_RESET}"
    return 0
  fi
  Logger::raw LOG "[CMD] $*"
  "$@"
}

# 系统 / 服务 / 数据库（统一走 lib 的对象）
detect_os() {
  step "识别操作系统"
  OS_ID="${SYS[id]}"; OS_VERSION="${SYS[version]}"
  OS_FAMILY="${SYS[family]}"; OS_PRETTY="${SYS[pretty]}"
  PKG="${SYS[pm]}";   ARCH="${SYS[arch]}"
  info "发行版：${OS_PRETTY}（family=${OS_FAMILY}, 包管理器=${PKG}, 架构=${ARCH}）"
  case "$ARCH" in
    x86_64|amd64|aarch64|arm64) : ;;
    *) warn "架构 ${ARCH} 可能不在 MariaDB 官方仓库支持范围内；若仓库配置失败请改用 --repo distro" ;;
  esac
  return 0
}

# 说明：以下 MariaDB 相关函数两侧语义不同，各自保留原实现（卸载侧加 u_ 前缀），
#       这里只提供「新脚本自己要用」的少量便捷封装。
detect_service_name_any() {   # 只读探测：返回 0 表示找到服务
  if Db::detect_service DB; then
    SERVICE_NAME="${DB[service]}"; SERVICE_EXISTS="yes"
  else
    SERVICE_NAME=""; SERVICE_EXISTS="no"
  fi
  return 0
}

generate_password(){ Db::gen_password "${1:-20}"; }
password_strength_note() { Db::strength_note "$1"; }

require_root() {
  if [[ "$(Sys::euid)" == "0" ]]; then return 0; fi
  if sys::has_cmd sudo; then
    info "需要 root 权限，改用 sudo 重新执行…"
    exec sudo -E bash "$0" ${ORIG_ARGS[@]+"${ORIG_ARGS[@]}"}
  fi
  die "请以 root 身份运行：sudo bash $0 $*"
}

# ---------------------------------------------------------------------------
# 安装侧：业务逻辑（原 install-mariadb-lts.sh）
# ---------------------------------------------------------------------------

install_usage() {
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

install_parse_args() {
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
      -h|--help)         install_usage; exit 0 ;;
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

run_install() {
  install_parse_args "$@"
  require_root
  mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
  if ! : >>"$LOG_FILE" 2>/dev/null; then LOG_FILE="/tmp/install-mariadb-lts.log"; fi
  mdb_init

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

# ---------------------------------------------------------------------------
# 卸载侧：业务逻辑（原 uninstall-mariadb-lts.sh）
# ---------------------------------------------------------------------------

u_usage() {
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

u_parse_args() {
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
      -h|--help)       u_usage; exit 0 ;;
      *) die "未知参数：$1（用 --help 查看用法）" ;;
    esac
  done
  return 0
}

u_detect_service_name() {
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
  u_detect_service_name
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

init_clients() {
  SQL_CLIENT="$(command -v mariadb || command -v mysql || true)"
  DUMP_CLIENT="$(command -v mariadb-dump || command -v mysqldump || true)"
  return 0
}

u_write_client_cnf() {
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
  cnf="$(u_write_client_cnf "$pw")"
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

u_sql_query() {
  local sql="$1" out="" rc=0 f cnf=""
  f="$(mktemp_tracked)"
  printf '%s\n' "$sql" >"$f"
  if [[ "$ADMIN_AUTH_MODE" == "password" ]]; then
    cnf="$(u_write_client_cnf "$ADMIN_PASSWORD")"
    out="$("$SQL_CLIENT" --defaults-extra-file="$cnf" -B -N <"$f" 2>&1)" || rc=$?
  else
    out="$("$SQL_CLIENT" --protocol=socket -u root -B -N <"$f" 2>&1)" || rc=$?
  fi
  if [[ -n "$cnf" ]]; then rm -f "$cnf"; fi
  rm -f "$f"
  printf '%s\n' "$out"
  return $rc
}

u_wizard() {
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

u_show_plan() {
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

u_confirm_plan() {
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
    local cnf; cnf="$(u_write_client_cnf "$ADMIN_PASSWORD")"
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
      u_sql_query "SHOW DATABASES;" 2>/dev/null || true
      printf '\n## mysql.user\n'
      u_sql_query "SELECT CONCAT(User,'@',Host), plugin FROM mysql.user ORDER BY 1;" 2>/dev/null || true
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

u_verify() {
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

u_summary() {
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

u_main() {
  u_parse_args "$@"
  require_root
  mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
  if ! : >>"$LOG_FILE" 2>/dev/null; then LOG_FILE="/tmp/uninstall-mariadb-lts.log"; fi
  mdb_init

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

  u_wizard
  u_show_plan
  u_confirm_plan

  do_backup
  if [[ "$BACKUP" != "yes" ]]; then stop_service; fi
  remove_packages
  remove_configs
  remove_repo
  remove_data
  remove_runtime_and_user
  u_verify
  u_summary
  return 0
}

# ===========================================================================
#  统一入口
# ===========================================================================
usage() {
  cat <<EOF
mariadb-manager.sh v${SCRIPT_VERSION} —— MariaDB LTS 一体化管理

用法：
  sudo bash ${SCRIPT_NAME} install   [选项]   安装并初始化 MariaDB LTS
  sudo bash ${SCRIPT_NAME} uninstall [选项]   卸载（默认先做逻辑备份）
  bash  ${SCRIPT_NAME} status                 只读体检
  sudo bash ${SCRIPT_NAME} menu               交互式向导
  bash  ${SCRIPT_NAME} help [install|uninstall]

 install 常用选项：
  --series 12.3|11.8|11.4|10.11   版本系列（默认 12.3）
  --repo official|distro          软件源（默认官方仓库）
  --port N                        监听端口（默认 3306）
  --root-password <密码>          root 口令
  --auto-password                 自动生成强口令
  --remote-root                   允许 root 远程登录
  --create-app-db                 额外创建业务库与专用账号
  --open-firewall                 放行防火墙端口
  --no-start                      装完不立即启动
  --no-autostart                  不注册开机自启
  --service-only                  只调整服务启停状态
  --reconfigure-only              只改配置，不装包
  --arch-pkg mariadb-lts|mariadb  Arch 系包名选择

 uninstall 常用选项：
  --purge-data                    连同数据目录一起删除（默认保留）
  --no-backup                     卸载前不做逻辑备份
  --keep-config                   保留配置文件
  --keep-repo                     保留官方仓库
  --keep-mycnf                    保留 /root/.my.cnf
  --remove-extras                 一并移除可选公共包
  --remove-user yes|no|follow     是否删除 mysql 系统用户

 通用选项：
  -y, --yes           自动确认非破坏性询问
  -n, --dry-run       只预览，不做任何改动
      --non-interactive  完全非交互
      --log FILE      指定日志文件

说明：
  * 卸载是破坏性操作，必须逐字输入 DELETE 确认；-y 不会跳过这道确认。
  * 被覆盖或删除的文件都会先备份到 ${BACKUP_DIR}。
  * 完整日志见 ${LOG_FILE}。
EOF
}

# 把 install / uninstall 各自的选项解析原样保留（分别叫 xxx_args / u_parse_args）
parse_args() {
  ACTION="${1:-}"
  [[ $# -gt 0 ]] && shift || true
  case "$ACTION" in
    install)   install_parse_args "$@" ;;
    uninstall) u_parse_args "$@" ;;
    *)         usage; exit 1 ;;
  esac
}

cmd_status() {
  Lib::bootstrap ""
  Logger::section LOG "MariaDB 体检（只读）"
  OS::summary SYS

  Db::new DB
  if ! Db::detect_service DB; then
    warn "未检测到 MariaDB / MySQL 服务（可能未安装）。"
    return 1
  fi
  SERVICE_NAME="${DB[service]}"
  Db::detect_paths DB

  Svc::new SVCOBJ "$SERVICE_NAME"
  printf '\n'
  Ui::table UI "服务状态" \
    "服务名|${SERVICE_NAME}" \
    "运行状态|$(Svc::status_line SVCOBJ)" \
    "数据目录|${DB[datadir]}" \
    "配置目录|${DB[conf_dir]}" \
    "socket|${DB[socket]:-（未探测到）}"
  printf '\n'

  if Db::test_local DB "${ADMIN_PASSWORD}"; then
    ok "可以用当前凭据登录（socket）"
    local v
    v="$(Db::query_scalar DB "SELECT VERSION();" 2>/dev/null || true)"
    [[ -n "$v" ]] && Ui::item UI "服务器版本" "$v" 2 20
  else
    warn "用当前凭据无法登录（未安装客户端 / 需要密码 / 服务未运行）。"
  fi
  return 0
}

cmd_menu() {
  Menu::new MM "MariaDB 管理" "请选择操作"
  Menu::add MM "安装 MariaDB LTS"            "install"   "向导式安装并初始化"
  Menu::add MM "卸载 MariaDB"                "uninstall" "可先做逻辑备份"
  Menu::add MM "只读体检"                    "status"    "版本 / 服务 / 数据目录"
  if ! Menu::run MM; then return 0; fi
  case "${MM[choice]}" in
    1) shift 0; install_parse_args "$@"; run_install ;;
    2) u_parse_args "$@"; u_main ;;
    3) cmd_status ;;
  esac
}

main() {
  local sub="${1:-}"
  case "$sub" in
    install|uninstall|status|menu|help)
      ACTION="$sub"; shift || true ;;
    -h|--help|"")
      usage; exit 0 ;;
    *)
      err "未知子命令：$sub"; usage; exit 1 ;;
  esac

  case "$ACTION" in
    help)
      if [[ "${1:-}" == "install" ]]; then install_usage
      elif [[ "${1:-}" == "uninstall" ]]; then u_usage
      else usage; fi
      exit 0 ;;
    status)
      cmd_status ;;
    install)
      LOG_FILE="/var/log/mariadb-manager-install.log"
      BACKUP_DIR="/var/backups/mariadb-install"
      install_parse_args "$@"
      run_install ;;
    uninstall)
      LOG_FILE="/var/log/mariadb-manager-uninstall.log"
      BACKUP_DIR="/var/backups/mariadb-uninstall"
      u_parse_args "$@"
      u_main ;;
    menu)
      cmd_menu "$@" ;;
  esac
}

main "$@"


# =============================================================================
#  面板声明（供 panel.sh 自动发现，不参与脚本执行）
# =============================================================================
# PANEL: MariaDB | 数据库 | 1 | 安装 / 卸载 / 体检一体化
# PANEL-CMD: 安装 MariaDB LTS | install | 向导式：版本、密码、远程、业务库
# PANEL-CMD: 卸载 MariaDB | uninstall | 可先做逻辑备份，需输入 DELETE 确认
# PANEL-CMD: 只读体检 | status | 版本 / 服务 / 数据目录 / 登录连通性
# PANEL-CMD: 交互式向导 | menu | 进入脚本自带菜单
# PANEL-CMD: 演练安装 | install --dry-run --non-interactive | 只打印，不做变更
