# 0.6.7 原生 LLM 与 Agent 协议

版本为 `0.6.7+13 / v0.6.7-beta.1`。本轮跟进网站的协议改造，保留现有 Room、模型配置、OpenCode、命令沙箱和整站原生页面。

协议基准为网站提交 [2f46fae](https://github.com/redchenk/tsukuyomi-space/commit/2f46fae)，并以当前网站 [87fbe74](https://github.com/redchenk/tsukuyomi-space/commit/87fbe74b28edcd3e2bda7939caf578fc49b1b6b5) 的真实 Express / SQLite 后端联调。参考 [AstrBot Provider / Agent 分层](https://github.com/astrbotdevs/astrbot/tree/a6265fa6c9471d499574c119edeba54a125db314/astrbot/core) 的统一响应、工具循环及调用配对思路，独立实现 Dart 适配器，没有复制 AstrBot 实现或安装 AstrBot 服务。

## 四类模型线路

| 线路 | 实时输出与完整响应 | 原生工具续接 |
| --- | --- | --- |
| Chat Completions 兼容 | SSE / JSON，参数分片、UTF-8、CRLF、finish 后的 usage | `tool_calls.id` → `tool_call_id`；当前任务内保留 `reasoning_content` |
| Responses | SSE / JSON，输出项、参数事件及 completed / incomplete / failed | `function_call.call_id` → `function_call_output.call_id`；保留必要的 encrypted reasoning，`store:false` |
| Anthropic Messages | SSE / JSON，初始文本、文本增量、独立 thinking / signature 与 usage | `tool_use.id` → `tool_result.tool_use_id`；失败或拒绝使用 `is_error:true` |
| Ollama `/api/chat` | NDJSON / JSON，保留 done 帧最后文字，累计各帧工具调用 | 参数对象与 `tool_name`；thinking 仅在当前工具循环内续接 |

协议由端点决定。OpenRouter 的 Claude / MiniMax 使用 Chat Completions；显式 `/messages` 使用 Anthropic 的鉴权和消息格式。原有通用 Base URL 保持 Chat Completions，显式 `/responses` 使用 Responses。没有新增原生 Gemini 协议。[Ollama 流式工具规则](https://docs.ollama.com/capabilities/tool-calling)要求累计正文、thinking 和工具调用；原生适配器按此处理。

`lib/core/model_protocol.dart` 提供共同的 `ModelCompletion`、`ModelCall`、流式事件、界限检查和原生调用 / 结果配对。Room、结构化兼容模式及桌面 Agent 使用同一解码器；旧 Chat Completions 辅助函数也转为委托共同解码器。

桌面桥接把四类原生流实时转为 OpenCode 接受的 Chat Completions 事件，必要的工具参数在完整校验后交给运行时。公开状态继续显示“连接模型 / 整理任务 / 准备工具 / 生成回复”，正文保留 32ms 合并刷新。模型私有推理、签名和 encrypted reasoning 不显示为任务说明，也不写入普通气泡、日记或长期记忆。私有状态只在当前任务桥接内存中保留，完成、停止和账号变更后清除。

工具参数发生 JSON 键顺序或空白变化时仍识别为同一操作；调用 ID 对应的名称 / 内容变化、调用缺失、结果错配或重复 ID 会停止续接。任务外的旧工具链不会重新提交；已有会话恢复继续由运行时恢复，并不调用工具重放历史。

## Room 工具循环

模型可自主调用固定的 `web_search` 和当前附件的 `understand_image`。搜索只接受最长 500 字的查询，图片工具只接受最长 2,000 字的问题；图片由应用取自当前附件，模型不能提供 URL 或文件路径。现有关键词搜索和图片预读保留兼容。

每轮普通聊天最多 3 次模型请求、2 轮工具续接、4 次实际执行，每次最多 6 个调用。工具串行执行，同名称 / 参数的成功及失败结果均复用。结果最多 4,000 字，中间上下文总计最多 512 KiB。模型调用的中间状态不会增加聊天记录数量；原站代理使用同样的 `tools` 和 `agentTurns` 请求字段，最终仍只保存一轮用户消息和可见回复。

未知工具、非法参数、未启用工具、空结果和 MCP 错误返回明确的失败结果，不声称操作成功。关闭原生工具的模型继续普通聊天；明确拒绝工具协议的桌面模型沿用结构化兼容路径。普通聊天不会自动开放 Shell、任意文件或站内写操作。

## 桌面权限与执行

固定运行时仍为 OpenCode 1.18.33 与 Codex 0.159.0，安装包内捆绑、校验并附许可证。文件、命令、MCP、文章草稿、上传和发布继续经过统一网关；越界和服务器写入需要具体内容审批，文件真实路径及符号链接、草稿版本检查、撤销和系统沙箱规则保留。

网关增加当前任务的调用账本。同一个调用 ID 的重复请求共用执行 Future 和结果，失败或拒绝也不会再次执行；同 ID 的不同内容会拒绝。取消检查位于复用结果之前，防止旧审批或缓存结果越过取消边界。模型桥接在当前任务中拒绝再次出现的模型调用 ID，避免运行时为它生成新 RPC ID 后再次执行；新任务使用独立 ID 空间。账本不跨任务持久化，恢复无重放仍由原有会话恢复机制保证。

每任务最多 20 次真实工具操作，命令默认 120 秒。模型请求默认 180 秒总预算、45 秒读取停滞预算、30 秒响应头预算；取消关闭请求客户端及命令子进程。401 / 429 / 5xx 不因协议格式错误自动重试，只有服务明确拒绝流式或工具格式时使用有界兼容路径。

普通 Room 可见回复最多 256 KiB，单个事件最多 1 MiB，参数 32 KiB；桌面继续保留大 SVG 的正文 8 MiB、参数 / 动作 2 MiB、JSON 16 MiB、传输 64 MiB 预算。UTF-8 分片、未结束的 SSE 行及 JSON 包在解析前检查大小。EOF、损坏 JSON、截断、长度耗尽和错误终止不会保存成成功回复。

## MCP 配置

- 默认 `REST 桥接` 兼容已有配置。站内 `/api/mcp/token-plan` 继续使用站点账号与 CSRF 信息，45 秒预算。
- `Streamable HTTP` 执行 initialize → initialized 通知 → 操作，支持 JSON / SSE、会话 ID 和 2025-11-25 / 2025-06-18 / 2025-03-26 协商；最后尽力 DELETE 关闭短会话。自定义操作默认 8 秒、最多 15 秒，包含握手和完整响应体读取。
- 原生应用访问远程 HTTPS 或本机 HTTP；不受浏览器 CORS 限制，但仍需系统允许网络访问。手机 localhost 指手机本身；MCP 的本机 HTTP 边界只开放回环地址。
- 外部 MCP 使用独立密钥，不能覆盖 Cookie、Origin、Host、MCP 会话头等保留头，不携带网站 Cookie，不跟随重定向。RPC ID、版本、`isError` 和错误响应均校验；不明结果不会自动重试工具。
- 每次用户操作独立初始化，不持久化会话凭据或轮询。没有声明 sampling / elicitation / OAuth 能力，也不支持旧 GET + SSE 传输。Fushi / AstrBot 专属事件和授权保持独立。

设置页的连接方式、说明和端点标签支持中文 / 日语 / 英语，390px 与 1280px 的选择、保存流程均验证。既有配置无须迁移；需要接入标准 MCP HTTP 服务时，在“工具与扩展”选择 Streamable HTTP。

## 验证

本地完整回归 **667 项通过、无跳过**，含原有 840 个整站布局场景；格式检查和静态分析无问题，发布及运行时工具 **40 项通过**。新增 **68 项**回归（模型 / Agent 协议 32、MCP 27、三语配置保存 6、当前网站真实代理联调 3）。[本地验证记录](qa/protocol-v0.6.7/local-validation.json)列出命令、来源及日志校验值。新增用例覆盖四类逐字节中文分片、实时回环桥接、原生工具 ID 配对、私有状态及用量尾帧、调用内容变更、重复执行、失败缓存、预算、取消、JSON / SSE MCP 握手、错误、鉴权隔离和完整响应体超时。

网站联调使用隔离临时数据库和模型传输夹具，运行真实网站代理、网站共同协议解码器、原生 Room 控制器及真实 HTTP MCP；检查工具续接后只保存一条可见完整对话。模型夹具只拦截固定测试模型，未使用用户在线模型密钥或访问生产数据。

本机使用真实固定 OpenCode / Codex，三桌面发布门禁各执行 109 项运行时及协议用例，覆盖四协议工具流程、DeepSeek 兼容的实时大 SVG、取消、审批、沙箱与恢复。三桌面运行时用例串行执行，避免多个原生进程争用 CI 资源。Windows 大 SVG 测试使用 10 秒首活动预算，收到文字后等待 11 秒，继续验证有正文时不会误回退；本地相关 3 项回归另重跑通过。接口层四协议均验证完成前输出文字；上述测试的模型端仍为可控 HTTP 夹具，不代表用户付费账号、指定模型质量或全部服务器实现已经验收。

五平台安装、签名、系统依赖及运行时许可见 [安装与配置](release-guide.md)。iOS 仍为自签 IPA；Windows 不支持 PSEC 的系统会拒绝命令，支持 PSEC 的实机执行仍待验收。没有新增模型服务、账号迁移或后台权限变化。
