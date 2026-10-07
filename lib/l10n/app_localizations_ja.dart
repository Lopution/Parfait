// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Japanese (`ja`).
class AppLocalizationsJa extends AppLocalizations {
  AppLocalizationsJa([String locale = 'ja']) : super(locale);

  @override
  String get networkDohEndpointsInvalid => 'DoHエンドポイントリストが無効です';

  @override
  String get welcome1 => 'Parfaitをご利用ありがとうございます';

  @override
  String get welcome2 => '初期設定を開始します';

  @override
  String get start => '開始';

  @override
  String get selectLanguage => '言語の選択';

  @override
  String get next => '次へ';

  @override
  String get dark => 'ダーク';

  @override
  String get light => 'ライト';

  @override
  String get system => 'システムのデフォルト';

  @override
  String get loginTitle => '登録・ログイン';

  @override
  String get loginProxyNoticeTitle => 'お知らせ';

  @override
  String get loginProxyNoticeBody =>
      'ネットワーク環境の制限により、ログインまたは登録の前にシステムまたは外部プロキシを有効にしてください。Parfaitに内蔵プロキシはありません。';

  @override
  String get loginProxyNoticeCancel => 'キャンセル';

  @override
  String get loginProxyNoticeContinue => '有効にしました';

  @override
  String get register => '登録';

  @override
  String get login => 'ログイン';

  @override
  String get loginPageClosed => 'ページが閉じられました。再度開いてください。';

  @override
  String get loginCallbackInvalid => 'ログインコールバックが無効です。もう一度ログインしてください';

  @override
  String loginNetworkError(String status) {
    return 'ネットワークエラー (HTTP $status)';
  }

  @override
  String get loginPageLoadFailed => 'ページの読み込みに失敗しました';

  @override
  String get loginWebView2Missing =>
      'ログインには WebView2 Runtime が必要ですが、このシステムでは検出されませんでした。インストールしてからこのページを開き直してください。';

  @override
  String get loginInstallWebView2 => 'WebView2 Runtime をインストール';

  @override
  String get loginReload => '再読み込み';

  @override
  String get loginRestart => '再度ログイン';

  @override
  String get loginFailed => 'ログインに失敗しました';

  @override
  String get networkCompatibility => 'Pixiv互換接続';

  @override
  String get networkCompatibilityHint =>
      'オンにすると、Pixiv公式ドメインには暗号化DNS、ECH、SNIなしなどの互換接続と直接接続のうち使えるものを選び、成功した方法を記憶します。最後の互換接続は証明書を検証しません。オフにすると直接接続のみになります。他の通信はプロキシしません。';

  @override
  String get useLoginWithClipboard => 'クリップボードからログイン';

  @override
  String get accountTransferExportTitle => 'アカウント認証情報をエクスポート';

  @override
  String get accountTransferWarning =>
      'クリップボードは短時間保持され、他のアプリに読み取られる可能性があります。この形式は暗号化も送信者認証も提供しません。';

  @override
  String get loginClipboardHint =>
      'ログイン済みの端末で「マイページ → アカウント管理 → アカウント認証情報をエクスポート」からコピーし、ここに戻ってインポートしてください。';

  @override
  String get accountTransferSensitiveWarning =>
      'この端末はクリップボードの機密マーク（Android 13+）未対応です。認証情報は平文でシステムクリップボードに置かれます。すぐに貼り付けてください。5分後に自動クリアされます。';

  @override
  String get accountTransferCopied => 'アカウント移行データをコピーしました。対象端末ですぐに貼り付けてください。';

  @override
  String get accountTransferImported => 'アカウント移行に成功しました';

  @override
  String get accountTransferClipboardReplaced =>
      'アカウントを取り込みました。クリップボードが置き換えられたため消去していません。';

  @override
  String get accountTransferCorrupt => 'クリップボードのアカウントデータが壊れているか未対応です';

  @override
  String get accountTransferCredentialInvalid =>
      'アカウント認証情報が無効です。再ログインまたは再コピーしてください';

  @override
  String get accountTransferVerificationUnavailable =>
      'Pixiv の認証情報を一時的に確認できません';

  @override
  String get accountTransferNoAccount => 'コピーできるログイン済みアカウントがありません';

  @override
  String get accountTransferCredentialUnavailable =>
      '現在の認証情報を利用できません。再ログインしてください';

  @override
  String get accountTransferClipboardUnavailable => 'クリップボードを利用できません';

  @override
  String get accountTransferStorageFailure => 'アカウント移行記録を安全に保存できません';

  @override
  String get loginAgree => 'ログインすると以下に同意したことになります';

  @override
  String get userAgreement => '「Parfait利用規約」';

  @override
  String get agreementTitle => 'Parfait利用規約';

  @override
  String get agreementIntro =>
      'Parfaitをご利用いただきありがとうございます。本アプリを利用した時点で、以下の条項に同意したものとします。同意できない場合は利用を中止してください。';

  @override
  String get agreementServiceTitle => 'サービスについて';

  @override
  String get agreementServiceBody =>
      'Parfaitはオープンソースの非公式Pixivサードパーティクライアントで、Pixiv株式会社とは関係ありません。ソースコードはAGPL-3.0ライセンスで公開しています。\n\n本アプリ自体はコンテンツを提供しません。作品や情報はすべてPixivから取得します。';

  @override
  String get agreementAccountTitle => 'アカウントとログイン';

  @override
  String get agreementAccountBody =>
      '登録とログインは、アプリ内で開くPixiv公式のWebページで行います。本アプリがパスワードを読み取ったり保存したりすることはありません。ログイン後に得た認証情報はシステムの安全なストレージに保存します。\n\n「アカウント認証情報をエクスポート」は認証情報を平文でシステムのクリップボードに置きます。Android 13以降では機密内容としてマークされ、5分後に自動でクリアされます。自分の端末間でのみ使ってください。\n\nサードパーティクライアントの利用がPixivの規約に沿うかはご自身で判断し、それによるアカウントの制限はご自身の責任となります。';

  @override
  String get agreementUsageTitle => '利用上のルール';

  @override
  String get agreementUsageBody =>
      'お住まいの地域の法律とPixivの利用規約を守ってください。大量の取得、閲覧数やブックマークの自動水増し、他者への嫌がらせなど、Pixivやクリエイターの権利を損なう用途に本アプリを使わないでください。\n\n年齢制限のあるコンテンツはPixivアカウントの設定に従って表示されます。未成年者は閲覧しないでください。';

  @override
  String get agreementContentTitle => 'コンテンツと著作権';

  @override
  String get agreementContentBody =>
      '作品、コメント、ユーザー情報などの著作権は各権利者に帰属します。ダウンロードは個人での保存に限ります。転載や再配布には権利者の許可が必要です。';

  @override
  String get agreementNetworkTitle => 'ネットワークアクセス';

  @override
  String get agreementNetworkBody =>
      '既定の「自動」ネットワークモードでは、Pixiv公式ドメイン（API、ログイン、Webページ、画像）に接続する際、次の方法のうち使えるものを選び、成功した方法を記憶して以後優先します。\n• Cloudflare経由のECH暗号化ハンドシェイク\n• 暗号化DNS（既定はCloudflare、Google）で解決したアドレスへの接続（ECH設定の取得にはAlibaba DNSを使用）\n• SNIなしでのPixiv画像サーバーへの接続\n• システムの直接接続\nこれらはすべて証明書を検証します。\n\nすべて失敗した場合、最後の段階として内蔵または前回使えたPixivのアドレスにSNIなしで接続し、証明書を検証しません。この段階も成功すると記憶されます。ネットワーク上の誰かがPixivのサーバーになりすました場合、ログイン認証情報や閲覧内容を傍受されるおそれがあります。受け入れられない場合は「設定 → ネットワーク → ネットワークモード」で「直結のみ」を選んでください。上記の互換接続がすべて無効になります。\n\n画像ソースの既定は「自動」で、公式の画像サーバーとサードパーティのミラー（i.pixiv.re、i.pixiv.nl、i.pixiv.cat）の速度を計測し、最も速いものを使います。ミラーを経由する場合、ミラーの運営者はリクエストした画像のアドレスとあなたのIPアドレスを知ることができます。「設定 → ブラウズ設定 → 画像ソース」で公式に固定できます。\n\n本アプリはその他の通信をプロキシしません。ネットワークの可用性、APIの変更、サービスの中断については保証しません。';

  @override
  String get agreementThirdPartyTitle => 'サードパーティのサービス';

  @override
  String get agreementThirdPartyBody =>
      '次のサービスには、対応する機能を使ったときにだけ接続します。\n• コメント翻訳（既定はオフ）：コメント本文を、選んだGoogle翻訳、Baidu翻訳、または入力したOpenAI互換APIに送信します。\n• 画像検索：選んだ画像をSauceNAOまたはiqdbにアップロードします。\n\nログイン用のWebページはPixivが提供しており、Pixivが使うサードパーティのリソース（例：ロボット認証）を読み込むことがあります。\n\nアップデート確認：本アプリは24時間に最大1回、GitHub上のバージョン情報を自動で取得します。F-Droid版はアップデートを確認しません。';

  @override
  String get agreementPrivacyTitle => 'プライバシーとローカルデータ';

  @override
  String get agreementPrivacyBody =>
      '設定、キャッシュ、閲覧履歴、あとで見る、ダウンロードしたファイルはすべてこの端末に保存されます。本アプリには統計、広告、クラッシュ報告の仕組みがなく、データを開発者のサーバーに送信しません。\n\nクラッシュログはこの端末にのみ保存され、「マイページ → このアプリについて → ログをエクスポート」で共有するかどうかはご自身で決められます。\n\nアプリのアンインストールやデータの消去でこれらは削除されます（公開フォルダに保存したダウンロードファイルを除く）。';

  @override
  String get agreementDisclaimerTitle => '免責事項';

  @override
  String get agreementDisclaimerBody =>
      '本アプリは現状のまま提供され、不具合がないことや継続して利用できることを保証しません。ネットワーク、アカウント、サードパーティのサービス、不可抗力によるコンテンツの消失、アクセスの失敗、その他の損害について、作者は法律で認められる範囲で責任を負いません。';

  @override
  String get agreementUpdatesTitle => '規約の更新';

  @override
  String get agreementUpdates =>
      '本規約は機能や法律の変更に応じて更新されることがあります。更新後も利用を続けた場合、更新後の規約に同意したものとします。';

  @override
  String get settingsTitle => '設定';

  @override
  String get settingsSearchHint => '設定を検索';

  @override
  String get settingsSearchEmpty => '一致する設定はありません';

  @override
  String get settingsEntrySummary => '外観、閲覧、ネットワーク、ダウンロード、バックアップ';

  @override
  String get settingsGroupAppearance => '外観';

  @override
  String get settingsGroupNetwork => 'ネットワークとダウンロード';

  @override
  String get settingsGroupBrowse => '閲覧';

  @override
  String get settingsGroupLibrary => 'マイコンテンツ';

  @override
  String get settingsGroupDeveloper => '開発者向け';

  @override
  String get developerOptionsUnlocked => '開発者向けオプションを有効にしました';

  @override
  String developerOptionsCountdown(int count) {
    return 'あと $count 回タップで開発者向けオプションを有効化';
  }

  @override
  String get settingsGroupData => 'データ';

  @override
  String get accountSettings => 'アカウント';

  @override
  String get networkSettings => 'ネットワーク';

  @override
  String get networkMode => 'Pixiv公式ネットワーク互換';

  @override
  String get networkModeHint =>
      '開けない時は互換ルートを自動で試行。Pixiv 公式ドメインのみに作用し、他の通信はプロキシしません。';

  @override
  String get networkModeListTitle => 'ネットワークモード';

  @override
  String get networkModeAutomatic => '自動';

  @override
  String get networkModeAutomaticHint => '使える接続方式を自動で選びます。';

  @override
  String get networkModeDirectOnly => '直結のみ';

  @override
  String get networkModeDirectOnlyHint => 'システムの直接接続のみ。直結できるネットワーク向け。';

  @override
  String get networkModeCompatPrefer => '互換経路優先';

  @override
  String get networkModeCompatPreferHint =>
      '互換ルートを優先し、駄目なら直結。直結が遮断されたネットワーク向け。';

  @override
  String get networkEffectiveRoutes => '現在有効な経路';

  @override
  String get networkEffectiveRoutesEmpty => '経路情報はまだありません——少し閲覧してから更新してください。';

  @override
  String get networkRouteForImages => '画像の読み込み';

  @override
  String get networkRouteKindDirect => '直连';

  @override
  String get networkRouteKindCompat => '互換ルート';

  @override
  String get networkThirdParty => 'サードパーティ到達性';

  @override
  String get networkThirdPartyAuto => 'このページを開くと自動で一度チェックします。';

  @override
  String get networkThirdPartyHint => 'システムのネットワークを使用。VPN/プロキシがそのまま有効です。';

  @override
  String get networkReachable => '到達可能';

  @override
  String get networkUnreachable => '到達不能';

  @override
  String get networkChecking => '確認中…';

  @override
  String get networkAdvanced => '詳細設定';

  @override
  String get networkAdvancedHint => '上級者向けの低レベル設定。';

  @override
  String get networkAdvancedReset => 'デフォルトに戻す';

  @override
  String get networkAdvancedResetConfirm =>
      'DoH エンドポイントと ECH フロントホストをデフォルトに戻します。';

  @override
  String get networkDoh => '厳格フォールバックで DoH を使用';

  @override
  String get networkDohHint =>
      '有効時、フォールバック層は DoH（デフォルト Cloudflare DoH：ドメイン端点を静的 Anycast IP にピン留め — 汚染されたシステム DNS を回避；カスタム端点は自身のホスト名を解決）で解決します。無効時はシステム DNS を使用します。';

  @override
  String get networkDohEndpoints => 'DoH エンドポイント';

  @override
  String get networkDohEndpointsHint => 'カンマ区切りの https URL';

  @override
  String get networkEchFrontHost => 'ECH フロントホスト';

  @override
  String get networkEchFrontHostHint =>
      'ECH config を含む HTTPS RR を照会するドメイン（デフォルト cloudflare-ech.com）';

  @override
  String get networkEchHostInvalid => 'フロントホスト名が無効です';

  @override
  String get networkProbe => '階層接続プローブ';

  @override
  String get networkProbeTitle => '階層接続プローブ';

  @override
  String get networkProbeHint => 'Pixiv への接続を段階的に検査し、開けない原因を特定します。';

  @override
  String get frameProbeTitle => 'フレームプローブ';

  @override
  String get frameProbeHint =>
      'スクロール中のフレーム時間を記録します。このページを離れて対象画面をスクロールし、戻って停止してレポートをコピーできます。debug/profile ビルドのみ。';

  @override
  String get frameProbeStart => '記録開始';

  @override
  String get frameProbeRecording => '記録中';

  @override
  String get frameProbeCapHint => 'フレーム上限に達しました。最古のフレームを破棄しています。';

  @override
  String get frameProbeStop => '停止';

  @override
  String get networkProbeRun => 'プローブ開始';

  @override
  String get networkProbeRunning => '実行中…';

  @override
  String get networkProbeNotRun => '未実行';

  @override
  String get networkProbeHostFailed => 'ホストのプローブに失敗しました';

  @override
  String get networkProbeCopied => 'レポートをコピーしました';

  @override
  String get networkProbeDnsDiff => '追加情報：システム DNS と DoH の公開アドレスが一致しません。';

  @override
  String get networkProbeStepSystemDns => 'システム DNS';

  @override
  String get networkProbeStepDoh => 'DoH';

  @override
  String get networkProbeStepTcp => 'TCP';

  @override
  String get networkProbeStepTls => 'TLS';

  @override
  String get networkProbeStepHttp => '最小リクエスト';

  @override
  String get networkProbeStepEch => 'ECH';

  @override
  String get networkProbeStepNoSni => '空 SNI';

  @override
  String get networkProbeStepOk => '成功';

  @override
  String get networkProbeStepFailed => '失敗';

  @override
  String get networkProbeStepSkipped => 'スキップ';

  @override
  String get networkProbeConclusionAllReachable => '到達可能';

  @override
  String get networkProbeConclusionDnsPolluted => 'DNS 汚染';

  @override
  String get networkProbeConclusionSniBlocked => 'SNI ブロック';

  @override
  String get networkProbeConclusionEchAvailable => 'ECH を使用';

  @override
  String get networkProbeConclusionNoSniAvailable => '空 SNI を使用';

  @override
  String get networkProbeConclusionIpBlackholed => 'IP ブラックホール';

  @override
  String get networkProbeConclusionAppLayer => 'アプリ層';

  @override
  String get networkProbeConclusionInconclusive => '不明';

  @override
  String get networkProbeOverview => '概要';

  @override
  String get networkProbeWorst => '最悪';

  @override
  String get networkProbeDetails => '詳細';

  @override
  String get networkProbeNotPersisted => '結果は保存されません。このページを離れると破棄されます。';

  @override
  String get networkProbeAdviceAllReachable => 'すべてのホストに到達可能。調整は不要です。';

  @override
  String get networkProbeAdviceEchAvailable =>
      'ECH が利用可能——「自動」または「互換優先」モードで使われます。';

  @override
  String get networkProbeAdviceNoSniAvailable =>
      '空 SNI が利用可能——「互換優先」モードで使われます。';

  @override
  String get networkProbeAdviceSniBlocked =>
      '実 SNI が遮断されています——「互換優先」モードを試してください。';

  @override
  String get networkProbeAdviceDnsPolluted =>
      'システム DNS が汚染されています——DoH を有効のままにすれば回避できます。';

  @override
  String get networkProbeAdviceIpBlackholed =>
      'IP がブラックホール化——アプリでは回避できません。ネットワークを変えてください。';

  @override
  String get networkProbeAdviceAppLayer =>
      '伝送層は正常。問題はアプリ層です——レポートをコピーして報告してください。';

  @override
  String get networkProbeAdviceInconclusive =>
      '結論が出ません——別のネットワークか、後で再試行してください。';

  @override
  String get copy => 'コピー';

  @override
  String get themeSettings => 'テーマ';

  @override
  String get followSystemColors => 'システムの色を使用';

  @override
  String get followSystemColorsHint => '壁紙やシステムのアクセントカラーをテーマ色にします';

  @override
  String get followSystemColorsUnavailable => 'このシステムでは利用できません';

  @override
  String get languageSettings => '言語';

  @override
  String get translateSettings => '翻訳';

  @override
  String get browseSettings => 'ブラウズ設定';

  @override
  String get settingsBrowseHint => 'ローカル非表示・画質';

  @override
  String get downloadSettings => 'ダウンロード設定';

  @override
  String get historySettings => '履歴';

  @override
  String get historyRecordLocal => 'ローカルに閲覧履歴を記録';

  @override
  String get historyRecordPixiv => 'Pixivの閲覧履歴に記録';

  @override
  String get historyEmpty => '閲覧履歴はありません';

  @override
  String get historyLoadFailed => '履歴の読み込みに失敗しました';

  @override
  String get historyDelete => '履歴を削除';

  @override
  String get historyDeleteAll => '履歴をすべて削除';

  @override
  String get historyDeleteHint => '削除した履歴は復元できません。';

  @override
  String get downloaderSettings => 'ダウンロード状況';

  @override
  String get aboutSettings => 'このアプリについて';

  @override
  String get signedOut => '未ログイン';

  @override
  String get currentAccount => '現在のアカウント';

  @override
  String get accountId => 'アカウント ID';

  @override
  String get reauthRequired => '再ログインが必要です';

  @override
  String get accountProfile => 'プロフィール';

  @override
  String get accountReadFailed => 'アカウント状態を読み込めませんでした';

  @override
  String get dismiss => '閉じる';

  @override
  String get profileEditTitle => 'プロフィールを編集';

  @override
  String get profileEditLoadFailed => 'プロフィールを読み込めませんでした';

  @override
  String get profileEditUnavailable => 'アプリ内プロフィール編集経路はありません。';

  @override
  String get profileEditPending => '変更を送信しました。確認後に反映されます。';

  @override
  String get profileEditConfirmed => 'プロフィールを確認して同期しました。';

  @override
  String get profileEditDisplayName => '表示名';

  @override
  String get profileEditComment => '自己紹介';

  @override
  String get profileEditWebpage => 'ウェブページ';

  @override
  String get profileEditAvatar => 'アバター';

  @override
  String get profileEditBackground => '背景画像';

  @override
  String get profileEditCurrentPassword => '現在のパスワード';

  @override
  String get profileEditFieldUnsupported => '現在の経路ではこの項目に対応していません';

  @override
  String get profileEditImageChoose => '対応する画像を選択してください';

  @override
  String get profileEditImageFailed => '画像の処理に失敗しました';

  @override
  String get profileEditChooseImage => '画像を選択';

  @override
  String get profileChangeAvatar => 'アイコンを変更';

  @override
  String get profileChangeBackground => '背景画像を変更';

  @override
  String get profileEditSave => 'プロフィールを保存';

  @override
  String get profileEditLeaveTitle => '未保存の変更を破棄しますか？';

  @override
  String get profileEditLeaveDetail => '変更はまだ送信されていないため、離れると失われます。';

  @override
  String get profileEditLeaveConfirm => '変更を破棄';

  @override
  String get accountManagement => 'アカウント管理';

  @override
  String get addAccount => 'アカウントを追加';

  @override
  String get switchAccount => 'アカウントを切り替え';

  @override
  String get accountSwitching => '切り替え中…';

  @override
  String get removeAccount => 'アカウントを削除';

  @override
  String get removeAccountConfirm => 'このアカウントを削除しますか？';

  @override
  String get noAccounts => 'アカウントがありません';

  @override
  String get profileReadOnly => '保存されたアカウント情報を表示しています。プロフィール編集はプロフィール機能で提供します。';

  @override
  String get serverDisplaySettings => 'アカウント表示設定';

  @override
  String get serverDisplayHint => 'Pixiv サーバーに保存され、このアカウントへの API 返却内容に作用します。';

  @override
  String get serverShowAi => 'AI 生成作品を表示';

  @override
  String get serverRestrictedMode => '制限モード';

  @override
  String get serverDisplayLoadFailed => 'サーバー設定の読み込みに失敗しました';

  @override
  String get serverDisplayWriteFailed => 'サーバー設定の保存に失敗しました';

  @override
  String get backupSettings => 'バックアップと復元';

  @override
  String get backupHint => '設定・ミュート一覧・閲覧履歴を書き出します。認証情報はファイルに含まれません。';

  @override
  String get backupExport => 'バックアップを書き出す';

  @override
  String get backupExportHint => '選択したフォルダに parfait-backup-*.json を保存';

  @override
  String backupExported(String name) {
    return '$name を書き出しました';
  }

  @override
  String get backupExportFailed => '書き出しに失敗しました';

  @override
  String get backupImport => 'バックアップを読み込む';

  @override
  String get backupImportHint => 'JSON ファイルから読み込み（マージまたは上書き）';

  @override
  String get backupImportInvalid => 'バックアップファイルが無効です';

  @override
  String get backupImportFailed => '読み込みに失敗しました';

  @override
  String get backupImportStrategyTitle => '読み込み方法を選択';

  @override
  String backupImportPrompt(
    int tags,
    int users,
    int works,
    int history,
    String account,
  ) {
    return 'ファイル内容：ミュートタグ $tags 件、ミュートユーザー $users 件、作品ミュート $works 件、履歴 $history 件。\n書き出し元アカウント：$account';
  }

  @override
  String get backupImportOverwriteNote =>
      '上書きはローカル履歴を消去して作品ミュートを置き換えます。サーバー側のミュートは追加のみで、読み込みで削除されることはありません。';

  @override
  String get backupMerge => 'マージ';

  @override
  String get backupOverwrite => '上書き';

  @override
  String get backupMergeHint => '既存データを残し、ファイルの内容を追加します';

  @override
  String get backupOverwriteHint => 'ファイルの内容でローカルデータを置き換えます';

  @override
  String backupImportMergeConfirmTitle(
    int tags,
    int users,
    int works,
    int history,
  ) {
    return 'ミュートタグ $tags 件、ミュートユーザー $users 件、ミュート作品 $works 件、履歴 $history 件を追加します';
  }

  @override
  String get backupImportOverwriteConfirmTitle =>
      'ローカル履歴を消去し、ミュート作品と設定をファイルに合わせます';

  @override
  String backupImportDone(int tags, int users, int works, int history) {
    return '読み込み完了：タグ +$tags、ユーザー +$users、作品ミュート変更 $works 件、履歴 $history 件';
  }

  @override
  String get imageSource => '画像ソース';

  @override
  String get imageSourceNormal => '公式';

  @override
  String get imageSourcePixivCat => 'pixiv.cat ミラー';

  @override
  String get imageSourcePixivRe => 'pixiv.re ミラー';

  @override
  String get imageSourcePixivNl => 'pixiv.nl ミラー';

  @override
  String get imageSourceCustom => 'カスタムプロキシ';

  @override
  String get imageSourceCustomHint =>
      'https://host[/path]、例：https://i.pixiv.cat';

  @override
  String get imageSourceCustomUnset => '未設定';

  @override
  String get imageSourceCustomInvalid =>
      '無効なソースです：https・DNS ホスト名・ポート 443 が必要です';

  @override
  String get imageSourceApplyAndTest => '適用してテスト';

  @override
  String imageSourceTestOk(String code) {
    return 'ミラーに接続できました（HTTP $code）';
  }

  @override
  String get imageSourceTestFailed => 'ミラー接続テストに失敗しました';

  @override
  String get imageSourceUnreachableMainland => '中国本土ネットワークからは通常到達不能';

  @override
  String get imageSourceAuto => '自動（デフォルト、現在のネットワークで計測）';

  @override
  String imageSourceAutoWinner(String host) {
    return '現在: $host';
  }

  @override
  String get imageSourceAutoPending => '未計測 — 直连で読み込み';

  @override
  String get previewQuality => 'プレビュー画質';

  @override
  String get viewQuality => 'ビューア画質';

  @override
  String get detailQuality => '詳細画質';

  @override
  String get qualityMedium => '中サイズ';

  @override
  String get qualityLarge => '大サイズ';

  @override
  String get qualityOriginal => 'オリジナル';

  @override
  String get scaleQuality => 'ビューア画質（オリジナル）';

  @override
  String get blockR18 => 'R-18作品をローカルで非表示';

  @override
  String get blockAI => 'AI作品をローカルで非表示';

  @override
  String get hideMuted => 'ミュートした作品を非表示';

  @override
  String get hideMutedHint => 'オフの場合、ミュート対象はぼかしカードで表示され、タップで一時的に確認できます';

  @override
  String get mutedContent => 'ミュート中';

  @override
  String get mutedItemsSettings => 'ミュート管理';

  @override
  String get mutedTagsSection => 'ミュートタグ';

  @override
  String get mutedUsersSection => 'ミュートユーザー';

  @override
  String get mutedWorksSection => 'ミュート作品';

  @override
  String get mutedEmpty => 'ミュート項目はありません';

  @override
  String muteEmptyHint(String action) {
    return '作品カードを長押しして「$action」を選択';
  }

  @override
  String get muteTagInputHint => 'ミュートするタグ';

  @override
  String get muteWork => 'この作品をミュート';

  @override
  String get unmuteWork => 'この作品のミュートを解除';

  @override
  String get muteAuthor => '作者をミュート';

  @override
  String get unmuteAuthor => '作者のミュートを解除';

  @override
  String get unmuteTag => 'ミュート解除';

  @override
  String get muteFailed => 'ミュート操作に失敗しました';

  @override
  String get reduceMotion => '視覚効果を減らす';

  @override
  String get reduceMotionHint => '画面遷移・リスト入場・押下フィードバックなどの装飾アニメーションをオフにします';

  @override
  String get pressFeedback => '押下フィードバック';

  @override
  String get pressFeedbackHint => 'カードを押している間わずかに縮小します';

  @override
  String get animationSpeed => 'アニメーション速度';

  @override
  String get animationSpeedFast => '速い';

  @override
  String get animationSpeedNormal => '標準';

  @override
  String get animationSpeedSlow => '遅い';

  @override
  String get animationSpeedHint => 'アプリ内のすべてのアニメーションに適用されます。波紋などのシステム効果は変わりません';

  @override
  String get animationSpeedReduceHint =>
      '「視覚効果を減らす」がオンの間はアニメーションを再生しないため、速度は反映されません';

  @override
  String get motionSettings => 'モーションと触覚';

  @override
  String get motionPageTransition => '画面遷移';

  @override
  String get pageTransitionStyleSystem => 'システムのデフォルト';

  @override
  String get pageTransitionStyleSystemHint => 'Android システムの遷移。予測型「戻る」に対応';

  @override
  String get pageTransitionStyleSystemHintOther => 'プラットフォームのデフォルト';

  @override
  String get pageTransitionStyleSharedAxis => '共有軸';

  @override
  String get pageTransitionStyleSharedAxisHint =>
      'Material 推奨：新旧の画面が同じ方向にスライドしてクロスフェード';

  @override
  String get pageTransitionStyleZoom => 'ズーム';

  @override
  String get pageTransitionStyleZoomHint => '拡大して表示（Android 10 風）';

  @override
  String get pageTransitionStyleSlide => 'スライド';

  @override
  String get pageTransitionStyleSlideHint => '右から押し出し、前の画面はずれて暗くなる（iOS 風）';

  @override
  String get maxDownloadCount => '同時ダウンロード数の上限';

  @override
  String get maxDownloadCountHint => 'ドラッグでプレビュー、離すと適用';

  @override
  String get namingRule => 'ファイル名規則';

  @override
  String get namingRuleHint => '空欄で標準の名前を使用';

  @override
  String get saveFolder => '保存フォルダー';

  @override
  String get saveLocation => '保存先';

  @override
  String get saveLocationAlbum => 'アルバム';

  @override
  String get saveLocationPixivAlbum => 'Parfait アルバム（デフォルト）';

  @override
  String get saveLocationCustomAlbum => 'カスタムアルバム名';

  @override
  String get saveLocationCustomAlbumHint => '英数字・日本語・アンダースコアのみ';

  @override
  String get saveLocationAlbumInvalid => 'アルバム名が無効です';

  @override
  String get saveLocationSafFolder => 'フォルダー（システムディレクトリ選択）';

  @override
  String get saveLocationSafFolderHint => 'システム SAF でフォルダーを選択し、権限を永続化';

  @override
  String get safStorageInternal => '内部ストレージ';

  @override
  String safStorageSdCard(String volume) {
    return 'SD カード（$volume）';
  }

  @override
  String get saveLocationUriCopied => 'フォルダ URI をコピーしました';

  @override
  String get namingPreset => 'ファイル名プリセット';

  @override
  String get namingPresetId => '作品 ID（デフォルト）';

  @override
  String get namingPresetArtistTitleId => '作者 - タイトル - ID';

  @override
  String get namingPresetTitleId => 'タイトル - ID';

  @override
  String get namingPresetCustom => 'カスタムテンプレート';

  @override
  String get namingTemplate => '命名テンプレート';

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
  String get namingTemplateInvalid => '未対応の変数または不正な文字を含みます';

  @override
  String get namingPreview => 'プレビュー';

  @override
  String get namingVarArtist => '作者名';

  @override
  String get namingVarTitle => 'タイトル';

  @override
  String get namingVarId => '作品 ID';

  @override
  String get namingVarAuthorId => '作者 ID';

  @override
  String get namingVarPage => 'ページ番号（0 から）';

  @override
  String get namingVarPage1 => 'ページ番号（1 から）';

  @override
  String get namingVarPages => '総ページ数';

  @override
  String get namingVarExt => '拡張子';

  @override
  String get namingVarW => '幅';

  @override
  String get namingVarH => '高さ';

  @override
  String get namingVarDate => '日付';

  @override
  String get namingVarCreated => '日時';

  @override
  String get namingVarSeries => 'シリーズ名';

  @override
  String get namingVarSeriesOrder => 'シリーズ内の番号';

  @override
  String get namingVarChapters => 'シリーズの総話数';

  @override
  String get namingSampleArtist => '作者名';

  @override
  String get namingSampleTitle => '作品タイトル';

  @override
  String get namingSampleSeries => 'シリーズ名';

  @override
  String get namingTemplateSanitizeNote => '不正な文字は _ に置換され、長い名前は切り詰められます。';

  @override
  String get notConfigured => '未設定';

  @override
  String get translateProvider => '翻訳サービス';

  @override
  String get translateGoogle => 'Google Translate';

  @override
  String get translateDisabled => '無効';

  @override
  String get translateBaidu => '百度翻訳';

  @override
  String get translateLlm => 'カスタム LLM（OpenAI 互換）';

  @override
  String get translateBaiduCredential => '百度 AppID / シークレット';

  @override
  String get translateLlmCredential => 'LLM エンドポイントとキー';

  @override
  String get translateBaiduAppId => 'AppID';

  @override
  String get translateBaiduSecret => 'シークレット';

  @override
  String get translateLlmBaseUrl => 'ベース URL（HTTPS）';

  @override
  String get translateLlmApiKey => 'API キー';

  @override
  String get translateLlmModel => 'モデル名（任意）';

  @override
  String get translateCredentialsSave => '安全なストレージに保存';

  @override
  String get translateCredentialsClear => '認証情報を削除';

  @override
  String get translateCredentialsClearConfirm =>
      '安全ストレージ内の認証情報を削除します。翻訳するには再入力が必要です。';

  @override
  String get translateCredentialsSaved => '安全なストレージに保存しました';

  @override
  String get translateCredentialsCleared => '認証情報を削除しました';

  @override
  String get translateCredentialsStoreError => '安全なストレージの操作に失敗しました';

  @override
  String get translateCredentialsInvalid => '入力が不完全か、エンドポイントが HTTPS ではありません';

  @override
  String get translateBaiduHint =>
      '百度翻訳の標準版は認証不要ですが月 5 万文字・毎秒 1 回までで、コメント翻訳には足りません。高級版は個人の実名認証（氏名 + 身分証番号）が必要で、月 100 万文字・毎秒 10 回です。認証情報は翻訳リクエストにのみ使用します。';

  @override
  String get translateLlmCredentialHint =>
      'HTTPS エンドポイントのみ。翻訳は固定プロンプトで、モデルや詳細パラメータは変更できません。コメント本文と翻訳は保存されません。';

  @override
  String get translateCredentialHint =>
      '翻訳の認証情報は通常の設定に保存せず、必要な場合は安全なストレージで管理します。';

  @override
  String get downloadTasksEmpty => 'ダウンロードタスクはありません';

  @override
  String get downloadQueued => '待機中';

  @override
  String get downloadRunning => 'ダウンロード中';

  @override
  String get downloadCanceling => 'キャンセル中';

  @override
  String get downloadSucceeded => '完了';

  @override
  String get downloadFailed => '失敗';

  @override
  String get downloadCanceled => 'キャンセル済み';

  @override
  String get retryDownload => '再試行';

  @override
  String get cancelDownload => 'キャンセル';

  @override
  String get downloadPaused => '一時停止';

  @override
  String get pauseDownload => '一時停止';

  @override
  String get downloadProcessing => '処理中';

  @override
  String get downloadViewResult => '表示';

  @override
  String get downloadRemoveRecord => '一覧から削除';

  @override
  String get downloadOpenWork => '作品を開く';

  @override
  String get downloadClearCompleted => '完了したタスクを消去';

  @override
  String downloadTasksRemoved(int count) {
    return '$count件の記録を削除しました';
  }

  @override
  String downloadBatchCancelConfirm(int count) {
    return '選択した $count 件のダウンロードをキャンセルしますか？未完了の進捗は破棄されます。';
  }

  @override
  String get resumeDownload => '再開';

  @override
  String downloadGroupTitle(int count) {
    return '一括ダウンロード · $count件';
  }

  @override
  String downloadGroupProgress(int done, int count) {
    return '$done/$count 完了';
  }

  @override
  String downloadGroupAuthorTitle(String name) {
    return '$name の作品';
  }

  @override
  String downloadTaskPageLabel(int page, int total) {
    return '$page/$total ページ';
  }

  @override
  String get downloadAuthorWorks => 'すべての作品をダウンロード';

  @override
  String get downloadAuthorWorksTitle => '作者の全作品をダウンロード';

  @override
  String downloadAuthorEnumerating(int count) {
    return '作品を列挙中…$count 件';
  }

  @override
  String downloadAuthorConfirmBody(int works, int pages) {
    return 'この作者の $works 件の作品（全 $pages ページ）をダウンロードします。';
  }

  @override
  String downloadAuthorTruncated(int max) {
    return '作品数が多いため、先頭 $max 件のみダウンロードします。';
  }

  @override
  String get downloadAuthorEmpty => 'この作者にはダウンロード可能な作品がありません。';

  @override
  String get downloadAuthorFailed => '作品の列挙に失敗しました';

  @override
  String get downloadCaption => '作品のキャプションを書き出す';

  @override
  String get downloadCaptionHint =>
      'イラスト・マンガのダウンロード時に、タイトル・作者・キャプションを同名の .txt として保存します';

  @override
  String get aboutVersion => 'バージョン';

  @override
  String get aboutCheckUpdate => '更新を確認';

  @override
  String get aboutCheckingUpdate => '更新を確認中…';

  @override
  String get aboutUpdateAvailable => '新しいバージョンがあります';

  @override
  String get aboutUpdateOpen => '確認';

  @override
  String get aboutExportLogs => 'ログをエクスポート';

  @override
  String get aboutNoLogs => 'ログはまだありません';

  @override
  String get aboutUpdateNoUpdate => '最新バージョンです';

  @override
  String get aboutUpdatePrerelease => 'プレリリースがあります。安定版チャンネルではインストールしません';

  @override
  String get aboutUpdateDownload => 'ダウンロードしてインストール';

  @override
  String get aboutUpdateDownloading => 'ダウンロードと検証中…';

  @override
  String get aboutUpdateConfirmTitle => '更新を確認';

  @override
  String get aboutUpdateConfirmDetail =>
      '署名、サイズ、ハッシュ、パッケージ名、証明書を検証した APK のみインストールします。続行しますか？';

  @override
  String get aboutUpdatePermission => 'この提供元からのアプリのインストールを許可してから、もう一度確認してください。';

  @override
  String get aboutUpdateStarted => 'システムインストーラーを開きました';

  @override
  String get aboutUpdateStore => 'このビルドの更新は F-Droid が管理します。';

  @override
  String get aboutUpdateUnavailable => '現在、更新を確認できません';

  @override
  String get aboutUpdateFailed => '更新の確認またはインストールに失敗しました。後でもう一度お試しください';

  @override
  String get aboutUpdateOffline => '更新サーバーに接続できません。ネットワークを確認して再試行してください';

  @override
  String get aboutUpdateRateLimited => 'GitHub のレート制限に達しました。しばらくしてから再試行してください';

  @override
  String get aboutUpdateInvalid => '更新マニフェストが無効です。開発者に報告してください';

  @override
  String get aboutUpdateBusy => '別の更新タスクが進行中です';

  @override
  String get aboutUpdateCanceled => '更新のインストールはキャンセルされました';

  @override
  String get aboutLicense => 'ライセンス';

  @override
  String get aboutAttribution => '帰属表示';

  @override
  String get aboutSource => 'ソースコード';

  @override
  String get aboutLicenseText =>
      'このプロジェクトは公開された Pixiv Func のソースを基にし、GNU AGPL v3.0 に従います。';

  @override
  String get aboutAttributionText => '著作権およびメンテナンス：Lopution。';

  @override
  String get settingsReadFailed => '設定の読み込みに失敗しました';

  @override
  String get settingsWriteFailed => '設定の保存に失敗しました';

  @override
  String settingsMutedSummary(int count) {
    return 'ミュート項目 $count 件';
  }

  @override
  String settingsDownloadTasksSummary(int count) {
    return 'アクティブなタスク $count 件';
  }

  @override
  String get settingsCredentialConfigured => '設定済み';

  @override
  String get settingsCredentialNotConfigured => '未設定';

  @override
  String get add => '追加';

  @override
  String get viewerNoImages => '表示できる画像がありません';

  @override
  String get detailDownloaded => 'ダウンロード済み';

  @override
  String get downloadAll => 'すべてダウンロード';

  @override
  String get downloadQueuedMessage => 'ダウンロードキューに追加しました';

  @override
  String get downloadAlreadyQueued => 'すでにダウンロードキューにあります';

  @override
  String get downloadSubmissionFailed => 'ダウンロードに失敗しました';

  @override
  String get downloadFailurePermission => 'ストレージ権限がありません';

  @override
  String get downloadFailureResource => 'デバイスのリソース不足またはファイルが大きすぎます';

  @override
  String get downloadFailureOwnership => 'このタスクは無効になりました。もう一度ダウンロードしてください';

  @override
  String get downloadFailureInterrupted => 'アプリの再起動で中断されました。再試行で続行できます';

  @override
  String get ugoiraSaveGif => 'GIFを保存';

  @override
  String get ugoiraLoadCanceled => '読み込みをキャンセルしました';

  @override
  String get ugoiraLoginRequired => 'GIFを保存するにはログインしてください';

  @override
  String get ugoiraSaved => 'GIFを保存しました';

  @override
  String get ugoiraSaveCanceled => 'GIFの保存をキャンセルしました';

  @override
  String get ugoiraSaveFailed => 'GIFの保存に失敗しました';

  @override
  String get ugoiraArchiveInvalid => 'アニメーションのアーカイブが無効です';

  @override
  String get ugoiraFrameCorrupt => 'アニメーションフレームが壊れています';

  @override
  String get ugoiraLoadFailed => 'アニメーションを読み込めませんでした';

  @override
  String get homeRecommended => 'おすすめ';

  @override
  String get homeRanking => 'ランキング';

  @override
  String get homeMe => 'マイページ';

  @override
  String get bookmarkIllust => 'イラストをブックマーク';

  @override
  String get bookmarkNovel => '小説をブックマーク';

  @override
  String get bookmarkOperationFailed => 'ブックマーク操作に失敗しました';

  @override
  String get save => '保存';

  @override
  String get saved => '保存しました';

  @override
  String get retry => '再試行';

  @override
  String get refresh => '更新';

  @override
  String get relatedWorks => '関連作品';

  @override
  String get cancel => 'キャンセル';

  @override
  String get confirm => '確認';

  @override
  String get continueAction => '続行';

  @override
  String get errorNetwork => 'ネットワーク接続に失敗しました';

  @override
  String get errorTimeout => '接続がタイムアウトしました';

  @override
  String get errorRateLimited => 'リクエストが多すぎます。しばらくしてから再試行してください';

  @override
  String get errorUnauthorized => '再ログインが必要です';

  @override
  String get errorServer => 'サーバーエラー';

  @override
  String get errorNotFound => 'コンテンツが見つからないか削除されました';

  @override
  String get errorParse => '応答を解析できませんでした';

  @override
  String get errorStorage => 'ストレージエラー';

  @override
  String get errorUnknown => '不明なエラー';

  @override
  String get errorDetails => '詳細';

  @override
  String get errorDetailsCopy => 'コピー';

  @override
  String get errorDetailsCopied => 'コピーしました';

  @override
  String errorWithReason(String action, String reason) {
    return '$action：$reason';
  }

  @override
  String labelValue(String label, String value) {
    return '$label：$value';
  }

  @override
  String get rankingDay => 'デイリー';

  @override
  String get rankingDayR18 => 'デイリー (R-18)';

  @override
  String get rankingDayMale => 'デイリー (男子に人気)';

  @override
  String get rankingDayMaleR18 => 'デイリー (男子に人気 & R-18)';

  @override
  String get rankingDayFemale => 'デイリー (女子に人気)';

  @override
  String get rankingDayFemaleR18 => 'デイリー (女子に人気 & R-18)';

  @override
  String get rankingWeek => 'ウィークリー';

  @override
  String get rankingWeekR18 => 'ウィークリー (R-18)';

  @override
  String get rankingWeekOriginal => 'ウィークリー (オリジナル)';

  @override
  String get rankingWeekRookie => 'ウィークリー (ルーキー)';

  @override
  String get rankingWeekAi => 'ウィークリー (AI)';

  @override
  String get rankingWeekAiR18 => 'ウィークリー (AI & R-18)';

  @override
  String get rankingWeekR18G => 'ウィークリー (R-18G)';

  @override
  String get rankingMonth => 'マンスリー';

  @override
  String get rankingEmpty => 'ランキングの内容はありません';

  @override
  String get rankingPickDate => '日付を選択';

  @override
  String rankingDateLabel(String date) {
    return '$dateのランキング';
  }

  @override
  String get rankingBackToLatest => '最新に戻る';

  @override
  String rankingLoadFailed(String mode) {
    return '$modeの読み込みに失敗しました';
  }

  @override
  String get rankingLoadMoreFailed => '追加コンテンツの読み込みに失敗しました';

  @override
  String get profileBookmarked => 'ブックマーク';

  @override
  String get profileFollowing => 'フォロー';

  @override
  String get profileFans => 'フォロワー';

  @override
  String get profileMyPixiv => 'マイピク';

  @override
  String profileFollowingCount(String count) {
    return 'フォロー $count';
  }

  @override
  String profileMyPixivCount(String count) {
    return 'マイピク $count';
  }

  @override
  String profileWorksTotal(String count) {
    return '全 $count 件';
  }

  @override
  String get profileTagFilterAll => 'タグ：すべて';

  @override
  String profileTagFilter(String tag) {
    return 'タグ：$tag';
  }

  @override
  String get profileTagAny => 'すべて';

  @override
  String get profileTagMore => 'その他のタグ…';

  @override
  String get profileAbout => '概要';

  @override
  String get profileIllust => 'イラスト';

  @override
  String get profileManga => 'マンガ';

  @override
  String get profileNovel => '小説';

  @override
  String get searchTitle => '検索';

  @override
  String get searchHint => '作品、ユーザー、タグを検索';

  @override
  String get searchBarHint => '検索';

  @override
  String get searchReverseImage => '画像で検索';

  @override
  String get searchTrending => '人気タグ';

  @override
  String get searchNoTrending => '人気タグはありません';

  @override
  String get searchTrendingFailed => '人気タグの読み込みに失敗しました';

  @override
  String get searchIllustManga => 'イラスト・マンガ';

  @override
  String get searchNovel => '小説';

  @override
  String get searchUser => 'ユーザー';

  @override
  String get searchCancel => 'キャンセル';

  @override
  String get searchSubmit => '検索';

  @override
  String get searchClear => 'クリア';

  @override
  String get contentLoading => '読み込み中';

  @override
  String get searchLoading => '検索中';

  @override
  String get searchNoResults => '検索結果はありません';

  @override
  String get searchLoadFailed => '検索に失敗しました';

  @override
  String get searchLoadMoreFailed => '追加結果の読み込みに失敗しました';

  @override
  String get searchRetry => '再試行';

  @override
  String get searchRefreshFailed => '更新に失敗しました';

  @override
  String get searchInputEmpty => '検索語を入力してください';

  @override
  String get searchReversePick => '画像を選択';

  @override
  String get searchReversePreparing => '画像を準備中…';

  @override
  String get searchReverseSearching => '検索中…';

  @override
  String get searchReverseCancel => 'キャンセル';

  @override
  String get searchReverseUse => '画像で検索を開始';

  @override
  String get searchReverseRetry => '別の画像を選択';

  @override
  String get searchReverseReady => '画像の準備が完了しました';

  @override
  String get searchReverseNoResults => '一致する結果はありません';

  @override
  String get searchReverseIntentFailed => '共有された画像を使用できません';

  @override
  String get searchReverseOpenFailed => 'ソースリンクを開けません';

  @override
  String get searchReverseRateLimited => '検索が混み合っています。しばらくしてからお試しください';

  @override
  String searchReverseRateLimitedWait(int seconds) {
    return '約 $seconds 秒後に再試行できます';
  }

  @override
  String get searchReverseDailyLimit => '本日の匿名検索回数の上限に達しました。明日もう一度お試しください';

  @override
  String searchReverseChallenge(String engine) {
    return '$engine が人による確認を求めています。ウェブページで確認を済ませてから検索できます';
  }

  @override
  String get searchReversePageLoadFailed => '結果ページの読み込みに失敗しました';

  @override
  String get searchReverseUploadTapHint =>
      'ページ内のアップロードボタンをタップすると検索します。選択した画像は自動で入力されます。';

  @override
  String get searchReverseUploadPickHint => 'ページのファイル選択で同じ画像をもう一度選んでください。';

  @override
  String get searchReverseRetrySameEngine => 'このエンジンで再試行';

  @override
  String get searchReverseEngineUnsupported => '選択した画像はこのエンジンの入力制限を満たしていません';

  @override
  String get searchReverseIntro => '選択した画像は選択中のエンジンにアップロードされ、結果ページがアプリ内で開きます。';

  @override
  String get searchReverseFailed => '検索に失敗しました';

  @override
  String get searchReverseDone => '完了';

  @override
  String get searchReverseEngineSwitch => 'エンジンを切り替え';

  @override
  String searchReverseEngineUnavailable(String engine) {
    return '$engine は現在利用できません';
  }

  @override
  String get searchReverseNetwork => '接続できませんでした。ネットワークを確認してもう一度お試しください';

  @override
  String searchReverseBadResponse(String engine) {
    return '$engine から読み取れないページが返されました';
  }

  @override
  String get searchReverseStopped => '検索を停止しました';

  @override
  String get searchReverseImageFormat =>
      'この画像形式には対応していません。PNG、JPEG、GIF、WebP を選んでください';

  @override
  String get searchReverseImageTooLarge => '画像が大きすぎて処理できません';

  @override
  String get searchReverseImagePermission => 'この画像を読み取る権限がありません。もう一度選んでください';

  @override
  String get searchReverseImageUnreadable => 'この画像を読み取れません。別の画像を選んでください';

  @override
  String get searchReverseCleanupFailed => '一時画像を削除できませんでした';

  @override
  String get searchReversePickerUnavailable => 'この端末では画像を選べません';

  @override
  String get searchReversePrivacyNote => '画像は選んだエンジンにだけ送信され、このページを離れると削除されます';

  @override
  String get searchReverseOpenInBrowser => 'ウェブページで検索';

  @override
  String searchReverseTryEngine(String engine) {
    return '$engine で検索';
  }

  @override
  String get searchReverseAllEnginesTried => 'どのエンジンでも一致する結果は見つかりませんでした';

  @override
  String get searchFilters => 'フィルター';

  @override
  String searchFiltersActive(int count) {
    return 'フィルター（$count 件適用中）';
  }

  @override
  String get searchReset => 'リセット';

  @override
  String get searchApply => '適用';

  @override
  String get searchTarget => '検索対象';

  @override
  String get searchPartialTags => 'タグ部分一致';

  @override
  String get searchExactTags => 'タグ完全一致';

  @override
  String get searchTitleCaption => 'タイトルとキャプション';

  @override
  String get searchTargetText => '本文';

  @override
  String get searchTargetKeyword => 'キーワード';

  @override
  String get searchSort => '並び順';

  @override
  String get searchDateDesc => '新着順';

  @override
  String get searchDateAsc => '古い順';

  @override
  String get searchPopularDesc => '人気順';

  @override
  String get searchPopularMaleDesc => '男性向け人気';

  @override
  String get searchPopularFemaleDesc => '女性向け人気';

  @override
  String get searchAiSection => 'AI 作品';

  @override
  String get searchAiAll => 'すべて';

  @override
  String get searchAiExclude => 'AI を除外';

  @override
  String get searchAiOnly => 'AI のみ';

  @override
  String get searchBookmarkSection => 'ブックマーク数';

  @override
  String get searchMin => '最小';

  @override
  String get searchMax => '最大';

  @override
  String get searchRatioSection => '縦横比';

  @override
  String get searchRatioAny => '指定なし';

  @override
  String get searchRatioLandscape => '横長';

  @override
  String get searchRatioPortrait => '縦長';

  @override
  String get searchRatioSquare => '正方形';

  @override
  String get searchContentSection => '作品タイプ';

  @override
  String get searchContentAll => 'すべて';

  @override
  String get searchContentIllustUgoira => 'イラスト・うごイラ';

  @override
  String get searchContentIllust => 'イラストのみ';

  @override
  String get searchContentUgoira => 'うごイラのみ';

  @override
  String get searchContentManga => 'マンガのみ';

  @override
  String get searchResolutionSection => '解像度';

  @override
  String get searchWidth => '幅';

  @override
  String get searchHeight => '高さ';

  @override
  String get searchTextLength => '本文の長さ';

  @override
  String get searchChars => '文字数';

  @override
  String get searchOriginalOnly => 'オリジナルのみ';

  @override
  String get searchSetDefault => 'デフォルトにする';

  @override
  String searchRangeAtLeast(String label, String value) {
    return '$label $value以上';
  }

  @override
  String searchRangeAtMost(String label, String value) {
    return '$label $value以下';
  }

  @override
  String searchRangeBetween(String label, String min, String max) {
    return '$label $min～$max';
  }

  @override
  String searchDateFrom(String date) {
    return '$date以降';
  }

  @override
  String searchDateUntil(String date) {
    return '$dateまで';
  }

  @override
  String searchDateBetween(String start, String end) {
    return '$start～$end';
  }

  @override
  String get searchDuration => '投稿日';

  @override
  String get searchAllTime => '指定なし';

  @override
  String get searchWithinDay => '1日以内';

  @override
  String get searchWithinWeek => '1週間以内';

  @override
  String get searchWithinMonth => '1か月以内';

  @override
  String get searchStartDate => '開始日';

  @override
  String get searchEndDate => '終了日';

  @override
  String get searchInvalidDateRange => '開始日は終了日より後にできません';

  @override
  String get searchInvalidBoundRange => '最小値は最大値より大きくできません';

  @override
  String get searchPopularPreviewHint => 'プレミアム未加入のため、人気順はプレビュー結果を使用します';

  @override
  String get searchNoSuggestions => '候補はありません';

  @override
  String get searchSuggestionFill => '検索欄に入力';

  @override
  String get searchSuggestionSearch => '今すぐ検索';

  @override
  String get searchHistoryTitle => '検索履歴';

  @override
  String get searchHistoryClear => 'すべて消去';

  @override
  String get searchHistoryClearConfirm => '検索履歴をすべて消去しますか？';

  @override
  String get searchHistoryRemoved => '検索履歴から削除しました';

  @override
  String get searchHistoryRemove => '検索履歴から削除';

  @override
  String searchOpenIllust(int id) {
    return 'イラスト・マンガ ID $id を開く';
  }

  @override
  String searchOpenNovel(int id) {
    return '小説 ID $id を開く';
  }

  @override
  String searchOpenUser(int id) {
    return 'ユーザー ID $id を開く';
  }

  @override
  String get searchModifyQuery => '検索を編集';

  @override
  String get searchUserAccount => 'アカウント';

  @override
  String get illustDetailTitle => '作品詳細';

  @override
  String detailMetaCountsSemantics(String views, String bookmarks) {
    return '閲覧 $views、ブックマーク $bookmarks';
  }

  @override
  String get detailCollapsePages => '折りたたむ';

  @override
  String get detailStatViews => '閲覧';

  @override
  String get detailStatBookmarks => 'ブックマーク';

  @override
  String get detailStatComments => 'コメント';

  @override
  String detailStatsSemantics(String views, String bookmarks, String comments) {
    return '閲覧 $views、ブックマーク $bookmarks、コメント $comments';
  }

  @override
  String get detailSectionCaption => 'キャプション';

  @override
  String get detailSectionTags => 'タグ';

  @override
  String get detailViewAll => 'すべて見る';

  @override
  String get detailSectionAuthorWorks => 'この作者の他の作品';

  @override
  String get detailAuthorNoOtherWorks => '他の作品はまだありません';

  @override
  String get detailAuthorWorksLoadFailed => '作者の作品を読み込めませんでした';

  @override
  String get feedContinueLoading => '続きを読み込む';

  @override
  String detailExpandPages(int count) {
    return '全$count枚を表示';
  }

  @override
  String get illustDetailOpenLinkFailed => 'リンクを開けませんでした';

  @override
  String illustDetailRestricted(int id) {
    return 'この作品は削除または非公開になりました（ID: $id）';
  }

  @override
  String get illustDetailNotFound => '作品が存在しないか削除されました';

  @override
  String get illustDetailLoadFailed => '作品の読み込みに失敗しました';

  @override
  String get commentTitle => 'コメント';

  @override
  String get commentInput => 'コメントを追加';

  @override
  String get commentReply => '返信';

  @override
  String get commentReplyTo => '返信先';

  @override
  String get commentCancelReply => '返信をキャンセル';

  @override
  String get commentSend => '送信';

  @override
  String get commentDelete => 'コメントを削除';

  @override
  String get commentDeleteConfirm => 'このコメントを削除しますか？';

  @override
  String get commentDeleteFailed => 'コメントの削除に失敗しました';

  @override
  String get commentSendFailed => 'コメントの送信に失敗しました';

  @override
  String get commentLoadFailed => 'コメントの読み込みに失敗しました';

  @override
  String get relatedLoadFailed => '関連作品の読み込みに失敗しました';

  @override
  String get commentLoadMoreFailed => 'コメントをさらに読み込めませんでした';

  @override
  String get commentNoResults => 'コメントはありません';

  @override
  String get commentReplies => '返信';

  @override
  String commentViewReplies(int count) {
    return '返信$count件を表示';
  }

  @override
  String get commentMoreActions => 'その他の操作';

  @override
  String get commentTranslate => '翻訳';

  @override
  String get commentTranslation => '翻訳結果';

  @override
  String get commentTranslationUnavailable => '翻訳は利用できません。設定で有効にしてください。';

  @override
  String get commentTranslationFailed => '翻訳に失敗しました';

  @override
  String get commentTranslationInvalidCredentials =>
      '翻訳の認証情報が無効です。設定を確認してください。';

  @override
  String get commentTranslationRateLimited => '翻訳が混み合っているか、上限に達しました';

  @override
  String get commentEmoji => 'Emoji';

  @override
  String get commentSending => '送信中';

  @override
  String commentStampLabel(int id) {
    return 'スタンプ $id';
  }

  @override
  String get commentStamps => 'Stamp';

  @override
  String get commentPermissionDenied => '自分のコメントのみ削除できます';

  @override
  String get newTitle => '新着';

  @override
  String get newFollowing => 'フォロー中';

  @override
  String get newEveryone => 'みんな';

  @override
  String get newMyPixiv => 'マイピク';

  @override
  String get newNovels => '小説の新着';

  @override
  String get recommendedIllust => 'イラスト';

  @override
  String get recommendedManga => '漫画';

  @override
  String get recommendedNovel => '小説';

  @override
  String get recommendedUser => 'ユーザー';

  @override
  String get recommendedEmpty => 'おすすめはありません';

  @override
  String get recommendedLoadFailed => 'おすすめの読み込みに失敗しました';

  @override
  String get recommendedLoadMoreFailed => '追加コンテンツの読み込みに失敗しました';

  @override
  String get recommendedEnd => 'これ以上はありません';

  @override
  String get newLoading => '新着作品を読み込み中';

  @override
  String get newEmpty => 'コンテンツはありません';

  @override
  String get newLoadFailed => '新着作品の読み込みに失敗しました';

  @override
  String get newLoadMoreFailed => '追加読み込みに失敗しました';

  @override
  String get newRetry => '再試行';

  @override
  String get newRefreshFailed => '更新に失敗しました';

  @override
  String get recommendedRefreshFailed => '更新に失敗しました';

  @override
  String get profileId => 'ユーザー ID';

  @override
  String get profileAccount => 'アカウント';

  @override
  String get profileIntroduction => '紹介';

  @override
  String get profileBirthday => '誕生日';

  @override
  String get profileGender => '性別';

  @override
  String get profileRegion => '地域';

  @override
  String get profileJob => '職業';

  @override
  String get profileWebsite => 'ホームページ';

  @override
  String get profileWorkspace => '作業環境';

  @override
  String get profileStats => '統計';

  @override
  String get profileLoading => 'プロフィールを読み込み中';

  @override
  String get profileNotFound => 'ユーザーが存在しないか削除されています';

  @override
  String get profileBlocked => 'このユーザーのプロフィールは表示できません';

  @override
  String get profileLoadFailed => 'プロフィールの読み込みに失敗しました';

  @override
  String get profileItemsEmpty => 'コンテンツはありません';

  @override
  String get profileLoadMoreFailed => '追加読み込みに失敗しました';

  @override
  String get profileRetry => '再試行';

  @override
  String get profileNovelPending => '小説一覧は Novel Reader モジュールで接続されます';

  @override
  String get profileShare => 'ユーザーを共有';

  @override
  String get profileShareHint => '次のユーザーリンクを共有できます';

  @override
  String get profileShareClose => '閉じる';

  @override
  String get profileSettings => '設定';

  @override
  String get restrictSelector => '公開範囲を選択';

  @override
  String get restrictPublic => '公開';

  @override
  String get restrictPrivate => '非公開';

  @override
  String get follow => 'フォロー';

  @override
  String get followed => 'フォロー中';

  @override
  String get followPrivately => '非公開でフォロー';

  @override
  String get unfollow => 'フォローを解除';

  @override
  String get followPublicAction => 'フォローする';

  @override
  String get followSwitchToPrivate => '非公開に切り替え';

  @override
  String get followSwitchToPublic => '公開に切り替え';

  @override
  String get followFailed => 'フォロー操作に失敗しました';

  @override
  String get userPreviewFollow => 'フォロー';

  @override
  String get novelLoading => '小説を読み込み中';

  @override
  String get novelNotFound => '小説が存在しないか削除されています';

  @override
  String get novelRestricted => 'この小説は制限されています';

  @override
  String get novelContentUnavailable => '現在の API は小説本文を返しませんでした';

  @override
  String get novelLoadFailed => '小説の読み込みに失敗しました';

  @override
  String get novelLayoutFailed => '小説の組版に失敗しました';

  @override
  String get novelRetry => '再試行';

  @override
  String get novelNoContent => '本文はありません';

  @override
  String get novelWords => '文字';

  @override
  String get novelSeries => 'シリーズ';

  @override
  String get novelRanking => '小説ランキング';

  @override
  String get novelSeriesUnavailable => 'シリーズ情報を利用できません';

  @override
  String get novelInfoTitle => '作品情報';

  @override
  String get novelPrevious => '前の小説';

  @override
  String get novelNext => '次の小説';

  @override
  String get novelDecreaseFont => '文字を小さく';

  @override
  String get novelIncreaseFont => '文字を大きく';

  @override
  String get novelReadingProgress => '読書進捗';

  @override
  String get novelReaderSettings => '読書設定';

  @override
  String get novelSettingsSaveFailed => '読書設定を保存できませんでした。今回のみ有効です';

  @override
  String get novelFontSize => '文字サイズ';

  @override
  String get novelLineHeight => '行間';

  @override
  String get novelThemeSystem => 'システム';

  @override
  String get novelThemePaper => '紙';

  @override
  String get novelThemeSepia => '目に優しい';

  @override
  String get novelThemeNight => 'ナイト';

  @override
  String get aboutDisplayRefreshRate => '画面リフレッシュレート';

  @override
  String get cardActionDownload => 'ダウンロード';

  @override
  String get cardActionWatchLater => 'あとで見る';

  @override
  String get cardActionRemoveWatchLater => 'あとで見るから削除';

  @override
  String get cardActionShare => '共有';

  @override
  String get share => '共有';

  @override
  String get openInBrowser => 'ブラウザで開く';

  @override
  String get linkCopied => 'リンクをコピーしました';

  @override
  String get copyLink => 'リンクをコピー';

  @override
  String get openLink => 'リンクを開く';

  @override
  String get watchLaterAdded => 'あとで見るに追加しました';

  @override
  String get watchLaterTitle => 'あとで見る';

  @override
  String get watchLaterEmpty => '一時保存した作品がここに表示されます';

  @override
  String get watchLaterLoadFailed => 'あとで見るの読み込みに失敗しました';

  @override
  String get bookmarkEditTitle => 'ブックマークを編集';

  @override
  String get bookmarkTags => 'ブックマークタグ';

  @override
  String get bookmarkTagNewHint => 'タグを入力して確定';

  @override
  String get bookmarkTagFilterEmpty => '読み込み済み作品に一致するものはありません';

  @override
  String get bookmarkTagFilterHint => '読み込み済み作品を絞り込む';

  @override
  String get bookmarkTagSuggestions => 'よく使うタグ';

  @override
  String get bookmarkTagsEmpty => 'ブックマークタグはまだありません';

  @override
  String get bookmarkTagsLoadFailed => 'ブックマークタグを読み込めませんでした';

  @override
  String get bookmarkTagsEnd => 'すべてのタグを表示しました';

  @override
  String get seriesTitle => 'シリーズ';

  @override
  String get seriesLoadFailed => 'シリーズの読み込みに失敗しました';

  @override
  String get seriesLoadMoreFailed => '追加読み込みに失敗しました';

  @override
  String get seriesEmpty => 'このシリーズにはまだ作品がありません';

  @override
  String seriesWorksCount(int count) {
    return '全 $count 作品';
  }

  @override
  String seriesEpisode(int order) {
    return '第 $order 話';
  }

  @override
  String get seriesStartReading => '読み始める';

  @override
  String seriesContinueEpisode(int n) {
    return '第$n話から続ける';
  }

  @override
  String get seriesContinue => '続きを読む';

  @override
  String get seriesStartFromFirst => '第1話から読む';

  @override
  String get seriesPrevious => '前の作品';

  @override
  String get seriesNext => '次の作品';

  @override
  String get watchlistTitle => 'ウォッチリスト';

  @override
  String get watchlistManga => '漫画';

  @override
  String get watchlistNovel => '小説';

  @override
  String get watchlistEmpty => 'フォロー中のシリーズはまだありません';

  @override
  String get watchlistLoadFailed => 'ウォッチリストの読み込みに失敗しました';

  @override
  String get watchlistLoadMoreFailed => '追加の読み込みに失敗しました';

  @override
  String get watchlistAdd => 'シリーズをフォロー';

  @override
  String get watchlistRemove => 'フォロー解除';

  @override
  String get watchlistFailed => 'シリーズのフォロー操作に失敗しました';

  @override
  String get watchlistNewContent => '新着';

  @override
  String get localNovelsTitle => 'ローカル小説';

  @override
  String get localNovelsEmpty => 'インポートした小説はまだありません';

  @override
  String get localNovelsLoadFailed => 'ローカル小説の読み込みに失敗しました';

  @override
  String get localNovelsImport => 'TXT をインポート';

  @override
  String get localNovelsImportFailed => 'インポートに失敗しました';

  @override
  String localNovelsImported(String title) {
    return '「$title」をインポートしました';
  }

  @override
  String get localNovelsImportedLossy =>
      'インポートしましたが、エンコーディングを完全に認識できず文字化けしている可能性があります';

  @override
  String get localNovelsDelete => '削除';

  @override
  String localNovelsDeleteConfirm(String title) {
    return '「$title」を削除しますか？ローカルファイルも削除されます。';
  }

  @override
  String get novelChapters => '目次';

  @override
  String get localNovelFileInfo => 'ファイル情報';

  @override
  String localNovelFileEncoding(String encoding) {
    return 'エンコーディング: $encoding';
  }

  @override
  String localNovelFileImportedAt(String date) {
    return 'インポート日時 $date';
  }

  @override
  String localNovelsChars(int count) {
    return '$count 文字';
  }

  @override
  String localNovelContinue(int percent) {
    return '続きを読む · $percent%';
  }

  @override
  String get profileSeries => 'シリーズ';

  @override
  String get spotlightTitle => 'スポットライト';

  @override
  String get spotlightSeeAll => 'すべて';

  @override
  String get spotlightArticleLoadFailed => '記事の読み込みに失敗しました';

  @override
  String get spotlightCategoryAll => 'すべて';

  @override
  String get spotlightCategoryIllust => 'イラスト';

  @override
  String get spotlightCategoryManga => 'マンガ';

  @override
  String get spotlightLoadFailed => 'スポットライトの読み込みに失敗しました';

  @override
  String get spotlightLoadMoreFailed => '続きの読み込みに失敗しました';

  @override
  String get spotlightEmpty => 'スポットライト記事がありません';

  @override
  String get hapticStrength => '触覚の強さ';

  @override
  String get hapticStrengthOff => 'オフ';

  @override
  String get hapticStrengthLight => '弱';

  @override
  String get hapticStrengthStandard => '標準';

  @override
  String get hapticStrengthStrong => '強';

  @override
  String get hapticTierComposition => 'この端末は細かな振動に対応しており、強さを段階的に調整できます';

  @override
  String get hapticTierPredefined => 'この端末はシステムのプリセット振動を使い、段階ごとに効果を切り替えます';

  @override
  String get hapticTierSystem => 'この端末はシステムの触覚のみ対応しており、強さは調整できません';

  @override
  String get hapticTierNone => 'この端末には振動機能がありません';

  @override
  String get hapticTierUnknown => 'この端末の振動機能を取得できませんでした';

  @override
  String get hapticSystemOff => 'システム設定でタッチ振動がオフのため、アプリの触覚は動作しません';

  @override
  String get downloadSelectPages => 'ダウンロードするページを選択';

  @override
  String get downloadSelectedPages => '選択したページをダウンロード';

  @override
  String get selectAll => 'すべて選択';

  @override
  String viewerPageLabel(int page, int total) {
    return '$total ページ中 $page ページ目';
  }

  @override
  String get tagActionSearch => 'このタグを検索';

  @override
  String get tagActionCopy => 'タグ名をコピー';

  @override
  String get tagActionMute => 'このタグをミュート';

  @override
  String get tagActionUnmute => 'このタグのミュートを解除';

  @override
  String get tagActionMuteMode => 'タグをまとめてミュート';

  @override
  String get tagCopied => 'タグをコピーしました';

  @override
  String ugoiraExporting(int percent) {
    return 'GIF を書き出し中… $percent%';
  }

  @override
  String get viewerFitScreen => '画面に合わせる';

  @override
  String get viewerSavePage => 'このページを保存';

  @override
  String get viewerJumpToPage => 'ページへ移動';

  @override
  String get viewerInfo => '作品情報';

  @override
  String get viewerOpenDetail => '詳細ページを開く';

  @override
  String illustPagesTotal(int count) {
    return '全 $count ページ';
  }

  @override
  String get badgeUgoira => 'うごイラ';

  @override
  String get badgeAi => 'AI生成';

  @override
  String rankLabel(int rank) {
    return '$rank位';
  }

  @override
  String get openAuthorProfile => '作者のページを開く';

  @override
  String get expandText => 'もっと見る';

  @override
  String get collapseText => '閉じる';

  @override
  String get illustInfoJump => '作品情報へ移動';

  @override
  String get manage => '管理';

  @override
  String selectedCount(int n) {
    return '$n 件選択中';
  }

  @override
  String get undo => '元に戻す';

  @override
  String get watchLaterRemoved => 'あとで見るから削除しました';

  @override
  String get bookmarkRemoved => 'ブックマークを解除しました';

  @override
  String get followRemoved => 'フォローを解除しました';

  @override
  String get muteRemoved => 'ミュートを解除しました';

  @override
  String get watchlistOpenContents => '目次を開く';

  @override
  String get imageRetry => '画像を再読み込み';

  @override
  String get imageLoading => '画像を読み込み中';

  @override
  String get timeJustNow => 'たった今';

  @override
  String timeMinutesAgo(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count分前',
    );
    return '$_temp0';
  }

  @override
  String timeHoursAgo(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count時間前',
    );
    return '$_temp0';
  }

  @override
  String timeDaysAgo(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count日前',
    );
    return '$_temp0';
  }
}
