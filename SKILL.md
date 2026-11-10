---
name: dsh-windows-shell-toolchain
description: 把 DSH 在 Windows 上的命令执行环境搭好：一个真 bash（PortableGit）当执行器，外加 PowerShell 7 便携版。当新机器上 bash 工具不存在、或只有 Windows PowerShell 5.1 时使用。全程不需要管理员。
whenToUse: 在 Windows 上 DSH 没有 bash 工具、或只有 5.1 版 PowerShell；或用户要求「把这套装到新电脑」。先做 §2 探测，再按 §3 判据表决定做哪几步。POSIX 平台不需要本技能。
---

# DSH on Windows：把命令工具的执行 shell 换成 bash（并装好 PowerShell 7）

> 执行源。脚本在 scripts/ 下，参数化，不含任何具体机器的路径或版本。
> 每一步都要有实测输出；「应该能行」不算完成。

## 1. 铁律

1. **先有还原点，再改配置**。scripts/restore.ps1 先按本机改 targets 列表，再 -Snapshot。
2. **PowerShell 脚本写纯 ASCII**。Windows PowerShell 5.1 把无 BOM 的 UTF-8 当 ANSI 读，中文注释会让脚本解析失败。
3. **不碰 presets 内部**。profile patch 够不到预设里的 id；硬改会让预设消失，用户直接打不开会话。
4. **顺序固定**：验证 spawn → 改配置 → 重启 → 验收。

## 2. 探测（只读，先跑完再决定）

    where bash 2>nul
    where pwsh 2>nul
    echo %PROCESSOR_ARCHITECTURE%
    whoami /groups | findstr /i S-1-5-32-544 >nul && echo ELEVATED || echo NOT_ELEVATED

判定要点：

- C:\Windows\System32\bash.exe 是 WSL 入口，只有装了发行版才真能跑；wsl -l -q 无输出等于没有。
- 已经装了 Git 的机器，bash 通常在 <Git>\bin\bash.exe 和 <Git>\usr\bin\bash.exe。
- 装了 MSI 版 PowerShell 7 的机器，pwsh 在 %ProgramFiles%\PowerShell\7\pwsh.exe。

## 3. 判据表

| bash | PS7 | 做哪几步 |
|---|---|---|
| 有 | 有 | 只做 §7 配置 + §8 重启；可选 §9 验收 |
| 有 | 无 | §6 装 PS7 + §7 + §8 |
| 无 | 有 | §5 装 bash + §7 + §8 |
| 无 | 无 | §5 + §6 + §7 + §8 |

## 4. 选装目录

装哪里不影响功能，唯一硬要求是 **bash 所在目录必须进 PATH**（见 §6）。默认 %LOCALAPPDATA%\dsh-tools，可用 -Root 改；装在数据盘也行，因为不需要管理员。

## 5. 装 bash（PortableGit，不要 MinGit）

    powershell -NoProfile -ExecutionPolicy Bypass -File scripts\setup-tools.ps1 -SkipPs7

- **MinGit 里没有 bash**：只有 cmd/git.exe 与 ucrt64/*，没有 usr\bin\bash.exe。要 bash 必须 PortableGit。
- 版本默认取 GitHub 最新 release；要固定就传 -GitVersion 2.56.0.4。
- 下载慢或连不上 GitHub 时，传 -Mirror <前缀>，脚本会先试镜像再退回 origin；不传就只有 origin。
- 已下载过的包带 .ok 标记才算完整；中断留下的 .part 不会被复用。

## 5.1 背景：官方为什么在 Windows 上关掉 tool-bash

官方组合在 win32 上 `ctx.shell` 是 dsh-pwsh-sandbox，且各预设的 tool-bash 行被 `process.platform === 'win32'` 关掉。原因不是疏忽：Windows 上裸 `bash` 可能解析到 C:\Windows\System32\bash.exe —— 那是 WSL 的占位入口，没装发行版时它不能执行命令。

所以「让 Windows 有 bash」只有两条路：

1. **保证 PATH 里有真 bash，再把执行器换成 bash**（本技能走这条，靠 PortableGit）；
2. 另写一个自带执行器的插件（不推荐：要把代码绑进官方会变的内部结构，官方一升级就得追）。

### 执行器必须选 bash-sandbox，不能选 bash-local

`@deepseek-ai/dsh-permission-presets` 构造时有一道硬检查：

    if (ctx.shell.sandboxMode === void 0) throw new Error("permission: the mounted bash executor does not confine (no sandboxMode) ...");

权限预设要求 shell 执行器**自称能隔离**。`dsh-bash-local` 没有 `sandboxMode`，挂上去会让权限预设插件拒绝挂载，聊天框的模式选择器和 `/permission` 命令会一起消失。`dsh-bash-sandbox` 是它的子类，只多了 `sandboxMode` 与隔离装饰；在 `danger-full-access` 档下它直接走父类执行、不套任何约束，命令手感与 `bash-local` 完全一致。

它官方标称 POSIX-only：受限档（read-only / workspace-write）的沙箱 runner 在 Windows 上能否起来**未验证**。一旦受限档报错，切回 danger-full-access 即可。

### 已知代价

- `pwsh` 工具名存实亡：执行器是 bash，PowerShell 语法会报错；profile patch 改不动预设层那份 tool-pwsh，禁不干净。需要 PowerShell 时显式调 `pwsh -NoProfile -Command '...'`。
- 命令以 harness 进程权限运行，约束由当前权限档决定，不再来自 pwsh-sandbox。

## 6. PATH 与 spawn 解析（成败关键）

bash 执行器（`bash-local` 与 `bash-sandbox` 同源）硬编码 spawn('bash')，**没有 bashPath 之类配置项**。所以：

- bash 必须能被 PATH 解析到，装在哪不重要，进 PATH 才重要；
- 改用户 PATH 只对**新进程**生效，正在跑的 DSH 用的是旧 PATH → 必须重启 DSH；
- 用 Node 直接 spawn 验证，别在交互 shell 里手打（那用另一套解析）：

    node -e "const{execFileSync}=require('child_process');console.log(execFileSync('bash',['-c','echo $BASH_VERSION'],{encoding:'utf8'}))"

## 7. 改 DSH profile 补丁

文件：<DSH home>\profiles\<profile>\cordis.patch.yml，追加到末尾。

patch 语义：**按 id 定位的条目是整条替换，不深合并**（官方原文：a user patch replaces the whole matched config）。由此两条硬规则：

1. 改已有条目必须重述要保留的字段（尤其 name），否则条目变空壳、静默失效；
2. **新增**插件必须写成 insert 列表，单个 id 条目插不进去。

最小可用块（把 cwd 换成目标工作区）：

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

写完先解析校验 YAML 再落盘（profile 目录里的 js-yaml 或任意 YAML 解析器都行）。

## 8. 重启与验收

    scripts\restart-dsh.cmd

验收三连，缺一不算完成：

1. 工具表里有 bash；
2. 真跑一条：echo $0; uname -s; pwd，期望 bash 路径 + MINGW/MSYS + 目标目录，exit 0；
3. **新会话也拿到**：开一个 subagent，让它自报工具名并实跑一条——子 agent 走新实例化路径，能验出预设层的问题。

## 9. 故障对照

| 现象 | 原因 | 处理 |
|---|---|---|
| spawn bash ENOENT | 进程 PATH 是旧的 | 重启 DSH |
| NtCreateDirectoryObject ... 0xC0000022 | 在已有 MSYS 环境里嵌套跑另一套 MSYS | 从原生进程（powershell.exe/cmd）调，并清掉 MSYSTEM / MSYS / MSYS2_PATH_TYPE |
| 工具有 pwsh 但 PowerShell 语法报错 | 执行器被换成 bash 了，pwsh 只是名字 | 命令走 bash 工具；要 PowerShell 就显式调 pwsh -NoProfile -Command |
| 改完配置当前会话工具不变 | 预设只决定新建 agent | 用 subagent 或新会话验收 |
| 会话打不开，报 Unknown agent preset | 用不完整条目覆盖了预设节点 | 跑 restore.ps1 还原，别在坏状态继续改 |

## 10. 回滚与卸载

    scripts\restore.ps1 -DryRun          # 只看差异
    scripts\restore.ps1                  # 逐字节还原配置
    scripts\restore.ps1 -RestorePath     # 连用户 PATH 一起还原
    scripts\restore.ps1 -Restart         # 还原后重启

完整卸载 = 还原配置 + 从用户 PATH 删掉装的两个目录 + 删除 -Root 目录。

## 11. 脚本参数

| 参数 | 默认 | 含义 |
|---|---|---|
| -Root | %LOCALAPPDATA%\dsh-tools | 安装根目录 |
| -GitVersion | latest | PortableGit 版本，或固定版本号 |
| -Ps7Version | latest | PowerShell 版本，或固定版本号 |
| -Mirror | 空 | 可选下载前缀，先试它再试 origin |
| -ResolveOnly | 关 | 只打印将要下载的 URL，不下载（可用来测网络） |
| -Offline | 关 | 只用已有的包，不联网 |
| -SkipGit / -SkipPs7 / -SkipPath | 关 | 拆开单步执行 |

架构自动识别：ARM64 取 arm64 资产，其余取 x64。

## 12. 文件清单

- SKILL.md：这份执行源
- scripts/setup-tools.ps1：解析版本 → 下载 → 解压 → 验签 → 写 PATH（纯 ASCII，5.1 可用）
- scripts/verify.ps1：检查 bash / pwsh7 / PATH
- scripts/restore.ps1：快照、dry-run、逐字节还原、还原 PATH、重启
- scripts/restart-dsh.cmd / restart-dsh.ps1：重启 DSH