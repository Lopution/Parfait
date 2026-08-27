enum ReplicaLanguage {
  zhCN('zh-CN'),
  enUS('en-US'),
  jaJP('ja-JP'),
  ruRU('ru-RU');

  const ReplicaLanguage(this.tag);

  final String tag;

  static ReplicaLanguage fromTag(String tag) {
    final normalized = tag.replaceAll('_', '-').toLowerCase();
    if (normalized.startsWith('en')) return ReplicaLanguage.enUS;
    if (normalized.startsWith('ja')) return ReplicaLanguage.jaJP;
    if (normalized.startsWith('ru')) return ReplicaLanguage.ruRU;
    return ReplicaLanguage.zhCN;
  }
}

class ReplicaStrings {
  static const _values = {
    ReplicaLanguage.zhCN: {
      'welcome1': '感谢使用Pixiv Func',
      'welcome2': '下面将进行首次启动设置',
      'start': '开始',
      'selectTheme': '选择喜欢的主题',
      'next': '下一步',
      'later': '稍后您可以在设置中进行相应变更',
      'dark': '黑暗',
      'light': '明亮',
      'system': '跟随系统',
      'loginTitle': '注册 或 登录',
      'register': '注册',
      'login': '登录',
      'localReverseProxy': '本地反向代理',
      'reverseProxyHint': 'Pixiv官方页面无法注册或登陆时 建议开启本地反向代理',
      'getMoreHelp': '获取更多帮助 >>',
      'useLoginWithClipboardHint': '或使用\n长按头像复制账号数据',
      'useLoginWithClipboard': '使用剪贴板数据登录',
      'loginAgree': '登录即表示您同意',
      'userAgreement': '《Pixiv Func用户使用协议》',
      'rankingDay': '每日',
      'rankingDayR18': '每日(R-18)',
      'rankingDayMale': '每日(男性欢迎)',
      'rankingDayMaleR18': '每日(男性欢迎 & R-18)',
      'rankingDayFemale': '每日(女性欢迎)',
      'rankingDayFemaleR18': '每日(女性欢迎 & R-18)',
      'rankingWeek': '每周',
      'rankingWeekR18': '每周(R-18)',
      'rankingWeekOriginal': '每周(原创)',
      'rankingWeekRookie': '每周(新人)',
      'rankingMonth': '每月',
    },
    ReplicaLanguage.enUS: {
      'welcome1': 'Thank you for using Pixiv Func',
      'welcome2': 'Initial setup will begin now',
      'start': 'Start',
      'selectTheme': 'Choose your favorite theme',
      'next': 'Next',
      'later': 'You can change it later in the settings',
      'dark': 'Dark',
      'light': 'Light',
      'system': 'Follow the System',
      'loginTitle': 'Register or Login',
      'register': 'Register',
      'login': 'Log in',
      'localReverseProxy': 'Local reverse proxy',
      'reverseProxyHint':
          'When the official page of Pixiv cannot be registered or logged in, it is recommended to open a local reverse proxy.',
      'getMoreHelp': 'Get more help >>',
      'useLoginWithClipboardHint':
          'Or use\nlong press on the avatar to copy account data',
      'useLoginWithClipboard': 'Login with clipboard data',
      'loginAgree': 'By logging in you agree',
      'userAgreement': '《Pixiv Func User Agreement》',
      'rankingDay': 'Daily',
      'rankingDayR18': 'Daily (R-18)',
      'rankingDayMale': 'Daily (Male favorite)',
      'rankingDayMaleR18': 'Daily (Male favorite & R-18)',
      'rankingDayFemale': 'Daily (Female favorite)',
      'rankingDayFemaleR18': 'Daily (Female favorite & R-18)',
      'rankingWeek': 'Weekly',
      'rankingWeekR18': 'Weekly (R-18)',
      'rankingWeekOriginal': 'Weekly (Original)',
      'rankingWeekRookie': 'Weekly (Rookie)',
      'rankingMonth': 'Monthly',
    },
    ReplicaLanguage.jaJP: {
      'welcome1': 'Pixiv Funcをご利用ありがとうございます',
      'welcome2': '初期設定を開始します',
      'start': '開始',
      'selectTheme': 'テーマの選択',
      'next': '次へ',
      'later': '後で設定を変更できます',
      'dark': 'ダーク',
      'light': 'ライト',
      'system': 'システムのデフォルト',
      'loginTitle': '登録･ログイン',
      'register': '登録',
      'login': 'ログイン',
      'localReverseProxy': 'リバースプロキシ',
      'reverseProxyHint': 'Pixivに登録･ログインできない場合はリバースプロキシを利用することをオススメします',
      'getMoreHelp': '詳細なヘルプ >>',
      'useLoginWithClipboardHint': 'もしくは\nプロフィール画像を長押ししてアカウントデータをコピー',
      'useLoginWithClipboard': 'クリップボードに保存されたデータでログイン',
      'loginAgree': 'ログインすると利用規約に同意したものとみなします',
      'userAgreement': '《Pixiv Func利用規約》',
      'rankingDay': 'デイリー',
      'rankingDayR18': 'デイリー (R-18)',
      'rankingDayMale': 'デイリー (男子に人気)',
      'rankingDayMaleR18': 'デイリー (男子に人気 & R-18)',
      'rankingDayFemale': 'デイリー (女子に人気)',
      'rankingDayFemaleR18': 'デイリー (女子に人気 & R-18)',
      'rankingWeek': 'ウィークリー',
      'rankingWeekR18': 'ウィークリー (R-18)',
      'rankingWeekOriginal': 'ウィークリー (オリジナル)',
      'rankingWeekRookie': 'ウィークリー (ルーキー)',
      'rankingMonth': 'マンスリー',
    },
    ReplicaLanguage.ruRU: {
      'welcome1': 'Спасибо за использование Pixiv Func',
      'welcome2': 'Начнется первоначальная настройка',
      'start': 'Начать',
      'selectTheme': 'Выберите свою любимую тему',
      'next': 'Далее',
      'later': 'Позже вы сможете измененить в настройках',
      'dark': 'Тёмный',
      'light': 'Светлый',
      'system': 'Как в системе',
      'loginTitle': 'Вход или Регистрация',
      'register': 'Регистрация',
      'login': 'Вход',
      'localReverseProxy': 'Локальный прокси',
      'reverseProxyHint':
          'Если официальная страница Pixiv не может быть зарегистрирована или авторизована, рекомендуется включить прокси.',
      'getMoreHelp': 'Получить дополнительную помощь >>',
      'useLoginWithClipboardHint':
          'Или используйте длинное нажатие на аватаре,\n чтобы скопировать данные аккаунта',
      'useLoginWithClipboard': 'Войти с данными из буфера обмена',
      'loginAgree': 'Входя в систему, вы принимаете',
      'userAgreement': '《Пользовательское соглашение Pixiv Func》',
      'rankingDay': 'Ежедневно',
      'rankingDayR18': 'Ежедневно (R-18)',
      'rankingDayMale': 'Ежедневно (Мужчины)',
      'rankingDayMaleR18': 'Ежедневно (Мужчины & R-18)',
      'rankingDayFemale': 'Ежедневно (Женщины)',
      'rankingDayFemaleR18': 'Ежедневно (Женщины & R-18)',
      'rankingWeek': 'Еженедельно',
      'rankingWeekR18': 'Еженедельно (R-18)',
      'rankingWeekOriginal': 'Еженедельно (Оригинальное)',
      'rankingWeekRookie': 'Еженедельно (Дебют)',
      'rankingMonth': 'Ежемесячно',
    },
  };

  static String text(ReplicaLanguage language, String key) {
    return _values[language]?[key] ?? _values[ReplicaLanguage.zhCN]![key]!;
  }

  static String fromTag(String languageTag, String key) {
    return text(ReplicaLanguage.fromTag(languageTag), key);
  }
}
