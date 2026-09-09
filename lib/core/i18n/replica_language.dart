/// The four UI languages the app ships ARBs for (C6).
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
