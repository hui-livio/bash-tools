#!/usr/bin/env bash
# =============================================================================
#  cleanup.sh —— 系统清理与包管理器故障修复
#
#  做三件事：
#    1. 审计并修复半配置 / 依赖断裂的包状态（dpkg --audit / --configure -a / -f install）
#    2. 可选：彻底卸载 CUDA / NVIDIA 相关包及其残留目录与软件源
#    3. 清理无用依赖与下载缓存，刷新索引
#
#  用法：
#    sudo bash cleanup.sh                  # 安全清理（不动 CUDA/NVIDIA）
#    sudo bash cleanup.sh --purge-cuda     # 额外卸载 CUDA/NVIDIA 相关包
#    sudo bash cleanup.sh --dry-run        # 只打印将执行的命令
#    sudo bash cleanup.sh -y               # 危险确认也自动通过（配合 --purge-cuda）
#    bash  cleanup.sh -h | --help
#
#  依赖共享库 lib/（日志、确认、包管理器统一接口、命令执行器）
# =============================================================================
set -Eeuo pipefail

__OPS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# shellcheck source=/dev/null
source "${__OPS_DIR}/lib/lib.sh"
unset __OPS_DIR

PURGE_CUDA=0
DRY_RUN="${DRY_RUN:-0}"
ASSUME_YES="${ASSUME_YES:-0}"
while (($#)); do
    case "$1" in
        --purge-cuda) PURGE_CUDA=1; shift ;;
        -n|--dry-run) DRY_RUN=1;    shift ;;
        -y|--yes)     ASSUME_YES=1; shift ;;
        -h|--help)    sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) err "未知参数：$1（用 --help 查看用法）"; exit 1 ;;
    esac
done

Lib::bootstrap "/var/log/cleanup-$(date '+%Y%m%d-%H%M%S').log"
Lib::install_err_trap
RUN[dry_run]="$DRY_RUN"; RUN[fatal]=0
FS[dry_run]="$DRY_RUN"
UI[assume_yes]="$ASSUME_YES"

Sys::require_root

# -----------------------------------------------------------------------------
# 类：Cleaner —— 清理动作集合（本脚本的业务对象）
# -----------------------------------------------------------------------------
Cleaner::audit() {
    Logger::section LOG "1. 包状态审计"
    case "${SYS[pm]}" in
        apt)    Runner::exec RUN dpkg --audit || true ;;
        dnf|yum) Runner::exec RUN rpm -Va --nofiles --nodigest >/dev/null 2>&1 || true
                 ok "rpm 校验完成（无输出即正常）" ;;
        pacman) Runner::exec RUN pacman -Qkk >/dev/null 2>&1 || true
                ok "pacman 完整性检查完成" ;;
        *)      info "当前包管理器（${SYS[pm]:-未识别}）无等价审计动作，跳过" ;;
    esac
}

Cleaner::fix_broken() {
    Logger::section LOG "2. 修复半配置 / 依赖断裂"
    Pkg::fix_broken PKGMGR || true
    if [[ "${SYS[pm]}" == "apt" ]] && ! dpkg --configure -a >/dev/null 2>&1; then
        warn "dpkg --configure -a 未能完全成功。"
        hint "可尝试强制移除问题包，例如："
        hint "  sudo dpkg --remove --force-remove-reinstreq cuda-toolkit-13-1-config-common"
        hint "或运行 cuda-manager.sh repair / mariadb-manager.sh 对应修复流程。"
    else
        ok "依赖状态已修复"
    fi
}

# 卸载 CUDA / NVIDIA：仅 Debian 系用通配符匹配，其它家族给出提示
Cleaner::purge_cuda() {
    Logger::section LOG "3. 卸载 CUDA / NVIDIA 相关包"
    local -a pkgs=()
    case "${SYS[pm]}" in
        apt)
            mapfile -t pkgs < <(Pkg::list_matching PKGMGR 'cuda*' 'nvidia*' 'libcudnn*' 'libnvidia*' 'libcuda*' 2>/dev/null || true)
            ;;
        dnf|yum)
            mapfile -t pkgs < <(rpm -qa 2>/dev/null | grep -E '^(cuda|nvidia|libcudnn|libnvidia|libcuda)' || true)
            ;;
        pacman)
            mapfile -t pkgs < <(pacman -Qq 2>/dev/null | grep -E '^(cuda|nvidia|libcudnn|libcuda)' || true)
            ;;
        *) warn "当前包管理器（${SYS[pm]}）未内置 CUDA 匹配规则，跳过" ; return 0 ;;
    esac

    if (( ${#pkgs[@]} == 0 )); then
        info "未找到 CUDA / NVIDIA 相关包。"
        return 0
    fi

    printf '%s\n' "${pkgs[@]}"
    warn "以上 ${#pkgs[@]} 个包将被彻底卸载（含 NVIDIA 驱动，可能影响图形界面）。"
    if ! Ui::typed UI "确认卸载" DELETE; then
        info "已跳过卸载。"
        return 0
    fi

    Pkg::purge PKGMGR "${pkgs[@]}" || warn "部分包卸载失败，详见日志：${LOG_FILE}"

    if Ui::confirm UI "是否同时删除残留目录 /usr/local/cuda* 与 CUDA/NVIDIA 软件源" n; then
        local p
        for p in /usr/local/cuda* /var/cuda* \
                 /etc/apt/sources.list.d/cuda* /etc/apt/sources.list.d/nvidia* \
                 /etc/yum.repos.d/cuda* /etc/zypp/repos.d/cuda*; do
            [[ -e "$p" ]] || continue
            if [[ "$DRY_RUN" == "1" ]]; then
                printf '%s[dry-run]%s rm -rf %s\n' "$C_DIM" "$C_RESET" "$p"
            else
                rm -rf -- "$p" 2>/dev/null || warn "删除失败：$p"
            fi
        done
        ok "残留目录与软件源已清理。"
    fi
}

Cleaner::tidy() {
    Logger::section LOG "4. 清理无用依赖与缓存"
    Pkg::clean PKGMGR || true
    ok "缓存已清理"
}

Cleaner::refresh() {
    Logger::section LOG "5. 刷新软件源索引"
    Pkg::update PKGMGR || warn "索引刷新失败（网络问题？），详见日志：${LOG_FILE}"
}

# -----------------------------------------------------------------------------
# 主流程
# -----------------------------------------------------------------------------
main() {
    Logger::section LOG "系统清理 / 包管理器修复"
    OS::summary SYS
    printf '\n'

    Cleaner::audit
    Cleaner::fix_broken
    if (( PURGE_CUDA )); then Cleaner::purge_cuda; else info "跳过 CUDA/NVIDIA 卸载（加 --purge-cuda 启用）"; fi
    Cleaner::tidy
    Cleaner::refresh
    Cleaner::audit

    ok "清理完成。完整日志：${LOG_FILE}"
    Tmp::cleanup
}

main "$@"


# =============================================================================
#  面板声明（供 panel.sh 自动发现，不参与脚本执行）
# =============================================================================
# PANEL: 系统清理 | 系统维护 | 1 | 修复包管理器故障、清理缓存
# PANEL-CMD: 安全清理（不动 CUDA/NVIDIA） |  | 审计 + 修复依赖 + 清缓存 + 刷新索引
# PANEL-CMD: 彻底卸载 CUDA/NVIDIA | --purge-cuda | 额外卸载 CUDA/NVIDIA 包与残留目录
# PANEL-CMD: 演练（只看会做什么） | --dry-run | 不改动系统
