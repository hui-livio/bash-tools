#!/usr/bin/env bash
# ============================================================
# ssh-key-router.sh —— SSH 密钥创建 + 多平台路由自动配置
#
# 功能：
#   add    新建 ed25519 密钥，并自动写入 ~/.ssh/config 路由
#   remove 永久删除指定平台的密钥和路由区块
#   list   列出当前已配置的平台路由
#
# 用法：
#   ./ssh-key-router.sh add <github|gitlab|gitee>
#   ./ssh-key-router.sh add custom <名称>
#   ./ssh-key-router.sh remove <平台名>
#   ./ssh-key-router.sh list
#
# 设计说明：
#   - 每个平台一把独立密钥（id_ed25519_<平台名>），IdentitiesOnly 隔离互不串用
#   - GitHub 预设走 ssh.github.com:443 通道（兼容代理拦截 22 端口的环境）
#   - GitLab 预设对应 gitlab.com；私有部署的 GitLab 请用 custom 模式
#   - remove 会永久删除对应私钥和公钥，不提供备份或回滚
# ============================================================

set -u

# 密钥目录（默认 ~/.ssh；测试时可用环境变量 SSH_KEY_DIR 覆盖）
SSH_DIR="${SSH_KEY_DIR:-$HOME/.ssh}"
CONFIG_FILE="$SSH_DIR/config"
KNOWN_HOSTS="$SSH_DIR/known_hosts"

# ---------- 颜色输出 ----------
if [[ -t 1 ]]; then
  C_INFO="\033[1;32m"; C_WARN="\033[1;33m"; C_ERR="\033[1;31m"; C_OFF="\033[0m"
else
  C_INFO=""; C_WARN=""; C_ERR=""; C_OFF=""
fi
info() { printf "${C_INFO}%s${C_OFF}\n" "$*"; }
warn() { printf "${C_WARN}[警告] %s${C_OFF}\n" "$*"; }
err()  { printf "${C_ERR}[错误] %s${C_OFF}\n" "$*"; }

usage() {
  cat <<'EOF'
用法：
  ./ssh-key-router.sh add <github|gitlab|gitee>          新建预设平台密钥并配置路由
  ./ssh-key-router.sh add custom [名称]                 新建自定义平台密钥并配置路由
  ./ssh-key-router.sh remove <平台名>                    永久删除密钥和路由
  ./ssh-key-router.sh list                               查看已配置的平台路由

示例：
  ./ssh-key-router.sh add github      # GitHub 官方（自动走 443 通道）
  ./ssh-key-router.sh add gitlab      # gitlab.com 公共站
  ./ssh-key-router.sh add custom work # 添加名为 work 的自建/其他平台
  ./ssh-key-router.sh remove github   # 永久删除 GitHub 的密钥与路由
EOF
}

# ---------- 平台预设解析 ----------
resolve_platform() {
  local platform_type="$1"
  PLATFORM="$2"
  PLATFORM_KEY="$SSH_DIR/id_ed25519_${PLATFORM}"

  case "$platform_type" in
    github)
      HOST="github.com"; HOSTNAME="ssh.github.com"; PORT=443
      KEY_URL="https://github.com/settings/keys"
      NOTE="GitHub 官方，走 ssh.github.com:443 通道（22 端口常被代理环境拦截）"
      ;;
    gitlab)
      HOST="gitlab.com"; HOSTNAME="gitlab.com"; PORT=22
      KEY_URL="https://gitlab.com/-/user_settings/ssh_keys"
      NOTE="gitlab.com 公共站；私有部署的 GitLab 请改用 custom 模式"
      ;;
    gitee)
      HOST="gitee.com"; HOSTNAME="gitee.com"; PORT=22
      KEY_URL="https://gitee.com/profile/sshkeys"
      NOTE="Gitee（码云）"
      ;;
    custom)
      HOST=""; HOSTNAME=""; PORT=22
      KEY_URL=""
      NOTE="自建平台（如私有 GitLab、公司 Git 服务）"
      # 交互式收集信息，连接地址和端口可分别覆盖 Host 与默认端口。
      local platform_name_in="" hostname_in="" port_in=""
      if [[ -z "$PLATFORM" ]]; then
        read -r -p "请输入平台名称（仅字母、数字、_、-）: " platform_name_in || true
        PLATFORM="$platform_name_in"
      fi
      if [[ ! "$PLATFORM" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]*$ ]]; then
        err "平台名称无效：仅允许以字母或数字开头，并包含字母、数字、_ 或 -。"
        exit 1
      fi
      PLATFORM_KEY="$SSH_DIR/id_ed25519_${PLATFORM}"
      read -r -p "请输入仓库地址里的 Host（如 git.company.com）: " HOST || true
      read -r -p "实际连接地址 [同上] : " hostname_in || true
      read -r -p "SSH 端口 [22] : " port_in || true
      HOSTNAME="${hostname_in:-$HOST}"
      PORT="${port_in:-22}"
      KEY_URL="请在对应平台网站的 SSH 公钥设置页添加"
      if [[ -z "$HOST" ]]; then
        err "Host 不能为空，已取消。"
        exit 1
      fi
      if [[ ! "$PORT" =~ ^[0-9]{1,5}$ ]] || (( 10#$PORT < 1 || 10#$PORT > 65535 )); then
        err "SSH 端口无效：请输入 1 到 65535 之间的数字。"
        exit 1
      fi
      ;;
    *)
      err "未知平台：$platform_type（支持 github / gitlab / gitee / custom）"
      usage
      exit 1
      ;;
  esac

  # 密钥备注（注释），回车用默认值
  local COMMENT_IN=""
  read -r -p "密钥备注/邮箱（回车默认 ${PLATFORM}-${HOST}）: " COMMENT_IN || true
  COMMENT="${COMMENT_IN:-${PLATFORM}-${HOST}}"
}

# ---------- config 区块操作 ----------
# 用 BEGIN/END 标记包裹，保证 add 幂等（重复执行是替换而不是叠加）
remove_block() {
  local tag="$1"
  [[ -f "$CONFIG_FILE" ]] || return 0
  awk -v tag="$tag" '
    $1 == "#" && $2 == "BEGIN" && $3 == tag { skip = 1 }
    skip && $1 == "#" && $2 == "END" && $3 == tag { skip = 0; next }
    !skip { print }
  ' "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
}

write_block() {
  remove_block "$PLATFORM"
  cat >> "$CONFIG_FILE" <<EOF

# BEGIN ${PLATFORM}
# ${PLATFORM} 路由（ssh-key-router.sh 自动生成，${NOTE}）
Host ${HOST}
    HostName ${HOSTNAME}
    User git
    Port ${PORT}
    IdentityFile ~/.ssh/id_ed25519_${PLATFORM}
    IdentitiesOnly yes
# END ${PLATFORM}
EOF
}

# ---------- 子命令 ----------
cmd_add() {
  [[ $# -ge 1 ]] || { err "缺少平台名。"; usage; exit 1; }
  local platform_type="$1"
  shift
  if [[ "$platform_type" == "custom" ]]; then
    [[ $# -le 1 ]] || { err "custom 最多只能指定一个平台名称。"; usage; exit 1; }
    resolve_platform "$platform_type" "${1:-}"
  else
    [[ $# -eq 0 ]] || { err "预设平台不接受额外参数。"; usage; exit 1; }
    resolve_platform "$platform_type" "$platform_type"
  fi

  # 防覆盖：已存在同平台密钥时拒绝，引导先 remove 后重新生成
  if [[ -e "$PLATFORM_KEY" ]]; then
    err "密钥已存在：$PLATFORM_KEY"
    echo "    如需重新生成，请先执行：$0 remove $PLATFORM"
    exit 1
  fi

  mkdir -p "$SSH_DIR" && chmod 700 "$SSH_DIR"

  info ">> 正在生成密钥（ed25519，无密码短语）：$PLATFORM_KEY"
  if ! ssh-keygen -t ed25519 -C "$COMMENT" -f "$PLATFORM_KEY" -N "" -q; then
    err "密钥生成失败。"
    exit 1
  fi
  chmod 600 "$PLATFORM_KEY"

  info ">> 正在写入路由配置：$CONFIG_FILE"
  write_block

  info ">> 正在抓取服务器主机公钥并加入 known_hosts"
  if ssh-keyscan -p "$PORT" -t ed25519,ecdsa,rsa "$HOSTNAME" >> "$KNOWN_HOSTS" 2>/dev/null; then
    info "   主机公钥已写入（首次连接不会再询问指纹）。"
  else
    warn "known_hosts 写入失败（可能是网络不通或权限受限）。"
    echo "    首次连接时会提示确认主机指纹，输入 yes 即可，不影响使用。"
  fi

  echo
  info "==== 完成！请把下面这行公钥添加到平台网站 ===="
  echo "    添加入口：$KEY_URL"
  echo "-------------------------------------------"
  cat "${PLATFORM_KEY}.pub"
  echo "-------------------------------------------"
  echo "    添加完成后，用下面命令验证（出现欢迎语即成功）："
  echo "    ssh -T git@${HOST}"
  echo
  warn "移除此平台会永久删除密钥：$0 remove $PLATFORM"
}

cmd_remove() {
  [[ $# -eq 1 ]] || { err "请指定一个平台名。"; usage; exit 1; }
  local platform="$1"
  if [[ ! "$platform" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]*$ ]]; then
    err "平台名称无效：仅允许以字母或数字开头，并包含字母、数字、_ 或 -。"
    exit 1
  fi
  local key="$SSH_DIR/id_ed25519_${platform}"

  if [[ ! -f "$key" && ! -f "$CONFIG_FILE" ]]; then
    warn "没有找到 $platform 的密钥或配置，无需移除。"
    exit 0
  fi

  if ! rm -f "$key" "${key}.pub"; then
    err "删除密钥失败：$key"
    exit 1
  fi
  info ">> 已永久删除 ${platform} 的私钥和公钥（若存在）。"

  remove_block "$platform"
  info ">> 已从 $CONFIG_FILE 移除 ${platform} 路由区块。"

  warn "注意：平台网站上登记的公钥仍然有效，建议到网站上一并删除以保安全。"
}

cmd_list() {
  [[ -f "$CONFIG_FILE" ]] || { info "还没有 $CONFIG_FILE，尚未配置任何平台。"; exit 0; }
  printf "%-10s %-24s %-24s %-6s %s\n" "平台" "Host" "实际地址" "端口" "密钥文件"
  printf "%s\n" "------------------------------------------------------------------------------------------------"
  awk '
    $1 == "#" && $2 == "BEGIN" { plat = $3; host = hn = port = key = "" }
    plat == "" { next }
    $1 == "Host"     { host = $2 }
    $1 == "HostName" { hn = $2 }
    $1 == "Port"     { port = $2 }
    $1 == "IdentityFile" { key = $2 }
    $1 == "#" && $2 == "END" {
      printf "%-10s %-24s %-24s %-6s %s\n", plat, host, hn, port, key
      plat = ""
    }
  ' "$CONFIG_FILE"
}

# ---------- 入口 ----------
main() {
  case "${1:-}" in
    add)    shift; cmd_add "$@" ;;
    remove) shift; cmd_remove "$@" ;;
    list)   cmd_list ;;
    -h|--help|help) usage ;;
    "")     usage; exit 1 ;;
    *)      err "未知命令：$1"; usage; exit 1 ;;
  esac
}

main "$@"
