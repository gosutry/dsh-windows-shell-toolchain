---
name: dsh-windows-shell-toolchain
description: 把 DSH 在 Windows 上的命令执行环境补齐：真 bash（PortableGit）当执行器 + PowerShell 7 便携版。新机器无 bash、或只有 PowerShell 5.1 时使用。不需要管理员。
whenToUse: Windows 上 DSH 没有 bash 工具、或只有 5.1 版 PowerShell；或要把这套装到新电脑。先 §2 探测，按 §3 判据选步骤。POSIX 平台不用本技能。
---

# DSH Windows shell toolchain

## 1. 铁律

1. 先快照：`scripts/restore.ps1 -Snapshot`
2. PowerShell 脚本写纯 ASCII（5.1 按 ANSI 读无 BOM UTF-8）
3. 不碰 presets 内部 id
4. 顺序：验证 spawn → 改配置 → 重启 → 验收

## 2. 探测

    where bash 2>nul
    where pwsh 2>nul
    echo %PROCESSOR_ARCHITECTURE%
    whoami /groups | findstr /i S-1-5-32-544 >nul && echo ELEVATED || echo NOT_ELEVATED

- `C:\Windows\System32\bash.exe` 是 WSL 入口，装了发行版才可用
- Git 的 bash：`<Git>\bin\bash.exe`
- MSI 版 PS7：`%ProgramFiles%\PowerShell\7\pwsh.exe`

## 3. 判据

| bash | PS7 | 做哪几步 |
|---|---|---|
| 有 | 有 | §7 + §8 |
| 有 | 无 | §5 + §7 + §8 |
| 无 | 有 | §4 + §7 + §8 |
| 无 | 无 | §4 + §5 + §7 + §8 |

## 4. 装 bash

    powershell -NoProfile -ExecutionPolicy Bypass -File scripts\setup-tools.ps1 -SkipPs7

- 必须 PortableGit；MinGit 不含 `usr\bin\bash.exe`
- 版本默认 latest，固定用 `-GitVersion <版本>`
- 下载慢加 `-Mirror <前缀>`；`.ok` 标记存在才算完整包
- 执行器用内置 `bash-sandbox`（`- id: bash-sandbox` / `disabled: false`）；不要用 `bash-local`——没有 `sandboxMode`，权限预设插件拒绝挂载，聊天框选择器与 `/permission` 会消失

## 5. 装 PowerShell 7

    powershell -NoProfile -ExecutionPolicy Bypass -File scripts\setup-tools.ps1 -SkipGit

## 6. PATH

- bash 所在目录必须进 PATH；执行器硬编码 `spawn('bash')`，无 `bashPath` 配置
- 改 PATH 只对新进程生效 → 重启 DSH
- 验证：

    node -e "const{execFileSync}=require('child_process');console.log(execFileSync('bash',['-c','echo $BASH_VERSION'],{encoding:'utf8'}))"

## 7. profile 补丁

文件：`<DSH home>\profiles\<profile>\cordis.patch.yml`，追加到末尾。

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

## 8. 验收

    scripts\restart-dsh.cmd

1. 工具表里有 `bash`
2. `echo $0; uname -s; pwd` → exit 0，输出 bash 路径 + MINGW/MSYS + 目标目录
3. 开 subagent，让它自报工具名并实跑一条

## 9. 故障

| 现象 | 处理 |
|---|---|
| `spawn bash ENOENT` | 进程 PATH 是旧的 → 重启 DSH |
| `NtCreateDirectoryObject ... 0xC0000022` | 从 powershell.exe/cmd 调，并清 `MSYSTEM` / `MSYS` / `MSYS2_PATH_TYPE` |
| pwsh 工具报 PowerShell 语法错 | 执行器是 bash → 用 bash 工具，或显式 `pwsh -NoProfile -Command` |
| 当前会话工具表不变 | 预设只影响新建 agent → 用 subagent 或新会话验收 |
| `Unknown agent preset` | 用不完整条目覆盖了预设节点 → `restore.ps1` 还原 |

## 10. 参数

| 参数 | 默认 | 含义 |
|---|---|---|
| `-Root` | `%LOCALAPPDATA%\dsh-tools` | 安装根目录 |
| `-GitVersion` | `latest` | PortableGit 版本或固定号 |
| `-Ps7Version` | `latest` | PowerShell 版本或固定号 |
| `-Mirror` | 空 | 可选下载前缀，先试它再试 origin |
| `-ResolveOnly` | 关 | 只打印下载 URL，不下载 |
| `-Offline` | 关 | 只用已有包，不联网 |
| `-SkipGit` / `-SkipPs7` / `-SkipPath` | 关 | 拆步执行 |

架构自动识别：ARM64 取 arm64 资产，其余 x64。

## 11. 回滚

    scripts\restore.ps1 -DryRun          # 只看差异
    scripts\restore.ps1                  # 逐字节还原配置
    scripts\restore.ps1 -RestorePath     # 连用户 PATH 还原
    scripts\restore.ps1 -Restart         # 还原并重启

卸载 = 还原配置 + 从用户 PATH 删掉两个目录 + 删除 `-Root` 目录。