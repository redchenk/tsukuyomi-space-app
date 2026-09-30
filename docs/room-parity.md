# Room / Room settings 功能对照

基准：原网站 `src/frontend/pages/RoomPage.vue`、`RoomSettingsPage.vue` 及对应 composables/services（2026-09-28 本地版本）。原生实现位于 `lib/features/room`、`lib/features/settings`、`lib/core/room_*`。

以下功能已接入原生实现。验证包括 129 项自动化测试、2 项隔离网站后端集成测试及桌面/手机截图对照；真实供应商付费账号、已签名 iPhone 安装和各厂商设备仍需用户验收。

- 聊天：流式回复、停止、失败重试、主动开场、新建与清空、查看开头、改写与重新生成、图片压缩/上传/历史、段落展示、朗读、分享卡/链接/撤销。
- 上下文：固定聊天角色、用户补充指令、时间/环境、长期记忆开关与检索、知识库开关与排序、角色原作检索、成长/站点动态、MCP 搜索与图片理解。
- 日记：结束会话生成、失败保留录制、选择作者人设、阅读/删除、导入/导出/清空、账号同步、删除墓碑、版本冲突恢复。
- 房间：资料昵称/签名、便签、音乐列表/前后曲/进度/音量、环境刷新/定位、安静陪伴、桌面工作区和手机工具菜单。
- 设置：8 分区及搜索、未保存提示、保存全部/放弃/进入房间；LLM 服务预设和模型目录、协议/代理/测试；所有网站 TTS 提供商、GPT-SoVITS 权重与参考音频；记忆管理/向量同步、知识 CRUD/恢复默认、角色尺寸位置/重置、日记人设与存档、MCP 预设/鉴权/白名单/工具列表、Live2D 表情动作队列与 JSON 状态。
- 恢复与验证：配置迁移、密钥安全存储、账号切换隔离、401/断网保留、跨设备修改、取消后不提交半条回复；桌面与手机截图对照、协议与状态测试、原生构建。


验证证据与限制见根目录 `design-qa.md`。运行后端联调：先 `node tool/testing/site_room_fixture.cjs ../tsukuyomi-space`，再 `flutter test test/room_backend_parity_test.dart test/site_backend_integration_test.dart --concurrency=1 --dart-define=RUN_WEBSITE_INTEGRATION=true`。该进程使用临时数据和内存对象存储，不接触线上用户数据。
