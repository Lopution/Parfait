# 更新日志 · Changelog

Parfait 每个版本中用户能感知到的变化，格式参照 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，版本号遵循[语义化版本](https://semver.org/lang/zh-CN/)。

User-facing changes in each Parfait release. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

### 新增

- 排行补全为插画 21 个、小说 12 个分类，新增 AI、漫画和 R-18G 等排行。排行页右上角的"全部分类"面板里可以跳到任一分类、选择日期、切换插画和小说排行，也可以编辑分类：长按拖动排序，点一下隐藏或加回，随时恢复默认。长按顶部的分类标签可以移到最前或隐藏。设置 → 导航与布局里也能编辑。
- 排行页记住上次看的分类，下次打开时回到这里。
- R-18G 排行为空时，提示需要在 pixiv 网页版的浏览设置里开启 R-18G，并附上设置页链接。

### 修复

- 打开兼容通道时，API、登录和网页请求不再落到会被 pixiv 源站以 403 拒绝的无 SNI 连接；这条最后的兜底连接只用于图片。
- 没网时点的收藏、关注和追更，现在会在启动时和网络恢复时自动补发，不必切到后台或再做一次操作；补发失败后会在等待结束时自动重试，补发途中应用被关闭也不会丢失。
- 应用运行中清除缓存，不再导致图片加载出错。
- 在部分使用 PowerVR B 系列 GPU 的设备上，画面异常和卡顿的问题已修复。
- 排行加载失败时，标题不再显示成一串内部文字，而是写明哪个分类加载失败。
- 账号页的服务器显示设置、搜索页的热门标签、追更列表、收藏标签、稍后看、本地小说和应用设置加载失败时，立即显示错误和重试按钮，不再先转圈约 40 秒。

### 安全

- TLS 库更新到 rustls 0.23.45：不再跨加密级别接受 TLS 1.3 握手消息。

### Added

- Rankings now cover 21 illustration and 12 novel categories, adding AI, manga and R-18G rankings. The "All categories" sheet at the top right of the ranking page jumps to any category, picks a date, switches between illustration and novel rankings, and edits the categories: long-press and drag to reorder, tap to hide or add one back, or restore the defaults. Long-press a category tab to move it to the front or hide it. The same editor is under Settings → Navigation & layout.
- The ranking page remembers the last category you viewed and opens on it next time.
- An empty R-18G ranking now explains that R-18G must be turned on in pixiv's web viewing settings, with a link to that page.

### Fixed

- With the compatibility route on, API, login and web requests no longer fall back to a no-SNI connection that pixiv's origin rejects with 403; that last-resort connection now serves images only.
- Bookmarks, follows and watchlist changes made offline are now sent at launch and as soon as the network is back, without leaving the app or tapping something else; a failed attempt retries once its wait is over, and closing the app mid-send no longer loses them.
- Clearing the app's cache while it runs no longer makes images fail to load.
- Fixed visual glitches and slowdowns on devices with PowerVR B-Series GPUs.
- A ranking that fails to load now names the category in its title instead of showing an internal placeholder.
- When the server display settings, search trends, watchlists, bookmark tags, Watch Later, local novels or the app settings fail to load, the error and its retry button now appear at once instead of after about 40 seconds of spinning.

### Security

- The TLS library moves to rustls 0.23.45, which no longer accepts TLS 1.3 handshake messages across an encryption level boundary.

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
