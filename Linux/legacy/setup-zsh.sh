#!/usr/bin/env bash
# =============================================================================
#  setup-zsh.sh  --  zsh 统一部署脚本（root 执行一次，全用户共用一份配置）
#
#  做什么:
#    1. 安装 zsh，并把 root 的默认 shell 切换为 zsh
#    2. 安装 oh-my-zsh 到系统级共享目录（全系统只此一份，不重复下载）
#    3. 默认主题 haoomz —— 安装时下载到本地，
#       主题文件：/usr/local/share/zsh-config/themes/haoomz.zsh-theme
#       运行时纯本地加载，.zshrc 里没有任何联网动作
#    4. 常用插件（全部本地化）：
#       自带：git / z / extract / history / sudo / colored-man-pages /
#             dirhistory / jsontools / cp / command-not-found / fzf(若已装)
#       第三方：zsh-autosuggestions / zsh-completions / zsh-syntax-highlighting
#    4. root、已存在的普通用户、以及未来新建用户（/etc/skel）共用同一份配置：
#       每个人的 ~/.zshrc 只有一行 source，指向共享配置；主题/插件零冗余
#
#  用法（必须用 root 运行）:
#    sudo bash setup-zsh.sh [选项]
#
#  选项:
#    -y, --yes               非交互，自动确认
#    -n, --dry-run           只打印将执行的命令
#    -t, --theme=NAME        主题，默认 simple（可选 simple/robbyrussell/bureau/avit...）
#        --font=NAME         主题字体 Nerd Font（默认 meslo，必装，否则 ➜/powerline 符号是方块）
#        --plugins="a b c"   自定义插件列表（留空则用默认列表）
#        --users=u1,u2       额外把这些普通用户的默认 shell 改为 zsh
#        --all-users         所有 UID>=1000 且有交互 shell 的普通用户都改为 zsh
#        --skip-chsh         只装配置，不改任何人的默认 shell
#        --no-omz            不安装 oh-my-zsh（离线/极简场景，用内置提示符）
#        --prefix=DIR        共享目录，默认 /usr/local/share/zsh-config
#        --print-config      只打印生成的共享配置内容，不做任何改动
#    -h, --help              显示帮助
#    -V, --version           显示版本
#
#  默认行为：root 和所有普通用户的终端默认 shell 都会改成 zsh，
#            并通过 useradd -D 让以后新建的用户也默认用 zsh。
#
#  字体：主题里的 ➜ / powerline 符号需要 Nerd Font，本脚本默认下载 MesloLGS NF
#        到 /usr/local/share/fonts 并 fc-cache 启用。注意最终显示字体由"客户端
#        终端"决定，Windows Terminal / iTerm2 / PuTTY 里也要把字体选成同一个
#        Nerd Font，否则依然可能显示方块。
#
#  示例:
#    sudo bash setup-zsh.sh                    # 装好并把所有人（含 root）的终端切成 zsh
#    sudo bash setup-zsh.sh --only-root        # 只给 root 切，其他人仅获得配置
#    sudo bash setup-zsh.sh --users=hui,www    # 只切指定用户
#    sudo bash setup-zsh.sh -t robbyrussell    # 换个主题（自带的无需下载）
#    sudo bash setup-zsh.sh --theme-url=http://内网/haoomz.zsh-theme   # 主题走内网镜像
# =============================================================================

set -euo pipefail
readonly SCRIPT_VERSION="1.2.0"

# ----------------------------- 默认选项 --------------------------------------
DRY_RUN=0
ASSUME_YES=0
THEME="haoomz"       # 默认主题：安装时下载到本地，运行时绝不联网加载
PLUGINS=""
TARGET_USERS=""
ALL_USERS=1          # 默认：root + 所有普通用户的终端默认 shell 都改为 zsh
ONLY_ROOT=0
SKIP_CHSH=0
NO_OMZ=0
PRINT_CONFIG=0
PREFIX="/usr/local/share/zsh-config"
FONT="meslo"         # meslo|jetbrains|hack|firacode|sourcecode|none
FONT_URL=""          # 自定义字体包下载地址（内网/离线环境可用）
THEME_URL=""         # 自定义主题文件下载地址（内网/离线环境可用）

# ----------------------------- 彩色输出 --------------------------------------
C_RESET=""; C_BLUE=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_GRAY=""
if [[ -t 1 ]]; then
    C_RESET=$'\033[0m'; C_BLUE=$'\033[1;34m'; C_GREEN=$'\033[1;32m'
    C_YELLOW=$'\033[1;33m'; C_RED=$'\033[1;31m'; C_GRAY=$'\033[0;90m'
fi
log()  { printf '%s[INFO]%s %s\n' "$C_BLUE"   "$C_RESET" "$*"; }
ok()   { printf '%s[ OK ]%s %s\n' "$C_GREEN"  "$C_RESET" "$*"; }
warn() { printf '%s[WARN]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
err()  { printf '%s[FAIL]%s %s\n' "$C_RED"    "$C_RESET" "$*" >&2; }
die()  { err "$*"; exit 1; }

usage() {
    cat <<'EOF'
用法: sudo bash setup-zsh.sh [选项]

选项:
  -y, --yes             非交互，自动确认
  -n, --dry-run         只打印将执行的命令
  -t, --theme=NAME      主题（默认 simple）
      --plugins="a b c" 自定义插件列表
      --users=u1,u2     只把这些普通用户的默认 shell 改为 zsh
      --all-users       所有普通用户都改为 zsh（默认行为）
      --only-root       只改 root 的 shell，普通用户只装配置不换 shell
      --skip-chsh       只装配置，不改任何人的默认 shell
      --no-omz          不安装 oh-my-zsh（离线/极简）
      --prefix=DIR      共享目录，默认 /usr/local/share/zsh-config
      --print-config    只打印生成的共享配置，不做任何改动
      --font=NAME       主题字体，默认 meslo（可选 jetbrains/hack/firacode/sourcecode/none）
      --font-url=URL    自定义字体包下载地址（内网/离线用）
      --theme-url=URL   自定义主题下载地址（默认主题 haoomz 已内置镜像地址）
  -h, --help            显示帮助
  -V, --version         显示版本

示例:
  sudo bash setup-zsh.sh                    # 只给 root 装并启用
  sudo bash setup-zsh.sh --all-users        # 同时把所有普通用户切到 zsh
  sudo bash setup-zsh.sh --users=hui,www    # 只切指定用户
EOF
    exit 0
}

# ----------------------------- 参数解析 --------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)        usage ;;
        -V|--version)     echo "setup-zsh.sh v$SCRIPT_VERSION"; exit 0 ;;
        -y|--yes)         ASSUME_YES=1; shift ;;
        -n|--dry-run)     DRY_RUN=1; shift ;;
        -t|--theme)       [[ $# -ge 2 ]] || die "--theme 缺少参数"; THEME="$2"; shift 2 ;;
        -t=*|--theme=*)   THEME="${1#*=}"; shift ;;
        --plugins)        [[ $# -ge 2 ]] || die "--plugins 缺少参数"; PLUGINS="$2"; shift 2 ;;
        --plugins=*)      PLUGINS="${1#--plugins=}"; shift ;;
        --users)          [[ $# -ge 2 ]] || die "--users 缺少参数"; TARGET_USERS="$2"; shift 2 ;;
        --users=*)        TARGET_USERS="${1#--users=}"; shift ;;
        --all-users)      ALL_USERS=1; ONLY_ROOT=0; shift ;;
        --only-root)      ONLY_ROOT=1; ALL_USERS=0; shift ;;
        --skip-chsh)      SKIP_CHSH=1; shift ;;
        --no-omz)         NO_OMZ=1; shift ;;
        --print-config)   PRINT_CONFIG=1; shift ;;
        --prefix)         [[ $# -ge 2 ]] || die "--prefix 缺少参数"; PREFIX="$2"; shift 2 ;;
        --prefix=*)       PREFIX="${1#--prefix=}"; shift ;;
        --font)           [[ $# -ge 2 ]] || die "--font 缺少参数"; FONT="$2"; shift 2 ;;
        --font=*)         FONT="${1#--font=}"; shift ;;
        --font-url)       [[ $# -ge 2 ]] || die "--font-url 缺少参数"; FONT_URL="$2"; shift 2 ;;
        --font-url=*)     FONT_URL="${1#--font-url=}"; shift ;;
        --theme-url)      [[ $# -ge 2 ]] || die "--theme-url 缺少参数"; THEME_URL="$2"; shift 2 ;;
        --theme-url=*)    THEME_URL="${1#--theme-url=}"; shift ;;
        *)                die "未知参数: $1（用 -h 查看帮助）" ;;
    esac
done

OMZ_DIR="$PREFIX/oh-my-zsh"
SHARED_RC="$PREFIX/zshrc"
THEME_DIR="$PREFIX/themes"     # 第三方主题下载到这里（本地加载，不联网）

# ----------------------------- 共享配置内容 ----------------------------------
# 说明：这是唯一一份 zsh 配置，所有用户共用；个人定制写 ~/.zshrc.local
render_shared_rc() {
    cat <<'ZSHRC'
# =============================================================================
#  全局共享 zsh 配置 —— 所有用户（root / 普通用户）共用这一份
#  由 setup-zsh.sh 生成，目录：@@PREFIX@@
#  主题：@@THEME@@（本地文件 @@THEME_DIR@@/@@THEME@@.zsh-theme，无任何联网加载）
#  修改本文件即可对所有人生效；个人定制请写入 ~/.zshrc.local
# =============================================================================

# ---------------------------- oh-my-zsh（全系统唯一一份） --------------------
if [[ -r "@@OMZ_DIR@@/oh-my-zsh.sh" ]]; then
    export ZSH="@@OMZ_DIR@@"
    export ZSH_CUSTOM="$ZSH/custom"
    # 缓存目录放到各用户自己的家目录，避免共享目录的写权限问题
    export ZSH_CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/oh-my-zsh"
    [[ -d "$ZSH_CACHE_DIR" ]] || mkdir -p "$ZSH_CACHE_DIR"

    # 关闭自动更新与更新提示（共享目录由管理员统一维护）
    zstyle ':omz:update' mode disabled
    DISABLE_UPDATE_PROMPT="true"
    DISABLE_AUTO_UPDATE="true"
    DISABLE_MAGIC_FUNCTIONS="false"

    ZSH_THEME="@@THEME@@"

    plugins=(
        @@PLUGINS@@
    )

    source "$ZSH/oh-my-zsh.sh"
else
    # 未安装 oh-my-zsh 时的极简提示符（--no-omz 场景）
    autoload -Uz colors && colors
    PROMPT='%F{cyan}%n@%m%f %F{blue}%~%f %# '
    RPROMPT='%(?..%F{red}Exit %?%f)'
fi

# ---------------------------- 第三方插件兜底 --------------------------------
# 若发行版自带了这两个插件（Debian/Fedora/Arch 都打包了），直接复用系统里的，
# 不再重复下载。
_load_plugin() {   # $1=插件名 其余=候选路径
    local name="$1"; shift
    local f
    for f in "$@"; do
        if [[ -r "$f" ]]; then source "$f"; return 0; fi
    done
    return 1
}

if [[ ! -r "${ZSH:-}/custom/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh" ]]; then
    ZSH_AUTOSUGGEST_HIGHLIGHT_STYLE="fg=8"
    ZSH_AUTOSUGGEST_STRATEGY=(history completion)
    _load_plugin zsh-autosuggestions \
        /usr/share/zsh-autosuggestions/zsh-autosuggestions.zsh \
        /usr/share/zsh/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh \
        /usr/local/share/zsh-autosuggestions/zsh-autosuggestions.zsh || true
fi

if [[ ! -r "${ZSH:-}/custom/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh" ]]; then
    _load_plugin zsh-syntax-highlighting \
        /usr/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh \
        /usr/share/zsh/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh \
        /usr/local/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh || true
fi

# ---------------------------- 历史记录 --------------------------------------
HISTFILE="${HOME}/.zsh_history"
HISTSIZE=50000
SAVEHIST=50000
setopt INC_APPEND_HISTORY SHARE_HISTORY HIST_IGNORE_ALL_DUPS \
       HIST_IGNORE_SPACE HIST_REDUCE_BLANKS EXTENDED_HISTORY

# ---------------------------- 基础环境 --------------------------------------
bindkey -e                       # emacs 键位（左右/行首行末可用）
export EDITOR="${EDITOR:-vi}"    # 不强制改 LANG/LC_ALL，避免系统无该 locale 时报警

alias ll='ls -alFh'
alias la='ls -Ah'
alias lt='ls -alFht'
alias ..='cd ..'
alias ...='cd ../..'
alias df='df -h'
alias du='du -h'
alias grep='grep --color=auto'

# ---------------------------- 个人定制入口 ----------------------------------
[[ -r "$HOME/.zshrc.local" ]] && source "$HOME/.zshrc.local"
ZSHRC
}

default_plugins() {
    # 说明：
    #   - 前 11 个都是 oh-my-zsh 自带插件（随 oh-my-zsh 一起下载到本地，无需额外下载）
    #   - zsh-autosuggestions / zsh-completions / zsh-syntax-highlighting 为第三方，
    #     安装时已克隆到共享目录的 custom/plugins 下
    #   - zsh-syntax-highlighting 必须放最后一个
    local -a list=(
        git                # git 别名 + 分支/状态提示
        z                  # 按访问频率跳转目录（比 autojump 轻）
        extract            # 一个 x 命令解压任意格式
        history            # 历史命令快捷查询
        sudo               # 连按两次 ESC 给当前命令加 sudo
        colored-man-pages  # man 手册彩色化
        dirhistory         # Alt+←/→ 在目录间前进后退
        jsontools          # pp-json / is-json 等 JSON 小工具
        cp                 # cpv：带进度条的复制（依赖 rsync）
        command-not-found  # 命令不存在时提示该装哪个包
    )
    if command -v fzf >/dev/null 2>&1; then
        list+=(fzf)        # 模糊搜索（装上了才启用）
    fi
    list+=(zsh-autosuggestions zsh-completions zsh-syntax-highlighting)

    local p out=""
    for p in "${list[@]}"; do out+="        $p"$'\n'; done
    printf '%s' "${out%$'\n'}"
}

build_shared_rc() {
    local plugin_block p
    if [[ -n "$PLUGINS" ]]; then
        plugin_block=""
        for p in $PLUGINS; do plugin_block+="        $p"$'\n'; done
        plugin_block="${plugin_block%$'\n'}"
    else
        plugin_block="$(default_plugins)"
    fi
    # 纯 bash 字符串替换，不依赖 sed/awk
    local content
    content="$(render_shared_rc)"
    content="${content//@@PREFIX@@/$PREFIX}"
    content="${content//@@OMZ_DIR@@/$OMZ_DIR}"
    content="${content//@@THEME_DIR@@/$THEME_DIR}"
    content="${content//@@THEME@@/$THEME}"
    content="${content//        @@PLUGINS@@/$plugin_block}"
    printf '%s\n' "$content"
}

# --print-config：只输出配置内容，不做任何改动（方便审阅 / 手动部署）
if [[ "$PRINT_CONFIG" == "1" ]]; then
    build_shared_rc
    exit 0
fi

# ----------------------------- 环境检查 --------------------------------------
[[ "$(uname -s)" == "Linux" ]] || die "本脚本仅支持 Linux，当前系统: $(uname -s)"
[[ ${EUID} -eq 0 ]] || die "请用 root 运行：sudo bash $0"

export DEBIAN_FRONTEND=noninteractive

# ----------------------------- 包管理器探测 ----------------------------------
PM=""
os_field() {
    local key="$1" line val
    [[ -r /etc/os-release ]] || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" == "$key="* ]] || continue
        val="${line#*=}"
        if [[ "$val" == '"'*'"' ]]; then val="${val:1:${#val}-2}"; fi
        printf '%s' "$val"
        return 0
    done < /etc/os-release
}
detect_pm() {
    local sig
    sig="$(os_field ID || true) $(os_field ID_LIKE || true)"
    case "$sig" in
        *debian*|*ubuntu*|*mint*|*deepin*|*uos*|*kali*) command -v apt-get >/dev/null 2>&1 && { PM="apt"; return 0; } ;;
        *fedora*|*rhel*|*centos*|*rocky*|*almalinux|*opencloudos*|*tencentos*)
            command -v dnf >/dev/null 2>&1 && { PM="dnf"; return 0; }
            command -v yum >/dev/null 2>&1 && { PM="yum"; return 0; } ;;
        *suse*)   command -v zypper >/dev/null 2>&1 && { PM="zypper"; return 0; } ;;
        *arch*|*manjaro*|*artix*) command -v pacman >/dev/null 2>&1 && { PM="pacman"; return 0; } ;;
        *alpine*) command -v apk >/dev/null 2>&1 && { PM="apk"; return 0; } ;;
        *void*)   command -v xbps-install >/dev/null 2>&1 && { PM="xbps"; return 0; } ;;
    esac
    local p
    for p in apt-get dnf yum pacman zypper apk xbps-install; do
        if command -v "$p" >/dev/null 2>&1; then
            case "$p" in apt-get) PM="apt";; xbps-install) PM="xbps";; *) PM="$p";; esac
            return 0
        fi
    done
    return 1
}

# ----------------------------- 命令封装 --------------------------------------
run() {
    if [[ "$DRY_RUN" == "1" ]]; then
        local s="" a
        for a in "$@"; do
            if [[ "$a" == *" "* || -z "$a" ]]; then s+="'$a' "; else s+="$a "; fi
        done
        printf '%s$ %s%s\n' "$C_GRAY" "${s% }" "$C_RESET"
        return 0
    fi
    "$@"
}

# ----------------------------- 安装 zsh --------------------------------------
install_packages() {
    log "安装 zsh / git / curl ..."
    local -a pkgs=(zsh git curl ca-certificates)
    case "$PM" in
        apt)    run apt-get update -y || warn "apt-get update 失败，继续尝试安装"
                run apt-get install -y "${pkgs[@]}" ;;
        dnf)    run dnf install -y "${pkgs[@]}" ;;
        yum)    run yum install -y "${pkgs[@]}" ;;
        zypper) run zypper --non-interactive install "${pkgs[@]}" ;;
        pacman) run pacman -S --needed --noconfirm "${pkgs[@]}" ;;
        apk)    run apk update || true
                run apk add "${pkgs[@]}" ;;
        xbps)   run xbps-install -Sy "${pkgs[@]}" ;;
        *)      die "未检测到受支持的包管理器，请手动安装 zsh 后重跑本脚本" ;;
    esac
}

# ----------------------------- 可选流行工具 ----------------------------------
# fzf（模糊搜索，装上才会启用 fzf 插件）、rsync（cp 插件的 cpv 进度条依赖）
# 装不上只告警，不影响主流程
install_optional_tools() {
    log "安装可选工具（fzf / rsync）..."
    pm_install fzf   || warn "fzf 安装失败，将不启用 fzf 插件"
    pm_install rsync || warn "rsync 安装失败，cp 插件的 cpv 进度条不可用"
    if command -v fzf >/dev/null 2>&1; then ok "fzf: $(command -v fzf)"; fi
}

# ----------------------------- 通用安装命令 ----------------------------------
pm_install() {   # $@ = 包名；失败只返回非 0，不中断脚本
    local -a pkgs=("$@")
    case "$PM" in
        apt)    run apt-get install -y "${pkgs[@]}" ;;
        dnf)    run dnf install -y "${pkgs[@]}" ;;
        yum)    run yum install -y "${pkgs[@]}" ;;
        zypper) run zypper --non-interactive install "${pkgs[@]}" ;;
        pacman) run pacman -S --needed --noconfirm "${pkgs[@]}" ;;
        apk)    run apk add "${pkgs[@]}" ;;
        xbps)   run xbps-install -Sy "${pkgs[@]}" ;;
        *)      return 1 ;;
    esac
}

# ----------------------------- 主题字体（Nerd Font） --------------------------
# 主题里的 ➜ / powerline 符号需要带符号补丁的等宽字体，否则终端里是方块。
# 说明：Linux 只负责"装好字体"，最终的显示字体由客户端终端决定，
#       Windows Terminal / iTerm2 / PuTTY 里也要把字体选成同一个 Nerd Font。
install_fonts() {
    [[ "$FONT" == "none" ]] && { log "已指定 --font=none，跳过字体安装"; return 0; }

    local asset="" family=""
    case "$FONT" in
        meslo)     asset="Meslo";         family="MesloLGS NF" ;;
        jetbrains) asset="JetBrainsMono"; family="JetBrainsMono Nerd Font" ;;
        hack)      asset="Hack";          family="Hack Nerd Font" ;;
        firacode)  asset="FiraCode";      family="FiraCode Nerd Font" ;;
        sourcecode) asset="SourceCodePro"; family="SauceCodePro Nerd Font" ;;
        *)         die "未知字体: $FONT（可选 meslo|jetbrains|hack|firacode|sourcecode|none）" ;;
    esac

    log "安装字体工具（fontconfig / unzip）..."
    pm_install fontconfig unzip || warn "fontconfig / unzip 安装失败，字体可能无法启用"

    # 1) 发行版自带的 powerline 字体（可选，装不上不影响）
    log "尝试安装发行版 powerline 字体 ..."
    case "$PM" in
        apt)    pm_install fonts-powerline  || warn "fonts-powerline 不可用，改用 Nerd Font" ;;
        dnf|yum) pm_install powerline-fonts || warn "powerline-fonts 不可用（可先装 EPEL），改用 Nerd Font" ;;
        zypper) pm_install powerline-fonts  || warn "powerline-fonts 不可用，改用 Nerd Font" ;;
        pacman) pm_install powerline-fonts  || warn "powerline-fonts 不可用，改用 Nerd Font" ;;
        apk)    pm_install powerline-fonts  || warn "powerline-fonts 不可用，改用 Nerd Font" ;;
        xbps)   pm_install powerline-fonts  || warn "powerline-fonts 不可用，改用 Nerd Font" ;;
    esac

    # 2) Nerd Font（含 powerline 符号 + 大量图标）
    local dir="/usr/local/share/fonts/${asset}NF"
    local url="${FONT_URL:-https://github.com/ryanoasis/nerd-fonts/releases/latest/download/${asset}.zip}"
    local zipfile="/tmp/nerdfont-${asset}.zip"

    if [[ -d "$dir" && -n "$(ls -A "$dir" 2>/dev/null)" ]]; then
        log "字体已存在，跳过下载: $dir"
    else
        log "下载 Nerd Font: ${asset}"
        if ! run curl -fsSL -o "$zipfile" "$url"; then
            warn "字体下载失败，可手动下载后解压到 $dir："
            warn "  $url"
            return 1
        fi
        if [[ "$DRY_RUN" == "0" ]]; then
            mkdir -p "$dir"
            if command -v unzip >/dev/null 2>&1; then
                unzip -o -q "$zipfile" -d "$dir" || warn "解压失败: $zipfile"
                # 删掉 Windows 兼容变体，省空间
                find "$dir" -type f -name '*Windows Compatible*' -delete 2>/dev/null || true
            else
                warn "没有 unzip，无法解压字体包（已保留 $zipfile）"
                return 1
            fi
            rm -f "$zipfile"
        fi
    fi

    # 3) 启用：刷新字体缓存 + 设为等宽字体首选
    if [[ "$DRY_RUN" == "0" ]]; then
        chmod -R a+rX /usr/local/share/fonts 2>/dev/null || true
        if command -v fc-cache >/dev/null 2>&1; then
            log "刷新字体缓存（fc-cache）..."
            fc-cache -f >/dev/null 2>&1 || warn "fc-cache 执行失败"
            ok "字体已启用: $family"
        else
            warn "系统无 fc-cache（fontconfig 未装上），字体需手动刷新缓存"
        fi
        if [[ -d /etc/fonts/conf.d ]]; then
            local conf="/etc/fonts/conf.d/99-nerdfont-monospace.conf"
            log "写入 fontconfig 首选等宽字体: $conf"
            cat > "$conf" <<FONTCONF
<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "fonts.dtd">
<fontconfig>
  <!-- 由 setup-zsh.sh 生成：让 monospace 首选 Nerd Font，避免主题符号显示成方块 -->
  <alias>
    <family>monospace</family>
    <prefer>
      <family>${family}</family>
      <family>PowerlineSymbols</family>
      <family>DejaVu Sans Mono</family>
    </prefer>
  </alias>
</fontconfig>
FONTCONF
        fi
        if command -v fc-list >/dev/null 2>&1; then
            if fc-list 2>/dev/null | grep -qi "${asset}"; then
                ok "已验证系统字体库中存在 ${asset}"
            else
                warn "fc-list 未查到 ${asset}，请检查 $dir 下的字体文件"
            fi
        fi
    fi
}

# ----------------------------- oh-my-zsh 与插件 -------------------------------
clone_repo() {   # $1=目标目录，其余=候选仓库地址
    local dir="$1"; shift
    local url
    if [[ -d "$dir" ]]; then
        log "已存在，跳过克隆: $dir"
        return 0
    fi
    for url in "$@"; do
        log "克隆 $url"
        if run git clone --depth=1 "$url" "$dir"; then return 0; fi
        warn "克隆失败: $url"
    done
    if [[ ! -d "$dir" ]]; then rm -rf "$dir" 2>/dev/null || true; fi
    return 1
}

install_omz() {
    [[ "$NO_OMZ" == "1" ]] && { log "已指定 --no-omz，跳过 oh-my-zsh"; return 0; }
    mkdir -p "$PREFIX"
    if ! clone_repo "$OMZ_DIR" \
        "https://github.com/ohmyzsh/ohmyzsh.git" \
        "https://gitee.com/mirrors/oh-my-zsh.git"; then
        warn "oh-my-zsh 下载失败，将使用内置极简提示符（离线场景可加 --no-omz 明确指定）"
        NO_OMZ=1
        return 0
    fi

    local custom="$OMZ_DIR/custom/plugins"
    mkdir -p "$custom"
    clone_repo "$custom/zsh-autosuggestions" \
        "https://github.com/zsh-users/zsh-autosuggestions.git" || warn "zsh-autosuggestions 未安装"
    clone_repo "$custom/zsh-completions" \
        "https://github.com/zsh-users/zsh-completions.git" || warn "zsh-completions 未安装"
    clone_repo "$custom/zsh-syntax-highlighting" \
        "https://github.com/zsh-users/zsh-syntax-highlighting.git" || warn "zsh-syntax-highlighting 未安装"

    ensure_theme
    chmod -R a+rX "$PREFIX"
}

# ----------------------------- 主题本地化 ------------------------------------
# 原则：主题一律下载到本地再加载，.zshrc 里绝不做任何联网动作。
#   - oh-my-zsh 自带主题：本来就是本地文件（$OMZ_DIR/themes/*.zsh-theme）
#   - 第三方主题（如 haoomz）：安装时下载到 $THEME_DIR，再放进 custom/themes
download_file() {   # $1=url  $2=目标文件
    local url="$1" dest="$2"
    if command -v curl >/dev/null 2>&1; then
        run curl -fsSL -o "$dest" "$url"
    elif command -v wget >/dev/null 2>&1; then
        run wget -q -O "$dest" "$url"
    else
        warn "系统无 curl / wget，无法下载: $url"
        return 1
    fi
}

# 已知第三方主题的下载地址（多个候选，逐个尝试）
theme_urls() {
    case "$1" in
        haoomz)
            printf '%s\n' \
                "https://cdn.haoyep.com/gh/leegical/Blog_img/zsh/haoomz.zsh-theme" \
                "https://raw.githubusercontent.com/leegical/Blog_img/master/zsh/haoomz.zsh-theme" ;;
    esac
}

ensure_theme() {
    if [[ "$NO_OMZ" == "1" ]]; then
        warn "--no-omz 下不使用 oh-my-zsh 主题（haoomz 依赖 oh-my-zsh 的 git_prompt_info），将用内置极简提示符"
        return 0
    fi

    local builtin_file="$OMZ_DIR/themes/$THEME.zsh-theme"
    local custom_file="$OMZ_DIR/custom/themes/$THEME.zsh-theme"
    local local_file="$THEME_DIR/$THEME.zsh-theme"

    if [[ -f "$builtin_file" ]]; then
        ok "主题（oh-my-zsh 自带，本地文件）: $THEME"
        return 0
    fi
    if [[ -f "$custom_file" ]]; then
        ok "主题（已下载到本地）: $custom_file"
        return 0
    fi

    local urls url
    if [[ -n "$THEME_URL" ]]; then urls="$THEME_URL"; else urls="$(theme_urls "$THEME")"; fi
    if [[ -z "$urls" ]]; then
        warn "主题 $THEME 既不是 oh-my-zsh 自带主题，也没有预设下载地址，回退为 simple"
        THEME="simple"
        return 0
    fi

    mkdir -p "$THEME_DIR" "$OMZ_DIR/custom/themes"
    if [[ "$DRY_RUN" == "1" ]]; then
        url="${urls%%$'\n'*}"
        printf '%s$ curl -fsSL -o %s %s%s\n' "$C_GRAY" "$local_file" "$url" "$C_RESET"
        printf '%s$ cp -f %s %s%s\n' "$C_GRAY" "$local_file" "$custom_file" "$C_RESET"
        return 0
    fi

    while IFS= read -r url; do
        [[ -n "$url" ]] || continue
        log "下载主题到本地: $url"
        if download_file "$url" "$local_file" && [[ -s "$local_file" ]]; then
            cp -f "$local_file" "$custom_file"
            chmod 0644 "$local_file" "$custom_file"
            ok "主题已本地化: $custom_file"
            return 0
        fi
        warn "下载失败: $url"
    done <<< "$urls"

    warn "主题 $THEME 下载失败，回退为 simple（可用 --theme-url 指定内网地址）"
    THEME="simple"
}

# ----------------------------- 写入共享配置 ----------------------------------
write_shared_config() {
    log "写入共享配置: $SHARED_RC"
    if [[ "$DRY_RUN" == "1" ]]; then
        printf '%s$ cat > %s <<<共享配置%s\n' "$C_GRAY" "$SHARED_RC" "$C_RESET"
        return 0
    fi
    mkdir -p "$PREFIX"
    build_shared_rc > "$SHARED_RC"
    chmod 0644 "$SHARED_RC"
    ok "$SHARED_RC"
}

# ----------------------------- 用户配置 --------------------------------------
USER_RC_CONTENT='# 本文件由 setup-zsh.sh 生成：所有用户共用一份共享配置
# 需要个人定制，请写入 ~/.zshrc.local（不会被覆盖）
source @@SHARED_RC@@
'

write_user_rc() {   # $1=用户名 $2=家目录 $3=uid(可空)
    local user="$1" home="$2" uid="${3:-}"
    [[ -d "$home" ]] || { warn "家目录不存在，跳过: $home"; return 0; }
    local rc="$home/.zshrc"
    if [[ -f "$rc" ]]; then
        local bak="$rc.bak.$(date +%Y%m%d%H%M%S)"
        log "备份已有配置 $rc -> $bak"
        if [[ "$DRY_RUN" == "0" ]]; then cp -a "$rc" "$bak"; fi
    fi
    log "写入 $rc"
    if [[ "$DRY_RUN" == "0" ]]; then
        printf '%s' "${USER_RC_CONTENT//@@SHARED_RC@@/$SHARED_RC}" > "$rc"
        chmod 0644 "$rc"
        mkdir -p "$home/.cache"
        if [[ -n "$uid" ]]; then
            local gid
            gid="$(id -g "$user" 2>/dev/null || echo "")"
            if [[ -n "$gid" ]]; then chown "$uid:$gid" "$rc" "$home/.cache" 2>/dev/null || true
            else chown "$uid" "$rc" "$home/.cache" 2>/dev/null || true; fi
        fi
    fi
    ok "$rc"
}

write_skel() {
    log "写入 /etc/skel/.zshrc（新建用户自动继承）"
    if [[ "$DRY_RUN" == "0" ]]; then
        mkdir -p /etc/skel
        printf '%s' "${USER_RC_CONTENT//@@SHARED_RC@@/$SHARED_RC}" > /etc/skel/.zshrc
        chmod 0644 /etc/skel/.zshrc
    fi
    ok "/etc/skel/.zshrc"
}

# ----------------------------- 切换默认 shell --------------------------------
ensure_shells_entry() {
    local zbin="$1"
    if ! grep -qx "$zbin" /etc/shells 2>/dev/null; then
        log "把 $zbin 加入 /etc/shells"
        if [[ "$DRY_RUN" == "0" ]]; then printf '%s\n' "$zbin" >> /etc/shells; fi
    fi
}

set_user_shell() {   # $1=用户名
    local user="$1" zbin="$2"
    log "切换 $user 的默认 shell -> $zbin"
    if [[ "$DRY_RUN" == "1" ]]; then
        printf '%s$ chsh -s %s %s%s\n' "$C_GRAY" "$zbin" "$user" "$C_RESET"
        return 0
    fi
    if chsh -s "$zbin" "$user" 2>/dev/null; then ok "$user -> zsh"; return 0; fi
    if usermod -s "$zbin" "$user" 2>/dev/null; then ok "$user -> zsh"; return 0; fi
    err "$user 的 shell 切换失败（chsh/usermod 都不可用），请手动执行: chsh -s $zbin $user"
    return 1
}

enumerate_normal_users() {
    local user uid home shell
    while IFS=: read -r user _ uid _ _ home shell; do
        [[ "$user" == "nobody" || "$user" == "root" ]] && continue
        [[ "$uid" =~ ^[0-9]+$ ]] || continue
        [[ "$uid" -ge 1000 ]] || continue
        [[ -d "$home" ]] || continue
        grep -qx "$shell" /etc/shells 2>/dev/null || continue
        printf '%s %s %s\n' "$user" "$home" "$uid"
    done < /etc/passwd
}

# ============================== 主流程 =======================================
main() {
    detect_pm || die "未检测到受支持的包管理器（apt/dnf/yum/zypper/pacman/apk/xbps）"

    printf '%s\n' "-----------------------------------------------"
    printf ' 系统       : %s\n' "$(os_field NAME || echo unknown)"
    printf ' 包管理器   : %s\n' "$PM"
    printf ' 共享目录   : %s\n' "$PREFIX"
    printf ' oh-my-zsh  : %s\n' "$OMZ_DIR"
    printf ' 主题       : %s\n' "$THEME"
    printf ' 主题字体   : %s\n' "$FONT"
    printf '%s\n' "-----------------------------------------------"

    if [[ "$ASSUME_YES" == "0" && "$DRY_RUN" == "0" ]]; then
        printf '确认开始？[y/N] '
        read -r ans
        [[ "$ans" == "y" || "$ans" == "Y" || "$ans" == "yes" ]] || { log "已取消"; exit 0; }
    fi

    install_packages
    local zbin
    zbin="$(command -v zsh || true)"
    [[ -n "$zbin" ]] || die "zsh 安装后仍找不到可执行文件，请检查安装日志"
    ok "zsh: $zbin ($("$zbin" --version 2>/dev/null || echo unknown))"

    install_fonts || true
    install_optional_tools
    install_omz            # 内含 ensure_theme：主题下载到本地
    write_shared_config

    # root
    ensure_shells_entry "$zbin"
    write_user_rc "root" "/root" ""
    [[ "$SKIP_CHSH" == "1" ]] || set_user_shell "root" "$zbin" || true

    # 普通用户：只写配置（继承同一份）；是否改默认 shell 由参数决定
    local line user home uid
    while read -r user home uid; do
        [[ -n "$user" ]] || continue
        write_user_rc "$user" "$home" "$uid"
    done < <(enumerate_normal_users)

    write_skel

    # 切换终端默认 shell
    if [[ "$SKIP_CHSH" == "0" ]]; then
        if [[ -n "$TARGET_USERS" ]]; then
            # 显式指定 > 全部用户 > 仅 root
            local u
            for u in ${TARGET_USERS//,/ }; do
                if id "$u" >/dev/null 2>&1; then
                    set_user_shell "$u" "$zbin" || true
                else
                    warn "用户不存在，跳过: $u"
                fi
            done
        elif [[ "$ONLY_ROOT" == "0" && "$ALL_USERS" == "1" ]]; then
            while read -r user home uid; do
                [[ -n "$user" ]] || continue
                set_user_shell "$user" "$zbin" || true
            done < <(enumerate_normal_users)
        fi
        # 未来新建的用户也默认用 zsh
        if command -v useradd >/dev/null 2>&1; then
            log "设置新建用户的默认 shell -> $zbin"
            run useradd -D -s "$zbin" || warn "useradd 默认 shell 设置失败（Alpine 等无 useradd 的系统请忽略）"
        fi
    fi

    printf '\n%s=============== 部署结果 ===============%s\n' "$C_BLUE" "$C_RESET"
    printf ' 共享配置 : %s\n' "$SHARED_RC"
    printf ' 主题     : %s\n' "$THEME"
    printf ' 主题字体 : %s\n' "$([[ "$FONT" == "none" ]] && echo "未安装" || echo "${FONT} (Nerd Font)")"
    printf ' root     : %s\n' "$(getent passwd root | cut -d: -f7)"
    if [[ "$DRY_RUN" == "0" ]]; then
        printf ' zsh      : %s\n' "$(zsh --version 2>/dev/null || echo '?')"
        printf ' 已配置用户: '
        local cnt=0 f
        for f in /root/.zshrc /etc/skel/.zshrc /home/*/.zshrc; do
            [[ -f "$f" ]] || continue
            cnt=$((cnt + 1))
        done
        printf '%s 个 ~/.zshrc\n' "$cnt"
    fi
    printf '%s======================================%s\n' "$C_BLUE" "$C_RESET"
    log "生效方式：重新登录，或在当前终端执行 exec zsh"
    log "个人定制请写入 ~/.zshrc.local（不会被本脚本覆盖）"
    if [[ "$FONT" != "none" ]]; then
        warn "重要：Linux 端只负责装好字体，真正的显示字体由客户端终端决定"
        log "请把 Windows Terminal / iTerm2 / PuTTY 的字体也设为同一个 Nerd Font："
        case "$FONT" in
            meslo)     log "  MesloLGS NF（推荐，powerlevel10k 官方配套）" ;;
            jetbrains) log "  JetBrainsMono Nerd Font" ;;
            hack)      log "  Hack Nerd Font" ;;
            firacode)  log "  FiraCode Nerd Font" ;;
            sourcecode) log "  SauceCodePro Nerd Font" ;;
        esac
    fi
}

main "$@"
