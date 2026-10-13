# Swipick — App Store Connect 数据收集声明填写稿

依据 2026 年 10 月 13 日工作区中的 iOS 源码整理。提交前应以实际归档的 Release Build 为准，并复核此后新增的代码、SDK 和服务。

## 建议填写

**App Privacy → Data Collection：选 “No, we do not collect data from this app”（否，我们不会从此 App 中收集数据）。** 选“否”后无需逐项勾选数据类型。

理由：Swipick 在设备上读取并分析获准访问的系统照片，将审核决定和分析结果保存在本机。当前工程中未发现开发者服务器上传入口、广告 SDK、第三方分析 SDK、账户服务或跨 App 跟踪代码。Apple 在 App Privacy 中将“收集”定义为：数据离开设备，使开发者或其集成的第三方合作方能在完成实时请求所需时间之外继续访问。仅本机处理和本机存储不属于此处的“收集”。

选“否”**不表示 App 不读取个人内容**：它会请求照片权限，也可能在本机处理截图中的敏感文字。它也**不表示设备完全不联网**：PhotoKit 可能从用户自己的 iCloud 照片下载媒体；用户还可以通过 iOS 系统分享面板将所选项目发给自己选择的目标。就当前实现而言，这些路径不会把用户的图库副本交给 Swipick 开发者。

## 已核对的数据流

| 数据或操作 | 当前行为 | 声明判断 |
| --- | --- | --- |
| 照片和视频 | 获得完整或有限权限后，从系统图库读取；预览、播放、分享、转换及确认后的图库写入使用 PhotoKit。 | 用于 App 功能；当前实现未向开发者收集。 |
| 图像分析与截图 OCR | Vision 在本机运行。分类、图像特征、评分和资源哈希留在本地缓存；不保存完整 OCR 文本转录。 | 不收集。 |
| 审核决定与设置 | SwiftData、SQLite、本地文件和 UserDefaults 保存进度及偏好。 | 不收集。 |
| iCloud 照片 | 用户操作或可选的高清浏览设置可让 PhotoKit 请求 Apple 保存的预览或原片；建议扫描不下载 iCloud 原片。 | 属于 Apple 照片服务行为；当前实现不是开发者收集。 |
| 分享 | 用户选择的媒体通过 iOS 分享面板交给其自行选择的目标。 | 用户主动分享；如日后集成上传服务，需重新判断。 |
| 广告、分析、跟踪、账户 | 当前工程未发现相关集成。 | 暂不申报相应数据类型或跟踪。 |

## 隐私政策与上架前核对

1. 将中英文公开政策中的 **[开发者名称] / [DEVELOPER NAME]** 和 **[公开联系邮箱] / [PUBLIC SUPPORT EMAIL]** 换成实际上架主体及对外邮箱。
2. 将 `docs/privacy/PRIVACY_POLICY.en.md` 和中文版发布到稳定、无需登录即可访问的 HTTPS 地址。当前仓库的候选英文地址是 `https://github.com/Mars-Kinga/swipick/blob/main/docs/privacy/PRIVACY_POLICY.en.md`；**尚未发布，不能直接填入 App Store Connect**。发布并实际打开核对后，把 URL 填入 **App Privacy → Privacy Policy URL**，并在 App 内提供易找到的政策入口。
3. 核对最终归档文件及本次检查后新增的第三方 SDK、扩展或服务。如开发者或合作方能留存 App 传出的数据，先修改隐私政策及 App Store Connect 答案。
4. 后续如加入云端分析、崩溃上报、遥测、账户或订阅，重新评估声明。

## Apple 官方依据

- [App Privacy Details：何谓“收集”](https://developer.apple.com/app-store/app-privacy-details/)
- [App Store Connect：管理 App 隐私](https://developer.apple.com/cn/help/app-store-connect/manage-app-information/manage-app-privacy/)
- [App Review Guidelines 5.1.1：隐私政策要求](https://developer.apple.com/app-store/review/guidelines/)
