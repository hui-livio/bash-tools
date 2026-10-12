#!/usr/bin/env bash
# ============================================================================
# update-system.sh —— 多 Linux 发行版通用的「仓库索引 + 软件包」更新脚本
#
# 支持：Debian/Ubuntu/Deepin/UOS/麒麟（apt）、
#       RHEL/CentOS/Rocky/Alma/Fedora/openEuler/Anolis（dnf|yum）、
#       openSUSE/SLES（zypper）、Arch/Manjaro（pacman）、Alpine（apk）
#
# 用法：
#   bash update-system.sh              # 交互式：刷新索引 + 升级软件包
#   bash update-system.sh -y           # 免确认，直接执行
#   bash update-system.sh --check      # 只检查可升级项，不做任何更改
#   bash update-system.sh --no-clean   # 升级后不清理下载缓存
#   bash update-system.sh --full       # apt 系使用 full-upgrade（允许卸载冲突包）
#   bash update-system.sh -h           # 帮助
#
# 日志：/var/log/update-system-<时间戳>.log
# ============================================================================
set -Eeuo pipefail

# ---------------------------- 全局状态 ----------------------------
SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
TS="$(date '+%Y%m%d-%H%M%S')"
LOG_DIR="/var/log"
LOG_FILE="${LOG_DIR}/update-system-${TS}.log"
AUTO_YES=0
CHECK_ONLY=0
DO_CLEAN=1
FULL_UPGRADE=0
PM=""            # 检测到的包管理器：apt/dnf/yum/zypper/pacman/apk
OS_NAME="未知"
OS_VER=""
_TOLERANT=0      # 错误陷阱容忍标志：临时段置 1，结束前复位为 0
_RUN_RC=0        # run 包装函数记录的实际退出码

# 升级结果统计
UPGRADED_NOTE=""
REFRESH_OK=0     # 1=索引刷新成功 2=部分失败 0=失败
UPGRADE_RC=0

# ---------------------------- 日志输出 ----------------------------
__OPS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# shellcheck source=/dev/null
source "${__OPS_DIR}/lib/lib.sh"
unset __OPS_DIR
Lib::bootstrap "$LOG_FILE"
LOG_FILE="${LOG[file]:-/dev/null}"
Lib::install_err_trap
UI[assume_yes]="$AUTO_YES"

# ---------------------------- 通用工具 ----------------------------
usage() {
    cat <<EOF
用法：${SCRIPT_NAME} [选项]

选项：
  -y          免确认模式（跳过所有"是否继续"询问）
  --check     只检查可升级的软件包并列表，不做任何更改
  --no-clean  升级完成后不清理包管理器下载缓存
  --full      apt 系使用 full-upgrade / zypper 使用 dist-upgrade
              （允许卸载有依赖冲突的旧包；pacman 本身即同步完整升级）
  -h, --help  显示本帮助

说明：
  * 需要 root 权限（脚本会自动尝试 sudo）。
  * 兼容发行版：
      - Debian / Ubuntu / Deepin / UOS / 麒麟          (apt)
      - RHEL / CentOS / Rocky / Alma / Fedora / openEuler (dnf 或 yum)
      - openSUSE / SLES                                (zypper)
      - Arch / Manjaro / EndeavourOS                   (pacman)
      - Alpine Linux                                   (apk)
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -y|--yes)     AUTO_YES=1 ;;
            --check)      CHECK_ONLY=1 ;;
            --no-clean)   DO_CLEAN=0 ;;
            --full)       FULL_UPGRADE=1 ;;
            -h|--help)    usage; exit 0 ;;
            *)            err "未知参数：$1"; usage; exit 2 ;;
        esac
        shift
    done
}

need_root() {
    if [[ "$(Sys::euid)" -eq 0 ]]; then return 0; fi
    if sys::has_cmd sudo; then
        info "当前不是 root，尝试通过 sudo 提权后重新运行……"
        exec sudo -E bash "$0" ${ORIG_ARGS[@]+"${ORIG_ARGS[@]}"}
    fi
    die "请用 root 身份运行：sudo bash ${SCRIPT_NAME}"
}

confirm() {
    # $1 = 提示文字；-y 时自动同意（由 Ui::confirm 统一处理）
    if [[ "$AUTO_YES" -eq 1 ]]; then
        info "已启用 -y，自动确认：$1"
        return 0
    fi
    Ui::confirm UI "$1" n
}

# 统一的命令执行包装：输出同时落终端 + 日志；失败默认警告不中止
# 用法：run "说明" 命令 参数...
run() {
    local desc="$1"; shift
    info "$desc"
    _log_raw "EXEC: $*"
    local rc=0
    _TOLERANT=1; set +e
    "$@" 2>&1 | tee -a "$LOG_FILE"
    _RUN_RC=${PIPESTATUS[0]}
    set -e; _TOLERANT=0
    return 0    # 调用方通过 $_RUN_RC 检查实际退出码
}

# ---------------------------- 系统识别 ----------------------------
# 发行版 / 版本 / 包管理器统一由 lib/20-os.sh 的 OS 对象提供：
#   SYS[pretty] SYS[version] SYS[pm] SYS[family] SYS[arch]
detect_os() {
    OS_NAME="${SYS[name]}"
    OS_VER="${SYS[version]}"
}

detect_pm() {
    PM="${SYS[pm]}"
    if [[ -z "$PM" ]]; then
        die "未识别到任何受支持的包管理器（apt/dnf/yum/zypper/pacman/apk）。"
    fi
}

detect_pm() {
    if command -v apt-get >/dev/null 2>&1; then
        PM="apt"
    elif command -v dnf >/dev/null 2>&1; then
        PM="dnf"
    elif command -v yum >/dev/null 2>&1; then
        PM="yum"
    elif command -v zypper >/dev/null 2>&1; then
        PM="zypper"
    elif command -v pacman >/dev/null 2>&1; then
        PM="pacman"
    elif command -v apk >/dev/null 2>&1; then
        PM="apk"
    else
        err "未识别到任何受支持的包管理器（apt/dnf/yum/zypper/pacman/apk）。"
        exit 1
    fi
}

# ---------------------------- 索引刷新 ----------------------------
refresh_index() {
    step "刷新软件仓库索引"
    local rc=0
    case "$PM" in
        apt)
            _TOLERANT=1; set +e
            DEBIAN_FRONTEND=noninteractive apt-get update 2>&1 | tee -a "$LOG_FILE"
            rc=${PIPESTATUS[0]}
            set -e; _TOLERANT=0
            ;;
        dnf)
            # dnf5 / dnf4 均支持 makecache
            run "生成 dnf 元数据缓存" dnf -y makecache
            rc="$_RUN_RC"
            ;;
        yum)
            run "生成 yum 元数据缓存" yum makecache fast
            rc="$_RUN_RC"
            if [[ "$rc" -ne 0 ]]; then
                run "回退尝试：生成 yum 元数据缓存（不带 fast）" yum makecache
                rc="$_RUN_RC"
            fi
            ;;
        zypper)
            run "刷新 zypper 仓库" zypper --non-interactive refresh
            rc="$_RUN_RC"
            ;;
        pacman)
            # Arch 必须与升级命令一起做 -Sy，单独 -Sy 后不升级属于部分升级（有风险），
            # 这里只检查网络可达性，真正的同步放到 upgrade 阶段统一执行。
            info "Arch 系将在升级阶段统一执行『pacman -Syu』（避免部分升级风险）。"
            rc=0
            ;;
        apk)
            run "刷新 apk 仓库索引" apk update
            rc=$?
            ;;
    esac
    if [[ "$rc" -eq 0 ]]; then
        REFRESH_OK=1
        info "仓库索引刷新成功。"
    else
        REFRESH_OK=2
        warn "仓库索引刷新返回非 0（退出码 ${rc}），可能是部分镜像源暂不可达。"
        warn "脚本会尝试继续升级，但若列出升级清单为空，请检查网络与软件源配置。"
    fi
    return 0
}

# ---------------------------- 可升级检查 ----------------------------
check_upgradable() {
    step "检查可升级的软件包"
    case "$PM" in
        apt)
            apt list --upgradable 2>/dev/null | tail -n +2 >"$LOG_FILE.upgradable" || true
            ;;
        dnf|yum)
            # 注意：dnf check-update 有更新时退出码为 100，属正常
            local rc=0
            _TOLERANT=1; set +e
            "$PM" check-update -q 2>&1 | tee "$LOG_FILE.upgradable"
            rc=${PIPESTATUS[0]}
            set -e; _TOLERANT=0
            if [[ "$rc" -eq 100 ]]; then rc=0; fi
            ;;
        zypper)
            zypper --non-interactive list-updates 2>&1 | tee "$LOG_FILE.upgradable" || true
            ;;
        pacman)
            # 用 checkupdates（pacman-contrib）在临时数据库里检查，避免裸 -Sy 造成部分升级风险；
            # 没有该工具时退回只读的 pacman -Qu（可能基于较旧的本地索引）。
            if command -v checkupdates >/dev/null 2>&1; then
                checkupdates 2>/dev/null >"$LOG_FILE.upgradable" || true
            else
                pacman -Qu 2>/dev/null >"$LOG_FILE.upgradable" || true
            fi
            ;;
        apk)
            apk version -l '<' 2>&1 | tee "$LOG_FILE.upgradable" || true
            ;;
    esac
    local n=0
    if [[ -s "$LOG_FILE.upgradable" ]]; then
        n="$(grep -cve '^[[:space:]]*$' "$LOG_FILE.upgradable" || true)"
    fi
    if [[ "$n" -gt 0 ]]; then
        info "共有 ${n} 条可升级记录，明细见：${LOG_FILE}.upgradable"
    else
        info "当前没有可升级的软件包。"
    fi
    return 0
}

# ---------------------------- 执行升级 ----------------------------
do_upgrade() {
    step "升级全部软件包"
    local rc=0
    case "$PM" in
        apt)
            if [[ "$FULL_UPGRADE" -eq 1 ]]; then
                _TOLERANT=1; set +e
                DEBIAN_FRONTEND=noninteractive apt-get -y dist-upgrade 2>&1 | tee -a "$LOG_FILE"
                rc=${PIPESTATUS[0]}
                set -e; _TOLERANT=0
            else
                _TOLERANT=1; set +e
                DEBIAN_FRONTEND=noninteractive apt-get -y upgrade 2>&1 | tee -a "$LOG_FILE"
                rc=${PIPESTATUS[0]}
                set -e; _TOLERANT=0
            fi
            ;;
        dnf)
            run "dnf 升级全部软件包" dnf -y upgrade
            rc="$_RUN_RC"
            ;;
        yum)
            run "yum 升级全部软件包" yum -y update
            rc="$_RUN_RC"
            ;;
        zypper)
            if [[ "$FULL_UPGRADE" -eq 1 ]]; then
                run "zypper 发行版级升级" zypper --non-interactive dist-upgrade
            else
                run "zypper 升级全部软件包" zypper --non-interactive update
            fi
            rc="$_RUN_RC"
            ;;
        pacman)
            _TOLERANT=1; set +e
            pacman -Syu --noconfirm 2>&1 | tee -a "$LOG_FILE"
            rc=${PIPESTATUS[0]}
            set -e; _TOLERANT=0
            ;;
        apk)
            run "apk 升级全部软件包" apk upgrade
            rc=$?
            ;;
    esac
    UPGRADE_RC="$rc"
    if [[ "$rc" -eq 0 ]]; then
        info "软件包升级完成。"
    else
        err "软件包升级失败（退出码 ${rc}）。"
        # apt 系常见故障快速翻译
        if [[ "$PM" == "apt" && -f "$LOG_FILE" ]]; then
            if grep -q "dpkg was interrupted" "$LOG_FILE" 2>/dev/null; then
                warn "检测到上次 dpkg 操作被中断，可执行：sudo dpkg --configure -a 后重试。"
            fi
            if grep -q "Could not get lock" "$LOG_FILE" 2>/dev/null; then
                warn "apt/dpkg 数据库被占用，请先确认没有其他安装进程在运行。"
            fi
            if grep -qi "No space left on device" "$LOG_FILE" 2>/dev/null; then
                warn "磁盘空间不足，可执行：sudo apt-get clean 后查看 df -h。"
            fi
        fi
    fi
    return 0
}

# ---------------------------- 收尾清理 ----------------------------
do_autoremove() {
    step "清理不再需要的依赖包"
    case "$PM" in
        apt)   run "apt 自动清理无用依赖" apt-get -y autoremove --purge ;;
        dnf)   run "dnf 自动清理无用依赖" dnf -y autoremove ;;
        yum)   info "yum 无 autoremove 子命令，跳过。" ; return 0 ;;
        zypper) info "zypper 的孤包需手动处理（zypper packages --orphaned），跳过。" ; return 0 ;;
        pacman) info "Arch 的孤包需手动处理（pacman -Qtdq | pacman -Rns -），跳过。" ; return 0 ;;
        apk)   info "apk 无 autoremove 子命令，跳过。" ; return 0 ;;
    esac
    return 0
}

do_clean() {
    step "清理下载缓存"
    case "$PM" in
        apt)    run "apt 清理缓存" apt-get clean ;;
        dnf)    run "dnf 清理缓存" dnf clean packages ;;
        yum)    run "yum 清理缓存" yum clean packages ;;
        zypper) run "zypper 清理缓存" zypper --non-interactive clean ;;
        pacman) run "pacman 清理未安装版本缓存" pacman -Sc --noconfirm ;;
        apk)    run "apk 清理缓存" apk cache clean || true ;;
    esac
    return 0
}

# ---------------------------- 汇总 ----------------------------
summary() {
    step "执行结果汇总"
    local refresh_txt="失败"
    if [[ "$REFRESH_OK" -eq 1 ]]; then refresh_txt="成功"; fi
    if [[ "$REFRESH_OK" -eq 2 ]]; then refresh_txt="部分失败（有镜像源不可达）"; fi
    local upgrade_txt="失败（退出码 ${UPGRADE_RC}）"
    if [[ "$UPGRADE_RC" -eq 0 ]]; then upgrade_txt="成功"; fi
    if [[ "$CHECK_ONLY" -eq 1 ]]; then
        printf '  系统：%s %s\n  包管理器：%s\n  模式：仅检查（未做任何更改）\n' "$OS_NAME" "$OS_VER" "$PM"
        info "完整检查结果：${LOG_FILE}.upgradable"
        return 0
    fi
    printf '  系统：%s %s\n' "$OS_NAME" "$OS_VER"
    printf '  包管理器：%s\n' "$PM"
    printf '  仓库索引刷新：%s\n' "$refresh_txt"
    printf '  软件包升级：%s\n' "$upgrade_txt"
    if [[ "$UPGRADE_RC" -ne 0 ]]; then
        warn "升级未成功，请把日志发给排查：${LOG_FILE}"
    else
        info "全部完成。完整日志：${LOG_FILE}"
    fi
    return 0
}

# ---------------------------- 主流程 ----------------------------
main() {
    ORIG_ARGS=("$@")
    parse_args "$@"

    # 初始化日志文件（/var/log 不可写时静默降级为仅终端输出）
    : >"$LOG_FILE" 2>/dev/null || LOG_FILE="/dev/null"

    step "系统更新脚本启动"
    detect_os
    detect_pm
    info "检测到系统：${OS_NAME} ${OS_VER}（包管理器：${PM}）"

    if [[ "$(id -u)" -ne 0 ]]; then
        need_root
    fi

    if [[ "$CHECK_ONLY" -eq 1 ]]; then
        refresh_index
        check_upgradable
        summary
        return 0
    fi

    if [[ "$AUTO_YES" -ne 1 ]]; then
        confirm "即将刷新仓库索引并升级全部软件包，是否继续？" || { info "已取消，未做任何更改。"; exit 0; }
    fi

    refresh_index
    do_upgrade

    if [[ "$UPGRADE_RC" -eq 0 ]]; then
        do_autoremove
        if [[ "$DO_CLEAN" -eq 1 ]]; then
            do_clean
        else
            info "已按要求跳过缓存清理。"
        fi
    else
        warn "升级失败，跳过清理步骤。"
    fi

    summary
    if [[ "$UPGRADE_RC" -ne 0 ]]; then
        exit "$UPGRADE_RC"
    fi
    return 0
}

main "$@"


# =============================================================================
#  面板声明（供 panel.sh 自动发现，不参与脚本执行）
# =============================================================================
# PANEL: 系统更新 | 系统维护 | 1 | 刷新索引并升级全部软件包
# PANEL-CMD: 检查可升级项 | --check | 只读，不做任何更改
# PANEL-CMD: 升级全部软件包 |  | 交互式，会先询问一次
# PANEL-CMD: 免确认升级 | -y | 自动确认并升级
# PANEL-CMD: 发行版级升级 | --full -y | 允许卸载有依赖冲突的旧包
