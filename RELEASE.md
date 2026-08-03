# Daily Wallpaper 发布指南

## Release 说明强制规则

每个版本必须在 `release-notes/` 目录中提供与 tag 同名的 Markdown 文件，例如：

```text
release-notes/v0.2.4.md
```

Release 说明必须按照下面的固定顺序包含三个二级标题：

1. `## 新增`：首次提供给用户的功能、入口或能力。
2. `## 变更`：已有功能的交互、界面、性能、兼容性或行为调整。
3. `## 修复`：已经存在且会影响用户的问题修正。

每个分类至少要有一个以 `- ` 开头的有效非空列表项，代码块中的示例不计入有效内容。某个版本没有对应内容时，也不能省略标题，必须写成 `- 无`。不要把提交记录直接复制成 Release 说明；每一项都应描述用户能感知的结果和影响。

标准模板位于 [`release-notes/TEMPLATE.md`](release-notes/TEMPLATE.md)：

```markdown
## 新增

- 无

## 变更

- 无

## 修复

- 无
```

允许在三个必需分类之后增加“下载与安装”“完整变更”等辅助信息，但不能改变必需标题的名称和顺序。GitHub Actions 会在构建前检查文件、标题顺序及列表项；校验不通过时不会创建 Release。

## 发布一个新版本

### 1. 确定版本号

tag 必须使用 `vX.Y.Z` 格式：

- `v0.1.1`：只包含向后兼容的问题修复。
- `v0.2.0`：增加向后兼容的新功能或明显能力。
- `v1.0.0`：正式稳定版本，或者包含不兼容调整。

已经推送并发布的 tag 不得覆盖或移动。发布后需要修正代码时，应提交修复并创建更高版本号。

### 2. 编写 Release 说明

从模板创建与新 tag 同名的说明文件，并基于上一个版本到当前版本的真实差异填写：

```bash
cp release-notes/TEMPLATE.md release-notes/v0.2.4.md
git log --oneline v0.2.3..HEAD
git diff --stat v0.2.3..HEAD
./Scripts/validate-release-notes.sh release-notes/v0.2.4.md
```

发布前至少确认：

- “新增、变更、修复”三个分类齐全且顺序正确。
- 没有内容的分类已经明确写为 `- 无`。
- 文案面向使用者，不包含无法从代码或测试确认的效果。
- “完整变更”链接中的前后 tag 正确。
- ad-hoc 签名与 Apple 公证限制仍与当前分发方式一致。

### 3. 验证并推送代码

Release 说明必须和准备发布的代码一起提交，并包含在即将创建 tag 的提交中：

```bash
./Scripts/test.sh
git status
git add release-notes/v0.2.4.md
git commit -m "补充 v0.2.4 发布说明"
git push origin main
```

如果版本代码尚未提交，应同时明确暂存本次需要发布的代码文件；不要使用 `git add -A` 混入无关改动。

### 4. 创建并推送 tag

确认 `main` 已推送、工作区干净，并且 `HEAD` 正是准备发布的提交：

```bash
git status
git log -1 --oneline
git tag -a v0.2.4 -m "发布 v0.2.4"
git push origin v0.2.4
```

到这里不需要手动构建 App，也不需要修改 Xcode 工程中的版本号。

GitHub Actions 会自动完成以下工作：

1. 校验 tag 格式以及对应 Release 说明。
2. 运行全部单元测试。
3. 将 tag 中的版本号写入 App。
4. 构建同时支持 Apple Silicon 和 Intel Mac 的通用架构 App。
5. 校验签名并生成带“应用程序”快捷入口的 DMG，同时保留 ZIP 备用包。
6. 分别生成 DMG 和 ZIP 的 SHA-256 校验文件。
7. 使用版本说明文件创建或更新 GitHub Release，并上传下载文件。

构建进度可以在仓库的 [Actions 页面](https://github.com/hdheid/daily-wallpaper/actions)查看，完成后的安装包可以在 [Releases 页面](https://github.com/hdheid/daily-wallpaper/releases)下载。

## 发布后的文案修正

如果 Release 说明存在错别字或分类错误，可以同步修正 GitHub Release 和 `main` 分支中的对应说明文件，但不要移动已经发布的 tag。涉及实际代码行为变化时，不能只修改文案，应发布一个更高版本。

## 当前分发限制

当前 App 使用 ad-hoc 签名，尚未使用 Developer ID 证书，也没有经过 Apple 公证。其他用户首次运行时，可能需要右键 App 选择“打开”，或在“系统设置 -> 隐私与安全性”中确认打开。

当前 GitHub 仓库已经公开，任何人都可以访问 Releases 页面并下载安装包。
