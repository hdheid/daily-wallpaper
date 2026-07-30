# Daily Wallpaper 发布指南

## 发布一个新版本

发布前先确认需要发布的代码已经提交，并且 `main` 分支已推送到 GitHub：

```bash
git status
git push origin main
```

然后创建并推送一个 `vX.Y.Z` 格式的版本 tag。例如发布 `v0.2.0`：

```bash
git tag -a v0.2.0 -m "发布 v0.2.0"
git push origin v0.2.0
```

到这里发布操作就完成了，不需要手动构建 App，也不需要手动修改 Xcode 中的版本号。

GitHub Actions 会自动完成以下工作：

1. 运行全部单元测试。
2. 将 tag 中的版本号写入 App。
3. 构建同时支持 Apple Silicon 和 Intel Mac 的通用架构 App。
4. 校验签名并生成带“应用程序”快捷入口的 DMG，同时保留 ZIP 备用包。
5. 分别生成 DMG 和 ZIP 的 SHA-256 校验文件。
6. 创建 GitHub Release 并上传下载文件。

构建进度可以在仓库的 [Actions 页面](https://github.com/hdheid/daily-wallpaper/actions)查看，完成后的安装包可以在 [Releases 页面](https://github.com/hdheid/daily-wallpaper/releases)下载。

## 版本号规则

tag 必须使用 `vX.Y.Z` 格式，例如：

- `v0.1.1`：修复问题，没有新增主要功能。
- `v0.2.0`：增加新功能，但保持兼容。
- `v1.0.0`：正式稳定版本，或者存在较大的不兼容调整。

已经推送并发布的 tag 不要覆盖或移动。如果发布后需要修复问题，应提交修复代码并创建一个更高的新版本号。

## 当前分发限制

当前 App 使用 ad-hoc 签名，尚未使用 Developer ID 证书，也没有经过 Apple 公证。其他用户首次运行时，可能需要右键 App 选择“打开”，或在“系统设置 -> 隐私与安全性”中确认打开。

当前 GitHub 仓库已经公开，任何人都可以访问 Releases 页面并下载安装包。
