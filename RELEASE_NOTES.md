# v1.0.1

修正执行器选型：改用 `bash-sandbox`，此前用 `bash-local` 会让权限预设插件拒绝挂载。

## 变更

- profile 补丁：`insert` 挂 `bash-local` 改为放开内置的 `bash-sandbox`（带 `sandboxMode`）
- SKILL.md §5.1：写明 `@deepseek-ai/dsh-permission-presets` 的 `ctx.shell.sandboxMode` 硬检查，以及为什么不能用 `bash-local`
- README：同步执行器说明与已知代价

## 已验证（Windows 11 22631 + DSH 0.2.2-rc.1）

- bash 工具 exit 0，`SHELL=/usr/bin/bash`，上报 `sandbox: {mode: danger-full-access}`
- 权限预设选择器与 `/permission` 正常工作
- PowerShell 7.6.9 便携版签名 Valid

## 未验证

- 受限档（read-only / workspace-write）下 Windows 的沙箱 runner 能否启动
- 全新无 Git / 无 PS7 机器的完整端到端流程