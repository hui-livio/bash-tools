#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
#  lib/lib.sh —— 共享库统一入口
#
#  在本目录下任意脚本顶部加一行即可获得全部能力：
#     source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/lib.sh"
#  或者（面板/子脚本由面板注入环境变量时）：
#     source "${LINUX_OPS_LIB:-/path/to/lib}/lib.sh"
#
#  提供的内容一览：
#    00-core.sh  Term（颜色） / Logger（日志） / Tmp（临时文件） / Err（错误陷阱）
#                字符串与转义小工具
#    10-ui.sh    Ui（表格、输入、确认） / Menu（菜单）
#    20-os.sh    OS（发行版、家族、包管理器、架构、WSL、容器） / Sys（权限）
#    30-pkg.sh   Pkg（apt/dnf/yum/zypper/pacman/apk 统一接口）
#    40-exec.sh  Runner（命令执行 + dry-run） / Fs（备份与写文件）
#    50-svc.sh   Svc（systemd/openrc/sysv 统一服务管理）
#    60-db.sh    Db（MariaDB/MySQL 客户端封装）
#
#  设计约定见 00-core.sh 顶部注释：类 = 前缀函数族，对象 = 关联数组 + nameref。
# =============================================================================

# 定位自身目录：既支持 BASH_SOURCE（被 source），也支持 $0（被执行/调试）
__lib_dir="${LINUX_OPS_LIB:-}"
if [[ -z "$__lib_dir" ]]; then
    __lib_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" >/dev/null 2>&1 && pwd)"
fi
readonly LIB_DIR="$__lib_dir"
unset -f __lib_dir_dummy 2>/dev/null || true
unset __lib_dir

# shellcheck source=/dev/null
for __m in 00-core 10-ui 20-os 30-pkg 40-exec 50-svc 60-db; do
    if [[ -r "${LIB_DIR}/${__m}.sh" ]]; then
        # shellcheck disable=SC1090
        source "${LIB_DIR}/${__m}.sh"
    else
        printf '[错误] 缺少共享库模块：%s\n' "${LIB_DIR}/${__m}.sh" >&2
        exit 1
    fi
done
unset __m

# -----------------------------------------------------------------------------
# 便利：一次性补齐「全局默认对象」，业务脚本通常只需这一行
#   Lib::bootstrap [日志文件路径]
# 会自动创建：LOG（日志） UI（交互） SYS（系统信息） PKGMGR（包管理器）
#             RUN（命令执行器） FS（文件操作）
# 并导出历史兼容的全局变量 OS_ID / OS_FAMILY / PKG / ARCH ...
# -----------------------------------------------------------------------------
Lib::bootstrap() {
    LOG_FILE="${1:-${LOG_FILE:-}}"
    Logger::new LOG "$LOG_FILE"
    LOG_FILE="${LOG[file]}"

    Ui::new UI
    UI[assume_yes]="${ASSUME_YES:-0}"
    UI[non_interactive]="${NON_INTERACTIVE:-0}"

    OS::new SYS
    OS::detect SYS "${FORCE_PM:-}"

    Pkg::new PKGMGR "${SYS[pm]}"
    Runner::new RUN; RUN[dry_run]="${DRY_RUN:-0}"
    Fs::new FS;      FS[dry_run]="${DRY_RUN:-0}"
    Err::new ERRCTX "$(basename -- "${BASH_SOURCE[1]:-$0}")" LOG

    # 历史脚本用过的全局变量别名（保证老代码不用大改）
    OS_ID="${SYS[id]}";        OS_ID_LIKE="${SYS[id_like]}"
    OS_NAME="${SYS[name]}";    OS_VERSION="${SYS[version]}"
    OS_MAJOR="${SYS[major]}";  OS_PRETTY="${SYS[pretty]}"
    OS_FAMILY="${SYS[family]}"; OS_CODENAME="${SYS[codename]}"
    OS_ARCH="${SYS[arch]}";    ARCH="${SYS[arch]}"
    PKG="${SYS[pm]}";          PM="${SYS[pm]}"
    WSL="${SYS[wsl]}";         WSL_VERSION="${SYS[wsl_version]}"
    CONTAINER="${SYS[container]}"
    SUDO="$(Sys::sudo_prefix)"
    return 0
}

# 设置 ERR 陷阱（Lib::bootstrap 之后调用）
Lib::install_err_trap() { Err::install ERRCTX; }
