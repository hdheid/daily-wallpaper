# UI 优化任务清单

> 依据 `UI-OPTIMIZATION.md` 拆解，按实施顺序排列（Token 先行，供后续任务复用）。
> 完成一项勾选一项；每批完成后执行 `./Scripts/build.sh` 验证。

## 任务列表

- [x] **T1 · 设计 Token 收拢**（P3 提前）
  新建 `DesignTokens.swift`：卡片圆角、阴影参数、动画时长（fast 0.15s / normal 0.22s）、瀑布流间距等；提供 `reduceMotion` 判断入口。
- [x] **T2 · 媒体库卡片精修**（P0）
  hover 上浮 + 投影 + 元数据条渐显；元数据条换 `NSVisualEffectView` 毛玻璃；圆角 6→10；选中态 accent 光晕 + 0.15s 动画；卡片背景换语义色。
- [x] **T3 · 缩略图加载体验**（P0）
  SF Symbol 占位 → 中性灰底占位；缩略图到达后 0.2s 渐显；失败态灰底居中小图标。
- [x] **T4 · 空状态升级**（P1）
  48pt SF Symbol 插图 + 标题/副标题 + "导入图片"引导按钮；区分"库为空"与"筛选无结果"两种空态。
- [x] **T5 · 全局过渡动画**（P1）
  主窗口切页 crossfade；设置分页切换 crossfade；菜单栏忙碌图标旋转动画；侧栏状态文字 fade。
- [x] **T6 · 分页增量插入动画**（P2）
  追加分页从整体 `reloadData` 改为 `insertItems(at:)`，新卡片渐显入场。
- [x] **T7 · 导入进度窗升级**（P2）
  不确定菊花 → 确定型进度条（scanned 驱动）；统计分色显示（失败红色）；完成态绿色对勾图标。
- [x] **T8 · 菜单栏菜单质感**（P2）
  动作菜单项加 SF Symbol 图标；顶部加当前壁纸缩略图预览项。
- [x] **T9 · 设置页分组卡片视觉升级**（P3，仅视觉）
  平铺表单 → 分组圆角卡片风格。
- [x] **T9.1 · 设置页即时生效**（追加）
  移除"草稿 + 保存"交互：控件变化直接提交 SettingsStore / LaunchAtLoginService，删除两个"保存更改"按钮与草稿结构，对齐 macOS 设置惯例。
- [x] **T10 · 构建验证与回归**
  `./Scripts/build.sh` 通过；`./Scripts/test.sh` 通过；深色/浅色模式无硬编码颜色违和。

## 约束

- 纯系统 API，不引入第三方依赖（Swift 6 / AppKit / macOS 13+）
- 所有动画尊重 `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion`
- 卡片复用（`prepareForReuse`）必须重置 hover/动画状态，避免滚动错乱
