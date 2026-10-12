#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""给每个脚本追加 # PANEL: / # PANEL-CMD: 声明，供 panel.sh 自动发现子命令。

追加在文件末尾（注释不影响执行，也不会打乱脚本顶部 sed -n '2,Np' 的 help 输出）。
"""
from pathlib import Path

BASE = Path(__file__).resolve().parent

META = {
    'cleanup.sh': (
        '系统清理 | 系统维护 | 1 | 修复包管理器故障、清理缓存',
        [
            ('安全清理（不动 CUDA/NVIDIA）', '', '审计 + 修复依赖 + 清缓存 + 刷新索引'),
            ('彻底卸载 CUDA/NVIDIA', '--purge-cuda', '额外卸载 CUDA/NVIDIA 包与残留目录'),
            ('演练（只看会做什么）', '--dry-run', '不改动系统'),
        ],
    ),
    'update-system.sh': (
        '系统更新 | 系统维护 | 1 | 刷新索引并升级全部软件包',
        [
            ('检查可升级项', '--check', '只读，不做任何更改'),
            ('升级全部软件包', '', '交互式，会先询问一次'),
            ('免确认升级', '-y', '自动确认并升级'),
            ('发行版级升级', '--full -y', '允许卸载有依赖冲突的旧包'),
        ],
    ),
    'configure-mirrors.sh': (
        '镜像源配置 | 软件源 | 1 | Arch / Debian / Ubuntu 切换国内镜像',
        [
            ('自动测速换源', '--auto', '并行测速，切到最快镜像站'),
            ('手动选择镜像站', '', '交互式菜单挑选 tuna/ustc/aliyun/huawei'),
            ('查看当前配置', '--show', '只读'),
            ('回滚到上一次备份', '--restore', '恢复 <原路径>.bak-<时间戳>'),
        ],
    ),
    'install-devtools.sh': (
        '开发工具 | 开发环境 | 1 | cmake/gcc/clang/python/node 等工具链',
        [
            ('标准集', '', '编译 + 调试 + 常用 CLI + 网络工具'),
            ('最小集', '-m', 'cmake/make/gcc/g++/gdb/python3/git'),
            ('完整集', '-f', '追加静态检查、valgrind、nmap/iperf3 等'),
            ('仅列出将要安装的包', '-l', '只读预览'),
            ('额外装 Node.js LTS', '--node-lts', '走 NodeSource 而非发行版仓库'),
        ],
    ),
    'setup-zsh.sh': (
        'zsh 环境 | Shell 环境 | 1 | 全用户共用一份 zsh 配置',
        [
            ('安装并切换到 zsh', '', 'oh-my-zsh + 主题 + 插件 + Nerd Font'),
            ('仅打印生成的配置', '--print-config', '只读，不改动系统'),
            ('只装配置不改默认 shell', '--skip-chsh', '配置到位，切换自行决定'),
            ('只给 root 切换', '--only-root', '其他人仅获得配置'),
        ],
    ),
    'setup_vimrc.sh': (
        'vim 配置 | Shell 环境 | 1 | 全用户通用 vim 配置',
        [
            ('安装（全局 + 新用户）', '', '写入 /etc/vim/vimrc.local + /etc/skel'),
            ('覆盖已存在的用户', '--all-users', '含 root 在内的所有已有用户'),
            ('额外配置 Neovim', '--nvim', '写入系统级 sysinit.vim'),
            ('卸载脚本所做改动', '--uninstall', '还原所有备份'),
        ],
    ),
    'cuda-manager.sh': (
        'CUDA 管理 | 开发环境 | 1 | 只装 Toolkit，不动显卡驱动',
        [
            ('环境检测', 'detect', '系统 / GPU / 驱动 / 已装版本'),
            ('列出可安装版本', 'list', '联网读取官方源全部版本'),
            ('安装指定版本', 'install {{CUDA 版本:12.6}}', '可精确到补丁号，如 12.6.3'),
            ('卸载指定版本或全部', 'uninstall {{版本或 all:all}}', '需逐字输入 DELETE 确认'),
            ('切换默认版本', 'use {{CUDA 版本:12.6}}', '改变 /usr/local/cuda 指向'),
            ('环境体检', 'doctor', '只读诊断'),
            ('一键修复', 'repair', '修复 dpkg 中断 / 残缺包 / 失效源'),
        ],
    ),
    'mariadb-manager.sh': (
        'MariaDB | 数据库 | 1 | 安装 / 卸载 / 体检一体化',
        [
            ('安装 MariaDB LTS', 'install', '向导式：版本、密码、远程、业务库'),
            ('卸载 MariaDB', 'uninstall', '可先做逻辑备份，需输入 DELETE 确认'),
            ('只读体检', 'status', '版本 / 服务 / 数据目录 / 登录连通性'),
            ('交互式向导', 'menu', '进入脚本自带菜单'),
            ('演练安装', 'install --dry-run --non-interactive', '只打印，不做变更'),
        ],
    ),
    'ssh-key-router.sh': (
        'SSH 密钥 | 安全 | 0 | 多平台独立密钥 + config 路由',
        [
            ('列出已配置平台', 'list', '当前 ~/.ssh/config 里的路由'),
            ('添加 GitHub 密钥', 'add github', '自动走 ssh.github.com:443'),
            ('添加 GitLab 密钥', 'add gitlab', 'gitlab.com 公共站'),
            ('添加 Gitee 密钥', 'add gitee', '码云'),
            ('添加自建平台', 'add custom {{平台名:work}}', '交互式收集 Host 与端口'),
            ('删除某平台密钥', 'remove {{平台名:github}}', '永久删除私钥与路由（不可恢复）'),
        ],
    ),
    'env_deploy.sh': (
        '环境迁移 | 系统维护 | 0 | Arch 环境导出 / 新机部署',
        [
            ('导出当前环境', 'export {{导出目录:/tmp/arch-env}}', '包清单 + shell/git/vim 配置'),
            ('部署到本机', 'deploy {{目录或 tar.gz:/tmp/arch-env.tar.gz}}', '在新系统上还原'),
            ('交互式菜单', 'menu', '脚本自带菜单'),
        ],
    ),
}

tmpl = """

# =============================================================================
#  面板声明（供 panel.sh 自动发现，不参与脚本执行）
# =============================================================================
# PANEL: %s
%s
"""

for fname, (panel, cmds) in META.items():
    p = BASE / fname
    if not p.exists():
        print(f'跳过（不存在）：{fname}')
        continue
    text = p.read_text(encoding='utf-8')
    # 幂等：先移除旧的声明块
    marker = '#  面板声明（供 panel.sh 自动发现，不参与脚本执行）'
    if marker in text:
        idx = text.index('# =============================================================================\n' + marker)
        text = text[:idx].rstrip('\n') + '\n'
    cmd_lines = '\n'.join(f'# PANEL-CMD: {n} | {a} | {d}' for n, a, d in cmds)
    text = text.rstrip('\n') + '\n' + (tmpl % (panel, cmd_lines))
    p.write_text(text, encoding='utf-8')
    print(f'已写入 {fname}（{len(cmds)} 个子命令）')
