# 更新日志 · Changelog

Parfait 每个版本中用户能感知到的变化，格式参照 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，版本号遵循[语义化版本](https://semver.org/lang/zh-CN/)。

User-facing changes in each Parfait release. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

### 修复

- 打开兼容通道时，API、登录和网页请求不再落到会被 pixiv 源站以 403 拒绝的无 SNI 连接；这条最后的兜底连接只用于图片。
- 没网时点的收藏、关注和追更，现在会在启动时和网络恢复时自动补发，不必切到后台或再做一次操作；补发失败后会在等待结束时自动重试，补发途中应用被关闭也不会丢失。
- 应用运行中清除缓存，不再导致图片加载出错。

### Fixed

- With the compatibility route on, API, login and web requests no longer fall back to a no-SNI connection that pixiv's origin rejects with 403; that last-resort connection now serves images only.
- Bookmarks, follows and watchlist changes made offline are now sent at launch and as soon as the network is back, without leaving the app or tapping something else; a failed attempt retries once its wait is over, and closing the app mid-send no longer loses them.
- Clearing the app's cache while it runs no longer makes images fail to load.

## [0.9.0] - 2026-10-10

第一个公开测试版。The first public beta.

### 新增

- 中国大陆直连：浏览和下载不需要一直开着代理（首次登录除外）；兼容通道只作用于 pixiv 的域名，每种连接方式都会完整校验 HTTPS 证书。
- 插画、漫画、小说的推荐、排行、搜索与 pixivision 特辑，支持反向搜图。
- 小说阅读可调字号和行距，有三种配色；可追更漫画和小说系列。
- 批量下载，可暂停、继续，可自定义文件命名模板。
- 没网时点的收藏、关注会先记下来，联网后自动补发。
- 多账号、设置备份、桌面小部件；中文、English、日本語、Русский 界面。
- 无广告、无统计。

### Added

- Direct access in mainland China: browsing and downloads work without a proxy after the first login; the compatibility route applies to pixiv's domains only, and every connection fully verifies the HTTPS certificate.
- Recommendations, rankings, search and pixivision features for illustrations, manga and novels, plus reverse image search.
- A novel reader with adjustable text size and line spacing and three color schemes; watchlists for manga and novel series.
- Batch downloads that can be paused and resumed, with custom file name templates.
- Bookmarks and follows made offline are queued and sent once the app is back online.
- Multiple accounts, settings backup and a home screen widget; Chinese, English, Japanese and Russian interfaces.
- No ads, no analytics.

[Unreleased]: https://github.com/Lopution/Parfait/compare/v0.9.0...HEAD
[0.9.0]: https://github.com/Lopution/Parfait/releases/tag/v0.9.0
