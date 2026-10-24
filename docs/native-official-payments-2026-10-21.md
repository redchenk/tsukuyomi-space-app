# 站内直供与原生支付中心

本次功能已发布为 [0.6.25+32 / v0.6.25-beta.1](https://github.com/redchenk/tsukuyomi-space-app/releases/tag/v0.6.25-beta.1)；配套主站移动支付修改仍在开发目录，尚未部署。网站 API 契约以 2026-10-21 的主站及独立直供服务源码为准。

## 用户入口与功能

个人中心、分组菜单的「支付中心」均打开原生 `/payments`。Room 设置新增「站内直供」，登录后刷新可用模型并保存，无需供应商 Key；同页可前往余额、充值和订单。

支付中心包含网站统一余额、冻结金额、充值与普通商品、订单列表及分页、付款结果核对、直供模型价格、最近用量及分页、单次请求详情和 UTC 月账单。直供服务故障不阻断主站余额和订单。金额始终用十亿分之一元的整数或 BigInt 运算，显示保留最多 9 位小数。

维护者使用独立服务返回的 `me.operator` 权限，维护供应商、模型、三类售价、输入输出上限、并发和频率限制、服务开关、供应商密钥及待核对请求。凭据只写不读，人工结算或释放必须提交可追溯凭据编号。Terminal 中的「支付与订单」仅对已核实的超级管理员开放，包含商品价格、上架、充值标记和全站订单查单。

| API | 原生用途 |
| --- | --- |
| `/api/payments/catalog`、`wallet` | 商品、支付渠道状态、统一余额 |
| `/api/payments/orders`、`:id`、`:id/checkout`、`:id/refresh` | 下单、订单、支付和服务端核对 |
| `/api/admin/payments/settings`、`orders`、`orders/:id/refresh` | 主站支付管理 |
| `/official-api/api/dashboard` | 核实站点用户、直供账号和模型 |
| `/official-api/v1/chat/completions` | 文字、支持视觉的模型的图片输入、流式回复、工具调用、日记及结构化 Agent |
| `/official-api/api/usage`、`requests/:id` | 用量分页与请求详情 |
| `/official-api/api/statements/monthly` | UTC 自然月账单 |
| `/official-api/api/admin/settings` | 维护者服务配置 |
| `/official-api/api/admin/reconciliation`、`reconcile` | 待核对请求及凭据结算/释放 |

直供聊天只向当前站点的固定路径发送网站 Cookie。先读取最新 dashboard 核对 `site_user_id`，请求携带 `X-Official-Expected-Account`，不发送外部供应商 Key。输出 Token 受当前服务模型上限限制，DeepSeek 沿用网站关闭思考模式的行为。2026-10-24 同步网站图片能力：仅当服务端模型声明 `capabilities.vision === true` 时直接发送图片；其余模型可使用用户配置的 MCP 识图。设置和支付中心显示「文字与图片」能力，图片与文字按实际 Token 用量统一计费。每次发送重新读取模型能力，覆盖旧版缓存的文字限定；不支持图片或账号不匹配时不发送聊天请求，并保留图片草稿。收费请求不进行兼容性自动重发；401 提示重新登录，402 指向支付中心。更换账号、站点或会话后丢弃旧余额、订单、用量及未完成响应。

## 移动端付款

Android 优先使用 App 支付：服务端为新订单固定 `app` 渠道，使用移动应用的独立 AppID、商户 PID 和密钥生成 `alipay.trade.app.pay` 订单字符串。Flutter 通过官方 SDK 的 Tobias 封装唤起支付宝。在服务端仅支持 WAP 时，移动端使用签名的 `alipay.trade.wap.pay` 链接，先唤起支付宝，未安装时打开 HTTPS 收银台。桌面继续使用电脑网站支付。

客户端只接受固定支付宝 HTTPS 网关，或与当前订单号、金额、AppID、RSA2 和支付产品一致的 App 订单。支付宝 SDK 的 `9000`、处理中、未知结果和回跳参数都不能直接增加余额。返回应用、SDK 结束及手动核对都使用服务端查单；活动页面最多自动核对 6 次，每次间隔 10 秒。下单使用幂等请求编号，网络失败保留编号，返回应用和查询不创建新订单。

跨渠道订单不更换 AppID。网页与 App 共用主站订单、通知验签及钱包幂等入账，历史网页订单在迁移后仍属于 `web` 渠道。服务端配套修改见主站 `docs/payments.md` 的移动支付说明和迁移 `047_payment_app_channel`。

## 验证与边界

2026-10-24 图片同步已通过 161 项相关回归测试、静态检查和 320/390/1280 宽度界面检查。使用离线账号和合成图片验证压缩、认证、流式回复、图片上传与历史保存；未调用生产计费模型，也未做手机实机验收。本次图片功能从 0.6.31 起提供，0.6.30 安装包不包含这些改动。详见[验证记录](qa/native-official-images-20261024/validation.json)和[390px 设置截图（模拟模型）](qa/native-official-images-20261024/settings-390.png)。

- `flutter analyze --no-pub`；核心传输、精确金额、账号切换、回调不直接入账、SDK 调起与 WAP 回退测试。
- 手机 390px、桌面 1280px 的原生页面测试；直供离线时仍显示主站余额和订单。
- macOS 调试应用构建，以及 iOS 未签名设备构建。iOS 暂走 WAP；当前支付宝控制台的移动应用仅登记 Android。iOS 的应用支付还需要在开放平台登记对应平台并配置 Universal Link。
- 主站支付测试使用临时数据库、临时 RSA 密钥和模拟 SDK 传输，验证渠道隔离、真实 RSA2 签名、伪造通知、幂等到账和历史订单；没有生产资金操作。
- `tool/preview_payments.dart` 是标有「离线界面验收」的模拟数据预览，不能用于实际付款。

2026-10-21 检查 Chrome：移动应用「月读空间APP」已上线，Android 包名与发行签名正确，接口加签已设置；其「可调用产品」当前只显示电脑网站支付，未看到 App 支付。需要为该应用开通 App 支付，并将对应私钥及支付宝公钥安全配置到主站服务器，才能开启 `ALIPAY_APP_PAY_ENABLED`。本次没有开启生产支付渠道、修改现有商品或做真实付款。

Android 发行包已通过 CI 构建、签名与原生探针检查；全部 16 个公开附件已下载校验，详见[发行验证记录](qa/native-official-payments-20261021/README.md)。手机上真实拉起、安装及到账仍需 App 支付开通后在实际设备验收。
