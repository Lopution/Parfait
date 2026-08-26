enum ReplicaLanguage { zhCN, enUS, jaJP, ruRU }

class ReplicaStrings {
  static const _values = {
    ReplicaLanguage.zhCN: {
      'welcome1': '感谢使用Pixiv Func',
      'welcome2': '下面将进行首次启动设置',
      'start': '开始',
      'selectLanguage': '选择您的语言',
      'selectTheme': '选择喜欢的主题',
      'next': '下一步',
      'later': '稍后您可以在设置中进行相应变更',
      'dark': '黑暗',
      'light': '明亮',
      'system': '跟随系统',
      'loginTitle': '注册 或 登录',
      'register': '注册',
      'login': '登录',
    },
    ReplicaLanguage.enUS: {
      'welcome1': 'Thank you for using Pixiv Func',
      'welcome2': 'Initial setup will begin now',
      'start': 'Start',
      'selectLanguage': 'Select your language',
      'selectTheme': 'Choose your favorite theme',
      'next': 'Next',
      'later': 'You can change the settings later',
      'dark': 'Dark',
      'light': 'Light',
      'system': 'Follow the System',
      'loginTitle': 'Register or Login',
      'register': 'Register',
      'login': 'Log in',
    },
    ReplicaLanguage.jaJP: {
      'welcome1': 'Pixiv Funcをご利用ありがとうございます',
      'welcome2': '初期設定を開始します',
      'start': '開始',
      'selectLanguage': '言語を選択',
      'selectTheme': 'テーマの選択',
      'next': '次へ',
      'later': '後で設定を変更できます',
      'dark': 'ダーク',
      'light': 'ライト',
      'system': 'システムのデフォルト',
      'loginTitle': '登録･ログイン',
      'register': '登録',
      'login': 'ログイン',
    },
    ReplicaLanguage.ruRU: {
      'welcome1': 'Спасибо за использование Pixiv Func',
      'welcome2': 'Начнется первоначальная настройка',
      'start': 'Начать',
      'selectLanguage': 'Выберите свой язык',
      'selectTheme': 'Выберите тему',
      'next': 'Далее',
      'later': 'Позже вы можете изменить настройки',
      'dark': 'Тёмный',
      'light': 'Светлый',
      'system': 'Как в системе',
      'loginTitle': 'Вход или Регистрация',
      'register': 'Регистрация',
      'login': 'Вход',
    },
  };

  static String text(ReplicaLanguage language, String key) {
    return _values[language]?[key] ?? _values[ReplicaLanguage.zhCN]![key]!;
  }
}
