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
  String get welcome1 => '感谢使用 Parfait';

  @override
  String get welcome2 => '下面将进行首次启动设置';

  @override
  String get start => '开始';

  @override
  String get selectLanguage => '选择您的语言';

  @override
  String get next => '下一步';

  @override
  String get dark => '深色';

  @override
  String get light => '浅色';

  @override
  String get system => '跟随系统';

  @override
  String get loginTitle => '注册 或 登录';

  @override
  String get loginProxyNoticeTitle => '提示';

  @override
  String get loginProxyNoticeBody =>
      '由于网络环境限制，登录和注册需要你先在系统或其他应用中开启代理（梯子）。Parfait 不提供内置代理。';

  @override
  String get loginProxyNoticeCancel => '取消';

  @override
  String get loginProxyNoticeContinue => '我已开启代理';

  @override
  String get register => '注册';

  @override
  String get login => '登录';

  @override
  String get loginPageClosed => '页面已关闭，请重新打开';

  @override
  String get loginCallbackInvalid => '登录回调无效，请重新登录';

  @override
  String loginNetworkError(String status) {
    return '网络错误 (HTTP $status)';
  }

  @override
  String get loginPageLoadFailed => '页面加载失败';

  @override
  String get loginWebView2Missing =>
      '登录需要 WebView2 Runtime，但当前系统未检测到它。请安装后重新打开本页。';

  @override
  String get loginInstallWebView2 => '安装 WebView2 Runtime';

  @override
  String get loginReload => '重新加载';

  @override
  String get loginRestart => '重新登录';

  @override
  String get loginFailed => '登录失败';

  @override
  String get networkCompatibility => 'Pixiv 官方网络兼容';

  @override
  String get networkCompatibilityHint =>
      '开启时，访问 Pixiv 官方域名会在加密 DNS、ECH、无 SNI 等兼容连接与直连之间选择能用的一种，并记住成功的方式。最后一档兼容连接不校验证书；关闭此开关即只走直连。不会代理其他流量。';

  @override
  String get useLoginWithClipboard => '使用剪贴板数据登录';

  @override
  String get accountTransferExportTitle => '导出账号凭据';

  @override
  String get accountTransferWarning => '剪贴板内容会短时存在，可能被其他应用读取；此格式不提供加密或发送者认证。';

  @override
  String get loginClipboardHint => '先在已登录的设备上打开「我的 → 账号管理 → 导出账号凭据」复制，再回到这里导入。';

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
  String get loginAgree => '登录即表示你同意';

  @override
  String get userAgreement => '《Parfait 用户使用协议》';

  @override
  String get agreementTitle => 'Parfait 用户使用协议';

  @override
  String get agreementIntro =>
      '感谢使用 Parfait。使用本应用即表示你已阅读并同意以下条款；如不同意，请停止使用本应用。';

  @override
  String get agreementServiceTitle => '服务说明';

  @override
  String get agreementServiceBody =>
      'Parfait 是开源的非官方 Pixiv 第三方客户端，与 Pixiv Inc. 没有隶属关系，源代码以 AGPL-3.0 许可证公开。\n\n本应用不提供内容，所有作品与资料都来自 Pixiv。';

  @override
  String get agreementAccountTitle => '账号与登录';

  @override
  String get agreementAccountBody =>
      '注册和登录在应用内打开的 Pixiv 官方网页中完成；本应用不读取、也不保存你的密码。登录后得到的凭据保存在系统安全存储中。\n\n「导出账号凭据」会把凭据以明文放进系统剪贴板：Android 13 及以上会标记为敏感内容，5 分钟后自动清除。请只在自己的设备之间使用。\n\n使用第三方客户端是否符合 Pixiv 的规则由你自行判断，账号因此受到的限制由你自行承担。';

  @override
  String get agreementUsageTitle => '使用规范';

  @override
  String get agreementUsageBody =>
      '请遵守所在地法律和 Pixiv 的使用条款。不得把本应用用于批量抓取、自动刷量、骚扰他人，或其他会损害 Pixiv 与创作者权益的用途。\n\n限制级内容按你的 Pixiv 账号设置显示；未成年人不得浏览限制级内容。';

  @override
  String get agreementContentTitle => '内容与版权';

  @override
  String get agreementContentBody =>
      '作品、评论、用户资料等内容的版权归相应权利人所有。下载仅供个人保存；转载或再分发须取得权利人许可。';

  @override
  String get agreementNetworkTitle => '网络访问';

  @override
  String get agreementNetworkBody =>
      '在默认的「自动」网络模式下，访问 Pixiv 官方域名（API、登录、网页、图片）时，本应用会在以下连接方式中选择能用的一种，并记住成功的方式，之后优先使用：\n• 经 Cloudflare 的 ECH 加密握手连接；\n• 通过加密 DNS（默认 Cloudflare、Google）解析地址后连接，获取 ECH 配置时查询阿里云 DNS；\n• 不带 SNI 连接 Pixiv 图片服务器；\n• 系统直连。\n以上方式都会校验证书。\n\n都失败时，最后一档会使用内置或上次可用的 Pixiv 地址、不带 SNI 连接，并且不校验证书；这一档成功后同样会被记住。如果网络中有人冒充 Pixiv 服务器，你的登录凭据和浏览内容可能被截获。如不接受，请在「设置 → 网络 → 网络模式」选择「仅直连」，这会关闭以上所有兼容连接。\n\n图片源默认为「自动」：在官方图片服务器与第三方镜像（i.pixiv.re、i.pixiv.nl、i.pixiv.cat）之间测速，使用最快的一个。经由镜像时，镜像运营方能看到你请求的图片地址和你的 IP 地址。可在「设置 → 浏览设置 → 图片源」固定为官方源。\n\n本应用不代理其他流量；网络可用性、接口变更与服务中断不由本应用保证。';

  @override
  String get agreementThirdPartyTitle => '第三方服务';

  @override
  String get agreementThirdPartyBody =>
      '以下服务只在你使用相应功能时访问：\n• 评论翻译（默认关闭）：把评论原文发送给你选择的 Google 翻译、百度翻译，或你填写的 OpenAI 兼容接口；\n• 以图搜图：把你选择的图片上传到 SauceNAO 或 iqdb。\n\n登录网页由 Pixiv 提供，可能加载 Pixiv 使用的第三方资源（例如人机验证）。\n\n检查更新：本应用每 24 小时最多自动访问一次 GitHub 上的版本清单；F-Droid 版本不检查更新。';

  @override
  String get agreementPrivacyTitle => '隐私与本地数据';

  @override
  String get agreementPrivacyBody =>
      '设置、缓存、浏览历史、稍后再看与下载文件都保存在本机。本应用没有统计、广告或崩溃上报，不会把你的数据发送到开发者的服务器。\n\n崩溃日志只保存在本机，由你决定是否通过「我的 → 关于 → 导出日志」分享。\n\n卸载应用或清除数据会删除这些内容（保存到公共目录的下载文件除外）。';

  @override
  String get agreementDisclaimerTitle => '免责声明';

  @override
  String get agreementDisclaimerBody =>
      '本应用按现状提供，不保证没有错误或持续可用。因网络、账号、第三方服务或不可抗力造成的内容丢失、访问失败或其他损失，作者在法律允许范围内不承担责任。';

  @override
  String get agreementUpdatesTitle => '协议更新';

  @override
  String get agreementUpdates => '协议可能随功能或法律变化而更新；更新后继续使用即表示接受更新后的协议。';

  @override
  String get settingsTitle => '设置';

  @override
  String get settingsSearchHint => '搜索设置';

  @override
  String get settingsSearchEmpty => '没有匹配的设置';

  @override
  String get settingsEntrySummary => '外观、浏览、网络、下载、备份';

  @override
  String get settingsGroupAppearance => '外观';

  @override
  String get settingsGroupNetwork => '网络与下载';

  @override
  String get settingsGroupBrowse => '浏览';

  @override
  String get settingsGroupLibrary => '我的内容';

  @override
  String get settingsGroupDeveloper => '开发者';

  @override
  String get developerOptionsUnlocked => '开发者选项已开启';

  @override
  String developerOptionsCountdown(int count) {
    return '再点 $count 次开启开发者选项';
  }

  @override
  String get settingsGroupData => '数据';

  @override
  String get accountSettings => '账号';

  @override
  String get networkSettings => '网络';

  @override
  String get networkMode => 'Pixiv 官方网络兼容';

  @override
  String get networkModeHint => '打不开时自动尝试兼容通道；只作用于 Pixiv 官方域名，不会代理其他流量。';

  @override
  String get networkModeListTitle => '网络模式';

  @override
  String get networkModeAutomatic => '自动';

  @override
  String get networkModeAutomaticHint => '自动选择能用的连接方式。';

  @override
  String get networkModeDirectOnly => '仅直连';

  @override
  String get networkModeDirectOnlyHint => '只走系统直连；适合直连可用的网络。';

  @override
  String get networkModeCompatPrefer => '兼容优先';

  @override
  String get networkModeCompatPreferHint => '优先尝试兼容通道，不行再直连；适合直连已被阻断的网络。';

  @override
  String get networkEffectiveRoutes => '当前生效路由';

  @override
  String get networkEffectiveRoutesEmpty => '还没有路由记录——逛一逛再刷新。';

  @override
  String get networkRouteForImages => '图片加载';

  @override
  String get networkRouteKindDirect => '直连';

  @override
  String get networkRouteKindCompat => '兼容通道';

  @override
  String get networkThirdParty => '第三方服务可达性';

  @override
  String get networkThirdPartyAuto => '进入本页时自动检测一次。';

  @override
  String get networkThirdPartyHint => '走系统网络，你的 VPN/代理会照常生效。';

  @override
  String get networkReachable => '可达';

  @override
  String get networkUnreachable => '不可达';

  @override
  String get networkChecking => '检测中…';

  @override
  String get networkAdvanced => '高级设置';

  @override
  String get networkAdvancedHint => '面向高级用户的底层选项。';

  @override
  String get networkAdvancedReset => '恢复默认值';

  @override
  String get networkAdvancedResetConfirm => '将 DoH 端点与 ECH 前置主机恢复为默认值。';

  @override
  String get networkDoh => '严格回退使用 DoH 解析';

  @override
  String get networkDohHint =>
      '启用后，回退阶梯使用 DoH 解析（默认 Cloudflare DoH：域名端点 + 静态 Anycast IP，免系统 DNS 投毒；自定义端点解析域名）；关闭则仅用系统 DNS。';

  @override
  String get networkDohEndpoints => 'DoH 端点';

  @override
  String get networkDohEndpointsHint => '逗号分隔的 https URL';

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
  String get networkProbeHint => '逐层检测 Pixiv 连通性，定位打不开的原因。';

  @override
  String get frameProbeTitle => '帧探针';

  @override
  String get frameProbeHint =>
      '滚动时记录帧耗时。可离开本页去目标页面滚动，回来停止并复制报告。仅 debug/profile 构建可见。';

  @override
  String get frameProbeStart => '开始记录';

  @override
  String get frameProbeRecording => '录制中';

  @override
  String get frameProbeCapHint => '已达帧数上限，正在丢弃最旧帧。';

  @override
  String get frameProbeStop => '停止';

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
  String get networkProbeOverview => '探测总览';

  @override
  String get networkProbeWorst => '最劣';

  @override
  String get networkProbeDetails => '明细';

  @override
  String get networkProbeNotPersisted => '结果不保存——离开本页即丢失。';

  @override
  String get networkProbeAdviceAllReachable => '全部可达，无需调整。';

  @override
  String get networkProbeAdviceEchAvailable => 'ECH 可用——「自动」或「兼容优先」模式都会用它。';

  @override
  String get networkProbeAdviceNoSniAvailable => '空 SNI 通道可用——「兼容优先」模式会用它。';

  @override
  String get networkProbeAdviceSniBlocked => '真实 SNI 被封——建议把网络模式设为「兼容优先」。';

  @override
  String get networkProbeAdviceDnsPolluted => '系统 DNS 被污染——保持 DoH 开启即可绕过。';

  @override
  String get networkProbeAdviceIpBlackholed => 'IP 被黑洞，客户端无法绕过——请更换网络。';

  @override
  String get networkProbeAdviceAppLayer => '传输层正常，问题在应用层——可复制报告反馈。';

  @override
  String get networkProbeAdviceInconclusive => '无法得出结论——换个网络或稍后重试。';

  @override
  String get copy => '复制';

  @override
  String get themeSettings => '主题';

  @override
  String get followSystemColors => '跟随系统取色';

  @override
  String get followSystemColorsHint => '用壁纸或系统强调色作为主题色';

  @override
  String get followSystemColorsUnavailable => '当前系统不提供系统取色';

  @override
  String get languageSettings => '语言';

  @override
  String get translateSettings => '翻译';

  @override
  String get browseSettings => '浏览设置';

  @override
  String get settingsBrowseHint => '本地屏蔽、图片画质';

  @override
  String get downloadSettings => '下载设置';

  @override
  String get historySettings => '历史记录';

  @override
  String get historyRecordLocal => '记录本地浏览历史';

  @override
  String get historyRecordPixiv => '记录到 Pixiv 浏览历史';

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
  String get profileEditImageFailed => '图片处理失败';

  @override
  String get profileEditChooseImage => '选择图片';

  @override
  String get profileChangeAvatar => '更换头像';

  @override
  String get profileChangeBackground => '更换背景图';

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
  String get accountSwitching => '正在切换…';

  @override
  String get removeAccount => '移除账号';

  @override
  String get removeAccountConfirm => '确定移除这个账号？';

  @override
  String get noAccounts => '暂无账号';

  @override
  String get profileReadOnly => '这里显示当前账号的已保存资料。完整资料编辑由个人资料模块提供。';

  @override
  String get serverDisplaySettings => '账号显示设置';

  @override
  String get serverDisplayHint => '由 Pixiv 服务端保存，作用于接口为该账号返回的内容。';

  @override
  String get serverShowAi => '显示 AI 生成作品';

  @override
  String get serverRestrictedMode => '受限模式';

  @override
  String get serverDisplayLoadFailed => '服务端设置读取失败';

  @override
  String get serverDisplayWriteFailed => '服务端设置保存失败';

  @override
  String get backupSettings => '备份与导入';

  @override
  String get backupHint => '导出当前设置、屏蔽列表和浏览历史；凭据不会写入文件。';

  @override
  String get backupExport => '导出备份';

  @override
  String get backupExportHint => '选择目录后写入 parfait-backup-*.json';

  @override
  String backupExported(String name) {
    return '已导出 $name';
  }

  @override
  String get backupExportFailed => '导出失败';

  @override
  String get backupImport => '导入备份';

  @override
  String get backupImportHint => '从 JSON 文件导入，可选合并或覆盖';

  @override
  String get backupImportInvalid => '备份文件无效';

  @override
  String get backupImportFailed => '导入失败';

  @override
  String get backupImportStrategyTitle => '选择导入方式';

  @override
  String backupImportPrompt(
    int tags,
    int users,
    int works,
    int history,
    String account,
  ) {
    return '文件包含 $tags 个屏蔽标签、$users 个屏蔽用户、$works 条作品屏蔽、$history 条历史。\n导出账号：$account';
  }

  @override
  String get backupImportOverwriteNote =>
      '覆盖会先清空本地历史并替换作品屏蔽；服务端屏蔽列表只增不删，覆盖不会删除服务器上的屏蔽项。';

  @override
  String get backupMerge => '合并';

  @override
  String get backupOverwrite => '覆盖';

  @override
  String get backupMergeHint => '保留现有数据，添加文件内容';

  @override
  String get backupOverwriteHint => '以文件内容替换本地数据';

  @override
  String backupImportMergeConfirmTitle(
    int tags,
    int users,
    int works,
    int history,
  ) {
    return '将添加 $tags 个屏蔽标签、$users 个屏蔽用户、$works 个屏蔽作品和 $history 条历史记录';
  }

  @override
  String get backupImportOverwriteConfirmTitle => '将清空本地历史，屏蔽作品与设置以文件为准';

  @override
  String backupImportDone(int tags, int users, int works, int history) {
    return '导入完成：新增 $tags 个标签、$users 个用户、$works 项作品屏蔽变更、$history 条历史';
  }

  @override
  String get imageSource => '图片源';

  @override
  String get imageSourceNormal => '官方源';

  @override
  String get imageSourcePixivCat => 'pixiv.cat 镜像';

  @override
  String get imageSourcePixivRe => 'pixiv.re 镜像';

  @override
  String get imageSourcePixivNl => 'pixiv.nl 镜像';

  @override
  String get imageSourceCustom => '自定义反代';

  @override
  String get imageSourceCustomHint =>
      'https://host[/path]，例如 https://i.pixiv.cat';

  @override
  String get imageSourceCustomUnset => '未配置';

  @override
  String get imageSourceCustomInvalid => '无效自定义源：需 https、域名且仅支持 443 端口';

  @override
  String get imageSourceApplyAndTest => '应用并测试';

  @override
  String imageSourceTestOk(String code) {
    return '镜像可达（HTTP $code）';
  }

  @override
  String get imageSourceTestFailed => '镜像连通性测试失败';

  @override
  String get imageSourceUnreachableMainland => '大陆网络通常不可达';

  @override
  String get imageSourceAuto => '自动（默认，按当前网络测速选源）';

  @override
  String imageSourceAutoWinner(String host) {
    return '当前：$host';
  }

  @override
  String get imageSourceAutoPending => '尚未测速，暂按直连';

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
  String get blockR18 => '本地屏蔽 R-18 作品';

  @override
  String get blockAI => '本地屏蔽 AI 作品';

  @override
  String get hideMuted => '直接隐藏被屏蔽的作品';

  @override
  String get hideMutedHint => '关闭后，被屏蔽的作品以模糊卡片显示，点按可临时查看';

  @override
  String get mutedContent => '已屏蔽';

  @override
  String get mutedItemsSettings => '屏蔽管理';

  @override
  String get mutedTagsSection => '屏蔽标签';

  @override
  String get mutedUsersSection => '屏蔽用户';

  @override
  String get mutedWorksSection => '屏蔽作品';

  @override
  String get mutedEmpty => '暂无屏蔽条目';

  @override
  String muteEmptyHint(String action) {
    return '长按作品卡片，选择「$action」';
  }

  @override
  String get muteTagInputHint => '输入要屏蔽的标签';

  @override
  String get muteWork => '屏蔽此作品';

  @override
  String get unmuteWork => '解除屏蔽此作品';

  @override
  String get muteAuthor => '屏蔽作者';

  @override
  String get unmuteAuthor => '解除屏蔽作者';

  @override
  String get unmuteTag => '解除屏蔽';

  @override
  String get muteFailed => '屏蔽操作失败';

  @override
  String get reduceMotion => '减少动态效果';

  @override
  String get reduceMotionHint => '关闭页面转场、列表进场与按压反馈等装饰性动画';

  @override
  String get pressFeedback => '按压反馈';

  @override
  String get pressFeedbackHint => '按下卡片时轻微缩小';

  @override
  String get animationSpeed => '动画速度';

  @override
  String get animationSpeedFast => '快';

  @override
  String get animationSpeedNormal => '标准';

  @override
  String get animationSpeedSlow => '慢';

  @override
  String get animationSpeedHint => '作用于应用内全部动画；水波纹等系统控件动画不受影响';

  @override
  String get animationSpeedReduceHint => '开启「减少动态效果」时不播放动画，速度不生效';

  @override
  String get motionSettings => '动效与触感';

  @override
  String get motionPageTransition => '页面转场';

  @override
  String get pageTransitionStyleSystem => '系统默认';

  @override
  String get pageTransitionStyleSystemHint => '安卓系统转场，支持预测性返回';

  @override
  String get pageTransitionStyleSystemHintOther => '平台默认';

  @override
  String get pageTransitionStyleSharedAxis => '共享轴';

  @override
  String get pageTransitionStyleSharedAxisHint => 'Material 推荐：新旧页面同向滑动并交叉淡化';

  @override
  String get pageTransitionStyleZoom => '缩放';

  @override
  String get pageTransitionStyleZoomHint => '放大进入（Android 10 风格）';

  @override
  String get pageTransitionStyleSlide => '侧滑';

  @override
  String get pageTransitionStyleSlideHint => '从右侧推入，上一页错开并变暗（iOS 风格）';

  @override
  String get maxDownloadCount => '最大并行下载数';

  @override
  String get maxDownloadCountHint => '拖动预览数值，松手后生效';

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
  String get saveLocationPixivAlbum => 'Parfait 相册（默认）';

  @override
  String get saveLocationCustomAlbum => '自定义相册名称';

  @override
  String get saveLocationCustomAlbumHint => '仅字母、数字、中文与下划线';

  @override
  String get saveLocationAlbumInvalid => '相册名称无效';

  @override
  String get saveLocationSafFolder => '文件夹（系统目录选择）';

  @override
  String get saveLocationSafFolderHint => '通过系统 SAF 选择目录并持久授权';

  @override
  String get safStorageInternal => '内部存储';

  @override
  String safStorageSdCard(String volume) {
    return 'SD 卡（$volume）';
  }

  @override
  String get saveLocationUriCopied => '已复制目录 URI';

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
  String get namingVarArtist => '作者名';

  @override
  String get namingVarTitle => '标题';

  @override
  String get namingVarId => '作品 ID';

  @override
  String get namingVarAuthorId => '作者 ID';

  @override
  String get namingVarPage => '页码（从 0 开始）';

  @override
  String get namingVarPage1 => '页码（从 1 开始）';

  @override
  String get namingVarPages => '总页数';

  @override
  String get namingVarExt => '扩展名';

  @override
  String get namingVarW => '宽度';

  @override
  String get namingVarH => '高度';

  @override
  String get namingVarDate => '日期';

  @override
  String get namingVarCreated => '日期和时间';

  @override
  String get namingVarSeries => '系列名';

  @override
  String get namingVarSeriesOrder => '系列内序号';

  @override
  String get namingVarChapters => '系列总话数';

  @override
  String get namingSampleArtist => '作者名';

  @override
  String get namingSampleTitle => '作品标题';

  @override
  String get namingSampleSeries => '系列名';

  @override
  String get namingTemplateSanitizeNote => '非法字符自动替换为 _，超长自动裁剪。';

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
  String get translateCredentialsClearConfirm => '将删除安全存储中的凭据；翻译前需要重新输入。';

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
  String get downloadPaused => '已暂停';

  @override
  String get pauseDownload => '暂停';

  @override
  String get downloadProcessing => '处理中';

  @override
  String get downloadViewResult => '查看';

  @override
  String get downloadRemoveRecord => '移除';

  @override
  String get downloadOpenWork => '打开作品';

  @override
  String get downloadClearCompleted => '清除已完成';

  @override
  String downloadTasksRemoved(int count) {
    return '已移除 $count 条记录';
  }

  @override
  String downloadBatchCancelConfirm(int count) {
    return '取消选中的 $count 项下载？未完成的进度会被丢弃。';
  }

  @override
  String get resumeDownload => '继续';

  @override
  String downloadGroupTitle(int count) {
    return '批量下载 · $count 项';
  }

  @override
  String downloadGroupProgress(int done, int count) {
    return '已完成 $done/$count';
  }

  @override
  String downloadGroupAuthorTitle(String name) {
    return '$name 的作品';
  }

  @override
  String downloadTaskPageLabel(int page, int total) {
    return '第 $page/$total 页';
  }

  @override
  String get downloadAuthorWorks => '下载全部作品';

  @override
  String get downloadAuthorWorksTitle => '下载作者全部作品';

  @override
  String downloadAuthorEnumerating(int count) {
    return '正在枚举作品…已找到 $count 个';
  }

  @override
  String downloadAuthorConfirmBody(int works, int pages) {
    return '将下载该作者的 $works 个作品，共 $pages 页。';
  }

  @override
  String downloadAuthorTruncated(int max) {
    return '作品过多，仅下载前 $max 个。';
  }

  @override
  String get downloadAuthorEmpty => '该作者没有可下载的作品。';

  @override
  String get downloadAuthorFailed => '枚举作品失败';

  @override
  String get downloadCaption => '同时导出作品简介';

  @override
  String get downloadCaptionHint => '下载插画/漫画时，把标题、作者与简介保存为同名 .txt';

  @override
  String get aboutVersion => '版本';

  @override
  String get aboutCheckUpdate => '检查更新';

  @override
  String get aboutCheckingUpdate => '正在检查更新…';

  @override
  String get aboutUpdateAvailable => '发现新版本';

  @override
  String get aboutUpdateOpen => '查看';

  @override
  String get aboutExportLogs => '导出日志';

  @override
  String get aboutNoLogs => '暂无日志';

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
  String get aboutUpdateOffline => '无法连接更新服务，请检查网络后重试';

  @override
  String get aboutUpdateRateLimited => 'GitHub 限流，请稍后重试';

  @override
  String get aboutUpdateInvalid => '更新清单无效，请向开发者反馈';

  @override
  String get aboutUpdateBusy => '已有更新任务进行中';

  @override
  String get aboutUpdateCanceled => '已取消更新安装';

  @override
  String get aboutLicense => '许可证';

  @override
  String get aboutAttribution => '归属';

  @override
  String get aboutSource => '项目源码';

  @override
  String get aboutLicenseText => '本项目基于 Pixiv Func 公开源码，遵循 GNU AGPL v3.0。';

  @override
  String get aboutAttributionText => '版权所有及维护：Lopution。';

  @override
  String get settingsReadFailed => '读取设置失败';

  @override
  String get settingsWriteFailed => '设置保存失败';

  @override
  String settingsMutedSummary(int count) {
    return '$count 个屏蔽项';
  }

  @override
  String settingsDownloadTasksSummary(int count) {
    return '$count 个活动任务';
  }

  @override
  String get settingsCredentialConfigured => '已配置';

  @override
  String get settingsCredentialNotConfigured => '未配置';

  @override
  String get add => '添加';

  @override
  String get viewerNoImages => '没有可显示的图片';

  @override
  String get detailDownloaded => '已下载';

  @override
  String get downloadAll => '下载全部';

  @override
  String get downloadQueuedMessage => '已加入下载队列';

  @override
  String get downloadAlreadyQueued => '已在下载队列中';

  @override
  String get downloadSubmissionFailed => '下载失败';

  @override
  String get downloadFailurePermission => '缺少存储权限';

  @override
  String get downloadFailureResource => '设备资源不足或文件过大';

  @override
  String get downloadFailureOwnership => '任务已失效，需重新下载';

  @override
  String get downloadFailureInterrupted => '应用重启时下载中断，点重试继续';

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
  String get ugoiraSaveFailed => 'GIF 保存失败';

  @override
  String get ugoiraArchiveInvalid => '动图压缩包无效';

  @override
  String get ugoiraFrameCorrupt => '动图帧损坏';

  @override
  String get ugoiraLoadFailed => '动图加载失败';

  @override
  String get homeRecommended => '推荐';

  @override
  String get homeRanking => '排行';

  @override
  String get homeMe => '我的';

  @override
  String get bookmarkIllust => '收藏插画';

  @override
  String get bookmarkNovel => '收藏小说';

  @override
  String get bookmarkOperationFailed => '收藏操作失败';

  @override
  String get save => '保存';

  @override
  String get saved => '已保存';

  @override
  String get retry => '重试';

  @override
  String get refresh => '刷新';

  @override
  String get relatedWorks => '相关作品';

  @override
  String get cancel => '取消';

  @override
  String get confirm => '确定';

  @override
  String get continueAction => '继续';

  @override
  String get errorNetwork => '网络连接失败';

  @override
  String get errorTimeout => '连接超时';

  @override
  String get errorRateLimited => '请求过于频繁，请稍后重试';

  @override
  String get errorUnauthorized => '需要重新登录';

  @override
  String get errorServer => '服务器错误';

  @override
  String get errorNotFound => '内容不存在或已被删除';

  @override
  String get errorParse => '响应无法解析';

  @override
  String get errorStorage => '存储错误';

  @override
  String get errorUnknown => '未知错误';

  @override
  String get errorDetails => '详情';

  @override
  String get errorDetailsCopy => '复制';

  @override
  String get errorDetailsCopied => '已复制';

  @override
  String errorWithReason(String action, String reason) {
    return '$action：$reason';
  }

  @override
  String labelValue(String label, String value) {
    return '$label：$value';
  }

  @override
  String get rankingDay => '每日';

  @override
  String get rankingDayR18 => '每日（R-18）';

  @override
  String get rankingDayMale => '每日（男性欢迎）';

  @override
  String get rankingDayMaleR18 => '每日（男性欢迎 & R-18）';

  @override
  String get rankingDayFemale => '每日（女性欢迎）';

  @override
  String get rankingDayFemaleR18 => '每日（女性欢迎 & R-18）';

  @override
  String get rankingWeek => '每周';

  @override
  String get rankingWeekR18 => '每周（R-18）';

  @override
  String get rankingWeekOriginal => '每周（原创）';

  @override
  String get rankingWeekRookie => '每周（新人）';

  @override
  String get rankingWeekAi => '每周（AI）';

  @override
  String get rankingWeekAiR18 => '每周（AI & R-18）';

  @override
  String get rankingWeekR18G => '每周（R-18G）';

  @override
  String get rankingMonth => '每月';

  @override
  String get rankingEmpty => '暂无榜单内容';

  @override
  String get rankingPickDate => '选择日期';

  @override
  String rankingDateLabel(String date) {
    return '$date 的排行';
  }

  @override
  String get rankingBackToLatest => '回到最新';

  @override
  String rankingLoadFailed(String mode) {
    return '$mode加载失败';
  }

  @override
  String get rankingLoadMoreFailed => '加载更多失败';

  @override
  String get profileBookmarked => '收藏';

  @override
  String get profileFollowing => '关注';

  @override
  String get profileFans => '粉丝';

  @override
  String get profileMyPixiv => '好P友';

  @override
  String profileWorksTotal(String count) {
    return '共 $count 件';
  }

  @override
  String get profileTagFilterAll => '标签：全部';

  @override
  String profileTagFilter(String tag) {
    return '标签：$tag';
  }

  @override
  String get profileTagAny => '全部';

  @override
  String get profileTagMore => '更多标签…';

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
  String get searchBarHint => '搜索';

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
  String get contentLoading => '正在加载';

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
  String get searchReversePick => '选择图片';

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
  String searchReverseChallenge(String engine) {
    return '$engine 要求人机验证；可以在网页中完成验证后搜索';
  }

  @override
  String get searchReversePageLoadFailed => '结果页加载失败';

  @override
  String get searchReverseUploadTapHint => '点按页面中的上传按钮开始搜索，已选图片会自动填入。';

  @override
  String get searchReverseUploadPickHint => '请在页面的文件选择框中重新选择同一张图片。';

  @override
  String get searchReverseRetrySameEngine => '重试当前引擎';

  @override
  String get searchReverseEngineUnsupported => '当前图片不满足该引擎的输入限制';

  @override
  String get searchReverseIntro => '选择图片后将上传到所选引擎进行反向检索；结果页在应用内打开。';

  @override
  String get searchReverseFailed => '搜索失败';

  @override
  String get searchReverseDone => '已完成';

  @override
  String get searchReverseEngineSwitch => '切换引擎';

  @override
  String searchReverseEngineUnavailable(String engine) {
    return '$engine 暂时无法使用';
  }

  @override
  String get searchReverseNetwork => '网络连接失败，请检查网络后重试';

  @override
  String searchReverseBadResponse(String engine) {
    return '$engine 返回了无法识别的页面';
  }

  @override
  String get searchReverseStopped => '搜索已停止';

  @override
  String get searchReverseImageFormat => '不支持这种图片格式，请选择 PNG、JPEG、GIF 或 WebP';

  @override
  String get searchReverseImageTooLarge => '图片太大，无法处理';

  @override
  String get searchReverseImagePermission => '没有读取这张图片的权限，请重新选择';

  @override
  String get searchReverseImageUnreadable => '无法读取这张图片，请重新选择';

  @override
  String get searchReverseCleanupFailed => '临时图片清理失败';

  @override
  String get searchReversePickerUnavailable => '此设备无法选择图片';

  @override
  String get searchReversePrivacyNote => '图片只会上传到所选引擎，离开本页即删除';

  @override
  String get searchReverseOpenInBrowser => '在网页中搜索';

  @override
  String searchReverseTryEngine(String engine) {
    return '换用 $engine 搜索';
  }

  @override
  String get searchReverseAllEnginesTried => '所有引擎都没有找到匹配结果';

  @override
  String get searchFilters => '筛选';

  @override
  String searchFiltersActive(int count) {
    return '筛选（已启用 $count 项）';
  }

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
  String get searchTargetText => '正文';

  @override
  String get searchTargetKeyword => '关键词';

  @override
  String get searchSort => '排序';

  @override
  String get searchDateDesc => '最新发布';

  @override
  String get searchDateAsc => '最早发布';

  @override
  String get searchPopularDesc => '热门排序';

  @override
  String get searchPopularMaleDesc => '男性向人气';

  @override
  String get searchPopularFemaleDesc => '女性向人气';

  @override
  String get searchAiSection => 'AI 作品';

  @override
  String get searchAiAll => '全部';

  @override
  String get searchAiExclude => '排除 AI';

  @override
  String get searchAiOnly => '仅 AI';

  @override
  String get searchBookmarkSection => '收藏数';

  @override
  String get searchMin => '最小';

  @override
  String get searchMax => '最大';

  @override
  String get searchRatioSection => '纵横比';

  @override
  String get searchRatioAny => '不限';

  @override
  String get searchRatioLandscape => '横向';

  @override
  String get searchRatioPortrait => '纵向';

  @override
  String get searchRatioSquare => '方形';

  @override
  String get searchContentSection => '作品类别';

  @override
  String get searchContentAll => '插画·漫画·动图';

  @override
  String get searchContentIllustUgoira => '插画·动图';

  @override
  String get searchContentIllust => '仅插画';

  @override
  String get searchContentUgoira => '仅动图';

  @override
  String get searchContentManga => '仅漫画';

  @override
  String get searchResolutionSection => '分辨率';

  @override
  String get searchWidth => '宽';

  @override
  String get searchHeight => '高';

  @override
  String get searchTextLength => '正文长度';

  @override
  String get searchChars => '字数';

  @override
  String get searchOriginalOnly => '仅原创';

  @override
  String get searchSetDefault => '设为默认';

  @override
  String searchRangeAtLeast(String label, String value) {
    return '$label $value 以上';
  }

  @override
  String searchRangeAtMost(String label, String value) {
    return '$label $value 以下';
  }

  @override
  String searchRangeBetween(String label, String min, String max) {
    return '$label $min–$max';
  }

  @override
  String searchDateFrom(String date) {
    return '$date 起';
  }

  @override
  String searchDateUntil(String date) {
    return '截至 $date';
  }

  @override
  String searchDateBetween(String start, String end) {
    return '$start – $end';
  }

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
  String get searchInvalidDateRange => '开始日期不能晚于结束日期';

  @override
  String get searchInvalidBoundRange => '最小值不能大于最大值';

  @override
  String get searchPopularPreviewHint => '未开通会员，热门排序将使用人气预览结果';

  @override
  String get searchNoSuggestions => '没有匹配建议';

  @override
  String get searchSuggestionFill => '填入搜索框';

  @override
  String get searchSuggestionSearch => '立即搜索';

  @override
  String get searchHistoryTitle => '搜索历史';

  @override
  String get searchHistoryClear => '清除全部';

  @override
  String get searchHistoryClearConfirm => '清除全部搜索历史？';

  @override
  String get searchHistoryRemoved => '已从搜索历史中删除';

  @override
  String get searchHistoryRemove => '从搜索历史中删除';

  @override
  String searchOpenIllust(int id) {
    return '打开插画/漫画 ID $id';
  }

  @override
  String searchOpenNovel(int id) {
    return '打开小说 ID $id';
  }

  @override
  String searchOpenUser(int id) {
    return '打开用户 ID $id';
  }

  @override
  String get searchModifyQuery => '修改搜索';

  @override
  String get searchUserAccount => '账号';

  @override
  String get illustDetailTitle => '作品详情';

  @override
  String detailMetaCountsSemantics(String views, String bookmarks) {
    return '$views 次浏览，$bookmarks 次收藏';
  }

  @override
  String get detailCollapsePages => '收起';

  @override
  String get detailStatViews => '浏览';

  @override
  String get detailStatBookmarks => '收藏';

  @override
  String get detailStatComments => '评论';

  @override
  String detailStatsSemantics(String views, String bookmarks, String comments) {
    return '$views 次浏览，$bookmarks 次收藏，$comments 条评论';
  }

  @override
  String get detailSectionCaption => '简介';

  @override
  String get detailSectionTags => '标签';

  @override
  String get detailViewAll => '查看全部';

  @override
  String get detailSectionAuthorWorks => '作者的其他作品';

  @override
  String get detailAuthorNoOtherWorks => '暂无其他作品';

  @override
  String get detailAuthorWorksLoadFailed => '作者作品加载失败';

  @override
  String get feedContinueLoading => '继续加载';

  @override
  String get commentAuthorBadge => '作者';

  @override
  String get commentShowReplies => '查看回复';

  @override
  String novelEntryBookmarks(String count) {
    return '$count 次收藏';
  }

  @override
  String detailExpandPages(int count) {
    return '展开全部 $count 张';
  }

  @override
  String get illustDetailOpenLinkFailed => '无法打开链接';

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
  String commentViewReplies(int count) {
    return '查看 $count 条回复';
  }

  @override
  String get commentMoreActions => '更多操作';

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
  String get commentSending => '发送中';

  @override
  String commentStampLabel(int id) {
    return '贴图 $id';
  }

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
  String get newNovels => '小说新作';

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
  String get recommendedRefreshFailed => '刷新失败';

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
  String get followPrivately => '私密关注';

  @override
  String get unfollow => '取消关注';

  @override
  String get followPublicAction => '公开关注';

  @override
  String get followSwitchToPrivate => '改为私密关注';

  @override
  String get followSwitchToPublic => '改为公开关注';

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
  String get novelLayoutFailed => '小说排版失败';

  @override
  String get novelRetry => '重试';

  @override
  String get novelNoContent => '暂无正文';

  @override
  String get novelWords => '字';

  @override
  String get novelSeries => '系列';

  @override
  String get novelRanking => '小说排行';

  @override
  String get novelSeriesUnavailable => '系列信息暂不可用';

  @override
  String get novelInfoTitle => '作品信息';

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

  @override
  String get novelReaderSettings => '阅读设置';

  @override
  String get novelSettingsSaveFailed => '阅读设置未能保存，仅本次生效';

  @override
  String get novelFontSize => '字号';

  @override
  String get novelLineHeight => '行距';

  @override
  String get novelThemeSystem => '跟随系统';

  @override
  String get novelThemePaper => '纸张';

  @override
  String get novelThemeSepia => '护眼';

  @override
  String get novelThemeNight => '夜间';

  @override
  String get aboutDisplayRefreshRate => '显示刷新率';

  @override
  String get cardActionDownload => '下载';

  @override
  String get cardActionWatchLater => '稍后再看';

  @override
  String get cardActionRemoveWatchLater => '从稍后再看移除';

  @override
  String get cardActionShare => '分享';

  @override
  String get share => '分享';

  @override
  String get openInBrowser => '在浏览器打开';

  @override
  String get linkCopied => '链接已复制';

  @override
  String get copyLink => '复制链接';

  @override
  String get openLink => '打开链接';

  @override
  String get watchLaterAdded => '已加入稍后再看';

  @override
  String get watchLaterTitle => '稍后再看';

  @override
  String get watchLaterEmpty => '暂存的作品会显示在这里';

  @override
  String get watchLaterLoadFailed => '稍后再看加载失败';

  @override
  String get bookmarkEditTitle => '编辑收藏';

  @override
  String get bookmarkTags => '收藏标签';

  @override
  String get bookmarkTagNewHint => '输入新标签，回车添加';

  @override
  String get bookmarkTagFilterEmpty => '已加载内容中无匹配';

  @override
  String get bookmarkTagFilterHint => '筛选已加载作品';

  @override
  String get bookmarkTagSuggestions => '常用标签';

  @override
  String get bookmarkTagsEmpty => '还没有收藏标签';

  @override
  String get bookmarkTagsLoadFailed => '收藏标签加载失败';

  @override
  String get bookmarkTagsEnd => '已显示全部标签';

  @override
  String get seriesTitle => '系列';

  @override
  String get seriesLoadFailed => '系列加载失败';

  @override
  String get seriesLoadMoreFailed => '加载更多失败';

  @override
  String get seriesEmpty => '该系列暂无作品';

  @override
  String seriesWorksCount(int count) {
    return '共 $count 个作品';
  }

  @override
  String seriesEpisode(int order) {
    return '第 $order 话';
  }

  @override
  String get seriesStartReading => '开始阅读';

  @override
  String seriesContinueEpisode(int n) {
    return '继续第 $n 话';
  }

  @override
  String get seriesContinue => '继续阅读';

  @override
  String get seriesStartFromFirst => '从第 1 话开始';

  @override
  String get seriesPrevious => '上一话';

  @override
  String get seriesNext => '下一话';

  @override
  String get watchlistTitle => '追更';

  @override
  String get watchlistManga => '漫画';

  @override
  String get watchlistNovel => '小说';

  @override
  String get watchlistEmpty => '还没有追更的系列';

  @override
  String get watchlistLoadFailed => '追更列表加载失败';

  @override
  String get watchlistLoadMoreFailed => '加载更多失败';

  @override
  String get watchlistAdd => '追更';

  @override
  String get watchlistRemove => '取消追更';

  @override
  String get watchlistFailed => '追更操作失败';

  @override
  String get watchlistNewContent => '更新';

  @override
  String get localNovelsTitle => '本地小说';

  @override
  String get localNovelsEmpty => '还没有导入的本地小说';

  @override
  String get localNovelsLoadFailed => '本地小说加载失败';

  @override
  String get localNovelsImport => '导入 TXT';

  @override
  String get localNovelsImportFailed => '导入失败';

  @override
  String localNovelsImported(String title) {
    return '已导入「$title」';
  }

  @override
  String get localNovelsImportedLossy => '已导入，但编码无法完全识别，可能包含乱码';

  @override
  String get localNovelsDelete => '删除';

  @override
  String localNovelsDeleteConfirm(String title) {
    return '删除「$title」？本地文件会一并删除。';
  }

  @override
  String get novelChapters => '目录';

  @override
  String get localNovelFileInfo => '文件信息';

  @override
  String localNovelFileEncoding(String encoding) {
    return '编码：$encoding';
  }

  @override
  String localNovelFileImportedAt(String date) {
    return '导入时间 $date';
  }

  @override
  String localNovelsChars(int count) {
    return '$count 字';
  }

  @override
  String localNovelContinue(int percent) {
    return '继续阅读 · $percent%';
  }

  @override
  String get profileSeries => '系列';

  @override
  String get spotlightTitle => '特辑';

  @override
  String get spotlightSeeAll => '全部';

  @override
  String get spotlightArticleLoadFailed => '文章加载失败';

  @override
  String get spotlightCategoryAll => '全部';

  @override
  String get spotlightCategoryIllust => '插画';

  @override
  String get spotlightCategoryManga => '漫画';

  @override
  String get spotlightLoadFailed => '特辑加载失败';

  @override
  String get spotlightLoadMoreFailed => '特辑加载更多失败';

  @override
  String get spotlightEmpty => '暂无特辑';

  @override
  String get hapticStrength => '触感强度';

  @override
  String get hapticStrengthOff => '关';

  @override
  String get hapticStrengthLight => '轻';

  @override
  String get hapticStrengthStandard => '标准';

  @override
  String get hapticStrengthStrong => '强';

  @override
  String get hapticTierComposition => '本机支持精细振动，强度逐级可调';

  @override
  String get hapticTierPredefined => '本机使用系统预设振动，强度按档位换用不同效果';

  @override
  String get hapticTierSystem => '本机仅支持系统触感，强度不可调';

  @override
  String get hapticTierNone => '本机没有振动器';

  @override
  String get hapticTierUnknown => '无法读取本机的振动能力';

  @override
  String get hapticSystemOff => '系统已关闭触摸振动，应用内触感不会生效';

  @override
  String get downloadSelectPages => '选择要下载的页';

  @override
  String get downloadSelectedPages => '下载选中的页';

  @override
  String get selectAll => '全选';

  @override
  String viewerPageLabel(int page, int total) {
    return '第 $page 页，共 $total 页';
  }

  @override
  String get tagActionSearch => '搜索该标签';

  @override
  String get tagActionCopy => '复制标签名';

  @override
  String get tagActionMute => '屏蔽该标签';

  @override
  String get tagActionUnmute => '解除屏蔽该标签';

  @override
  String get tagActionMuteMode => '批量屏蔽标签';

  @override
  String get tagCopied => '已复制标签';

  @override
  String ugoiraExporting(int percent) {
    return '正在导出 GIF… $percent%';
  }

  @override
  String get viewerFitScreen => '适应屏幕';

  @override
  String get viewerSavePage => '保存当前页';

  @override
  String get viewerJumpToPage => '跳转到页码';

  @override
  String get viewerInfo => '作品信息';

  @override
  String get viewerOpenDetail => '打开详情页';

  @override
  String illustPagesTotal(int count) {
    return '共 $count 页';
  }

  @override
  String get badgeUgoira => '动图';

  @override
  String get badgeAi => 'AI 生成';

  @override
  String rankLabel(int rank) {
    return '第 $rank 名';
  }

  @override
  String get openAuthorProfile => '打开作者主页';

  @override
  String get expandText => '展开';

  @override
  String get collapseText => '收起';

  @override
  String get illustInfoJump => '跳到作品信息区';

  @override
  String get manage => '管理';

  @override
  String selectedCount(int n) {
    return '已选 $n 项';
  }

  @override
  String get undo => '撤销';

  @override
  String get watchLaterRemoved => '已从稍后再看移除';

  @override
  String get bookmarkRemoved => '已取消收藏';

  @override
  String get followRemoved => '已取消关注';

  @override
  String get muteRemoved => '已解除屏蔽';

  @override
  String get watchlistOpenContents => '打开目录';

  @override
  String get imageRetry => '重新加载图片';

  @override
  String get imageLoading => '图片加载中';

  @override
  String get timeJustNow => '刚刚';

  @override
  String timeMinutesAgo(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count 分钟前',
    );
    return '$_temp0';
  }

  @override
  String timeHoursAgo(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count 小时前',
    );
    return '$_temp0';
  }

  @override
  String timeDaysAgo(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count 天前',
    );
    return '$_temp0';
  }
}
