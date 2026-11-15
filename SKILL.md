---
name: dsh-windows-shell-toolchain
description: 把 DSH 在 Windows 上的命令执行环境补齐：真 bash 当执行器（默认装 niubash，受限沙箱也可用；也可选 PortableGit）+ PowerShell 7 便携版。新机器无 bash、或只有 PowerShell 5.1 时使用。已有可用 shell 时先用手上的，装完再问要不要升级。不需要管理员。
whenToUse: Windows 上 DSH 没有 bash 工具、或只有 5.1 版 PowerShell；或要把这套装到新电脑；或机器上已有 bash/pwsh、想确认是否需要换新版。先 §2 跑一次 -ResolveOnly。POSIX 平台不用本技能。
---

# DSH Windows shell toolchain

## 1. 铁律

1. 先快照：`scripts\restore.ps1 -Snapshot`
2. 不碰 presets 内部 id
3. 顺序：验证 spawn → 改配置 → 重启 → 验收，每步留实测输出
4. 不静默升级：要换新版必须经用户同意（`-Upgrade` 或 `-AskUpgrade`）
5. 见到 `REQUIRES-ESCALATION mode=danger-full-access` 且退出码 3：立刻带 `sandbox_permissions: "danger-full-access"` 和一句 justification 重试同一条命令。只有审批被拒才允许报告"装不了"
6. 受限沙箱用 `-BashSource sandbox`（niubash）；MSYS 系 bash 只能在 danger-full-access 下跑
7. 判断有没有 bash 只认 `-ResolveOnly` 的 `phase A`；`where bash` 为空不等于没装

## 2. 探测

    powershell -NoProfile -ExecutionPolicy Bypass -File scripts\setup-tools.ps1 -ResolveOnly

读四段：`phase A: detect`（真实 bash/pwsh 与版本）、`upstream`（上游最新）、`plan`（用现有还是装、PATH 怎么变）、`UPGRADE-OFFER`（有新版才出现）。不下载、不写盘。

## 3. 决策

| 机器现状 | 脚本行为 |
|---|---|
| bash / pwsh 都有且不旧 | 直接用，只把目录提到 PATH 最前 |
| 有，但上游更新 | 用现有的把活干完，结束时给一行 `UPGRADE-OFFER`，不自动下载 |
| 有，且比上游还新 | 保留，不提示也不降级 |
| 缺其中一个 | 只装缺的那个（不询问） |
| 缺两个 | 两个都装 |

## 4. 装

    powershell -NoProfile -ExecutionPolicy Bypass -File scripts\setup-tools.ps1 -BashSource sandbox
    powershell -NoProfile -ExecutionPolicy Bypass -File scripts\setup-tools.ps1 -Upgrade
    powershell -NoProfile -ExecutionPolicy Bypass -File scripts\setup-tools.ps1 -SkipGit          # 只装 pwsh
    powershell -NoProfile -ExecutionPolicy Bypass -File scripts\setup-tools.ps1 -SkipGit -Upgrade

退出码：`0` 正常　`2` `-Offline` 且 `-Root` 下没有压缩包　`3` 撞了沙箱墙 → 带 `danger-full-access` 重试同一条命令。

## 5. PATH

- 执行器写死 `bash -c`，没有 bash 路径配置项 → PATH 顺序是唯一手段
- 脚本把选中目录放到用户 PATH 最前；改动只对新进程生效 → 重启 DSH
- 装了 WSL 时 `C:\Windows\System32\bash.exe` 永远压过用户 PATH → 用 `-Launcher` 生成 `launch-dsh.cmd` 启动 DSH
- 验证：`bash -c 'echo $BASH_VERSION; uname -s'`

## 6. profile 补丁

    powershell -NoProfile -ExecutionPolicy Bypass -File scripts\setup-tools.ps1 -PatchProfile -DryRun
    powershell -NoProfile -ExecutionPolicy Bypass -File scripts\setup-tools.ps1 -PatchProfile

- 写的是**双执行器块**：`tool-bash` / `bash-sandbox` 一对挂 `isolate: { shell: bash }`，`pwsh-sandbox` 留在默认 realm 并带 `pwshPath`，`tool-pwsh` 由预设挂载后连到它
- 一个上下文只有一份 `ctx.shell`：工具与执行器要配对，两边的 `isolate` label 必须一致；写 `shell: true` 会各得私有 realm、配不上对
- 补丁在**安装之后**才写，所以 `pwshPath` 指向真实存在的 exe；`-SkipPs7` 且本机没有 pwsh 时直接 `exit 1`，不写指向空处的执行器
- 写入是原地替换：新标记 `isolated dual executor` 与旧标记 `bash executor (sandboxing variant)` 都会被识别并从较早处截断，不要在同一个文件里手工再写第二段
- 用 `*-sandbox` 而不是 `*-local`：后者没有 `sandboxMode`，权限预设插件拒绝挂载，聊天框模式选择器会消失
- 按 id 定位是**字段级覆盖**：只改写补丁里写出的键，其余原样保留；只有 `config` 这一键是整块替换（不深合并）。`name` 写上会做校验，写错整条跳过
- `cwd` 默认当前目录，`-Workspace` 指定

## 7. 必须问用户

跳过不算同意。

| 何时 | 问什么 | 选项 → 参数 |
|---|---|---|
| 本机已有 Git / PortableGit | 本机已有 Git，如何配置？ | 指向本机 bash（需完全访问）→ `-BashSource local -AllowDangerFullAccess`；装沙箱级 bash、不动本机 Git → `-BashSource sandbox` |
| 装过执行器、上游有新版本 | 执行器有新版本，是否更新？ | 更新并删旧版 → `-UpdateExecutor`；不更新 → 结束，不写盘 |
| DSH 正在运行 | 配置完由谁重启？ | 我直接重启（会中断会话）→ `-Restart`；你自己重启 → 不加参数 |
| 架构是 x86 | 本机没有可用的原生 bash，如何配置？ | 继续用 PortableGit（需完全访问）→ `-BashSource portablegit -AllowDangerFullAccess`；不装 → 结束 |

## 8. 验收

    scripts\restart-dsh.cmd -ResolveOnly    # 先确认能找到 DSH
    scripts\restart-dsh.cmd                 # 换 PATH 后必须重启

1. 工具表里有 `bash`
2. `bash -c 'echo $BASH_VERSION; uname -s'` → exit 0
3. `bash -c 'echo $0; uname -s; pwd'` → exit 0
4. `pwsh -NoProfile -Command '$PSVersionTable.PSVersion.ToString()'` → `7.7.0`（能跑通才说明两个 realm 配对正确；报 bash 语法错说明补丁没生效或没重启）
5. 开 subagent，让它自报工具名并实跑一条
6. 聊天框的权限选择器与 `/permission` 仍在

## 9. 故障排查

| 现象 | 处理 |
|---|---|
| `spawn bash ENOENT` | 进程 PATH 是旧的 → 重启 DSH |
| 已装 niubash 却重跑又下载一遍 | 已修：niubash 的 `uname -s` 也答 `MSYS_NT`，曾误判成 MSYS 使 `needGit` 恒真；现按安装路径识别。仍复现说明它不在 `-Root\niubash-*` 下 |
| 安装脚本卡住不返回 | 已修：Node 兜底下载器原无超时；现每源有硬上限 + `-DownloadBudgetSec` 总预算 |
| `-Root` 下留着 `.part` / `node-download.cjs` | 下次任意一次运行（含空跑）在清理段删除 |
| `phase A` 报旧 bash / 同版本被重装 / 清理要删在用的版本 | 已修：探测先看 `-Root` 下本脚本装的版本，清理按版本目录比对 |
| bash 报 WSL 的路径 / 权限错 | 命中的是 `System32\bash.exe` → `-Launcher`，或改机器级 PATH（需管理员） |
| `NtCreateDirectoryObject ... 0xC0000022` | 从 powershell.exe / cmd 调，并清 `MSYSTEM` / `MSYS` / `MSYS2_PATH_TYPE` |
| 受限档下 bash 起不来 | MSYS 系 bash 的固有上限 → `-BashSource sandbox`，或临时切 danger-full-access |
| 下载卡住或 403 | 已自动测速换源；仍失败用 `-Mirror <前缀>` |
| `curl: (35) ... SEC_E_NO_CREDENTIALS` | Schannel 拿不到凭证，自动回退 Node；全失败用 `-Offline` 预放包 |
| 装完仍报 signal pipe / Win32 error 5 | 命中的是 Git 的 MSYS bash → `-BashSource sandbox`，确认 PATH 最前是 `niubash-<v>\winuxcmd\usr\bin` |
| `pwsh` 工具报 PowerShell 语法错 | 执行器是 bash → 用 bash 工具，或 `pwsh -NoProfile -Command` |
| 当前会话工具表不变 | 预设只影响新建 agent → 用 subagent 或新会话验收 |
| `Unknown agent preset` | 用不完整条目覆盖了预设节点 → `restore.ps1` 还原 |

## 10. 参数

### setup-tools.ps1

| 参数 | 默认 | 含义 |
|---|---|---|
| `-Root` | `%LOCALAPPDATA%\dsh-tools` | 安装根目录 |
| `-StateDir` | `%LOCALAPPDATA%\dsh-windows-shell` | 状态与升级记录（`state.json`） |
| `-GitVersion` / `-Ps7Version` | `latest` | 固定版本号 |
| `-Mirror` | 空 | 追加下载前缀，`;` 分隔 |
| `-NoAutoMirror` | 关 | 关掉内置镜像与测速 |
| `-DownloadBudgetSec` | 600 | 单个包的下载总预算，到点抛错而不是一直换源 |
| `-ResolveOnly` | 关 | 只探测 + 打印计划，不下载不写盘 |
| `-DryRun` | 关 | 打印所有将发生的写入，不写 |
| `-Upgrade` | 关 | 有更新就下载安装 |
| `-AskUpgrade` | 关 | 装完当场询问（无控制台则跳过） |
| `-Launcher` | 关 | 生成 `<Root>\launch-dsh.cmd` |
| `-Offline` | 关 | 不联网，只用 `-Root` 下的现成包 |
| `-SkipGit` / `-SkipPs7` / `-SkipPath` | 关 | 拆步执行 |
| `-KeepArchives` | 关 | 保留下载的压缩包（默认解压后删） |
| `-KeepOldVersions` | 关 | 保留旧版本目录 |
| `-PatchProfile` | 关 | 写入/刷新 profile 的 `cordis.patch.yml`（备份 + 幂等 + 结构校验） |
| `-Profile` | 全部 | `-PatchProfile` 时只处理这些 profile，逗号分隔 |
| `-Workspace` | 当前目录 | 写进 bash-sandbox 块的 `cwd` |
| `-DshHome` | `%USERPROFILE%\.dsh` | profile 所在 DSH 主目录 |
| `-BashSource` | `auto` | `sandbox`（niubash，受限档可用）/ `portablegit` / `local` / `auto` |
| `-AllowDangerFullAccess` | 关 | 同意该 bash 只在完全访问下可用（输出留痕） |
| `-UpdateExecutor` | 关 | 上游有新版就更新并清理旧版 |
| `-Restart` | 关 | 装完重启 DSH（会中断当前会话） |
| `-ProbeTimeoutSec` | 25 | API 请求超时 |

### restore.ps1

| 参数 | 默认 | 含义 |
|---|---|---|
| `-Snapshot` | — | 记录用户 PATH + 复制每个 profile 的 `cordis.patch.yml`（改动**之前**跑） |
| `-DryRun` | 关 | 只打印 SAME/CHANGED/MISSING 与 PATH 计划 |
| （无参数） | — | 还原：逐字节写回配置 + 还原 PATH |
| `-Uninstall` | 关 | 同上，并剔除 PATH 里 `-ToolsRoot` 下的条目 |
| `-DeleteTools` | 关 | 配合 `-Uninstall` 真删 `-ToolsRoot` |
| `-Restart` | 关 | 还原后重启 DSH |
| `-StateDir` | `%LOCALAPPDATA%\dsh-windows-shell` | 快照目录 |
| `-DshHome` | `%USERPROFILE%\.dsh` | DSH 主目录 |
| `-Profiles` | 自动发现 | 指定 profile，逗号分隔 |
| `-ToolsRoot` | `%LOCALAPPDATA%\dsh-tools` | 卸载时处理的工具目录 |
| `-DshExe` | 自动探测 | 覆盖 DSH 可执行文件路径 |
| `-KeepPrevs` | 2 | 保留最近几份旧快照 |

## 11. 文件清单

| 文件 | 作用 |
|---|---|
| `SKILL.md` | 执行源 |
| `scripts/setup-tools.ps1` | 探测 → 决定装不装 → 测速选源 → 下载（sha256）→ 解压 → 验签 → 前置 PATH → 清理 → 升级提议 |
| `scripts/restore.ps1` | 快照 / dry-run / 逐字节还原 / 还原 PATH / 卸载 / 重启 |
| `scripts/restart-dsh.ps1` / `.cmd` | 重启 DSH 让新 PATH 生效 |

## 12. 执行时容易踩的

- `run_code` 的子进程 env 是空的：显式传 `-Root` 与 `-StateDir`，自建 env 别漏 `PATHEXT`，否则 `Get-Command bash` 会说谎
- 验 exe 用 `bash` 工具或 Node `spawn`，别在单引号里读 `$LASTEXITCODE`
- 应用双执行器块并重启后，`pwsh` 工具应能直接吃 PowerShell 语法；仍报 bash 语法错就查 `profiles\<p>\cordis.patch.yml` 是否写入、DSH 是否重启过
- PATH 改完未重启时 `bash` / `pwsh` 都报 `spawn bash ENOENT`：用 Node 起 `C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe` 继续诊断，别报"装不了"
- 被调用超时掐断先查盘上状态再重跑，同一条命令别跑第三次
