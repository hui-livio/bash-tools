#!/usr/bin/env bash
# apt_cleanup.sh
# 用法:
#   sudo bash apt_cleanup.sh              # 安全清理
#   sudo bash apt_cleanup.sh --purge-cuda # 额外卸载 CUDA/NVIDIA 相关包

set -u

PURGE_CUDA=0
if [[ "${1:-}" == "--purge-cuda" ]]; then
  PURGE_CUDA=1
fi

if [[ $EUID -ne 0 ]]; then
  echo "请用 sudo 运行: sudo bash $0 [--purge-cuda]"
  exit 1
fi

echo "=== 1. 当前 dpkg 审计 ==="
dpkg --audit || true

echo
echo "=== 2. 尝试修复半配置包 ==="
if ! dpkg --configure -a; then
  echo "dpkg --configure -a 失败。"
  echo "你可以手动尝试强制移除有问题的包，例如："
  echo "  sudo dpkg --remove --force-remove-reinstreq cuda-toolkit-13-1-config-common"
fi

echo
echo "=== 3. 修复依赖 ==="
apt --fix-broken install -y || true

if [[ $PURGE_CUDA -eq 1 ]]; then
  echo
  echo "=== 4. 查找 CUDA/NVIDIA 相关包 ==="
  PKGS=$(dpkg-query -W -f='${Package}\n' \
    'cuda*' 'nvidia*' 'libcudnn*' 'libnvidia*' 'libcuda*' 2>/dev/null | sort -u)

  if [[ -z "$PKGS" ]]; then
    echo "未找到相关包。"
  else
    echo "$PKGS"
    echo
    read -r -p "确认卸载以上所有包？这会移除 NVIDIA 驱动和 CUDA，可能影响图形界面。输入 yes 继续: " ans
    if [[ "$ans" == "yes" ]]; then
      # shellcheck disable=SC2086
      apt purge -y $PKGS

      echo
      read -r -p "是否同时删除残留目录 /usr/local/cuda* 和 CUDA apt 源？输入 yes 继续: " ans2
      if [[ "$ans2" == "yes" ]]; then
        rm -rf /usr/local/cuda* /var/cuda* /etc/apt/sources.list.d/cuda* /etc/apt/sources.list.d/nvidia*
        echo "残留目录和源已清理。"
      fi
    else
      echo "已跳过卸载。"
    fi
  fi
else
  echo
  echo "=== 4. 跳过 CUDA/NVIDIA 卸载（如需卸载请加 --purge-cuda）==="
fi

echo
echo "=== 5. 自动移除无用依赖 ==="
apt autoremove -y --purge

echo
echo "=== 6. 清理 apt 缓存 ==="
apt clean
apt autoclean

echo
echo "=== 7. 更新软件包列表 ==="
apt update

echo
echo "=== 8. 再次审计 ==="
dpkg --audit || true

echo
echo "完成。"
