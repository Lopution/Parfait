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
  String get welcome1 => 'Pixiv Funcをご利用ありがとうございます';

  @override
  String get welcome2 => '初期設定を開始します';

  @override
  String get start => '開始';

  @override
  String get selectLanguage => '言語の選択';

  @override
  String get selectTheme => 'テーマの選択';

  @override
  String get next => '次へ';

  @override
  String get later => '後で設定を変更できます';

  @override
  String get dark => 'ダーク';

  @override
  String get light => 'ライト';

  @override
  String get system => 'システムのデフォルト';

  @override
  String get loginTitle => '登録･ログイン';

  @override
  String get loginProxyNoticeTitle => 'お知らせ';

  @override
  String get loginProxyNoticeBody =>
      'ネットワーク環境の制限により、ログインまたは登録の前にシステムまたは外部プロキシを有効にしてください。Pixiv Funcに内蔵プロキシはありません。';

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
  String loginCallbackInvalid(String reason) {
    return 'ログインコールバックが無効です: $reason';
  }

  @override
  String loginNetworkError(String status) {
    return 'ネットワークエラー (HTTP $status)';
  }

  @override
  String loginPageLoadFailed(String error) {
    return 'ページの読み込みに失敗しました ($error)';
  }

  @override
  String get loginWebView2Missing =>
      'ログインには WebView2 Runtime が必要ですが、このシステムでは検出されませんでした。インストールしてからこのページを開き直してください。';

  @override
  String get loginInstallWebView2 => 'WebView2 Runtime をインストール';

  @override
  String loginFailed(String error) {
    return 'ログインに失敗しました: $error';
  }

  @override
  String loginFailedType(String type) {
    return 'ログインに失敗しました ($type)';
  }

  @override
  String get networkCompatibility => 'Pixiv公式ネットワーク互換';

  @override
  String get networkCompatibilityHint =>
      'まず直接 HTTPS を試し、明確な転送障害時だけ Pixiv 公式宛先に厳格な HTTPS 候補を試します。他の通信はプロキシせず、証明書検証も無効にしません。';

  @override
  String get getMoreHelp => '詳細なヘルプ >>';

  @override
  String get useLoginWithClipboardHint => 'もしくは\\nプロフィール画像を長押ししてアカウントデータをコピー';

  @override
  String get useLoginWithClipboard => 'クリップボードに保存されたデータでログイン';

  @override
  String get accountTransferWarning =>
      'クリップボードは短時間保持され、他のアプリに読み取られる可能性があります。この形式は暗号化も送信者認証も提供しません。';

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
  String get loginAgree => 'ログインすると利用規約に同意したものとみなします';

  @override
  String get userAgreement => '《Pixiv Func利用規約》';

  @override
  String get agreementTitle => 'Pixiv Func利用規約';

  @override
  String get agreementIntro =>
      'Pixiv Funcをご利用いただきありがとうございます。本アプリを利用した時点で、以下の条項に同意したものとします。同意できない場合は利用を中止してください。';

  @override
  String get agreementAccountTitle => 'アカウントと認証';

  @override
  String get agreementAccountBody =>
      '本アプリはPixiv公式のログインフローを使用し、Pixivのパスワードを本アプリに入力または共有するよう求めません。アカウントと端末を安全に管理し、利用状況や認証の取り消しはPixivの設定で管理してください。';

  @override
  String get agreementContentTitle => 'コンテンツと著作権';

  @override
  String get agreementContentBody =>
      '作品、コメント、プロフィールなどはPixivおよびユーザーが提供し、権利は各権利者に帰属します。法律とPixivの規約が許す範囲でのみ閲覧・保存・共有し、他者の権利を侵害しないでください。';

  @override
  String get agreementNetworkTitle => 'ネットワークアクセス';

  @override
  String get agreementNetworkBody =>
      '本アプリの互換ルーティングはPixiv公式宛先のみに使用します。他の通信をプロキシせず、証明書検証も有効です。ネットワーク状況、API変更、サービス停止は保証されません。';

  @override
  String get agreementPrivacyTitle => 'プライバシーとローカルデータ';

  @override
  String get agreementPrivacyBody =>
      '認証情報はシステムの安全な保存領域に保管し、設定・キャッシュ・履歴・ダウンロードは端末内に保存します。個人情報を販売することはありません。アンインストールやデータ消去でローカル内容が失われる場合があります。';

  @override
  String get agreementDisclaimerTitle => '免責事項';

  @override
  String get agreementDisclaimerBody =>
      '本アプリはPixiv Inc.とは無関係の非公式サードパーティークライアントです。法律で認められる範囲で、ネットワーク、アカウント、第三者サービス、不可抗力による損失やアクセス障害について作者は責任を負いません。';

  @override
  String get agreementUpdates =>
      '本規約は機能や法令の変更に応じて更新されることがあります。利用を続けることで更新後の規約に同意したものとします。';

  @override
  String get settingsTitle => '設定';

  @override
  String get settingsGroupAppearance => '外観';

  @override
  String get settingsGroupNetwork => 'ネットワークと閲覧';

  @override
  String get settingsGroupContent => 'コンテンツ';

  @override
  String get settingsGroupDownload => 'ダウンロード';

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
      'デフォルトは直結。Pixiv 公式ドメインのみ、明確な転送失敗時に厳格 HTTPS 候補を試します。他トラフィックはプロキシせず、証明書検証は無効化しません。';

  @override
  String get networkModeListTitle => 'ネットワークモード';

  @override
  String get networkModeAutomatic => '自動';

  @override
  String get networkModeAutomaticHint =>
      '標準ネットワークスタック：ホストグループごとに到達可能な経路を選択します。';

  @override
  String get networkModeDirectOnly => '直結のみ';

  @override
  String get networkModeDirectOnlyHint =>
      'システム DNS + 実 SNI で直結します。直結で利用可能なネットワーク向け。';

  @override
  String get networkAdvanced => '詳細設定';

  @override
  String get networkAdvancedHint => 'DoH エンドポイント、ECH フロントホストなどの詳細。';

  @override
  String get networkAdvancedReset => 'デフォルトに戻す';

  @override
  String get networkDoh => '厳格フォールバックで DoH を使用';

  @override
  String get networkDohHint =>
      '有効時、フォールバック層は DoH（デフォルト Cloudflare DoH：ドメイン端点を静的 Anycast IP にピン留め — 汚染されたシステム DNS を回避；カスタム端点は自身のホスト名を解決）で解決します。無効時はシステム DNS を使用します。';

  @override
  String get networkDohEndpoints => 'DoH エンドポイント（カンマ区切り、https URL）';

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
  String get networkProbeHint =>
      'Pixiv の4公式ホストを層ごとにテスト：システム DNS → DoH → TCP → TLS(実SNI) → 最小リクエスト。TCP 成功でも TLS ハンドシェイク失敗 = SNI ブロック。';

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
  String get copy => 'コピー';

  @override
  String get themeSettings => 'テーマ';

  @override
  String get languageSettings => '言語';

  @override
  String get translateSettings => '翻訳';

  @override
  String get browseSettings => 'ブラウズ設定';

  @override
  String get downloadSettings => 'ダウンロード設定';

  @override
  String get historySettings => '履歴';

  @override
  String get historyView => '閲覧履歴を見る';

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
  String get reopen => '開き直す';

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
  String get profileEditChooseImage => '画像を選択';

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
  String get backupExportHint => '選択したフォルダに pixiv-func-backup-*.json を保存';

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
  String backupImportDone(int tags, int users, int works, int history) {
    return '読み込み完了：タグ +$tags、ユーザー +$users、作品ミュート変更 $works 件、履歴 $history 件';
  }

  @override
  String get imageSource => '画像ソース';

  @override
  String get imageSourceNormal => '公式 CDN（システム DNS / HTTPS）';

  @override
  String get imageSourcePixivCat => 'pixiv.cat ミラー';

  @override
  String get imageSourcePixivRe => 'pixiv.re ミラー';

  @override
  String get imageSourcePixivNl => 'pixiv.nl ミラー';

  @override
  String get imageSourceCustom => 'カスタムリバースプロキシ';

  @override
  String get imageSourceCustomHint =>
      'https://host[/path]、例：https://i.pixiv.cat';

  @override
  String get imageSourceCustomUnset => '未設定';

  @override
  String get imageSourceCustomInvalid =>
      '無効なソースです：https・DNS ホスト名・ポート 443 が必要です';

  @override
  String get imageSourceTest => 'テスト';

  @override
  String imageSourceTestOk(String code) {
    return 'ミラーに接続できました（HTTP $code）';
  }

  @override
  String get imageSourceTestFailed => 'ミラー接続テストに失敗しました';

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
  String get localHistory => 'ローカル閲覧履歴';

  @override
  String get pixivHistory => 'Pixiv 閲覧履歴';

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
  String muteFailed(Object error) {
    return 'ミュート操作に失敗しました:$error';
  }

  @override
  String get reduceMotion => '視覚効果を減らす';

  @override
  String get reduceMotionHint => '画面遷移・リスト入場・押下フィードバックなどの装飾アニメーションをオフにします';

  @override
  String get maxDownloadCount => '同時ダウンロード数の上限';

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
  String get saveLocationPixivAlbum => 'PixivFunc アルバム（デフォルト）';

  @override
  String get saveLocationCustomAlbum => 'カスタムアルバム名';

  @override
  String get saveLocationCustomAlbumHint => '英数字・日本語・アンダースコアのみ';

  @override
  String get saveLocationUseCustomAlbum => 'カスタムアルバムを使用';

  @override
  String get saveLocationAlbumInvalid => 'アルバム名が無効です';

  @override
  String get saveLocationSafFolder => 'フォルダー（システムディレクトリ選択）';

  @override
  String get saveLocationSafFolderHint => 'システム SAF でフォルダーを選択し、権限を永続化';

  @override
  String get saveLocationSafPicked => 'フォルダーを選択済み';

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
  String namingTemplateVariables(String variables) {
    return '変数：$variables。不正な文字は _ に置換され、長い名前は切り詰められます。';
  }

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
  String get historySettingsHint => '履歴機能がこのスイッチを読み取ります。無効にすると新しい履歴を追加しません。';

  @override
  String get downloaderSettingsHint =>
      'ダウンロード状況は共有 DownloadManager がリアルタイムで管理します。';

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
  String downloadAuthorFailed(String error) {
    return '作品の列挙に失敗しました：$error';
  }

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
  String get add => '追加';

  @override
  String get viewerNoImages => '表示できる画像がありません';

  @override
  String get downloadAll => 'すべてダウンロード';

  @override
  String get downloadQueuedMessage => 'ダウンロードキューに追加しました';

  @override
  String downloadSubmissionFailed(String error) {
    return 'ダウンロードに失敗しました: $error';
  }

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
  String ugoiraSaveFailed(String error) {
    return 'GIFの保存に失敗しました: $error';
  }

  @override
  String ugoiraArchiveInvalid(String error) {
    return 'アニメーションのアーカイブが無効です: $error';
  }

  @override
  String ugoiraFrameCorrupt(String error) {
    return 'アニメーションフレームが壊れています: $error';
  }

  @override
  String ugoiraLoadFailed(String error) {
    return 'アニメーションを読み込めませんでした: $error';
  }

  @override
  String get homeRecommended => 'おすすめ';

  @override
  String get homeRanking => 'ランキング';

  @override
  String get homeMe => 'マイページ';

  @override
  String get homeExitHint => 'もう一度戻ると終了します';

  @override
  String get bookmarkIllust => 'イラストをブックマーク';

  @override
  String get bookmarkNovel => '小説をブックマーク';

  @override
  String bookmarkOperationFailed(String error) {
    return 'ブックマーク操作に失敗しました: $error';
  }

  @override
  String get save => '保存';

  @override
  String get saved => '保存しました';

  @override
  String get retry => '再試行';

  @override
  String get relatedWorks => '関連作品';

  @override
  String get cancel => 'キャンセル';

  @override
  String get confirm => '確認';

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
  String rankingLoadFailed(String mode) {
    return '$modeの読み込みに失敗しました';
  }

  @override
  String get rankingLoadMoreFailed => '追加コンテンツの読み込みに失敗しました';

  @override
  String get profileWork => '作品';

  @override
  String get profileBookmarked => 'ブックマーク';

  @override
  String get profileFollowing => 'フォロー';

  @override
  String get profileFans => 'フォロワー';

  @override
  String get profileMyPixiv => 'マイピク';

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
  String get searchReverseUnavailable => '画像検索は利用できません';

  @override
  String get searchReverseUnavailableDetail =>
      '認証情報、利用規約、プライバシー審査を通過した構造化サービスがないため、画像のアップロードやウェブページのスクレイピングは行いません。';

  @override
  String get searchReversePick => '画像を選択';

  @override
  String get searchReversePrivacy => 'プライバシーに関する注意';

  @override
  String get searchReversePrivacyDetail =>
      '検索を確認した後だけ画像を承認済みサービスへ送信し、キャンセルまたは失敗時に一時データを削除します。';

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
  String get searchReverseOpenExternal => 'ソースを開く';

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
    return '$engine が人による確認を求めています。今回の検索は完了していません。しばらくしてからお試しください';
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
  String get searchNoRepresentative => 'このタグには代表作品がありません';

  @override
  String get searchFilters => 'フィルター';

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
  String get searchContentAll => 'イラスト・マンガ・うごイラ';

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
  String get searchPopularPreviewHint => 'プレミアム未加入のため、人気順はプレビュー結果を使用します';

  @override
  String get searchNoSuggestions => '候補はありません';

  @override
  String get searchUserAccount => 'アカウント';

  @override
  String get illustDetailTitle => '作品詳細';

  @override
  String get illustDetailCreateDateUnknown => '投稿日不明';

  @override
  String illustDetailCreateDate(String date) {
    return '投稿日：$date';
  }

  @override
  String illustDetailSize(int width, int height) {
    return 'サイズ：${width}x$height';
  }

  @override
  String illustDetailOpenLinkFailed(String error) {
    return 'リンクを開けませんでした：$error';
  }

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
  String get newIllust => 'イラスト';

  @override
  String get newNovel => '小説';

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
  String get followUser => 'ユーザーをフォロー';

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
  String get aboutDisplayRefreshRate => '画面リフレッシュレート';

  @override
  String get cardActionBookmark => 'ブックマーク';

  @override
  String get cardActionUnbookmark => 'ブックマークを解除';

  @override
  String get cardActionDownload => 'ダウンロード';

  @override
  String get cardActionWatchLater => 'あとで見る';

  @override
  String get cardActionRemoveWatchLater => 'あとで見るから削除';

  @override
  String get cardActionShare => '共有';

  @override
  String get linkCopied => 'リンクをコピーしました';

  @override
  String get copyLink => 'リンクをコピー';

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
  String get bookmarkTagSuggestions => 'よく使うタグ';

  @override
  String get bookmarkTagsEmpty => 'ブックマークタグはまだありません';

  @override
  String get bookmarkTagsLoadFailed => 'ブックマークタグを読み込めませんでした';

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
  String localNovelsChars(int count) {
    return '$count 文字';
  }

  @override
  String get profileSeries => 'シリーズ';

  @override
  String get spotlightTitle => 'スポットライト';

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
}
