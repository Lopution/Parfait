// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Russian (`ru`).
class AppLocalizationsRu extends AppLocalizations {
  AppLocalizationsRu([String locale = 'ru']) : super(locale);

  @override
  String get networkDohEndpointsInvalid => 'Недопустимый список DoH-адресов';

  @override
  String get welcome1 => 'Спасибо за использование Pixiv Func';

  @override
  String get welcome2 => 'Начнется первоначальная настройка';

  @override
  String get start => 'Начать';

  @override
  String get selectLanguage => 'Выберите язык';

  @override
  String get selectTheme => 'Выберите свою любимую тему';

  @override
  String get next => 'Далее';

  @override
  String get later => 'Позже вы сможете изменить в настройках';

  @override
  String get dark => 'Тёмный';

  @override
  String get light => 'Светлый';

  @override
  String get system => 'Как в системе';

  @override
  String get loginTitle => 'Вход или Регистрация';

  @override
  String get loginProxyNoticeTitle => 'Внимание';

  @override
  String get loginProxyNoticeBody =>
      'Из-за ограничений сети перед входом или регистрацией включите системный или внешний прокси. Pixiv Func не содержит встроенного прокси.';

  @override
  String get loginProxyNoticeCancel => 'Отмена';

  @override
  String get loginProxyNoticeContinue => 'Прокси включён';

  @override
  String get register => 'Регистрация';

  @override
  String get login => 'Вход';

  @override
  String get loginPageClosed => 'Страница закрыта. Откройте её снова.';

  @override
  String loginCallbackInvalid(String reason) {
    return 'Недействительный callback входа: $reason';
  }

  @override
  String loginNetworkError(String status) {
    return 'Сетевая ошибка (HTTP $status)';
  }

  @override
  String loginPageLoadFailed(String error) {
    return 'Не удалось загрузить страницу ($error)';
  }

  @override
  String get loginWebView2Missing =>
      'Для входа требуется WebView2 Runtime, который не обнаружен в системе. Установите его и откройте страницу заново.';

  @override
  String get loginInstallWebView2 => 'Установить WebView2 Runtime';

  @override
  String get loginReload => 'Перезагрузить';

  @override
  String get loginRestart => 'Войти снова';

  @override
  String loginFailed(String error) {
    return 'Не удалось войти: $error';
  }

  @override
  String loginFailedType(String type) {
    return 'Не удалось войти ($type)';
  }

  @override
  String get networkCompatibility => 'Совместимость с официальной сетью Pixiv';

  @override
  String get networkCompatibilityHint =>
      'Сначала используется прямой HTTPS; только официальные адреса Pixiv могут попробовать строгий HTTPS-маршрут после явного сбоя транспорта. Другой трафик не проксируется, проверка сертификата не отключается.';

  @override
  String get getMoreHelp => 'Получить дополнительную помощь >>';

  @override
  String get useLoginWithClipboardHint =>
      'Или используйте длинное нажатие на аватаре,\\n чтобы скопировать данные аккаунта';

  @override
  String get useLoginWithClipboard => 'Войти с данными из буфера обмена';

  @override
  String get accountTransferExportTitle => 'Экспорт учётных данных аккаунта';

  @override
  String get accountTransferWarning =>
      'Буфер обмена хранится недолго и может быть прочитан другими приложениями; этот формат не обеспечивает шифрование или аутентификацию отправителя.';

  @override
  String get accountTransferSensitiveWarning =>
      'Это устройство не поддерживает пометку буфера как конфиденциального (только Android 13+): учётные данные попадут в системный буфер открытым текстом. Вставьте как можно скорее; очистка через 5 минут.';

  @override
  String get accountTransferCopied =>
      'Данные для переноса аккаунта скопированы. Скоро вставьте их на целевом устройстве.';

  @override
  String get accountTransferImported => 'Перенос аккаунта выполнен';

  @override
  String get accountTransferClipboardReplaced =>
      'Аккаунт импортирован; буфер обмена заменён, поэтому он не очищен.';

  @override
  String get accountTransferCorrupt =>
      'Данные аккаунта в буфере повреждены или не поддерживаются';

  @override
  String get accountTransferCredentialInvalid =>
      'Учетные данные аккаунта недействительны; войдите или скопируйте снова';

  @override
  String get accountTransferVerificationUnavailable =>
      'Проверка учетных данных Pixiv временно недоступна';

  @override
  String get accountTransferNoAccount =>
      'Нет вошедшего аккаунта для копирования';

  @override
  String get accountTransferCredentialUnavailable =>
      'Текущие учетные данные недоступны; войдите снова';

  @override
  String get accountTransferClipboardUnavailable => 'Буфер обмена недоступен';

  @override
  String get accountTransferStorageFailure =>
      'Запись переноса аккаунта не удалось безопасно сохранить';

  @override
  String get loginAgree => 'Входя в систему, вы принимаете';

  @override
  String get userAgreement => '《Пользовательское соглашение Pixiv Func》';

  @override
  String get agreementTitle => 'Пользовательское соглашение Pixiv Func';

  @override
  String get agreementIntro =>
      'Спасибо за использование Pixiv Func. Используя приложение, вы подтверждаете, что прочитали и приняли эти условия. Если вы не согласны, прекратите использование.';

  @override
  String get agreementAccountTitle => 'Аккаунт и авторизация';

  @override
  String get agreementAccountBody =>
      'Приложение использует официальный вход Pixiv и не просит вводить или передавать пароль Pixiv внутри приложения. Защищайте аккаунт и устройство; действия аккаунта и отзыв авторизации управляются в настройках Pixiv.';

  @override
  String get agreementContentTitle => 'Контент и авторские права';

  @override
  String get agreementContentBody =>
      'Иллюстрации, комментарии и профили предоставляются Pixiv и его пользователями, а права принадлежат соответствующим правообладателям. Просматривайте, сохраняйте и делитесь только в рамках закона и правил Pixiv.';

  @override
  String get agreementNetworkTitle => 'Сетевой доступ';

  @override
  String get agreementNetworkBody =>
      'Стратегия совместимости используется только для официальных адресов Pixiv. Другой трафик не проксируется, проверка сертификатов включена. Доступность сети, изменения API и сбои сервиса не гарантируются.';

  @override
  String get agreementPrivacyTitle => 'Конфиденциальность и локальные данные';

  @override
  String get agreementPrivacyBody =>
      'Учётные данные хранятся в защищённом хранилище системы; настройки, кэш, история и загрузки остаются локальными. Приложение не продаёт персональные данные. Удаление приложения или его данных может удалить локальное содержимое.';

  @override
  String get agreementDisclaimerTitle => 'Отказ от ответственности';

  @override
  String get agreementDisclaimerBody =>
      'Это неофициальный сторонний клиент, не связанный с Pixiv Inc. В пределах, разрешённых законом, автор не отвечает за потерю данных или сбои доступа из-за сети, аккаунта, сторонних сервисов или неподконтрольных событий.';

  @override
  String get agreementUpdates =>
      'Соглашение может обновляться из-за изменений продукта или закона. Продолжение использования означает принятие обновлённого соглашения.';

  @override
  String get settingsTitle => 'Настройки';

  @override
  String get settingsGroupAppearance => 'Внешний вид';

  @override
  String get settingsGroupNetwork => 'Сеть и загрузки';

  @override
  String get settingsGroupBrowse => 'Просмотр';

  @override
  String get settingsGroupLibrary => 'Моё';

  @override
  String get settingsGroupDeveloper => 'Разработчику';

  @override
  String get developerOptionsUnlocked => 'Режим разработчика включён';

  @override
  String developerOptionsCountdown(int count) {
    return 'Ещё $count нажатий до режима разработчика';
  }

  @override
  String get settingsGroupData => 'Данные';

  @override
  String get accountSettings => 'Аккаунт';

  @override
  String get networkSettings => 'Сеть';

  @override
  String get networkMode => 'Совместимость с официальной сетью Pixiv';

  @override
  String get networkModeHint =>
      'Если Pixiv не открывается — автоматически пробует совместимые каналы. Действует только на официальные домены Pixiv, другой трафик не проксируется.';

  @override
  String get networkModeListTitle => 'Режим сети';

  @override
  String get networkModeAutomatic => 'Авто';

  @override
  String get networkModeAutomaticHint =>
      'Автоматически выбирает рабочее подключение.';

  @override
  String get networkModeDirectOnly => 'Только прямое';

  @override
  String get networkModeDirectOnlyHint =>
      'Только прямое системное подключение; если прямой доступ работает.';

  @override
  String get networkModeCompatPrefer => 'Сначала совместимые маршруты';

  @override
  String get networkModeCompatPreferHint =>
      'Сначала совместимые каналы, прямое — как запасной вариант; если прямой доступ заблокирован.';

  @override
  String get networkEffectiveRoutes => 'Текущие маршруты';

  @override
  String get networkEffectiveRoutesEmpty =>
      'Маршрутов пока нет — поработайте в приложении и обновите.';

  @override
  String get networkRouteKindDirect => 'Напрямую';

  @override
  String get networkRouteKindCompat => 'Совместимый канал';

  @override
  String get networkThirdParty => 'Доступность сторонних сервисов';

  @override
  String get networkThirdPartyHint =>
      'Обычное системное подключение — ваш VPN/прокси применяется.';

  @override
  String get networkReachable => 'Доступно';

  @override
  String get networkUnreachable => 'Недоступно';

  @override
  String get networkChecking => 'Проверка…';

  @override
  String get networkAdvanced => 'Дополнительно';

  @override
  String get networkAdvancedHint =>
      'Низкоуровневые параметры для опытных пользователей.';

  @override
  String get networkAdvancedReset => 'Сбросить настройки';

  @override
  String get networkDoh => 'Использовать DoH для строгого резерва';

  @override
  String get networkDohHint =>
      'Включено: резервный уровень резолвит через DoH (по умолчанию Cloudflare DoH: доменные эндпоинты привязаны к статическим Anycast IP — никакого отравленного системного DNS; кастомные эндпоинты резолвят свои хосты); выключено — системный DNS.';

  @override
  String get networkDohEndpoints => 'DoH-эндпоинты (через запятую, https URL)';

  @override
  String get networkEchFrontHost => 'ECH-фронт-хост';

  @override
  String get networkEchFrontHostHint =>
      'Домен, у которого запрашивается HTTPS RR с ECH config (по умолчанию cloudflare-ech.com)';

  @override
  String get networkEchHostInvalid => 'Неверное имя фронт-хоста';

  @override
  String get networkProbe => 'Многоуровневый зонд связи';

  @override
  String get networkProbeTitle => 'Многоуровневый зонд связи';

  @override
  String get networkProbeHint =>
      'Поэтапная проверка связи с Pixiv для поиска причины сбоя.';

  @override
  String get frameProbeTitle => 'Зонд кадров';

  @override
  String get frameProbeHint =>
      'Записывает тайминги кадров во время прокрутки. Прокрутите с резкими свайпами, остановите и скопируйте отчёт. Только debug/profile-сборки.';

  @override
  String get frameProbeStart => 'Начать запись';

  @override
  String get frameProbeStop => 'Стоп';

  @override
  String get networkProbeRun => 'Запустить зонд';

  @override
  String get networkProbeRunning => 'Проверка…';

  @override
  String get networkProbeNotRun => 'Ещё не запущен';

  @override
  String get networkProbeHostFailed => 'Проверка хоста не удалась';

  @override
  String get networkProbeCopied => 'Отчёт скопирован';

  @override
  String get networkProbeDnsDiff =>
      'Дополнительно: системный DNS и DoH не имеют общих публичных адресов.';

  @override
  String get networkProbeStepSystemDns => 'Системный DNS';

  @override
  String get networkProbeStepDoh => 'DoH';

  @override
  String get networkProbeStepTcp => 'TCP';

  @override
  String get networkProbeStepTls => 'TLS';

  @override
  String get networkProbeStepHttp => 'Минимальный запрос';

  @override
  String get networkProbeStepEch => 'ECH';

  @override
  String get networkProbeStepNoSni => 'Пустой SNI';

  @override
  String get networkProbeStepOk => 'Успешно';

  @override
  String get networkProbeStepFailed => 'Ошибка';

  @override
  String get networkProbeStepSkipped => 'Пропущено';

  @override
  String get networkProbeConclusionAllReachable => 'Доступен';

  @override
  String get networkProbeConclusionDnsPolluted => 'Загрязнение DNS';

  @override
  String get networkProbeConclusionSniBlocked => 'SNI заблокирован';

  @override
  String get networkProbeConclusionEchAvailable => 'Используйте ECH';

  @override
  String get networkProbeConclusionNoSniAvailable => 'Используйте пустой SNI';

  @override
  String get networkProbeConclusionIpBlackholed => 'IP недоступен';

  @override
  String get networkProbeConclusionAppLayer => 'Прикладной уровень';

  @override
  String get networkProbeConclusionInconclusive => 'Неопределённо';

  @override
  String get copy => 'Копировать';

  @override
  String get themeSettings => 'Тема';

  @override
  String get languageSettings => 'Язык';

  @override
  String get translateSettings => 'Перевод';

  @override
  String get browseSettings => 'Настройки просмотра';

  @override
  String get downloadSettings => 'Настройки загрузки';

  @override
  String get historySettings => 'История';

  @override
  String get historyView => 'Открыть историю просмотров';

  @override
  String get historyEmpty => 'История просмотров пуста';

  @override
  String get historyLoadFailed => 'Не удалось загрузить историю';

  @override
  String get historyDelete => 'Удалить историю';

  @override
  String get historyDeleteAll => 'Удалить всю историю';

  @override
  String get historyDeleteHint => 'Удалённую историю нельзя восстановить.';

  @override
  String get downloaderSettings => 'Задачи загрузки';

  @override
  String get aboutSettings => 'О приложении';

  @override
  String get signedOut => 'Не выполнен вход';

  @override
  String get currentAccount => 'Текущий аккаунт';

  @override
  String get accountId => 'ID аккаунта';

  @override
  String get reauthRequired => 'Требуется повторный вход';

  @override
  String get accountProfile => 'Профиль';

  @override
  String get accountReadFailed => 'Не удалось прочитать состояние аккаунта';

  @override
  String get dismiss => 'Понятно';

  @override
  String get profileEditTitle => 'Редактировать профиль';

  @override
  String get profileEditLoadFailed => 'Не удалось загрузить профиль';

  @override
  String get profileEditUnavailable =>
      'Нет доступного канала редактирования в приложении.';

  @override
  String get profileEditPending =>
      'Изменения отправлены и ожидают подтверждения.';

  @override
  String get profileEditConfirmed => 'Профиль подтверждён и синхронизирован.';

  @override
  String get profileEditDisplayName => 'Имя';

  @override
  String get profileEditComment => 'О себе';

  @override
  String get profileEditWebpage => 'Веб-страница';

  @override
  String get profileEditAvatar => 'Аватар';

  @override
  String get profileEditBackground => 'Фоновое изображение';

  @override
  String get profileEditCurrentPassword => 'Текущий пароль';

  @override
  String get profileEditFieldUnsupported =>
      'Этот канал не поддерживает данное поле';

  @override
  String get profileEditImageChoose => 'Выберите поддерживаемое изображение';

  @override
  String get profileEditChooseImage => 'Выбрать изображение';

  @override
  String get profileEditSave => 'Сохранить профиль';

  @override
  String get profileEditLeaveTitle => 'Отменить несохранённые изменения?';

  @override
  String get profileEditLeaveDetail =>
      'Изменения ещё не отправлены и будут потеряны.';

  @override
  String get profileEditLeaveConfirm => 'Отменить изменения';

  @override
  String get accountManagement => 'Управление аккаунтами';

  @override
  String get addAccount => 'Добавить аккаунт';

  @override
  String get switchAccount => 'Сменить аккаунт';

  @override
  String get removeAccount => 'Удалить аккаунт';

  @override
  String get removeAccountConfirm => 'Удалить этот аккаунт?';

  @override
  String get noAccounts => 'Нет аккаунтов';

  @override
  String get profileReadOnly =>
      'Здесь показаны сохранённые данные аккаунта. Полное редактирование профиля предоставляет модуль профиля.';

  @override
  String get serverDisplaySettings => 'Настройки показа аккаунта';

  @override
  String get serverDisplayHint =>
      'Хранится на сервере Pixiv и влияет на то, что API возвращает этому аккаунту.';

  @override
  String get serverShowAi => 'Показывать AI-работы';

  @override
  String get serverRestrictedMode => 'Ограниченный режим';

  @override
  String get serverDisplayLoadFailed =>
      'Не удалось загрузить серверные настройки';

  @override
  String get serverDisplayWriteFailed =>
      'Не удалось сохранить настройку на сервере';

  @override
  String get backupSettings => 'Резервная копия';

  @override
  String get backupHint =>
      'Экспорт настроек, списка скрытого и истории просмотра; учётные данные в файл не записываются.';

  @override
  String get backupExport => 'Экспортировать копию';

  @override
  String get backupExportHint =>
      'Сохраняет pixiv-func-backup-*.json в выбранную папку';

  @override
  String backupExported(String name) {
    return 'Сохранено: $name';
  }

  @override
  String get backupExportFailed => 'Не удалось экспортировать';

  @override
  String get backupImport => 'Импортировать копию';

  @override
  String get backupImportHint => 'Импорт из JSON-файла; слияние или замена';

  @override
  String get backupImportInvalid => 'Недействительный файл резервной копии';

  @override
  String get backupImportFailed => 'Не удалось импортировать';

  @override
  String get backupImportStrategyTitle => 'Способ импорта';

  @override
  String backupImportPrompt(
    int tags,
    int users,
    int works,
    int history,
    String account,
  ) {
    return 'В файле: скрытых тегов $tags, пользователей $users, скрытых работ $works, записей истории $history.\nЭкспортировано аккаунтом: $account';
  }

  @override
  String get backupImportOverwriteNote =>
      'Замена сначала очищает локальную историю и заменяет скрытые работы; серверный список скрытого только пополняется и импортом не удаляется.';

  @override
  String get backupMerge => 'Объединить';

  @override
  String get backupOverwrite => 'Заменить';

  @override
  String backupImportDone(int tags, int users, int works, int history) {
    return 'Импортировано: теги +$tags, пользователи +$users, изменений скрытых работ: $works, история: $history';
  }

  @override
  String get imageSource => 'Источник изображений';

  @override
  String get imageSourceNormal => 'Официальный (по умолчанию)';

  @override
  String get imageSourcePixivCat => 'зеркало pixiv.cat';

  @override
  String get imageSourcePixivRe => 'зеркало pixiv.re';

  @override
  String get imageSourcePixivNl => 'зеркало pixiv.nl';

  @override
  String get imageSourceCustom => 'Свой обратный прокси';

  @override
  String get imageSourceCustomHint =>
      'https://host[/path], например https://i.pixiv.cat';

  @override
  String get imageSourceCustomUnset => 'Не настроено';

  @override
  String get imageSourceCustomInvalid =>
      'Недопустимый источник: нужны https, DNS-имя и порт 443';

  @override
  String get imageSourceApplyAndTest => 'Применить и проверить';

  @override
  String imageSourceTestOk(String code) {
    return 'Зеркало доступно (HTTP $code)';
  }

  @override
  String get imageSourceTestFailed => 'Проверка зеркала не удалась';

  @override
  String get imageSourceUnreachableMainland =>
      'Обычно недоступно из сетей материкового Китая';

  @override
  String get imageSourceAuto => 'Авто (выбор зеркала для этой сети)';

  @override
  String imageSourceAutoWinner(String host) {
    return 'Текущее: $host';
  }

  @override
  String get imageSourceAutoPending => 'Ещё не измерено — прямая загрузка';

  @override
  String get previewQuality => 'Качество предпросмотра';

  @override
  String get viewQuality => 'Качество просмотра';

  @override
  String get detailQuality => 'Качество картинки в детальной странице';

  @override
  String get qualityMedium => 'Среднее';

  @override
  String get qualityLarge => 'Большое';

  @override
  String get qualityOriginal => 'Оригинал';

  @override
  String get scaleQuality => 'Качество просмотра (оригинал)';

  @override
  String get localHistory => 'Локальная история просмотров';

  @override
  String get pixivHistory => 'История просмотров Pixiv';

  @override
  String get blockR18 => 'Локально скрывать работы R-18';

  @override
  String get blockAI => 'Локально скрывать работы AI';

  @override
  String get hideMuted => 'Скрывать заглушенные работы';

  @override
  String get hideMutedHint =>
      'Если выключено, заглушенные работы показываются размытыми карточками; нажатие временно показывает их';

  @override
  String get mutedContent => 'Заглушено';

  @override
  String get mutedItemsSettings => 'Заглушенные';

  @override
  String get mutedTagsSection => 'Теги';

  @override
  String get mutedUsersSection => 'Пользователи';

  @override
  String get mutedWorksSection => 'Работы';

  @override
  String get mutedEmpty => 'Ничего не заглушено';

  @override
  String get muteTagInputHint => 'Тег для заглушения';

  @override
  String get muteWork => 'Заглушить работу';

  @override
  String get unmuteWork => 'Снять заглушение работы';

  @override
  String get muteAuthor => 'Заглушить автора';

  @override
  String get unmuteAuthor => 'Снять заглушение автора';

  @override
  String get unmuteTag => 'Снять заглушение';

  @override
  String muteFailed(Object error) {
    return 'Ошибка заглушения: $error';
  }

  @override
  String get reduceMotion => 'Меньше анимаций';

  @override
  String get reduceMotionHint =>
      'Отключить декоративную анимацию: переходы страниц, появление списков и отклик на нажатие';

  @override
  String get maxDownloadCount => 'Максимум параллельных загрузок';

  @override
  String get namingRule => 'Правило имени файла';

  @override
  String get namingRuleHint => 'Пусто — использовать имя по умолчанию';

  @override
  String get saveFolder => 'Папка сохранения';

  @override
  String get saveLocation => 'Место сохранения';

  @override
  String get saveLocationAlbum => 'Альбом';

  @override
  String get saveLocationPixivAlbum => 'Альбом PixivFunc (по умолчанию)';

  @override
  String get saveLocationCustomAlbum => 'Имя пользовательского альбома';

  @override
  String get saveLocationCustomAlbumHint =>
      'Только буквы, цифры, кириллица и _';

  @override
  String get saveLocationUseCustomAlbum => 'Использовать альбом';

  @override
  String get saveLocationAlbumInvalid => 'Недопустимое имя альбома';

  @override
  String get saveLocationSafFolder => 'Папка (системный выбор каталога)';

  @override
  String get saveLocationSafFolderHint =>
      'Выбор каталога через системный SAF с сохранением прав';

  @override
  String get saveLocationSafPicked => 'Папка выбрана';

  @override
  String get namingPreset => 'Пресет имени файла';

  @override
  String get namingPresetId => 'ID работы (по умолчанию)';

  @override
  String get namingPresetArtistTitleId => 'Автор - название - ID';

  @override
  String get namingPresetTitleId => 'Название - ID';

  @override
  String get namingPresetCustom => 'Пользовательский шаблон';

  @override
  String get namingTemplate => 'Шаблон имени';

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
  String get namingTemplateInvalid =>
      'Шаблон содержит недопустимые переменные или символы';

  @override
  String get namingPreview => 'Предпросмотр';

  @override
  String namingTemplateVariables(String variables) {
    return 'Переменные: $variables; недопустимые символы заменяются на _, длинные имена обрезаются.';
  }

  @override
  String get notConfigured => 'Не настроено';

  @override
  String get translateProvider => 'Сервис перевода';

  @override
  String get translateGoogle => 'Google Translate';

  @override
  String get translateDisabled => 'Отключено';

  @override
  String get translateBaidu => 'Baidu Translate';

  @override
  String get translateLlm => 'Свой LLM (OpenAI-совместимый)';

  @override
  String get translateBaiduCredential => 'AppID / секрет Baidu';

  @override
  String get translateLlmCredential => 'Адрес LLM и ключ';

  @override
  String get translateBaiduAppId => 'AppID';

  @override
  String get translateBaiduSecret => 'Секрет';

  @override
  String get translateLlmBaseUrl => 'Базовый URL (HTTPS)';

  @override
  String get translateLlmApiKey => 'API-ключ';

  @override
  String get translateLlmModel => 'Модель (необязательно)';

  @override
  String get translateCredentialsSave => 'Сохранить в защищённое хранилище';

  @override
  String get translateCredentialsClear => 'Очистить учётные данные';

  @override
  String get translateCredentialsSaved => 'Сохранено в защищённое хранилище';

  @override
  String get translateCredentialsCleared => 'Учётные данные очищены';

  @override
  String get translateCredentialsStoreError => 'Ошибка защищённого хранилища';

  @override
  String get translateCredentialsInvalid => 'Неполный ввод или адрес не HTTPS';

  @override
  String get translateBaiduHint =>
      'Стандартная версия Baidu не требует верификации, но даёт лишь 50 тыс. символов/мес при 1 запросе/с — для комментариев этого мало; премиум требует личную верификацию (имя + номер удостоверения): 1 млн символов/мес, 10 запросов/с. Учётные данные используются только для запросов перевода.';

  @override
  String get translateLlmCredentialHint =>
      'Только HTTPS; перевод использует фиксированный промпт без настроек модели. Текст и перевод не сохраняются.';

  @override
  String get translateCredentialHint =>
      'Данные перевода не записываются в обычные настройки; при необходимости они хранятся в защищённом хранилище.';

  @override
  String get historySettingsHint =>
      'Модуль истории читает эти переключатели; отключённая история не получает новые записи.';

  @override
  String get downloaderSettingsHint =>
      'Задачи загрузки в реальном времени ведёт общий DownloadManager.';

  @override
  String get downloadTasksEmpty => 'Нет задач загрузки';

  @override
  String get downloadQueued => 'В очереди';

  @override
  String get downloadRunning => 'Загрузка';

  @override
  String get downloadCanceling => 'Отмена';

  @override
  String get downloadSucceeded => 'Готово';

  @override
  String get downloadFailed => 'Ошибка';

  @override
  String get downloadCanceled => 'Отменено';

  @override
  String get retryDownload => 'Повторить';

  @override
  String get cancelDownload => 'Отмена';

  @override
  String get downloadPaused => 'Приостановлено';

  @override
  String get pauseDownload => 'Пауза';

  @override
  String get resumeDownload => 'Возобновить';

  @override
  String downloadGroupTitle(int count) {
    return 'Пакетная загрузка · $count шт.';
  }

  @override
  String downloadGroupProgress(int done, int count) {
    return 'Готово $done/$count';
  }

  @override
  String get downloadAuthorWorks => 'Скачать все работы';

  @override
  String get downloadAuthorWorksTitle => 'Скачать все работы автора';

  @override
  String downloadAuthorEnumerating(int count) {
    return 'Перечисление работ… найдено $count';
  }

  @override
  String downloadAuthorConfirmBody(int works, int pages) {
    return 'Будет скачано $works работ ($pages стр.) этого автора.';
  }

  @override
  String downloadAuthorTruncated(int max) {
    return 'Слишком много работ — будут скачаны только первые $max.';
  }

  @override
  String get downloadAuthorEmpty => 'У этого автора нет работ для скачивания.';

  @override
  String downloadAuthorFailed(String error) {
    return 'Не удалось перечислить работы: $error';
  }

  @override
  String get downloadCaption => 'Экспортировать описание работы';

  @override
  String get downloadCaptionHint =>
      'При скачивании иллюстраций и манги сохранять название, автора и описание в одноимённый .txt';

  @override
  String get aboutVersion => 'Версия';

  @override
  String get aboutCheckUpdate => 'Проверить обновления';

  @override
  String get aboutCheckingUpdate => 'Проверка обновлений…';

  @override
  String get aboutUpdateAvailable => 'Доступно обновление';

  @override
  String get aboutUpdateOpen => 'Открыть';

  @override
  String get aboutExportLogs => 'Экспорт логов';

  @override
  String get aboutNoLogs => 'Логов пока нет';

  @override
  String get aboutUpdateNoUpdate => 'Установлена последняя версия';

  @override
  String get aboutUpdatePrerelease =>
      'Доступен предварительный выпуск; стабильный канал его не установит';

  @override
  String get aboutUpdateDownload => 'Скачать и установить';

  @override
  String get aboutUpdateDownloading => 'Загрузка и проверка…';

  @override
  String get aboutUpdateConfirmTitle => 'Подтвердить обновление';

  @override
  String get aboutUpdateConfirmDetail =>
      'Будет установлено только APK, прошедшее проверку подписи, размера, хэша, пакета и сертификата. Продолжить?';

  @override
  String get aboutUpdatePermission =>
      'Разрешите этому источнику устанавливать приложения и снова подтвердите установку.';

  @override
  String get aboutUpdateStarted => 'Системный установщик открыт';

  @override
  String get aboutUpdateStore => 'Обновления этой сборки управляются F-Droid.';

  @override
  String get aboutUpdateUnavailable => 'Проверка обновлений сейчас недоступна';

  @override
  String get aboutUpdateFailed =>
      'Не удалось проверить или установить обновление. Повторите позже.';

  @override
  String get aboutLicense => 'Лицензия';

  @override
  String get aboutAttribution => 'Атрибуция';

  @override
  String get aboutSource => 'Исходный код';

  @override
  String get aboutLicenseText =>
      'Проект основан на открытом исходном коде Pixiv Func и распространяется по GNU AGPL v3.0.';

  @override
  String get aboutAttributionText =>
      'Авторские права и сопровождение: Lopution.';

  @override
  String get settingsReadFailed => 'Не удалось прочитать настройки';

  @override
  String get settingsWriteFailed => 'Не удалось сохранить настройки';

  @override
  String get add => 'Добавить';

  @override
  String get viewerNoImages => 'Нет изображений для отображения';

  @override
  String get downloadAll => 'Скачать всё';

  @override
  String get downloadQueuedMessage => 'Добавлено в очередь загрузки';

  @override
  String downloadSubmissionFailed(String error) {
    return 'Не удалось скачать: $error';
  }

  @override
  String get ugoiraSaveGif => 'Сохранить GIF';

  @override
  String get ugoiraLoadCanceled => 'Загрузка отменена';

  @override
  String get ugoiraLoginRequired => 'Войдите, чтобы сохранить GIF';

  @override
  String get ugoiraSaved => 'GIF сохранён';

  @override
  String get ugoiraSaveCanceled => 'Сохранение GIF отменено';

  @override
  String ugoiraSaveFailed(String error) {
    return 'Не удалось сохранить GIF: $error';
  }

  @override
  String ugoiraArchiveInvalid(String error) {
    return 'Архив анимации недействителен: $error';
  }

  @override
  String ugoiraFrameCorrupt(String error) {
    return 'Кадр анимации повреждён: $error';
  }

  @override
  String ugoiraLoadFailed(String error) {
    return 'Не удалось загрузить анимацию: $error';
  }

  @override
  String get homeRecommended => 'Рекомендации';

  @override
  String get homeRanking => 'Рейтинг';

  @override
  String get homeMe => 'Профиль';

  @override
  String get homeExitHint => 'Нажмите ещё раз, чтобы выйти';

  @override
  String get bookmarkIllust => 'Добавить иллюстрацию в закладки';

  @override
  String get bookmarkNovel => 'Добавить новеллу в закладки';

  @override
  String bookmarkOperationFailed(String error) {
    return 'Не удалось изменить закладки: $error';
  }

  @override
  String get save => 'Сохранить';

  @override
  String get saved => 'Сохранено';

  @override
  String get retry => 'Повторить';

  @override
  String get refresh => 'Обновить';

  @override
  String get relatedWorks => 'Похожие работы';

  @override
  String get cancel => 'Отмена';

  @override
  String get confirm => 'Подтвердить';

  @override
  String get rankingDay => 'Ежедневно';

  @override
  String get rankingDayR18 => 'Ежедневно (R-18)';

  @override
  String get rankingDayMale => 'Ежедневно (Мужчины)';

  @override
  String get rankingDayMaleR18 => 'Ежедневно (Мужчины & R-18)';

  @override
  String get rankingDayFemale => 'Ежедневно (Женщины)';

  @override
  String get rankingDayFemaleR18 => 'Ежедневно (Женщины & R-18)';

  @override
  String get rankingWeek => 'Еженедельно';

  @override
  String get rankingWeekR18 => 'Еженедельно (R-18)';

  @override
  String get rankingWeekOriginal => 'Еженедельно (Оригинальное)';

  @override
  String get rankingWeekRookie => 'Еженедельно (Дебют)';

  @override
  String get rankingWeekAi => 'Еженедельно (AI)';

  @override
  String get rankingWeekAiR18 => 'Еженедельно (AI и R-18)';

  @override
  String get rankingWeekR18G => 'Еженедельно (R-18G)';

  @override
  String get rankingMonth => 'Ежемесячно';

  @override
  String get rankingEmpty => 'Нет содержимого рейтинга';

  @override
  String rankingLoadFailed(String mode) {
    return 'Не удалось загрузить: $mode';
  }

  @override
  String get rankingLoadMoreFailed => 'Не удалось загрузить ещё';

  @override
  String get profileWork => 'Работы';

  @override
  String get profileBookmarked => 'Закладки';

  @override
  String get profileFollowing => 'Подписки';

  @override
  String get profileFans => 'Подписчики';

  @override
  String get profileMyPixiv => 'Мои Pixiv';

  @override
  String get profileAbout => 'О пользователе';

  @override
  String get profileIllust => 'Иллюстрации';

  @override
  String get profileManga => 'Манга';

  @override
  String get profileNovel => 'Романы';

  @override
  String get searchTitle => 'Поиск';

  @override
  String get searchHint => 'Работы, пользователи или теги';

  @override
  String get searchReverseImage => 'Поиск по изображению';

  @override
  String get searchTrending => 'Популярные теги';

  @override
  String get searchNoTrending => 'Нет популярных тегов';

  @override
  String get searchTrendingFailed => 'Не удалось загрузить популярные теги';

  @override
  String get searchIllustManga => 'Иллюстрации и манга';

  @override
  String get searchNovel => 'Романы';

  @override
  String get searchUser => 'Пользователи';

  @override
  String get searchCancel => 'Отмена';

  @override
  String get searchSubmit => 'Поиск';

  @override
  String get searchClear => 'Очистить';

  @override
  String get searchLoading => 'Поиск';

  @override
  String get searchNoResults => 'Нет результатов поиска';

  @override
  String get searchLoadFailed => 'Поиск не удался';

  @override
  String get searchLoadMoreFailed => 'Не удалось загрузить ещё результаты';

  @override
  String get searchRetry => 'Повторить';

  @override
  String get searchRefreshFailed => 'Не удалось обновить';

  @override
  String get searchInputEmpty => 'Введите запрос';

  @override
  String get searchReverseUnavailable => 'Поиск по изображению недоступен';

  @override
  String get searchReverseUnavailableDetail =>
      'Нет структурированного сервиса, прошедшего проверку учётных данных, условий и приватности; изображение не загружается и не обрабатывается через скрейпинг.';

  @override
  String get searchReversePick => 'Выбрать изображение';

  @override
  String get searchReversePrivacy => 'Уведомление о приватности';

  @override
  String get searchReversePrivacyDetail =>
      'Изображение отправляется одобренному сервису только после подтверждения, а временные данные удаляются после отмены или ошибки.';

  @override
  String get searchReversePreparing => 'Подготовка изображения…';

  @override
  String get searchReverseSearching => 'Поиск…';

  @override
  String get searchReverseCancel => 'Отмена';

  @override
  String get searchReverseUse => 'Начать поиск по изображению';

  @override
  String get searchReverseRetry => 'Выбрать другое изображение';

  @override
  String get searchReverseReady => 'Изображение готово';

  @override
  String get searchReverseNoResults => 'Совпадений не найдено';

  @override
  String get searchReverseIntentFailed =>
      'Общее изображение нельзя использовать';

  @override
  String get searchReverseOpenExternal => 'Открыть источник';

  @override
  String get searchReverseOpenFailed => 'Не удалось открыть ссылку источника';

  @override
  String get searchReverseRateLimited =>
      'Слишком много запросов, попробуйте позже';

  @override
  String searchReverseRateLimitedWait(int seconds) {
    return 'Повторите попытку примерно через $seconds с';
  }

  @override
  String get searchReverseDailyLimit =>
      'Дневной лимит анонимного поиска исчерпан. Попробуйте завтра.';

  @override
  String searchReverseChallenge(String engine) {
    return '$engine требует проверку человека. Этот поиск не завершён. Попробуйте позже.';
  }

  @override
  String get searchReversePageLoadFailed =>
      'Не удалось загрузить страницу результатов';

  @override
  String get searchReverseUploadTapHint =>
      'Нажмите кнопку загрузки на странице, чтобы начать поиск — выбранное изображение подставится автоматически.';

  @override
  String get searchReverseUploadPickHint =>
      'Выберите то же изображение ещё раз в диалоге выбора файла на странице.';

  @override
  String get searchReverseRetrySameEngine => 'Повторить в этом движке';

  @override
  String get searchReverseEngineUnsupported =>
      'Выбранное изображение не соответствует ограничениям этого движка';

  @override
  String get searchReverseIntro =>
      'Выбранное изображение отправляется в выбранный движок; страница результатов открывается в приложении.';

  @override
  String get searchReverseFailed => 'Ошибка поиска';

  @override
  String get searchReverseDone => 'Готово';

  @override
  String searchReverseResultCount(int count) {
    return 'Результатов: $count';
  }

  @override
  String get searchReverseEngineSwitch => 'Сменить сервис';

  @override
  String get searchNoRepresentative =>
      'У этого тега нет представительной работы';

  @override
  String get searchFilters => 'Фильтры';

  @override
  String get searchReset => 'Сбросить';

  @override
  String get searchApply => 'Применить';

  @override
  String get searchTarget => 'Область поиска';

  @override
  String get searchPartialTags => 'Частичное совпадение тегов';

  @override
  String get searchExactTags => 'Точное совпадение тегов';

  @override
  String get searchTitleCaption => 'Название и описание';

  @override
  String get searchSort => 'Сортировка';

  @override
  String get searchDateDesc => 'Сначала новые';

  @override
  String get searchDateAsc => 'Сначала старые';

  @override
  String get searchPopularDesc => 'Популярные';

  @override
  String get searchPopularMaleDesc => 'Популярное (муж.)';

  @override
  String get searchPopularFemaleDesc => 'Популярное (жен.)';

  @override
  String get searchAiSection => 'AI-работы';

  @override
  String get searchAiAll => 'Все';

  @override
  String get searchAiExclude => 'Скрыть AI';

  @override
  String get searchAiOnly => 'Только AI';

  @override
  String get searchBookmarkSection => 'Закладки';

  @override
  String get searchMin => 'Мин.';

  @override
  String get searchMax => 'Макс.';

  @override
  String get searchRatioSection => 'Формат';

  @override
  String get searchRatioAny => 'Любая';

  @override
  String get searchRatioLandscape => 'Альбомная';

  @override
  String get searchRatioPortrait => 'Портретная';

  @override
  String get searchRatioSquare => 'Квадрат';

  @override
  String get searchContentSection => 'Тип работ';

  @override
  String get searchContentAll => 'Илл.+манга+угоира';

  @override
  String get searchContentIllustUgoira => 'Илл.+угоира';

  @override
  String get searchContentIllust => 'Только иллюстр.';

  @override
  String get searchContentUgoira => 'Только угоира';

  @override
  String get searchContentManga => 'Только манга';

  @override
  String get searchResolutionSection => 'Разрешение';

  @override
  String get searchWidth => 'Ширина';

  @override
  String get searchHeight => 'Высота';

  @override
  String get searchDuration => 'Дата публикации';

  @override
  String get searchAllTime => 'Любое время';

  @override
  String get searchWithinDay => 'За день';

  @override
  String get searchWithinWeek => 'За неделю';

  @override
  String get searchWithinMonth => 'За месяц';

  @override
  String get searchStartDate => 'Дата начала';

  @override
  String get searchEndDate => 'Дата окончания';

  @override
  String get searchInvalidDateRange =>
      'Дата начала не может быть позже даты окончания';

  @override
  String get searchPopularPreviewHint =>
      'Без Premium сортировка по популярности использует предпросмотр';

  @override
  String get searchNoSuggestions => 'Нет подходящих вариантов';

  @override
  String get searchSuggestionFill => 'Подставить в строку поиска';

  @override
  String get searchSuggestionSearch => 'Искать сразу';

  @override
  String get searchModifyQuery => 'Изменить запрос';

  @override
  String get searchUserAccount => 'Аккаунт';

  @override
  String get illustDetailTitle => 'Работа';

  @override
  String get illustDetailCreateDateUnknown => 'Дата публикации неизвестна';

  @override
  String illustDetailCreateDate(String date) {
    return 'Опубликовано: $date';
  }

  @override
  String illustDetailSize(int width, int height) {
    return 'Размер: ${width}x$height';
  }

  @override
  String illustDetailOpenLinkFailed(String error) {
    return 'Не удалось открыть ссылку: $error';
  }

  @override
  String illustDetailRestricted(int id) {
    return 'Работа удалена или ограничена (ID: $id)';
  }

  @override
  String get illustDetailNotFound => 'Работа не существует или была удалена';

  @override
  String get illustDetailLoadFailed => 'Не удалось загрузить работу';

  @override
  String get commentTitle => 'Комментарии';

  @override
  String get commentInput => 'Добавить комментарий';

  @override
  String get commentReply => 'Ответить';

  @override
  String get commentReplyTo => 'Ответить пользователю';

  @override
  String get commentCancelReply => 'Отменить ответ';

  @override
  String get commentSend => 'Отправить';

  @override
  String get commentDelete => 'Удалить комментарий';

  @override
  String get commentDeleteConfirm => 'Удалить этот комментарий?';

  @override
  String get commentDeleteFailed => 'Не удалось удалить комментарий';

  @override
  String get commentSendFailed => 'Не удалось отправить комментарий';

  @override
  String get commentLoadFailed => 'Не удалось загрузить комментарии';

  @override
  String get relatedLoadFailed => 'Не удалось загрузить похожие работы';

  @override
  String get commentLoadMoreFailed => 'Не удалось загрузить ещё комментарии';

  @override
  String get commentNoResults => 'Комментариев нет';

  @override
  String get commentReplies => 'Ответы';

  @override
  String get commentTranslate => 'Перевести';

  @override
  String get commentTranslation => 'Перевод';

  @override
  String get commentTranslationUnavailable =>
      'Перевод недоступен. Включите его в настройках.';

  @override
  String get commentTranslationFailed => 'Перевод не удался';

  @override
  String get commentTranslationInvalidCredentials =>
      'Учётные данные перевода недействительны; проверьте настройки';

  @override
  String get commentTranslationRateLimited =>
      'Слишком много переводов или исчерпана квота';

  @override
  String get commentEmoji => 'Emoji';

  @override
  String get commentStamps => 'Stamps';

  @override
  String get commentPermissionDenied => 'Можно удалять только свои комментарии';

  @override
  String get newTitle => 'Новинки';

  @override
  String get newFollowing => 'Подписки';

  @override
  String get newEveryone => 'Все';

  @override
  String get newMyPixiv => 'Мои Pixiv';

  @override
  String get newIllust => 'Иллюстрации';

  @override
  String get newNovel => 'Новеллы';

  @override
  String get recommendedIllust => 'Иллюстрации';

  @override
  String get recommendedManga => 'Манга';

  @override
  String get recommendedNovel => 'Новеллы';

  @override
  String get recommendedUser => 'Пользователи';

  @override
  String get recommendedEmpty => 'Нет рекомендаций';

  @override
  String get recommendedLoadFailed => 'Не удалось загрузить рекомендации';

  @override
  String get recommendedLoadMoreFailed => 'Не удалось загрузить ещё';

  @override
  String get recommendedEnd => 'Больше нет';

  @override
  String get newLoading => 'Загрузка новинок';

  @override
  String get newEmpty => 'Нет содержимого';

  @override
  String get newLoadFailed => 'Не удалось загрузить новинки';

  @override
  String get newLoadMoreFailed => 'Не удалось загрузить ещё';

  @override
  String get newRetry => 'Повторить';

  @override
  String get newRefreshFailed => 'Не удалось обновить';

  @override
  String get recommendedRefreshFailed => 'Не удалось обновить';

  @override
  String get profileId => 'ID пользователя';

  @override
  String get profileAccount => 'Аккаунт';

  @override
  String get profileIntroduction => 'Описание';

  @override
  String get profileBirthday => 'День рождения';

  @override
  String get profileGender => 'Пол';

  @override
  String get profileRegion => 'Регион';

  @override
  String get profileJob => 'Профессия';

  @override
  String get profileWebsite => 'Сайт';

  @override
  String get profileWorkspace => 'Рабочее место';

  @override
  String get profileStats => 'Статистика';

  @override
  String get profileLoading => 'Загрузка профиля пользователя';

  @override
  String get profileNotFound => 'Пользователь не существует или удалён';

  @override
  String get profileBlocked => 'Профиль пользователя недоступен';

  @override
  String get profileLoadFailed => 'Не удалось загрузить профиль';

  @override
  String get profileItemsEmpty => 'Нет содержимого';

  @override
  String get profileLoadMoreFailed => 'Не удалось загрузить ещё';

  @override
  String get profileRetry => 'Повторить';

  @override
  String get profileNovelPending =>
      'Списки романов подключит модуль Novel Reader';

  @override
  String get profileShare => 'Поделиться пользователем';

  @override
  String get profileShareHint => 'Можно поделиться ссылкой на пользователя';

  @override
  String get profileShareClose => 'Закрыть';

  @override
  String get profileSettings => 'Настройки';

  @override
  String get restrictSelector => 'Выбрать видимость';

  @override
  String get restrictPublic => 'Открытый';

  @override
  String get restrictPrivate => 'Приватный';

  @override
  String get follow => 'Подписаться';

  @override
  String get followed => 'Вы подписаны';

  @override
  String get followUser => 'Подписаться на пользователя';

  @override
  String get followFailed => 'Не удалось изменить подписку';

  @override
  String get userPreviewFollow => 'Подписаться';

  @override
  String get novelLoading => 'Загрузка новеллы';

  @override
  String get novelNotFound => 'Новелла не существует или удалена';

  @override
  String get novelRestricted => 'Новелла ограничена';

  @override
  String get novelContentUnavailable => 'Текущий API не вернул текст новеллы';

  @override
  String get novelLoadFailed => 'Не удалось загрузить новеллу';

  @override
  String get novelRetry => 'Повторить';

  @override
  String get novelNoContent => 'Нет текста';

  @override
  String get novelWords => 'слов';

  @override
  String get novelSeries => 'Серия';

  @override
  String get novelRanking => 'Рейтинг новелл';

  @override
  String get novelSeriesUnavailable => 'Информация о серии недоступна';

  @override
  String get novelInfoTitle => 'О произведении';

  @override
  String get novelPrevious => 'Предыдущая новелла';

  @override
  String get novelNext => 'Следующая новелла';

  @override
  String get novelDecreaseFont => 'Уменьшить шрифт';

  @override
  String get novelIncreaseFont => 'Увеличить шрифт';

  @override
  String get novelReadingProgress => 'Прогресс чтения';

  @override
  String get novelReaderSettings => 'Настройки чтения';

  @override
  String get novelFontSize => 'Размер шрифта';

  @override
  String get novelLineHeight => 'Межстрочный интервал';

  @override
  String get novelThemeSystem => 'Системная';

  @override
  String get novelThemePaper => 'Бумага';

  @override
  String get novelThemeSepia => 'Защита глаз';

  @override
  String get novelThemeNight => 'Ночная';

  @override
  String get aboutDisplayRefreshRate => 'Частота обновления';

  @override
  String get cardActionBookmark => 'В закладки';

  @override
  String get cardActionUnbookmark => 'Убрать из закладок';

  @override
  String get cardActionDownload => 'Скачать';

  @override
  String get cardActionWatchLater => 'Посмотреть позже';

  @override
  String get cardActionRemoveWatchLater => 'Убрать из «Посмотреть позже»';

  @override
  String get cardActionShare => 'Поделиться';

  @override
  String get linkCopied => 'Ссылка скопирована';

  @override
  String get copyLink => 'Копировать ссылку';

  @override
  String get watchLaterAdded => 'Добавлено в «Посмотреть позже»';

  @override
  String get watchLaterTitle => 'Посмотреть позже';

  @override
  String get watchLaterEmpty => 'Отложенные работы появятся здесь';

  @override
  String get watchLaterLoadFailed => 'Не удалось загрузить «Посмотреть позже»';

  @override
  String get bookmarkEditTitle => 'Изменить закладку';

  @override
  String get bookmarkTags => 'Теги закладок';

  @override
  String get bookmarkTagNewHint => 'Введите тег и нажмите Enter';

  @override
  String get bookmarkTagSuggestions => 'Частые теги';

  @override
  String get bookmarkTagsEmpty => 'Тегов закладок пока нет';

  @override
  String get bookmarkTagsLoadFailed => 'Не удалось загрузить теги закладок';

  @override
  String get seriesTitle => 'Серия';

  @override
  String get seriesLoadFailed => 'Не удалось загрузить серию';

  @override
  String get seriesLoadMoreFailed => 'Не удалось загрузить ещё';

  @override
  String get seriesEmpty => 'В этой серии пока нет работ';

  @override
  String seriesWorksCount(int count) {
    return '$count работ';
  }

  @override
  String seriesEpisode(int order) {
    return 'Часть $order';
  }

  @override
  String get seriesPrevious => 'Предыдущая';

  @override
  String get seriesNext => 'Следующая';

  @override
  String get watchlistTitle => 'Отслеживаемое';

  @override
  String get watchlistManga => 'Манга';

  @override
  String get watchlistNovel => 'Новелла';

  @override
  String get watchlistEmpty => 'В отслеживаемом пока нет серий';

  @override
  String get watchlistLoadFailed => 'Не удалось загрузить список';

  @override
  String get watchlistLoadMoreFailed => 'Не удалось загрузить ещё';

  @override
  String get watchlistAdd => 'Следить за серией';

  @override
  String get watchlistRemove => 'Не следить';

  @override
  String get watchlistNewContent => 'Новое';

  @override
  String get localNovelsTitle => 'Локальные новеллы';

  @override
  String get localNovelsEmpty => 'Пока нет импортированных новелл';

  @override
  String get localNovelsLoadFailed => 'Не удалось загрузить локальные новеллы';

  @override
  String get localNovelsImport => 'Импорт TXT';

  @override
  String get localNovelsImportFailed => 'Не удалось импортировать';

  @override
  String localNovelsImported(String title) {
    return 'Импортировано «$title»';
  }

  @override
  String get localNovelsImportedLossy =>
      'Импортировано, но кодировка распознана не полностью — текст может содержать искажённые символы';

  @override
  String get localNovelsDelete => 'Удалить';

  @override
  String localNovelsDeleteConfirm(String title) {
    return 'Удалить «$title»? Локальный файл тоже будет удалён.';
  }

  @override
  String localNovelsChars(int count) {
    return '$count символов';
  }

  @override
  String get profileSeries => 'Серии';

  @override
  String get spotlightTitle => 'Спотлайт';

  @override
  String get spotlightArticleLoadFailed => 'Не удалось загрузить статью';

  @override
  String get spotlightCategoryAll => 'Все';

  @override
  String get spotlightCategoryIllust => 'Иллюстрации';

  @override
  String get spotlightCategoryManga => 'Манга';

  @override
  String get spotlightLoadFailed => 'Не удалось загрузить спотлайт';

  @override
  String get spotlightLoadMoreFailed => 'Не удалось загрузить ещё статьи';

  @override
  String get spotlightEmpty => 'Нет статей спотлайта';

  @override
  String get enableHaptics => 'Тактильный отклик';

  @override
  String get enableHapticsHint => 'Вибрация при выборе, сохранении и ошибках';

  @override
  String get downloadSelectPages => 'Выберите страницы для скачивания';

  @override
  String downloadSelectedCount(int selected, int total) {
    return 'Выбрано: $selected из $total';
  }

  @override
  String get selectAll => 'Выбрать все';

  @override
  String get done => 'Готово';

  @override
  String viewerPageLabel(int page, int total) {
    return 'Страница $page из $total';
  }

  @override
  String get tagActionSearch => 'Искать этот тег';

  @override
  String get tagActionCopy => 'Копировать имя тега';

  @override
  String get tagActionMute => 'Скрыть этот тег';

  @override
  String get tagActionUnmute => 'Показать этот тег';

  @override
  String get tagActionMuteMode => 'Выбрать теги для скрытия';

  @override
  String get tagCopied => 'Тег скопирован';

  @override
  String ugoiraExporting(int percent) {
    return 'Экспорт GIF… $percent%';
  }

  @override
  String get viewerEnterFullscreen => 'Полный экран';

  @override
  String get viewerExitFullscreen => 'Выйти из полноэкранного';

  @override
  String get viewerFitScreen => 'По размеру экрана';
}
