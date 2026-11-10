# dsh-windows-shell-toolchain

> 给 **DeepSeek Harness (DSH)** 在 Windows 上配一个真正的 bash 执行器，并把 PowerShell 7 便携版一并装好。**不需要管理员**，全程可回滚。

[English summary](#english-summary) · [安装](#安装) · [它到底改了什么](#它到底改了什么) · [回滚](#回滚)

## 这是什么

一个 **agent skill**（不是插件）：一份能被任意 agent 读懂并执行的文档 + 一组可直接运行的 PowerShell 脚本。

- 不侵入 DSH 代码，不注册任何服务；
- 只依赖官方发行物：Git for Windows 的 PortableGit、微软的 PowerShell 7；
- DSH 升级、换机器、换 agent 都还能用；删掉即可卸载。

## 它解决什么

Windows 上的 DSH 默认只有 PowerShell 执行器；各内置预设把 `tool-bash` 在 win32 上禁用，因为裸 `bash` 可能解析到 `C:\Windows\System32\bash.exe`（WSL 占位入口，没装发行版时跑不了命令）。

本技能做两件事：

1. 用 PortableGit 装一个**真 bash**，放进用户 PATH；
2. 用便携版 PowerShell 7 补上 pwsh 7，并把 DSH 的 profile 执行器换成 **`bash-sandbox`**（带 `sandboxMode`，因此权限预设与 `/permission` 不受影响）。

## 安装

~~~powershell
# 1) 装到技能目录（目录名保持 dsh-windows-shell-toolchain）
Expand-Archive dsh-windows-shell-toolchain-v1.0.2.zip -DestinationPath "$env:USERPROFILE\.dsh\skills" -Force

# 2) 先看看会下载什么（不实际下载）
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.dsh\skills\dsh-windows-shell-toolchain\scripts\setup-tools.ps1" -ResolveOnly

# 3) 正式安装（默认 %LOCALAPPDATA%\dsh-tools）
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.dsh\skills\dsh-windows-shell-toolchain\scripts\setup-tools.ps1"

# 4) 重启 DSH，让新 PATH 生效
~~~

然后让你的 agent 加载这个技能（`dsh-windows-shell-toolchain`），按 SKILL.md 第 7 节改 profile 补丁即可。

常用参数：`-Root` 装到别处、`-Mirror` 走下载加速、`-Offline` 只用已有包、`-SkipGit` / `-SkipPs7` 拆步。

## 它到底改了什么

| 位置 | 改动 | 可逆性 |
|---|---|---|
| `%LOCALAPPDATA%\dsh-tools` | 解压 PortableGit 与 PowerShell 7 | 删目录 |
| 用户 PATH | 追加两个目录 | `restore.ps1 -RestorePath` |
| `<DSH home>\profiles\*\cordis.patch.yml` | 追加一段执行器切换条目（`bash-sandbox`） | `restore.ps1` 逐字节还原 |

**代价（写在明面上）**：切换后 `pwsh` 工具名存实亡（执行器是 bash，PowerShell 语法会报错），需要 PowerShell 时显式调 `pwsh -NoProfile -Command`。执行器必须用 `bash-sandbox` 而不是 `bash-local`：后者没有 `sandboxMode`，会让权限预设插件拒绝挂载、聊天框的模式选择器消失。细节见 SKILL.md §5.1。

## 回滚

~~~powershell
restore.ps1 -DryRun          # 只看差异
restore.ps1                  # 逐字节还原配置
restore.ps1 -RestorePath     # 连 PATH 一起还原
restore.ps1 -Restart         # 还原并重启 DSH
~~~

## 已验证 / 未验证

- 已验证：PortableGit 解压出的 bash 与系统 Git 的 bash 同为 `5.3.15(2)-release`；PowerShell 7.6.9 便携版签名 Valid、可运行；`bash-sandbox` 作执行器时 bash 工具 exit 0 且上报 `sandbox: {mode: danger-full-access}`，权限预设选择器与 `/permission` 正常；脚本在 Windows PowerShell 5.1 下语法通过。
- 未验证：整条链路在「全新无 Git / 无 PS7」的机器上端到端跑通；`bash-sandbox` 在 read-only / workspace-write 档下的沙箱 runner 在 Windows 上能否启动。

## English summary

An agent skill that gives DeepSeek Harness a real bash executor on Windows, plus a portable PowerShell 7. No admin rights, no plugin, fully revertible. It installs PortableGit and PowerShell 7 into a user-writable directory, prepends them to the user PATH, and patches the DSH profile to use the bash executor. Rollback is a single script.

## License

MIT