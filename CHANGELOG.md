# 更新日志 · Changelog

Parfait 每个版本中用户能感知到的变化，格式参照 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，版本号遵循[语义化版本](https://semver.org/lang/zh-CN/)。

User-facing changes in each Parfait release. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.10.0] - 2026-10-17

### 新增

- 排行补全为插画 21 个、小说 12 个分类，新增 AI、漫画和 R-18G 等排行。排行页右上角的"全部分类"面板里可以跳到任一分类、选择日期、切换插画和小说排行，也可以编辑分类：长按拖动排序，点一下隐藏或加回，随时恢复默认。长按顶部的分类标签可以移到最前或隐藏。设置 → 导航与布局里也能编辑。
- 排行页记住上次看的分类，下次打开时回到这里。
- R-18G 排行为空时，提示需要在 pixiv 网页版的浏览设置里开启 R-18G，并附上设置页链接。
- 底栏可以自定义：设置 → 导航与布局 → 底栏项目里拖动排序、关掉不用的页面（"我的"始终保留，至少留 2 项）。不在底栏的页面会出现在"我的"页里；搜索不在底栏时，推荐页顶栏会出现搜索按钮。
- 可以选择启动页：底栏第一项、上次停留的页，或指定某一页。返回键会回到底栏第一项；在那里按返回键会提示"再按一次退出"，2 秒内再按一次才退出。
- 接上鼠标或键盘时：右键等同长按（作品卡、标签、历史、下载任务等）；鼠标悬停在作品卡上会高亮；列表显示滚动条；按 Esc 返回上一页（在输入框里按 Esc 先收起输入）。
- 作品详情页标题下一行集中显示发布日期、页数、尺寸和作品 ID，点 ID 即可复制。

### 变更

- 平板、折叠屏和横屏手机上，作品详情改为左右两栏：左边看图，右边是作品信息，底部操作按钮放在信息栏里。横屏手机和小平板也会用两栏。
- 宽屏的侧边导航栏改为图标加文字的窄栏，只在很宽的窗口（1600dp 以上）展开；窗口太矮时侧栏可以滚动，不再被截断。
- 宽屏阅读小说时隐藏侧边导航栏，阅读区占满整个窗口。
- 宽屏上，小说、用户和系列列表改为多列排列；评论、搜索建议、收藏标签和个人主页“关于”等文字列表限制宽度并居中，搜索框和以图搜图的按钮也不再横跨整个窗口。顶部标签栏在宽屏上靠左排列，不再平均铺满整行。
- 横屏手机上，欢迎页和登录页把标题放到左侧，“开始”和登录按钮在首屏就能看到。
- 适配 Android 17：自定义图片源、DoH、LLM 翻译地址或系统代理在局域网里时，Parfait 会用系统弹窗申请“附近设备”权限；不允许的话，相关请求立即报错，不再一直等到超时。其他情况不会申请这个权限。
- 作品详情和大图查看器改为共享元素转场：页面在静止的下层页面上淡入淡出，图片在两者之间飞行；返回时图片原来的位置透出下层页面，图片还在飞回时详情页就能滑动和点按。详情页底部胶囊只保留下载和收藏，更矮、半透明、没有阴影。
- 动画时长按动的内容分档：小的状态变化更快，查看器双击缩放、翻页和 Tab 归位更稳；回到顶部按距离加长，很远时先跳近再滑；长文本展开改为弹簧动画。随操作出现或消失的提示、横幅和状态行改为展开淡入、收起淡出。开启"减少动态效果"时都直接到位。
- 关注按钮、下载状态、追更和多选勾选切换时会像收藏心形一样轻轻弹一下，关注成功的触感与收藏一致；评论头像和搜索页热门标签按下时有反馈。
- 评论区："翻译"改为评论下方的按钮，与"回复""查看回复"并排；⋮ 只出现在自己的评论上，里面是删除；所有评论的日期对齐在同一右边缘；表情和图片表情面板打开、收起、互相切换时有过渡，从面板切回键盘时输入栏不再先落下再升起。
- 界面统一：页面边距统一为 16dp，行尾的图标按钮与上下文字对齐；搜索框、设置表单、分组标题和说明文字的样式一致；作品详情页各小节的标题和间距统一；排行分类的名字不再被拆成两行；特辑文中的图片都是圆角。
- 图标含义统一：稍后再看都用书签，追更用书库图标，我的页的账号按钮改为"账号管理"，屏蔽列表用"解除屏蔽"文字按钮代替眼睛图标。
- 更流畅：列表滚动和加载下一页，打开、返回作品详情和切换首页分区，第一次打开排行、新作、作者主页、搜索结果和设置，评论页弹出、收起键盘，小说阅读时呼出工具栏和翻页，卡顿都减少了；多图作品的详情页打开更快。
- 开启无障碍服务（如 TalkBack、随选朗读或自动化工具）时滚动更流畅：语义信息最多每 100 毫秒同步给系统一次，与原生应用一致。

### 移除

- 移除桌面小部件。升级后，已放在桌面上的小部件会失效，可以长按后移除；它在后台定期刷新用的任务和缓存的图片也会一并清理。

### 修复

- 打开兼容通道时，API、登录和网页请求不再落到会被 pixiv 源站以 403 拒绝的无 SNI 连接；这条最后的兜底连接只用于图片。
- 没网时点的收藏、关注和追更，现在会在启动时和网络恢复时自动补发，不必切到后台或再做一次操作；补发失败后会在等待结束时自动重试，补发途中应用被关闭也不会丢失。
- 应用运行中清除缓存，不再导致图片加载出错。
- 在部分使用 PowerVR B 系列 GPU 的设备上，画面异常和卡顿的问题已修复。
- 排行加载失败时，标题不再显示成一串内部文字，而是写明哪个分类加载失败。
- 账号页的服务器显示设置、搜索页的热门标签、追更列表、收藏标签、稍后看、本地小说和应用设置加载失败时，立即显示错误和重试按钮，不再先转圈约 40 秒。
- 横屏手机打开个人主页时，作品数一行不再被挤压变形。
- 选用 pixiv.re、pixiv.nl 等镜像图片源或自定义图片源时，图片不再加载失败：镜像先直接连接，不再先等可能连不上的 DoH 解析（之前一张图要等 20 多秒，超时后显示失败）。
- 用户主页的横幅较亮时，状态栏的时间、电量图标改为深色，不再看不清。
- 小说阅读器的标题栏和底栏不再透出下面的正文；个人页横幅上的返回和菜单按钮加了描边，彩色横幅上也看得清；手机上下载任务的删除按钮不再单独占一行。
- 放得下的可选文字（如单行作品标题）不再能单独拖动，拖动会滚动整页。
- 个人页下拉刷新后往回推，会先收起刷新指示器，再折叠头部。
- 在详情页左右划到另一件作品后返回，如果它的卡片在屏幕外，图片不再从屏幕外飞回来。
- 追更日期按系统语言的格式显示；稍后再看为空时，页面上说明怎样添加。
- 关于页的版本号不再带内部构建号（如"+2001"）。

### 安全

- TLS 库更新到 rustls 0.23.45：不再跨加密级别接受 TLS 1.3 握手消息。
- 导出账号凭据后，如果到 5 分钟时 Parfait 在后台或已被关闭，剪贴板里的凭据之前不会被清除；现在回到 Parfait 时会补清。相关提示也不再说成一定会自动清除，并提醒粘贴后自行清空剪贴板。

### Added

- Rankings now cover 21 illustration and 12 novel categories, adding AI, manga and R-18G rankings. The "All categories" sheet at the top right of the ranking page jumps to any category, picks a date, switches between illustration and novel rankings, and edits the categories: long-press and drag to reorder, tap to hide or add one back, or restore the defaults. Long-press a category tab to move it to the front or hide it. The same editor is under Settings → Navigation & layout.
- The ranking page remembers the last category you viewed and opens on it next time.
- An empty R-18G ranking now explains that R-18G must be turned on in pixiv's web viewing settings, with a link to that page.
- The bottom bar can be customized: under Settings → Navigation & layout → Bottom bar items, drag to reorder and switch off pages you don't use (Me always stays, and at least 2 items remain). Pages off the bar appear on the Me page; while Search is off the bar, the For you top bar shows a search button.
- Choose the start page: the first bar item, the last used page, or a specific page. Back returns to the first bar item; there, back shows "Press back again to exit", and a second back within 2 seconds leaves the app.
- With a mouse or keyboard: right-click does what a long press does (work cards, tags, history, downloads and more), work cards highlight under the pointer, lists show a scrollbar, and Esc goes back (in a text field it first leaves the field).
- The artwork page shows the date, page count, size and artwork ID in one line under the title; tap the ID to copy it.

### Changed

- On tablets, foldables and phones held sideways, artwork details now show in two columns: the artwork on the left, its information on the right, with the action buttons in the information column. Phones in landscape and small tablets get the two columns too.
- The side navigation on wide screens is now a narrow rail of icons with labels, expanding only on very wide windows (1600dp and up). On a short window the rail scrolls instead of being cut off.
- Reading a novel on a wide screen hides the side navigation so the text gets the whole window.
- On wide screens, novel, user and series lists show in several columns; text lists such as comments, search suggestions, bookmark tags and a profile's About tab keep a readable width and stay centred, and the search field and the reverse image search button no longer span the whole window. Top tabs keep to the left instead of spreading across the row.
- On a phone held sideways, the welcome and login pages put the heading on the left so the start and login buttons are on the first screen.
- Ready for Android 17: when a custom image source, DoH or LLM translation address, or the system proxy is on your local network, Parfait asks for the Nearby devices permission with the system dialog; without it those requests fail at once instead of waiting for a timeout. It is never asked for otherwise.
- Artwork details and the image viewer now use a shared-element transition: the page fades over a still page below while the image flies between them. On back, the image's spot shows the page below, and the detail page can be scrolled and tapped while the image is still flying back. The detail capsule keeps only download and bookmark, and is slimmer, translucent and shadowless.
- Animation lengths depend on what moves: small state changes are quicker; viewer zoom, page turns and tab settling are steadier; scrolling back to the top grows with the distance and jumps close first when far; long text springs open. Notes, banners and status lines that appear or go after an action now open and fade instead of jumping. With reduced motion, all of these are instant.
- The follow button, download state, watchlist and selection checks pop like the bookmark heart when they switch, and a follow feels the same as a bookmark; comment avatars and hot-tag tiles on the search page show a press.
- Comments: Translate is a button under each comment, next to Reply and View replies; the ⋮ appears only on your own comments and holds Delete; every comment's date lines up on the same edge. The emoji and stamp panels slide open, closed and between each other, and switching from a panel back to the keyboard no longer drops the input bar first.
- A consistent look: page margins are 16dp everywhere and icon buttons at the end of a row line up with the text; search fields, settings forms, group titles and notes share one style; section headings and gaps on the artwork page are even; ranking category names no longer break onto two lines; every image in a Spotlight article has rounded corners.
- Icons mean one thing each: Watch later is always the bookmark, followed series use the library icon, the Me page's account button says "Accounts", and the muted list uses an "Unmute" text button instead of an eye.
- Smoother overall: scrolling lists and loading their next page, opening and leaving artwork details, switching home sections, opening ranking, new works, an author's page, search results and settings for the first time, raising and dismissing the keyboard on the comments page, and showing the novel reader's bars and turning its pages all stutter less; multi-page works open faster.
- Scrolling is smoother while an accessibility service (TalkBack, Select to Speak, automation tools) is on: semantics reach the system at most every 100 ms, as native apps do.

### Removed

- The home screen widget is gone. After the update, a widget already on the home screen stops working and can be removed with a long press; its background refresh job and cached images are cleaned up too.

### Fixed

- With the compatibility route on, API, login and web requests no longer fall back to a no-SNI connection that pixiv's origin rejects with 403; that last-resort connection now serves images only.
- Bookmarks, follows and watchlist changes made offline are now sent at launch and as soon as the network is back, without leaving the app or tapping something else; a failed attempt retries once its wait is over, and closing the app mid-send no longer loses them.
- Clearing the app's cache while it runs no longer makes images fail to load.
- Fixed visual glitches and slowdowns on devices with PowerVR B-Series GPUs.
- A ranking that fails to load now names the category in its title instead of showing an internal placeholder.
- When the server display settings, search trends, watchlists, bookmark tags, Watch Later, local novels or the app settings fail to load, the error and its retry button now appear at once instead of after about 40 seconds of spinning.
- Opening a profile on a phone held sideways no longer squeezes the works count row out of shape.
- Images load again with a mirror image source such as pixiv.re or pixiv.nl, or a custom one: Parfait now connects to the mirror directly first instead of waiting on DoH lookups that may not get through (an image used to wait over 20 seconds and then fail).
- Status bar icons over a bright profile banner turn dark so they stay readable.
- The novel reader's top and bottom bars no longer show the text underneath; the back and menu buttons on a profile banner have an outline that stays visible on colored banners; on phones a download's remove button no longer takes a line of its own.
- Selectable text that fits, such as a one-line work title, no longer drags on its own; dragging it scrolls the page.
- On a profile, pushing a pull-to-refresh back retracts the indicator before the header collapses.
- After swiping to another work on the detail page, back no longer flies the image in from off the screen when that work's card is off screen.
- Watchlist dates follow your language, and an empty Watch later page says how to add works.
- The version on the About page no longer carries the internal build number (such as "+2001").

### Security

- The TLS library moves to rustls 0.23.45, which no longer accepts TLS 1.3 handshake messages across an encryption level boundary.
- After exporting the account credential, the clipboard was not cleared if Parfait was in the background or closed when the 5 minutes ran out; it is now cleared when you return to Parfait. The notices no longer promise an automatic clear and ask you to clear the clipboard yourself after pasting.

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

[Unreleased]: https://github.com/Lopution/Parfait/compare/v0.10.0...HEAD
[0.10.0]: https://github.com/Lopution/Parfait/releases/tag/v0.10.0
[0.9.0]: https://github.com/Lopution/Parfait/releases/tag/v0.9.0
