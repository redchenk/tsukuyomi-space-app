# 0.6.0 Room 与桌面 Agent 验收

原站代码基准：`6f784dd80093ab43c7d1140485411a77e82df366`。客户端版本：`0.6.0+6`，发布标签：`v0.6.0-beta.1`。本轮沿用原站后端、账号权限和用户模型配置，未新增公共模型服务。

## 页面、操作、权限与 API 核对表

下表中的接口是现有原站接口；页面读取、交互及服务端写入均保留原权限。历史完整迁移说明见 [0.5 整站记录](native-full-site-implementation-2026-09-30.md)，本轮覆盖完整回归并增加 Room、Agent 和编辑器验证。

| 页面 | 操作 | 权限 | API / 数据源 | 结果与回归证据 |
| --- | --- | --- | --- | --- |
| `/`、`/access`、旧 HTML 别名 | 启动、内部链接和旧链接 | 全部 | 原生路由 | 直接 Room；不实例化 Access；`site_routes_test`、`room_first_and_menu_test` |
| Room / 分享对话深链接 | 输入、图片、流式回复、重试、停止、修改、重新生成、分享 | 访客本地；登录云端 | 用户模型；`/api/room/chat`、`/turn`、`/images`、分享接口 | 四种协议；稳定 ID、先本地保存、迟到同步合并；Room 协议、控制器、分享及后端测试 |
| Room 设置 | 模型、TTS、知识、记忆、布局、日记、MCP、Live2D | 本机配置；账号私有数据 | 设备安全存储、原 `/api/room/*` | 演示默认关闭；就地配置；旧演示记录保留；`room_first_and_menu_test` |
| 日记 / 资料 / 便签 | 生成、编辑、搜索、导入导出、删除、人设 | 对应账号 / 本机 | `/api/room/diary`、persona、设备草稿 | 源码及 Room archive / parity 回归 |
| 长期记忆 | 本地、云端、合并、评分、向量同步 | 私有账号 / 访客 | `/api/room/memories`、memory-source | 原站字节/条数上限、账号隔离、幂等合并；memory-source 真后端回归 |
| 桌面 Room Agent | 开始、恢复、取消、文件、命令、MCP、审批、差异 | 所选目录；越界、外部操作需确认 | 捆绑 OpenCode 1.18.33、本地 MCP 网关、Codex 0.159.0 沙箱 | 四协议真实进程、恢复无重放、目录逃逸、取消、20 次上限测试 |
| `/hub` | 聚合内容、公告、统计、快捷留言 | 公开；写留言须登录 | `/api/hub-preview`、stats、messages | `hub_page_test`、原站后端联调 |
| `/stage`、文章 | 分类、搜索、排序、分页、HTML/Markdown、目录、阅读进度 | 公开 / 原站可见性 | `/api/articles`、article-categories、阅读及互动接口 | `native_article_rendering_test`、`site_backend_integration_test` |
| 文章互动 | 评论、回复、点赞、收藏、有效阅读、分享 | 写入登录；阅读公开 | articles/comments/like、bookmarks、read、growth | 真实 Express/SQLite 联调、通知与分享回归 |
| `/editor` | 创建、作者修改、审核修改、草稿恢复、格式、素材、摘要、发布 | 作者 / admin / super_admin；公告限制沿用 | `/api/articles`、`/api/user/articles/:id`、`/api/moderation/articles/:id`、summarize | 固定工具栏、元信息折叠、三视图、中文 IME、选区/撤销；creation / Agent article 回归 |
| Agent 文章操作 | 读取、版本检查、修改、差异、撤销、确认发布 | 已登录；同原编辑器 | 活跃原生草稿、现有文章接口 | 冲突不覆盖手动修改；确认含完整字段；`agent_article_workflow_test` |
| `/plaza` | 留言、回复、点赞、搜索、筛选、作者主页 | 公开读取；登录写入；原审核规则 | `/api/messages` | 评论及留言真后端、目标锚点回归 |
| `/gallery`、manage | 浏览原图、筛选、随机、上传 JPEG、个人管理 | 原站公开 / 所有者 | `/api/gallery` | `native_gallery_details_test`、full-site backend |
| `/attachments` | 选择、上传、暂停、取消、重试、续传、素材引用、下载 | 登录个人附件 | `/api/assets/uploads`、分片、complete、assets | SHA-256、4MB 分片；100MB 站点上限；creation / 真后端回归 |
| Agent 上传 | 内容预览、摘要确认、提交 | 登录；目录外读额外确认 | 同附件接口 | 提交已确认的不可变临时快照；名字、MIME、大小、SHA-256 与文本/图片预览 |
| `/pixel` | 绘画、撤销重做、导入导出、草稿、发布、编辑、删除、点赞、分享 | 本机绘画；登录作品 | `/api/pixel-art`、manage | `pixel_native_test`、真实发布接口 |
| `/game` | 跑酷、飞行、节奏、战斗、暂停、重开、键盘/触摸、排行 | 本地游戏；原成绩规则 | 原项目资源、Box2D、成绩/排行榜接口 | `game_native_test`、真后端提交 |
| `/wiki` | 19 条目、91 图片、交叉链接、目录与来源 | 公开 | 原站生成的静态归档 | `site_archive_pages_test` |
| `/friend-links`、`/reality` | 目录、申请、说明、联络链接 | 公开；原申请校验 | friend-links、原说明数据 | 静态/后端回归；外链保留原目标 |
| 登录、注册、忘记密码、QQ | 验证码、确认密码、回跳、绑定、补全资料 | 原服务器会话 | `/api/auth/*` | `native_auth_test`、login / account 回归 |
| `/user`、公开主页 | 独立昵称、只读 ID/登录用户名、资料、头像、密码、绑定、个人文章/留言/收藏/像素 | 当前账号 / 公开资料 | `/api/user/*`、mine、bookmarks、manage | `user_center_account_test`、full-site backend |
| `/growth` | 签到、每日任务、邀请、分享、成长记录 | 原站账号规则 | `/api/growth/*` | `site_growth_test`、daily-view / backend |
| `/notifications` | 分页、角标、单条/全部已读、偏好、目标跳转 | 当前有效账号 | `/api/user/notifications*` | notification / share / anchor 真后端回归 |
| `/admin` | 分类、内容审核、编辑、删除及用户管理 | 服务端有效 admin / super_admin | 原 moderation / admin 接口 | 入口隐藏；直接访问也验证；`management_native_test`、full-site backend |
| `/terminal` | 终端登录、角色管理能力 | 原终端会话及服务端角色 | 原 admin 终端 API | 与站内会话分离、原角色分工；management 回归 |
| `/live2d` | 参数、完整动作、导演、队列、字幕、直播调度、语音 | 隐藏原生工具页 | 原动作语义、导演/模型协议 | `live2d_director_test`；普通/全屏 Room 共享模型和时钟 |
| 全站导航与菜单 | 四组、选中状态、键盘、Esc、外部点击、焦点恢复、主题/语言 | 后台需服务端角色 | 统一原生导航与设备偏好 | 360/390/768/1280/1920、zh/ja/en、深浅主题、2 倍字体回归 |

原站 `/agent-os` 是独立部署应用。本版在原生 Room 内提供任务 Agent，不迁移完整 Agent OS，也不把外部网页当作原生 Agent 实现。

## 启动与隔离

根路由及 Access 别名统一解析为 `/room`；文章和共享会话深链接保留目标。升级时一次性关闭旧默认演示；随后用户显式开启演示仍有效。演示历史与真实历史分区保存。

本地配置、凭据提示和历史就绪后即可输入。服务端身份验证随后执行，验证期间不上传聊天或私有云数据；新的完整轮次先保存在账号本地待同步队列。同一账号确认后合并上传，不重新载入启动前历史覆盖新消息。缓存提示不含管理员角色；后台权限以服务端有效身份为准。角色失效或菜单所属页面销毁时，已经展开的菜单立即关闭，避免保留旧后台入口。

## 运行时与工具边界

桌面安装包附 OpenCode 1.18.33 和 Codex 0.159.0，无需预装 Node/npm 或两个 CLI。普通聊天不启动它们。Agent 首次使用时校验全部文件 SHA-256，启动回环随机端口和临时鉴权；上游模型密钥留在 Flutter 协议桥接层，不写入 OpenCode 配置。运行时禁止自动升级、项目配置、插件、LSP、格式器及全部内置执行工具，只开放经网关注册的 MCP 工具。

网关逐项校验结构化参数、真实路径和符号链接，串行执行，每任务最多 20 次工具操作。命令仅调用捆绑 Codex 系统沙箱，默认禁止网络、限制所选目录写入、超时 120 秒、输出上限 64KiB；沙箱缺失或启动失败即停止。Windows 严格使用 Codex 内置 MXC/PSEC 后端；上游旧 elevated/unelevated 后端无法满足本计划的根目录默认拒绝读取策略，因此不启用。系统缺少 PSEC 时命令直接停止，不放宽目录读取权限，也不创建系统账户。提权命令展示确认后仍停止，绝不绕过沙箱。操作系统基础只读目录由 Codex `:minimal` 定义，运行时自身目录只读挂载供 Linux 沙箱重新执行；Linux 的空白根文件系统可能允许创建临时影子文件，但不能修改或读取未批准的宿主文件。

启动健康检查使用独立短连接，单次最多两秒，超时关闭连接并重新探测，整体仍限三十秒，避免首个连接卡住整个启动。OpenCode 状态、缓存和临时目录隔离，开启 pure 模式；诊断只保留有限输出并移除鉴权值。

外部 MCP 工具均显示参数确认，不能仅依赖服务器的 `readOnlyHint` 绕过确认。上传先创建不可变快照，展示内容及摘要，确认后发送该快照。文章发布显示完整字段并在确认前后检查版本。注销、切换站点/账号和模型配置变更均使待执行操作与审批失效。恢复本地任务不会发送旧工具操作；若 OpenCode 的旧会话不存在，只用 `noReply` 存储历史文字上下文。

OpenAI Chat Completions、Responses、Anthropic Messages、Ollama 原生工具协议分别转换。明确拒绝 tools 的模型在尚未执行工具时回退到结构化模式；用户也可显式选择。结构化动作解析失败修复一次，再失败停止；文本不会被直接当作命令执行。网站聊天代理使用结构化模式。

## 最新原站契约

基于原站 `6f784dd` 新增的独立昵称契约，用户中心通过 `/api/user/profile` 保存昵称，后台改为 POST `/users/:id/nickname`。登录用户名、ID、主页和头像 URL、权限与隔离键保持固定；内容作者、公开主页、图库、留言和排行榜优先展示昵称。昵称验证遵循 32 个 Unicode 码点与控制字符限制。GPT-SoVITS 按端点选择传输，本机直连，公网通过需要登录的网站代理，完整传递参考音频、提示和权重路径；语音播放保持原站日语转换逻辑。

## 性能对比

证据：[优化前](qa/v0.6/room-before.json)、[优化后](qa/v0.6/room-after.json)。基准为同一 Apple M5 / 16GB / macOS、Flutter 3.47.5 Profile、1280×820，2,000 条相同双轮消息、200 个图片消息、240 次流式分片、滚动与真实 Cubism 同时运行，每版重复三次。基线源码为 `bc3704410809cdc49a7182161a58c009ce4cae31`，通过独立 Git archive 构建。

| 指标 | 优化前（三次） | 优化后（三次） |
| --- | --- | --- |
| 本地 Room 首帧可输入 | 214 / 224 / 231 ms | 82 / 52 / 52 ms |
| UI P95 | 90.920 / 91.039 / 90.793 ms | 10.361 / 10.168 / 10.308 ms |
| Raster P95 | 8.012 / 7.976 / 8.213 ms | 5.829 / 5.943 / 6.079 ms |
| 超出 16.7ms 的采样帧 | 242 / 242 / 242 | 1 / 1 / 1 |
| 隐藏页面模型更新 | 0 / 0 / 0 | 0 / 0 / 0 |
| 模型平均更新耗时 | 0.594 / 0.575 / 0.578 ms | 0.571 / 0.580 / 0.586 ms |
| 模型更新 CPU 时间 / 场景墙钟时间 | 1.258 / 1.212 / 1.222% | 3.424 / 3.481 / 3.517% |
| 采样 RSS | 383 / 432 / 383 MiB | 365 / 393 / 396 MiB |

UI P95 平均降低约 88.7%，Raster P95 降低约 26%。优化后保持约 60 次/秒模型更新；基线因 UI 阻塞完成相同负载需要约 25 秒、模型仅约 21 次/秒，因此优化后的模型 CPU 比例更高，不能把它误报成 CPU 降低。CPU 列只计算模型更新耗时，不含 Flutter 绘制或整个进程占用。

启动指标从测试内本地读取与挂载到可输入首帧计时，不包含安装、操作系统进程创建、真实密钥环或真实网络延迟。图片为固定 PNG fixture；流式模型是本地受控夹具，不衡量供应商响应速度。导航后 RSS 与采样值接近；三轮不能替代长时间压力测试。移动端 30fps 策略已实现，手机 GPU 的 33.3ms 预算仍需对应实机复测。

## 复验

```sh
python3 tool/agent/prepare_runtime.py --target macos
flutter test test/desktop_agent_test.dart --dart-define=RUN_AGENT_TESTS=true
flutter drive --profile -d macos --driver=test_driver/performance_driver.dart \
  --target=integration_test/room_performance_test.dart --dart-define=BENCHMARK_LABEL=after
```

完整后端、模型和截图复验使用新的临时 Express/SQLite fixture，方法同 [整站迁移记录](native-full-site-implementation-2026-09-30.md)，并加 `--dart-define=RUN_AGENT_TESTS=true`。发布流水线在 macOS、Windows、Linux 分别执行真实 OpenCode 与系统沙箱测试，再打包两个 Mac 架构及 Windows/Linux x64 的运行时。每个 bundle 含 `runtime-manifest.json` 和许可证；Release 整包另附 `SHA256SUMS.txt`。

最终本地完整回归通过 467 项，无失败、无跳过；包含当前原站 `6f784dd` 的临时后端、独立昵称与身份不可变校验、远程 GPT-SoVITS 代理、原生 Cubism、界面截图以及安装包内签名后的 OpenCode / Codex。Python 发布校验 35 项与运行时校验 3 项通过，静态分析无问题。退出请求等待 Agent 保存及关闭，启动失败释放运行时后可重新尝试；捆绑运行时路径在启动前解析为绝对真实路径。五平台构建与发布结果以流水线完成后的交付记录为准。

## 已知限制

- 无开发者签名/公证的 macOS、Windows 分发与需自行签名的 iOS IPA 延续既有方式。
- 手机与平板提供普通聊天，桌面 Agent 目前提供 Mac arm64/x64、Windows x64、Linux x64；ARM Windows/Linux 尚无发行包。
- 提权命令无法在当前普通用户沙箱执行；需要由用户在系统工具中自行处理。
- Windows 命令需要系统提供 MXC/PSEC；Windows Server 2022 等旧内核没有该能力，命令会关闭，文件工具、MCP 和站内 Agent 不受影响。CI 在该系统验证明确拒绝且无写入；支持 PSEC 的 Windows 实机命令及取消仍待设备验证。
- 外部真实供应商模型/TTS、QQ 实号授权、已签名 iPhone 及不同移动 GPU 需要对应账号和硬件。测试协议服务证明接口链路，不证明每个供应商模型的工具能力。
- Cubism 原生模型/Canvas 边界与 0.5 记录相同：支持网站的现有模型及语义动作，尚不支持任意 motion3 文件和 Cubism 5.3 的离屏扩展混合。
