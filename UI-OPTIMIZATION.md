# Daily Wallpaper UI 优化设计清单

> 基于当前代码（纯 AppKit、无 xib/storyboard）的 UI 现状调研整理。
> 现状核心问题：**全项目无任何动画（NSAnimationContext / CAAnimation）、无任何 hover 反馈（NSTrackingArea）**，功能完整但缺乏质感。

## 现状盘点

### 值得保留的部分
- unified 工具栏 + `fullSizeContentView` + sourceList 毛玻璃侧栏，现代 macOS 窗口骨架（`MainWindowController.swift`）
- 颜色基本使用语义色（labelColor / secondaryLabelColor / controlAccentColor），深色模式自动适配
- 瀑布流按原图宽高比排布（`MasonryCollectionViewLayout.swift`）
- 无障碍标签与 toolTip 覆盖较好

### 主要短板
| # | 问题 | 位置 |
|---|------|------|
| 1 | 零动画：切页、选中、缩略图加载、菜单栏图标切换全部瞬间跳变 | 全局 |
| 2 | 零 hover：卡片、侧栏行无任何悬停反馈 | 全局 |
| 3 | 卡片样式硬编码：纯黑背景、6pt 小圆角、无阴影，选中态仅 2pt 边框 | `MediaLibraryCollectionItem.swift` |
| 4 | 元数据条为硬编码黑色 58% 遮罩，非毛玻璃材质 | `MediaLibraryCollectionItem.swift` L51-L53 |
| 5 | 缩略图占位是 SF Symbol 图标，加载完成直接替换，无渐显 | `MediaLibraryCollectionItem.swift` L106-L125 |
| 6 | 空状态只有一行灰字，无插图、无引导按钮 | `MediaLibraryWindowController.swift` L23 / L251-L255 |
| 7 | 导入进度有精确计数却用不确定型菊花 | `ImportProgressWindowController.swift` L65-L67 |
| 8 | 分页加载用整体 `reloadData`，无增量插入动画 | `MediaLibraryWindowController.swift` L368-L369 |
| 9 | 设计常量（圆角/间距/字号/列宽）散落各文件硬编码 | 全局 |
| 10 | 菜单栏菜单纯文本，无图标、无当前壁纸预览 | `MenuBarController.swift` |
| 11 | 设置页为传统平铺表单 + "草稿+保存"模式，与 macOS 即时生效惯例不符 | `PreferencesWindowController.swift` |

---

## 优化项清单（按性价比排序）

### P0 — 媒体库卡片精修 ⭐️⭐️⭐️

视觉主战场，改完观感提升最明显。

- **hover 效果**：添加 `NSTrackingArea`，鼠标悬停时
  - 卡片轻微上浮（`translateY -2pt` 或 scale 1.02）
  - 出现柔和投影（`shadowRadius 12 / opacity 0.25`）
  - 元数据条从隐藏渐显（平时隐藏，hover 才出现，让图片本身成为主角）
- **元数据条材质化**：黑色 58% 遮罩 → `NSVisualEffectView`（material `.hudWindow` 或 `.popover`，配合 `maskImage` 做底部渐变），文字换语义色
- **圆角升级**：6pt → 10pt，与现代 macOS 卡片风格一致
- **选中态升级**：2pt 边框 → accent 色外发光（border + shadow 同色）+ 轻微 scale，切换加 0.15s 动画
- **卡片背景**：硬编码 `NSColor.black` → `underPageBackgroundColor` 等语义色

涉及文件：`MediaLibraryCollectionItem.swift`

### P0 — 缩略图加载体验 ⭐️⭐️⭐️

- **占位骨架**：SF Symbol 占位 → 中性灰底（可选 shimmer 微光动画）
- **渐显动画**：缩略图到达后 `CATransition` fade 0.2s，消除跳变
- **失败态**：保留 exclamation 图标，但配灰底居中小图标样式

涉及文件：`MediaLibraryCollectionItem.swift`

### P1 — 空状态升级 ⭐️⭐️

- 大号 SF Symbol 插图（如 `photo.on.rectangle.angled`，48pt，tertiaryLabel 色）
- 标题 + 副标题两行文案
- "导入图片"引导按钮（accent 主按钮样式），直接触发导入流程
- 区分两种空态：媒体库全空（引导导入）vs 筛选无结果（引导清除筛选）

涉及文件：`MediaLibraryWindowController.swift`

### P1 — 全局过渡动画 ⭐️⭐️

- **主窗口切页**：`MainContentHostViewController.show` 加 crossfade（`NSAnimationContext` + transition，约 0.2s）
- **设置分页切换**：`PreferencesViewController.showPage` 同样处理
- **菜单栏忙碌态**：图标瞬间替换 → 加旋转 `CABasicAnimation`（`arrow.triangle.2.circlepath` 持续旋转）
- **侧栏 footer 状态文字**：变化时 fade 过渡

涉及文件：`MainWindowController.swift`、`PreferencesWindowController.swift`、`MenuBarController.swift`

### P2 — 导入进度窗升级 ⭐️

- 不确定菊花 → 确定型 `NSProgressIndicator`（bar 样式），用 scanned/imported 计数驱动
- 明细统计从单行文字 → 分列小标签（已导入 / 重复 / 跳过 / 失败，失败用 systemRed）
- 完成时状态图标变化（checkmark.circle.fill 绿色）

涉及文件：`ImportProgressWindowController.swift`

### P2 — 菜单栏菜单质感 ⭐️

- 各动作菜单项加 SF Symbol 图标（`NSMenuItem.image`）
- 顶部加**当前壁纸缩略图预览项**（自定义 view 的 NSMenuItem，小圆角缩略图 + 标题）
- 版权信息文案与状态信息排版优化

涉及文件：`MenuBarController.swift`

### P2 — 分页加载动画 ⭐️

- `reloadData` → `insertItems(at:)` 增量插入，配合 `animator()` 渐显
- 新卡片出现时轻微 fade + 上移入场

涉及文件：`MediaLibraryWindowController.swift`、`MasonryCollectionViewLayout.swift`

### P3 — 设计 Token 收拢（为后续改版打底）

- 新建 `DesignTokens.swift`：统一圆角（cardCornerRadius）、间距（gridSpacing / contentInset）、字号层级、动画时长（fast 0.15s / normal 0.25s）
- 替换各文件中的魔法数字与硬编码颜色

### P3 — 设置页现代化（工作量较大，可单独排期）

- "草稿 + 保存按钮"模式 → macOS 惯例的即时生效
- 平铺表单 → macOS 13+ 系统设置风格的分组卡片（圆角组背景 `NSBox` custom / 分组行）
- 可考虑用 `NSGridView` 对齐表单行

涉及文件：`PreferencesWindowController.swift`

---

## 建议实施顺序

1. **第一批（视觉冲击最大）**：P0 卡片精修 + 缩略图渐显 + P1 空状态
2. **第二批（全局活起来）**：P1 全局过渡动画 + P2 分页插入动画
3. **第三批（细节质感）**：P2 导入进度窗 + 菜单栏菜单
4. **第四批（重构类）**：P3 设计 Token + 设置页现代化

## 验收要点

- 深色/浅色模式下均无违和（避免新引入硬编码颜色）
- 动画时长克制（0.15–0.25s），关闭"减弱动态效果"辅助功能时应尊重 `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion`
- hover/动画不影响滚动性能（瀑布流大量卡片场景，layer 复用注意 `prepareForReuse` 重置状态）
