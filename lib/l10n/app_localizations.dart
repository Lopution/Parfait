import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_ja.dart';
import 'app_localizations_ru.dart';
import 'app_localizations_zh.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations)!;
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('ja'),
    Locale('ru'),
    Locale('zh'),
  ];

  /// No description provided for @networkDohEndpointsInvalid.
  ///
  /// In zh, this message translates to:
  /// **'DoH 地址列表无效'**
  String get networkDohEndpointsInvalid;

  /// No description provided for @welcome1.
  ///
  /// In zh, this message translates to:
  /// **'感谢使用 Parfait'**
  String get welcome1;

  /// No description provided for @welcome2.
  ///
  /// In zh, this message translates to:
  /// **'下面将进行首次启动设置'**
  String get welcome2;

  /// No description provided for @start.
  ///
  /// In zh, this message translates to:
  /// **'开始'**
  String get start;

  /// No description provided for @selectLanguage.
  ///
  /// In zh, this message translates to:
  /// **'选择您的语言'**
  String get selectLanguage;

  /// No description provided for @next.
  ///
  /// In zh, this message translates to:
  /// **'下一步'**
  String get next;

  /// No description provided for @dark.
  ///
  /// In zh, this message translates to:
  /// **'深色'**
  String get dark;

  /// No description provided for @light.
  ///
  /// In zh, this message translates to:
  /// **'浅色'**
  String get light;

  /// No description provided for @system.
  ///
  /// In zh, this message translates to:
  /// **'跟随系统'**
  String get system;

  /// No description provided for @loginTitle.
  ///
  /// In zh, this message translates to:
  /// **'注册 或 登录'**
  String get loginTitle;

  /// No description provided for @loginProxyNoticeTitle.
  ///
  /// In zh, this message translates to:
  /// **'提示'**
  String get loginProxyNoticeTitle;

  /// No description provided for @loginProxyNoticeBody.
  ///
  /// In zh, this message translates to:
  /// **'由于网络环境限制，登录和注册需要你先在系统或其他应用中开启代理（梯子）。Parfait 不提供内置代理。'**
  String get loginProxyNoticeBody;

  /// No description provided for @loginProxyNoticeCancel.
  ///
  /// In zh, this message translates to:
  /// **'取消'**
  String get loginProxyNoticeCancel;

  /// No description provided for @loginProxyNoticeContinue.
  ///
  /// In zh, this message translates to:
  /// **'我已开启代理'**
  String get loginProxyNoticeContinue;

  /// No description provided for @register.
  ///
  /// In zh, this message translates to:
  /// **'注册'**
  String get register;

  /// No description provided for @login.
  ///
  /// In zh, this message translates to:
  /// **'登录'**
  String get login;

  /// No description provided for @loginPageClosed.
  ///
  /// In zh, this message translates to:
  /// **'页面已关闭，请重新打开'**
  String get loginPageClosed;

  /// No description provided for @loginCallbackInvalid.
  ///
  /// In zh, this message translates to:
  /// **'登录回调无效，请重新登录'**
  String get loginCallbackInvalid;

  /// No description provided for @loginNetworkError.
  ///
  /// In zh, this message translates to:
  /// **'网络错误 (HTTP {status})'**
  String loginNetworkError(String status);

  /// No description provided for @loginPageLoadFailed.
  ///
  /// In zh, this message translates to:
  /// **'页面加载失败'**
  String get loginPageLoadFailed;

  /// No description provided for @loginWebView2Missing.
  ///
  /// In zh, this message translates to:
  /// **'登录需要 WebView2 Runtime，但当前系统未检测到它。请安装后重新打开本页。'**
  String get loginWebView2Missing;

  /// No description provided for @loginInstallWebView2.
  ///
  /// In zh, this message translates to:
  /// **'安装 WebView2 Runtime'**
  String get loginInstallWebView2;

  /// No description provided for @loginReload.
  ///
  /// In zh, this message translates to:
  /// **'重新加载'**
  String get loginReload;

  /// No description provided for @loginRestart.
  ///
  /// In zh, this message translates to:
  /// **'重新登录'**
  String get loginRestart;

  /// No description provided for @loginFailed.
  ///
  /// In zh, this message translates to:
  /// **'登录失败'**
  String get loginFailed;

  /// No description provided for @networkCompatibility.
  ///
  /// In zh, this message translates to:
  /// **'Pixiv 官方网络兼容'**
  String get networkCompatibility;

  /// No description provided for @networkCompatibilityHint.
  ///
  /// In zh, this message translates to:
  /// **'开启时，访问 Pixiv 官方域名会在加密 DNS、ECH、无 SNI 等兼容连接与直连之间选择能用的一种，并记住成功的方式。最后一档兼容连接不校验证书；关闭此开关即只走直连。不会代理其他流量。'**
  String get networkCompatibilityHint;

  /// No description provided for @useLoginWithClipboard.
  ///
  /// In zh, this message translates to:
  /// **'使用剪贴板数据登录'**
  String get useLoginWithClipboard;

  /// No description provided for @accountTransferExportTitle.
  ///
  /// In zh, this message translates to:
  /// **'导出账号凭据'**
  String get accountTransferExportTitle;

  /// No description provided for @accountTransferWarning.
  ///
  /// In zh, this message translates to:
  /// **'剪贴板内容会短时存在，可能被其他应用读取；此格式不提供加密或发送者认证。'**
  String get accountTransferWarning;

  /// No description provided for @loginClipboardHint.
  ///
  /// In zh, this message translates to:
  /// **'先在已登录的设备上打开「我的 → 账号管理 → 导出账号凭据」复制，再回到这里导入。'**
  String get loginClipboardHint;

  /// No description provided for @accountTransferSensitiveWarning.
  ///
  /// In zh, this message translates to:
  /// **'此设备不支持敏感剪贴板标记（Android 13+ 才支持）：凭据将以明文进入系统剪贴板，请尽快粘贴；5 分钟后自动清除。'**
  String get accountTransferSensitiveWarning;

  /// No description provided for @accountTransferCopied.
  ///
  /// In zh, this message translates to:
  /// **'账号迁移数据已复制，请尽快在目标设备粘贴。'**
  String get accountTransferCopied;

  /// No description provided for @accountTransferImported.
  ///
  /// In zh, this message translates to:
  /// **'账号迁移成功'**
  String get accountTransferImported;

  /// No description provided for @accountTransferClipboardReplaced.
  ///
  /// In zh, this message translates to:
  /// **'账号已导入；剪贴板已被其他内容替换，未执行清除。'**
  String get accountTransferClipboardReplaced;

  /// No description provided for @accountTransferCorrupt.
  ///
  /// In zh, this message translates to:
  /// **'剪贴板账号数据损坏或格式不受支持'**
  String get accountTransferCorrupt;

  /// No description provided for @accountTransferCredentialInvalid.
  ///
  /// In zh, this message translates to:
  /// **'账号凭据无效，请重新登录或重新复制'**
  String get accountTransferCredentialInvalid;

  /// No description provided for @accountTransferVerificationUnavailable.
  ///
  /// In zh, this message translates to:
  /// **'暂时无法向 Pixiv 验证账号凭据'**
  String get accountTransferVerificationUnavailable;

  /// No description provided for @accountTransferNoAccount.
  ///
  /// In zh, this message translates to:
  /// **'当前没有可复制的已登录账号'**
  String get accountTransferNoAccount;

  /// No description provided for @accountTransferCredentialUnavailable.
  ///
  /// In zh, this message translates to:
  /// **'当前账号凭据不可用，请重新登录'**
  String get accountTransferCredentialUnavailable;

  /// No description provided for @accountTransferClipboardUnavailable.
  ///
  /// In zh, this message translates to:
  /// **'剪贴板当前不可用'**
  String get accountTransferClipboardUnavailable;

  /// No description provided for @accountTransferStorageFailure.
  ///
  /// In zh, this message translates to:
  /// **'账号迁移记录无法安全保存'**
  String get accountTransferStorageFailure;

  /// No description provided for @loginAgree.
  ///
  /// In zh, this message translates to:
  /// **'登录即表示你同意'**
  String get loginAgree;

  /// No description provided for @userAgreement.
  ///
  /// In zh, this message translates to:
  /// **'《Parfait 用户使用协议》'**
  String get userAgreement;

  /// No description provided for @agreementTitle.
  ///
  /// In zh, this message translates to:
  /// **'Parfait 用户使用协议'**
  String get agreementTitle;

  /// No description provided for @agreementIntro.
  ///
  /// In zh, this message translates to:
  /// **'感谢使用 Parfait。使用本应用即表示你已阅读并同意以下条款；如不同意，请停止使用本应用。'**
  String get agreementIntro;

  /// No description provided for @agreementServiceTitle.
  ///
  /// In zh, this message translates to:
  /// **'服务说明'**
  String get agreementServiceTitle;

  /// No description provided for @agreementServiceBody.
  ///
  /// In zh, this message translates to:
  /// **'Parfait 是开源的非官方 Pixiv 第三方客户端，与 Pixiv Inc. 没有隶属关系，源代码以 AGPL-3.0 许可证公开。\n\n本应用不提供内容，所有作品与资料都来自 Pixiv。'**
  String get agreementServiceBody;

  /// No description provided for @agreementAccountTitle.
  ///
  /// In zh, this message translates to:
  /// **'账号与登录'**
  String get agreementAccountTitle;

  /// No description provided for @agreementAccountBody.
  ///
  /// In zh, this message translates to:
  /// **'注册和登录在应用内打开的 Pixiv 官方网页中完成；本应用不读取、也不保存你的密码。登录后得到的凭据保存在系统安全存储中。\n\n「导出账号凭据」会把凭据以明文放进系统剪贴板：Android 13 及以上会标记为敏感内容，5 分钟后自动清除。请只在自己的设备之间使用。\n\n使用第三方客户端是否符合 Pixiv 的规则由你自行判断，账号因此受到的限制由你自行承担。'**
  String get agreementAccountBody;

  /// No description provided for @agreementUsageTitle.
  ///
  /// In zh, this message translates to:
  /// **'使用规范'**
  String get agreementUsageTitle;

  /// No description provided for @agreementUsageBody.
  ///
  /// In zh, this message translates to:
  /// **'请遵守所在地法律和 Pixiv 的使用条款。不得把本应用用于批量抓取、自动刷量、骚扰他人，或其他会损害 Pixiv 与创作者权益的用途。\n\n限制级内容按你的 Pixiv 账号设置显示；未成年人不得浏览限制级内容。'**
  String get agreementUsageBody;

  /// No description provided for @agreementContentTitle.
  ///
  /// In zh, this message translates to:
  /// **'内容与版权'**
  String get agreementContentTitle;

  /// No description provided for @agreementContentBody.
  ///
  /// In zh, this message translates to:
  /// **'作品、评论、用户资料等内容的版权归相应权利人所有。下载仅供个人保存；转载或再分发须取得权利人许可。'**
  String get agreementContentBody;

  /// No description provided for @agreementNetworkTitle.
  ///
  /// In zh, this message translates to:
  /// **'网络访问'**
  String get agreementNetworkTitle;

  /// No description provided for @agreementNetworkBody.
  ///
  /// In zh, this message translates to:
  /// **'在默认的「自动」网络模式下，访问 Pixiv 官方域名（API、登录、网页、图片）时，本应用会在以下连接方式中选择能用的一种，并记住成功的方式，之后优先使用：\n• 经 Cloudflare 的 ECH 加密握手连接；\n• 通过加密 DNS（默认 Cloudflare、Google）解析地址后连接，获取 ECH 配置时查询阿里云 DNS；\n• 不带 SNI 连接 Pixiv 图片服务器；\n• 系统直连。\n以上方式都会校验证书。\n\n都失败时，最后一档会使用内置或上次可用的 Pixiv 地址、不带 SNI 连接，并且不校验证书；这一档成功后同样会被记住。如果网络中有人冒充 Pixiv 服务器，你的登录凭据和浏览内容可能被截获。如不接受，请在「设置 → 网络 → 网络模式」选择「仅直连」，这会关闭以上所有兼容连接。\n\n图片源默认为「自动」：在官方图片服务器与第三方镜像（i.pixiv.re、i.pixiv.nl、i.pixiv.cat）之间测速，使用最快的一个。经由镜像时，镜像运营方能看到你请求的图片地址和你的 IP 地址。可在「设置 → 浏览设置 → 图片源」固定为官方源。\n\n本应用不代理其他流量；网络可用性、接口变更与服务中断不由本应用保证。'**
  String get agreementNetworkBody;

  /// No description provided for @agreementThirdPartyTitle.
  ///
  /// In zh, this message translates to:
  /// **'第三方服务'**
  String get agreementThirdPartyTitle;

  /// No description provided for @agreementThirdPartyBody.
  ///
  /// In zh, this message translates to:
  /// **'以下服务只在你使用相应功能时访问：\n• 评论翻译（默认关闭）：把评论原文发送给你选择的 Google 翻译、百度翻译，或你填写的 OpenAI 兼容接口；\n• 以图搜图：把你选择的图片上传到 SauceNAO 或 iqdb。\n\n登录网页由 Pixiv 提供，可能加载 Pixiv 使用的第三方资源（例如人机验证）。\n\n检查更新：本应用每 24 小时最多自动访问一次 GitHub 上的版本清单；F-Droid 版本不检查更新。'**
  String get agreementThirdPartyBody;

  /// No description provided for @agreementPrivacyTitle.
  ///
  /// In zh, this message translates to:
  /// **'隐私与本地数据'**
  String get agreementPrivacyTitle;

  /// No description provided for @agreementPrivacyBody.
  ///
  /// In zh, this message translates to:
  /// **'设置、缓存、浏览历史、稍后再看与下载文件都保存在本机。本应用没有统计、广告或崩溃上报，不会把你的数据发送到开发者的服务器。\n\n崩溃日志只保存在本机，由你决定是否通过「我的 → 关于 → 导出日志」分享。\n\n卸载应用或清除数据会删除这些内容（保存到公共目录的下载文件除外）。'**
  String get agreementPrivacyBody;

  /// No description provided for @agreementDisclaimerTitle.
  ///
  /// In zh, this message translates to:
  /// **'免责声明'**
  String get agreementDisclaimerTitle;

  /// No description provided for @agreementDisclaimerBody.
  ///
  /// In zh, this message translates to:
  /// **'本应用按现状提供，不保证没有错误或持续可用。因网络、账号、第三方服务或不可抗力造成的内容丢失、访问失败或其他损失，作者在法律允许范围内不承担责任。'**
  String get agreementDisclaimerBody;

  /// No description provided for @agreementUpdatesTitle.
  ///
  /// In zh, this message translates to:
  /// **'协议更新'**
  String get agreementUpdatesTitle;

  /// No description provided for @agreementUpdates.
  ///
  /// In zh, this message translates to:
  /// **'协议可能随功能或法律变化而更新；更新后继续使用即表示接受更新后的协议。'**
  String get agreementUpdates;

  /// No description provided for @settingsTitle.
  ///
  /// In zh, this message translates to:
  /// **'设置'**
  String get settingsTitle;

  /// No description provided for @settingsSearchHint.
  ///
  /// In zh, this message translates to:
  /// **'搜索设置'**
  String get settingsSearchHint;

  /// No description provided for @settingsSearchEmpty.
  ///
  /// In zh, this message translates to:
  /// **'没有匹配的设置'**
  String get settingsSearchEmpty;

  /// No description provided for @settingsGroupAppearance.
  ///
  /// In zh, this message translates to:
  /// **'外观'**
  String get settingsGroupAppearance;

  /// No description provided for @settingsGroupNetwork.
  ///
  /// In zh, this message translates to:
  /// **'网络与下载'**
  String get settingsGroupNetwork;

  /// No description provided for @settingsGroupBrowse.
  ///
  /// In zh, this message translates to:
  /// **'浏览'**
  String get settingsGroupBrowse;

  /// No description provided for @settingsGroupLibrary.
  ///
  /// In zh, this message translates to:
  /// **'我的内容'**
  String get settingsGroupLibrary;

  /// No description provided for @settingsGroupDeveloper.
  ///
  /// In zh, this message translates to:
  /// **'开发者'**
  String get settingsGroupDeveloper;

  /// No description provided for @developerOptionsUnlocked.
  ///
  /// In zh, this message translates to:
  /// **'开发者选项已开启'**
  String get developerOptionsUnlocked;

  /// No description provided for @developerOptionsCountdown.
  ///
  /// In zh, this message translates to:
  /// **'再点 {count} 次开启开发者选项'**
  String developerOptionsCountdown(int count);

  /// No description provided for @settingsGroupData.
  ///
  /// In zh, this message translates to:
  /// **'数据'**
  String get settingsGroupData;

  /// No description provided for @accountSettings.
  ///
  /// In zh, this message translates to:
  /// **'账号'**
  String get accountSettings;

  /// No description provided for @networkSettings.
  ///
  /// In zh, this message translates to:
  /// **'网络'**
  String get networkSettings;

  /// No description provided for @networkMode.
  ///
  /// In zh, this message translates to:
  /// **'Pixiv 官方网络兼容'**
  String get networkMode;

  /// No description provided for @networkModeHint.
  ///
  /// In zh, this message translates to:
  /// **'打不开时自动尝试兼容通道；只作用于 Pixiv 官方域名，不会代理其他流量。'**
  String get networkModeHint;

  /// No description provided for @networkModeListTitle.
  ///
  /// In zh, this message translates to:
  /// **'网络模式'**
  String get networkModeListTitle;

  /// No description provided for @networkModeAutomatic.
  ///
  /// In zh, this message translates to:
  /// **'自动'**
  String get networkModeAutomatic;

  /// No description provided for @networkModeAutomaticHint.
  ///
  /// In zh, this message translates to:
  /// **'自动选择能用的连接方式。'**
  String get networkModeAutomaticHint;

  /// No description provided for @networkModeDirectOnly.
  ///
  /// In zh, this message translates to:
  /// **'仅直连'**
  String get networkModeDirectOnly;

  /// No description provided for @networkModeDirectOnlyHint.
  ///
  /// In zh, this message translates to:
  /// **'只走系统直连；适合直连可用的网络。'**
  String get networkModeDirectOnlyHint;

  /// No description provided for @networkModeCompatPrefer.
  ///
  /// In zh, this message translates to:
  /// **'兼容优先'**
  String get networkModeCompatPrefer;

  /// No description provided for @networkModeCompatPreferHint.
  ///
  /// In zh, this message translates to:
  /// **'优先尝试兼容通道，不行再直连；适合直连已被阻断的网络。'**
  String get networkModeCompatPreferHint;

  /// No description provided for @networkEffectiveRoutes.
  ///
  /// In zh, this message translates to:
  /// **'当前生效路由'**
  String get networkEffectiveRoutes;

  /// No description provided for @networkEffectiveRoutesEmpty.
  ///
  /// In zh, this message translates to:
  /// **'还没有路由记录——逛一逛再刷新。'**
  String get networkEffectiveRoutesEmpty;

  /// No description provided for @networkRouteForImages.
  ///
  /// In zh, this message translates to:
  /// **'图片加载'**
  String get networkRouteForImages;

  /// No description provided for @networkRouteKindDirect.
  ///
  /// In zh, this message translates to:
  /// **'直连'**
  String get networkRouteKindDirect;

  /// No description provided for @networkRouteKindCompat.
  ///
  /// In zh, this message translates to:
  /// **'兼容通道'**
  String get networkRouteKindCompat;

  /// No description provided for @networkThirdParty.
  ///
  /// In zh, this message translates to:
  /// **'第三方服务可达性'**
  String get networkThirdParty;

  /// No description provided for @networkThirdPartyAuto.
  ///
  /// In zh, this message translates to:
  /// **'进入本页时自动检测一次。'**
  String get networkThirdPartyAuto;

  /// No description provided for @networkThirdPartyHint.
  ///
  /// In zh, this message translates to:
  /// **'走系统网络，你的 VPN/代理会照常生效。'**
  String get networkThirdPartyHint;

  /// No description provided for @networkReachable.
  ///
  /// In zh, this message translates to:
  /// **'可达'**
  String get networkReachable;

  /// No description provided for @networkUnreachable.
  ///
  /// In zh, this message translates to:
  /// **'不可达'**
  String get networkUnreachable;

  /// No description provided for @networkChecking.
  ///
  /// In zh, this message translates to:
  /// **'检测中…'**
  String get networkChecking;

  /// No description provided for @networkAdvanced.
  ///
  /// In zh, this message translates to:
  /// **'高级设置'**
  String get networkAdvanced;

  /// No description provided for @networkAdvancedHint.
  ///
  /// In zh, this message translates to:
  /// **'面向高级用户的底层选项。'**
  String get networkAdvancedHint;

  /// No description provided for @networkAdvancedReset.
  ///
  /// In zh, this message translates to:
  /// **'恢复默认值'**
  String get networkAdvancedReset;

  /// No description provided for @networkAdvancedResetConfirm.
  ///
  /// In zh, this message translates to:
  /// **'将 DoH 端点与 ECH 前置主机恢复为默认值。'**
  String get networkAdvancedResetConfirm;

  /// No description provided for @networkDoh.
  ///
  /// In zh, this message translates to:
  /// **'严格回退使用 DoH 解析'**
  String get networkDoh;

  /// No description provided for @networkDohHint.
  ///
  /// In zh, this message translates to:
  /// **'启用后，回退阶梯使用 DoH 解析（默认 Cloudflare DoH：域名端点 + 静态 Anycast IP，免系统 DNS 投毒；自定义端点解析域名）；关闭则仅用系统 DNS。'**
  String get networkDohHint;

  /// No description provided for @networkDohEndpoints.
  ///
  /// In zh, this message translates to:
  /// **'DoH 端点'**
  String get networkDohEndpoints;

  /// No description provided for @networkDohEndpointsHint.
  ///
  /// In zh, this message translates to:
  /// **'逗号分隔的 https URL'**
  String get networkDohEndpointsHint;

  /// No description provided for @networkEchFrontHost.
  ///
  /// In zh, this message translates to:
  /// **'ECH 前置主机'**
  String get networkEchFrontHost;

  /// No description provided for @networkEchFrontHostHint.
  ///
  /// In zh, this message translates to:
  /// **'查询 HTTPS RR 获取 ECH config 的域名（默认 cloudflare-ech.com）'**
  String get networkEchFrontHostHint;

  /// No description provided for @networkEchHostInvalid.
  ///
  /// In zh, this message translates to:
  /// **'前置主机名无效'**
  String get networkEchHostInvalid;

  /// No description provided for @networkProbe.
  ///
  /// In zh, this message translates to:
  /// **'分层连通性探测'**
  String get networkProbe;

  /// No description provided for @networkProbeTitle.
  ///
  /// In zh, this message translates to:
  /// **'分层连通性探测'**
  String get networkProbeTitle;

  /// No description provided for @networkProbeHint.
  ///
  /// In zh, this message translates to:
  /// **'逐层检测 Pixiv 连通性，定位打不开的原因。'**
  String get networkProbeHint;

  /// No description provided for @frameProbeTitle.
  ///
  /// In zh, this message translates to:
  /// **'帧探针'**
  String get frameProbeTitle;

  /// No description provided for @frameProbeHint.
  ///
  /// In zh, this message translates to:
  /// **'滚动时记录帧耗时。可离开本页去目标页面滚动，回来停止并复制报告。仅 debug/profile 构建可见。'**
  String get frameProbeHint;

  /// No description provided for @frameProbeStart.
  ///
  /// In zh, this message translates to:
  /// **'开始记录'**
  String get frameProbeStart;

  /// No description provided for @frameProbeRecording.
  ///
  /// In zh, this message translates to:
  /// **'录制中'**
  String get frameProbeRecording;

  /// No description provided for @frameProbeCapHint.
  ///
  /// In zh, this message translates to:
  /// **'已达帧数上限，正在丢弃最旧帧。'**
  String get frameProbeCapHint;

  /// No description provided for @frameProbeStop.
  ///
  /// In zh, this message translates to:
  /// **'停止'**
  String get frameProbeStop;

  /// No description provided for @networkProbeRun.
  ///
  /// In zh, this message translates to:
  /// **'开始探测'**
  String get networkProbeRun;

  /// No description provided for @networkProbeRunning.
  ///
  /// In zh, this message translates to:
  /// **'探测中…'**
  String get networkProbeRunning;

  /// No description provided for @networkProbeNotRun.
  ///
  /// In zh, this message translates to:
  /// **'尚未运行'**
  String get networkProbeNotRun;

  /// No description provided for @networkProbeHostFailed.
  ///
  /// In zh, this message translates to:
  /// **'主机探测失败'**
  String get networkProbeHostFailed;

  /// No description provided for @networkProbeCopied.
  ///
  /// In zh, this message translates to:
  /// **'报告已复制'**
  String get networkProbeCopied;

  /// No description provided for @networkProbeDnsDiff.
  ///
  /// In zh, this message translates to:
  /// **'附加信息：系统 DNS 与 DoH 的公共地址没有交集。'**
  String get networkProbeDnsDiff;

  /// No description provided for @networkProbeStepSystemDns.
  ///
  /// In zh, this message translates to:
  /// **'系统 DNS'**
  String get networkProbeStepSystemDns;

  /// No description provided for @networkProbeStepDoh.
  ///
  /// In zh, this message translates to:
  /// **'DoH'**
  String get networkProbeStepDoh;

  /// No description provided for @networkProbeStepTcp.
  ///
  /// In zh, this message translates to:
  /// **'TCP'**
  String get networkProbeStepTcp;

  /// No description provided for @networkProbeStepTls.
  ///
  /// In zh, this message translates to:
  /// **'TLS'**
  String get networkProbeStepTls;

  /// No description provided for @networkProbeStepHttp.
  ///
  /// In zh, this message translates to:
  /// **'最小请求'**
  String get networkProbeStepHttp;

  /// No description provided for @networkProbeStepEch.
  ///
  /// In zh, this message translates to:
  /// **'ECH'**
  String get networkProbeStepEch;

  /// No description provided for @networkProbeStepNoSni.
  ///
  /// In zh, this message translates to:
  /// **'空 SNI'**
  String get networkProbeStepNoSni;

  /// No description provided for @networkProbeStepOk.
  ///
  /// In zh, this message translates to:
  /// **'成功'**
  String get networkProbeStepOk;

  /// No description provided for @networkProbeStepFailed.
  ///
  /// In zh, this message translates to:
  /// **'失败'**
  String get networkProbeStepFailed;

  /// No description provided for @networkProbeStepSkipped.
  ///
  /// In zh, this message translates to:
  /// **'跳过'**
  String get networkProbeStepSkipped;

  /// No description provided for @networkProbeConclusionAllReachable.
  ///
  /// In zh, this message translates to:
  /// **'可访问'**
  String get networkProbeConclusionAllReachable;

  /// No description provided for @networkProbeConclusionDnsPolluted.
  ///
  /// In zh, this message translates to:
  /// **'DNS 污染'**
  String get networkProbeConclusionDnsPolluted;

  /// No description provided for @networkProbeConclusionSniBlocked.
  ///
  /// In zh, this message translates to:
  /// **'SNI 被封'**
  String get networkProbeConclusionSniBlocked;

  /// No description provided for @networkProbeConclusionEchAvailable.
  ///
  /// In zh, this message translates to:
  /// **'应选 ECH'**
  String get networkProbeConclusionEchAvailable;

  /// No description provided for @networkProbeConclusionNoSniAvailable.
  ///
  /// In zh, this message translates to:
  /// **'应选空 SNI'**
  String get networkProbeConclusionNoSniAvailable;

  /// No description provided for @networkProbeConclusionIpBlackholed.
  ///
  /// In zh, this message translates to:
  /// **'IP 黑洞'**
  String get networkProbeConclusionIpBlackholed;

  /// No description provided for @networkProbeConclusionAppLayer.
  ///
  /// In zh, this message translates to:
  /// **'应用层'**
  String get networkProbeConclusionAppLayer;

  /// No description provided for @networkProbeConclusionInconclusive.
  ///
  /// In zh, this message translates to:
  /// **'不确定'**
  String get networkProbeConclusionInconclusive;

  /// No description provided for @networkProbeOverview.
  ///
  /// In zh, this message translates to:
  /// **'探测总览'**
  String get networkProbeOverview;

  /// No description provided for @networkProbeWorst.
  ///
  /// In zh, this message translates to:
  /// **'最劣'**
  String get networkProbeWorst;

  /// No description provided for @networkProbeDetails.
  ///
  /// In zh, this message translates to:
  /// **'明细'**
  String get networkProbeDetails;

  /// No description provided for @networkProbeNotPersisted.
  ///
  /// In zh, this message translates to:
  /// **'结果不保存——离开本页即丢失。'**
  String get networkProbeNotPersisted;

  /// No description provided for @networkProbeAdviceAllReachable.
  ///
  /// In zh, this message translates to:
  /// **'全部可达，无需调整。'**
  String get networkProbeAdviceAllReachable;

  /// No description provided for @networkProbeAdviceEchAvailable.
  ///
  /// In zh, this message translates to:
  /// **'ECH 可用——「自动」或「兼容优先」模式都会用它。'**
  String get networkProbeAdviceEchAvailable;

  /// No description provided for @networkProbeAdviceNoSniAvailable.
  ///
  /// In zh, this message translates to:
  /// **'空 SNI 通道可用——「兼容优先」模式会用它。'**
  String get networkProbeAdviceNoSniAvailable;

  /// No description provided for @networkProbeAdviceSniBlocked.
  ///
  /// In zh, this message translates to:
  /// **'真实 SNI 被封——建议把网络模式设为「兼容优先」。'**
  String get networkProbeAdviceSniBlocked;

  /// No description provided for @networkProbeAdviceDnsPolluted.
  ///
  /// In zh, this message translates to:
  /// **'系统 DNS 被污染——保持 DoH 开启即可绕过。'**
  String get networkProbeAdviceDnsPolluted;

  /// No description provided for @networkProbeAdviceIpBlackholed.
  ///
  /// In zh, this message translates to:
  /// **'IP 被黑洞，客户端无法绕过——请更换网络。'**
  String get networkProbeAdviceIpBlackholed;

  /// No description provided for @networkProbeAdviceAppLayer.
  ///
  /// In zh, this message translates to:
  /// **'传输层正常，问题在应用层——可复制报告反馈。'**
  String get networkProbeAdviceAppLayer;

  /// No description provided for @networkProbeAdviceInconclusive.
  ///
  /// In zh, this message translates to:
  /// **'无法得出结论——换个网络或稍后重试。'**
  String get networkProbeAdviceInconclusive;

  /// No description provided for @copy.
  ///
  /// In zh, this message translates to:
  /// **'复制'**
  String get copy;

  /// No description provided for @themeSettings.
  ///
  /// In zh, this message translates to:
  /// **'主题'**
  String get themeSettings;

  /// No description provided for @followSystemColors.
  ///
  /// In zh, this message translates to:
  /// **'跟随系统取色'**
  String get followSystemColors;

  /// No description provided for @followSystemColorsHint.
  ///
  /// In zh, this message translates to:
  /// **'用壁纸或系统强调色作为主题色'**
  String get followSystemColorsHint;

  /// No description provided for @followSystemColorsUnavailable.
  ///
  /// In zh, this message translates to:
  /// **'当前系统不提供系统取色'**
  String get followSystemColorsUnavailable;

  /// No description provided for @languageSettings.
  ///
  /// In zh, this message translates to:
  /// **'语言'**
  String get languageSettings;

  /// No description provided for @translateSettings.
  ///
  /// In zh, this message translates to:
  /// **'翻译'**
  String get translateSettings;

  /// No description provided for @browseSettings.
  ///
  /// In zh, this message translates to:
  /// **'浏览设置'**
  String get browseSettings;

  /// No description provided for @settingsBrowseHint.
  ///
  /// In zh, this message translates to:
  /// **'本地屏蔽、图片画质'**
  String get settingsBrowseHint;

  /// No description provided for @downloadSettings.
  ///
  /// In zh, this message translates to:
  /// **'下载设置'**
  String get downloadSettings;

  /// No description provided for @historySettings.
  ///
  /// In zh, this message translates to:
  /// **'历史记录'**
  String get historySettings;

  /// No description provided for @historyRecordLocal.
  ///
  /// In zh, this message translates to:
  /// **'记录本地浏览历史'**
  String get historyRecordLocal;

  /// No description provided for @historyRecordPixiv.
  ///
  /// In zh, this message translates to:
  /// **'记录到 Pixiv 浏览历史'**
  String get historyRecordPixiv;

  /// No description provided for @historyEmpty.
  ///
  /// In zh, this message translates to:
  /// **'暂无浏览历史'**
  String get historyEmpty;

  /// No description provided for @historyLoadFailed.
  ///
  /// In zh, this message translates to:
  /// **'历史记录加载失败'**
  String get historyLoadFailed;

  /// No description provided for @historyDelete.
  ///
  /// In zh, this message translates to:
  /// **'删除历史记录'**
  String get historyDelete;

  /// No description provided for @historyDeleteAll.
  ///
  /// In zh, this message translates to:
  /// **'删除全部历史记录'**
  String get historyDeleteAll;

  /// No description provided for @historyDeleteHint.
  ///
  /// In zh, this message translates to:
  /// **'删除后将不可恢复'**
  String get historyDeleteHint;

  /// No description provided for @downloaderSettings.
  ///
  /// In zh, this message translates to:
  /// **'下载任务'**
  String get downloaderSettings;

  /// No description provided for @aboutSettings.
  ///
  /// In zh, this message translates to:
  /// **'关于'**
  String get aboutSettings;

  /// No description provided for @signedOut.
  ///
  /// In zh, this message translates to:
  /// **'未登录'**
  String get signedOut;

  /// No description provided for @currentAccount.
  ///
  /// In zh, this message translates to:
  /// **'当前账号'**
  String get currentAccount;

  /// No description provided for @accountId.
  ///
  /// In zh, this message translates to:
  /// **'账号 ID'**
  String get accountId;

  /// No description provided for @reauthRequired.
  ///
  /// In zh, this message translates to:
  /// **'需要重新登录'**
  String get reauthRequired;

  /// No description provided for @accountProfile.
  ///
  /// In zh, this message translates to:
  /// **'个人资料'**
  String get accountProfile;

  /// No description provided for @accountReadFailed.
  ///
  /// In zh, this message translates to:
  /// **'读取账号状态失败'**
  String get accountReadFailed;

  /// No description provided for @dismiss.
  ///
  /// In zh, this message translates to:
  /// **'知道了'**
  String get dismiss;

  /// No description provided for @profileEditTitle.
  ///
  /// In zh, this message translates to:
  /// **'编辑个人资料'**
  String get profileEditTitle;

  /// No description provided for @profileEditLoadFailed.
  ///
  /// In zh, this message translates to:
  /// **'个人资料加载失败'**
  String get profileEditLoadFailed;

  /// No description provided for @profileEditUnavailable.
  ///
  /// In zh, this message translates to:
  /// **'当前没有可用的应用内资料编辑通道。'**
  String get profileEditUnavailable;

  /// No description provided for @profileEditPending.
  ///
  /// In zh, this message translates to:
  /// **'资料已提交，等待验证后才会生效。'**
  String get profileEditPending;

  /// No description provided for @profileEditConfirmed.
  ///
  /// In zh, this message translates to:
  /// **'资料已确认并同步。'**
  String get profileEditConfirmed;

  /// No description provided for @profileEditDisplayName.
  ///
  /// In zh, this message translates to:
  /// **'昵称'**
  String get profileEditDisplayName;

  /// No description provided for @profileEditComment.
  ///
  /// In zh, this message translates to:
  /// **'自我介绍'**
  String get profileEditComment;

  /// No description provided for @profileEditWebpage.
  ///
  /// In zh, this message translates to:
  /// **'网页'**
  String get profileEditWebpage;

  /// No description provided for @profileEditAvatar.
  ///
  /// In zh, this message translates to:
  /// **'头像'**
  String get profileEditAvatar;

  /// No description provided for @profileEditBackground.
  ///
  /// In zh, this message translates to:
  /// **'背景图'**
  String get profileEditBackground;

  /// No description provided for @profileEditCurrentPassword.
  ///
  /// In zh, this message translates to:
  /// **'当前密码'**
  String get profileEditCurrentPassword;

  /// No description provided for @profileEditFieldUnsupported.
  ///
  /// In zh, this message translates to:
  /// **'当前通道不支持此字段'**
  String get profileEditFieldUnsupported;

  /// No description provided for @profileEditImageChoose.
  ///
  /// In zh, this message translates to:
  /// **'选择一张受支持的图片'**
  String get profileEditImageChoose;

  /// No description provided for @profileEditImageFailed.
  ///
  /// In zh, this message translates to:
  /// **'图片处理失败'**
  String get profileEditImageFailed;

  /// No description provided for @profileEditChooseImage.
  ///
  /// In zh, this message translates to:
  /// **'选择图片'**
  String get profileEditChooseImage;

  /// Screen-reader label of the tappable avatar on the profile edit page.
  ///
  /// In zh, this message translates to:
  /// **'更换头像'**
  String get profileChangeAvatar;

  /// Screen-reader label of the tappable background image on the profile edit page.
  ///
  /// In zh, this message translates to:
  /// **'更换背景图'**
  String get profileChangeBackground;

  /// No description provided for @profileEditSave.
  ///
  /// In zh, this message translates to:
  /// **'保存资料'**
  String get profileEditSave;

  /// No description provided for @profileEditLeaveTitle.
  ///
  /// In zh, this message translates to:
  /// **'放弃未保存的修改？'**
  String get profileEditLeaveTitle;

  /// No description provided for @profileEditLeaveDetail.
  ///
  /// In zh, this message translates to:
  /// **'当前修改尚未提交，离开后会丢失。'**
  String get profileEditLeaveDetail;

  /// No description provided for @profileEditLeaveConfirm.
  ///
  /// In zh, this message translates to:
  /// **'放弃修改'**
  String get profileEditLeaveConfirm;

  /// No description provided for @accountManagement.
  ///
  /// In zh, this message translates to:
  /// **'账号管理'**
  String get accountManagement;

  /// No description provided for @addAccount.
  ///
  /// In zh, this message translates to:
  /// **'添加账号'**
  String get addAccount;

  /// No description provided for @switchAccount.
  ///
  /// In zh, this message translates to:
  /// **'切换账号'**
  String get switchAccount;

  /// No description provided for @accountSwitching.
  ///
  /// In zh, this message translates to:
  /// **'正在切换…'**
  String get accountSwitching;

  /// No description provided for @removeAccount.
  ///
  /// In zh, this message translates to:
  /// **'移除账号'**
  String get removeAccount;

  /// No description provided for @removeAccountConfirm.
  ///
  /// In zh, this message translates to:
  /// **'确定移除这个账号？'**
  String get removeAccountConfirm;

  /// No description provided for @noAccounts.
  ///
  /// In zh, this message translates to:
  /// **'暂无账号'**
  String get noAccounts;

  /// No description provided for @profileReadOnly.
  ///
  /// In zh, this message translates to:
  /// **'这里显示当前账号的已保存资料。完整资料编辑由个人资料模块提供。'**
  String get profileReadOnly;

  /// No description provided for @serverDisplaySettings.
  ///
  /// In zh, this message translates to:
  /// **'账号显示设置'**
  String get serverDisplaySettings;

  /// No description provided for @serverDisplayHint.
  ///
  /// In zh, this message translates to:
  /// **'由 Pixiv 服务端保存，作用于接口为该账号返回的内容。'**
  String get serverDisplayHint;

  /// No description provided for @serverShowAi.
  ///
  /// In zh, this message translates to:
  /// **'显示 AI 生成作品'**
  String get serverShowAi;

  /// No description provided for @serverRestrictedMode.
  ///
  /// In zh, this message translates to:
  /// **'受限模式'**
  String get serverRestrictedMode;

  /// No description provided for @serverDisplayLoadFailed.
  ///
  /// In zh, this message translates to:
  /// **'服务端设置读取失败'**
  String get serverDisplayLoadFailed;

  /// No description provided for @serverDisplayWriteFailed.
  ///
  /// In zh, this message translates to:
  /// **'服务端设置保存失败'**
  String get serverDisplayWriteFailed;

  /// No description provided for @backupSettings.
  ///
  /// In zh, this message translates to:
  /// **'备份与导入'**
  String get backupSettings;

  /// No description provided for @backupHint.
  ///
  /// In zh, this message translates to:
  /// **'导出当前设置、屏蔽列表和浏览历史；凭据不会写入文件。'**
  String get backupHint;

  /// No description provided for @backupExport.
  ///
  /// In zh, this message translates to:
  /// **'导出备份'**
  String get backupExport;

  /// No description provided for @backupExportHint.
  ///
  /// In zh, this message translates to:
  /// **'选择目录后写入 parfait-backup-*.json'**
  String get backupExportHint;

  /// No description provided for @backupExported.
  ///
  /// In zh, this message translates to:
  /// **'已导出 {name}'**
  String backupExported(String name);

  /// No description provided for @backupExportFailed.
  ///
  /// In zh, this message translates to:
  /// **'导出失败'**
  String get backupExportFailed;

  /// No description provided for @backupImport.
  ///
  /// In zh, this message translates to:
  /// **'导入备份'**
  String get backupImport;

  /// No description provided for @backupImportHint.
  ///
  /// In zh, this message translates to:
  /// **'从 JSON 文件导入，可选合并或覆盖'**
  String get backupImportHint;

  /// No description provided for @backupImportInvalid.
  ///
  /// In zh, this message translates to:
  /// **'备份文件无效'**
  String get backupImportInvalid;

  /// No description provided for @backupImportFailed.
  ///
  /// In zh, this message translates to:
  /// **'导入失败'**
  String get backupImportFailed;

  /// No description provided for @backupImportStrategyTitle.
  ///
  /// In zh, this message translates to:
  /// **'选择导入方式'**
  String get backupImportStrategyTitle;

  /// No description provided for @backupImportPrompt.
  ///
  /// In zh, this message translates to:
  /// **'文件包含 {tags} 个屏蔽标签、{users} 个屏蔽用户、{works} 条作品屏蔽、{history} 条历史。\n导出账号：{account}'**
  String backupImportPrompt(
    int tags,
    int users,
    int works,
    int history,
    String account,
  );

  /// No description provided for @backupImportOverwriteNote.
  ///
  /// In zh, this message translates to:
  /// **'覆盖会先清空本地历史并替换作品屏蔽；服务端屏蔽列表只增不删，覆盖不会删除服务器上的屏蔽项。'**
  String get backupImportOverwriteNote;

  /// No description provided for @backupMerge.
  ///
  /// In zh, this message translates to:
  /// **'合并'**
  String get backupMerge;

  /// No description provided for @backupOverwrite.
  ///
  /// In zh, this message translates to:
  /// **'覆盖'**
  String get backupOverwrite;

  /// No description provided for @backupMergeHint.
  ///
  /// In zh, this message translates to:
  /// **'保留现有数据，添加文件内容'**
  String get backupMergeHint;

  /// No description provided for @backupOverwriteHint.
  ///
  /// In zh, this message translates to:
  /// **'以文件内容替换本地数据'**
  String get backupOverwriteHint;

  /// No description provided for @backupImportMergeConfirmTitle.
  ///
  /// In zh, this message translates to:
  /// **'将添加 {tags} 个屏蔽标签、{users} 个屏蔽用户、{works} 个屏蔽作品和 {history} 条历史记录'**
  String backupImportMergeConfirmTitle(
    int tags,
    int users,
    int works,
    int history,
  );

  /// No description provided for @backupImportOverwriteConfirmTitle.
  ///
  /// In zh, this message translates to:
  /// **'将清空本地历史，屏蔽作品与设置以文件为准'**
  String get backupImportOverwriteConfirmTitle;

  /// No description provided for @backupImportDone.
  ///
  /// In zh, this message translates to:
  /// **'导入完成：新增 {tags} 个标签、{users} 个用户、{works} 项作品屏蔽变更、{history} 条历史'**
  String backupImportDone(int tags, int users, int works, int history);

  /// No description provided for @imageSource.
  ///
  /// In zh, this message translates to:
  /// **'图片源'**
  String get imageSource;

  /// No description provided for @imageSourceNormal.
  ///
  /// In zh, this message translates to:
  /// **'官方源'**
  String get imageSourceNormal;

  /// No description provided for @imageSourcePixivCat.
  ///
  /// In zh, this message translates to:
  /// **'pixiv.cat 镜像'**
  String get imageSourcePixivCat;

  /// No description provided for @imageSourcePixivRe.
  ///
  /// In zh, this message translates to:
  /// **'pixiv.re 镜像'**
  String get imageSourcePixivRe;

  /// No description provided for @imageSourcePixivNl.
  ///
  /// In zh, this message translates to:
  /// **'pixiv.nl 镜像'**
  String get imageSourcePixivNl;

  /// No description provided for @imageSourceCustom.
  ///
  /// In zh, this message translates to:
  /// **'自定义反代'**
  String get imageSourceCustom;

  /// No description provided for @imageSourceCustomHint.
  ///
  /// In zh, this message translates to:
  /// **'https://host[/path]，例如 https://i.pixiv.cat'**
  String get imageSourceCustomHint;

  /// No description provided for @imageSourceCustomUnset.
  ///
  /// In zh, this message translates to:
  /// **'未配置'**
  String get imageSourceCustomUnset;

  /// No description provided for @imageSourceCustomInvalid.
  ///
  /// In zh, this message translates to:
  /// **'无效自定义源：需 https、域名且仅支持 443 端口'**
  String get imageSourceCustomInvalid;

  /// No description provided for @imageSourceApplyAndTest.
  ///
  /// In zh, this message translates to:
  /// **'应用并测试'**
  String get imageSourceApplyAndTest;

  /// No description provided for @imageSourceTestOk.
  ///
  /// In zh, this message translates to:
  /// **'镜像可达（HTTP {code}）'**
  String imageSourceTestOk(String code);

  /// No description provided for @imageSourceTestFailed.
  ///
  /// In zh, this message translates to:
  /// **'镜像连通性测试失败'**
  String get imageSourceTestFailed;

  /// No description provided for @imageSourceUnreachableMainland.
  ///
  /// In zh, this message translates to:
  /// **'大陆网络通常不可达'**
  String get imageSourceUnreachableMainland;

  /// No description provided for @imageSourceAuto.
  ///
  /// In zh, this message translates to:
  /// **'自动（默认，按当前网络测速选源）'**
  String get imageSourceAuto;

  /// No description provided for @imageSourceAutoWinner.
  ///
  /// In zh, this message translates to:
  /// **'当前：{host}'**
  String imageSourceAutoWinner(String host);

  /// No description provided for @imageSourceAutoPending.
  ///
  /// In zh, this message translates to:
  /// **'尚未测速，暂按直连'**
  String get imageSourceAutoPending;

  /// No description provided for @previewQuality.
  ///
  /// In zh, this message translates to:
  /// **'预览质量'**
  String get previewQuality;

  /// No description provided for @viewQuality.
  ///
  /// In zh, this message translates to:
  /// **'查看质量'**
  String get viewQuality;

  /// No description provided for @detailQuality.
  ///
  /// In zh, this message translates to:
  /// **'详情质量'**
  String get detailQuality;

  /// No description provided for @qualityMedium.
  ///
  /// In zh, this message translates to:
  /// **'中图'**
  String get qualityMedium;

  /// No description provided for @qualityLarge.
  ///
  /// In zh, this message translates to:
  /// **'大图'**
  String get qualityLarge;

  /// No description provided for @qualityOriginal.
  ///
  /// In zh, this message translates to:
  /// **'原图'**
  String get qualityOriginal;

  /// No description provided for @scaleQuality.
  ///
  /// In zh, this message translates to:
  /// **'查看质量（原图）'**
  String get scaleQuality;

  /// No description provided for @blockR18.
  ///
  /// In zh, this message translates to:
  /// **'本地屏蔽 R-18 作品'**
  String get blockR18;

  /// No description provided for @blockAI.
  ///
  /// In zh, this message translates to:
  /// **'本地屏蔽 AI 作品'**
  String get blockAI;

  /// No description provided for @hideMuted.
  ///
  /// In zh, this message translates to:
  /// **'直接隐藏被屏蔽的作品'**
  String get hideMuted;

  /// No description provided for @hideMutedHint.
  ///
  /// In zh, this message translates to:
  /// **'关闭后，被屏蔽的作品以模糊卡片显示，点按可临时查看'**
  String get hideMutedHint;

  /// No description provided for @mutedContent.
  ///
  /// In zh, this message translates to:
  /// **'已屏蔽'**
  String get mutedContent;

  /// No description provided for @mutedItemsSettings.
  ///
  /// In zh, this message translates to:
  /// **'屏蔽管理'**
  String get mutedItemsSettings;

  /// No description provided for @mutedTagsSection.
  ///
  /// In zh, this message translates to:
  /// **'屏蔽标签'**
  String get mutedTagsSection;

  /// No description provided for @mutedUsersSection.
  ///
  /// In zh, this message translates to:
  /// **'屏蔽用户'**
  String get mutedUsersSection;

  /// No description provided for @mutedWorksSection.
  ///
  /// In zh, this message translates to:
  /// **'屏蔽作品'**
  String get mutedWorksSection;

  /// No description provided for @mutedEmpty.
  ///
  /// In zh, this message translates to:
  /// **'暂无屏蔽条目'**
  String get mutedEmpty;

  /// Hint in an empty group of the muted items page: where this kind of mute is made. action is the card menu label (muteAuthor or muteWork).
  ///
  /// In zh, this message translates to:
  /// **'长按作品卡片，选择「{action}」'**
  String muteEmptyHint(String action);

  /// No description provided for @muteTagInputHint.
  ///
  /// In zh, this message translates to:
  /// **'输入要屏蔽的标签'**
  String get muteTagInputHint;

  /// No description provided for @muteWork.
  ///
  /// In zh, this message translates to:
  /// **'屏蔽此作品'**
  String get muteWork;

  /// No description provided for @unmuteWork.
  ///
  /// In zh, this message translates to:
  /// **'解除屏蔽此作品'**
  String get unmuteWork;

  /// No description provided for @muteAuthor.
  ///
  /// In zh, this message translates to:
  /// **'屏蔽作者'**
  String get muteAuthor;

  /// No description provided for @unmuteAuthor.
  ///
  /// In zh, this message translates to:
  /// **'解除屏蔽作者'**
  String get unmuteAuthor;

  /// No description provided for @unmuteTag.
  ///
  /// In zh, this message translates to:
  /// **'解除屏蔽'**
  String get unmuteTag;

  /// No description provided for @muteFailed.
  ///
  /// In zh, this message translates to:
  /// **'屏蔽操作失败'**
  String get muteFailed;

  /// No description provided for @reduceMotion.
  ///
  /// In zh, this message translates to:
  /// **'减少动态效果'**
  String get reduceMotion;

  /// No description provided for @reduceMotionHint.
  ///
  /// In zh, this message translates to:
  /// **'关闭页面转场、列表进场与按压反馈等装饰性动画'**
  String get reduceMotionHint;

  /// No description provided for @pressFeedback.
  ///
  /// In zh, this message translates to:
  /// **'按压反馈'**
  String get pressFeedback;

  /// No description provided for @pressFeedbackHint.
  ///
  /// In zh, this message translates to:
  /// **'按下卡片时轻微缩小'**
  String get pressFeedbackHint;

  /// No description provided for @animationSpeed.
  ///
  /// In zh, this message translates to:
  /// **'动画速度'**
  String get animationSpeed;

  /// No description provided for @animationSpeedFast.
  ///
  /// In zh, this message translates to:
  /// **'快'**
  String get animationSpeedFast;

  /// No description provided for @animationSpeedNormal.
  ///
  /// In zh, this message translates to:
  /// **'标准'**
  String get animationSpeedNormal;

  /// No description provided for @animationSpeedSlow.
  ///
  /// In zh, this message translates to:
  /// **'慢'**
  String get animationSpeedSlow;

  /// No description provided for @animationSpeedHint.
  ///
  /// In zh, this message translates to:
  /// **'作用于应用内全部动画；水波纹等系统控件动画不受影响'**
  String get animationSpeedHint;

  /// No description provided for @animationSpeedReduceHint.
  ///
  /// In zh, this message translates to:
  /// **'开启「减少动态效果」时不播放动画，速度不生效'**
  String get animationSpeedReduceHint;

  /// No description provided for @motionSettings.
  ///
  /// In zh, this message translates to:
  /// **'动效与触感'**
  String get motionSettings;

  /// No description provided for @motionPageTransition.
  ///
  /// In zh, this message translates to:
  /// **'页面转场'**
  String get motionPageTransition;

  /// No description provided for @pageTransitionStyleSystem.
  ///
  /// In zh, this message translates to:
  /// **'系统默认'**
  String get pageTransitionStyleSystem;

  /// No description provided for @pageTransitionStyleSystemHint.
  ///
  /// In zh, this message translates to:
  /// **'安卓系统转场，支持预测性返回'**
  String get pageTransitionStyleSystemHint;

  /// No description provided for @pageTransitionStyleSystemHintOther.
  ///
  /// In zh, this message translates to:
  /// **'平台默认'**
  String get pageTransitionStyleSystemHintOther;

  /// No description provided for @pageTransitionStyleSlide.
  ///
  /// In zh, this message translates to:
  /// **'侧滑'**
  String get pageTransitionStyleSlide;

  /// No description provided for @pageTransitionStyleSlideHint.
  ///
  /// In zh, this message translates to:
  /// **'从右侧推入，上一页错开并变暗（iOS 风格）'**
  String get pageTransitionStyleSlideHint;

  /// No description provided for @maxDownloadCount.
  ///
  /// In zh, this message translates to:
  /// **'最大并行下载数'**
  String get maxDownloadCount;

  /// No description provided for @maxDownloadCountHint.
  ///
  /// In zh, this message translates to:
  /// **'拖动预览数值，松手后生效'**
  String get maxDownloadCountHint;

  /// No description provided for @namingRule.
  ///
  /// In zh, this message translates to:
  /// **'文件命名规则'**
  String get namingRule;

  /// No description provided for @namingRuleHint.
  ///
  /// In zh, this message translates to:
  /// **'留空使用默认命名'**
  String get namingRuleHint;

  /// No description provided for @saveFolder.
  ///
  /// In zh, this message translates to:
  /// **'保存目录'**
  String get saveFolder;

  /// No description provided for @saveLocation.
  ///
  /// In zh, this message translates to:
  /// **'保存位置'**
  String get saveLocation;

  /// No description provided for @saveLocationAlbum.
  ///
  /// In zh, this message translates to:
  /// **'相册'**
  String get saveLocationAlbum;

  /// No description provided for @saveLocationPixivAlbum.
  ///
  /// In zh, this message translates to:
  /// **'Parfait 相册（默认）'**
  String get saveLocationPixivAlbum;

  /// No description provided for @saveLocationCustomAlbum.
  ///
  /// In zh, this message translates to:
  /// **'自定义相册名称'**
  String get saveLocationCustomAlbum;

  /// No description provided for @saveLocationCustomAlbumHint.
  ///
  /// In zh, this message translates to:
  /// **'仅字母、数字、中文与下划线'**
  String get saveLocationCustomAlbumHint;

  /// No description provided for @saveLocationAlbumInvalid.
  ///
  /// In zh, this message translates to:
  /// **'相册名称无效'**
  String get saveLocationAlbumInvalid;

  /// No description provided for @saveLocationSafFolder.
  ///
  /// In zh, this message translates to:
  /// **'文件夹（系统目录选择）'**
  String get saveLocationSafFolder;

  /// No description provided for @saveLocationSafFolderHint.
  ///
  /// In zh, this message translates to:
  /// **'通过系统 SAF 选择目录并持久授权'**
  String get saveLocationSafFolderHint;

  /// No description provided for @safStorageInternal.
  ///
  /// In zh, this message translates to:
  /// **'内部存储'**
  String get safStorageInternal;

  /// No description provided for @safStorageSdCard.
  ///
  /// In zh, this message translates to:
  /// **'SD 卡（{volume}）'**
  String safStorageSdCard(String volume);

  /// No description provided for @saveLocationUriCopied.
  ///
  /// In zh, this message translates to:
  /// **'已复制目录 URI'**
  String get saveLocationUriCopied;

  /// No description provided for @namingPreset.
  ///
  /// In zh, this message translates to:
  /// **'文件命名预设'**
  String get namingPreset;

  /// No description provided for @namingPresetId.
  ///
  /// In zh, this message translates to:
  /// **'作品 ID（默认）'**
  String get namingPresetId;

  /// No description provided for @namingPresetArtistTitleId.
  ///
  /// In zh, this message translates to:
  /// **'作者 - 标题 - ID'**
  String get namingPresetArtistTitleId;

  /// No description provided for @namingPresetTitleId.
  ///
  /// In zh, this message translates to:
  /// **'标题 - ID'**
  String get namingPresetTitleId;

  /// No description provided for @namingPresetCustom.
  ///
  /// In zh, this message translates to:
  /// **'自定义模板'**
  String get namingPresetCustom;

  /// No description provided for @namingTemplate.
  ///
  /// In zh, this message translates to:
  /// **'命名模板'**
  String get namingTemplate;

  /// No description provided for @namingTemplateHint.
  ///
  /// In zh, this message translates to:
  /// **'{artist}_{title}_{id}_p{page}.{ext}'**
  String namingTemplateHint(
    String artist,
    String title,
    String id,
    String page,
    String ext,
  );

  /// No description provided for @namingTemplateInvalid.
  ///
  /// In zh, this message translates to:
  /// **'模板包含不支持的变量或非法字符'**
  String get namingTemplateInvalid;

  /// No description provided for @namingPreview.
  ///
  /// In zh, this message translates to:
  /// **'预览'**
  String get namingPreview;

  /// Chip under the custom naming template: what the variable inserts. Tapping it inserts the variable.
  ///
  /// In zh, this message translates to:
  /// **'作者名'**
  String get namingVarArtist;

  /// Chip under the custom naming template: what the variable inserts. Tapping it inserts the variable.
  ///
  /// In zh, this message translates to:
  /// **'标题'**
  String get namingVarTitle;

  /// Chip under the custom naming template: what the variable inserts. Tapping it inserts the variable.
  ///
  /// In zh, this message translates to:
  /// **'作品 ID'**
  String get namingVarId;

  /// Chip under the custom naming template: what the variable inserts. Tapping it inserts the variable.
  ///
  /// In zh, this message translates to:
  /// **'作者 ID'**
  String get namingVarAuthorId;

  /// Chip under the custom naming template: what the variable inserts. Tapping it inserts the variable.
  ///
  /// In zh, this message translates to:
  /// **'页码（从 0 开始）'**
  String get namingVarPage;

  /// Chip under the custom naming template: what the variable inserts. Tapping it inserts the variable.
  ///
  /// In zh, this message translates to:
  /// **'页码（从 1 开始）'**
  String get namingVarPage1;

  /// Chip under the custom naming template: what the variable inserts. Tapping it inserts the variable.
  ///
  /// In zh, this message translates to:
  /// **'总页数'**
  String get namingVarPages;

  /// Chip under the custom naming template: what the variable inserts. Tapping it inserts the variable.
  ///
  /// In zh, this message translates to:
  /// **'扩展名'**
  String get namingVarExt;

  /// Chip under the custom naming template: what the variable inserts. Tapping it inserts the variable.
  ///
  /// In zh, this message translates to:
  /// **'宽度'**
  String get namingVarW;

  /// Chip under the custom naming template: what the variable inserts. Tapping it inserts the variable.
  ///
  /// In zh, this message translates to:
  /// **'高度'**
  String get namingVarH;

  /// Chip under the custom naming template: what the variable inserts. Tapping it inserts the variable.
  ///
  /// In zh, this message translates to:
  /// **'日期'**
  String get namingVarDate;

  /// Chip under the custom naming template: what the variable inserts. Tapping it inserts the variable.
  ///
  /// In zh, this message translates to:
  /// **'日期和时间'**
  String get namingVarCreated;

  /// Chip under the custom naming template: what the variable inserts. Tapping it inserts the variable.
  ///
  /// In zh, this message translates to:
  /// **'系列名'**
  String get namingVarSeries;

  /// Chip under the custom naming template: what the variable inserts. Tapping it inserts the variable.
  ///
  /// In zh, this message translates to:
  /// **'系列内序号'**
  String get namingVarSeriesOrder;

  /// Chip under the custom naming template: what the variable inserts. Tapping it inserts the variable.
  ///
  /// In zh, this message translates to:
  /// **'系列总话数'**
  String get namingVarChapters;

  /// Sample value in the naming template preview.
  ///
  /// In zh, this message translates to:
  /// **'作者名'**
  String get namingSampleArtist;

  /// Sample value in the naming template preview.
  ///
  /// In zh, this message translates to:
  /// **'作品标题'**
  String get namingSampleTitle;

  /// Sample value in the naming template preview.
  ///
  /// In zh, this message translates to:
  /// **'系列名'**
  String get namingSampleSeries;

  /// No description provided for @namingTemplateSanitizeNote.
  ///
  /// In zh, this message translates to:
  /// **'非法字符自动替换为 _，超长自动裁剪。'**
  String get namingTemplateSanitizeNote;

  /// No description provided for @notConfigured.
  ///
  /// In zh, this message translates to:
  /// **'未配置'**
  String get notConfigured;

  /// No description provided for @translateProvider.
  ///
  /// In zh, this message translates to:
  /// **'翻译服务'**
  String get translateProvider;

  /// No description provided for @translateGoogle.
  ///
  /// In zh, this message translates to:
  /// **'Google Translate'**
  String get translateGoogle;

  /// No description provided for @translateDisabled.
  ///
  /// In zh, this message translates to:
  /// **'关闭'**
  String get translateDisabled;

  /// No description provided for @translateBaidu.
  ///
  /// In zh, this message translates to:
  /// **'百度翻译'**
  String get translateBaidu;

  /// No description provided for @translateLlm.
  ///
  /// In zh, this message translates to:
  /// **'自定义 LLM（OpenAI 兼容）'**
  String get translateLlm;

  /// No description provided for @translateBaiduCredential.
  ///
  /// In zh, this message translates to:
  /// **'百度 AppID / 密钥'**
  String get translateBaiduCredential;

  /// No description provided for @translateLlmCredential.
  ///
  /// In zh, this message translates to:
  /// **'LLM 接口与密钥'**
  String get translateLlmCredential;

  /// No description provided for @translateBaiduAppId.
  ///
  /// In zh, this message translates to:
  /// **'AppID'**
  String get translateBaiduAppId;

  /// No description provided for @translateBaiduSecret.
  ///
  /// In zh, this message translates to:
  /// **'密钥 (Secret)'**
  String get translateBaiduSecret;

  /// No description provided for @translateLlmBaseUrl.
  ///
  /// In zh, this message translates to:
  /// **'接口地址（HTTPS）'**
  String get translateLlmBaseUrl;

  /// No description provided for @translateLlmApiKey.
  ///
  /// In zh, this message translates to:
  /// **'API Key'**
  String get translateLlmApiKey;

  /// No description provided for @translateLlmModel.
  ///
  /// In zh, this message translates to:
  /// **'模型名（可选）'**
  String get translateLlmModel;

  /// No description provided for @translateCredentialsSave.
  ///
  /// In zh, this message translates to:
  /// **'保存到安全存储'**
  String get translateCredentialsSave;

  /// No description provided for @translateCredentialsClear.
  ///
  /// In zh, this message translates to:
  /// **'清除凭据'**
  String get translateCredentialsClear;

  /// No description provided for @translateCredentialsClearConfirm.
  ///
  /// In zh, this message translates to:
  /// **'将删除安全存储中的凭据；翻译前需要重新输入。'**
  String get translateCredentialsClearConfirm;

  /// No description provided for @translateCredentialsSaved.
  ///
  /// In zh, this message translates to:
  /// **'已保存到安全存储'**
  String get translateCredentialsSaved;

  /// No description provided for @translateCredentialsCleared.
  ///
  /// In zh, this message translates to:
  /// **'凭据已清除'**
  String get translateCredentialsCleared;

  /// No description provided for @translateCredentialsStoreError.
  ///
  /// In zh, this message translates to:
  /// **'安全存储操作失败'**
  String get translateCredentialsStoreError;

  /// No description provided for @translateCredentialsInvalid.
  ///
  /// In zh, this message translates to:
  /// **'输入不完整或接口地址不是 HTTPS'**
  String get translateCredentialsInvalid;

  /// No description provided for @translateBaiduHint.
  ///
  /// In zh, this message translates to:
  /// **'百度翻译标准版无需认证，但只有 5 万字符/月、每秒 1 次，评论翻译基本不够；高级版需个人实名认证（姓名 + 身份证号），100 万字符/月、每秒 10 次。凭据仅用于翻译请求。'**
  String get translateBaiduHint;

  /// No description provided for @translateLlmCredentialHint.
  ///
  /// In zh, this message translates to:
  /// **'仅允许 HTTPS 接口；翻译使用固定提示词，不开放模型与高级参数。评论正文与译文不会持久化。'**
  String get translateLlmCredentialHint;

  /// No description provided for @translateCredentialHint.
  ///
  /// In zh, this message translates to:
  /// **'翻译凭据不会写入普通设置；需要时由安全存储管理。'**
  String get translateCredentialHint;

  /// No description provided for @translateDoubao.
  ///
  /// In zh, this message translates to:
  /// **'豆包（网页登录）'**
  String get translateDoubao;

  /// No description provided for @translateDoubaoAccount.
  ///
  /// In zh, this message translates to:
  /// **'豆包账号'**
  String get translateDoubaoAccount;

  /// No description provided for @translateDoubaoSignedIn.
  ///
  /// In zh, this message translates to:
  /// **'已登录'**
  String get translateDoubaoSignedIn;

  /// No description provided for @translateDoubaoSignedOut.
  ///
  /// In zh, this message translates to:
  /// **'未登录'**
  String get translateDoubaoSignedOut;

  /// No description provided for @translateDoubaoHint.
  ///
  /// In zh, this message translates to:
  /// **'用你在应用内登录的豆包网页账号翻译，无需 API Key，请求以你的豆包账号身份发出。这是非官方接口，可能随时失效，也可能触发账号风控。'**
  String get translateDoubaoHint;

  /// No description provided for @translateDoubaoSignOut.
  ///
  /// In zh, this message translates to:
  /// **'退出豆包登录？'**
  String get translateDoubaoSignOut;

  /// No description provided for @translateDoubaoSignOutConfirm.
  ///
  /// In zh, this message translates to:
  /// **'将删除保存的豆包登录信息，翻译前需要重新登录。'**
  String get translateDoubaoSignOutConfirm;

  /// No description provided for @translateDoubaoSignOutAction.
  ///
  /// In zh, this message translates to:
  /// **'退出登录'**
  String get translateDoubaoSignOutAction;

  /// No description provided for @doubaoLoginTitle.
  ///
  /// In zh, this message translates to:
  /// **'登录豆包'**
  String get doubaoLoginTitle;

  /// No description provided for @doubaoLoginDone.
  ///
  /// In zh, this message translates to:
  /// **'完成'**
  String get doubaoLoginDone;

  /// No description provided for @doubaoLoginNotDetected.
  ///
  /// In zh, this message translates to:
  /// **'还没有检测到豆包登录，请先在页面中登录'**
  String get doubaoLoginNotDetected;

  /// No description provided for @downloadTasksEmpty.
  ///
  /// In zh, this message translates to:
  /// **'暂无下载任务'**
  String get downloadTasksEmpty;

  /// No description provided for @downloadQueued.
  ///
  /// In zh, this message translates to:
  /// **'排队中'**
  String get downloadQueued;

  /// No description provided for @downloadRunning.
  ///
  /// In zh, this message translates to:
  /// **'下载中'**
  String get downloadRunning;

  /// No description provided for @downloadCanceling.
  ///
  /// In zh, this message translates to:
  /// **'取消中'**
  String get downloadCanceling;

  /// No description provided for @downloadSucceeded.
  ///
  /// In zh, this message translates to:
  /// **'已完成'**
  String get downloadSucceeded;

  /// No description provided for @downloadFailed.
  ///
  /// In zh, this message translates to:
  /// **'失败'**
  String get downloadFailed;

  /// No description provided for @downloadCanceled.
  ///
  /// In zh, this message translates to:
  /// **'已取消'**
  String get downloadCanceled;

  /// No description provided for @retryDownload.
  ///
  /// In zh, this message translates to:
  /// **'重试'**
  String get retryDownload;

  /// No description provided for @cancelDownload.
  ///
  /// In zh, this message translates to:
  /// **'取消'**
  String get cancelDownload;

  /// No description provided for @downloadPaused.
  ///
  /// In zh, this message translates to:
  /// **'已暂停'**
  String get downloadPaused;

  /// No description provided for @pauseDownload.
  ///
  /// In zh, this message translates to:
  /// **'暂停'**
  String get pauseDownload;

  /// No description provided for @downloadProcessing.
  ///
  /// In zh, this message translates to:
  /// **'处理中'**
  String get downloadProcessing;

  /// No description provided for @downloadViewResult.
  ///
  /// In zh, this message translates to:
  /// **'查看'**
  String get downloadViewResult;

  /// No description provided for @downloadRemoveRecord.
  ///
  /// In zh, this message translates to:
  /// **'移除'**
  String get downloadRemoveRecord;

  /// Screen-reader hint of a download task row: tapping opens its work
  ///
  /// In zh, this message translates to:
  /// **'打开作品'**
  String get downloadOpenWork;

  /// Download tasks app-bar action: removes the records of successfully finished tasks
  ///
  /// In zh, this message translates to:
  /// **'清除已完成'**
  String get downloadClearCompleted;

  /// Undo prompt after download task records were removed
  ///
  /// In zh, this message translates to:
  /// **'已移除 {count} 条记录'**
  String downloadTasksRemoved(int count);

  /// No description provided for @downloadBatchCancelConfirm.
  ///
  /// In zh, this message translates to:
  /// **'取消选中的 {count} 项下载？未完成的进度会被丢弃。'**
  String downloadBatchCancelConfirm(int count);

  /// No description provided for @resumeDownload.
  ///
  /// In zh, this message translates to:
  /// **'继续'**
  String get resumeDownload;

  /// No description provided for @downloadGroupTitle.
  ///
  /// In zh, this message translates to:
  /// **'批量下载 · {count} 项'**
  String downloadGroupTitle(int count);

  /// No description provided for @downloadGroupProgress.
  ///
  /// In zh, this message translates to:
  /// **'已完成 {done}/{count}'**
  String downloadGroupProgress(int done, int count);

  /// No description provided for @downloadGroupAuthorTitle.
  ///
  /// In zh, this message translates to:
  /// **'{name} 的作品'**
  String downloadGroupAuthorTitle(String name);

  /// No description provided for @downloadTaskPageLabel.
  ///
  /// In zh, this message translates to:
  /// **'第 {page}/{total} 页'**
  String downloadTaskPageLabel(int page, int total);

  /// No description provided for @downloadAuthorWorks.
  ///
  /// In zh, this message translates to:
  /// **'下载全部作品'**
  String get downloadAuthorWorks;

  /// No description provided for @downloadAuthorWorksTitle.
  ///
  /// In zh, this message translates to:
  /// **'下载作者全部作品'**
  String get downloadAuthorWorksTitle;

  /// No description provided for @downloadAuthorEnumerating.
  ///
  /// In zh, this message translates to:
  /// **'正在枚举作品…已找到 {count} 个'**
  String downloadAuthorEnumerating(int count);

  /// No description provided for @downloadAuthorConfirmBody.
  ///
  /// In zh, this message translates to:
  /// **'将下载该作者的 {works} 个作品，共 {pages} 页。'**
  String downloadAuthorConfirmBody(int works, int pages);

  /// No description provided for @downloadAuthorTruncated.
  ///
  /// In zh, this message translates to:
  /// **'作品过多，仅下载前 {max} 个。'**
  String downloadAuthorTruncated(int max);

  /// No description provided for @downloadAuthorEmpty.
  ///
  /// In zh, this message translates to:
  /// **'该作者没有可下载的作品。'**
  String get downloadAuthorEmpty;

  /// No description provided for @downloadAuthorFailed.
  ///
  /// In zh, this message translates to:
  /// **'枚举作品失败'**
  String get downloadAuthorFailed;

  /// No description provided for @downloadCaption.
  ///
  /// In zh, this message translates to:
  /// **'同时导出作品简介'**
  String get downloadCaption;

  /// No description provided for @downloadCaptionHint.
  ///
  /// In zh, this message translates to:
  /// **'下载插画/漫画时，把标题、作者与简介保存为同名 .txt'**
  String get downloadCaptionHint;

  /// No description provided for @aboutVersion.
  ///
  /// In zh, this message translates to:
  /// **'版本'**
  String get aboutVersion;

  /// No description provided for @aboutCheckUpdate.
  ///
  /// In zh, this message translates to:
  /// **'检查更新'**
  String get aboutCheckUpdate;

  /// No description provided for @aboutCheckingUpdate.
  ///
  /// In zh, this message translates to:
  /// **'正在检查更新…'**
  String get aboutCheckingUpdate;

  /// No description provided for @aboutUpdateAvailable.
  ///
  /// In zh, this message translates to:
  /// **'发现新版本'**
  String get aboutUpdateAvailable;

  /// No description provided for @aboutUpdateOpen.
  ///
  /// In zh, this message translates to:
  /// **'查看'**
  String get aboutUpdateOpen;

  /// No description provided for @aboutExportLogs.
  ///
  /// In zh, this message translates to:
  /// **'导出日志'**
  String get aboutExportLogs;

  /// No description provided for @aboutNoLogs.
  ///
  /// In zh, this message translates to:
  /// **'暂无日志'**
  String get aboutNoLogs;

  /// No description provided for @aboutUpdateNoUpdate.
  ///
  /// In zh, this message translates to:
  /// **'已是最新版本'**
  String get aboutUpdateNoUpdate;

  /// No description provided for @aboutUpdatePrerelease.
  ///
  /// In zh, this message translates to:
  /// **'发现预发布版本，当前稳定通道不会安装'**
  String get aboutUpdatePrerelease;

  /// No description provided for @aboutUpdateDownload.
  ///
  /// In zh, this message translates to:
  /// **'下载并安装'**
  String get aboutUpdateDownload;

  /// No description provided for @aboutUpdateDownloading.
  ///
  /// In zh, this message translates to:
  /// **'正在下载并验证…'**
  String get aboutUpdateDownloading;

  /// No description provided for @aboutUpdateConfirmTitle.
  ///
  /// In zh, this message translates to:
  /// **'确认更新'**
  String get aboutUpdateConfirmTitle;

  /// No description provided for @aboutUpdateConfirmDetail.
  ///
  /// In zh, this message translates to:
  /// **'只会安装通过签名、大小、哈希、包名和签名证书校验的 APK。是否继续？'**
  String get aboutUpdateConfirmDetail;

  /// No description provided for @aboutUpdatePermission.
  ///
  /// In zh, this message translates to:
  /// **'需要允许此来源安装应用，然后再次确认安装。'**
  String get aboutUpdatePermission;

  /// No description provided for @aboutUpdateStarted.
  ///
  /// In zh, this message translates to:
  /// **'已打开系统安装器'**
  String get aboutUpdateStarted;

  /// No description provided for @aboutUpdateStore.
  ///
  /// In zh, this message translates to:
  /// **'此构建由 F-Droid 管理更新。'**
  String get aboutUpdateStore;

  /// No description provided for @aboutUpdateUnavailable.
  ///
  /// In zh, this message translates to:
  /// **'更新检查当前不可用'**
  String get aboutUpdateUnavailable;

  /// No description provided for @aboutUpdateFailed.
  ///
  /// In zh, this message translates to:
  /// **'更新检查或安装失败，请稍后重试'**
  String get aboutUpdateFailed;

  /// No description provided for @aboutUpdateOffline.
  ///
  /// In zh, this message translates to:
  /// **'无法连接更新服务，请检查网络后重试'**
  String get aboutUpdateOffline;

  /// No description provided for @aboutUpdateRateLimited.
  ///
  /// In zh, this message translates to:
  /// **'GitHub 限流，请稍后重试'**
  String get aboutUpdateRateLimited;

  /// No description provided for @aboutUpdateInvalid.
  ///
  /// In zh, this message translates to:
  /// **'更新清单无效，请向开发者反馈'**
  String get aboutUpdateInvalid;

  /// No description provided for @aboutUpdateBusy.
  ///
  /// In zh, this message translates to:
  /// **'已有更新任务进行中'**
  String get aboutUpdateBusy;

  /// No description provided for @aboutUpdateCanceled.
  ///
  /// In zh, this message translates to:
  /// **'已取消更新安装'**
  String get aboutUpdateCanceled;

  /// No description provided for @aboutLicense.
  ///
  /// In zh, this message translates to:
  /// **'许可证'**
  String get aboutLicense;

  /// No description provided for @aboutAttribution.
  ///
  /// In zh, this message translates to:
  /// **'归属'**
  String get aboutAttribution;

  /// No description provided for @aboutSource.
  ///
  /// In zh, this message translates to:
  /// **'项目源码'**
  String get aboutSource;

  /// No description provided for @aboutLicenseText.
  ///
  /// In zh, this message translates to:
  /// **'本项目基于 Pixiv Func 公开源码，遵循 GNU AGPL v3.0。'**
  String get aboutLicenseText;

  /// No description provided for @aboutAttributionText.
  ///
  /// In zh, this message translates to:
  /// **'版权所有及维护：Lopution。'**
  String get aboutAttributionText;

  /// No description provided for @settingsReadFailed.
  ///
  /// In zh, this message translates to:
  /// **'读取设置失败'**
  String get settingsReadFailed;

  /// No description provided for @settingsWriteFailed.
  ///
  /// In zh, this message translates to:
  /// **'设置保存失败'**
  String get settingsWriteFailed;

  /// No description provided for @settingsMutedSummary.
  ///
  /// In zh, this message translates to:
  /// **'{count} 个屏蔽项'**
  String settingsMutedSummary(int count);

  /// No description provided for @settingsDownloadTasksSummary.
  ///
  /// In zh, this message translates to:
  /// **'{count} 个活动任务'**
  String settingsDownloadTasksSummary(int count);

  /// No description provided for @settingsCredentialConfigured.
  ///
  /// In zh, this message translates to:
  /// **'已配置'**
  String get settingsCredentialConfigured;

  /// No description provided for @settingsCredentialNotConfigured.
  ///
  /// In zh, this message translates to:
  /// **'未配置'**
  String get settingsCredentialNotConfigured;

  /// No description provided for @add.
  ///
  /// In zh, this message translates to:
  /// **'添加'**
  String get add;

  /// No description provided for @viewerNoImages.
  ///
  /// In zh, this message translates to:
  /// **'没有可显示的图片'**
  String get viewerNoImages;

  /// No description provided for @detailDownloaded.
  ///
  /// In zh, this message translates to:
  /// **'已下载'**
  String get detailDownloaded;

  /// No description provided for @downloadAll.
  ///
  /// In zh, this message translates to:
  /// **'下载全部'**
  String get downloadAll;

  /// No description provided for @downloadQueuedMessage.
  ///
  /// In zh, this message translates to:
  /// **'已加入下载队列'**
  String get downloadQueuedMessage;

  /// No description provided for @downloadAlreadyQueued.
  ///
  /// In zh, this message translates to:
  /// **'已在下载队列中'**
  String get downloadAlreadyQueued;

  /// No description provided for @downloadSubmissionFailed.
  ///
  /// In zh, this message translates to:
  /// **'下载失败'**
  String get downloadSubmissionFailed;

  /// No description provided for @downloadFailurePermission.
  ///
  /// In zh, this message translates to:
  /// **'缺少存储权限'**
  String get downloadFailurePermission;

  /// No description provided for @downloadFailureResource.
  ///
  /// In zh, this message translates to:
  /// **'设备资源不足或文件过大'**
  String get downloadFailureResource;

  /// No description provided for @downloadFailureOwnership.
  ///
  /// In zh, this message translates to:
  /// **'任务已失效，需重新下载'**
  String get downloadFailureOwnership;

  /// No description provided for @downloadFailureInterrupted.
  ///
  /// In zh, this message translates to:
  /// **'应用重启时下载中断，点重试继续'**
  String get downloadFailureInterrupted;

  /// No description provided for @ugoiraSaveGif.
  ///
  /// In zh, this message translates to:
  /// **'保存 GIF'**
  String get ugoiraSaveGif;

  /// No description provided for @ugoiraLoadCanceled.
  ///
  /// In zh, this message translates to:
  /// **'加载已取消'**
  String get ugoiraLoadCanceled;

  /// No description provided for @ugoiraLoginRequired.
  ///
  /// In zh, this message translates to:
  /// **'请先登录后保存 GIF'**
  String get ugoiraLoginRequired;

  /// No description provided for @ugoiraSaved.
  ///
  /// In zh, this message translates to:
  /// **'GIF 已保存'**
  String get ugoiraSaved;

  /// No description provided for @ugoiraSaveCanceled.
  ///
  /// In zh, this message translates to:
  /// **'GIF 保存已取消'**
  String get ugoiraSaveCanceled;

  /// No description provided for @ugoiraSaveFailed.
  ///
  /// In zh, this message translates to:
  /// **'GIF 保存失败'**
  String get ugoiraSaveFailed;

  /// No description provided for @ugoiraArchiveInvalid.
  ///
  /// In zh, this message translates to:
  /// **'动图压缩包无效'**
  String get ugoiraArchiveInvalid;

  /// No description provided for @ugoiraFrameCorrupt.
  ///
  /// In zh, this message translates to:
  /// **'动图帧损坏'**
  String get ugoiraFrameCorrupt;

  /// No description provided for @ugoiraLoadFailed.
  ///
  /// In zh, this message translates to:
  /// **'动图加载失败'**
  String get ugoiraLoadFailed;

  /// No description provided for @homeRecommended.
  ///
  /// In zh, this message translates to:
  /// **'推荐'**
  String get homeRecommended;

  /// No description provided for @homeRanking.
  ///
  /// In zh, this message translates to:
  /// **'排行'**
  String get homeRanking;

  /// No description provided for @homeMe.
  ///
  /// In zh, this message translates to:
  /// **'我的'**
  String get homeMe;

  /// No description provided for @bookmarkIllust.
  ///
  /// In zh, this message translates to:
  /// **'收藏插画'**
  String get bookmarkIllust;

  /// No description provided for @bookmarkNovel.
  ///
  /// In zh, this message translates to:
  /// **'收藏小说'**
  String get bookmarkNovel;

  /// No description provided for @bookmarkOperationFailed.
  ///
  /// In zh, this message translates to:
  /// **'收藏操作失败'**
  String get bookmarkOperationFailed;

  /// No description provided for @save.
  ///
  /// In zh, this message translates to:
  /// **'保存'**
  String get save;

  /// No description provided for @saved.
  ///
  /// In zh, this message translates to:
  /// **'已保存'**
  String get saved;

  /// No description provided for @retry.
  ///
  /// In zh, this message translates to:
  /// **'重试'**
  String get retry;

  /// No description provided for @refresh.
  ///
  /// In zh, this message translates to:
  /// **'刷新'**
  String get refresh;

  /// No description provided for @relatedWorks.
  ///
  /// In zh, this message translates to:
  /// **'相关作品'**
  String get relatedWorks;

  /// No description provided for @cancel.
  ///
  /// In zh, this message translates to:
  /// **'取消'**
  String get cancel;

  /// No description provided for @confirm.
  ///
  /// In zh, this message translates to:
  /// **'确定'**
  String get confirm;

  /// No description provided for @continueAction.
  ///
  /// In zh, this message translates to:
  /// **'继续'**
  String get continueAction;

  /// No description provided for @errorNetwork.
  ///
  /// In zh, this message translates to:
  /// **'网络连接失败'**
  String get errorNetwork;

  /// No description provided for @errorTimeout.
  ///
  /// In zh, this message translates to:
  /// **'连接超时'**
  String get errorTimeout;

  /// No description provided for @errorRateLimited.
  ///
  /// In zh, this message translates to:
  /// **'请求过于频繁，请稍后重试'**
  String get errorRateLimited;

  /// No description provided for @errorUnauthorized.
  ///
  /// In zh, this message translates to:
  /// **'需要重新登录'**
  String get errorUnauthorized;

  /// No description provided for @errorServer.
  ///
  /// In zh, this message translates to:
  /// **'服务器错误'**
  String get errorServer;

  /// No description provided for @errorNotFound.
  ///
  /// In zh, this message translates to:
  /// **'内容不存在或已被删除'**
  String get errorNotFound;

  /// No description provided for @errorParse.
  ///
  /// In zh, this message translates to:
  /// **'响应无法解析'**
  String get errorParse;

  /// No description provided for @errorStorage.
  ///
  /// In zh, this message translates to:
  /// **'存储错误'**
  String get errorStorage;

  /// No description provided for @errorUnknown.
  ///
  /// In zh, this message translates to:
  /// **'未知错误'**
  String get errorUnknown;

  /// No description provided for @errorDetails.
  ///
  /// In zh, this message translates to:
  /// **'详情'**
  String get errorDetails;

  /// No description provided for @errorDetailsCopy.
  ///
  /// In zh, this message translates to:
  /// **'复制'**
  String get errorDetailsCopy;

  /// No description provided for @errorDetailsCopied.
  ///
  /// In zh, this message translates to:
  /// **'已复制'**
  String get errorDetailsCopied;

  /// No description provided for @errorWithReason.
  ///
  /// In zh, this message translates to:
  /// **'{action}：{reason}'**
  String errorWithReason(String action, String reason);

  /// A labelled value in running text, e.g. a setting and its current value.
  ///
  /// In zh, this message translates to:
  /// **'{label}：{value}'**
  String labelValue(String label, String value);

  /// No description provided for @rankingDay.
  ///
  /// In zh, this message translates to:
  /// **'每日'**
  String get rankingDay;

  /// No description provided for @rankingDayR18.
  ///
  /// In zh, this message translates to:
  /// **'每日（R-18）'**
  String get rankingDayR18;

  /// No description provided for @rankingDayMale.
  ///
  /// In zh, this message translates to:
  /// **'每日（男性欢迎）'**
  String get rankingDayMale;

  /// No description provided for @rankingDayMaleR18.
  ///
  /// In zh, this message translates to:
  /// **'每日（男性欢迎 & R-18）'**
  String get rankingDayMaleR18;

  /// No description provided for @rankingDayFemale.
  ///
  /// In zh, this message translates to:
  /// **'每日（女性欢迎）'**
  String get rankingDayFemale;

  /// No description provided for @rankingDayFemaleR18.
  ///
  /// In zh, this message translates to:
  /// **'每日（女性欢迎 & R-18）'**
  String get rankingDayFemaleR18;

  /// No description provided for @rankingWeek.
  ///
  /// In zh, this message translates to:
  /// **'每周'**
  String get rankingWeek;

  /// No description provided for @rankingWeekR18.
  ///
  /// In zh, this message translates to:
  /// **'每周（R-18）'**
  String get rankingWeekR18;

  /// No description provided for @rankingWeekOriginal.
  ///
  /// In zh, this message translates to:
  /// **'每周（原创）'**
  String get rankingWeekOriginal;

  /// No description provided for @rankingWeekRookie.
  ///
  /// In zh, this message translates to:
  /// **'每周（新人）'**
  String get rankingWeekRookie;

  /// No description provided for @rankingWeekAi.
  ///
  /// In zh, this message translates to:
  /// **'每周（AI）'**
  String get rankingWeekAi;

  /// No description provided for @rankingWeekAiR18.
  ///
  /// In zh, this message translates to:
  /// **'每周（AI & R-18）'**
  String get rankingWeekAiR18;

  /// No description provided for @rankingWeekR18G.
  ///
  /// In zh, this message translates to:
  /// **'每周（R-18G）'**
  String get rankingWeekR18G;

  /// No description provided for @rankingMonth.
  ///
  /// In zh, this message translates to:
  /// **'每月'**
  String get rankingMonth;

  /// No description provided for @rankingEmpty.
  ///
  /// In zh, this message translates to:
  /// **'暂无榜单内容'**
  String get rankingEmpty;

  /// Tooltip of the ranking date button
  ///
  /// In zh, this message translates to:
  /// **'选择日期'**
  String get rankingPickDate;

  /// Bar under the ranking tabs while a past date is shown
  ///
  /// In zh, this message translates to:
  /// **'{date} 的排行'**
  String rankingDateLabel(String date);

  /// Leaves a past ranking date
  ///
  /// In zh, this message translates to:
  /// **'回到最新'**
  String get rankingBackToLatest;

  /// No description provided for @rankingLoadFailed.
  ///
  /// In zh, this message translates to:
  /// **'{mode}加载失败'**
  String rankingLoadFailed(String mode);

  /// No description provided for @rankingLoadMoreFailed.
  ///
  /// In zh, this message translates to:
  /// **'加载更多失败'**
  String get rankingLoadMoreFailed;

  /// No description provided for @profileBookmarked.
  ///
  /// In zh, this message translates to:
  /// **'收藏'**
  String get profileBookmarked;

  /// No description provided for @profileFollowing.
  ///
  /// In zh, this message translates to:
  /// **'关注'**
  String get profileFollowing;

  /// No description provided for @profileFans.
  ///
  /// In zh, this message translates to:
  /// **'粉丝'**
  String get profileFans;

  /// No description provided for @profileMyPixiv.
  ///
  /// In zh, this message translates to:
  /// **'好P友'**
  String get profileMyPixiv;

  /// Profile work tab: the total number of works (or series) above the list. count is already formatted.
  ///
  /// In zh, this message translates to:
  /// **'共 {count} 件'**
  String profileWorksTotal(String count);

  /// Own bookmarks filter button when no tag is picked.
  ///
  /// In zh, this message translates to:
  /// **'标签：全部'**
  String get profileTagFilterAll;

  /// Own bookmarks filter button showing the picked tag.
  ///
  /// In zh, this message translates to:
  /// **'标签：{tag}'**
  String profileTagFilter(String tag);

  /// Tag filter menu: no tag filter.
  ///
  /// In zh, this message translates to:
  /// **'全部'**
  String get profileTagAny;

  /// Tag filter menu: opens the full bookmark tag list.
  ///
  /// In zh, this message translates to:
  /// **'更多标签…'**
  String get profileTagMore;

  /// No description provided for @profileAbout.
  ///
  /// In zh, this message translates to:
  /// **'关于'**
  String get profileAbout;

  /// No description provided for @profileIllust.
  ///
  /// In zh, this message translates to:
  /// **'插画'**
  String get profileIllust;

  /// No description provided for @profileManga.
  ///
  /// In zh, this message translates to:
  /// **'漫画'**
  String get profileManga;

  /// No description provided for @profileNovel.
  ///
  /// In zh, this message translates to:
  /// **'小说'**
  String get profileNovel;

  /// No description provided for @searchTitle.
  ///
  /// In zh, this message translates to:
  /// **'搜索'**
  String get searchTitle;

  /// No description provided for @searchHint.
  ///
  /// In zh, this message translates to:
  /// **'搜索作品、用户或标签'**
  String get searchHint;

  /// No description provided for @searchBarHint.
  ///
  /// In zh, this message translates to:
  /// **'搜索'**
  String get searchBarHint;

  /// No description provided for @searchReverseImage.
  ///
  /// In zh, this message translates to:
  /// **'反向搜图'**
  String get searchReverseImage;

  /// No description provided for @searchTrending.
  ///
  /// In zh, this message translates to:
  /// **'热门标签'**
  String get searchTrending;

  /// No description provided for @searchNoTrending.
  ///
  /// In zh, this message translates to:
  /// **'暂无热门标签'**
  String get searchNoTrending;

  /// No description provided for @searchTrendingFailed.
  ///
  /// In zh, this message translates to:
  /// **'热门标签加载失败'**
  String get searchTrendingFailed;

  /// No description provided for @searchIllustManga.
  ///
  /// In zh, this message translates to:
  /// **'插画 & 漫画'**
  String get searchIllustManga;

  /// No description provided for @searchNovel.
  ///
  /// In zh, this message translates to:
  /// **'小说'**
  String get searchNovel;

  /// No description provided for @searchUser.
  ///
  /// In zh, this message translates to:
  /// **'用户'**
  String get searchUser;

  /// No description provided for @searchCancel.
  ///
  /// In zh, this message translates to:
  /// **'取消'**
  String get searchCancel;

  /// No description provided for @searchSubmit.
  ///
  /// In zh, this message translates to:
  /// **'搜索'**
  String get searchSubmit;

  /// No description provided for @searchClear.
  ///
  /// In zh, this message translates to:
  /// **'清除'**
  String get searchClear;

  /// No description provided for @contentLoading.
  ///
  /// In zh, this message translates to:
  /// **'正在加载'**
  String get contentLoading;

  /// No description provided for @searchLoading.
  ///
  /// In zh, this message translates to:
  /// **'正在搜索'**
  String get searchLoading;

  /// No description provided for @searchNoResults.
  ///
  /// In zh, this message translates to:
  /// **'暂无搜索结果'**
  String get searchNoResults;

  /// No description provided for @searchLoadFailed.
  ///
  /// In zh, this message translates to:
  /// **'搜索失败'**
  String get searchLoadFailed;

  /// No description provided for @searchLoadMoreFailed.
  ///
  /// In zh, this message translates to:
  /// **'加载更多搜索结果失败'**
  String get searchLoadMoreFailed;

  /// No description provided for @searchRetry.
  ///
  /// In zh, this message translates to:
  /// **'重试'**
  String get searchRetry;

  /// No description provided for @searchRefreshFailed.
  ///
  /// In zh, this message translates to:
  /// **'刷新失败'**
  String get searchRefreshFailed;

  /// No description provided for @searchInputEmpty.
  ///
  /// In zh, this message translates to:
  /// **'请输入搜索内容'**
  String get searchInputEmpty;

  /// No description provided for @searchReversePick.
  ///
  /// In zh, this message translates to:
  /// **'选择图片'**
  String get searchReversePick;

  /// No description provided for @searchReversePreparing.
  ///
  /// In zh, this message translates to:
  /// **'正在准备图片…'**
  String get searchReversePreparing;

  /// No description provided for @searchReverseSearching.
  ///
  /// In zh, this message translates to:
  /// **'正在搜索…'**
  String get searchReverseSearching;

  /// No description provided for @searchReverseCancel.
  ///
  /// In zh, this message translates to:
  /// **'取消'**
  String get searchReverseCancel;

  /// No description provided for @searchReverseUse.
  ///
  /// In zh, this message translates to:
  /// **'开始反向搜图'**
  String get searchReverseUse;

  /// No description provided for @searchReverseRetry.
  ///
  /// In zh, this message translates to:
  /// **'重新选择'**
  String get searchReverseRetry;

  /// No description provided for @searchReverseReady.
  ///
  /// In zh, this message translates to:
  /// **'图片已准备好'**
  String get searchReverseReady;

  /// No description provided for @searchReverseNoResults.
  ///
  /// In zh, this message translates to:
  /// **'没有找到匹配结果'**
  String get searchReverseNoResults;

  /// No description provided for @searchReverseIntentFailed.
  ///
  /// In zh, this message translates to:
  /// **'分享的图片无法使用'**
  String get searchReverseIntentFailed;

  /// No description provided for @searchReverseOpenFailed.
  ///
  /// In zh, this message translates to:
  /// **'无法打开来源链接'**
  String get searchReverseOpenFailed;

  /// No description provided for @searchReverseRateLimited.
  ///
  /// In zh, this message translates to:
  /// **'搜索过于频繁，请稍后再试'**
  String get searchReverseRateLimited;

  /// No description provided for @searchReverseRateLimitedWait.
  ///
  /// In zh, this message translates to:
  /// **'约 {seconds} 秒后可重试'**
  String searchReverseRateLimitedWait(int seconds);

  /// No description provided for @searchReverseDailyLimit.
  ///
  /// In zh, this message translates to:
  /// **'今日匿名搜索额度已用完，明天再试'**
  String get searchReverseDailyLimit;

  /// No description provided for @searchReverseChallenge.
  ///
  /// In zh, this message translates to:
  /// **'{engine} 要求人机验证；可以在网页中完成验证后搜索'**
  String searchReverseChallenge(String engine);

  /// No description provided for @searchReversePageLoadFailed.
  ///
  /// In zh, this message translates to:
  /// **'结果页加载失败'**
  String get searchReversePageLoadFailed;

  /// No description provided for @searchReverseUploadTapHint.
  ///
  /// In zh, this message translates to:
  /// **'点按页面中的上传按钮开始搜索，已选图片会自动填入。'**
  String get searchReverseUploadTapHint;

  /// No description provided for @searchReverseUploadPickHint.
  ///
  /// In zh, this message translates to:
  /// **'请在页面的文件选择框中重新选择同一张图片。'**
  String get searchReverseUploadPickHint;

  /// No description provided for @searchReverseRetrySameEngine.
  ///
  /// In zh, this message translates to:
  /// **'重试当前引擎'**
  String get searchReverseRetrySameEngine;

  /// No description provided for @searchReverseEngineUnsupported.
  ///
  /// In zh, this message translates to:
  /// **'当前图片不满足该引擎的输入限制'**
  String get searchReverseEngineUnsupported;

  /// No description provided for @searchReverseIntro.
  ///
  /// In zh, this message translates to:
  /// **'选择图片后将上传到所选引擎进行反向检索；结果页在应用内打开。'**
  String get searchReverseIntro;

  /// No description provided for @searchReverseFailed.
  ///
  /// In zh, this message translates to:
  /// **'搜索失败'**
  String get searchReverseFailed;

  /// No description provided for @searchReverseDone.
  ///
  /// In zh, this message translates to:
  /// **'已完成'**
  String get searchReverseDone;

  /// No description provided for @searchReverseEngineSwitch.
  ///
  /// In zh, this message translates to:
  /// **'切换引擎'**
  String get searchReverseEngineSwitch;

  /// No description provided for @searchReverseEngineUnavailable.
  ///
  /// In zh, this message translates to:
  /// **'{engine} 暂时无法使用'**
  String searchReverseEngineUnavailable(String engine);

  /// No description provided for @searchReverseNetwork.
  ///
  /// In zh, this message translates to:
  /// **'网络连接失败，请检查网络后重试'**
  String get searchReverseNetwork;

  /// No description provided for @searchReverseBadResponse.
  ///
  /// In zh, this message translates to:
  /// **'{engine} 返回了无法识别的页面'**
  String searchReverseBadResponse(String engine);

  /// No description provided for @searchReverseStopped.
  ///
  /// In zh, this message translates to:
  /// **'搜索已停止'**
  String get searchReverseStopped;

  /// No description provided for @searchReverseImageFormat.
  ///
  /// In zh, this message translates to:
  /// **'不支持这种图片格式，请选择 PNG、JPEG、GIF 或 WebP'**
  String get searchReverseImageFormat;

  /// No description provided for @searchReverseImageTooLarge.
  ///
  /// In zh, this message translates to:
  /// **'图片太大，无法处理'**
  String get searchReverseImageTooLarge;

  /// No description provided for @searchReverseImagePermission.
  ///
  /// In zh, this message translates to:
  /// **'没有读取这张图片的权限，请重新选择'**
  String get searchReverseImagePermission;

  /// No description provided for @searchReverseImageUnreadable.
  ///
  /// In zh, this message translates to:
  /// **'无法读取这张图片，请重新选择'**
  String get searchReverseImageUnreadable;

  /// No description provided for @searchReverseCleanupFailed.
  ///
  /// In zh, this message translates to:
  /// **'临时图片清理失败'**
  String get searchReverseCleanupFailed;

  /// No description provided for @searchReversePickerUnavailable.
  ///
  /// In zh, this message translates to:
  /// **'此设备无法选择图片'**
  String get searchReversePickerUnavailable;

  /// No description provided for @searchReversePrivacyNote.
  ///
  /// In zh, this message translates to:
  /// **'图片只会上传到所选引擎，离开本页即删除'**
  String get searchReversePrivacyNote;

  /// No description provided for @searchReverseOpenInBrowser.
  ///
  /// In zh, this message translates to:
  /// **'在网页中搜索'**
  String get searchReverseOpenInBrowser;

  /// No description provided for @searchReverseTryEngine.
  ///
  /// In zh, this message translates to:
  /// **'换用 {engine} 搜索'**
  String searchReverseTryEngine(String engine);

  /// No description provided for @searchReverseAllEnginesTried.
  ///
  /// In zh, this message translates to:
  /// **'所有引擎都没有找到匹配结果'**
  String get searchReverseAllEnginesTried;

  /// No description provided for @searchFilters.
  ///
  /// In zh, this message translates to:
  /// **'筛选'**
  String get searchFilters;

  /// No description provided for @searchFiltersActive.
  ///
  /// In zh, this message translates to:
  /// **'筛选（已启用 {count} 项）'**
  String searchFiltersActive(int count);

  /// No description provided for @searchReset.
  ///
  /// In zh, this message translates to:
  /// **'重置'**
  String get searchReset;

  /// No description provided for @searchApply.
  ///
  /// In zh, this message translates to:
  /// **'应用'**
  String get searchApply;

  /// No description provided for @searchTarget.
  ///
  /// In zh, this message translates to:
  /// **'搜索范围'**
  String get searchTarget;

  /// No description provided for @searchPartialTags.
  ///
  /// In zh, this message translates to:
  /// **'标签部分匹配'**
  String get searchPartialTags;

  /// No description provided for @searchExactTags.
  ///
  /// In zh, this message translates to:
  /// **'标签完全匹配'**
  String get searchExactTags;

  /// No description provided for @searchTitleCaption.
  ///
  /// In zh, this message translates to:
  /// **'标题和简介'**
  String get searchTitleCaption;

  /// No description provided for @searchTargetText.
  ///
  /// In zh, this message translates to:
  /// **'正文'**
  String get searchTargetText;

  /// No description provided for @searchTargetKeyword.
  ///
  /// In zh, this message translates to:
  /// **'关键词'**
  String get searchTargetKeyword;

  /// No description provided for @searchSort.
  ///
  /// In zh, this message translates to:
  /// **'排序'**
  String get searchSort;

  /// No description provided for @searchDateDesc.
  ///
  /// In zh, this message translates to:
  /// **'最新发布'**
  String get searchDateDesc;

  /// No description provided for @searchDateAsc.
  ///
  /// In zh, this message translates to:
  /// **'最早发布'**
  String get searchDateAsc;

  /// No description provided for @searchPopularDesc.
  ///
  /// In zh, this message translates to:
  /// **'热门排序'**
  String get searchPopularDesc;

  /// No description provided for @searchPopularMaleDesc.
  ///
  /// In zh, this message translates to:
  /// **'男性向人气'**
  String get searchPopularMaleDesc;

  /// No description provided for @searchPopularFemaleDesc.
  ///
  /// In zh, this message translates to:
  /// **'女性向人气'**
  String get searchPopularFemaleDesc;

  /// No description provided for @searchAiSection.
  ///
  /// In zh, this message translates to:
  /// **'AI 作品'**
  String get searchAiSection;

  /// No description provided for @searchAiAll.
  ///
  /// In zh, this message translates to:
  /// **'全部'**
  String get searchAiAll;

  /// No description provided for @searchAiExclude.
  ///
  /// In zh, this message translates to:
  /// **'排除 AI'**
  String get searchAiExclude;

  /// No description provided for @searchAiOnly.
  ///
  /// In zh, this message translates to:
  /// **'仅 AI'**
  String get searchAiOnly;

  /// No description provided for @searchBookmarkSection.
  ///
  /// In zh, this message translates to:
  /// **'收藏数'**
  String get searchBookmarkSection;

  /// No description provided for @searchMin.
  ///
  /// In zh, this message translates to:
  /// **'最小'**
  String get searchMin;

  /// No description provided for @searchMax.
  ///
  /// In zh, this message translates to:
  /// **'最大'**
  String get searchMax;

  /// No description provided for @searchRatioSection.
  ///
  /// In zh, this message translates to:
  /// **'纵横比'**
  String get searchRatioSection;

  /// No description provided for @searchRatioAny.
  ///
  /// In zh, this message translates to:
  /// **'不限'**
  String get searchRatioAny;

  /// No description provided for @searchRatioLandscape.
  ///
  /// In zh, this message translates to:
  /// **'横向'**
  String get searchRatioLandscape;

  /// No description provided for @searchRatioPortrait.
  ///
  /// In zh, this message translates to:
  /// **'纵向'**
  String get searchRatioPortrait;

  /// No description provided for @searchRatioSquare.
  ///
  /// In zh, this message translates to:
  /// **'方形'**
  String get searchRatioSquare;

  /// No description provided for @searchContentSection.
  ///
  /// In zh, this message translates to:
  /// **'作品类别'**
  String get searchContentSection;

  /// No description provided for @searchContentAll.
  ///
  /// In zh, this message translates to:
  /// **'插画·漫画·动图'**
  String get searchContentAll;

  /// No description provided for @searchContentIllustUgoira.
  ///
  /// In zh, this message translates to:
  /// **'插画·动图'**
  String get searchContentIllustUgoira;

  /// No description provided for @searchContentIllust.
  ///
  /// In zh, this message translates to:
  /// **'仅插画'**
  String get searchContentIllust;

  /// No description provided for @searchContentUgoira.
  ///
  /// In zh, this message translates to:
  /// **'仅动图'**
  String get searchContentUgoira;

  /// No description provided for @searchContentManga.
  ///
  /// In zh, this message translates to:
  /// **'仅漫画'**
  String get searchContentManga;

  /// No description provided for @searchResolutionSection.
  ///
  /// In zh, this message translates to:
  /// **'分辨率'**
  String get searchResolutionSection;

  /// No description provided for @searchWidth.
  ///
  /// In zh, this message translates to:
  /// **'宽'**
  String get searchWidth;

  /// No description provided for @searchHeight.
  ///
  /// In zh, this message translates to:
  /// **'高'**
  String get searchHeight;

  /// No description provided for @searchTextLength.
  ///
  /// In zh, this message translates to:
  /// **'正文长度'**
  String get searchTextLength;

  /// No description provided for @searchChars.
  ///
  /// In zh, this message translates to:
  /// **'字数'**
  String get searchChars;

  /// No description provided for @searchOriginalOnly.
  ///
  /// In zh, this message translates to:
  /// **'仅原创'**
  String get searchOriginalOnly;

  /// No description provided for @searchSetDefault.
  ///
  /// In zh, this message translates to:
  /// **'设为默认'**
  String get searchSetDefault;

  /// Filter chip: a lower bound only, e.g. bookmarks or width
  ///
  /// In zh, this message translates to:
  /// **'{label} {value} 以上'**
  String searchRangeAtLeast(String label, String value);

  /// Filter chip: an upper bound only
  ///
  /// In zh, this message translates to:
  /// **'{label} {value} 以下'**
  String searchRangeAtMost(String label, String value);

  /// Filter chip: both bounds
  ///
  /// In zh, this message translates to:
  /// **'{label} {min}–{max}'**
  String searchRangeBetween(String label, String min, String max);

  /// Filter chip: start date only
  ///
  /// In zh, this message translates to:
  /// **'{date} 起'**
  String searchDateFrom(String date);

  /// Filter chip: end date only
  ///
  /// In zh, this message translates to:
  /// **'截至 {date}'**
  String searchDateUntil(String date);

  /// Filter chip: a date range
  ///
  /// In zh, this message translates to:
  /// **'{start} – {end}'**
  String searchDateBetween(String start, String end);

  /// No description provided for @searchDuration.
  ///
  /// In zh, this message translates to:
  /// **'发布时间'**
  String get searchDuration;

  /// No description provided for @searchAllTime.
  ///
  /// In zh, this message translates to:
  /// **'不限时间'**
  String get searchAllTime;

  /// No description provided for @searchWithinDay.
  ///
  /// In zh, this message translates to:
  /// **'一天内'**
  String get searchWithinDay;

  /// No description provided for @searchWithinWeek.
  ///
  /// In zh, this message translates to:
  /// **'一周内'**
  String get searchWithinWeek;

  /// No description provided for @searchWithinMonth.
  ///
  /// In zh, this message translates to:
  /// **'一个月内'**
  String get searchWithinMonth;

  /// No description provided for @searchStartDate.
  ///
  /// In zh, this message translates to:
  /// **'开始日期'**
  String get searchStartDate;

  /// No description provided for @searchEndDate.
  ///
  /// In zh, this message translates to:
  /// **'结束日期'**
  String get searchEndDate;

  /// No description provided for @searchInvalidDateRange.
  ///
  /// In zh, this message translates to:
  /// **'开始日期不能晚于结束日期'**
  String get searchInvalidDateRange;

  /// No description provided for @searchInvalidBoundRange.
  ///
  /// In zh, this message translates to:
  /// **'最小值不能大于最大值'**
  String get searchInvalidBoundRange;

  /// No description provided for @searchPopularPreviewHint.
  ///
  /// In zh, this message translates to:
  /// **'未开通会员，热门排序将使用人气预览结果'**
  String get searchPopularPreviewHint;

  /// No description provided for @searchNoSuggestions.
  ///
  /// In zh, this message translates to:
  /// **'没有匹配建议'**
  String get searchNoSuggestions;

  /// No description provided for @searchSuggestionFill.
  ///
  /// In zh, this message translates to:
  /// **'填入搜索框'**
  String get searchSuggestionFill;

  /// No description provided for @searchSuggestionSearch.
  ///
  /// In zh, this message translates to:
  /// **'立即搜索'**
  String get searchSuggestionSearch;

  /// No description provided for @searchHistoryTitle.
  ///
  /// In zh, this message translates to:
  /// **'搜索历史'**
  String get searchHistoryTitle;

  /// No description provided for @searchHistoryClear.
  ///
  /// In zh, this message translates to:
  /// **'清除全部'**
  String get searchHistoryClear;

  /// No description provided for @searchHistoryClearConfirm.
  ///
  /// In zh, this message translates to:
  /// **'清除全部搜索历史？'**
  String get searchHistoryClearConfirm;

  /// No description provided for @searchHistoryRemoved.
  ///
  /// In zh, this message translates to:
  /// **'已从搜索历史中删除'**
  String get searchHistoryRemoved;

  /// No description provided for @searchHistoryRemove.
  ///
  /// In zh, this message translates to:
  /// **'从搜索历史中删除'**
  String get searchHistoryRemove;

  /// No description provided for @searchOpenIllust.
  ///
  /// In zh, this message translates to:
  /// **'打开插画/漫画 ID {id}'**
  String searchOpenIllust(int id);

  /// No description provided for @searchOpenNovel.
  ///
  /// In zh, this message translates to:
  /// **'打开小说 ID {id}'**
  String searchOpenNovel(int id);

  /// No description provided for @searchOpenUser.
  ///
  /// In zh, this message translates to:
  /// **'打开用户 ID {id}'**
  String searchOpenUser(int id);

  /// No description provided for @searchModifyQuery.
  ///
  /// In zh, this message translates to:
  /// **'修改搜索'**
  String get searchModifyQuery;

  /// No description provided for @searchUserAccount.
  ///
  /// In zh, this message translates to:
  /// **'账号'**
  String get searchUserAccount;

  /// No description provided for @illustDetailTitle.
  ///
  /// In zh, this message translates to:
  /// **'作品详情'**
  String get illustDetailTitle;

  /// The metadata line's screen-reader text when the posting date is unknown.
  ///
  /// In zh, this message translates to:
  /// **'{views} 次浏览，{bookmarks} 次收藏'**
  String detailMetaCountsSemantics(String views, String bookmarks);

  /// Folds an expanded illustration set back to its first image.
  ///
  /// In zh, this message translates to:
  /// **'收起'**
  String get detailCollapsePages;

  /// Label under the view count in the artwork stats card.
  ///
  /// In zh, this message translates to:
  /// **'浏览'**
  String get detailStatViews;

  /// Label under the bookmark count in the artwork stats card.
  ///
  /// In zh, this message translates to:
  /// **'收藏'**
  String get detailStatBookmarks;

  /// Section heading over the artwork caption.
  ///
  /// In zh, this message translates to:
  /// **'简介'**
  String get detailSectionCaption;

  /// Section heading over the artwork tags.
  ///
  /// In zh, this message translates to:
  /// **'标签'**
  String get detailSectionTags;

  /// Action beside a detail-page section heading; opens the full list.
  ///
  /// In zh, this message translates to:
  /// **'查看全部'**
  String get detailViewAll;

  /// Section heading over a strip of the author's other works.
  ///
  /// In zh, this message translates to:
  /// **'作者的其他作品'**
  String get detailSectionAuthorWorks;

  /// The author's other-works strip when the author has no other work.
  ///
  /// In zh, this message translates to:
  /// **'暂无其他作品'**
  String get detailAuthorNoOtherWorks;

  /// The author's other-works strip failed to load.
  ///
  /// In zh, this message translates to:
  /// **'作者作品加载失败'**
  String get detailAuthorWorksLoadFailed;

  /// Feed tail button after automatic paging paused: loads the next pages.
  ///
  /// In zh, this message translates to:
  /// **'继续加载'**
  String get feedContinueLoading;

  /// Marker beside the work author's name in its comments
  ///
  /// In zh, this message translates to:
  /// **'作者'**
  String get commentAuthorBadge;

  /// Comment action that opens the replies when the reply count is unknown
  ///
  /// In zh, this message translates to:
  /// **'查看回复'**
  String get commentShowReplies;

  /// Spoken part of a novel list row: its bookmark count, already formatted (e.g. 1.2万)
  ///
  /// In zh, this message translates to:
  /// **'{count} 次收藏'**
  String novelEntryBookmarks(String count);

  /// Under the first image of a multi-image illustration; shows the rest.
  ///
  /// In zh, this message translates to:
  /// **'展开全部 {count} 张'**
  String detailExpandPages(int count);

  /// No description provided for @illustDetailOpenLinkFailed.
  ///
  /// In zh, this message translates to:
  /// **'无法打开链接'**
  String get illustDetailOpenLinkFailed;

  /// No description provided for @illustDetailRestricted.
  ///
  /// In zh, this message translates to:
  /// **'该作品已被删除或受限（ID: {id}）'**
  String illustDetailRestricted(int id);

  /// No description provided for @illustDetailNotFound.
  ///
  /// In zh, this message translates to:
  /// **'作品不存在或已被删除'**
  String get illustDetailNotFound;

  /// No description provided for @illustDetailLoadFailed.
  ///
  /// In zh, this message translates to:
  /// **'作品加载失败'**
  String get illustDetailLoadFailed;

  /// No description provided for @commentTitle.
  ///
  /// In zh, this message translates to:
  /// **'评论'**
  String get commentTitle;

  /// No description provided for @commentInput.
  ///
  /// In zh, this message translates to:
  /// **'添加评论'**
  String get commentInput;

  /// No description provided for @commentReply.
  ///
  /// In zh, this message translates to:
  /// **'回复'**
  String get commentReply;

  /// No description provided for @commentReplyTo.
  ///
  /// In zh, this message translates to:
  /// **'回复给'**
  String get commentReplyTo;

  /// No description provided for @commentCancelReply.
  ///
  /// In zh, this message translates to:
  /// **'取消回复'**
  String get commentCancelReply;

  /// No description provided for @commentSend.
  ///
  /// In zh, this message translates to:
  /// **'发送'**
  String get commentSend;

  /// No description provided for @commentDelete.
  ///
  /// In zh, this message translates to:
  /// **'删除评论'**
  String get commentDelete;

  /// No description provided for @commentDeleteConfirm.
  ///
  /// In zh, this message translates to:
  /// **'确定删除这条评论吗？'**
  String get commentDeleteConfirm;

  /// No description provided for @commentDeleteFailed.
  ///
  /// In zh, this message translates to:
  /// **'删除评论失败'**
  String get commentDeleteFailed;

  /// No description provided for @commentSendFailed.
  ///
  /// In zh, this message translates to:
  /// **'发送评论失败'**
  String get commentSendFailed;

  /// No description provided for @commentLoadFailed.
  ///
  /// In zh, this message translates to:
  /// **'评论加载失败'**
  String get commentLoadFailed;

  /// No description provided for @relatedLoadFailed.
  ///
  /// In zh, this message translates to:
  /// **'相关作品加载失败'**
  String get relatedLoadFailed;

  /// No description provided for @commentLoadMoreFailed.
  ///
  /// In zh, this message translates to:
  /// **'加载更多评论失败'**
  String get commentLoadMoreFailed;

  /// No description provided for @commentNoResults.
  ///
  /// In zh, this message translates to:
  /// **'暂无评论'**
  String get commentNoResults;

  /// No description provided for @commentDeletedUser.
  ///
  /// In zh, this message translates to:
  /// **'已注销用户'**
  String get commentDeletedUser;

  /// No description provided for @commentReplies.
  ///
  /// In zh, this message translates to:
  /// **'回复'**
  String get commentReplies;

  /// Comment action that opens the replies to a comment
  ///
  /// In zh, this message translates to:
  /// **'查看 {count} 条回复'**
  String commentViewReplies(int count);

  /// Tooltip of a comment's overflow menu (translate, delete)
  ///
  /// In zh, this message translates to:
  /// **'更多操作'**
  String get commentMoreActions;

  /// No description provided for @translateAction.
  ///
  /// In zh, this message translates to:
  /// **'翻译'**
  String get translateAction;

  /// No description provided for @translationResult.
  ///
  /// In zh, this message translates to:
  /// **'翻译结果'**
  String get translationResult;

  /// No description provided for @translationUnavailable.
  ///
  /// In zh, this message translates to:
  /// **'翻译未开启'**
  String get translationUnavailable;

  /// No description provided for @translationFailed.
  ///
  /// In zh, this message translates to:
  /// **'翻译失败'**
  String get translationFailed;

  /// No description provided for @translationInvalidCredentials.
  ///
  /// In zh, this message translates to:
  /// **'翻译凭据无效或登录已失效'**
  String get translationInvalidCredentials;

  /// No description provided for @translationRateLimited.
  ///
  /// In zh, this message translates to:
  /// **'翻译过于频繁或额度已用完'**
  String get translationRateLimited;

  /// No description provided for @translationRejected.
  ///
  /// In zh, this message translates to:
  /// **'翻译服务拒绝了这段内容'**
  String get translationRejected;

  /// No description provided for @translationNotConfigured.
  ///
  /// In zh, this message translates to:
  /// **'翻译服务还没配置好（缺少凭据或未登录）'**
  String get translationNotConfigured;

  /// No description provided for @translationOpenSettings.
  ///
  /// In zh, this message translates to:
  /// **'去设置'**
  String get translationOpenSettings;

  /// No description provided for @translationHide.
  ///
  /// In zh, this message translates to:
  /// **'收起翻译'**
  String get translationHide;

  /// No description provided for @translationCopied.
  ///
  /// In zh, this message translates to:
  /// **'已复制译文'**
  String get translationCopied;

  /// No description provided for @commentEmoji.
  ///
  /// In zh, this message translates to:
  /// **'Emoji'**
  String get commentEmoji;

  /// No description provided for @commentSending.
  ///
  /// In zh, this message translates to:
  /// **'发送中'**
  String get commentSending;

  /// No description provided for @commentStampLabel.
  ///
  /// In zh, this message translates to:
  /// **'贴图 {id}'**
  String commentStampLabel(int id);

  /// No description provided for @commentStamps.
  ///
  /// In zh, this message translates to:
  /// **'Stamp'**
  String get commentStamps;

  /// No description provided for @commentPermissionDenied.
  ///
  /// In zh, this message translates to:
  /// **'只能删除自己的评论'**
  String get commentPermissionDenied;

  /// No description provided for @newTitle.
  ///
  /// In zh, this message translates to:
  /// **'新作'**
  String get newTitle;

  /// No description provided for @newFollowing.
  ///
  /// In zh, this message translates to:
  /// **'关注'**
  String get newFollowing;

  /// No description provided for @newEveryone.
  ///
  /// In zh, this message translates to:
  /// **'大家'**
  String get newEveryone;

  /// No description provided for @newMyPixiv.
  ///
  /// In zh, this message translates to:
  /// **'好P友'**
  String get newMyPixiv;

  /// No description provided for @newNovels.
  ///
  /// In zh, this message translates to:
  /// **'小说新作'**
  String get newNovels;

  /// No description provided for @recommendedIllust.
  ///
  /// In zh, this message translates to:
  /// **'插画'**
  String get recommendedIllust;

  /// No description provided for @recommendedManga.
  ///
  /// In zh, this message translates to:
  /// **'漫画'**
  String get recommendedManga;

  /// No description provided for @recommendedNovel.
  ///
  /// In zh, this message translates to:
  /// **'小说'**
  String get recommendedNovel;

  /// No description provided for @recommendedUser.
  ///
  /// In zh, this message translates to:
  /// **'用户'**
  String get recommendedUser;

  /// No description provided for @recommendedEmpty.
  ///
  /// In zh, this message translates to:
  /// **'暂无推荐内容'**
  String get recommendedEmpty;

  /// No description provided for @recommendedLoadFailed.
  ///
  /// In zh, this message translates to:
  /// **'推荐加载失败'**
  String get recommendedLoadFailed;

  /// No description provided for @recommendedLoadMoreFailed.
  ///
  /// In zh, this message translates to:
  /// **'加载更多失败'**
  String get recommendedLoadMoreFailed;

  /// No description provided for @recommendedEnd.
  ///
  /// In zh, this message translates to:
  /// **'没有更多了'**
  String get recommendedEnd;

  /// No description provided for @newLoading.
  ///
  /// In zh, this message translates to:
  /// **'正在加载新作'**
  String get newLoading;

  /// No description provided for @newEmpty.
  ///
  /// In zh, this message translates to:
  /// **'暂无内容'**
  String get newEmpty;

  /// No description provided for @newLoadFailed.
  ///
  /// In zh, this message translates to:
  /// **'新作加载失败'**
  String get newLoadFailed;

  /// No description provided for @newLoadMoreFailed.
  ///
  /// In zh, this message translates to:
  /// **'加载更多新作失败'**
  String get newLoadMoreFailed;

  /// No description provided for @newRetry.
  ///
  /// In zh, this message translates to:
  /// **'重试'**
  String get newRetry;

  /// No description provided for @newRefreshFailed.
  ///
  /// In zh, this message translates to:
  /// **'刷新失败'**
  String get newRefreshFailed;

  /// No description provided for @recommendedRefreshFailed.
  ///
  /// In zh, this message translates to:
  /// **'刷新失败'**
  String get recommendedRefreshFailed;

  /// No description provided for @profileId.
  ///
  /// In zh, this message translates to:
  /// **'用户 ID'**
  String get profileId;

  /// No description provided for @profileAccount.
  ///
  /// In zh, this message translates to:
  /// **'账号'**
  String get profileAccount;

  /// No description provided for @profileIntroduction.
  ///
  /// In zh, this message translates to:
  /// **'简介'**
  String get profileIntroduction;

  /// No description provided for @profileBirthday.
  ///
  /// In zh, this message translates to:
  /// **'生日'**
  String get profileBirthday;

  /// No description provided for @profileGender.
  ///
  /// In zh, this message translates to:
  /// **'性别'**
  String get profileGender;

  /// No description provided for @profileRegion.
  ///
  /// In zh, this message translates to:
  /// **'地区'**
  String get profileRegion;

  /// No description provided for @profileJob.
  ///
  /// In zh, this message translates to:
  /// **'职业'**
  String get profileJob;

  /// No description provided for @profileWebsite.
  ///
  /// In zh, this message translates to:
  /// **'主页'**
  String get profileWebsite;

  /// No description provided for @profileWorkspace.
  ///
  /// In zh, this message translates to:
  /// **'工作环境'**
  String get profileWorkspace;

  /// No description provided for @profileStats.
  ///
  /// In zh, this message translates to:
  /// **'统计'**
  String get profileStats;

  /// No description provided for @profileLoading.
  ///
  /// In zh, this message translates to:
  /// **'正在加载用户资料'**
  String get profileLoading;

  /// No description provided for @profileNotFound.
  ///
  /// In zh, this message translates to:
  /// **'用户不存在或已被删除'**
  String get profileNotFound;

  /// No description provided for @profileBlocked.
  ///
  /// In zh, this message translates to:
  /// **'该用户资料不可见'**
  String get profileBlocked;

  /// No description provided for @profileLoadFailed.
  ///
  /// In zh, this message translates to:
  /// **'用户资料加载失败'**
  String get profileLoadFailed;

  /// No description provided for @profileItemsEmpty.
  ///
  /// In zh, this message translates to:
  /// **'暂无内容'**
  String get profileItemsEmpty;

  /// No description provided for @profileLoadMoreFailed.
  ///
  /// In zh, this message translates to:
  /// **'加载更多失败'**
  String get profileLoadMoreFailed;

  /// No description provided for @profileRetry.
  ///
  /// In zh, this message translates to:
  /// **'重试'**
  String get profileRetry;

  /// No description provided for @profileNovelPending.
  ///
  /// In zh, this message translates to:
  /// **'小说列表将在 Novel Reader 模块接入'**
  String get profileNovelPending;

  /// No description provided for @profileShare.
  ///
  /// In zh, this message translates to:
  /// **'分享用户'**
  String get profileShare;

  /// No description provided for @profileShareHint.
  ///
  /// In zh, this message translates to:
  /// **'可分享以下用户链接'**
  String get profileShareHint;

  /// No description provided for @profileShareClose.
  ///
  /// In zh, this message translates to:
  /// **'关闭'**
  String get profileShareClose;

  /// No description provided for @profileSettings.
  ///
  /// In zh, this message translates to:
  /// **'设置'**
  String get profileSettings;

  /// No description provided for @restrictSelector.
  ///
  /// In zh, this message translates to:
  /// **'选择公开范围'**
  String get restrictSelector;

  /// No description provided for @restrictPublic.
  ///
  /// In zh, this message translates to:
  /// **'公开'**
  String get restrictPublic;

  /// No description provided for @restrictPrivate.
  ///
  /// In zh, this message translates to:
  /// **'私密'**
  String get restrictPrivate;

  /// No description provided for @follow.
  ///
  /// In zh, this message translates to:
  /// **'关注'**
  String get follow;

  /// No description provided for @followed.
  ///
  /// In zh, this message translates to:
  /// **'已关注'**
  String get followed;

  /// No description provided for @followPrivately.
  ///
  /// In zh, this message translates to:
  /// **'私密关注'**
  String get followPrivately;

  /// No description provided for @unfollow.
  ///
  /// In zh, this message translates to:
  /// **'取消关注'**
  String get unfollow;

  /// Follow sheet, not followed yet: follow publicly (primary action, next to followPrivately).
  ///
  /// In zh, this message translates to:
  /// **'公开关注'**
  String get followPublicAction;

  /// Follow sheet, followed publicly: switch the follow to private.
  ///
  /// In zh, this message translates to:
  /// **'改为私密关注'**
  String get followSwitchToPrivate;

  /// Follow sheet, followed privately: switch the follow to public.
  ///
  /// In zh, this message translates to:
  /// **'改为公开关注'**
  String get followSwitchToPublic;

  /// No description provided for @followFailed.
  ///
  /// In zh, this message translates to:
  /// **'关注操作失败'**
  String get followFailed;

  /// No description provided for @userPreviewFollow.
  ///
  /// In zh, this message translates to:
  /// **'关注'**
  String get userPreviewFollow;

  /// No description provided for @novelLoading.
  ///
  /// In zh, this message translates to:
  /// **'正在加载小说'**
  String get novelLoading;

  /// No description provided for @novelNotFound.
  ///
  /// In zh, this message translates to:
  /// **'小说不存在或已被删除'**
  String get novelNotFound;

  /// No description provided for @novelRestricted.
  ///
  /// In zh, this message translates to:
  /// **'该小说受限，无法阅读'**
  String get novelRestricted;

  /// No description provided for @novelContentUnavailable.
  ///
  /// In zh, this message translates to:
  /// **'当前 API 未提供小说正文'**
  String get novelContentUnavailable;

  /// No description provided for @novelLoadFailed.
  ///
  /// In zh, this message translates to:
  /// **'小说加载失败'**
  String get novelLoadFailed;

  /// No description provided for @novelLayoutFailed.
  ///
  /// In zh, this message translates to:
  /// **'小说排版失败'**
  String get novelLayoutFailed;

  /// No description provided for @novelRetry.
  ///
  /// In zh, this message translates to:
  /// **'重试'**
  String get novelRetry;

  /// No description provided for @novelNoContent.
  ///
  /// In zh, this message translates to:
  /// **'暂无正文'**
  String get novelNoContent;

  /// No description provided for @novelWords.
  ///
  /// In zh, this message translates to:
  /// **'字'**
  String get novelWords;

  /// No description provided for @novelSeries.
  ///
  /// In zh, this message translates to:
  /// **'系列'**
  String get novelSeries;

  /// No description provided for @novelRanking.
  ///
  /// In zh, this message translates to:
  /// **'小说排行'**
  String get novelRanking;

  /// No description provided for @novelSeriesUnavailable.
  ///
  /// In zh, this message translates to:
  /// **'系列信息暂不可用'**
  String get novelSeriesUnavailable;

  /// No description provided for @novelInfoTitle.
  ///
  /// In zh, this message translates to:
  /// **'作品信息'**
  String get novelInfoTitle;

  /// No description provided for @novelPrevious.
  ///
  /// In zh, this message translates to:
  /// **'上一篇'**
  String get novelPrevious;

  /// No description provided for @novelNext.
  ///
  /// In zh, this message translates to:
  /// **'下一篇'**
  String get novelNext;

  /// No description provided for @novelDecreaseFont.
  ///
  /// In zh, this message translates to:
  /// **'减小字号'**
  String get novelDecreaseFont;

  /// No description provided for @novelIncreaseFont.
  ///
  /// In zh, this message translates to:
  /// **'增大字号'**
  String get novelIncreaseFont;

  /// No description provided for @novelReadingProgress.
  ///
  /// In zh, this message translates to:
  /// **'阅读进度'**
  String get novelReadingProgress;

  /// No description provided for @novelReaderSettings.
  ///
  /// In zh, this message translates to:
  /// **'阅读设置'**
  String get novelReaderSettings;

  /// No description provided for @novelTranslatePage.
  ///
  /// In zh, this message translates to:
  /// **'翻译本页'**
  String get novelTranslatePage;

  /// No description provided for @novelTranslating.
  ///
  /// In zh, this message translates to:
  /// **'翻译中'**
  String get novelTranslating;

  /// No description provided for @novelSettingsSaveFailed.
  ///
  /// In zh, this message translates to:
  /// **'阅读设置未能保存，仅本次生效'**
  String get novelSettingsSaveFailed;

  /// No description provided for @novelFontSize.
  ///
  /// In zh, this message translates to:
  /// **'字号'**
  String get novelFontSize;

  /// No description provided for @novelLineHeight.
  ///
  /// In zh, this message translates to:
  /// **'行距'**
  String get novelLineHeight;

  /// No description provided for @novelThemeSystem.
  ///
  /// In zh, this message translates to:
  /// **'跟随系统'**
  String get novelThemeSystem;

  /// No description provided for @novelThemePaper.
  ///
  /// In zh, this message translates to:
  /// **'纸张'**
  String get novelThemePaper;

  /// No description provided for @novelThemeSepia.
  ///
  /// In zh, this message translates to:
  /// **'护眼'**
  String get novelThemeSepia;

  /// No description provided for @novelThemeNight.
  ///
  /// In zh, this message translates to:
  /// **'夜间'**
  String get novelThemeNight;

  /// No description provided for @aboutDisplayRefreshRate.
  ///
  /// In zh, this message translates to:
  /// **'显示刷新率'**
  String get aboutDisplayRefreshRate;

  /// No description provided for @cardActionDownload.
  ///
  /// In zh, this message translates to:
  /// **'下载'**
  String get cardActionDownload;

  /// No description provided for @cardActionWatchLater.
  ///
  /// In zh, this message translates to:
  /// **'稍后再看'**
  String get cardActionWatchLater;

  /// No description provided for @cardActionRemoveWatchLater.
  ///
  /// In zh, this message translates to:
  /// **'从稍后再看移除'**
  String get cardActionRemoveWatchLater;

  /// No description provided for @cardActionShare.
  ///
  /// In zh, this message translates to:
  /// **'分享'**
  String get cardActionShare;

  /// No description provided for @share.
  ///
  /// In zh, this message translates to:
  /// **'分享'**
  String get share;

  /// No description provided for @openInBrowser.
  ///
  /// In zh, this message translates to:
  /// **'在浏览器打开'**
  String get openInBrowser;

  /// No description provided for @linkCopied.
  ///
  /// In zh, this message translates to:
  /// **'链接已复制'**
  String get linkCopied;

  /// No description provided for @copyLink.
  ///
  /// In zh, this message translates to:
  /// **'复制链接'**
  String get copyLink;

  /// No description provided for @openLink.
  ///
  /// In zh, this message translates to:
  /// **'打开链接'**
  String get openLink;

  /// No description provided for @watchLaterAdded.
  ///
  /// In zh, this message translates to:
  /// **'已加入稍后再看'**
  String get watchLaterAdded;

  /// No description provided for @watchLaterTitle.
  ///
  /// In zh, this message translates to:
  /// **'稍后再看'**
  String get watchLaterTitle;

  /// No description provided for @watchLaterEmpty.
  ///
  /// In zh, this message translates to:
  /// **'暂存的作品会显示在这里'**
  String get watchLaterEmpty;

  /// No description provided for @watchLaterLoadFailed.
  ///
  /// In zh, this message translates to:
  /// **'稍后再看加载失败'**
  String get watchLaterLoadFailed;

  /// No description provided for @bookmarkEditTitle.
  ///
  /// In zh, this message translates to:
  /// **'编辑收藏'**
  String get bookmarkEditTitle;

  /// No description provided for @bookmarkTags.
  ///
  /// In zh, this message translates to:
  /// **'收藏标签'**
  String get bookmarkTags;

  /// No description provided for @bookmarkTagNewHint.
  ///
  /// In zh, this message translates to:
  /// **'输入新标签，回车添加'**
  String get bookmarkTagNewHint;

  /// No description provided for @bookmarkTagFilterEmpty.
  ///
  /// In zh, this message translates to:
  /// **'已加载内容中无匹配'**
  String get bookmarkTagFilterEmpty;

  /// No description provided for @bookmarkTagFilterHint.
  ///
  /// In zh, this message translates to:
  /// **'筛选已加载作品'**
  String get bookmarkTagFilterHint;

  /// No description provided for @bookmarkTagSuggestions.
  ///
  /// In zh, this message translates to:
  /// **'常用标签'**
  String get bookmarkTagSuggestions;

  /// No description provided for @bookmarkTagsEmpty.
  ///
  /// In zh, this message translates to:
  /// **'还没有收藏标签'**
  String get bookmarkTagsEmpty;

  /// No description provided for @bookmarkTagsLoadFailed.
  ///
  /// In zh, this message translates to:
  /// **'收藏标签加载失败'**
  String get bookmarkTagsLoadFailed;

  /// No description provided for @bookmarkTagsEnd.
  ///
  /// In zh, this message translates to:
  /// **'已显示全部标签'**
  String get bookmarkTagsEnd;

  /// No description provided for @seriesTitle.
  ///
  /// In zh, this message translates to:
  /// **'系列'**
  String get seriesTitle;

  /// No description provided for @seriesLoadFailed.
  ///
  /// In zh, this message translates to:
  /// **'系列加载失败'**
  String get seriesLoadFailed;

  /// No description provided for @seriesLoadMoreFailed.
  ///
  /// In zh, this message translates to:
  /// **'加载更多失败'**
  String get seriesLoadMoreFailed;

  /// No description provided for @seriesEmpty.
  ///
  /// In zh, this message translates to:
  /// **'该系列暂无作品'**
  String get seriesEmpty;

  /// No description provided for @seriesWorksCount.
  ///
  /// In zh, this message translates to:
  /// **'共 {count} 个作品'**
  String seriesWorksCount(int count);

  /// No description provided for @seriesEpisode.
  ///
  /// In zh, this message translates to:
  /// **'第 {order} 话'**
  String seriesEpisode(int order);

  /// Opens the first work in this series
  ///
  /// In zh, this message translates to:
  /// **'开始阅读'**
  String get seriesStartReading;

  /// Opens the series episode the user last opened
  ///
  /// In zh, this message translates to:
  /// **'继续第 {n} 话'**
  String seriesContinueEpisode(int n);

  /// Opens the series work the user last opened when its episode number is unknown
  ///
  /// In zh, this message translates to:
  /// **'继续阅读'**
  String get seriesContinue;

  /// Opens the first episode of a series the user has already been reading
  ///
  /// In zh, this message translates to:
  /// **'从第 1 话开始'**
  String get seriesStartFromFirst;

  /// No description provided for @seriesPrevious.
  ///
  /// In zh, this message translates to:
  /// **'上一话'**
  String get seriesPrevious;

  /// No description provided for @seriesNext.
  ///
  /// In zh, this message translates to:
  /// **'下一话'**
  String get seriesNext;

  /// No description provided for @watchlistTitle.
  ///
  /// In zh, this message translates to:
  /// **'追更'**
  String get watchlistTitle;

  /// No description provided for @watchlistManga.
  ///
  /// In zh, this message translates to:
  /// **'漫画'**
  String get watchlistManga;

  /// No description provided for @watchlistNovel.
  ///
  /// In zh, this message translates to:
  /// **'小说'**
  String get watchlistNovel;

  /// No description provided for @watchlistEmpty.
  ///
  /// In zh, this message translates to:
  /// **'还没有追更的系列'**
  String get watchlistEmpty;

  /// No description provided for @watchlistLoadFailed.
  ///
  /// In zh, this message translates to:
  /// **'追更列表加载失败'**
  String get watchlistLoadFailed;

  /// No description provided for @watchlistLoadMoreFailed.
  ///
  /// In zh, this message translates to:
  /// **'加载更多失败'**
  String get watchlistLoadMoreFailed;

  /// No description provided for @watchlistAdd.
  ///
  /// In zh, this message translates to:
  /// **'追更'**
  String get watchlistAdd;

  /// No description provided for @watchlistRemove.
  ///
  /// In zh, this message translates to:
  /// **'取消追更'**
  String get watchlistRemove;

  /// No description provided for @watchlistFailed.
  ///
  /// In zh, this message translates to:
  /// **'追更操作失败'**
  String get watchlistFailed;

  /// No description provided for @watchlistNewContent.
  ///
  /// In zh, this message translates to:
  /// **'更新'**
  String get watchlistNewContent;

  /// No description provided for @localNovelsTitle.
  ///
  /// In zh, this message translates to:
  /// **'本地小说'**
  String get localNovelsTitle;

  /// No description provided for @localNovelsEmpty.
  ///
  /// In zh, this message translates to:
  /// **'还没有导入的本地小说'**
  String get localNovelsEmpty;

  /// No description provided for @localNovelsLoadFailed.
  ///
  /// In zh, this message translates to:
  /// **'本地小说加载失败'**
  String get localNovelsLoadFailed;

  /// No description provided for @localNovelsImport.
  ///
  /// In zh, this message translates to:
  /// **'导入 TXT'**
  String get localNovelsImport;

  /// No description provided for @localNovelsImportFailed.
  ///
  /// In zh, this message translates to:
  /// **'导入失败'**
  String get localNovelsImportFailed;

  /// No description provided for @localNovelsImported.
  ///
  /// In zh, this message translates to:
  /// **'已导入「{title}」'**
  String localNovelsImported(String title);

  /// No description provided for @localNovelsImportedLossy.
  ///
  /// In zh, this message translates to:
  /// **'已导入，但编码无法完全识别，可能包含乱码'**
  String get localNovelsImportedLossy;

  /// No description provided for @localNovelsDelete.
  ///
  /// In zh, this message translates to:
  /// **'删除'**
  String get localNovelsDelete;

  /// No description provided for @localNovelsDeleteConfirm.
  ///
  /// In zh, this message translates to:
  /// **'删除「{title}」？本地文件会一并删除。'**
  String localNovelsDeleteConfirm(String title);

  /// No description provided for @novelChapters.
  ///
  /// In zh, this message translates to:
  /// **'目录'**
  String get novelChapters;

  /// No description provided for @localNovelFileInfo.
  ///
  /// In zh, this message translates to:
  /// **'文件信息'**
  String get localNovelFileInfo;

  /// No description provided for @localNovelFileEncoding.
  ///
  /// In zh, this message translates to:
  /// **'编码：{encoding}'**
  String localNovelFileEncoding(String encoding);

  /// No description provided for @localNovelFileImportedAt.
  ///
  /// In zh, this message translates to:
  /// **'导入时间 {date}'**
  String localNovelFileImportedAt(String date);

  /// No description provided for @localNovelsChars.
  ///
  /// In zh, this message translates to:
  /// **'{count} 字'**
  String localNovelsChars(int count);

  /// No description provided for @localNovelContinue.
  ///
  /// In zh, this message translates to:
  /// **'继续阅读 · {percent}%'**
  String localNovelContinue(int percent);

  /// No description provided for @profileSeries.
  ///
  /// In zh, this message translates to:
  /// **'系列'**
  String get profileSeries;

  /// No description provided for @spotlightTitle.
  ///
  /// In zh, this message translates to:
  /// **'特辑'**
  String get spotlightTitle;

  /// Search guide: trailing link of the Spotlight section header; opens the full Spotlight list.
  ///
  /// In zh, this message translates to:
  /// **'全部'**
  String get spotlightSeeAll;

  /// No description provided for @spotlightArticleLoadFailed.
  ///
  /// In zh, this message translates to:
  /// **'文章加载失败'**
  String get spotlightArticleLoadFailed;

  /// No description provided for @spotlightCategoryAll.
  ///
  /// In zh, this message translates to:
  /// **'全部'**
  String get spotlightCategoryAll;

  /// No description provided for @spotlightCategoryIllust.
  ///
  /// In zh, this message translates to:
  /// **'插画'**
  String get spotlightCategoryIllust;

  /// No description provided for @spotlightCategoryManga.
  ///
  /// In zh, this message translates to:
  /// **'漫画'**
  String get spotlightCategoryManga;

  /// No description provided for @spotlightLoadFailed.
  ///
  /// In zh, this message translates to:
  /// **'特辑加载失败'**
  String get spotlightLoadFailed;

  /// No description provided for @spotlightLoadMoreFailed.
  ///
  /// In zh, this message translates to:
  /// **'特辑加载更多失败'**
  String get spotlightLoadMoreFailed;

  /// No description provided for @spotlightEmpty.
  ///
  /// In zh, this message translates to:
  /// **'暂无特辑'**
  String get spotlightEmpty;

  /// No description provided for @hapticStrength.
  ///
  /// In zh, this message translates to:
  /// **'触感强度'**
  String get hapticStrength;

  /// No description provided for @hapticStrengthOff.
  ///
  /// In zh, this message translates to:
  /// **'关'**
  String get hapticStrengthOff;

  /// No description provided for @hapticStrengthLight.
  ///
  /// In zh, this message translates to:
  /// **'轻'**
  String get hapticStrengthLight;

  /// No description provided for @hapticStrengthStandard.
  ///
  /// In zh, this message translates to:
  /// **'标准'**
  String get hapticStrengthStandard;

  /// No description provided for @hapticStrengthStrong.
  ///
  /// In zh, this message translates to:
  /// **'强'**
  String get hapticStrengthStrong;

  /// No description provided for @hapticTierComposition.
  ///
  /// In zh, this message translates to:
  /// **'本机支持精细振动，强度逐级可调'**
  String get hapticTierComposition;

  /// No description provided for @hapticTierPredefined.
  ///
  /// In zh, this message translates to:
  /// **'本机使用系统预设振动，强度按档位换用不同效果'**
  String get hapticTierPredefined;

  /// No description provided for @hapticTierSystem.
  ///
  /// In zh, this message translates to:
  /// **'本机仅支持系统触感，强度不可调'**
  String get hapticTierSystem;

  /// No description provided for @hapticTierNone.
  ///
  /// In zh, this message translates to:
  /// **'本机没有振动器'**
  String get hapticTierNone;

  /// No description provided for @hapticTierUnknown.
  ///
  /// In zh, this message translates to:
  /// **'无法读取本机的振动能力'**
  String get hapticTierUnknown;

  /// No description provided for @hapticSystemOff.
  ///
  /// In zh, this message translates to:
  /// **'系统已关闭触摸振动，应用内触感不会生效'**
  String get hapticSystemOff;

  /// No description provided for @downloadSelectPages.
  ///
  /// In zh, this message translates to:
  /// **'选择要下载的页'**
  String get downloadSelectPages;

  /// No description provided for @downloadSelectedPages.
  ///
  /// In zh, this message translates to:
  /// **'下载选中的页'**
  String get downloadSelectedPages;

  /// No description provided for @selectAll.
  ///
  /// In zh, this message translates to:
  /// **'全选'**
  String get selectAll;

  /// No description provided for @viewerPageLabel.
  ///
  /// In zh, this message translates to:
  /// **'第 {page} 页，共 {total} 页'**
  String viewerPageLabel(int page, int total);

  /// No description provided for @tagActionSearch.
  ///
  /// In zh, this message translates to:
  /// **'搜索该标签'**
  String get tagActionSearch;

  /// No description provided for @tagActionCopy.
  ///
  /// In zh, this message translates to:
  /// **'复制标签名'**
  String get tagActionCopy;

  /// No description provided for @tagActionTranslate.
  ///
  /// In zh, this message translates to:
  /// **'翻译标签名'**
  String get tagActionTranslate;

  /// No description provided for @tagActionCopyTranslation.
  ///
  /// In zh, this message translates to:
  /// **'复制译文'**
  String get tagActionCopyTranslation;

  /// No description provided for @tagActionMute.
  ///
  /// In zh, this message translates to:
  /// **'屏蔽该标签'**
  String get tagActionMute;

  /// No description provided for @tagActionUnmute.
  ///
  /// In zh, this message translates to:
  /// **'解除屏蔽该标签'**
  String get tagActionUnmute;

  /// No description provided for @tagActionMuteMode.
  ///
  /// In zh, this message translates to:
  /// **'批量屏蔽标签'**
  String get tagActionMuteMode;

  /// No description provided for @tagCopied.
  ///
  /// In zh, this message translates to:
  /// **'已复制标签'**
  String get tagCopied;

  /// No description provided for @ugoiraExporting.
  ///
  /// In zh, this message translates to:
  /// **'正在导出 GIF… {percent}%'**
  String ugoiraExporting(int percent);

  /// No description provided for @viewerFitScreen.
  ///
  /// In zh, this message translates to:
  /// **'适应屏幕'**
  String get viewerFitScreen;

  /// No description provided for @viewerSavePage.
  ///
  /// In zh, this message translates to:
  /// **'保存当前页'**
  String get viewerSavePage;

  /// No description provided for @viewerJumpToPage.
  ///
  /// In zh, this message translates to:
  /// **'跳转到页码'**
  String get viewerJumpToPage;

  /// No description provided for @viewerInfo.
  ///
  /// In zh, this message translates to:
  /// **'作品信息'**
  String get viewerInfo;

  /// No description provided for @viewerOpenDetail.
  ///
  /// In zh, this message translates to:
  /// **'打开详情页'**
  String get viewerOpenDetail;

  /// No description provided for @illustPagesTotal.
  ///
  /// In zh, this message translates to:
  /// **'共 {count} 页'**
  String illustPagesTotal(int count);

  /// Spoken label of the animated-work badge on an artwork thumbnail
  ///
  /// In zh, this message translates to:
  /// **'动图'**
  String get badgeUgoira;

  /// Spoken label of the AI badge on an artwork thumbnail
  ///
  /// In zh, this message translates to:
  /// **'AI 生成'**
  String get badgeAi;

  /// Spoken ranking position before a work title in ranking lists
  ///
  /// In zh, this message translates to:
  /// **'第 {rank} 名'**
  String rankLabel(int rank);

  /// Screen-reader hint on an author row: tapping opens the author's profile
  ///
  /// In zh, this message translates to:
  /// **'打开作者主页'**
  String get openAuthorProfile;

  /// Button under collapsed long text (captions, descriptions) that shows all of it
  ///
  /// In zh, this message translates to:
  /// **'展开'**
  String get expandText;

  /// Button under expanded long text that collapses it again
  ///
  /// In zh, this message translates to:
  /// **'收起'**
  String get collapseText;

  /// Jump to the artwork info section
  ///
  /// In zh, this message translates to:
  /// **'跳到作品信息区'**
  String get illustInfoJump;

  /// Enter the management/selection mode
  ///
  /// In zh, this message translates to:
  /// **'管理'**
  String get manage;

  /// AppBar title in selection mode
  ///
  /// In zh, this message translates to:
  /// **'已选 {n} 项'**
  String selectedCount(int n);

  /// SnackBar action that reverses a just-made removal (watch later, bookmark, follow, mute)
  ///
  /// In zh, this message translates to:
  /// **'撤销'**
  String get undo;

  /// SnackBar shown after removing a watch-later entry; offers undo
  ///
  /// In zh, this message translates to:
  /// **'已从稍后再看移除'**
  String get watchLaterRemoved;

  /// SnackBar after unfollowing a user; offers undo
  ///
  /// In zh, this message translates to:
  /// **'已取消关注'**
  String get followRemoved;

  /// SnackBar after unmuting a tag, user or work; offers undo
  ///
  /// In zh, this message translates to:
  /// **'已解除屏蔽'**
  String get muteRemoved;

  /// Watchlist sheet action: open the manga series contents page
  ///
  /// In zh, this message translates to:
  /// **'打开目录'**
  String get watchlistOpenContents;

  /// Tooltip of the retry button on an image that failed to load
  ///
  /// In zh, this message translates to:
  /// **'重新加载图片'**
  String get imageRetry;

  /// Screen-reader label of the progress ring over a loading detail or viewer image
  ///
  /// In zh, this message translates to:
  /// **'图片加载中'**
  String get imageLoading;

  /// Relative time: less than a minute ago
  ///
  /// In zh, this message translates to:
  /// **'刚刚'**
  String get timeJustNow;

  /// Relative time: N minutes ago
  ///
  /// In zh, this message translates to:
  /// **'{count, plural, other{{count} 分钟前}}'**
  String timeMinutesAgo(int count);

  /// Relative time: N hours ago
  ///
  /// In zh, this message translates to:
  /// **'{count, plural, other{{count} 小时前}}'**
  String timeHoursAgo(int count);

  /// Relative time: N days ago (up to 7; older uses the absolute date)
  ///
  /// In zh, this message translates to:
  /// **'{count, plural, other{{count} 天前}}'**
  String timeDaysAgo(int count);
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'ja', 'ru', 'zh'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
    case 'ja':
      return AppLocalizationsJa();
    case 'ru':
      return AppLocalizationsRu();
    case 'zh':
      return AppLocalizationsZh();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
