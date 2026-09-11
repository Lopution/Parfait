// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Chinese (`zh`).
class AppLocalizationsZh extends AppLocalizations {
  AppLocalizationsZh([String locale = 'zh']) : super(locale);

  @override
  String get networkDohEndpointsInvalid => 'DoH 地址列表无效';

  @override
  String get welcome1 => '感谢使用Pixiv Func';

  @override
  String get welcome2 => '下面将进行首次启动设置';

  @override
  String get start => '开始';

  @override
  String get selectLanguage => '选择您的语言';

  @override
  String get selectTheme => '选择喜欢的主题';

  @override
  String get next => '下一步';

  @override
  String get later => '稍后您可以在设置中进行相应变更';

  @override
  String get dark => '黑暗';

  @override
  String get light => '明亮';

  @override
  String get system => '跟随系统';

  @override
  String get loginTitle => '注册 或 登录';

  @override
  String get register => '注册';

  @override
  String get login => '登录';

  @override
  String get loginPageClosed => '页面已关闭，请重新打开';

  @override
  String loginCallbackInvalid(String reason) {
    return '登录回调无效: $reason';
  }

  @override
  String loginNetworkError(String status) {
    return '网络错误 (HTTP $status)';
  }

  @override
  String loginPageLoadFailed(String error) {
    return '页面加载失败 ($error)';
  }

  @override
  String loginFailed(String error) {
    return '登录失败: $error';
  }

  @override
  String loginFailedType(String type) {
    return '登录失败 ($type)';
  }

  @override
  String get networkCompatibility => '自动兼容网络';

  @override
  String get networkCompatibilityHint =>
      '默认直连；仅 Pixiv 官方域名在明确的传输失败时尝试严格 HTTPS 候选。不会代理其他流量，也不会关闭证书校验。';

  @override
  String get getMoreHelp => '获取更多帮助 >>';

  @override
  String get useLoginWithClipboardHint => '或使用\\n长按头像复制账号数据';

  @override
  String get useLoginWithClipboard => '使用剪贴板数据登录';

  @override
  String get accountTransferWarning => '剪贴板内容会短时存在，可能被其他应用读取；此格式不提供加密或发送者认证。';

  @override
  String get accountTransferSensitiveWarning =>
      '此设备不支持敏感剪贴板标记（Android 13+ 才支持）：凭据将以明文进入系统剪贴板，请尽快粘贴；5 分钟后自动清除。';

  @override
  String get accountTransferCopied => '账号迁移数据已复制，请尽快在目标设备粘贴。';

  @override
  String get accountTransferImported => '账号迁移成功';

  @override
  String get accountTransferClipboardReplaced => '账号已导入；剪贴板已被其他内容替换，未执行清除。';

  @override
  String get accountTransferCorrupt => '剪贴板账号数据损坏或格式不受支持';

  @override
  String get accountTransferCredentialInvalid => '账号凭据无效，请重新登录或重新复制';

  @override
  String get accountTransferVerificationUnavailable => '暂时无法向 Pixiv 验证账号凭据';

  @override
  String get accountTransferNoAccount => '当前没有可复制的已登录账号';

  @override
  String get accountTransferCredentialUnavailable => '当前账号凭据不可用，请重新登录';

  @override
  String get accountTransferClipboardUnavailable => '剪贴板当前不可用';

  @override
  String get accountTransferStorageFailure => '账号迁移记录无法安全保存';

  @override
  String get loginAgree => '登录即表示您同意';

  @override
  String get userAgreement => '《Pixiv Func用户使用协议》';

  @override
  String get settingsTitle => '设置';

  @override
  String get accountSettings => '账号';

  @override
  String get networkSettings => '网络';

  @override
  String get networkMode => '自动兼容网络';

  @override
  String get networkModeHint =>
      '默认直连；仅 Pixiv 官方域名在明确的传输失败时尝试严格 HTTPS 候选。不会代理其他流量，也不会关闭证书校验。';

  @override
  String get networkModeListTitle => '网络模式';

  @override
  String get networkModeAutomatic => '自动';

  @override
  String get networkModeAutomaticHint => '标准网络栈：按各主机组选择可达且畅通的路线。';

  @override
  String get networkModeDirectOnly => '仅直连';

  @override
  String get networkModeDirectOnlyHint => '使用系统 DNS + 真实 SNI 直连。适合已知直连可用的网络。';

  @override
  String get networkAdvanced => '高级设置';

  @override
  String get networkAdvancedHint => 'DoH 端点、ECH 前置主机等实现细节。';

  @override
  String get networkAdvancedReset => '恢复默认值';

  @override
  String get networkDoh => '严格回退使用 DoH 解析';

  @override
  String get networkDohHint =>
      '启用后，回退阶梯使用 DoH 解析（默认 Cloudflare DoH：域名端点 + 静态 Anycast IP，免系统 DNS 投毒；自定义端点解析域名）；关闭则仅用系统 DNS。';

  @override
  String get networkDohEndpoints => 'DoH 端点（逗号分隔，https URL）';

  @override
  String get networkEchFrontHost => 'ECH 前置主机';

  @override
  String get networkEchFrontHostHint =>
      '查询 HTTPS RR 获取 ECH config 的域名（默认 cloudflare-ech.com）';

  @override
  String get networkEchHostInvalid => '前置主机名无效';

  @override
  String get networkProbe => '分层连通性探测';

  @override
  String get networkProbeTitle => '分层连通性探测';

  @override
  String get networkProbeHint =>
      '对 Pixiv 四个官方主机逐层测试：系统 DNS → DoH → TCP → TLS(真实 SNI) → 最小请求。TCP 通但 TLS 握手失败 = SNI 被封。';

  @override
  String get networkProbeRun => '开始探测';

  @override
  String get networkProbeRunning => '探测中…';

  @override
  String get networkProbeNotRun => '尚未运行';

  @override
  String get networkProbeHostFailed => '主机探测失败';

  @override
  String get networkProbeCopied => '报告已复制';

  @override
  String get networkProbeDnsDiff => '附加信息：系统 DNS 与 DoH 的公共地址没有交集。';

  @override
  String get networkProbeStepSystemDns => '系统 DNS';

  @override
  String get networkProbeStepDoh => 'DoH';

  @override
  String get networkProbeStepTcp => 'TCP';

  @override
  String get networkProbeStepTls => 'TLS';

  @override
  String get networkProbeStepHttp => '最小请求';

  @override
  String get networkProbeStepEch => 'ECH';

  @override
  String get networkProbeStepNoSni => '空 SNI';

  @override
  String get networkProbeStepOk => '成功';

  @override
  String get networkProbeStepFailed => '失败';

  @override
  String get networkProbeStepSkipped => '跳过';

  @override
  String get networkProbeConclusionAllReachable => '可访问';

  @override
  String get networkProbeConclusionDnsPolluted => 'DNS 污染';

  @override
  String get networkProbeConclusionSniBlocked => 'SNI 被封';

  @override
  String get networkProbeConclusionEchAvailable => '应选 ECH';

  @override
  String get networkProbeConclusionNoSniAvailable => '应选空 SNI';

  @override
  String get networkProbeConclusionIpBlackholed => 'IP 黑洞';

  @override
  String get networkProbeConclusionAppLayer => '应用层';

  @override
  String get networkProbeConclusionInconclusive => '不确定';

  @override
  String get copy => '复制';

  @override
  String get themeSettings => '主题';

  @override
  String get languageSettings => '语言';

  @override
  String get translateSettings => '翻译';

  @override
  String get browseSettings => '浏览设置';

  @override
  String get downloadSettings => '下载设置';

  @override
  String get historySettings => '历史记录';

  @override
  String get historyView => '查看浏览历史';

  @override
  String get historyEmpty => '暂无浏览历史';

  @override
  String get historyLoadFailed => '历史记录加载失败';

  @override
  String get historyDelete => '删除历史记录';

  @override
  String get historyDeleteAll => '删除全部历史记录';

  @override
  String get historyDeleteHint => '删除后将不可恢复';

  @override
  String get blockTagSettings => '屏蔽标签';

  @override
  String get downloaderSettings => '下载任务';

  @override
  String get aboutSettings => '关于';

  @override
  String get signedOut => '未登录';

  @override
  String get currentAccount => '当前账号';

  @override
  String get accountId => '账号 ID';

  @override
  String get reauthRequired => '需要重新登录';

  @override
  String get accountProfile => '个人资料';

  @override
  String get accountReadFailed => '读取账号状态失败';

  @override
  String get reopen => '重新打开';

  @override
  String get dismiss => '知道了';

  @override
  String get profileEditTitle => '编辑个人资料';

  @override
  String get profileEditLoadFailed => '个人资料加载失败';

  @override
  String get profileEditUnavailable => '当前没有可用的应用内资料编辑通道。';

  @override
  String get profileEditPending => '资料已提交，等待验证后才会生效。';

  @override
  String get profileEditConfirmed => '资料已确认并同步。';

  @override
  String get profileEditDisplayName => '昵称';

  @override
  String get profileEditComment => '自我介绍';

  @override
  String get profileEditWebpage => '网页';

  @override
  String get profileEditAvatar => '头像';

  @override
  String get profileEditBackground => '背景图';

  @override
  String get profileEditCurrentPassword => '当前密码';

  @override
  String get profileEditFieldUnsupported => '当前通道不支持此字段';

  @override
  String get profileEditImageChoose => '选择一张受支持的图片';

  @override
  String get profileEditChooseImage => '选择图片';

  @override
  String get profileEditSave => '保存资料';

  @override
  String get profileEditLeaveTitle => '放弃未保存的修改？';

  @override
  String get profileEditLeaveDetail => '当前修改尚未提交，离开后会丢失。';

  @override
  String get profileEditLeaveConfirm => '放弃修改';

  @override
  String get accountManagement => '账号管理';

  @override
  String get addAccount => '添加账号';

  @override
  String get switchAccount => '切换账号';

  @override
  String get removeAccount => '移除账号';

  @override
  String get removeAccountConfirm => '确定移除这个账号？';

  @override
  String get noAccounts => '暂无账号';

  @override
  String get profileReadOnly => '这里显示当前账号的已保存资料。完整资料编辑由个人资料模块提供。';

  @override
  String get imageSource => '图片源';

  @override
  String get imageSourceNormal => '官方 CDN（系统 DNS / HTTPS）';

  @override
  String get previewQuality => '预览质量';

  @override
  String get viewQuality => '查看质量';

  @override
  String get detailQuality => '详情质量';

  @override
  String get qualityMedium => '中图';

  @override
  String get qualityLarge => '大图';

  @override
  String get qualityOriginal => '原图';

  @override
  String get scaleQuality => '查看质量（原图）';

  @override
  String get localHistory => '本地浏览历史';

  @override
  String get pixivHistory => 'Pixiv 浏览历史';

  @override
  String get blockR18 => '本地屏蔽 R-18 作品';

  @override
  String get blockAI => '本地屏蔽 AI 作品';

  @override
  String get maxDownloadCount => '最大并行下载数';

  @override
  String get namingRule => '文件命名规则';

  @override
  String get namingRuleHint => '留空使用默认命名';

  @override
  String get saveFolder => '保存目录';

  @override
  String get saveLocation => '保存位置';

  @override
  String get saveLocationAlbum => '相册';

  @override
  String get saveLocationPixivAlbum => 'PixivFunc 相册（默认）';

  @override
  String get saveLocationCustomAlbum => '自定义相册名称';

  @override
  String get saveLocationCustomAlbumHint => '仅字母、数字、中文与下划线';

  @override
  String get saveLocationUseCustomAlbum => '使用自定义相册';

  @override
  String get saveLocationAlbumInvalid => '相册名称无效';

  @override
  String get saveLocationSafFolder => '文件夹（系统目录选择）';

  @override
  String get saveLocationSafFolderHint => '通过系统 SAF 选择目录并持久授权';

  @override
  String get saveLocationSafPicked => '已选择文件夹';

  @override
  String get namingPreset => '文件命名预设';

  @override
  String get namingPresetId => '作品 ID（默认）';

  @override
  String get namingPresetArtistTitleId => '作者 - 标题 - ID';

  @override
  String get namingPresetTitleId => '标题 - ID';

  @override
  String get namingPresetCustom => '自定义模板';

  @override
  String get namingTemplate => '命名模板';

  @override
  String namingTemplateHint(
    String artist,
    String title,
    String id,
    String page,
    String ext,
  ) {
    return '${artist}_${title}_${id}_p$page.$ext';
  }

  @override
  String get namingTemplateInvalid => '模板包含不支持的变量或非法字符';

  @override
  String get namingPreview => '预览';

  @override
  String namingTemplateVariables(
    String artist,
    String title,
    String id,
    String page,
    String ext,
    String date,
  ) {
    return '变量：$artist $title $id $page $ext $date；非法字符自动替换为 _，超长自动裁剪。';
  }

  @override
  String get notConfigured => '未配置';

  @override
  String get translateProvider => '翻译服务';

  @override
  String get translateGoogle => 'Google Translate';

  @override
  String get translateDisabled => '关闭';

  @override
  String get translateBaidu => '百度翻译';

  @override
  String get translateLlm => '自定义 LLM（OpenAI 兼容）';

  @override
  String get translateBaiduCredential => '百度 AppID / 密钥';

  @override
  String get translateLlmCredential => 'LLM 接口与密钥';

  @override
  String get translateBaiduAppId => 'AppID';

  @override
  String get translateBaiduSecret => '密钥 (Secret)';

  @override
  String get translateLlmBaseUrl => '接口地址（HTTPS）';

  @override
  String get translateLlmApiKey => 'API Key';

  @override
  String get translateLlmModel => '模型名（可选）';

  @override
  String get translateCredentialsSave => '保存到安全存储';

  @override
  String get translateCredentialsClear => '清除凭据';

  @override
  String get translateCredentialsSaved => '已保存到安全存储';

  @override
  String get translateCredentialsCleared => '凭据已清除';

  @override
  String get translateCredentialsStoreError => '安全存储操作失败';

  @override
  String get translateCredentialsInvalid => '输入不完整或接口地址不是 HTTPS';

  @override
  String get translateBaiduHint =>
      '百度翻译标准版无需认证，但只有 5 万字符/月、每秒 1 次，评论翻译基本不够；高级版需个人实名认证（姓名 + 身份证号），100 万字符/月、每秒 10 次。凭据仅用于翻译请求。';

  @override
  String get translateLlmCredentialHint =>
      '仅允许 HTTPS 接口；翻译使用固定提示词，不开放模型与高级参数。评论正文与译文不会持久化。';

  @override
  String get translateCredentialHint => '翻译凭据不会写入普通设置；需要时由安全存储管理。';

  @override
  String get historySettingsHint => '历史记录开关由历史模块读取；关闭后不会新增对应记录。';

  @override
  String get blockTagInputHint => '输入标签后添加';

  @override
  String get noBlockedTags => '暂无屏蔽标签';

  @override
  String get downloaderSettingsHint => '下载任务由共享 DownloadManager 实时维护。';

  @override
  String get downloadTasksEmpty => '暂无下载任务';

  @override
  String get downloadQueued => '排队中';

  @override
  String get downloadRunning => '下载中';

  @override
  String get downloadCanceling => '取消中';

  @override
  String get downloadSucceeded => '已完成';

  @override
  String get downloadFailed => '失败';

  @override
  String get downloadCanceled => '已取消';

  @override
  String get retryDownload => '重试';

  @override
  String get cancelDownload => '取消';

  @override
  String get aboutVersion => '版本';

  @override
  String get aboutCheckUpdate => '检查更新';

  @override
  String get aboutCheckingUpdate => '正在检查更新…';

  @override
  String get aboutUpdateAvailable => '发现新版本';

  @override
  String get aboutUpdateNoUpdate => '已是最新版本';

  @override
  String get aboutUpdatePrerelease => '发现预发布版本，当前稳定通道不会安装';

  @override
  String get aboutUpdateDownload => '下载并安装';

  @override
  String get aboutUpdateDownloading => '正在下载并验证…';

  @override
  String get aboutUpdateConfirmTitle => '确认更新';

  @override
  String get aboutUpdateConfirmDetail => '只会安装通过签名、大小、哈希、包名和签名证书校验的 APK。是否继续？';

  @override
  String get aboutUpdatePermission => '需要允许此来源安装应用，然后再次确认安装。';

  @override
  String get aboutUpdateStarted => '已打开系统安装器';

  @override
  String get aboutUpdateStore => '此构建由 F-Droid 管理更新。';

  @override
  String get aboutUpdateUnavailable => '更新检查当前不可用';

  @override
  String get aboutUpdateFailed => '更新检查或安装失败，请稍后重试';

  @override
  String get aboutLicense => '许可证';

  @override
  String get aboutAttribution => '归属';

  @override
  String get aboutSource => '项目源码';

  @override
  String get aboutLicenseText => '本项目基于 Pixiv Func 公开源码，遵循 GNU AGPL v3.0。';

  @override
  String get aboutAttributionText => '原项目作者：git-xiaocao（小草）。';

  @override
  String get settingsReadFailed => '读取设置失败';

  @override
  String get settingsWriteFailed => '设置保存失败';

  @override
  String get add => '添加';

  @override
  String get viewerNoImages => '没有可显示的图片';

  @override
  String get downloadAll => '下载全部';

  @override
  String get downloadQueuedMessage => '已加入下载队列';

  @override
  String downloadSubmissionFailed(String error) {
    return '下载失败：$error';
  }

  @override
  String get ugoiraSaveGif => '保存 GIF';

  @override
  String get ugoiraLoadCanceled => '加载已取消';

  @override
  String get ugoiraLoginRequired => '请先登录后保存 GIF';

  @override
  String get ugoiraSaved => 'GIF 已保存';

  @override
  String get ugoiraSaveCanceled => 'GIF 保存已取消';

  @override
  String ugoiraSaveFailed(String error) {
    return 'GIF 保存失败：$error';
  }

  @override
  String ugoiraArchiveInvalid(String error) {
    return '动图压缩包无效：$error';
  }

  @override
  String ugoiraFrameCorrupt(String error) {
    return '动图帧损坏：$error';
  }

  @override
  String ugoiraLoadFailed(String error) {
    return '动图加载失败：$error';
  }

  @override
  String get homeRecommended => '推荐';

  @override
  String get homeRanking => '排行';

  @override
  String get homeMe => '我的';

  @override
  String get homeExitHint => '再按一次退出';

  @override
  String get bookmarkIllust => '收藏插画';

  @override
  String get bookmarkNovel => '收藏小说';

  @override
  String bookmarkOperationFailed(String error) {
    return '收藏操作失败：$error';
  }

  @override
  String get save => '保存';

  @override
  String get saved => '已保存';

  @override
  String get retry => '重试';

  @override
  String get relatedWorks => '相关作品';

  @override
  String get cancel => '取消';

  @override
  String get confirm => '确定';

  @override
  String get rankingDay => '每日';

  @override
  String get rankingDayR18 => '每日(R-18)';

  @override
  String get rankingDayMale => '每日(男性欢迎)';

  @override
  String get rankingDayMaleR18 => '每日(男性欢迎 & R-18)';

  @override
  String get rankingDayFemale => '每日(女性欢迎)';

  @override
  String get rankingDayFemaleR18 => '每日(女性欢迎 & R-18)';

  @override
  String get rankingWeek => '每周';

  @override
  String get rankingWeekR18 => '每周(R-18)';

  @override
  String get rankingWeekOriginal => '每周(原创)';

  @override
  String get rankingWeekRookie => '每周(新人)';

  @override
  String get rankingMonth => '每月';

  @override
  String get rankingEmpty => '暂无榜单内容';

  @override
  String rankingLoadFailed(String mode) {
    return '$mode加载失败';
  }

  @override
  String get rankingLoadMoreFailed => '加载更多失败';

  @override
  String get profileWork => '作品';

  @override
  String get profileBookmarked => '收藏';

  @override
  String get profileFollowing => '关注';

  @override
  String get profileFans => '粉丝';

  @override
  String get profileMyPixiv => '好P友';

  @override
  String get profileAbout => '关于';

  @override
  String get profileIllust => '插画';

  @override
  String get profileManga => '漫画';

  @override
  String get profileNovel => '小说';

  @override
  String get searchTitle => '搜索';

  @override
  String get searchHint => '搜索作品、用户或标签';

  @override
  String get searchReverseImage => '反向搜图';

  @override
  String get searchTrending => '热门标签';

  @override
  String get searchNoTrending => '暂无热门标签';

  @override
  String get searchTrendingFailed => '热门标签加载失败';

  @override
  String get searchIllustManga => '插画 & 漫画';

  @override
  String get searchNovel => '小说';

  @override
  String get searchUser => '用户';

  @override
  String get searchCancel => '取消';

  @override
  String get searchSubmit => '搜索';

  @override
  String get searchClear => '清除';

  @override
  String get searchLoading => '正在搜索';

  @override
  String get searchNoResults => '暂无搜索结果';

  @override
  String get searchLoadFailed => '搜索失败';

  @override
  String get searchLoadMoreFailed => '加载更多搜索结果失败';

  @override
  String get searchRetry => '重试';

  @override
  String get searchRefreshFailed => '刷新失败';

  @override
  String get searchInputEmpty => '请输入搜索内容';

  @override
  String get searchReverseUnavailable => '反向搜图暂不可用';

  @override
  String get searchReverseUnavailableDetail =>
      '当前没有通过凭据、服务条款和隐私审查的结构化服务；不会上传图片或执行网页抓取。';

  @override
  String get searchReversePick => '选择图片';

  @override
  String get searchReversePrivacy => '隐私提示';

  @override
  String get searchReversePrivacyDetail =>
      '图片只会在你确认搜索后发送给已批准的服务；取消或失败后会立即清理临时文件。';

  @override
  String get searchReversePreparing => '正在准备图片…';

  @override
  String get searchReverseSearching => '正在搜索…';

  @override
  String get searchReverseCancel => '取消';

  @override
  String get searchReverseUse => '开始反向搜图';

  @override
  String get searchReverseRetry => '重新选择';

  @override
  String get searchReverseReady => '图片已准备好';

  @override
  String get searchReverseNoResults => '没有找到匹配结果';

  @override
  String get searchReverseIntentFailed => '分享的图片无法使用';

  @override
  String get searchReverseOpenExternal => '打开来源';

  @override
  String get searchReverseOpenFailed => '无法打开来源链接';

  @override
  String get searchReverseRateLimited => '搜索过于频繁，请稍后再试';

  @override
  String searchReverseRateLimitedWait(int seconds) {
    return '约 $seconds 秒后可重试';
  }

  @override
  String get searchReverseDailyLimit => '今日匿名搜索额度已用完，明天再试';

  @override
  String get searchReverseChallenge => 'SauceNAO 要求人机验证，本次搜索未完成，请稍后再试';

  @override
  String get searchReversePageLoadFailed => '结果页加载失败';

  @override
  String get searchReverseIntro => '选择图片后，将匿名上传到 SauceNAO 进行反向检索；结果页在应用内打开。';

  @override
  String get searchNoRepresentative => '该标签暂无代表作品';

  @override
  String get searchFilters => '筛选';

  @override
  String get searchReset => '重置';

  @override
  String get searchApply => '应用';

  @override
  String get searchTarget => '搜索范围';

  @override
  String get searchPartialTags => '标签部分匹配';

  @override
  String get searchExactTags => '标签完全匹配';

  @override
  String get searchTitleCaption => '标题和简介';

  @override
  String get searchSort => '排序';

  @override
  String get searchDateDesc => '最新发布';

  @override
  String get searchDateAsc => '最早发布';

  @override
  String get searchPopularDesc => '热门排序';

  @override
  String get searchDuration => '发布时间';

  @override
  String get searchAllTime => '不限时间';

  @override
  String get searchWithinDay => '一天内';

  @override
  String get searchWithinWeek => '一周内';

  @override
  String get searchWithinMonth => '一个月内';

  @override
  String get searchStartDate => '开始日期';

  @override
  String get searchEndDate => '结束日期';

  @override
  String get searchNoSuggestions => '没有匹配建议';

  @override
  String get searchUserAccount => '账号';

  @override
  String get illustDetailTitle => '作品详情';

  @override
  String get illustDetailCreateDateUnknown => '投稿日期未知';

  @override
  String illustDetailCreateDate(String date) {
    return '投稿日期：$date';
  }

  @override
  String illustDetailSize(int width, int height) {
    return '尺寸：${width}x$height';
  }

  @override
  String illustDetailOpenLinkFailed(String error) {
    return '无法打开链接：$error';
  }

  @override
  String illustDetailRestricted(int id) {
    return '该作品已被删除或受限（ID: $id）';
  }

  @override
  String get illustDetailNotFound => '作品不存在或已被删除';

  @override
  String get illustDetailLoadFailed => '作品加载失败';

  @override
  String get commentTitle => '评论';

  @override
  String get commentInput => '添加评论';

  @override
  String get commentReply => '回复';

  @override
  String get commentReplyTo => '回复给';

  @override
  String get commentCancelReply => '取消回复';

  @override
  String get commentSend => '发送';

  @override
  String get commentDelete => '删除评论';

  @override
  String get commentDeleteConfirm => '确定删除这条评论吗？';

  @override
  String get commentDeleteFailed => '删除评论失败';

  @override
  String get commentSendFailed => '发送评论失败';

  @override
  String get commentLoadFailed => '评论加载失败';

  @override
  String get relatedLoadFailed => '相关作品加载失败';

  @override
  String get commentLoadMoreFailed => '加载更多评论失败';

  @override
  String get commentNoResults => '暂无评论';

  @override
  String get commentReplies => '回复';

  @override
  String get commentTranslate => '翻译';

  @override
  String get commentTranslation => '翻译结果';

  @override
  String get commentTranslationUnavailable => '翻译服务不可用，请在设置中开启。';

  @override
  String get commentTranslationFailed => '翻译失败';

  @override
  String get commentTranslationInvalidCredentials => '翻译凭据无效，请在设置中检查。';

  @override
  String get commentTranslationRateLimited => '翻译过于频繁或额度已用完';

  @override
  String get commentEmoji => 'Emoji';

  @override
  String get commentStamps => 'Stamp';

  @override
  String get commentPermissionDenied => '只能删除自己的评论';

  @override
  String get newTitle => '新作';

  @override
  String get newFollowing => '关注';

  @override
  String get newEveryone => '大家';

  @override
  String get newMyPixiv => '好P友';

  @override
  String get newIllust => '插画';

  @override
  String get newNovel => '小说';

  @override
  String get recommendedIllust => '插画';

  @override
  String get recommendedManga => '漫画';

  @override
  String get recommendedNovel => '小说';

  @override
  String get recommendedUser => '用户';

  @override
  String get recommendedEmpty => '暂无推荐内容';

  @override
  String get recommendedLoadFailed => '推荐加载失败';

  @override
  String get recommendedLoadMoreFailed => '加载更多失败';

  @override
  String get recommendedEnd => '没有更多了';

  @override
  String get newLoading => '正在加载新作';

  @override
  String get newEmpty => '暂无内容';

  @override
  String get newLoadFailed => '新作加载失败';

  @override
  String get newLoadMoreFailed => '加载更多新作失败';

  @override
  String get newRetry => '重试';

  @override
  String get newRefreshFailed => '刷新失败';

  @override
  String get profileId => '用户 ID';

  @override
  String get profileAccount => '账号';

  @override
  String get profileIntroduction => '简介';

  @override
  String get profileBirthday => '生日';

  @override
  String get profileGender => '性别';

  @override
  String get profileRegion => '地区';

  @override
  String get profileJob => '职业';

  @override
  String get profileWebsite => '主页';

  @override
  String get profileWorkspace => '工作环境';

  @override
  String get profileStats => '统计';

  @override
  String get profileLoading => '正在加载用户资料';

  @override
  String get profileNotFound => '用户不存在或已被删除';

  @override
  String get profileBlocked => '该用户资料不可见';

  @override
  String get profileLoadFailed => '用户资料加载失败';

  @override
  String get profileItemsEmpty => '暂无内容';

  @override
  String get profileLoadMoreFailed => '加载更多失败';

  @override
  String get profileRetry => '重试';

  @override
  String get profileNovelPending => '小说列表将在 Novel Reader 模块接入';

  @override
  String get profileShare => '分享用户';

  @override
  String get profileShareHint => '可分享以下用户链接';

  @override
  String get profileShareClose => '关闭';

  @override
  String get profileSettings => '设置';

  @override
  String get restrictSelector => '选择公开范围';

  @override
  String get restrictPublic => '公开';

  @override
  String get restrictPrivate => '私密';

  @override
  String get follow => '关注';

  @override
  String get followed => '已关注';

  @override
  String get followUser => '关注用户';

  @override
  String get followFailed => '关注操作失败';

  @override
  String get userPreviewFollow => '关注';

  @override
  String get novelLoading => '正在加载小说';

  @override
  String get novelNotFound => '小说不存在或已被删除';

  @override
  String get novelRestricted => '该小说受限，无法阅读';

  @override
  String get novelContentUnavailable => '当前 API 未提供小说正文';

  @override
  String get novelLoadFailed => '小说加载失败';

  @override
  String get novelRetry => '重试';

  @override
  String get novelNoContent => '暂无正文';

  @override
  String get novelWords => '字';

  @override
  String get novelSeries => '系列';

  @override
  String get novelSeriesUnavailable => '系列信息暂不可用';

  @override
  String get novelPrevious => '上一篇';

  @override
  String get novelNext => '下一篇';

  @override
  String get novelDecreaseFont => '减小字号';

  @override
  String get novelIncreaseFont => '增大字号';

  @override
  String get novelReadingProgress => '阅读进度';
}
