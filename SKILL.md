---
name: dsh-windows-shell-toolchain
description: 把 DSH 在 Windows 上的命令执行环境补齐：真 bash（PortableGit）当执行器 + PowerShell 7 便携版。新机器无 bash、或只有 PowerShell 5.1 时使用。已有可用 shell 时先用手上的，装完再问要不要升级。不需要管理员。
whenToUse: Windows 上 DSH 没有 bash 工具、或只有 5.1 版 PowerShell；或要把这套装到新电脑；或机器上已有 bash/pwsh、想确认是否需要换新版。先 §2 跑一次 -ResolveOnly，脚本会自己判断。POSIX 平台不用本技能。
---

# DSH Windows shell toolchain

## 1. 铁律

1. 先快照：`scripts\restore.ps1 -Snapshot`
2. PowerShell 脚本写纯 ASCII（5.1 按 ANSI 读无 BOM UTF-8）
3. 不碰 presets 内部 id
4. 顺序：验证 spawn → 改配置 → 重启 → 验收；每步都要有实测输出
5. **不静默升级**：机器上已有的 shell 先用；要换新版必须经用户同意（`-Upgrade` 或当场回答 `-AskUpgrade`）

## 2. 探测：先跑脚本，不要手工猜

    powershell -NoProfile -ExecutionPolicy Bypass -File scripts\setup-tools.ps1 -ResolveOnly

输出四段：`phase A: detect`（这台机器上真实的 bash / pwsh 及其版本）、`upstream`（上游最新版）、`plan`（用现有的还是装哪个、PATH 会怎么变）、`UPGRADE-OFFER`（有新版才出现）。`-ResolveOnly` 不下载、不写盘。

要人工核对时：

    where bash 2>nul
    where pwsh 2>nul
    echo %PROCESSOR_ARCHITECTURE%

- `C:\Windows\System32\bash.exe` 是 WSL 入口，装了发行版才可用；脚本会把它排除在"可用 bash"之外
- Git 的 bash：`<Git>\bin\bash.exe`；`<Git>\usr\bin\bash.exe` 也能跑，但**不要**把 `usr\bin` 放进 PATH（会把整套 msys 工具顶到前面）
- MSI 版 PS7：`%ProgramFiles%\PowerShell\7\pwsh.exe`

## 3. 两段式：先用，再问

| 机器现状 | 脚本行为 |
|---|---|
| bash / pwsh 都有且不旧 | 直接用，只把它们的目录提到 PATH 最前（§6），不下载 |
| 有，但上游更新 | 用现有的把活干完；结束时给一行 `UPGRADE-OFFER`，**不会自动下载** |
| 有，且比上游还新 | 保留，降级提示都不会出现 |
| 缺其中一个 | 只装缺的那个（"没有"和"有但旧"是两回事，不询问） |
| 缺两个 | 两个都装 |

升级只有两个入口：重跑时加 `-Upgrade`，或加 `-AskUpgrade` 让它装完当场问（无控制台时自动按"不升级"处理）。同一版本被拒绝过会记在 `state.json` 里，不再重复打扰。

## 4. 装 / 升级 bash

    powershell -NoProfile -ExecutionPolicy Bypass -File scripts\setup-tools.ps1 -ResolveOnly
    powershell -NoProfile -ExecutionPolicy Bypass -File scripts\setup-tools.ps1 -Upgrade

- 必须 PortableGit；MinGit 不含 `usr\bin\bash.exe`
- 安装目录带版本号（`<Root>\git-<ver>`），旧目录不会被复用，因此真正能升级
- 下载优先走自动测速选出的镜像（§10），失败按延迟顺序换下一个源
- 资产有 sha256 摘要时强校验；没有摘要时退回大小检查
- 执行器用内置 `bash-sandbox`（`- id: bash-sandbox` / `disabled: false`）；不要用 `bash-local`——没有 `sandboxMode`，权限预设插件拒绝挂载，聊天框选择器与 `/permission` 会消失

## 5. 装 PowerShell 7

    powershell -NoProfile -ExecutionPolicy Bypass -File scripts\setup-tools.ps1 -SkipGit
    powershell -NoProfile -ExecutionPolicy Bypass -File scripts\setup-tools.ps1 -SkipGit -Upgrade

装完会验 Authenticode 签名，签名不是 Valid 就拒绝使用。

## 6. PATH：必须前置，且知道它的边界

- 执行器**写死** `["bash","-c",...]`，配置项只有 `cwd` / `timeoutMs` / `maxTimeoutMs`（已核对 asar 里的 `dsh-bash-local` 与 `dsh-bash-sandbox` 源码），**没有 bash 路径配置**——所以 PATH 顺序是唯一手段
- 脚本把选中目录放到**用户 PATH 最前**（不是追加），并顺手删掉 `-Root` 下过期的旧版本条目
- 边界：Windows 生效顺序是"机器级在前、用户级在后"，所以 `C:\Windows\System32\bash.exe` 永远压过用户 PATH。若机器装了 WSL，加 `-Launcher` 生成 `<Root>\launch-dsh.cmd`，用它启动 DSH（子进程继承它设好的 PATH）
- 改 PATH 只对新进程生效 → 重启 DSH
- 验证（不依赖 node）：

    powershell -NoProfile -Command "& (Get-Command bash).Source -c 'echo $BASH_VERSION; uname -s'"

## 7. profile 补丁

文件：`<DSH home>\profiles\<profile>\cordis.patch.yml`，追加到末尾。

- `<DSH home>` 默认 `%USERPROFILE%\.dsh`，可用环境变量 `DSH_HOME` 覆盖
- `<profile>` 是 `profiles\` 下的目录名（桌面版通常为 `desktop`）

- 按 id 定位的条目**整条替换、不深合并**：要保留的字段（尤其 `name`）必须重述
- 新增插件写 `insert` 列表，单个 id 条目插不进去

    - id: tool-bash
      name: '@deepseek-ai/dsh-tool-bash'
      disabled: false
    - id: tool-pwsh
      name: '@deepseek-ai/dsh-tool-pwsh'
      disabled: true
    - id: pwsh-sandbox
      name: '@deepseek-ai/dsh-pwsh-sandbox'
      disabled: true
    - id: bash-sandbox
      name: '@deepseek-ai/dsh-bash-sandbox'
      disabled: false
      config:
        cwd: '<workspace>'

写完先解析校验 YAML 再落盘。

`tool-pwsh` 那条 `disabled: true` 只关掉 bundle 层那份，每个预设自己也挂了一份，profile patch 够不到——所以 `pwsh` 工具仍会出现在工具表里。用 `bash` 工具，需要 PowerShell 时显式调 `pwsh -NoProfile -Command '...'`。

## 8. 验收

    scripts\restart-dsh.cmd -ResolveOnly    # 先确认能找到 DSH
    scripts\restart-dsh.cmd                 # 换 PATH 后必须重启

1. 工具表里有 `bash`
2. `echo $0; uname -s; pwd` → exit 0，输出 bash 路径 + MINGW/MSYS + 目标目录
3. 开 subagent，让它自报工具名并实跑一条
4. 聊天框的权限选择器与 `/permission` 命令仍在（换执行器最容易丢的就是这个）

## 9. 故障

| 现象 | 处理 |
|---|---|
| `spawn bash ENOENT` | 进程 PATH 是旧的 → 重启 DSH |
| bash 报 WSL 的路径/权限错 | 命中的是 `System32\bash.exe` → 用 `-Launcher` 启动，或改机器级 PATH（需管理员） |
| `NtCreateDirectoryObject ... 0xC0000022` | 从 powershell.exe/cmd 调，并清 `MSYSTEM` / `MSYS` / `MSYS2_PATH_TYPE` |
| 下载卡住或 403 | 脚本已自动测速换源；仍失败用 `-Mirror <前缀>` 指定可用的 GitHub 代理 |
| pwsh 工具报 PowerShell 语法错 | 执行器是 bash → 用 bash 工具，或显式 `pwsh -NoProfile -Command` |
| 当前会话工具表不变 | 预设只影响新建 agent → 用 subagent 或新会话验收 |
| `Unknown agent preset` | 用不完整条目覆盖了预设节点 → `restore.ps1` 还原 |

## 10. 说明

### 文件

| 文件 | 作用 |
|---|---|
| `SKILL.md` | 执行源，即本文 |
| `scripts/setup-tools.ps1` | 探测 → 决定用现有的还是装新的 → 测速选源 → 下载（sha256 校验）→ 解压 → 验签 → 前置用户 PATH → 清理 → 记录升级提议 |
| `scripts/restore.ps1` | 快照、dry-run 比对、逐字节还原配置、还原用户 PATH、卸载、重启 DSH |
| `scripts/restart-dsh.ps1` | 重启 DSH，让新 PATH 生效；DSH 路径运行时探测 |
| `scripts/restart-dsh.cmd` | 上面那个的双击入口，转发参数 |

### 清理（每次运行都执行，包含"已是最新"的空跑）

- 解压成功并写入 PATH 后，删掉下载的压缩包和 `.ok` 标记
- 升级到新版本后（新版本已解压 + 已指向），删掉旧版本目录
- 只处理 `-Root` 的**直接子项**，且必须长得像脚本自己装的东西：名字是 `git-<版本>` / `PowerShell-<版本>` / `PortableGit-*.7z.exe` / `PowerShell-*-win-*.zip`，目录里真的有 `bin\bash.exe` 或 `pwsh.exe`，并且**不是当前正在用的那个版本**
- 用户原有的东西（`C:\Program Files\Git`、别的盘上的 pwsh）不在 `-Root` 下，扫不到也删不到
- 删除失败（文件被占用/杀软拦截）只报告，下次运行会再试
- 逃生口：`-KeepArchives` 保留压缩包、`-KeepOldVersions` 保留旧版本目录；两个都不加就是全删

### 镜像（自动）

- 资产下载：`gh-proxy.com` / `ghfast.top` / `ghproxy.net` 与 GitHub 直连一起参与**实测吞吐**（取前 256KB 计时），按快慢排序后再下；直连快就用直连，被墙就自动沉到后面
- 下载中途断流会被 `--speed-limit/--speed-time` 掐掉（30 秒内低于 4KB/s）并换下一个源，不会挂死
- API 解析：只有能代理 `api.github.com` 的前缀才进候选（实测多数代理对 API 返回 403）
- 全部失败不等于安装失败：`-ResolveOnly` 会显示 `unknown (network unavailable)`，此时只用手上的版本，不阻塞
- `-NoAutoMirror` 关掉自动测速；`-Mirror "a;b"` 追加自定义前缀

### 参数（setup-tools.ps1）

| 参数 | 默认 | 含义 |
|---|---|---|
| `-Root` | `%LOCALAPPDATA%\dsh-tools` | 安装根目录，可指到任意盘 |
| `-StateDir` | `%LOCALAPPDATA%\dsh-windows-shell` | 状态与升级记录（`state.json`） |
| `-GitVersion` / `-Ps7Version` | `latest` | 固定版本号 |
| `-Mirror` | 空 | 追加下载前缀，`;` 分隔 |
| `-NoAutoMirror` | 关 | 关掉内置镜像与测速 |
| `-ResolveOnly` | 关 | 只探测 + 打印计划，不下载不写盘 |
| `-DryRun` | 关 | 打印所有将发生的写入，不写 |
| `-Upgrade` | 关 | 有更新的组件就下载安装 |
| `-AskUpgrade` | 关 | 装完当场询问（无控制台则跳过） |
| `-Launcher` | 关 | 生成 `<Root>\launch-dsh.cmd` |
| `-Offline` | 关 | 不联网，只用 `-Root` 下的现成包 |
| `-SkipGit` / `-SkipPs7` / `-SkipPath` | 关 | 拆步执行 |
| `-KeepArchives` | 关 | 保留下载的压缩包（默认解压后删） |
| `-KeepOldVersions` | 关 | 保留旧版本目录（默认升级后删） |
| `-ProbeTimeoutSec` | 25 | API 请求超时 |

架构自动识别：ARM64 取 arm64 资产，其余 x64。

### 参数（restore.ps1）

| 参数 | 默认 | 含义 |
|---|---|---|
| `-Snapshot` | — | 建立快照（改动前跑） |
| `-DryRun` | 关 | 只比对不写盘 |
| `-RestorePath` | 关 | 还原时连用户 PATH 一起还原 |
| `-Restart` | 关 | 还原后重启 DSH |
| `-Uninstall` | 关 | 还原配置 + PATH，打印待删目录 |
| `-DeleteTools` | 关 | 配合 `-Uninstall` 真正删除 `-ToolsRoot` |
| `-DshHome` | `%USERPROFILE%\.dsh` | DSH 主目录（决定去哪找 profile） |
| `-Profiles` | 自动发现 | 指定 profile 目录名，多个用逗号 |
| `-Extra` | 空 | 额外纳入快照的文件，`;` 分隔 |
| `-DshExe` | 自动探测 | 覆盖 DSH 可执行文件路径 |
| `-ToolsRoot` | `%LOCALAPPDATA%\dsh-tools` | 卸载时处理的工具目录 |
| `-StateDir` | `%LOCALAPPDATA%\dsh-windows-shell` | 快照存放目录 |

DSH 路径探测顺序：正在运行的进程 → 卸载注册表项 → 开始菜单快捷方式 → 默认安装位置 → 报错并提示 `-DshExe`。

### 回滚与卸载

    scripts\restore.ps1 -DryRun          # 只看差异，不写盘
    scripts\restore.ps1                  # 逐字节还原配置
    scripts\restore.ps1 -RestorePath     # 连用户 PATH 一起还原
    scripts\restore.ps1 -Restart         # 还原后重启 DSH
    scripts\restore.ps1 -Uninstall                 # 还原 + 列出手上的工具目录
    scripts\restore.ps1 -Uninstall -DeleteTools    # 连工具目录一起删
