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
  /// **'感谢使用Pixiv Func'**
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

  /// No description provided for @selectTheme.
  ///
  /// In zh, this message translates to:
  /// **'选择喜欢的主题'**
  String get selectTheme;

  /// No description provided for @next.
  ///
  /// In zh, this message translates to:
  /// **'下一步'**
  String get next;

  /// No description provided for @later.
  ///
  /// In zh, this message translates to:
  /// **'稍后您可以在设置中进行相应变更'**
  String get later;

  /// No description provided for @dark.
  ///
  /// In zh, this message translates to:
  /// **'黑暗'**
  String get dark;

  /// No description provided for @light.
  ///
  /// In zh, this message translates to:
  /// **'明亮'**
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
  /// **'登录回调无效: {reason}'**
  String loginCallbackInvalid(String reason);

  /// No description provided for @loginNetworkError.
  ///
  /// In zh, this message translates to:
  /// **'网络错误 (HTTP {status})'**
  String loginNetworkError(String status);

  /// No description provided for @loginPageLoadFailed.
  ///
  /// In zh, this message translates to:
  /// **'页面加载失败 ({error})'**
  String loginPageLoadFailed(String error);

  /// No description provided for @loginFailed.
  ///
  /// In zh, this message translates to:
  /// **'登录失败: {error}'**
  String loginFailed(String error);

  /// No description provided for @loginFailedType.
  ///
  /// In zh, this message translates to:
  /// **'登录失败 ({type})'**
  String loginFailedType(String type);

  /// No description provided for @networkCompatibility.
  ///
  /// In zh, this message translates to:
  /// **'自动兼容网络'**
  String get networkCompatibility;

  /// No description provided for @networkCompatibilityHint.
  ///
  /// In zh, this message translates to:
  /// **'默认直连；仅 Pixiv 官方域名在明确的传输失败时尝试严格 HTTPS 候选。不会代理其他流量，也不会关闭证书校验。'**
  String get networkCompatibilityHint;

  /// No description provided for @getMoreHelp.
  ///
  /// In zh, this message translates to:
  /// **'获取更多帮助 >>'**
  String get getMoreHelp;

  /// No description provided for @useLoginWithClipboardHint.
  ///
  /// In zh, this message translates to:
  /// **'或使用\\n长按头像复制账号数据'**
  String get useLoginWithClipboardHint;

  /// No description provided for @useLoginWithClipboard.
  ///
  /// In zh, this message translates to:
  /// **'使用剪贴板数据登录'**
  String get useLoginWithClipboard;

  /// No description provided for @accountTransferWarning.
  ///
  /// In zh, this message translates to:
  /// **'剪贴板内容会短时存在，可能被其他应用读取；此格式不提供加密或发送者认证。'**
  String get accountTransferWarning;

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
  /// **'登录即表示您同意'**
  String get loginAgree;

  /// No description provided for @userAgreement.
  ///
  /// In zh, this message translates to:
  /// **'《Pixiv Func用户使用协议》'**
  String get userAgreement;

  /// No description provided for @settingsTitle.
  ///
  /// In zh, this message translates to:
  /// **'设置'**
  String get settingsTitle;

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
  /// **'自动兼容网络'**
  String get networkMode;

  /// No description provided for @networkModeHint.
  ///
  /// In zh, this message translates to:
  /// **'默认直连；仅 Pixiv 官方域名在明确的传输失败时尝试严格 HTTPS 候选。不会代理其他流量，也不会关闭证书校验。'**
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
  /// **'标准网络栈：按各主机组选择可达且畅通的路线。'**
  String get networkModeAutomaticHint;

  /// No description provided for @networkModeDirectOnly.
  ///
  /// In zh, this message translates to:
  /// **'仅直连'**
  String get networkModeDirectOnly;

  /// No description provided for @networkModeDirectOnlyHint.
  ///
  /// In zh, this message translates to:
  /// **'使用系统 DNS + 真实 SNI 直连。适合已知直连可用的网络。'**
  String get networkModeDirectOnlyHint;

  /// No description provided for @networkAdvanced.
  ///
  /// In zh, this message translates to:
  /// **'高级设置'**
  String get networkAdvanced;

  /// No description provided for @networkAdvancedHint.
  ///
  /// In zh, this message translates to:
  /// **'DoH 端点、ECH 前置主机等实现细节。'**
  String get networkAdvancedHint;

  /// No description provided for @networkAdvancedReset.
  ///
  /// In zh, this message translates to:
  /// **'恢复默认值'**
  String get networkAdvancedReset;

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
  /// **'DoH 端点（逗号分隔，https URL）'**
  String get networkDohEndpoints;

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
  /// **'对 Pixiv 四个官方主机逐层测试：系统 DNS → DoH → TCP → TLS(真实 SNI) → 最小请求。TCP 通但 TLS 握手失败 = SNI 被封。'**
  String get networkProbeHint;

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

  /// No description provided for @historyView.
  ///
  /// In zh, this message translates to:
  /// **'查看浏览历史'**
  String get historyView;

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

  /// No description provided for @blockTagSettings.
  ///
  /// In zh, this message translates to:
  /// **'屏蔽标签'**
  String get blockTagSettings;

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

  /// No description provided for @reopen.
  ///
  /// In zh, this message translates to:
  /// **'重新打开'**
  String get reopen;

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

  /// No description provided for @profileEditChooseImage.
  ///
  /// In zh, this message translates to:
  /// **'选择图片'**
  String get profileEditChooseImage;

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

  /// No description provided for @imageSource.
  ///
  /// In zh, this message translates to:
  /// **'图片源'**
  String get imageSource;

  /// No description provided for @imageSourceNormal.
  ///
  /// In zh, this message translates to:
  /// **'官方 CDN（系统 DNS / HTTPS）'**
  String get imageSourceNormal;

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

  /// No description provided for @localHistory.
  ///
  /// In zh, this message translates to:
  /// **'本地浏览历史'**
  String get localHistory;

  /// No description provided for @pixivHistory.
  ///
  /// In zh, this message translates to:
  /// **'Pixiv 浏览历史'**
  String get pixivHistory;

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

  /// No description provided for @maxDownloadCount.
  ///
  /// In zh, this message translates to:
  /// **'最大并行下载数'**
  String get maxDownloadCount;

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
  /// **'PixivFunc 相册（默认）'**
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

  /// No description provided for @saveLocationUseCustomAlbum.
  ///
  /// In zh, this message translates to:
  /// **'使用自定义相册'**
  String get saveLocationUseCustomAlbum;

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

  /// No description provided for @saveLocationSafPicked.
  ///
  /// In zh, this message translates to:
  /// **'已选择文件夹'**
  String get saveLocationSafPicked;

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

  /// No description provided for @namingTemplateVariables.
  ///
  /// In zh, this message translates to:
  /// **'变量：{artist} {title} {id} {page} {ext} {date}；非法字符自动替换为 _，超长自动裁剪。'**
  String namingTemplateVariables(
    String artist,
    String title,
    String id,
    String page,
    String ext,
    String date,
  );

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

  /// No description provided for @historySettingsHint.
  ///
  /// In zh, this message translates to:
  /// **'历史记录开关由历史模块读取；关闭后不会新增对应记录。'**
  String get historySettingsHint;

  /// No description provided for @blockTagInputHint.
  ///
  /// In zh, this message translates to:
  /// **'输入标签后添加'**
  String get blockTagInputHint;

  /// No description provided for @noBlockedTags.
  ///
  /// In zh, this message translates to:
  /// **'暂无屏蔽标签'**
  String get noBlockedTags;

  /// No description provided for @downloaderSettingsHint.
  ///
  /// In zh, this message translates to:
  /// **'下载任务由共享 DownloadManager 实时维护。'**
  String get downloaderSettingsHint;

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
  /// **'原项目作者：git-xiaocao（小草）。'**
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

  /// No description provided for @downloadSubmissionFailed.
  ///
  /// In zh, this message translates to:
  /// **'下载失败：{error}'**
  String downloadSubmissionFailed(String error);

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
  /// **'GIF 保存失败：{error}'**
  String ugoiraSaveFailed(String error);

  /// No description provided for @ugoiraArchiveInvalid.
  ///
  /// In zh, this message translates to:
  /// **'动图压缩包无效：{error}'**
  String ugoiraArchiveInvalid(String error);

  /// No description provided for @ugoiraFrameCorrupt.
  ///
  /// In zh, this message translates to:
  /// **'动图帧损坏：{error}'**
  String ugoiraFrameCorrupt(String error);

  /// No description provided for @ugoiraLoadFailed.
  ///
  /// In zh, this message translates to:
  /// **'动图加载失败：{error}'**
  String ugoiraLoadFailed(String error);

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

  /// No description provided for @homeExitHint.
  ///
  /// In zh, this message translates to:
  /// **'再按一次退出'**
  String get homeExitHint;

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
  /// **'收藏操作失败：{error}'**
  String bookmarkOperationFailed(String error);

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

  /// No description provided for @rankingDay.
  ///
  /// In zh, this message translates to:
  /// **'每日'**
  String get rankingDay;

  /// No description provided for @rankingDayR18.
  ///
  /// In zh, this message translates to:
  /// **'每日(R-18)'**
  String get rankingDayR18;

  /// No description provided for @rankingDayMale.
  ///
  /// In zh, this message translates to:
  /// **'每日(男性欢迎)'**
  String get rankingDayMale;

  /// No description provided for @rankingDayMaleR18.
  ///
  /// In zh, this message translates to:
  /// **'每日(男性欢迎 & R-18)'**
  String get rankingDayMaleR18;

  /// No description provided for @rankingDayFemale.
  ///
  /// In zh, this message translates to:
  /// **'每日(女性欢迎)'**
  String get rankingDayFemale;

  /// No description provided for @rankingDayFemaleR18.
  ///
  /// In zh, this message translates to:
  /// **'每日(女性欢迎 & R-18)'**
  String get rankingDayFemaleR18;

  /// No description provided for @rankingWeek.
  ///
  /// In zh, this message translates to:
  /// **'每周'**
  String get rankingWeek;

  /// No description provided for @rankingWeekR18.
  ///
  /// In zh, this message translates to:
  /// **'每周(R-18)'**
  String get rankingWeekR18;

  /// No description provided for @rankingWeekOriginal.
  ///
  /// In zh, this message translates to:
  /// **'每周(原创)'**
  String get rankingWeekOriginal;

  /// No description provided for @rankingWeekRookie.
  ///
  /// In zh, this message translates to:
  /// **'每周(新人)'**
  String get rankingWeekRookie;

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

  /// No description provided for @profileWork.
  ///
  /// In zh, this message translates to:
  /// **'作品'**
  String get profileWork;

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

  /// No description provided for @searchReverseUnavailable.
  ///
  /// In zh, this message translates to:
  /// **'反向搜图暂不可用'**
  String get searchReverseUnavailable;

  /// No description provided for @searchReverseUnavailableDetail.
  ///
  /// In zh, this message translates to:
  /// **'当前没有通过凭据、服务条款和隐私审查的结构化服务；不会上传图片或执行网页抓取。'**
  String get searchReverseUnavailableDetail;

  /// No description provided for @searchReversePick.
  ///
  /// In zh, this message translates to:
  /// **'选择图片'**
  String get searchReversePick;

  /// No description provided for @searchReversePrivacy.
  ///
  /// In zh, this message translates to:
  /// **'隐私提示'**
  String get searchReversePrivacy;

  /// No description provided for @searchReversePrivacyDetail.
  ///
  /// In zh, this message translates to:
  /// **'图片只会在你确认搜索后发送给已批准的服务；取消或失败后会立即清理临时文件。'**
  String get searchReversePrivacyDetail;

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

  /// No description provided for @searchReverseOpenExternal.
  ///
  /// In zh, this message translates to:
  /// **'打开来源'**
  String get searchReverseOpenExternal;

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
  /// **'SauceNAO 要求人机验证，本次搜索未完成，请稍后再试'**
  String get searchReverseChallenge;

  /// No description provided for @searchReversePageLoadFailed.
  ///
  /// In zh, this message translates to:
  /// **'结果页加载失败'**
  String get searchReversePageLoadFailed;

  /// No description provided for @searchReverseIntro.
  ///
  /// In zh, this message translates to:
  /// **'选择图片后，将匿名上传到 SauceNAO 进行反向检索；结果页在应用内打开。'**
  String get searchReverseIntro;

  /// No description provided for @searchNoRepresentative.
  ///
  /// In zh, this message translates to:
  /// **'该标签暂无代表作品'**
  String get searchNoRepresentative;

  /// No description provided for @searchFilters.
  ///
  /// In zh, this message translates to:
  /// **'筛选'**
  String get searchFilters;

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

  /// No description provided for @searchNoSuggestions.
  ///
  /// In zh, this message translates to:
  /// **'没有匹配建议'**
  String get searchNoSuggestions;

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

  /// No description provided for @illustDetailCreateDateUnknown.
  ///
  /// In zh, this message translates to:
  /// **'投稿日期未知'**
  String get illustDetailCreateDateUnknown;

  /// No description provided for @illustDetailCreateDate.
  ///
  /// In zh, this message translates to:
  /// **'投稿日期：{date}'**
  String illustDetailCreateDate(String date);

  /// No description provided for @illustDetailSize.
  ///
  /// In zh, this message translates to:
  /// **'尺寸：{width}x{height}'**
  String illustDetailSize(int width, int height);

  /// No description provided for @illustDetailOpenLinkFailed.
  ///
  /// In zh, this message translates to:
  /// **'无法打开链接：{error}'**
  String illustDetailOpenLinkFailed(String error);

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

  /// No description provided for @commentReplies.
  ///
  /// In zh, this message translates to:
  /// **'回复'**
  String get commentReplies;

  /// No description provided for @commentTranslate.
  ///
  /// In zh, this message translates to:
  /// **'翻译'**
  String get commentTranslate;

  /// No description provided for @commentTranslation.
  ///
  /// In zh, this message translates to:
  /// **'翻译结果'**
  String get commentTranslation;

  /// No description provided for @commentTranslationUnavailable.
  ///
  /// In zh, this message translates to:
  /// **'翻译服务不可用，请在设置中开启。'**
  String get commentTranslationUnavailable;

  /// No description provided for @commentTranslationFailed.
  ///
  /// In zh, this message translates to:
  /// **'翻译失败'**
  String get commentTranslationFailed;

  /// No description provided for @commentTranslationInvalidCredentials.
  ///
  /// In zh, this message translates to:
  /// **'翻译凭据无效，请在设置中检查。'**
  String get commentTranslationInvalidCredentials;

  /// No description provided for @commentTranslationRateLimited.
  ///
  /// In zh, this message translates to:
  /// **'翻译过于频繁或额度已用完'**
  String get commentTranslationRateLimited;

  /// No description provided for @commentEmoji.
  ///
  /// In zh, this message translates to:
  /// **'Emoji'**
  String get commentEmoji;

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

  /// No description provided for @newIllust.
  ///
  /// In zh, this message translates to:
  /// **'插画'**
  String get newIllust;

  /// No description provided for @newNovel.
  ///
  /// In zh, this message translates to:
  /// **'小说'**
  String get newNovel;

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

  /// No description provided for @followUser.
  ///
  /// In zh, this message translates to:
  /// **'关注用户'**
  String get followUser;

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

  /// No description provided for @novelSeriesUnavailable.
  ///
  /// In zh, this message translates to:
  /// **'系列信息暂不可用'**
  String get novelSeriesUnavailable;

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
