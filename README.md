# Knot

本地优先的 AI 编码工作台：自动发现 Claude Code / Codex 会话，按代码目录组织、搜索和续接。

## 安装

Linux / macOS：

```bash
curl -fsSL https://raw.githubusercontent.com/knot-projects/knote/main/install.sh | sh
```

Windows（PowerShell）：

```powershell
irm https://raw.githubusercontent.com/knot-projects/knote/main/install.ps1 | iex
```

安装脚本会在后台启动 Knot，并配置当前用户登录后自动启动；不会自动打开浏览器。Linux 使用 systemd user service，macOS 使用 LaunchAgent，Windows 使用当前用户的启动注册表项，全程不需要管理员权限。

## 卸载

Linux / macOS：

```bash
curl -fsSL https://raw.githubusercontent.com/knot-projects/knote/main/install.sh | sh -s -- --uninstall
```

Windows（PowerShell）：

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/knot-projects/knote/main/install.ps1))) -Uninstall
```

卸载会停止 Knot 并移除对应的自动启动项，用户数据仍会保留。

## 手动下载

可以在 [GitHub Releases](https://github.com/knot-projects/knote/releases/latest) 下载 Linux、macOS 或 Windows 对应架构的可执行文件。
