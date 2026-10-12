#!/usr/bin/env bash
# Arch Linux / WSL 环境迁移脚本
#
# 在旧系统：  ./env_deploy.sh export [目录]
# 在新系统：  ./env_deploy.sh deploy <目录或 tar.gz>
# 直接运行：  ./env_deploy.sh              （交互式菜单）
#
# 默认迁移：pacman 显式包、AUR 包、shell/git/vim/用户配置、启用的服务。
# 默认不迁移：数据库数据、SSH/GPG/云平台密钥、缓存和机器身份。
set -Eeuo pipefail
IFS=$'\n\t'

VERSION=1.0.0
SCRIPT_NAME=${0##*/}
SELF_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
LOG_FILE=${ENV_DEPLOY_LOG:-"$HOME/env-deploy.log"}
DRY_RUN=0
ASSUME_YES=0
INCLUDE_SECRETS=0
DEPLOY_DATABASE=0
MIRROR_CHOICE="aliyun"
LOCALE_CHOICE="zh_CN.UTF-8"
GIT_PROXY_CHOICE="gh-proxy"
DEPLOY_USER="${SUDO_USER:-${USER:-root}}"
DEPLOY_HOME="$HOME"
SUDO=()

__OPS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# shellcheck source=/dev/null
source "${__OPS_DIR}/lib/lib.sh"
unset __OPS_DIR
Lib::bootstrap "$LOG_FILE"
Lib::install_err_trap

need(){ command -v "$1" >/dev/null 2>&1 || die "缺少命令：$1"; }
confirm(){ ((ASSUME_YES)) && return 0; Ui::confirm UI "$1" n; }
log(){ Logger::raw LOG "$*"; }

usage(){ cat <<EOF
$SCRIPT_NAME v$VERSION
用法：
  $SCRIPT_NAME export [目录]                 导出当前 Arch 环境
  $SCRIPT_NAME deploy <目录|tar.gz>          部署导出的环境
  $SCRIPT_NAME                               进入交互式菜单

选项：
  -y, --yes             自动确认非破坏性询问
  -n, --dry-run         只显示命令，不修改系统
      --include-secrets 导出 SSH/GPG 等敏感文件（默认跳过）
      --database        部署数据库软件、配置和服务（不迁移数据）
      --mirror NAME     软件源：aliyun（默认）|tsinghua|ustc|huawei|official
      --locale LOCALE   locale：zh_CN.UTF-8（默认）或 en_US.UTF-8
      --git-proxy NAME  GitHub 代理：gh-proxy（默认）|ghproxy|ghapi|none
      --log FILE        日志文件
EOF
}

parse_args(){
  ACTION=""; TARGET=""
  while (($#)); do case $1 in
    export|deploy|menu) ACTION=$1; shift; [[ $ACTION != menu && $# -gt 0 && $1 != -* ]] && TARGET=$1 && shift || true ;;
    -y|--yes) ASSUME_YES=1; shift;; -n|--dry-run) DRY_RUN=1; shift;;
    --include-secrets) INCLUDE_SECRETS=1; shift;; --database) DEPLOY_DATABASE=1; shift;;
    --mirror) (($#>1)) || die '--mirror 缺少参数'; MIRROR_CHOICE=$2; shift 2;; --mirror=*) MIRROR_CHOICE=${1#*=}; shift;;
    --locale) (($#>1)) || die '--locale 缺少参数'; LOCALE_CHOICE=$2; shift 2;; --locale=*) LOCALE_CHOICE=${1#*=}; shift;;
    --git-proxy) (($#>1)) || die '--git-proxy 缺少参数'; GIT_PROXY_CHOICE=$2; shift 2;; --git-proxy=*) GIT_PROXY_CHOICE=${1#*=}; shift;;
    --log) (($#>1)) || die '--log 缺少参数'; LOG_FILE=$2; shift 2;; --log=*) LOG_FILE=${1#*=}; shift;;
    -h|--help) usage; exit 0;; -V|--version) echo "$VERSION"; exit 0;;
    *) die "未知参数：$1（使用 --help 查看）";; esac; done
}

check_arch(){
  [[ $(uname -s) == Linux ]] || die '仅支持 Linux/Arch Linux。'
  [[ -r /etc/os-release ]] || die '无法读取 /etc/os-release。'
  local id; id=$(sed -n 's/^ID=//p' /etc/os-release | tr -d '"')
  [[ $id == arch || $id == manjaro || $id == endeavouros || $id == artix ]] || warn "当前发行版为 $id，脚本按 Arch/pacman 处理。"
  need pacman
  if ((EUID)); then command -v sudo >/dev/null 2>&1 || die '需要 root 或 sudo。'; SUDO=(sudo); fi
}

setup_wsl_user(){
  ((EUID==0)) || return 0
  [[ -f /proc/sys/kernel/osrelease ]] && grep -qi microsoft /proc/sys/kernel/osrelease || return 0
  [[ -f /etc/env-deploy-user-initialized ]] && return 0
  info '检测到 WSL，先初始化 root 和普通管理员账号。'
  if ! passwd -S root 2>/dev/null | grep -q ' P '; then
    info '请设置 root 密码（用于维护；密码不会写入导出文件）。'
    run passwd root
  else
    confirm 'root 已有密码，是否重新设置？' && run passwd root || true
  fi
  local name p1 p2
  read -r -p '新建普通用户名（默认 arch）：' name || true
  name=${name:-arch}
  [[ $name =~ ^[a-z_][a-z0-9_-]*$ ]] || die '用户名格式不合法。'
  if id "$name" >/dev/null 2>&1; then warn "用户 $name 已存在，将更新其管理员权限。"; else run useradd -m -s /bin/bash "$name"; fi
  info "请为 $name 设置密码。"
  run passwd "$name"
  run usermod -aG wheel "$name"
  # 新安装的 Arch/WSL 可能还没有 pacman 仓库数据库，先初始化默认镜像。
  configure_mirror "$MIRROR_CHOICE"
  run "${SUDO[@]}" pacman -Sy --needed --noconfirm sudo
  if ! grep -qE '^%wheel[[:space:]]+ALL=\(ALL:ALL\)[[:space:]]+ALL' /etc/sudoers; then
    printf '%%wheel ALL=(ALL:ALL) ALL\n' | run tee -a /etc/sudoers >/dev/null
  fi
  if [[ ! -f /etc/wsl.conf ]] || ! grep -q '^default=' /etc/wsl.conf; then
    { [[ -f /etc/wsl.conf ]] && cat /etc/wsl.conf; printf '\n[user]\ndefault=%s\n' "$name"; } | run tee /etc/wsl.conf >/dev/null
  else
    sed -i -E "s/^default=.*/default=$name/" /etc/wsl.conf
  fi
  DEPLOY_USER=$name; DEPLOY_HOME=$(getent passwd "$name" | cut -d: -f6)
  ok "已设置 WSL 默认用户：$DEPLOY_USER（wheel 管理员）"
  touch /etc/env-deploy-user-initialized
  cat <<EOF

用户初始化已完成。为确保后续文件归属和 sudo 环境正确，脚本现在退出。
请执行：
  wsl.exe --terminate <发行版名>   （在 Windows PowerShell 中执行）
  # 重新进入 WSL 后，以 $name 身份运行：
  $SCRIPT_NAME deploy <导出目录或 tar.gz>
EOF
  exit 0
}

configure_locale(){
  local loc=${1:-zh_CN.UTF-8}
  [[ $loc == zh_CN.UTF-8 || $loc == en_US.UTF-8 ]] || die "不支持的 locale：$loc（可选 zh_CN.UTF-8 或 en_US.UTF-8）"
  info "配置 UTF-8 locale：$loc"
  if ((DRY_RUN)); then
    printf '[dry-run] 启用 /etc/locale.gen 中的 %s，生成 locale，并写入 /etc/locale.conf\n' "$loc"
    return
  fi
  run "${SUDO[@]}" sed -i -E "s/^[# ]*(${loc//./\\.})[[:space:]]*$/\\1/" /etc/locale.gen
  run "${SUDO[@]}" locale-gen
  printf 'LANG=%s\nLANGUAGE=%s:%s\nLC_ALL=%s\n' "$loc" "${loc%%_*}" "${loc%%_*}" "$loc" | run "${SUDO[@]}" tee /etc/locale.conf >/dev/null
  local home=${DEPLOY_HOME:-$HOME} line f
  for f in "$home/.bashrc" "$home/.zshrc"; do
    touch "$f"
    for line in "export LANG=$loc" "export LC_ALL=$loc"; do
      grep -qxF "$line" "$f" 2>/dev/null || printf '%s\n' "$line" >> "$f"
    done
  done
  chown "$DEPLOY_USER":"$DEPLOY_USER" "$home/.bashrc" "$home/.zshrc" 2>/dev/null || true
  ok "locale 已启用：$loc"
}

configure_wsl(){
  [[ -f /proc/sys/kernel/osrelease ]] && grep -qi microsoft /proc/sys/kernel/osrelease || return 0
  info '配置 WSL interop 和 Windows PATH'
  local tmp; tmp=$(mktemp)
  if [[ -f /etc/wsl.conf ]]; then cp -a /etc/wsl.conf "$tmp"; else : > "$tmp"; fi
  grep -q '^\[interop\]' "$tmp" || printf '\n[interop]\nenabled=true\nappendWindowsPath=true\n' >> "$tmp"
  grep -q '^\[automount\]' "$tmp" || printf '\n[automount]\nenabled=true\nroot=/mnt/\noptions=metadata,umask=22,fmask=11\n' >> "$tmp"
  run "${SUDO[@]}" cp "$tmp" /etc/wsl.conf
  rm -f "$tmp"
  ok 'WSL interop、Windows PATH 和 automount 已配置。'
}

user_setup_menu(){
  ((EUID==0)) || { warn '此功能需要 root，请用 sudo 运行脚本。'; return; }
  local name a
  read -r -p '用户名（输入已有用户或新用户名，默认 arch）：' name || true
  name=${name:-arch}
  [[ $name =~ ^[a-z_][a-z0-9_-]*$ ]] || { warn '用户名格式不合法。'; return; }
  if ! id "$name" >/dev/null 2>&1; then
    run useradd -m -s /bin/bash "$name"
  fi
  info "请设置用户 $name 的密码"
  run passwd "$name"
  run usermod -aG wheel "$name"
  if ! command -v sudo >/dev/null 2>&1; then
    configure_mirror "$MIRROR_CHOICE"
    run pacman -Sy --needed --noconfirm sudo
  fi
  grep -qE '^%wheel[[:space:]]+ALL=\(ALL:ALL\)[[:space:]]+ALL' /etc/sudoers || printf '%%wheel ALL=(ALL:ALL) ALL\n' | run tee -a /etc/sudoers >/dev/null
  if [[ -f /etc/wsl.conf ]]; then
    if grep -q '^default=' /etc/wsl.conf; then sed -i -E "s/^default=.*/default=$name/" /etc/wsl.conf
    else printf '\n[user]\ndefault=%s\n' "$name" | run tee -a /etc/wsl.conf >/dev/null; fi
  else
    printf '[user]\ndefault=%s\n' "$name" | run tee /etc/wsl.conf >/dev/null
  fi
  ok "用户 $name 已设置密码并加入 wheel，已设为 WSL 默认用户。"
  info '请从 Windows 执行 wsl --shutdown 后重新进入 WSL 使默认用户生效。'
}

install_base_tools(){
  info '安装 Arch 基础工具'
  configure_mirror "$MIRROR_CHOICE"
  local pkgs=(sudo base-devel git vim zsh curl wget ca-certificates unzip tar gzip less man-db openssh which procps-ng inetutils bind)
  run "${SUDO[@]}" pacman -Syu --needed --noconfirm "${pkgs[@]}"
  ok '基础工具安装完成。'
}

export_env(){
  local out=${TARGET:-"$PWD/arch-env-$(hostname)-$(date +%Y%m%d-%H%M%S)"}
  [[ -e $out ]] && die "目标已存在：$out"
  mkdir -p "$out"/packages "$out"/home "$out"/system "$out"/database "$out"/common
  info "导出软件包清单"
  pacman -Qqe 2>/dev/null | sort -u > "$out/packages/explicit.txt"
  pacman -Qqm 2>/dev/null | sort -u > "$out/packages/foreign.txt"
  comm -23 "$out/packages/explicit.txt" "$out/packages/foreign.txt" > "$out/packages/explicit-repo.txt" || cp "$out/packages/explicit.txt" "$out/packages/explicit-repo.txt"
  pacman -Qq 2>/dev/null | sort -u > "$out/packages/all.txt"
  pacman -Q 2>/dev/null | sort -u > "$out/packages/versions.txt"
  command -v yay >/dev/null 2>&1 && yay -Qqm 2>/dev/null | sort -u > "$out/packages/aur-yay.txt" || :
  command -v paru >/dev/null 2>&1 && paru -Qqm 2>/dev/null | sort -u > "$out/packages/aur-paru.txt" || :
  pacman -Qq | grep -E '^(mariadb|mysql|postgresql|redis|mongodb|sqlite|memcached)' | sort -u > "$out/database/packages.txt" || :
  for cfg in /etc/my.cnf /etc/my.cnf.d /etc/postgresql /etc/redis /etc/redis.conf /etc/mongod.conf /etc/mongodb.conf; do
    [[ -e $cfg ]] || continue
    mkdir -p "$out/database$(dirname "$cfg")"
    cp -a "$cfg" "$out/database$(dirname "$cfg")/"
  done
  pacman -Qq | grep -E '^(mariadb|mysql|postgresql|redis|mongodb|sqlite|memcached)' | sort -u > "$out/packages/database.txt" || :
  pacman -Qi 2>/dev/null | awk -F': +' '/^Name/{n=$2}/^Install Date/{print n"\t"$2}' > "$out/packages/install-dates.txt" || :
  info "导出用户配置"
  local files=(.bashrc .bash_profile .zshrc .zprofile .vimrc .gitconfig .gitignore_global .npmrc .p10k.zsh .tmux.conf)
  for f in "${files[@]}"; do [[ -e $HOME/$f || -L $HOME/$f ]] && cp -a "$HOME/$f" "$out/home/"; done
  # .vimrc 常见为指向 /etc/vim/vimrc.local 的软链接，迁移时保存实际内容。
  if [[ -L $HOME/.vimrc && -r $HOME/.vimrc ]]; then
    # 先删除刚复制的目标软链接，否则 cp -L 会跟随目标链接并判断为同一文件。
    rm -f "$out/home/.vimrc"
    cp -L "$HOME/.vimrc" "$out/home/.vimrc"
  fi
  [[ -r /mnt/d/share/vimrc ]] && cp -a /mnt/d/share/vimrc "$out/home/vimrc.shared"
  if [[ -r /etc/vim/vimrc.local ]]; then
    mkdir -p "$out/system/vim"
    cp -a /etc/vim/vimrc.local "$out/system/vim/vimrc.local"
  elif [[ -r /mnt/d/share/vimrc ]]; then
    mkdir -p "$out/system/vim"
    cp -a /mnt/d/share/vimrc "$out/system/vim/vimrc.local"
  fi
  if [[ -d /usr/local/share/zsh-config ]]; then
    mkdir -p "$out/system"
    cp -a /usr/local/share/zsh-config "$out/system/"
  fi
  # 同时收集可独立复用的常用配置和安装脚本。
  for common in vimrc setup_vimrc.sh setup-zsh.sh; do
    [[ -r /mnt/d/share/$common ]] && cp -a "/mnt/d/share/$common" "$out/common/"
  done
  [[ -r /etc/vim/vimrc.local ]] && cp -a /etc/vim/vimrc.local "$out/common/vimrc.local"
  [[ -r /usr/local/share/zsh-config/zshrc ]] && cp -a /usr/local/share/zsh-config/zshrc "$out/common/zshrc.global"
  for d in .config .local/bin .vim .oh-my-zsh .zsh .zfunc; do [[ -e $HOME/$d ]] && cp -a "$HOME/$d" "$out/home/"; done
  if ((INCLUDE_SECRETS)); then
    for d in .ssh .gnupg .pki .aws .config/gh .config/gcloud; do [[ -e $HOME/$d ]] && cp -a "$HOME/$d" "$out/home/"; done
  else
    printf '%s\n' '.ssh .gnupg .pki .aws .config/gh .config/gcloud .netrc' > "$out/EXCLUDED_SECRETS.txt"
  fi
  info "导出系统设置和服务"
  cp -a /etc/pacman.conf "$out/system/" 2>/dev/null || :
  cp -a /etc/makepkg.conf "$out/system/" 2>/dev/null || :
  pacman -Qqg base-devel 2>/dev/null > "$out/packages/base-devel.txt" || :
  systemctl list-unit-files --state=enabled --type=service --no-legend 2>/dev/null | awk '{print $1}' | sort -u > "$out/system/enabled-services.txt" || :
  systemctl list-unit-files --state=enabled --type=timer --no-legend 2>/dev/null | awk '{print $1}' | sort -u > "$out/system/enabled-timers.txt" || :
  { printf 'hostname=%s\nuser=%s\nuid=%s\ncreated=%s\n' "$(hostname)" "$USER" "$(id -u)" "$(date -Is)"; cat /etc/os-release; } > "$out/manifest.txt"
  cat > "$out/README.txt" <<EOF
此目录由 $SCRIPT_NAME 生成。
部署：$SCRIPT_NAME deploy $out
默认跳过数据库数据和敏感密钥。数据库只在部署时明确选择 --database 才安装。
common/ 目录保存 Vim/Zsh 通用配置和可复用安装脚本。
EOF
  ok "环境已导出到：$out"
  if confirm '是否同时打包为 tar.gz？'; then tar -C "$(dirname "$out")" -czf "$out.tar.gz" "$(basename "$out")"; ok "已生成：$out.tar.gz"; fi
}

extract_bundle(){
  local src=$1
  [[ -d $src ]] && { printf '%s' "$(cd "$src" && pwd)"; return; }
  [[ -f $src ]] || die "找不到导出目录或压缩包：$src"
  local tmp; tmp=$(mktemp -d); tar -xzf "$src" -C "$tmp" || die '解压失败。'; printf '%s' "$(find "$tmp" -mindepth 1 -maxdepth 1 -type d -print -quit)"
}

install_pkg_file(){
  local file=$1 label=$2; [[ -s $file ]] || { warn "$label 清单为空，跳过。"; return; }
  mapfile -t pkgs < <(sed 's/[[:space:]]*#.*//' "$file" | awk 'NF && $1 !~ /^-/' | sort -u)
  ((${#pkgs[@]})) || return
  info "安装 $label（${#pkgs[@]} 个）"
  if [[ $label == *AUR* || $label == *foreign* ]]; then
    local helper=''
    command -v yay >/dev/null 2>&1 && helper=yay
    [[ -n $helper ]] || command -v paru >/dev/null 2>&1 && helper=paru
    if [[ -n $helper ]]; then run "$helper" -S --needed --noconfirm "${pkgs[@]}"; else warn '未找到 yay/paru，跳过 AUR 包；可安装后手动重试。'; fi
  else
    run "${SUDO[@]}" pacman -S --needed --noconfirm "${pkgs[@]}"
  fi
}

ensure_vim(){
  info '安装 Vim（含运行时和语法支持）'
  run "${SUDO[@]}" pacman -S --needed --noconfirm vim
}

ensure_zsh(){
  info '安装 Zsh，并设置新用户默认 shell'
  run "${SUDO[@]}" pacman -S --needed --noconfirm zsh
  if command -v chsh >/dev/null 2>&1 && [[ -n ${DEPLOY_USER:-} && ${DEPLOY_USER:-root} != root ]]; then
    run "${SUDO[@]}" chsh -s /bin/zsh "$DEPLOY_USER"
  fi
  local home=${DEPLOY_HOME:-$HOME}
  if [[ ! -e $home/.zshrc ]]; then
    printf '%s\n' '# Zsh configuration restored by env_deploy.sh' 'autoload -Uz compinit && compinit' > "$home/.zshrc"
    chown "$DEPLOY_USER":"$DEPLOY_USER" "$home/.zshrc" 2>/dev/null || true
  fi
}

configure_global_vimrc(){
  local root=$1 src="$root/system/vim/vimrc.local"
  [[ -r $src ]] || src="$root/common/vimrc.local"
  [[ -r $src ]] || src="$root/common/vimrc"
  [[ -r $src ]] || return 0
  info '恢复全局 Vim 配置：/etc/vim/vimrc.local'
  run "${SUDO[@]}" mkdir -p /etc/vim
  [[ -f /etc/vim/vimrc.local ]] && run "${SUDO[@]}" cp -a /etc/vim/vimrc.local "/etc/vim/vimrc.local.env-deploy.$(date +%Y%m%d-%H%M%S).bak"
  run "${SUDO[@]}" cp -a "$src" /etc/vim/vimrc.local
  # Arch 的系统 vimrc 通常会加载 vimrc.local；若没有，则补一行 source。
  if [[ -f /etc/vimrc ]] && ! grep -q 'vimrc.local' /etc/vimrc; then
    printf '\nif filereadable("/etc/vim/vimrc.local") | source /etc/vim/vimrc.local | endif\n' | run "${SUDO[@]}" tee -a /etc/vimrc >/dev/null
  fi
}

configure_global_zsh(){
  local root=$1 src="$root/system/zsh-config"
  if [[ -d $src ]]; then
    info '恢复全局 Zsh 主题和插件：/usr/local/share/zsh-config'
    if [[ -d /usr/local/share/zsh-config ]]; then
      run "${SUDO[@]}" mv /usr/local/share/zsh-config "/usr/local/share/zsh-config.env-deploy.$(date +%Y%m%d-%H%M%S).bak"
    fi
    run "${SUDO[@]}" mkdir -p /usr/local/share
    run "${SUDO[@]}" cp -a "$src" /usr/local/share/zsh-config
    return 0
  fi
  if [[ -r $root/common/zshrc.global ]]; then
    info '使用导出包中的通用 Zsh 配置'
    run "${SUDO[@]}" mkdir -p /usr/local/share/zsh-config
    run "${SUDO[@]}" cp -a "$root/common/zshrc.global" /usr/local/share/zsh-config/zshrc
    return 0
  fi
  # 兼容旧导出包：.zshrc 可能引用全局配置，但导出时未收集该目录。
  [[ -f /usr/local/share/zsh-config/zshrc ]] && return 0
  warn '导出包缺少全局 Zsh 配置，生成基础配置以避免 .zshrc 启动报错。'
  run "${SUDO[@]}" mkdir -p /usr/local/share/zsh-config
  cat <<'EOF' | run "${SUDO[@]}" tee /usr/local/share/zsh-config/zshrc >/dev/null
# env_deploy.sh fallback global zsh configuration
autoload -Uz compinit && compinit
setopt autocd interactivecomments
bindkey -e
PROMPT='%n@%m:%~%# '
EOF
}

configure_git_proxy(){
  local choice=${1:-gh-proxy} base home=${DEPLOY_HOME:-$HOME}
  case $choice in
    gh-proxy) base='https://gh-proxy.com/https://github.com/' ;;
    ghproxy)  base='https://ghproxy.net/https://github.com/' ;;
    ghapi)    base='https://gh.api.99988866.xyz/https://github.com/' ;;
    none)     info '跳过 GitHub Git 代理配置。'; return 0 ;;
    *) die "未知 Git 代理：$choice（可选 gh-proxy/ghproxy/ghapi/none）" ;;
  esac
  command -v git >/dev/null 2>&1 || { warn '未安装 git，跳过 Git 代理配置。'; return 0; }
  info "配置 GitHub 下载代理：$choice"
  # 使用 git config 而不是手工改文件，自动处理引号和已有配置。
  run git config --global --unset-all url."https://gh-proxy.com/https://github.com/".insteadOf || true
  run git config --global --unset-all url."https://ghproxy.net/https://github.com/".insteadOf || true
  run git config --global --unset-all url."https://gh.api.99988866.xyz/https://github.com/".insteadOf || true
  [[ $choice == none ]] || run git config --global url."$base".insteadOf 'https://github.com/'
  chown "$DEPLOY_USER":"$DEPLOY_USER" "$home/.gitconfig" 2>/dev/null || true
}

configure_mirror(){
  local choice=${1:-aliyun} url backup
  case $choice in
    aliyun)   url='https://mirrors.aliyun.com/archlinux/$repo/os/$arch' ;;
    tsinghua) url='https://mirrors.tuna.tsinghua.edu.cn/archlinux/$repo/os/$arch' ;;
    ustc)     url='https://mirrors.ustc.edu.cn/archlinux/$repo/os/$arch' ;;
    huawei)   url='https://repo.huaweicloud.com/archlinux/$repo/os/$arch' ;;
    official) url='https://geo.mirror.pkgbuild.com/$repo/os/$arch' ;;
    *) die "未知软件源：$choice（可选 aliyun/tsinghua/ustc/huawei/official）" ;;
  esac
  local mirror='/etc/pacman.d/mirrorlist'
  backup="${mirror}.env-deploy.$(date +%Y%m%d-%H%M%S).bak"
  info "配置 Arch 软件源：$choice"
  if ((DRY_RUN)); then printf '[dry-run] 备份 %s -> %s，并写入 %s\n' "$mirror" "$backup" "$url"; return; fi
  [[ -f $mirror ]] && run "${SUDO[@]}" cp -a "$mirror" "$backup"
  printf '# Generated by %s at %s\nServer = %s\n' "$SCRIPT_NAME" "$(date -Is)" "$url" | run "${SUDO[@]}" tee "$mirror" >/dev/null
  ok "软件源已切换为 $choice（备份：$backup）"
}

copy_home(){
  local root=$1 src=$root/home
  [[ -d $src ]] || return
  info '恢复用户配置（覆盖前会备份到 ~/.env-deploy-backup）'
  local home=$DEPLOY_HOME backup="$DEPLOY_HOME/.env-deploy-backup-$(date +%Y%m%d-%H%M%S)"; mkdir -p "$backup"
  for item in "$src"/* "$src"/.[!.]* "$src"/..?*; do [[ -e $item || -L $item ]] || continue; local name=${item##*/}; [[ $name == .vimrc ]] && continue; [[ $name == .ssh || $name == .gnupg || $name == .pki || $name == .aws ]] && ((INCLUDE_SECRETS==0)) && continue; [[ -e $home/$name || -L $home/$name ]] && cp -a "$home/$name" "$backup/"; cp -a "$item" "$home/"; done
  chown -R "$DEPLOY_USER":"$DEPLOY_USER" "$home" 2>/dev/null || true
}

deploy_env(){
  local root; root=$(extract_bundle "${TARGET:?请指定导出目录或 tar.gz}")
  [[ -f $root/manifest.txt ]] || die '无效的环境导出目录（缺少 manifest.txt）。'
  info "开始部署：$root"
  setup_wsl_user
  confirm '将更新 pacman 数据库并安装导出清单，继续？' || { info '已取消。'; return; }
  configure_mirror "$MIRROR_CHOICE"
  run "${SUDO[@]}" pacman -Syu --noconfirm
  install_base_tools
  ensure_vim
  configure_global_vimrc "$root"
  ensure_zsh
  configure_locale "$LOCALE_CHOICE"
  configure_wsl
  configure_global_zsh "$root"
  install_pkg_file "$root/packages/explicit-repo.txt" '显式软件包'
  install_pkg_file "$root/packages/foreign.txt" 'AUR/foreign 软件包'
  copy_home "$root"
  configure_git_proxy "$GIT_PROXY_CHOICE"
  [[ -f $root/system/pacman.conf ]] && warn '发现旧 pacman.conf，已保留在导出目录，未自动覆盖当前配置。'
  if ((DEPLOY_DATABASE)); then
    install_pkg_file "$root/database/packages.txt" '数据库软件包'
    if [[ -d $root/database/etc ]]; then
      info '恢复数据库配置（不会复制 /var/lib 下的数据目录）'
      while IFS= read -r -d '' cfg; do
        rel=${cfg#"$root/database"}; dest="/etc$rel"
        [[ -e $dest ]] && run "${SUDO[@]}" cp -a "$dest" "$dest.env-deploy.$(date +%Y%m%d-%H%M%S).bak"
        run "${SUDO[@]}" mkdir -p "$(dirname "$dest")"
        run "${SUDO[@]}" cp -a "$cfg" "$dest"
      done < <(find "$root/database/etc" -mindepth 1 -print0)
    fi
    info '仅安装数据库软件和配置；不会复制 /var/lib 下的数据目录。'
  fi
  if [[ -s $root/system/enabled-services.txt ]]; then
    while IFS= read -r svc; do [[ -n $svc ]] || continue; if systemctl cat "$svc" >/dev/null 2>&1; then run "${SUDO[@]}" systemctl enable "$svc"; else warn "服务不存在，跳过：$svc"; fi; done < "$root/system/enabled-services.txt"
  fi
  ok '部署完成。建议重新登录 shell，并检查 WSL 中的 systemd、用户和服务状态。'
}

menu(){
  while :; do
    printf '\n%sArch 环境部署工具%s\n  1) 配置用户密码 / 设置 WSL 默认用户\n  2) 安装基础工具\n  3) 导出当前环境\n  4) 部署导出环境\n  5) 查看帮助\n  0) 退出\n' "$C_BLUE" "$C_RESET"
    local n; read -r -p '请选择：' n || return
    case $n in
      1) user_setup_menu;;
      2) install_base_tools;;
      3) read -r -p '导出目录（回车使用默认）：' TARGET || true; ACTION=export; export_env; TARGET=;;
      4) read -r -p '导出目录或 tar.gz：' TARGET || true; [[ -n $TARGET ]] || continue; read -r -p '软件源 [aliyun/tsinghua/ustc/huawei/official，默认 aliyun]：' a || true; [[ -n $a ]] && MIRROR_CHOICE=$a; read -r -p 'locale [zh_CN.UTF-8/en_US.UTF-8，默认 zh_CN.UTF-8]：' a || true; [[ -n $a ]] && LOCALE_CHOICE=$a; read -r -p 'GitHub 代理 [gh-proxy/ghproxy/ghapi/none，默认 gh-proxy]：' a || true; [[ -n $a ]] && GIT_PROXY_CHOICE=$a; read -r -p '同时部署数据库软件和配置？[y/N] ' a || true; [[ ${a,,} == y || ${a,,} == yes ]] && DEPLOY_DATABASE=1; ACTION=deploy; deploy_env; TARGET=;;
      5) usage;; 0) return;; *) warn '无效选择。';; esac
  done
}

main(){ parse_args "$@"; check_arch; mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true; log "start $*"; case ${ACTION:-menu} in export) export_env;; deploy) deploy_env;; menu) menu;; esac; }
main "$@"


# =============================================================================
#  面板声明（供 panel.sh 自动发现，不参与脚本执行）
# =============================================================================
# PANEL: 环境迁移 | 系统维护 | 0 | Arch 环境导出 / 新机部署
# PANEL-CMD: 导出当前环境 | export {{导出目录:/tmp/arch-env}} | 包清单 + shell/git/vim 配置
# PANEL-CMD: 部署到本机 | deploy {{目录或 tar.gz:/tmp/arch-env.tar.gz}} | 在新系统上还原
# PANEL-CMD: 交互式菜单 | menu | 脚本自带菜单
