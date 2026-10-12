# Linux 运维脚本箱

一套面向 WSL / 物理机 / 云主机的 Linux 运维脚本集。原先 11 个脚本各自重复实现了
「颜色定义、日志、发行版识别、包管理器封装、确认输入、文件备份」等 8 大类通用逻辑，
现已全部收敛到 `lib/` 共享库；重复的 MariaDB 安装 / 卸载脚本已合并为单个 `mariadb-manager.sh`；
并新增 `panel.sh` 交互式总控面板统一调度。

---

## 一、目录结构

```
D:\share\Linux\
├─ lib/                    # 共享库（面向对象风格，按依赖顺序加载）
│  ├─ lib.sh               # 入口：source 全部模块 + Lib::bootstrap
│  ├─ 00-core.sh           # Term / Logger / Tmp / Err / str 工具
│  ├─ 10-ui.sh             # Ui（终端宽度、对齐表格、确认输入）/ Menu
│  ├─ 20-os.sh             # OS（发行版、家族、包管理器、架构、WSL）/ Sys（权限）
│  ├─ 30-pkg.sh            # Pkg（apt/dnf/yum/zypper/pacman/apk/xbps/emerge 统一封装）
│  ├─ 40-exec.sh           # Runner（dry-run/sudo/日志/致命判定）/ Fs（备份与回滚）
│  ├─ 50-svc.sh            # Svc（systemd / openrc / sysv 统一封装）
│  └─ 60-db.sh             # Db（MariaDB / MySQL 客户端与服务探测）
│
├─ panel.sh                # 交互式总控面板（自动发现目录下所有脚本）
├─ cleanup.sh              # 系统清理 / 修复包管理器 / 彻底卸载 CUDA
├─ configure-mirrors.sh    # 镜像源测速与切换
├─ cuda-manager.sh         # CUDA Toolkit 全生命周期（只装 toolkit，不动显卡驱动）
├─ env_deploy.sh           # 环境导出与迁移部署
├─ install-devtools.sh     # 开发工具链安装
├─ mariadb-manager.sh      # MariaDB LTS 安装 / 卸载 / 体检（已合并，见下文）
├─ setup-zsh.sh            # 全用户共用 zsh 配置
├─ setup_vimrc.sh          # 全用户通用 vim 配置
├─ ssh-key-router.sh       # 多平台独立 SSH 密钥 + config 路由
├─ update-system.sh        # 系统更新与升级
├─ vimrc                   # vim 配置模板（被 setup_vimrc.sh 引用）
│
└─ legacy/                 # 原始脚本备份 + 重构工具（可随时回滚对比）
   ├─ *.sh                 # 11 个脚本的 pristine 原件
   ├─ _install-mariadb-lts.sh.merged     # 合并前的 MariaDB 安装脚本
   ├─ _uninstall-mariadb-lts.sh.merged   # 合并前的 MariaDB 卸载脚本
   └─ _tools/              # 本次重构用的 Python 工具（_patch.py / _merge_mariadb.py / …）
```

---

## 二、共享库 lib/ 说明

### 2.1 加载方式

每个业务脚本开头统一写：

```bash
__OPS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
source "${__OPS_DIR}/lib/lib.sh"
Lib::bootstrap "/var/log/<脚本名>.log"     # 传空串则只输出到屏幕
Lib::install_err_trap                       # 可选：安装 ERR 陷阱
```

> **注意**：必须使用 `__OPS_DIR` 而不是 `SCRIPT_DIR` —— 部分脚本（如 `setup_vimrc.sh`）
> 已把 `SCRIPT_DIR` 声明为 `readonly`，会冲突。

`Lib::bootstrap` 会一次性创建并导出下列全局对象：

| 全局对象 | 类型 | 说明 |
|---|---|---|
| `LOG` | Logger | 日志（屏幕 + 文件，文件不可写时自动降级为仅屏幕） |
| `UI` | Ui | 交互与输出（默认已 `Ui::new UI`） |
| `SYS` | OS | 发行版信息（含 `SYS[id] / SYS[family] / SYS[pm] / SYS[arch] / SYS[wsl]` 等） |
| `PKGMGR` | Pkg | 包管理器统一封装 |
| `RUN` | Runner | 命令执行器（dry-run / sudo） |
| `FS` | Fs | 文件备份与回滚 |
| `ERRCTX` | Err | 错误处理上下文 |

同时导出一批兼容旧代码的全局变量：`OS_ID OS_FAMILY PKG PM ARCH WSL SUDO OS_NAME OS_VERSION`。

### 2.2 各模块职责

| 模块 | 对象 | 主要方法 | 收敛掉的重复 |
|---|---|---|---|
| `00-core.sh` | `Term` | `new / color` | 8 处重复的颜色定义 |
| | `Logger` | `new / raw / stamp / info / ok / warn / err / hint / step / section / die` | 7 处重复的 log 实现 |
| | `Tmp` | `make_file / make_dir / cleanup` | 临时文件管理 |
| | `Err` | `new / handler / install / tolerate / strict` | 4 处重复的 `on_error` 陷阱 |
| | `str` | `trim / trim_var / upper / lower / sql_escape / cnf_escape` | 字符串工具 |
| `10-ui.sh` | `Ui` | `disp_width / disp_width_var / pad / pad_var / item / table / prompt / confirm / feature / typed / read_line` | 7 处 `disp_width`+`item`、6 处 `confirm/ask` |
| | `Menu` | `new / add / count / render / run` | 各脚本自带的菜单循环 |
| `20-os.sh` | `OS` | `new / detect / osrel / osrel_var / family_of / family_of_var / detect_pm / detect_pm_var / summary` | 7 处重复的 `detect_os` |
| | `Sys` | `euid / require_root / sudo_prefix` | 5 处重复的权限检查 |
| `30-pkg.sh` | `Pkg` | `update / install / remove / purge / installed / upgrade / clean / fix_broken / list_matching` | 各脚本内联的 apt/dnf/pacman 分支 |
| `40-exec.sh` | `Runner` | `exec / try / must / run / tee` | 6 处重复的 `run()` |
| | `Fs` | `backup / write / rollback` | 5 处重复的 `backup_file`/`write_file` |
| `50-svc.sh` | `Svc` | `exists / active / enabled / enable / disable / start / stop / restart / status_line` | 服务探测分散在多个脚本 |
| `60-db.sh` | `Db` | `detect_service / detect_paths / write_cnf / sql / query / query_scalar / test_local / test_tcp / gen_password / strength_note` | 2 套近乎相同的 MariaDB 客户端栈 |

---

## 三、业务脚本清单（面板已登记 45 个子命令）

| 脚本 | 面板标题 | 分类 | root | 说明 |
|---|---|---|---|---|
| `cleanup.sh` | 系统清理 | 系统维护 | 是 | 修复包管理器故障、清理缓存；`--purge-cuda` 彻底卸载 CUDA/NVIDIA |
| `configure-mirrors.sh` | 镜像源配置 | 软件源 | 是 | `--auto` 并行测速换源；`--show` 只读；`--restore` 回滚 |
| `cuda-manager.sh` | CUDA 管理 | 开发环境 | 是 | `detect / list / install / uninstall / use / doctor / repair`，只装 Toolkit 不动驱动 |
| `env_deploy.sh` | 环境迁移 | 系统维护 | 否 | `export` 导出包清单与配置，`deploy` 在新机还原 |
| `install-devtools.sh` | 开发工具 | 开发环境 | 是 | `-m` 最小集 / 默认标准集 / `-f` 完整集 / `-l` 只读预览 |
| `mariadb-manager.sh` | MariaDB | 数据库 | 是 | `install / uninstall / status / menu`（原两个脚本已合并） |
| `setup-zsh.sh` | zsh 环境 | Shell 环境 | 是 | oh-my-zsh + 主题 + 插件 + Nerd Font，全用户共用一份配置 |
| `setup_vimrc.sh` | vim 配置 | Shell 环境 | 是 | `--all-users` 覆盖已有用户，`--nvim` 配置 Neovim，`--uninstall` 还原 |
| `ssh-key-router.sh` | SSH 密钥 | 安全 | 否 | `list / add github|gitlab|gitee|custom / remove`，GitHub 自动走 443 备用通道 |
| `update-system.sh` | 系统更新 | 系统维护 | 是 | `--check` 只读，`-y` 免确认，`--full -y` 发行版级升级 |

---

## 四、交互式总控面板 panel.sh

```bash
bash panel.sh                    # 进入交互式面板
bash panel.sh --list             # 列出所有可用脚本
bash panel.sh --help             # 查看帮助
bash panel.sh <脚本名> [参数]     # 直接转发，等价手敲（便于写 alias）
bash panel.sh cuda-manager.sh detect
bash panel.sh CUDA 管理 detect   # 也可用面板标题匹配
```

面板行为：

- **自动发现**：扫描本目录 `*.sh`（排除 `lib/`、`legacy/` 与自身），新脚本放进来即被识别，无需登记。
- **分类分组**：按 `# PANEL:` 里的分类字段分组渲染。
- **子命令菜单**：读取脚本里的 `# PANEL-CMD:` 声明，渲染成可直接执行的菜单项。
- **参数可编辑**：参数模板里的 `{{标签:默认值}}` 会变成可编辑项，选中后展示完整命令行并允许二次修改。
- **全局演练开关**：面板内可切换 dry-run，只打印命令不改动系统。
- **sudo 自动提权**：脚本声明 `need_root=1` 且当前非 root 时自动加 `sudo`。

### 4.1 如何把新脚本登记进面板

在脚本头部写一行概览，再为每个子命令写一行：

```bash
# PANEL: 镜像源配置 | 软件源 | 1 | Arch / Debian / Ubuntu 切换国内镜像
# PANEL-CMD: 自动测速换源 | --auto | 并行测速，切到最快镜像站
# PANEL-CMD: 查看当前配置 | --show | 只读
# PANEL-CMD: 安装指定版本 | install {{CUDA 版本:12.6}} | 可精确到补丁号
```

字段含义（用 `|` 分隔）：

| 声明 | 字段 1 | 字段 2 | 字段 3 | 字段 4 |
|---|---|---|---|---|
| `# PANEL:` | 标题 | 分类 | 是否需 root（0/1） | 一句话说明 |
| `# PANEL-CMD:` | 显示名 | 参数模板 | 说明 | — |

---

## 五、面向对象约定与踩过的坑（改动前必读）

这套库用 **nameref + 关联数组** 模拟对象：类 = `<Class>::` 前缀的函数族，
对象 = 关联数组，构造函数 = `<Class>::new <对象名>`，方法内用 nameref 引用。

```bash
Logger::new() {
    local -n __self_Logger_new="$1"
    declare -gA "$1"
    __self_Logger_new[file]="${2:-}"
    ...
}
```

维护时必须遵守以下约定，否则会踩到已经修过的坑：

1. **nameref 局部变量必须命名为 `__self_<函数名>`**。
   若局部变量与调用方传入的对象同名，bash 会报 `circular name reference`。
   （`legacy/_tools/_fix_nameref.py` 就是做这次批量重命名的工具。）

2. **`*_var` 系列函数内部的局部变量一律加 `__` 前缀**。
   它们是「结果写回变量」版本，若内部声明了 `local fam`，会遮蔽调用方的 `fam`，
   导致结果写到错误的地方（曾让面板的「家族」字段显示为空）。

3. **热路径不要用命令替换 `$()`**。
   每次 `$(...)` 都会 fork 一个子 shell，在 Windows/PortableGit 下每次约 0.1–0.3 秒。
   面板启动时约 40 次 `$(Ui::pad ...)` 曾让它卡 20 秒。已提供
   `Ui::pad_var / Ui::disp_width_var / OS::osrel_var / OS::family_of_var / OS::detect_pm_var`
   等写回变量版本替代。

4. **不要在函数里 `trap 'Tmp::cleanup' EXIT`**。
   命令替换产生的子 shell 会继承 EXIT 陷阱，把父进程还在用的临时文件删掉。

5. **`Fs` 的备份登记表是文件而非数组**。
   在 `$(...)` 里注册的备份会随子 shell 消失，导致 `Fs::rollback` 空转。
   登记表路径：`${TMPDIR:-/tmp}/.linux-ops-backup-$$`。

6. **`(( x++ ))` 在 `set -e` 下会中断脚本**（值为 0 时返回 1），统一写 `(( ++x ))`。

7. **`Db::gen_password` 不要再用 `| dd` 管道**，`dd` 提前退出会引发 SIGPIPE 卡死；
   已改为单次读取 + 非 `/dev/urandom` 回退。

8. **不要过度统一语义不同的同名函数**。
   MariaDB 安装侧与卸载侧的 `sql_query` 行为不同（安装侧要处理 `ADMIN_AUTH_MODE`
   与交互输密码，卸载侧要静默），因此合并时保留了两边实现并给卸载侧加 `u_` 前缀，
   而不是强行塞进 `lib/60-db.sh`。

---

## 六、回滚路径

| 场景 | 操作 |
|---|---|
| 单个脚本行为可疑 | 用 `legacy/<同名>.sh` 原件覆盖回去即可（原件是重构前的 pristine 备份） |
| 想对比重构前后差异 | `diff -u legacy/cleanup.sh cleanup.sh` |
| MariaDB 想拆回两个脚本 | `legacy/_install-mariadb-lts.sh.merged` / `legacy/_uninstall-mariadb-lts.sh.merged` |
| 误改了共享库 | `lib/` 是本次新增，删除后所有脚本会退化到报错；如需回退，请把整个目录恢复成 legacy 状态 |
| 文件被脚本改坏 | `configure-mirrors.sh --restore`、`setup_vimrc.sh --uninstall`；或用 `Fs` 的备份 `<原路径>.bak-<时间戳>` 手工还原 |
| 删除临时工具 | 已归档到 `legacy/_tools/`，确认无需再跑后可直接删除该目录 |

---

## 七、已知环境注意事项

以下问题属于**运行环境限制**，不是脚本缺陷：

- 在 Windows / PortableGit 沙箱里 `/var/log` 不可写，`Logger` 会打印
  `[警告] 日志文件不可写，已降级为仅屏幕输出` 后继续正常工作。
- 该沙箱中 `pacman` / `yum` 的探测结果可能失真，发行版识别仅供参考。
- `sudo` 在该环境是桩程序，需要 root 的脚本请在真实 Linux / WSL 中运行。
- `cleanup.sh` 在 `pad` 处退出码 1 与原件一致，非本次重构引入。

---

## 八、快速自检

```bash
cd /d/share/Linux
for f in lib/*.sh *.sh; do bash -n "$f" || echo "语法错误: $f"; done   # 语法全通过
bash panel.sh --list                                                    # 面板能发现全部 10 个脚本
bash install-devtools.sh -l                                             # 只读预览，安全
bash mariadb-manager.sh status                                          # 只读体检，安全
```
