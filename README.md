# dsh-windows-shell-toolchain

> 给 **DeepSeek Harness (DSH)** 在 Windows 上配一个真正的 bash 执行器，并补上 PowerShell 7 便携版。**不需要管理员**，全程可回滚。
>
> 设计前提：**机器上已经有的就先用手上的**；装完再把"要不要换最新版"交给你决定，绝不静默升级。

[English summary](#english-summary) · [安装](#安装) · [升级](#升级) · [它到底改了什么](#它到底改了什么) · [回滚与卸载](#回滚与卸载)

## 这是什么

一个 **agent skill**（不是插件）：一份能被任意 agent 读懂并执行的文档 + 一组可直接运行的 PowerShell 脚本。

- 不侵入 DSH 代码，不注册任何服务；
- 只依赖官方发行物：Git for Windows 的 PortableGit、微软的 PowerShell 7；
- DSH 升级、换机器、换 agent 都还能用；删掉即可卸载。

## 它解决什么

Windows 上的 DSH 默认只有 PowerShell 执行器；各内置预设把 `tool-bash` 在 win32 上禁用，因为裸 `bash` 可能解析到 `C:\Windows\System32\bash.exe`（WSL 占位入口，没装发行版时跑不了命令）。

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

## 它到底改了什么

| 位置 | 改动 | 可逆性 |
|---|---|---|
| `%LOCALAPPDATA%\dsh-tools` | 只在"缺"或"升级"时解压 PortableGit / PowerShell 7，目录带版本号 | `restore.ps1 -Uninstall -DeleteTools` |
| 用户 PATH | 把选中的目录**提到最前**（并删掉自己装过的过期条目） | `restore.ps1 -RestorePath` |
| `<DSH home>\profiles\*\cordis.patch.yml` | 追加一段执行器切换条目（`bash-sandbox`） | `restore.ps1` 逐字节还原 |
| `%LOCALAPPDATA%\dsh-windows-shell\state.json` | 记录"检查过/已提议/已拒绝"的版本 | 删文件 |

**PATH 的硬边界**：Windows 的生效顺序是"机器级在前、用户级在后"，所以 `C:\Windows\System32\bash.exe`（装了 WSL 才有）永远压过用户 PATH。这种情况下脚本会告警，并可以用 `-Launcher` 生成一个先把目录塞进 PATH 再启动 DSH 的 ```launch-dsh.cmd```。

**代价（写在明面上）**：切换后 `pwsh` 工具名存实亡（执行器是 bash，PowerShell 语法会报错），需要 PowerShell 时显式调 `pwsh -NoProfile -Command`。执行器必须用 `bash-sandbox` 而不是 `bash-local`：后者没有 `sandboxMode`，会让权限预设插件拒绝挂载、聊天框的模式选择器消失。

## 回滚与卸载

```powershell
restore.ps1 -DryRun          # 只看差异
restore.ps1                  # 逐字节还原配置
restore.ps1 -RestorePath     # 连 PATH 一起还原
restore.ps1 -Restart         # 还原并重启 DSH
restore.ps1 -Uninstall                 # 还原 + 列出手上的工具目录
restore.ps1 -Uninstall -DeleteTools    # 连工具目录一起删
```

DSH 可执行文件路径是**运行时探测**的（运行中的进程 → 卸载注册表项 → 开始菜单快捷方式 → 默认安装位置），所以换用户名、换盘、便携版都能找到；都不行时用 `-DshExe` 指定。

## 已验证 / 未验证

- 已验证（本机实测）：探测能识别系统 Git 的 bash 2.56.0 与 pwsh 7.6.9，正确给出 `UPGRADE-OFFER` 且不下载；`-DryRun` 不改 PATH、不建目录；镜像测速真实选中 `gh-proxy.com` 并完成下载；sha256 校验、验签、解压后 smoke test 通过；`restore.ps1` 快照 6 个文件、`-DryRun` 全部 SAME、`-Uninstall -DryRun` 只比对不写盘；`restart-dsh.ps1 -ResolveOnly` 与 `restart-dsh.cmd -ResolveOnly`（参数转发）都能解析到真实 exe；全部脚本纯 ASCII、在 Windows PowerShell 5.1 下跑通。
- 未验证：全新无 Git / 无 PS7 机器上的首次安装（路径分支存在但未实跑）；`bash-sandbox` 在 read-only / workspace-write 档下的沙箱 runner 在 Windows 上能否启动；`-AskUpgrade` 在无控制台时的实际交互（逻辑已按"跳过"处理）。

## English summary

An agent skill that gives DeepSeek Harness a real bash executor on Windows and fills in a portable PowerShell 7. No admin rights, no plugin, fully revertible.

It is **two-phase**: use the shell the machine already has (only re-ordering the user PATH so the chosen one actually wins, and installing just the component that is missing), report an upgrade offer at the end, and download/install a newer release only when the user opts in (`-Upgrade` or `-AskUpgrade`). Downloads race a built-in mirror list by latency with GitHub as the final fallback and are verified by sha256 when the release publishes a digest. A machine copy that is newer than upstream is kept. Rollback is a single script; the DSH executable is discovered at run time instead of being hard-coded.

## License

MIT
