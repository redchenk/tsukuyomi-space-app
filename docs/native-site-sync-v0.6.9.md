# 网站同步 · 0.6.9

版本：`0.6.9+15 / v0.6.9-beta.1`。本轮网站准源为 `redchenk/tsukuyomi-space@4b0ade76ac38dd0c0df551862b8b943a9cf96a15`，上版视觉准源为 `dba490894b62cd1799f8d9ab6fbf08199f9a335e`。对照提交差异、页面、接口及独立网站预览；原网站未提交的文档和输出文件保留。

## 页面、操作、权限及结果

| 页面 / 操作 | 网站准源 / API | 原生结果 | 验证 |
| --- | --- | --- | --- |
| 全站主题 | `useSeasonTheme.js`、`siteArt.js` | 自动按月份选择四季，可手选季节和南北半球；深浅主题独立保存；Room、Agent、编辑器及管理共用配色 | 月份、跨日、恢复、保存竞争及精确颜色 |
| 顶部导航 | `AppShell.vue`、网站分组导航 | 品牌 / 导航 / 工具分区；发现为 Wiki / 广场 / 图库 / 游戏，创作为文章 / 像素画，空间为 Agent OS / 现实回廊 / 友链 / 成长 / RSS；移动端保留原生设置和编辑入口 | 860px 断点、点击、方向键、Esc、外部关闭、焦点恢复、放大字体 |
| 季节素材 | `src/frontend/assets/{seasons,room,navigation}` | 29 个原站 WebP 原文件直接打包；用户上传封面优先 | 来源、文件长度和 SHA-256 见 `qa/theme-v0.6.9/source-assets.json` |
| Room 舞台 | 网站湖畔昼夜素材 | 四季背景；06:00–18:00 白昼，其余月夜；隐藏场景暂停昼夜时钟；继续复用原生模型与场景控制器 | 昼夜边界、Cubism 加载、生命周期及截图 |
| 全站音乐 | `/api/music/{status,qr,qr/check,logout,search,playlists,playlists/:id,tracks/:id/playback}` | 本站曲目 / 网易云扫码、确认状态、搜索、个人歌单、分页、头像 / 封面和播放；四种队列模式；音乐会话按站点与账号存入安全存储，只发往音乐接口 | 当前真实网站路由、独立数据库和可控上游；会话轮换、401、取消、分页、账号隔离 |
| Room 聊天 / 重生成 | `roomContext.mjs`、`roomMemoryRetrieval.mjs`、`/api/room/memory` | 按完整问答轮次裁剪；排除当前及短期历史的自动记忆；重生成冻结其他参考资料，向来源重新验证记忆版本、删除及所有权 | 当前网站生成的独立 JSON 样例、快照 / 删除 / 编辑、取消和账号切换 |
| LLM / Agent | 网站四类服务契约 | Kimi 参数、推理模型温度限制、仅官方 DashScope Qwen 3.8 参数；工具续接保留必要状态；原生 / 结构化模式、实时进度与统一网关继续可用 | 四协议 HTTP、真实 OpenCode / MCP、恢复、取消及沙箱 |
| 辉夜快跑 | `shared/kaguya-project-patch.cjs`、`/api/growth/game/leaderboard` | 重置 / 启动确认替代猜测帧数；保存累计分数与心情；速度 / 克隆数有界；排行榜显式分页 | 发射 / 节奏 / 战斗、200 次轮回 / 200 万分、分页和账号隔离 |
| 文章阅读 / 编辑 | 原站文章与素材接口 | 沿用网站排版、原生编辑 / 分栏 / 预览、上传、草稿恢复与发布；季节配色生效 | Markdown、输入 / 选区 / 撤销、草稿和发布回归 |
| 社区、Wiki、图库、附件、成长、通知、账户 | 当前页面和各自 API | 沿用真实原生操作和服务器权限；主题、素材及公共导航同步 | 28 页面 × 5 宽度 × 3 语言 × 2 主题及真实后端回归 |
| 后台 / 直接访问 | `/api/auth/me`、原站管理接口 | 仅服务端确认的 `admin` / `super_admin` 可见、可进入；角色撤销关闭旧菜单 | 权限与账号切换回归 |

## 加载与滑动

沿用惰性聊天列表、32ms 流式合并、稳定消息 ID、已完成 Markdown 缓存及异步像素纹理更新。素材按需加载；舞台解码高度限制为 1200px，导航预览宽度限制为 800px，音乐头像与封面按显示尺寸解码。导航动画支持系统减少动画设置。

季节控制器在下一次本地午夜更新；Room 昼夜只在下一次 06:00 / 18:00 更新，没有每秒轮询。网易云二维码仅在音乐面板打开且应用位于前台时检查。

## 复核与边界

[本地验证数据](qa/theme-v0.6.9/local-validation.json) 记录命令、测试结果和截图哈希；[素材出处](qa/theme-v0.6.9/source-assets.json) 记录原文件校验。截图位于开发工作区 `artifacts/theme-v069/`，正式安装包、许可证和 SHA-256 位于 GitHub Releases。

参考样例可执行 `node tool/sync_room_context_fixtures.mjs ../tsukuyomi-space` 重新生成。后端联调使用 `tool/testing/site_room_fixture.cjs`，音乐上游为受控测试提供方，不接触生产账号。完整 VM 压力回归与 Widget 截图不代表真实设备的 UI / Raster P95；不同 GPU、原生窗口、触控和 IME 仍需设备验收。

网站 CDN、SEO、PWA 缓存 / 图标指纹与部署项不进入原生启动流程。RSS 使用系统阅读器或浏览器打开公开订阅地址。这轮不新增原生 RSS 阅读器。

网易云沿用网站后端，真实扫码、版权 / 会员曲目和网络播放需用户账号验收，受上游可用性约束。模型与 Agent 通过受控 HTTP 和真实运行时验证，未使用用户付费供应商密钥。iOS 为 iPhoneOS unsigned IPA，需用户自签；macOS 未公证、Windows 未配可信发布者签名。Windows 缺少 PSEC 时拒绝执行命令。
