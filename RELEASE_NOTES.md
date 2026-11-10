# v1.0.0

首个公开版本。

## 内容

- `setup-tools.ps1`：解析最新版本 → 下载（可选镜像）→ 解压 → 验签 → 写用户 PATH
- `restore.ps1`：快照 / dry-run / 逐字节还原 / 还原 PATH / 重启 DSH
- `verify.ps1`：检查 bash、PowerShell 7、PATH
- `restart-dsh.cmd`：重启 DSH
- `SKILL.md`：探测判据、安装步骤、profile patch 形状、故障对照、已知代价

## 已验证

- Windows 11 (22631) + DSH 0.2.2-rc.1
- bash `5.3.15(2)-release`（PortableGit 与系统 Git 版本一致）
- PowerShell `7.6.9` 便携版，签名 Valid（CN=Microsoft Corporation）

## 已知限制

- `pwsh` 工具在切换后会名存实亡（由 bash 执行），需显式 `pwsh -NoProfile -Command`
- 切换后命令不经文件沙箱
- 全新无 Git/无 PS7 机器的完整端到端流程尚未实测