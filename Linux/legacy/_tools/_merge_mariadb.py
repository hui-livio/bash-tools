#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把 install-mariadb-lts.sh 与 uninstall-mariadb-lts.sh 合并为 mariadb-manager.sh。

策略（机械合并，不改写业务逻辑）：
  1. 两个脚本各自的函数按「函数头 → 顶格 }」切块
  2. 已被 lib/ 收敛的通用 helper 直接丢弃（日志/颜色/run/确认/disp_width/转义...）
  3. 安装侧函数保持原名；卸载侧中与安装侧重名的函数加 u_ 前缀
  4. usage / parse_args / main 由新脚本统一实现（install|uninstall|status|menu）
"""
import re
from pathlib import Path

BASE = Path(__file__).resolve().parent

# ---- 已被 lib/ 提供、合并时直接丢弃的函数（与业务无关的通用 helper）----
DROP = {
    # 颜色 / 日志 / 错误陷阱
    '_log_raw', 'log', 'info', 'ok', 'warn', 'err', 'die', 'step', 'on_error', 'cleanup',
    # 命令执行与查询
    'run', 'need_cmd', 'svc_is_active', 'svc_is_enabled', 'mktemp_tracked', 'retrim',
    # 显示与交互
    'disp_width', 'item', 'prompt', 'ask_yes_no', 'ask_feature', 'confirm_typed',
    'pause_for_confirm',
    # 转义 / 密码
    'cnf_escape', 'sql_escape', 'generate_password', 'password_strength_note',
    # 系统识别 / 权限
    'require_root', 'detect_os',
}

# 注意：MariaDB 客户端相关的函数两侧语义不同（安装侧要处理 ADMIN_AUTH_MODE 与交互取密码，
# 卸载侧是静默取数），不能强行统一，改为各自保留、卸载侧重名者加前缀。

# ---- 卸载侧与安装侧重名、需要加前缀的函数 ----
RENAME_UNINSTALL = {
    'usage': 'u_usage',
    'parse_args': 'u_parse_args',
    'main': 'u_main',
    'show_plan': 'u_show_plan',
    'verify': 'u_verify',
    'summary': 'u_summary',
    'wizard': 'u_wizard',
    'confirm_plan': 'u_confirm_plan',
    # 与安装侧同名但语义不同的 MariaDB 客户端函数
    'detect_service_name': 'u_detect_service_name',
    'write_client_cnf': 'u_write_client_cnf',
    'sql_query': 'u_sql_query',
}


def extract_functions(path: Path):
    """返回 [(name, body_lines)]，body 含函数头与结尾 }"""
    lines = path.read_text(encoding='utf-8').split('\n')
    fn_re = re.compile(r'^([A-Za-z_][A-Za-z0-9_]*)\(\)\s*(\{?)\s*(#.*)?$')
    funcs = []
    i, n = 0, len(lines)
    while i < n:
        m = fn_re.match(lines[i])
        if m and not lines[i].lstrip().startswith('#'):
            name = m.group(1)
            start = i
            # 单行函数（...; } 结尾）或块函数
            if lines[i].rstrip().endswith('}'):
                funcs.append((name, lines[start:i + 1]))
                i += 1
                continue
            j = i + 1
            while j < n and lines[j] != '}':
                j += 1
            if j >= n:
                raise SystemExit(f'{path.name}: 函数 {name} 未找到结尾 }}')
            funcs.append((name, lines[start:j + 1]))
            i = j + 1
            continue
        i += 1
    return funcs


def rename_in_body(body, mapping):
    """把 body 里出现的函数名替换为新名（只替换“被调用”的位置，函数头单独处理）"""
    out = []
    pat = re.compile(r'(?<![\w$])(' + '|'.join(sorted(mapping, key=len, reverse=True)) + r')(?![\w])')
    for k, line in enumerate(body):
        if k == 0:
            out.append(line)
            continue
        # 跳过注释行与纯字符串行，减少误伤
        stripped = line.lstrip()
        if stripped.startswith('#'):
            out.append(line)
            continue
        out.append(pat.sub(lambda m: mapping[m.group(1)], line))
    return out


HEADER = r'''#!/usr/bin/env bash
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
'''

MID = r'''
# ---------------------------------------------------------------------------
# 卸载侧：业务逻辑（原 uninstall-mariadb-lts.sh）
# ---------------------------------------------------------------------------
'''

TAIL = r'''
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
'''


def main():
    inst = extract_functions(BASE / 'install-mariadb-lts.sh')
    unin = extract_functions(BASE / 'uninstall-mariadb-lts.sh')

    # 在两个 main 里，日志文件确定之后插入 mdb_init（否则 Logger / 交互开关没就绪）
    for funcs in (inst, unin):
        for name, body in funcs:
            if name != 'main':
                continue
            for k, line in enumerate(body):
                if line.lstrip().startswith('if ! : >>"$LOG_FILE"'):
                    indent = line[:len(line) - len(line.lstrip())]
                    body.insert(k + 1, f'{indent}mdb_init')
                    break

    inst_names = {n for n, _ in inst}
    unin_names = {n for n, _ in unin}
    print(f'安装侧函数 {len(inst)} 个，卸载侧函数 {len(unin)} 个')

    # 安装侧：usage / parse_args / main 改为 install_ 前缀，由统一入口接管
    inst_rename = {'usage': 'install_usage', 'parse_args': 'install_parse_args', 'main': 'run_install'}

    parts = [HEADER]

    kept_inst, dropped = [], []
    for name, body in inst:
        if name in DROP:
            dropped.append(name); continue
        body = rename_in_body(body, inst_rename)
        if name in inst_rename:
            body[0] = body[0].replace(f'{name}()', f'{inst_rename[name]}()', 1)
        kept_inst.append('\n'.join(body))
    parts.append('\n\n'.join(kept_inst))
    parts.append(MID)

    # 卸载侧：丢弃通用 helper，重名加前缀
    rename_map = dict(RENAME_UNINSTALL)
    kept_unin = []
    for name, body in unin:
        if name in DROP:
            continue
        body = rename_in_body(body, rename_map)
        if name in rename_map:
            body[0] = body[0].replace(f'{name}()', f'{rename_map[name]}()', 1)
        kept_unin.append('\n'.join(body))
    parts.append('\n\n'.join(kept_unin))
    parts.append(TAIL)

    out = BASE / 'mariadb-manager.sh'
    out.write_text('\n'.join(parts), encoding='utf-8')
    print(f'已生成 {out.name}（{out.stat().st_size} 字节）')
    print(f'丢弃的通用 helper（{len(dropped)}）：{sorted(set(dropped))}')


if __name__ == '__main__':
    main()
