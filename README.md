# Knot

本地优先的 AI 编码工作台：自动发现 Claude Code / Codex 会话，按代码目录组织、搜索和续接。

## 一键安装或升级

```bash
curl -fsSL https://raw.githubusercontent.com/knot-projects/knote/main/install.sh | sh
```

安装脚本会自动识别 Linux 或 macOS 以及 amd64 或 arm64，校验下载文件后完成首次安装；再次执行同一命令即可升级到最新版本。安装或升级完成后会直接在前台启动 Knot Server，不会打开浏览器。服务地址为 `http://127.0.0.1:7330`，按 `Ctrl+C` 停止。

## 卸载

```bash
curl -fsSL https://raw.githubusercontent.com/knot-projects/knote/main/install.sh | sh -s -- --uninstall
```

卸载只删除 `knot` 可执行文件，保留用户数据。

## 手动下载

可以在 [GitHub Releases](https://github.com/knot-projects/knote/releases/latest) 下载对应平台的压缩包及 `SHA256SUMS`。
