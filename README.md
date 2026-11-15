# dsh-windows-shell-toolchain

> 给 **DeepSeek Harness (DSH)** 在 Windows 上配一个真正的 bash 执行器，并补上 PowerShell 7 便携版。**不需要管理员**。
>
> **可回滚至技能改动配置之前。**
>
> 设计前提：**机器上已经有的就先用手上的**；装完再把"要不要换最新版"交给你决定，绝不静默升级。

[English summary](#english-summary) · [安装](#安装) · [升级](#升级) · [它到底改了什么](#它到底改了什么) · [回滚与卸载](#回滚与卸载)

## 这是什么

一个 **agent skill**（不是插件）：一份能被任意 agent 读懂并执行的文档 + 一组可直接运行的 PowerShell 脚本。

- 不侵入 DSH 代码，不注册任何服务；
- 依赖官方发行物 + 一个第三方 bash：Git for Windows 的 PortableGit、微软的 PowerShell 7，以及 [Niubash](https://github.com/unixwin/niubash)（MIT，无 POSIX 模拟层的原生 bash，见下）；
- DSH 升级、换机器、换 agent 都还能用；删掉即可卸载。

## 为什么需要换一个 bash

DSH 在 Windows 上有两种沙箱档：`workspace-write` / `read-only` 用受限令牌 + Low 完整性级别跑子进程。**MSYS 系 bash（PortableGit 自带）在这种沙箱里连启动都做不到**——它在启动阶段要建一个 signal pipe，而受限令牌打不开那个命名管道，于是报：

```
*** fatal error - couldn't create signal pipe, Win32 error 5
```

这不是权限配置问题，也不是环境变量问题，切到 `danger-full-access` 就正常。所以"受限模式下能不能用 bash"这个问题的答案是：**MSYS 系不行，需要没有 POSIX 模拟层的实现**。

Niubash 就是这样一个实现（原生 Windows，无 MSYS/Cygwin 运行时）。本技能用 `-BashSource sandbox` 装它；`-BashSource portablegit` 仍保留旧路径。

## 架构与资产

按 **OS 架构**判断（不是进程位数；32 位进程跑在 64 位系统上也能选对）：

| OS 架构 | bash 默认（`-BashSource sandbox`/`auto`） | bash 备选（`-BashSource portablegit`） | pwsh |
|---|---|---|---|
| `x64` | `niubash-v<v>-win-x64.tar.gz` | `PortableGit-<v>-64-bit.7z.exe` | `PowerShell-<v>-win-x64.zip` |
| `ARM64` | `niubash-v<v>-win-arm64.tar.gz` | `PortableGit-<v>-arm64.7z.exe` | `PowerShell-<v>-win-arm64.zip` |
| `x86` | **不可用**（niubash 不发 32 位） | Git 最新版已停发 32 位，脚本分页回溯到最后一个有包的稳定版（当前 `v2.50.1`） | `PowerShell-<v>-win-x86.zip` |

回溯只用于 `latest`：显式 `-GitVersion` / `-Ps7Version` 不回退，缺包直接报错；回溯跳过 prerelease。

## 它解决什么

Windows 上的 DSH 默认只有 PowerShell 执行器；各内置预设把 `tool-bash` 在 win32 上禁用，因为裸 `bash` 可能解析到 `C:\Windows\System32\bash.exe`（WSL 占位入口，没装发行版时跑不了命令）。

已知限制：**32 位（x86）Windows 没有可用的原生 bash**——niubash 不发 32 位构建，PortableGit 也停在 v2.50.1，且 32 位只能走 PortableGit，因此在受限沙箱下不可用（只能用 `-AllowDangerFullAccess`）。

本技能做两件事：

1. 让一个**真 bash** 真的生效：已有的直接用（并提到 PATH 最前），没有的装 PortableGit；
2. 补上 pwsh 7（有 MSI 版就不动它），并把 DSH 的 profile 执行器换成 **`bash-sandbox`**（带 `sandboxMode`，因此权限预设与 `/permission` 不受影响）。

## 安装

```powershell
# 1) 装到技能目录（目录名保持 dsh-windows-shell-toolchain）
Expand-Archive .\dsh-windows-shell-toolchain-<版本>.zip -DestinationPath "$env:USERPROFILE\.dsh\skills" -Force

# 2) 先看一眼：探测 + 计划 + 上游版本，不下载不写盘
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.dsh\skills\dsh-windows-shell-toolchain\scripts\setup-tools.ps1" -ResolveOnly

# 3) 正式执行（已有的会用，缺的才装）
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.dsh\skills\dsh-windows-shell-toolchain\scripts\setup-tools.ps1"

# 4) 重启 DSH，让新 PATH 生效
```

然后让你的 agent 加载这个技能（`dsh-windows-shell-toolchain`），按 SKILL.md 第 7 节改 profile 补丁即可。

首次使用前建议先快照：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.dsh\skills\dsh-windows-shell-toolchain\scripts\restore.ps1" -Snapshot
```

常用参数：`-Root` 装到别处、`-Mirror` 指定下载前缀、`-Offline` 只用已有包、`-SkipGit` / `-SkipPs7` 拆步、`-DryRun` 只看不改。

## 升级

脚本**不会**自己下载新版本。它每次运行结束会打印一行：

```
UPGRADE-OFFER pwsh 7.6.9 -> 7.7.0
```

看到这行，你可以：

- 让脚本装完当场问：加 `-AskUpgrade`（没有控制台时自动按"不升级"处理）；
- 或者过后自己决定：加 `-Upgrade` 重跑。

机器上的版本**比上游还新**时不会提示，也不会降级。同一个版本被拒绝过会记在 `%LOCALAPPDATA%\dsh-windows-shell\state.json`，不会反复打扰。

注意：升级必然要**第二次重启 DSH**（PATH 变更只对新进程生效）。

## 下载加速（自动）

- 资产：内置 `gh-proxy.com` / `ghfast.top` / `ghproxy.net`，与 GitHub 直连一起**实测前 256KB 的吞吐**，谁快用谁（在中国实测：`ghfast.top` 163 KB/s、`gh-proxy.com` 68 KB/s、`ghproxy.net` 21 KB/s、直连连不上，直连会在别国自动胜出）；
- 中途断流 30 秒内低于 4KB/s 就掐掉换源，不会挂死；
- API：只有实测能代理 `api.github.com` 的前缀才作为候选（多数代理对 API 返回 403）；
- 拿到 GitHub 给出的 `sha256` 摘要时强校验，失败换下一个源；
- 网络完全不通时不是失败：只用手上的版本，并把上游标成 `unknown`。

## 清理（默认自动，每次运行都做）

| 时机 | 动作 |
|---|---|
| 解压成功、PATH 已指向 | 删掉下载的压缩包 + `.ok` 标记 |
| 升级到新版本（已解压、已指向） | 删掉**旧版本目录** + 压缩包 |
| 已经是最新（没有更新可做） | 照样执行：把上一次遗留的压缩包删掉 |

**只删自己装的**：范围限定在 `-Root`（默认 `%LOCALAPPDATA%\dsh-tools`）的**直接子项**，且名字必须像脚本产物（`git-<版本>` / `PowerShell-<版本>` / `PortableGit-*.7z.exe` / `PowerShell-*-win-*.zip`）、目录里真有 `bin\bash.exe` 或 `pwsh.exe`、并且**不是当前正在用的那个版本**。你原有的 `C:\Program Files\Git`、别的盘上的 pwsh 都不在范围内。

想留后路就加开关（默认不加 = 全删）：

```powershell
setup-tools.ps1 -Upgrade -KeepArchives      # 保留下载的压缩包
setup-tools.ps1 -Upgrade -KeepOldVersions   # 保留旧版本目录
```

删包之后 `-Offline` 重装和"退回上一版本"需要重新下载（PATH 快照仍可回滚配置）。

## 它到底改了什么

| 位置 | 改动 | 可逆性 |
|---|---|---|
| `%LOCALAPPDATA%\dsh-tools` | 只在"缺"或"升级"时解压 PortableGit / PowerShell 7，目录带版本号；解压后删压缩包、升级后删旧版本目录（`-KeepArchives` / `-KeepOldVersions` 可关掉） | `restore.ps1 -Uninstall -DeleteTools` |
| 用户 PATH | 把选中的目录**提到最前**（并删掉自己装过的过期条目） | `restore.ps1 -Uninstall`（会剔除 `-ToolsRoot` 下的条目） |
| `<DSH home>\profiles\*\cordis.patch.yml` | 追加一段带标记的执行器条目（`bash-sandbox`） | `restore.ps1` **只删这一段**，文件其余部分不动 |
| `%LOCALAPPDATA%\dsh-windows-shell\state.json` | 记录"检查过/已提议/已拒绝"的版本 | 删文件 |

**PATH 的硬边界**：Windows 的生效顺序是"机器级在前、用户级在后"，所以 `C:\Windows\System32\bash.exe`（装了 WSL 才有）永远压过用户 PATH。这种情况下脚本会告警，并可以用 `-Launcher` 生成一个先把目录塞进 PATH 再启动 DSH 的 ```launch-dsh.cmd```。

**代价（写在明面上）**：切换后 `pwsh` 工具名存实亡（执行器是 bash，PowerShell 语法会报错），需要 PowerShell 时显式调 `pwsh -NoProfile -Command`。执行器必须用 `bash-sandbox` 而不是 `bash-local`：后者没有 `sandboxMode`，会让权限预设插件拒绝挂载、聊天框的模式选择器消失。

## 回滚与卸载

| 能回滚 | 不能回滚 |
|---|---|
| `<DSH home>\profiles\*\cordis.patch.yml` 等配置（逐字节 + SHA-256 校验） | 已解压的工具目录（`git-<版本>` / `PowerShell-<版本>`） |
| 用户 PATH（回到快照那一刻的值） | 清理阶段删掉的安装包（`.7z.exe` / `.zip`） |
| | 清理阶段删掉的旧版本目录 |

回滚是**整份还原**：把每个 `cordis.patch.yml` 逐字节写回快照那份、用户 PATH 写回快照原值，卸载时删掉工具目录。因此 `-Snapshot` 必须在技能第一次改动**之前**跑；没有快照脚本会直接拒绝。

`cordis.yml` / `package.json` 技能从不写，也从不快照、从不还原。

要彻底回到"没装过"的状态：`restore.ps1 -Uninstall -DeleteTools`（删 shell block、清 PATH、删 `-Root`，并连同 `%LOCALAPPDATA%\dsh-windows-shell` 里的快照一起清掉；想留快照加 `-KeepState`）。

```powershell
restore.ps1 -DryRun          # 只看差异
restore.ps1                  # 逐字节还原配置
restore.ps1 -Uninstall       # 删 block + 还原/清理 PATH，并列出工具目录
restore.ps1 -Restart         # 还原并重启 DSH
restore.ps1 -Uninstall                 # 还原 + 列出手上的工具目录
restore.ps1 -Uninstall -DeleteTools    # 连工具目录一起删
```

DSH 可执行文件路径是**运行时探测**的（运行中的进程 → 卸载注册表项 → 开始菜单快捷方式 → 默认安装位置），所以换用户名、换盘、便携版都能找到；都不行时用 `-DshExe` 指定。

## 已验证 / 未验证

- 已验证（本机实测）：探测能识别系统 Git 的 bash 2.56.0 与 pwsh 7.6.9，正确给出 `UPGRADE-OFFER` 且不下载；真实升级后再跑一次会走"已最新"分支并把遗留压缩包删掉（实测 167.3 MB，780→613 MB，正在使用的目录与诱饵目录均未受影响）；`-DryRun` 不改 PATH、不建目录；镜像测速真实选中 `gh-proxy.com` 并完成下载；sha256 校验、验签、解压后 smoke test 通过；`restore.ps1` 快照 6 个文件、`-DryRun` 全部 SAME、`-Uninstall -DryRun` 只比对不写盘；`restart-dsh.ps1 -ResolveOnly` 与 `restart-dsh.cmd -ResolveOnly`（参数转发）都能解析到真实 exe；全部脚本纯 ASCII、在 Windows PowerShell 5.1 下跑通。
- 未验证：全新无 Git / 无 PS7 机器上的首次安装（路径分支存在但未实跑）；`-AskUpgrade` 在无控制台时的实际交互（逻辑已按"跳过"处理）。
- 已证不可用（issue #1）：MSYS 系 bash（PortableGit 自带）在受限沙箱（workspace-write / read-only）下启动即失败，报 `couldn't create signal pipe, Win32 error 5`。改用 `-BashSource sandbox`（niubash）后同档实测可跑，且写工作区外仍被拒绝。

## English summary

An agent skill that gives DeepSeek Harness a real bash executor on Windows and fills in a portable PowerShell 7. No admin rights, no plugin. Rollback restores the DSH profile files and the user PATH byte-exactly to the state before the skill touched them; extracted tool directories, deleted installers and retired versions are not restored by it.

It is **two-phase**: use the shell the machine already has (only re-ordering the user PATH so the chosen one actually wins, and installing just the component that is missing), report an upgrade offer at the end, and download/install a newer release only when the user opts in (`-Upgrade` or `-AskUpgrade`). Downloads race a built-in mirror list by latency with GitHub as the final fallback and are verified by sha256 when the release publishes a digest. A machine copy that is newer than upstream is kept. Rollback is a single script; the DSH executable is discovered at run time instead of being hard-coded.

## License

MIT
