# Room 双端 UI 对齐

2026-09-27，以 https://yachiyo.hk/room 的实际桌面和移动界面为参照。实现使用 Flutter widgets 与既有 Cubism Native 场景，未嵌入网站。原网站仓库未修改。

## 对照基准

| 项目 | 桌面 | 移动端 |
| --- | --- | --- |
| 主要对照尺寸 | 1440×960 | 390×844 |
| 布局断点 | 宽度 > 860 | 宽度 ≤ 860 |
| 导航 | 居中顶部导航，高 68、最大宽 1320 | 顶部悬浮导航，左右 12、高 60 |
| 主体 | 上距 104、左右 24、底部 20；舞台／聊天约 1.38:1，间隔 17 | 全屏角色与房间背景，聊天浮于场景之上 |
| 输入 | 白色聊天面板中的多行输入、快捷话题、发送提示 | 底部半透明胶囊输入框，键盘弹出后上移并隐藏话题 |
| 视觉 | 淡紫底色、白色面板、紫色强调、宋体标题、夜间公寓场景 | 复用场景与角色，浅色悬浮控件、白色欢迎文案 |

素材复用网站已有的 `moonlit-lake.png`、`room-night-apartment.webp` 和 `yachiyo-portrait.webp`。图标使用 Cupertino/Material 图标库近似表达；文字使用系统字体回退，各系统字形不保证逐像素相同。

## 本次实现

桌面和移动端分别组织界面；窗口跨越断点时使用同一个角色状态。保留原生模型加载、流式回复、取消重试、WAV 口型、账号和同步能力。新增新建会话、本机历史搜索、安静陪伴、本机便签和主题切换。

新建会话保留旧历史，仅切换当前运行中的显示和模型上下文。便签按账号范围独立保存，当前不上传网站。导航中的中枢／舞台／广场／百科等打开现有站点。日记、音乐显示明确的未接入说明和网站入口；图片聊天禁用。动作文件调度、截图保存、完整网站功能仍不在这次 UI 迁移范围。

## 验证与截图

- 真实 Cubism、眨眼与合成、状态、六种窗口尺寸和横竖屏键盘测试共 33 项通过。
- 本机截图测试分别渲染 1440×960 和 390×844，使用真实原生模型与本机字体，已与网站同尺寸截图人工对照。
- macOS 原生应用已打开并检查布局；移动截图来自 Flutter widget 渲染，不能代替 Android/iOS 真机验证。
- macOS Debug 和 Web 构建通过；其他平台保留工程与既有 CI 配置，未作本机验收。

本地截图位于 `artifacts/ui-alignment/`：`website-desktop.png`、`website-mobile.png`、`flutter-desktop.png`、`flutter-mobile.png`、`native-macos.png`。截图、SDK、模型和本机字体均不提交。

准备好 Cubism SDK、模型与 macOS 中文字体后，可显式运行截图用例：

```sh
flutter test test/room_visual_capture_test.dart --dart-define=CAPTURE_UI=true
```

该用例普通 CI 默认跳过。macOS 的 Songti 字体集合首个字重可能偏粗；可用 `--dart-define=QA_SERIF_FONT=/absolute/path/to/local-regular-font.ttf` 指定本机常规宋体，仅用于测试，不随应用打包或分发。
