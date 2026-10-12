#!/usr/bin/env bash
# ============================================================================
# configure-mirrors.sh — 为 Arch Linux / Debian / Ubuntu 一键切换中国境内镜像源
#
# 支持镜像站: 清华大学(tuna) / 中国科学技术大学(ustc) / 阿里云(aliyun) / 华为云(huawei)
# 支持发行版: Arch Linux / Debian / Ubuntu (含 WSL)
#
# 常见用法:
#   sudo bash configure-mirrors.sh                 # 交互式菜单选择
#   sudo bash configure-mirrors.sh --auto          # 自动测速, 切换到最快镜像站
#   sudo bash configure-mirrors.sh --provider tuna # 直接指定镜像站
#   bash configure-mirrors.sh --dry-run --auto     # 试运行: 只打印, 不写盘(无需 root)
#   sudo bash configure-mirrors.sh --restore       # 回滚到最近一次备份
#   bash configure-mirrors.sh --show               # 只查看当前镜像源配置
#
# 回滚方式: 每次写盘前自动备份为 <原路径>.bak-<时间戳>, 用 --restore 即可恢复
# ============================================================================

set -Eeuo pipefail

VERSION="1.0.0"
ORIG_ARGS=("$@")

# ----------------------------------------------------------------------------
# 全局状态
# ----------------------------------------------------------------------------
ACTION="set"          # set | restore | show
PROVIDER=""           # 命令行指定的镜像站
AUTO=0                # 1 = 自动测速
DRY_RUN=0             # 1 = 试运行, 不写盘
NO_UPDATE=0           # 1 = 换源后不刷新索引
ASSUME_YES=0          # 1 = 自动确认"是否继续"类问题
SELECTED_PROVIDER=""  # 菜单选择的镜像站
FASTEST_PROVIDER=""   # 测速最快的镜像站
APT_TARGET=""         # apt 族的目标源文件
APT_FORMAT=""         # deb822 | oneline
LOG_FILE=""

OS_FAMILY=""          # arch | debian | ubuntu
CODENAME=""           # debian/ubuntu 代号
ARCH=""               # CPU 架构
OS_TITLE=""           # 系统显示名

# 调试用环境变量: MIRROR_ROOT_PREFIX / MIRROR_FORCE_OS / MIRROR_FORCE_CODENAME / MIRROR_LOG_FILE
ROOT_PREFIX="${MIRROR_ROOT_PREFIX:-}"
ARCH_MIRRORLIST="${ROOT_PREFIX}/etc/pacman.d/mirrorlist"
APT_SOURCES_LIST="${ROOT_PREFIX}/etc/apt/sources.list"
APT_SOURCES_D="${ROOT_PREFIX}/etc/apt/sources.list.d"
DEB822_DEBIAN="${APT_SOURCES_D}/debian.sources"
DEB822_UBUNTU="${APT_SOURCES_D}/ubuntu.sources"

SCRIPT_ABS="$(readlink -f "$0" 2>/dev/null)" || SCRIPT_ABS="$0"

# 镜像站定义
declare -gA PROV_NAME=(
  [tuna]="清华大学"
  [ustc]="中国科学技术大学"
  [aliyun]="阿里云"
  [huawei]="华为云"
)
declare -gA PROV_BASE=(
  [tuna]="https://mirrors.tuna.tsinghua.edu.cn"
  [ustc]="https://mirrors.ustc.edu.cn"
  [aliyun]="https://mirrors.aliyun.com"
  [huawei]="https://repo.huaweicloud.com"
)
PROV_ORDER=(tuna ustc aliyun huawei)

# ----------------------------------------------------------------------------
# 颜色与日志
# ----------------------------------------------------------------------------
__OPS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# shellcheck source=/dev/null
source "${__OPS_DIR}/lib/lib.sh"
unset __OPS_DIR
Lib::bootstrap "${MIRROR_LOG_FILE:-/var/log/china-mirrors.log}"
Lib::install_err_trap

# 说明：颜色、info/warn/die、日志落盘、ERR 陷阱全部由 lib/ 提供。
#       下面的 init_log 只在日志文件不可写时把它降级到 /tmp。

# ----------------------------------------------------------------------------
# 通用小工具
# ----------------------------------------------------------------------------

# 中文表格对齐（disp_width / item）沿用 lib/10-ui.sh 的实现，此处不再重复定义

# item() 由 lib/10-ui.sh 提供，列宽默认 26 与此处不同，统一到 26：
item() { Ui::item UI "$1" "$2" "${3:-2}" "${4:-26}"; }

confirm() { # 提示语; 返回 0 = 是（统一走 lib/10-ui.sh 的 Ui::confirm）
  local prompt="$1"
  if [[ "${ASSUME_YES:-0}" == "1" ]]; then
    info "$prompt —— 已通过 --yes 自动确认为[是]"
    return 0
  fi
  if [[ ! -t 0 ]]; then
    die "非交互环境无法确认「$prompt」, 请追加 --yes 参数"
  fi
  Ui::confirm UI "$prompt" n
}

init_log() {
  if [[ -z "${LOG_FILE:-}" ]]; then
    LOG_FILE="/tmp/china-mirrors.log"
    touch "$LOG_FILE" 2>/dev/null || LOG_FILE=""
    if [[ -n "$LOG_FILE" ]]; then LOG[file]="$LOG_FILE"; fi
  fi
  Logger::raw LOG "===== configure-mirrors.sh v${VERSION} 启动 ====="
  return 0
}

usage() {
  cat <<'EOF'
configure-mirrors.sh — 为 Arch Linux / Debian / Ubuntu 切换中国境内镜像源

用法:
  sudo bash configure-mirrors.sh                  交互式选择镜像站
  sudo bash configure-mirrors.sh --auto           自动测速, 使用最快镜像站
  sudo bash configure-mirrors.sh --provider tuna  直接指定镜像站
  sudo bash configure-mirrors.sh --restore        恢复最近一次备份
  bash  configure-mirrors.sh --show               查看当前镜像源配置
  bash  configure-mirrors.sh --dry-run --auto     试运行(只打印, 不写盘, 无需 root)

选项:
  --provider NAME   指定镜像站: tuna(清华) | ustc(中科大) | aliyun(阿里云) | huawei(华为云)
  --auto            对所有镜像站测速并选择最快的
  --dry-run         试运行: 只显示将要写入的内容, 不修改任何文件
  --no-update       换源后不刷新软件包索引
  --restore         把镜像配置回滚到最近一次备份
  --show            只查看当前配置, 不做修改
  --yes, -y         自动确认(仅用于"是否继续"类确认)
  -h, --help        显示本帮助
  --version         显示版本

支持的镜像站:
  tuna    清华大学         https://mirrors.tuna.tsinghua.edu.cn
  ustc    中国科学技术大学  https://mirrors.ustc.edu.cn
  aliyun  阿里云           https://mirrors.aliyun.com
  huawei  华为云           https://repo.huaweicloud.com

说明:
  * Arch Linux    写入 /etc/pacman.d/mirrorlist
  * Debian/Ubuntu 优先写 deb822 格式(/etc/apt/sources.list.d/*.sources, 新版默认),
                   否则写 /etc/apt/sources.list
  * 每次修改前自动备份为 <原路径>.bak-<时间戳>, 用 --restore 即可回滚
  * 只替换官方源; 第三方源(PPA 等)保持不动, 与旧官方源文件冲突时会停用旧文件并保留内容

环境变量(调试用, 一般无需设置):
  MIRROR_FORCE_OS=arch|debian|ubuntu  强制指定发行版
  MIRROR_FORCE_CODENAME=<代号>        强制指定发行版代号
  MIRROR_LOG_FILE=<路径>              日志位置(默认 /var/log/china-mirrors.log)
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --provider)
        [[ $# -ge 2 ]] || die "--provider 需要参数: tuna|ustc|aliyun|huawei"
        PROVIDER="$2"; shift 2 ;;
      --provider=*) PROVIDER="${1#*=}"; shift ;;
      --auto)        AUTO=1; shift ;;
      --dry-run)     DRY_RUN=1; shift ;;
      --no-update)   NO_UPDATE=1; shift ;;
      --restore)     ACTION="restore"; shift ;;
      --show)        ACTION="show"; shift ;;
      --yes|-y)      ASSUME_YES=1; shift ;;
      --help|-h)     usage; exit 0 ;;
      --version)     printf 'configure-mirrors.sh %s\n' "$VERSION"; exit 0 ;;
      *) die "未知参数: $1 (使用 --help 查看用法)" ;;
    esac
  done
  if [[ -n "$PROVIDER" ]]; then
    [[ -n "${PROV_NAME[$PROVIDER]+x}" ]] || die "未知镜像站: $PROVIDER (可选: tuna|ustc|aliyun|huawei)"
  fi
  return 0
}

# ----------------------------------------------------------------------------
# 系统检测
# ----------------------------------------------------------------------------

_osr() { # 从 os-release 取键值(去引号), 找不到则输出空
  local key="$1" line="" v=""
  while IFS= read -r line; do
    [[ "$line" == "$key="* ]] || continue
    v="${line#*=}"
    v="${v%\"}"; v="${v#\"}"; v="${v%\'}"; v="${v#\'}"
    printf '%s' "$v"
    return 0
  done <"${ROOT_PREFIX}/etc/os-release"
  return 0
}

detect_system() {
  OS_FAMILY="" CODENAME="" ARCH="" OS_TITLE=""
  ARCH="$(uname -m)"
  if [[ -n "${MIRROR_FORCE_OS:-}" ]]; then
    OS_FAMILY="$MIRROR_FORCE_OS"
    CODENAME="${MIRROR_FORCE_CODENAME:-}"
    OS_TITLE="手动指定(${OS_FAMILY})"
  else
    local rel="${ROOT_PREFIX}/etc/os-release"
    [[ -r "$rel" ]] || die "无法读取 $rel, 不能识别发行版"
    local id="" id_like="" cn="" pretty=""
    id="$(_osr ID)"
    id_like="$(_osr ID_LIKE)"
    cn="$(_osr VERSION_CODENAME)"
    pretty="$(_osr PRETTY_NAME)"
    [[ -n "$pretty" ]] || pretty="$id"
    OS_TITLE="$pretty"
    case "$id" in
      arch)   OS_FAMILY="arch" ;;
      ubuntu) OS_FAMILY="ubuntu"; CODENAME="$cn" ;;
      debian) OS_FAMILY="debian"; CODENAME="$cn" ;;
      manjaro|endeavouros|garuda|steamos)
        die "检测到 ${pretty}: 该发行版仓库结构与官方 Arch 不同, 本脚本不支持(未做任何修改)" ;;
      *)
        case " $id_like " in
          *"debian"*) OS_FAMILY="debian"; CODENAME="$cn" ;;
          *"arch"*)   OS_FAMILY="arch" ;;
        esac
        ;;
    esac
  fi
  [[ -n "$OS_FAMILY" ]] || die "无法识别的发行版(仅支持 Arch Linux / Debian / Ubuntu)"
  if [[ -z "${MIRROR_FORCE_OS:-}" ]]; then
    if [[ "$OS_FAMILY" == "arch" ]]; then
      command -v pacman >/dev/null 2>&1 || die "未找到 pacman 命令, 无法确认是 Arch 系统"
    else
      command -v apt-get >/dev/null 2>&1 || die "未找到 apt-get 命令, 无法确认是 Debian/Ubuntu 系统"
    fi
  fi
  if [[ "$OS_FAMILY" != "arch" ]]; then
    if [[ -z "$CODENAME" ]]; then
      CODENAME="$(lsb_release -cs 2>/dev/null || true)"
    fi
    [[ -n "$CODENAME" ]] || die "无法确定发行版代号(codename), 可用环境变量 MIRROR_FORCE_CODENAME=<代号> 指定"
  fi
  local cn_show=""
  [[ "$OS_FAMILY" != "arch" ]] && cn_show="  代号: ${CODENAME}"
  info "检测到系统: ${OS_TITLE}  架构: ${ARCH}${cn_show}"
  _log_raw "SYSTEM: family=${OS_FAMILY} codename=${CODENAME} arch=${ARCH}"
  return 0
}

# ----------------------------------------------------------------------------
# 源文件内容生成
# ----------------------------------------------------------------------------

debian_components() { # bookworm 起需要 non-free-firmware
  case "$1" in
    stretch|buster|bullseye) printf 'main contrib non-free' ;;
    *)                       printf 'main contrib non-free non-free-firmware' ;;
  esac
}

_keyring() { # 输出存在的密钥环路径, 不存在则输出空
  local p=""
  if [[ "$1" == "debian" ]]; then
    p="${ROOT_PREFIX}/usr/share/keyrings/debian-archive-keyring.gpg"
  else
    p="${ROOT_PREFIX}/usr/share/keyrings/ubuntu-archive-keyring.gpg"
  fi
  [[ -f "$p" ]] && printf '%s' "$p"
  return 0
}

gen_arch_content() { # $1 = 镜像站
  local prov="$1" base p
  base="${PROV_BASE[$prov]}"
  printf '# 由 configure-mirrors.sh 生成于 %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
  printf '# 当前镜像站: %s (%s)\n\n' "${PROV_NAME[$prov]}" "$prov"
  printf 'Server = %s/archlinux/$repo/os/$arch\n\n' "$base"
  printf '# 以下为备用镜像站, 需要时注释掉上面的 Server 并去掉对应行的 # :\n'
  for p in "${PROV_ORDER[@]}"; do
    [[ "$p" == "$prov" ]] && continue
    printf '#Server = %s/archlinux/$repo/os/$arch\n' "${PROV_BASE[$p]}"
  done
  return 0
}

gen_deb822_debian() { # $1 = 镜像站
  local prov="$1" base comp sign
  base="${PROV_BASE[$prov]}"
  comp="$(debian_components "$CODENAME")"
  sign="$(_keyring debian)"
  printf '# 由 configure-mirrors.sh 生成于 %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
  printf '# 镜像站: %s (%s)\n\n' "${PROV_NAME[$prov]}" "$prov"
  printf 'Types: deb\nURIs: %s/debian\nSuites: %s %s-updates %s-backports\nComponents: %s\n' \
    "$base" "$CODENAME" "$CODENAME" "$CODENAME" "$comp"
  [[ -n "$sign" ]] && printf 'Signed-By: %s\n' "$sign"
  printf '\nTypes: deb\nURIs: %s/debian-security\nSuites: %s-security\nComponents: %s\n' \
    "$base" "$CODENAME" "$comp"
  [[ -n "$sign" ]] && printf 'Signed-By: %s\n' "$sign"
  printf '\n# 如需源码包, 把上面的 Types: deb 改为: Types: deb deb-src\n'
  return 0
}

gen_deb822_ubuntu() { # $1 = 镜像站
  local prov="$1" base sign
  base="${PROV_BASE[$prov]}"
  sign="$(_keyring ubuntu)"
  printf '# 由 configure-mirrors.sh 生成于 %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
  printf '# 镜像站: %s (%s)\n\n' "${PROV_NAME[$prov]}" "$prov"
  printf 'Types: deb\nURIs: %s/ubuntu\nSuites: %s %s-updates %s-backports\nComponents: main restricted universe multiverse\n' \
    "$base" "$CODENAME" "$CODENAME" "$CODENAME"
  [[ -n "$sign" ]] && printf 'Signed-By: %s\n' "$sign"
  printf '\nTypes: deb\nURIs: %s/ubuntu\nSuites: %s-security\nComponents: main restricted universe multiverse\n' \
    "$base" "$CODENAME"
  [[ -n "$sign" ]] && printf 'Signed-By: %s\n' "$sign"
  printf '\n# 如需源码包, 把上面的 Types: deb 改为: Types: deb deb-src\n'
  return 0
}

gen_oneline_debian() { # $1 = 镜像站
  local prov="$1" base comp
  base="${PROV_BASE[$prov]}"
  comp="$(debian_components "$CODENAME")"
  printf '# 由 configure-mirrors.sh 生成于 %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
  printf '# 镜像站: %s (%s)\n\n' "${PROV_NAME[$prov]}" "$prov"
  printf 'deb %s/debian %s %s\n'               "$base" "$CODENAME" "$comp"
  printf 'deb %s/debian %s-updates %s\n'       "$base" "$CODENAME" "$comp"
  printf 'deb %s/debian-security %s-security %s\n' "$base" "$CODENAME" "$comp"
  printf 'deb %s/debian %s-backports %s\n'     "$base" "$CODENAME" "$comp"
  printf '\n# 如需源码包, 去掉下行行首的 # :\n'
  printf '#deb-src %s/debian %s %s\n' "$base" "$CODENAME" "$comp"
  return 0
}

gen_oneline_ubuntu() { # $1 = 镜像站
  local prov="$1" base
  base="${PROV_BASE[$prov]}"
  printf '# 由 configure-mirrors.sh 生成于 %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
  printf '# 镜像站: %s (%s)\n\n' "${PROV_NAME[$prov]}" "$prov"
  printf 'deb %s/ubuntu %s main restricted universe multiverse\n'          "$base" "$CODENAME"
  printf 'deb %s/ubuntu %s-security main restricted universe multiverse\n' "$base" "$CODENAME"
  printf 'deb %s/ubuntu %s-updates main restricted universe multiverse\n'  "$base" "$CODENAME"
  printf 'deb %s/ubuntu %s-backports main restricted universe multiverse\n' "$base" "$CODENAME"
  printf '\n# 如需源码包, 去掉下行行首的 # :\n'
  printf '#deb-src %s/ubuntu %s main restricted universe multiverse\n' "$base" "$CODENAME"
  return 0
}

gen_deb822_content() {
  if [[ "$OS_FAMILY" == "debian" ]]; then
    gen_deb822_debian "$1"
  else
    gen_deb822_ubuntu "$1"
  fi
}

gen_oneline_content() {
  if [[ "$OS_FAMILY" == "debian" ]]; then
    gen_oneline_debian "$1"
  else
    gen_oneline_ubuntu "$1"
  fi
}

# ----------------------------------------------------------------------------
# 备份 / 写入 / 冲突处理 / 恢复
# ----------------------------------------------------------------------------

pick_apt_target() { # 选择 apt 族目标文件: 优先 deb822
  APT_TARGET="" APT_FORMAT=""
  local f822=""
  if [[ "$OS_FAMILY" == "debian" ]]; then
    f822="$DEB822_DEBIAN"
  else
    f822="$DEB822_UBUNTU"
  fi
  if [[ -f "$f822" ]]; then
    APT_TARGET="$f822"; APT_FORMAT="deb822"
  else
    APT_TARGET="$APT_SOURCES_LIST"; APT_FORMAT="oneline"
  fi
  return 0
}

backup_file() { # $1 = 目标文件
  local f="$1" bak=""
  if [[ ! -e "$f" ]]; then
    warn "目标文件不存在, 跳过备份: $f"
    return 0
  fi
  bak="$f.bak-$(date +%Y%m%d-%H%M%S)"
  cp -a "$f" "$bak"
  info "已备份: $f -> $bak"
  _log_raw "BACKUP: $f -> $bak"
  return 0
}

write_file() { # $1 = 内容  $2 = 目标文件
  local content="$1" target="$2" dir=""
  dir="$(dirname "$target")"
  if [[ "$DRY_RUN" == "1" ]]; then
    info "【试运行】将写入: $target"
    printf '%s\n' "$content"
    return 0
  fi
  mkdir -p "$dir"
  backup_file "$target"
  printf '%s\n' "$content" >"$target"
  chmod 644 "$target"
  info "已写入: $target"
  _log_raw "WRITE: $target"
  return 0
}

conflicting_source_file() { # 返回与目标冲突且含有效条目的旧文件路径(无则输出空)
  local other=""
  if [[ "$APT_TARGET" == *.sources ]]; then
    other="$APT_SOURCES_LIST"
  elif [[ "$OS_FAMILY" == "debian" ]]; then
    other="$DEB822_DEBIAN"
  else
    other="$DEB822_UBUNTU"
  fi
  [[ -f "$other" ]] || return 0
  if [[ "$other" == *.sources ]]; then
    grep -qE '^[[:space:]]*Types:' "$other" || return 0
  else
    grep -qE '^[[:space:]]*deb([[:space:]]|$)' "$other" || return 0
  fi
  printf '%s' "$other"
  return 0
}

disable_conflicting_sources() { # 停用与目标文件冲突的旧官方源文件(内容保留)
  local other="" dis=""
  other="$(conflicting_source_file)" || true
  [[ -n "$other" ]] || return 0
  if [[ "$other" != *.sources ]] && grep -qE '^[[:space:]]*deb[[:space:]].*launchpad' "$other"; then
    warn "检测到 $other 中含第三方源(PPA); 该文件将被整体停用(内容保留), 如需保留 PPA 请之后从备份文件恢复相应行"
  fi
  if [[ "$DRY_RUN" == "1" ]]; then
    info "【试运行】将停用冲突源文件: $other"
    return 0
  fi
  dis="$other.disabled-$(date +%Y%m%d-%H%M%S)"
  mv "$other" "$dis"
  info "已停用冲突源文件(原内容保留): $other -> $dis"
  _log_raw "DISABLE: $other -> $dis"
  return 0
}

do_restore() {
  local files=() f="" baks="" latest="" found=0 cmd=""
  case "$OS_FAMILY" in
    arch)   files=("$ARCH_MIRRORLIST") ;;
    debian) files=("$DEB822_DEBIAN" "$APT_SOURCES_LIST") ;;
    ubuntu) files=("$DEB822_UBUNTU" "$APT_SOURCES_LIST") ;;
  esac
  for f in "${files[@]}"; do
    baks="$(ls -1 "$f".bak-* 2>/dev/null)" || baks=""
    [[ -n "$baks" ]] || continue
    latest="$(printf '%s\n' "$baks" | tail -n 1)"
    found=1
    if [[ "$DRY_RUN" == "1" ]]; then
      info "【试运行】将恢复: $latest -> $f"
      continue
    fi
    backup_file "$f"
    cp -a "$latest" "$f"
    info "已恢复: $latest -> $f"
    _log_raw "RESTORE: $latest -> $f"
  done
  if [[ "$found" -eq 0 ]]; then
    warn "未找到任何备份文件(形如 *.bak-<时间戳>)"
    return 0
  fi
  [[ "$OS_FAMILY" == "arch" ]] && cmd="pacman -Syy" || cmd="apt-get update"
  info "恢复完成; 建议刷新索引: $cmd"
  return 0
}

# ----------------------------------------------------------------------------
# 测速与菜单
# ----------------------------------------------------------------------------

probe_url() { # $1 = 发行版族  $2 = 镜像站 → 探测 URL
  local fam="$1" prov="$2" base=""
  base="${PROV_BASE[$prov]}"
  case "$fam" in
    arch)   printf '%s/archlinux/core/os/%s/core.db' "$base" "$ARCH" ;;
    debian) printf '%s/debian/dists/%s/Release' "$base" "$CODENAME" ;;
    ubuntu) printf '%s/ubuntu/dists/%s/Release' "$base" "$CODENAME" ;;
  esac
  return 0
}

speed_test_pick() { # 并行测速, 设置 FASTEST_PROVIDER
  local fam="$OS_FAMILY" p="" url="" tmpd="" t="" results="" ranked="" best_line="" best=""
  command -v curl >/dev/null 2>&1 || die "未安装 curl, 无法测速; 请用 --provider 手动指定镜像站"
  tmpd="$(mktemp -d)"
  info "正在对 4 个镜像站测速(每个最多约 8 秒, 请稍候)..."
  for p in "${PROV_ORDER[@]}"; do
    url="$(probe_url "$fam" "$p")"
    (
      trap - ERR
      t=""
      t="$(curl -sL -o /dev/null -w '%{time_total}' --connect-timeout 4 -m 8 -r 0-0 "$url" 2>/dev/null)" || t=""
      printf '%s' "$t" >"${tmpd}/${p}"
    ) &
  done
  wait || true
  printf '\n测速结果(耗时, 越小越快):\n'
  for p in "${PROV_ORDER[@]}"; do
    t=""
    t="$(cat "${tmpd}/${p}" 2>/dev/null)" || t=""
    if [[ -z "$t" ]]; then
      item "${PROV_NAME[$p]}(${p})" "不可达/超时" 2 28
      continue
    fi
    item "${PROV_NAME[$p]}(${p})" "${t} 秒" 2 28
    results+="${t} ${p}\n"
  done
  if [[ -z "$results" ]]; then
    die "所有镜像站均不可达(本机可能未联网或有防火墙限制); 可改用 --provider 手动指定"
  fi
  ranked="$(printf '%b' "$results" | sort -g)" || ranked=""
  best_line="${ranked%%$'\n'*}"
  best="${best_line##* }"
  info "最快镜像站: ${PROV_NAME[$best]} (${best})"
  FASTEST_PROVIDER="$best"
  return 0
}

menu_pick() { # 设置 SELECTED_PROVIDER
  if [[ ! -t 0 ]]; then
    die "非交互环境: 请用 --provider <tuna|ustc|aliyun|huawei> 或 --auto 指定镜像站"
  fi
  local reply="" prov="" i=1 p=""
  printf '\n可选镜像站:\n'
  for p in "${PROV_ORDER[@]}"; do
    item "[${i}] ${PROV_NAME[$p]}(${p})" "${PROV_BASE[$p]}" 2 34
    i=$((i+1))
  done
  printf '\n'
  item "[a] 自动测速" "对以上镜像站测速并选择最快" 2 34
  item "[r] 恢复备份" "回滚到最近一次备份" 2 34
  item "[q] 退出" "不做任何修改" 2 34
  while true; do
    read -r -p "请选择: " reply || die "已取消"
    case "$reply" in
      1) prov="tuna"; break ;;
      2) prov="ustc"; break ;;
      3) prov="aliyun"; break ;;
      4) prov="huawei"; break ;;
      a|A) speed_test_pick; prov="$FASTEST_PROVIDER"; break ;;
      r|R) do_restore; exit 0 ;;
      q|Q) info "已退出, 未做任何修改"; exit 0 ;;
      *) printf '无效选择: %s\n' "$reply" >&2 ;;
    esac
  done
  SELECTED_PROVIDER="$prov"
  return 0
}

# ----------------------------------------------------------------------------
# 主流程
# ----------------------------------------------------------------------------

run_cmd() { # 执行外部命令, 输出同时落日志; 失败不中止(源文件已改, 提示可回滚)
  local rc=0
  info "执行: $*"
  _log_raw "----- EXEC: $* -----"
  set +e
  _TOLERANT=1
  "$@" 2>&1 | tee -a "$LOG_FILE"
  rc=${PIPESTATUS[0]}
  _TOLERANT=0
  set -e
  _log_raw "----- 退出码: ${rc} -----"
  if [[ "$rc" -ne 0 ]]; then
    warn "命令失败(退出码 ${rc}); 源文件已修改, 如有异常可用 --restore 回滚"
  fi
  return 0
}

refresh_index() {
  local cmd=""
  if [[ "$OS_FAMILY" == "arch" ]]; then cmd="pacman -Syy"; else cmd="apt-get update"; fi
  if [[ "$NO_UPDATE" == "1" ]]; then
    info "已按 --no-update 跳过索引刷新; 之后可手动执行: $cmd"
    return 0
  fi
  if [[ "$DRY_RUN" == "1" ]]; then
    info "【试运行】此处会执行: $cmd"
    return 0
  fi
  if ! confirm "是否立即刷新软件包索引(${cmd})?"; then
    info "已跳过索引刷新; 建议尽快手动执行: $cmd"
    return 0
  fi
  if [[ "$OS_FAMILY" == "arch" ]]; then
    run_cmd pacman -Syy
  else
    run_cmd apt-get update
  fi
  return 0
}

after_notes() {
  local cmd=""
  if [[ "$OS_FAMILY" == "arch" ]]; then cmd="pacman -Syy"; else cmd="apt-get update"; fi
  printf '\n%s\n' "${C_B}-------------------- 完成 --------------------${C_0}"
  info "若刚才跳过了索引刷新, 可手动执行: ${cmd}"
  info "回滚: sudo bash $0 --restore  (备份在原文件旁, 后缀 .bak-<时间戳>)"
  info "日志: ${LOG_FILE}"
  return 0
}

do_show() {
  printf '系统: %s | 架构: %s | 族: %s\n' "$OS_TITLE" "$ARCH" "$OS_FAMILY"
  local f=""
  if [[ "$OS_FAMILY" == "arch" ]]; then
    printf '\n%s 的 Server 行:\n' "$ARCH_MIRRORLIST"
    if grep -E '^[[:space:]]*Server' "$ARCH_MIRRORLIST" 2>/dev/null; then
      :
    else
      printf '  (无 Server 行或文件不存在)\n'
    fi
  else
    pick_apt_target
    printf '\n换源时将写入: %s (%s)\n' "$APT_TARGET" "$APT_FORMAT"
    printf '\n当前 APT 源配置(非注释行):\n'
    for f in "$APT_SOURCES_LIST" "$APT_SOURCES_D"/*.sources "$APT_SOURCES_D"/*.list; do
      [[ -f "$f" ]] || continue
      printf '\n-- %s --\n' "$f"
      { grep -vE '^[[:space:]]*(#|$)' "$f" 2>/dev/null | sed 's/^/  /' || true; } || true
    done
  fi
  printf '\n'
  return 0
}

ensure_root() {
  if [[ "$(id -u)" -eq 0 ]]; then return 0; fi
  warn "当前非 root 用户"
  if command -v sudo >/dev/null 2>&1; then
    info "尝试通过 sudo 重新执行..."
    exec sudo -E bash "$SCRIPT_ABS" "${ORIG_ARGS[@]}"
  fi
  die "请以 root 运行: sudo bash $0 ${ORIG_ARGS[*]}"
}

do_set() {
  local prov="" content="" target="" fmt="" other=""
  if [[ -n "$PROVIDER" ]]; then
    prov="$PROVIDER"
    info "已指定镜像站: ${PROV_NAME[$prov]} (${prov})"
  elif [[ "$AUTO" == "1" ]]; then
    speed_test_pick
    prov="$FASTEST_PROVIDER"
  else
    menu_pick
    prov="$SELECTED_PROVIDER"
  fi
  [[ -n "$prov" ]] || die "未能确定镜像站"

  if [[ "$OS_FAMILY" == "arch" ]]; then
    target="$ARCH_MIRRORLIST"
    content="$(gen_arch_content "$prov")"
    fmt="pacman mirrorlist"
  else
    pick_apt_target
    target="$APT_TARGET"
    if [[ "$APT_FORMAT" == "deb822" ]]; then
      content="$(gen_deb822_content "$prov")"
      fmt="deb822 (.sources)"
    else
      content="$(gen_oneline_content "$prov")"
      fmt="单行 deb (sources.list)"
    fi
  fi

  printf '\n目标文件: %s\n' "$target"
  printf '镜像站: %s (%s)  格式: %s\n' "${PROV_NAME[$prov]}" "$prov" "$fmt"
  if [[ "$OS_FAMILY" != "arch" ]]; then
    other="$(conflicting_source_file)" || true
    if [[ -n "$other" ]]; then
      printf '同时将停用冲突源文件(内容保留): %s\n' "$other"
    fi
  fi
  printf '\n%s\n' "---- 新配置预览 ----"
  printf '%s\n' "$content"
  printf '%s\n' "--------------------"
  if ! confirm "确认写入并切换镜像源?"; then
    info "已取消, 未做任何修改"
    return 0
  fi
  write_file "$content" "$target"
  if [[ "$OS_FAMILY" != "arch" ]]; then
    disable_conflicting_sources
  fi
  refresh_index
  after_notes
  return 0
}

banner() {
  printf '%s\n' "${C_B}============================================================${C_0}"
  printf '%s\n' "${C_B}  中国镜像源一键配置工具 v${VERSION}  (Arch/Debian/Ubuntu)${C_0}"
  printf '%s\n' "${C_B}============================================================${C_0}"
  return 0
}

main() {
  parse_args "$@"
  init_log
  banner
  detect_system
  if [[ "$ACTION" != "show" && "$DRY_RUN" != "1" ]]; then
    ensure_root
  fi
  case "$ACTION" in
    show)    do_show ;;
    restore) do_restore ;;
    set)     do_set ;;
  esac
  return 0
}

main "$@"


# =============================================================================
#  面板声明（供 panel.sh 自动发现，不参与脚本执行）
# =============================================================================
# PANEL: 镜像源配置 | 软件源 | 1 | Arch / Debian / Ubuntu 切换国内镜像
# PANEL-CMD: 自动测速换源 | --auto | 并行测速，切到最快镜像站
# PANEL-CMD: 手动选择镜像站 |  | 交互式菜单挑选 tuna/ustc/aliyun/huawei
# PANEL-CMD: 查看当前配置 | --show | 只读
# PANEL-CMD: 回滚到上一次备份 | --restore | 恢复 <原路径>.bak-<时间戳>
