# Google Play release preparation

The Play-specific candidate is built from `codex/google-play-release` and is separate from the existing GitHub installer release. It is not evidence of Play approval or physical-device acceptance.

## Build

Run the **Google Play bundle** workflow on that branch. The workflow uses the existing Android distribution signing secrets; it exports only the public certificate and never uploads the keystore as an artifact.

```sh
flutter build appbundle --release \
  --target-platform android-arm64,android-x64 \
  --build-number=100031 \
  --dart-define=TSUKUYOMI_GOOGLE_PLAY=true
```

The compile-time flag disables initialization of the GitHub APK updater and selects a release manifest overlay that removes `REQUEST_INSTALL_PACKAGES`. Direct-download builds keep their existing manifest and updater. The build verifies the signed AAB, both supported ABIs, absence of the APK-install permission in the packaged manifest, exact site/game/Live2D assets and SHA-256.

The initial Play version code is `100031`, above the ABI-offset version codes of the existing `0.6.24+31` APKs. Every later Play upload must increase this code. Version codes alone do not establish cross-channel upgrade compatibility: the final Play app-signing certificate must also be compared with the direct-distribution certificate.

Artifacts include the AAB, public upload certificate, signature-verification output, build provenance and checksums. Creating this candidate does not choose or migrate the Play app-signing key, upload a private signing key to Google, publish a store version, or modify the existing GitHub release.

## Console state and remaining evidence

On 2026-10-21, the developer's personal-account dashboard requires a closed test with at least 12 opted-in testers for 14 continuous days before production access can be requested. The developer reported no tester list is currently available. This gate cannot be skipped by preparing a package or adding internal testers.

The operator confirmed the support email `redchenk919@gmail.com`, website `https://yachiyo.hk`, Entertainment category and intended target age groups 13–15, 16–17 and 18+. The sign-in details and all three age groups were saved and verified in Console. Reviewer credentials belong only in Play Console; never add their password or model API keys to this repository, screenshots, artifacts, logs or release notes.

Before requesting external review, verify and complete:

- A working ordinary reviewer account, with any separately required review model/TTS service access, and English instructions.
- An app-specific published privacy notice covering native local storage, account/cloud data, user-selected model/TTS providers, uploads and optional location use.
- A clear account-and-associated-data deletion request path inside the app and at an accessible web URL. The existing Reality page only describes a general request channel; the operator delegated the handling plan: requests to the support email, identity verification, completion within 30 days. Deployment verification and historical-backup handling remain open.
- In-app AI-content reporting and UGC/user reporting and blocking. The inspection did not locate these capabilities in the native Room/community UI; a generic public feedback post must not be treated as a verified private reporting flow.
- A Data safety declaration derived from actual collection and sharing. Do not declare that the app collects no data: it supports accounts, private cloud chat/memory, content uploads, community interactions and optional location requests.
- Android-device acceptance. Two 864 × 1536 representative captures were saved to the store draft from the actual Flutter UI in a temporary macOS mobile-size preview, with no personal account or fabricated chat. Only the title bar was cropped; these are not Android-device captures.
- Content rating questionnaire, supported countries/regions, final signing-key decision, tester eligibility and Google review results.

Useful primary references:

- [Personal-account testing requirements](https://support.google.com/googleplay/android-developer/answer/14151465)
- [APK-install permission](https://support.google.com/googleplay/android-developer/answer/12085295)
- [Account deletion](https://support.google.com/googleplay/android-developer/answer/13327111)
- [AI-generated content](https://support.google.com/googleplay/android-developer/answer/13985936)
- [User-generated content](https://support.google.com/googleplay/android-developer/answer/9876937)

## Verified candidate and saved store draft

[Workflow run 39533744201](https://github.com/redchenk/tsukuyomi-space-app/actions/runs/39533744201) succeeded at `e8b58b79a1cc00f91a981cbf6a6e972838c41420`. The downloaded artifact archive matched the GitHub SHA-256 digest. The extracted AAB and public certificate matched their bundled checksums. AAB SHA-256: `505a29e77b7590ac3a86c3f0a99db968c8cdf6e1319c3ea4714e21f1ba423215`; size 174,475,237 bytes; version code 100031. CI verified signature, packaged assets, absence of APK-install permission and absence of 32-bit ABI libraries.

The Simplified Chinese title, short/full descriptions, 512 × 512 existing app icon, 1024 × 500 feature graphic, and two 9:16 phone screenshots were saved as a Play Console draft. This does not submit the listing for Google review. Local publication materials and sanitized Console status are under ignored `artifacts/google-play/`; no reviewer password is stored there.


## 2026-10-22 隐私政策与账号注销

- 隐私政策 URL：`https://yachiyo.hk/privacy`（公开 HTML；App 随包提供中英文正文，可离线阅读）。
- 账号删除 URL：`https://yachiyo.hk/delete-account`（卸载后仍可用，登录提交或通过绑定邮箱申请）。
- App 入口：用户中心 → 账户安全 → 申请注销账号；登录/注册页、现实连接也可阅读政策。
- 注销采用站长核验后人工处理，通常收到申请起 30 日内完成。申请有编号、状态、待核验阶段的撤回功能；并不立即删除账号或处理资金。无登录的邮箱申请同样有效。
- 后台工作台只有超级管理员可访问；完成登记要求账号已删除、清理清单逐项完成及处理回执。运行与清理规范见网站 `docs/privacy/account-deletion-runbook.md`。
- 政策单一编辑源为网站 `shared/privacy-policy.json`。更新后执行 `node tool/sync_privacy_policy.mjs <网站仓库路径>`，再执行 `dart format lib/core/privacy_policy.dart`。需同时发布网站与 App 的政策版本。
- Google Play 候选构建号从 100032 起；候选包不等于上架、真机验收或完成 Data safety/UGC/封闭测试要求。Console 中的政策 URL、删除 URL 和数据安全声明需按当前实测状态保存。

## 2026-10-24 封闭测试候选包

下一候选构建号为 100033，版本基于 0.6.31。旧包 100032 被定位插件附带的 `FOREGROUND_SERVICE_LOCATION` 权限触发了前台服务声明要求。Room 仅在用户主动请求时调用一次 `getCurrentPosition`，没有定位流或后台定位功能；Play manifest 因此移除该权限和可选服务的前台服务类型，同时保留插件绑定服务及前台单次定位能力。CI 检查最终 AAB 中没有该权限、前台服务类型及 APK 安装权限。
