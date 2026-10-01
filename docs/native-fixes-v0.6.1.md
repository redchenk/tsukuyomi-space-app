# 0.6.1 原生预览、滚动及 Agent 自动模式修复

版本 `0.6.1+7 / v0.6.1-beta.1`。上版发行源码 `2a1c269590c32cd9135803ea478a9f32ff84d5c6`，后端基线仍为原站 `6f784dd80093ab43c7d1140485411a77e82df366`。

## 文章预览

原站桌面默认 split，原生之前默认 write，且插入格式时总会强制回 write。现大于 760px 默认分栏，窄屏默认撰写并始终显示预览切换；格式操作保留分栏。预览按原站 180ms 合并刷新，切换视图立即同步，编辑字段通知不重建预览正文；预览不订阅阅读进度。草稿、选区和中文输入保持原生控制器。

## 滚动

此前阅读进度的 setState 会随滚动重建整篇 HTML 与嵌入组件。现使用独立阅读进度和当前标题订阅，正文保持稳定；滚动测量每帧最多一次，正文由 RepaintBoundary 隔离。图片及头像使用 ResizeImage fit 限制解码，既保留比例也不放大原图，点击查看原图使用原始图片源。

同一 Apple M5/16GB、Flutter 3.47.5 macOS Profile、1280×820，同一 60 节/600 段/20 代码块/20 表格/20 图片 fixture，上下滚动 180 步，各重复三次；启动和初次排版不计入采样。

| 指标 | 上版（三次） | 修复后（三次） |
| --- | --- | --- |
| UI P95 | 3.748 / 3.921 / 3.854 ms | 0.153 / 0.157 / 0.146 ms |
| Raster P95 | 1.180 / 1.181 / 1.188 ms | 0.407 / 0.409 / 0.383 ms |
| 超出 16.7ms 的采样帧 | 0 / 0 / 0 | 0 / 0 / 0 |

[原始优化前数据](qa/v0.6.1/article-before.json)、[优化后数据](qa/v0.6.1/article-after.json)。该受控场景说明正文重建成本降低，不证明报告者设备或所有页面已达到相同性能；手机及 Windows 实机仍需对应设备验证。

## Agent 自动兼容

之前仅凭错误正文的 tools unsupported 文本选择兼容模式，空响应的 400/422 无法识别。现从真实 OpenCode 错误及本地模型桥接保留 HTTP 状态：仅自动模式、原生运行时且没有任何已执行工具时切换结构化模式，最多一次。鉴权失败、限流及服务故障直接展示错误；已执行工具后绝不重试整个任务。网络及超时不再被桥接误报为 400。上游密钥不出现在诊断中。兼容模式仍严格校验动作、解析失败仅修复一次，并复用原网关审批。

真实进程回归覆盖明确拒绝 tools、空 400、空 422、401 不兼容重试以及已写文件后 400 不重放；模型桥接额外覆盖 400/401/429/500 的非空错误正文和原始状态。Moonshot/Kimi 参数与普通聊天一致。没有报告者的具体模型配置，因此此处验证的是错误类型和协议链路，真实供应商模型仍需对应账号验证。

## 验证与构建

完整本地回归 481 项，无失败、无跳过；定向回归 74 项；静态分析无问题。测试使用原站临时后端、原生 Cubism 和捆绑运行时，发布工具 37 项与运行时打包 3 项校验通过。所有实际平台打包及 CI 状态在 Release 完成后核验。

```sh
flutter test test/native_content_creation_test.dart test/native_article_rendering_test.dart test/desktop_agent_test.dart --dart-define=RUN_AGENT_TESTS=true
flutter drive --profile -d macos --driver=test_driver/article_performance_driver.dart --target=integration_test/article_scroll_performance_test.dart --dart-define=BENCHMARK_LABEL=after
```

捆绑运行时及 Windows PSEC、移动实机、第三方账号和发行签名的限制与 [0.6 验收记录](native-room-agent-v0.6.md) 相同。
