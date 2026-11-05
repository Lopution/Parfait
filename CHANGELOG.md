# 更新日志 · Changelog

Parfait 每个版本中用户能感知到的变化，格式参照 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，版本号遵循[语义化版本](https://semver.org/lang/zh-CN/)。

User-facing changes in each Parfait release. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [1.1.1] - 2026-11-06

### 修复

- 冷启动后第一屏的预览图比往下滑时加载慢很多：图片源为「自动」时每次启动都重新测速，第一屏加载到一半就换源；镜像源的一条线路连不上时，要等另一条慢线路超时。

### Fixed

- After a cold start, the first screen of previews loaded much more slowly than the images you scrolled to: with the Auto image source, every launch measured the sources again and could switch partway through the first screen, and a mirror whose fastest route failed waited on a slow one.

## [1.1.0] - 2026-11-05

### 新增

- **小说插图：** 小说正文里的插图会显示出来，每张占一页，点开可以看大图；清晰度在「浏览设置」的「小说插图质量」里选。
- **上下滚动阅读：** 小说阅读器默认改为上下滚动，「阅读设置」里可以切回「左右翻页」。
- **小说的标题页、章节与链接：** 第一页开头显示标题、作者和所属系列，章节标题用更大的粗体；作者写的页面跳转显示为「→ 第 N 页」，点一下到那一页；正文里的 Pixiv 链接可以直接打开；「阅读进度」面板的目录标出当前章节并滚到它。
- **Pixiv 小说书签：** 在「阅读进度」面板里可以给小说加 Pixiv 书签，随账号同步；没有阅读记录的小说从书签处打开。「我的」页新增「小说书签」，列出加了书签的小说和所在页码，点开从书签处阅读，也能删除或加回书签。
- **收藏的小说：** 个人主页的「收藏」可以在插画和小说之间切换，小说收藏有自己的公开、私密和标签筛选。
- **小说详情：** 小说详情面板列出系列、字数、浏览数、收藏数和发布时间。
- **小说系列页：** 显示标题、作者、作品数、「已完结」「原创」标签和可展开的简介，按「第 N 话」列出全部小说，看不了的会说明原因。读过的系列点「继续第 N 话」，从上次打开的那一话接着读（按账号记住，重启后仍在），也可以「从第 1 话开始」；没读过时点「开始阅读」；「阅读最新第 N 话」直接打开最新的一话。小说详情面板里的系列名、阅读器底部系列栏的标题，以及追更里小说系列的「打开目录」都能进入系列页；追更里的小说系列也能直接「继续阅读」。
- **画师搜索带作品：** 搜索用户的结果和推荐画师一样，每位画师下面带最多三张作品，点作品直接打开；被 R-18、AI 屏蔽或已屏蔽的作品不显示。

### 变更

- **小说也能屏蔽：** 屏蔽和本地过滤现在也作用于小说（推荐、排行、搜索、作者作品）：关闭「直接隐藏被屏蔽的作品」时，被屏蔽的小说封面模糊、标题处写明屏蔽原因，点按可以临时查看。「相关作品」和「新作」也会过滤，屏蔽 R-18 时同时隐藏 R-18G。
- **作品详情页的新样子：** 短图上方的空白和平板的看图区域铺上作品自己的淡淡色调，图片落定后从图片上沿升起；底部的下载收藏胶囊带柔和投影；作者卡片轻轻浮起；作品标题更大、分区标题更轻；顶栏、底栏和评论框的阴影变浅。
- **主页和欢迎页的色调：** 没有背景图的画师主页，头部铺上头像自己的淡淡色调，不再是一条灰带；欢迎页和登录页的标题后面有一层应用图标颜色的柔和光晕；登录页只有「登录」按钮是粉色，「注册」和「使用剪贴板数据登录」退到次要位置。
- **浮层：** 菜单、对话框、底部面板和提示浮在页面上方，带一层柔和的投影，浅色主题下偏暖；从屏幕边上的 ⋮ 打开的菜单不再贴着屏幕边。
- **排行榜名次：** 名次单独成一列，放在标题和作者前面，前三名更大更醒目，其余名次小一号、颜色淡一些；小说排行同样突出前三。
- **各页细节统一：** 搜索筛选的数量角标改为主题粉色，不再是报错红；特辑卡片和作品卡片一样，把标题和日期放在图片下方；评论之间用留白分隔，不再画分割线；空状态和加载失败的图标放进圆底，整体略微上移；移除账号、删除评论、清除翻译凭据等无法撤销的确认按钮改为红色；设置里选中的选项只有标题变色，说明文字保持灰色；平板横屏等宽窗口里的标签栏更紧凑，俄语等较长的标签也能完整显示。
- **详情页左右滑动更顺：** 滑到下一张作品时，标题、作者和按钮随图片淡入，不再一下子跳出来。
- **出错时只说原因：** 出错提示不再带「详情」和英文技术信息；技术信息仍记在日志里，可从「我的 → 关于 → 导出日志」导出；启动页和登录页出错时可以点「复制诊断信息」。
- **存储出错说清楚：** 下载因存储空间不足失败时显示「存储空间不足」；保存用的文件夹被删除或访问授权失效时，提示到「保存位置」重新选择；其他存储问题显示「存储错误」；GIF 保存失败也会说明原因。
- **设置没存上会提示：** 设置保存失败时（包括以图搜图引擎、开发者选项和移除账号）提示「设置保存失败」，已经离开页面也会提示；「稍后再看」没存上，或从卡片菜单下载、屏蔽失败时，同样会提示。
- **图片线路按网络挑选：** 图片按所在网络（运营商或 Wi-Fi）记住各条线路的快慢和失败，自动用表现最好的一条；常用的 Cloudflare 地址慢时，会试几个其他地址，留下更快的；pixiv 图片源站换了地址，也能经加密 DNS 自己找到，不用等新版本。「当前生效路由」列出图片线路、速度和 Cloudflare 所在机房，用户协议的网络说明也同步更新。
- **图片卡住更快恢复：** 缩略图卡在慢线路上约 2 秒后，会换一条线路再取一次；自动重试期间不再先显示裂图；切换网络或断网恢复后，加载失败的图片会自己重新加载。
- **原图下载更连贯：** 下载原图和查看原图改为单个连接，卡住时从已收到的位置接着下，不再一截一截地停顿。
- **超长图完整打开：** 超长图从卡片打开时整张显示：顶部的方图清晰，下方先显示模糊的整图，随后变清晰。
- **重新打开会刷新：** 重新打开作品、用户主页、评论、相关作品、搜索结果或「收藏标签」时会重新加载，不再一直是本次启动后第一次打开时的内容；作品的浏览数和收藏数超过 10 分钟会在后台刷新。
- **小说正文跟随系统字号。**
- **相册里不再导出简介：** 系统不允许相册存放文本文件，下载位置为相册时「同时导出作品简介」显示为不可用并注明原因，选「文件夹」时照常导出。以前在相册下打开它，下载时会报错，也不会生成简介。

### 修复

- 从作者主页连续按返回回到列表时，列表从侧边滑进来，飞回的图片和顶栏、底栏错开。
- 打开或返回作品时，底栏跟着图片滑开、滑回的过程中没有阴影，图片落定时阴影才突然出现。
- 以「覆盖」方式导入备份时，文件里有一条历史记录写不进去，或导入途中应用被关闭，本地浏览历史会被清空。
- 收藏等操作还没完成就切换了账号，登录过期时这个操作会被重新发到新账号上。
- 切换账号后，原账号在后台刷新登录，又把当前账号切了回去。
- 删除当前账号时应用恰好被关闭，下次启动账号数据读不出来。
- 浏览记录同步到 pixiv 的同时又看了同一作品，这次浏览不会再同步。
- 保存到相册的下载，暂停后点「继续」会从头重新下载。
- 下载刚点「暂停」又马上点「取消」，任务会一直停在「取消中」。
- 取消已暂停的下载后，已下好的部分不会被删除，一直占着存储空间。
- 应用在下载途中被关闭，没写完的文件不会被清理。
- 应用重启后接着下载更新时，点「取消」不起作用，下完照样打开安装界面；下得很快时还会一直停在「正在下载并验证…」。
- 网络连接中途卡住时，下载可能一直停在进行中，「分层连通性探测」也会一直停在检测中。
- 网络连接卡住后又断开时，正在加载的图片会一起失败；反复几次后，所有图片都加载不出来，直到重启应用。
- 个别图片加载失败后会一直失败，重试或重新打开都不行，只能清除缓存。
- 在稍后再看里用「管理」批量移除后马上返回，作品不会被移除。
- 图片源为「自动」并已测出镜像时，评论里的贴图和未设头像用户的默认头像显示不出来。
- 卡片、作品页和看图页之间转场时，图片被顶栏错误地遮住或裁掉；返回时，滑走的栏后面露出空白条。
- 从详情页返回可以下拉刷新的列表（推荐、排行、搜索结果、用户页）时，滑走的顶栏下面露出空白条，卡片被切平。
- 点开或返回卡片时，顶栏和底栏在复位的那一刻闪一下。
- 列表还在惯性滚动时连续小幅快滑，会越滑越快。
- 快速连点同一张卡片，会接着打开大图。
- 页面返回的动画还没结束时横滑，会切到底栏的下一个页面。
- 刷新时打开的卡片菜单或关注菜单，等刷新完成后再选，操作不生效。
- 收藏或关注失败时，如果按钮已经滑出屏幕就不提示原因；收藏面板提交失败会提示两遍。
- Pixiv 小说里作者设置的分页和章节标题，被原样显示成「[newpage]」「[chapter:…]」文字。
- 系统字号调大后，小说每行的末尾被截掉。
- 正文含「,]」的小说少了逗号。
- 简介由短行组成时，折叠后的「展开」压在文字上。
- 打开某位用户的小说作品时，先闪现上一位用户的小说。
- 切换账号后编辑资料，会改到另一个账号上。
- 添加账号途中被跳回首页。
- 切换账号后，短暂显示上一个账号的追更、用户页、系列、小说、收藏标签和最近浏览。
- 离线时排队的收藏、关注和追更，切换账号后会以另一个账号的身份发出。
- 移除账号后再添加回来，会补发它被移除前离线排队的收藏和关注。
- 登录途中离开登录页，仍会登录上。
- 退出豆包登录时如果安全存储出错，网页上的登录状态还留着。
- 收藏面板提交途中关闭面板，会把下面的页面一起关掉。
- 评论框关闭后评论发送失败，没有任何提示。
- 连点作者批量下载的确认，会把作者页一起关掉。
- 部分设备上下载到自选文件夹时报错，或文件名多出一段扩展名。
- 下载失败的条目里多出一个错位的「详情」。
- 分享图片或链接、以图搜图选图、导入备份或本地小说时，界面会卡住。
- 冷启动时分享图片进来，按返回会停在启动页。
- 导入本地小说失败时，会留下一个列表里看不到的文件。
- 保存设置（翻译凭据、相册名、命名模板、自定义图源、DoH/ECH）时继续输入，新输入的内容会被已保存的值覆盖，或被当成已经保存。
- 编辑资料时图片还在读取就点保存，资料会不带图片提交。
- 编辑资料读取失败时，只显示一行英文错误。
- 自动选择的图片源记录损坏后，再也存不进新的测速结果。
- 部分系统启动时，崩溃日志里会写入无关的错误。
- 启动时的更新检查如果在发出请求前就失败，要等一天才会再试。
- 应用从后台恢复后，详情页翻页会跳回第一张作品。
- 看图时应用被系统回收，回来后一直显示「没有可显示的图片」。
- 大图查看器里作品加载失败时，显示「没有可显示的图片」，没有重试。
- 带大段 EXIF 信息的 JPEG 不能用来以图搜图，也不能设为头像。
- 以图搜图时取消选图，会丢掉已选的图片并换回 SauceNAO。
- 用键盘或滚轮缩放图片，可以放大到超过 6 倍。
- 作品页「作者的其他作品」里会显示已屏蔽的作品。
- 搜索或排行加载到的作品全被过滤掉时，显示「暂无搜索结果」并停止加载。
- 开启屏蔽后，列表从上次保存的内容恢复时，仍会短暂显示被屏蔽的作品。
- 限定最近一天、一周或一月的搜索，过了午夜就加载不出下一页。
- 列表补页时遇到无效或重复的翻页地址，没有出错提示，看起来像已经到底。
- 应用被系统关闭后再回到搜索首页，热门标签加载出来时列表弹回上方。
- 简介里的 pixiv:// 链接打不开。
- 浏览历史删掉一条后往下翻，会漏掉一条；读取失败时显示「暂无浏览历史」，而且不能重试。
- 浏览历史时删除记录，后面的记录会加载不出来。
- 加载期间删掉的浏览记录，会随新加载的一页又回来。
- 一边浏览一边导出备份时，导出的浏览记录有的重复、有的缺失。
- 大字号加上键盘弹出时，收藏面板的确认按钮被挤出屏幕。
- 作品的绘画工具列表过长时，信息行溢出。
- 开启 TalkBack 时，关闭评论框或提交多页作品的下载后，底部操作栏不再出现。

### Added

- **Images in novels:** Images in a novel's text now show, each on a page of its own; tap one to view it. Pick their quality under Browse settings → Novel image quality.
- **A reader that scrolls:** The novel reader now scrolls up and down by default; Reading settings can switch back to Turn pages.
- **Title page, chapters and links in novels:** A novel's first page opens with its title, author and series, and chapter titles stand out in larger bold type. Page jumps an author writes show as a "→ Page N" link that goes to that page, and Pixiv links in the text open. The chapter list in the Reading progress sheet marks the chapter you are in and scrolls to it.
- **Pixiv markers on novels:** The Reading progress sheet can set a Pixiv marker on a novel, kept with your account, and a novel you have no reading position in opens at its marker. The Me page gains Novel markers, listing the novels you marked and the page of each: tap one to read from the marker, or remove the marker and put it back.
- **Bookmarked novels:** The Bookmarks tab of a profile switches between illustrations and novels, and novel bookmarks have their own public, private and tag filters.
- **Novel details:** A novel's info sheet lists its series, length, views, bookmarks and posting date.
- **Novel series page:** A novel series has its own page with its title, author, work count, Completed and Original labels, an expandable caption, and every novel by episode number; novels you cannot read say why. Continue episode N picks up at the novel you last opened in the series (remembered per account, across restarts), and Start from episode 1 is there too; a series you have not read shows Start reading, and Read latest (episode N) opens the newest one. The series name in a novel's info sheet, the series bar title in the reader and Open contents on a watched novel series all lead there, and a novel series in your Watchlist can also Continue reading directly.
- **Artist search shows works:** Like the recommended artists, each artist in user search results shows up to three of their works; tap one to open it. Works hidden by the R-18 or AI blocks or by a mute are left out.

### Changed

- **Mutes cover novels:** Mutes and the local filters now apply to novels too (recommended, rankings, search, an artist's works). With Hide muted works off, a muted novel's cover is blurred and its title says why until you tap it. Related works and New are filtered as well, and blocking R-18 also hides R-18G.
- **A new look for the artwork page:** The space above a short image and the tablet image stage carry a soft wash of the artwork's own colours, which rises from the top edge of the image once it has landed. The download and bookmark capsule casts a soft shadow, the author card sits slightly raised, the title is larger and section headings quieter, and the top bar, bottom bar and comment box cast lighter shadows.
- **Colour on profiles and the welcome page:** A profile without a cover shows a soft wash of the avatar's colours instead of a grey band. The welcome and login pages glow softly behind the title in the app icon's colours, and on the login page only Log in is pink, with Register and Log in with clipboard data stepping back.
- **Overlays:** Menus, dialogs, bottom sheets and messages float above the page on a soft shadow, warm in the light theme, and a menu opened from a ⋮ at the screen edge no longer touches the edge.
- **Ranking positions:** A ranking position stands in its own column before the title and author, with the top three larger and bolder and the rest smaller and lighter. Novel rankings mark the top three the same way.
- **Details that match across pages:** The search filter count badge is the theme pink instead of the error red. Spotlight cards put their title and date under the image, like work cards. Comments are separated by space instead of lines. Empty and error views show their icon on a disc, a little above the middle. Confirm buttons for things that cannot be undone (removing an account, deleting a comment, clearing translation credentials and so on) are red. A selected settings choice tints only its title, and its description stays grey. Tab rows on wide windows, such as a tablet in landscape, sit closer together and show long labels, such as Russian ones, in full.
- **Smoother swipes on the detail page:** When you swipe to the next work, its title, author and buttons fade in with the image instead of popping in.
- **Errors say what went wrong:** Error messages no longer come with Details and English technical text. The technical text stays in the log, which you can export from Me → About → Export logs, and errors on the startup and login pages offer Copy diagnostics.
- **Clear storage errors:** A download that fails because storage is full says Not enough storage space. If the chosen folder was deleted or lost its access, the message asks you to choose it again under Save location. Other storage problems read Storage error, and a failed GIF save says why.
- **Failed saves are reported:** When a setting fails to save (the reverse image search engine, developer options and account removal included), the app says Failed to save settings, even after you have left the page. A Watch later save that fails, and a download or mute from a card's menu that fails, are reported the same way.
- **Image routes chosen per network:** Images remember, for each network (carrier or Wi-Fi), how fast and how reliably each route loads them, and use the best one. When the usual Cloudflare addresses are slow, a few others are tried and the faster ones kept. If pixiv's image origin changes its addresses, the app finds the new ones over encrypted DNS without waiting for a release. Effective routes lists the image routes, their speed and each Cloudflare route's data centre, and the network section of the user agreement says so.
- **Stuck images recover sooner:** A thumbnail stuck on a slow route is fetched again over another route after about two seconds. Images no longer flash a broken-image icon while an automatic retry is pending, and images that failed reload on their own after a network switch or when the connection comes back.
- **Steadier original downloads:** Originals, whether downloaded or viewed, arrive on one connection that picks up from the last byte received when it stalls, instead of advancing in pauses.
- **Very tall works open whole:** A very tall work opened from a card shows in full: the square at its top is sharp, and the rest is blurry until the full image arrives.
- **Reopening refreshes:** Reopening a work, a profile, comments, related works, search results or Bookmark tags loads them again, instead of showing what they held the first time you opened them since launch. A work's view and bookmark counts refresh in the background once they are more than 10 minutes old.
- **Novel text follows the system font size.**
- **No captions in albums:** Android does not let an album hold text files, so Export work caption is greyed out with the reason while downloads go to an album, and works as before with a folder. Before, turning it on with an album made downloads report an error and wrote no caption.

### Fixed

- Pressing back twice in a row from an artist's profile slid the feed in from the side, so the returning image landed out of line with the top and bottom bars.
- While the bottom bar slid away and back with an opening or closing artwork it cast no shadow, which popped in only when the image landed.
- Importing a backup with Overwrite wiped the local browsing history if one history entry in the file could not be saved, or if the app was closed mid-import.
- A bookmark or similar action still in progress when you switched accounts could be resent from the new account once the login expired.
- After switching accounts, the previous account's background login refresh switched you back to it.
- If the app was closed while removing the current account, the accounts could fail to load on the next start.
- Viewing the same artwork again while its history was syncing to pixiv kept that view from syncing.
- A download saved to the album started over from the beginning when you tapped Resume after pausing it.
- Tapping Cancel right after Pause left the download stuck at Canceling.
- Canceling a paused download left its partly downloaded file behind, taking up storage.
- Unfinished files from a download cut short by closing the app were never cleaned up.
- An update download continued after restarting the app ignored Cancel and still opened the installer once finished, and could stay on "Downloading and verifying…" if it finished quickly.
- When a connection stalled midway, a download could hang forever, and so could the network probe.
- When a connection stalled and then dropped, every image loading at that moment failed; after a few times no image loaded until the app was restarted.
- An image that failed to load once could keep failing, through retries and reopening, until the cache was cleared.
- Removing several works from Watch later with Manage and leaving the page right away left them in the list.
- With the image source on Auto and a mirror picked, stamps in comments and the default avatar of users without one did not load.
- In transitions between cards, the work page and the viewer, the image was covered or cut off by the wrong bar, and a blank strip opened behind the bars as they slid away on the way back.
- Going back from a work to a feed you can pull to refresh (Recommended, Rankings, search results, user pages) showed a blank strip under the sliding top bar and cut the cards off flat.
- The top and bottom bars flashed at the moment they settled as a card opened or returned.
- Quick flicks in a row while a list was still scrolling made it go faster and faster.
- Tapping the same card twice quickly also opened the image viewer.
- A sideways swipe while a page was still closing moved to the next bottom-bar destination.
- A card or follow menu opened during a refresh did nothing when you picked from it after the refresh finished.
- A failed bookmark or follow gave no reason if its button had already scrolled off screen, and a failed bookmark sheet reported it twice.
- Pixiv novels showed the page breaks and chapter titles set by their author as raw "[newpage]" and "[chapter:…]" text.
- With a large system font, the end of every novel line was cut off.
- Novels whose text contains ",]" lost the comma.
- Show more overlapped a collapsed caption made of short lines.
- Opening a user's novel works briefly showed the previous user's novels.
- Editing your profile after switching accounts could change the other account.
- Adding an account could bounce you back to the home page partway through.
- Right after switching accounts, the previous account's watchlist, user pages, series, novels, bookmark tags and recent works could briefly show.
- Bookmarks, follows and Watchlist changes queued offline were sent as another account after a switch.
- Adding back a removed account sent the bookmarks and follows it had queued offline before it was removed.
- Leaving the login page partway through could still log you in.
- Logging out of Doubao kept the web login when secure storage failed.
- Closing the bookmark sheet while it was saving also closed the page under it.
- A comment that failed to send after its box was closed gave no message.
- Tapping confirm twice in an artist's batch download also closed the artist's page.
- Downloading to a chosen folder failed on some devices, or produced file names with a doubled extension.
- Failed downloads had a misplaced Details button.
- Sharing an image or link, picking an image for reverse image search, and importing a backup or a local novel could freeze the app.
- Going back from an image shared into the app at cold start stayed on the splash screen.
- A failed local novel import left behind a file the library did not list.
- Typing while a setting was saving (translation credentials, album name, naming template, custom image source, DoH/ECH) was overwritten by the saved value, or counted as saved.
- Saving your profile while a picked image was still loading sent it without the image.
- When the profile editor could not read your profile, it showed only a line of English error text.
- A damaged record of the automatically chosen image source kept new results from being saved.
- On some systems, launching the app wrote unrelated errors to the crash log.
- An update check at launch that failed before sending its request waited a day before trying again.
- After the app was restored in the background, paging on the detail page jumped back to the first work.
- If Android closed the app in the background while the image viewer was open, returning to it showed No images to display for good.
- When an artwork failed to load in the image viewer, it said there were no images to display, with no way to retry.
- JPEGs with large EXIF data could not be used for reverse image search or as an avatar.
- Cancelling the picker in reverse image search dropped the image you had picked and switched back to SauceNAO.
- Zooming with the keyboard or mouse wheel went past 6x.
- More by this artist on a work page showed muted works.
- A search or ranking whose loaded works were all filtered out said No search results and stopped loading.
- After you switched a block on, a list restored from what it last saved still briefly showed blocked works.
- A search limited to the last day, week or month stopped loading more after midnight.
- When a list topping up a short page got an invalid or repeated next-page link, it gave no error and looked finished.
- Coming back to the search home after Android closed the app made the list spring back up when the trending tags loaded.
- pixiv:// links in captions did not open.
- Deleting a browsing history entry skipped one further down, and a failed history read showed No browsing history with no retry.
- Deleting a history entry while browsing stopped the rest of the history from loading.
- History entries deleted while a page was loading came back with the next page.
- Exporting a backup while browsing could duplicate some history entries and leave others out.
- With a large font and the keyboard up, the bookmark sheet pushed its confirm button off screen.
- A long list of drawing tools overflowed the artwork's info row.
- Under TalkBack, the bottom action bar did not come back after closing the comment box or downloading selected pages of a work.

## [1.0.0] - 2026-10-25

第一个正式版。The first stable release.

### 新增

- **底栏页面左右滑动：** 各页面的首页可以左右滑动切换到相邻页面。带标签的页面先切标签，到第一个或最后一个标签后再滑一次才换页；点进去的二级页面和平板的侧边导航栏不受影响。
- **在作品页直接写评论：** 点评论区的输入框即可在当前页书写，发出后新评论立刻出现、评论数加 1，没发出的内容会保留为草稿。作者关闭评论的作品会直接提示「作者已关闭评论」。
- **⋮ 菜单加入常用操作：** 作品页的 ⋮ 菜单可以编辑收藏、加入稍后再看、屏蔽作品或作者，用户主页的 ⋮ 可以屏蔽该用户，不必再长按。
- **网格密度：** 浏览设置新增「网格密度」，可选紧凑 / 标准 / 宽松，手机上分别为 3 / 2 / 1 列，宽屏按比例增加；默认的「标准」与原来一致。
- **重置筛选、开启历史：** 带筛选的搜索没有结果时，可以一键重置筛选；浏览历史关闭时，历史页会说明原因并提供开启按钮。
- **搜索多关键词补全：** 关键词用空格（半角或全角）隔开，补全只针对光标所在的词，已输入的词不再出现在建议里；点建议直接搜索整串，点 ↖ 填入后自动补空格，接着输入下一个词。写完的词显示为圆角标签块，搜索结果页顶部也一样。

### 变更

- **「我的」页改版：** 顶部是头像、名字、用户 ID 和 Premium 标识，点击打开个人主页，账号管理是旁边单独的按钮；下方是最近看过的作品，点开后可按这一排的顺序左右切换，封面像信息流卡片一样飞入详情页、返回时飞回，看完回来这一排会平滑重排；收藏、关注、下载任务等入口改为列表；设置和关于移至页面末尾，不再在页面上直接铺开各项设置。
- **设置首页：** 搜索框移至顶部，各项图标按类别上色（开启「跟随系统取色」时也不变）。
- **作品详情页重新排版：** 浏览数、收藏数、完整发布时间与 AI 生成、R-18 / R-18G 标记并入同一行；作者显示为整张可点的卡片（小说信息页同）；尺寸、页数、绘画工具和可复制的 ID 移到标签之后；过长的标签单行省略，标签不再用强调色；简介折叠时「展开」跟在末行行尾，点简介任意处即可展开。短横图下方不再留白，展开多图后同一时刻只显示一个「收起」。
- **写评论不再锁住页面：** 点输入框以外的地方会收起输入框，同时照常滚动或打开点到的内容。输入框跟着键盘或表情面板一起升降；表情和贴纸面板与键盘同高，来回切换时输入框不再跳动。
- **页面转场：** 所有页面改为从侧边横推进入、横推退出。打开作品时先铺开背景再显示内容，同时图片飞入，返回时顺序相反。
- **返回可以中途掉头：** 页面或作品打开途中按返回，动画从当前位置平滑掉头，不再先慢慢退回、再猛地冲出屏幕；返回途中可以直接点按和滑动下面的页面，画面实时跟随。「我的」页各入口的打开动画统一。
- **图片飞入动画：** 从卡片打开作品时，图片整体缩放，卡片裁掉的部分随动画淡入；飞到一半不再顿一下；图片从顶栏和底栏下面穿过，栏随之滑开、滑回。超长图（列表里显示为正方形缩略图）也有飞入动画。再次打开加载过的作品时，飞行中的图片不再中途换图。动画被返回打断时，图片不再盖住栏或被栏截断；卡片角标与详情页的返回按钮、页码、操作栏在飞行时隐去，落定后淡入。
- **切换标签更跟手：** 左右滑动更容易触发，偏离水平 40° 以内都算，不再变成列表上下抖动；松手后顺着手指的速度走，不甩动时过半才翻页，落定后才切换标签；第一个、最后一个标签往外拉会回弹。
- **详情页与列表的滑动：** 作品详情和看图页中，偏竖向的滑动会滚动内容，不再误翻页；大图页下拉关闭、全景长图横向拖动不再被翻页抢走；左右翻页约 0.3 秒到位。慢慢拖动列表时，越过起拖距离立即跟手，不再先「粘」一下；卡片在列表开始滚动时立即松开按压效果。
- **底栏跟随滚动：** 首页底栏和作品页底部的操作栏跟随滚动逐像素移出、移回，慢慢滑也会动；滚动停下后停在离得近的一端。
- **主页下拉刷新：** 作者主页和个人主页的标签页下拉刷新时，列表像首页信息流一样整体下移，刷新圈出现在标签栏和列表之间。
- **返回到启动页：** 在其他页面按返回会回到你设的启动页（选了「上次停留的页」时，回到这次打开 App 时进入的页面），「再按一次退出」也在启动页出现。
- **配色：** 底色和灰色改为带一点粉调的暖灰；浅色模式下文字、链接和选中标记改用更深的玫红，按钮等实心填充仍是品牌粉配白字；作品上的返回、更多等图标改为中性色；已收藏的心改为固定的红色；成功、警告、错误等状态色更易读。
- **阴影代替分隔线：** 底栏、评论输入栏和各页顶栏（含标签栏、个人主页的标签条）与内容之间改用阴影分隔。
- **能点的地方看得出来：** 系列页和 pixivision 文章里的作者名后带 ›；小说阅读器底栏的页码进度改为胶囊按钮，点开进度面板；关于页里打开应用内页面的行带 ›，外部链接带外链图标；搜索用户结果的账号统一显示为「@账号」。
- **下载任务：** 最新的任务排在最上面，多页作品的分组按加入时间与单张任务混排；「清除已完成」移到 ⋮ 菜单。
- **用词和样式统一：** 翻译未开启时显示为提示，不再显示成错误；评论区标题的评论数、「查看全部」「恢复默认」等按钮用词和下载图标在各处一致，中文统一使用直角引号和全角括号；搜索筛选面板改为按间距分组；带标签的页面上，空状态、加载中和出错提示与其他页面同高。
- **更流畅：** 拖动和慢速滑动时画面每帧移动更均匀；首页各页面和左右相邻的标签在画面静止时提前建好，第一次切过去不再卡；信息流提前三屏加载下一页，加载时已显示的卡片不再全部重建；列表、小说阅读器和作品详情的文字提前在帧间排好；有屏蔽作品的列表滑动更顺；小说阅读器呼出工具栏、评论页弹出键盘时不再连带重建被盖住的页面；在骁龙 8 至尊版这类没有小核的手机上，绘制不再只挤在两颗超大核上。
- **看大图更快、更省内存：** 滑过的原图不再继续下载；大图先按屏幕两倍宽解码，放大后才解码整张原图。
- **开着无障碍服务也流畅：** 列表滚动和页面切换后的动画期间不再推送无障碍信息；读屏和辅助工具最迟 2 秒内拿到最新内容。
- **安装包体积减半：** arm64 约 31 MB → 15 MB，下载和应用内更新更快；安装后占用的存储空间会多一些（原生库在安装时解压）。Android 上的登录页和以图搜图结果页改用与桌面端相同的 WebView 组件，使用上没有变化。

### 移除

- 「动效与触感」里的「页面转场样式」选项。
- 页面里解释用法的说明文字：翻译、账号、下载、备份、网络、底栏和动效设置里的说明段落，排行分类面板和以图搜图里的提示，登录页剪贴板登录下的操作说明（凭据风险提示保留），稍后再看、追更、浏览历史和屏蔽列表空状态的第二行。说明选项作用的副标题、状态和确认提示照旧。

### 修复

- 作品详情页把已关注的画师显示为「关注」，要先进一次画师主页才正确。
- 在详情页左右切换时，旁边没看过的作品也被记进浏览历史（并同步到 pixiv）。
- 浏览历史页打开后一直只显示第一次读到的列表，不随新记录更新。
- 长按菜单关闭时，底栏跳到菜单上面。
- 从信息流打开作品后开关大图时，图片偶尔飞向别的位置。
- 作品详情页长按多选时，短横图等部分比例的首图，选择按钮跑到图片右侧中间，而不在右上角。
- 部分缩略图右边缘出现一条绿线。
- Windows / Linux 触屏设备上，新打开页面的第一次触摸拖不动列表。
- 用户协议里图片源设置的位置写错，第三方服务一节漏了小说翻译、豆包、ascii2d 和 TinEye。

### Added

- **Swipe between bottom bar pages:** The main screen of each bottom bar page can be swiped to the next one. On a page with tabs, a swipe changes tabs first and moves to the next page from the first or last tab; pages opened from them and the tablet's side rail are unaffected.
- **Comment on the artwork page:** Tap the comment input and write in place; a sent comment shows at once with the count updated, and unsent text is kept as a draft. When the author has turned comments off, the page says so.
- **More in the ⋮ menu:** The artwork page's ⋮ menu can edit the bookmark, add to Watch later and mute the work or its author, and a profile's ⋮ can mute the user, all without a long press.
- **Grid density:** Browse settings add Compact / Standard / Comfortable, with three, two or one column on a phone and proportionally more on wider screens; Standard matches the previous layout.
- **Reset filters, turn on history:** An empty search with filters on offers to reset them, and an empty history explains when recording is off and offers to turn it on.
- **Completion for each search keyword:** Separate keywords with a space (half or full width); suggestions follow the keyword at the cursor and leave out keywords already typed. Tapping a suggestion searches the whole query; ↖ puts it in and adds a space for the next keyword. Finished keywords show as rounded pills, also at the top of the results page.

### Changed

- **Redesigned Me tab:** At the top are your avatar, name, user ID and a Premium badge, which open your profile, with account management as its own button beside them. Below are the works you viewed last: opening one lets you swipe through the row, its cover flies into the artwork page and back like a feed card, and the row reorders smoothly when you return. Bookmarks, following, download tasks and the other entries are a list, and Settings and About sit at the end instead of the settings groups being laid out on the page.
- **Settings index:** The search field is at the top, and icons are colored by category, even with Use system colors on.
- **Reorganized artwork page:** Views, bookmarks, the full posting time and the AI-generated and R-18 / R-18G marks share one line; the author is a card you can tap anywhere (also on the novel info sheet); size, pages, drawing tools and a copyable ID come after the tags; a long tag stays on one line, and tags no longer use the accent color; a folded caption ends its last line with "Show more" and expands on a tap anywhere. A short, wide first image no longer leaves a gap below it, and an expanded set shows one "Collapse" at a time.
- **Writing a comment no longer locks the page:** A touch outside the input puts it away and still scrolls or opens what it landed on. The input rises and falls with the keyboard or emoji panel, and the emoji and stamp panels match the keyboard's height, so the input no longer jumps when switching.
- **Page transitions:** Every page slides in from the side and slides back out. Opening an artwork first lays down the page's background, then shows its content while the image flies in; going back reverses the order.
- **Back can turn around midway:** Pressing back while a page or an artwork is still opening reverses the animation smoothly from where it is, instead of creeping back and then shooting off the screen. During back, the page underneath can already be tapped and scrolled, and shows it as it happens. Every entry on the Me tab opens the same way.
- **Image fly-in:** Opening a work from a card scales the whole image, and the part the card cropped fades in; the animation no longer stalls halfway, and the image passes under the top and bottom bars, which slide away and back with it. Very tall works, shown as square thumbnails in lists, fly in too. A work opened again no longer swaps its image mid-animation. When back interrupts the animation, the image no longer covers the bars or gets cut off by them; card badges and the artwork page's back button, page counter and action bar hide while the image moves and fade in once it lands.
- **Tab swipes follow the finger:** Sideways swipes register more easily, anywhere within 40° of horizontal, instead of jiggling the list. After release they carry on at the finger's speed; a slow release switches only past halfway, the tab changes when the swipe lands, and the first and last tab bounce when pulled outwards.
- **Swipes on the artwork page and in lists:** On the artwork page and in the image viewer, a swipe leaning towards vertical scrolls the content instead of turning the page; pull-to-dismiss in the viewer and sideways scrolling of a panorama no longer lose the swipe to the pager; paging lands in about 0.3 s. A slow drag moves a list as soon as it starts, without a sticky start, and a pressed card lets go as soon as its list starts scrolling.
- **Bars follow the scroll:** The home bottom bar and the artwork page's action bar slide out and back pixel for pixel with the scroll, slow scrolling included, and settle at the nearer end once the scroll stops.
- **Pull to refresh on profiles:** Pulling to refresh on a profile's tabs slides the list down as on the home feed, with the indicator between the tabs and the list.
- **Back returns to the start page:** Back from another page returns to your start page (with "Last used page", the page the app opened on this time), and "Press back again to exit" appears there.
- **Colors:** Backgrounds and grays are warm grays with a hint of the brand pink; in light mode, text, links and selection marks use a deeper rose, while filled buttons keep the brand pink with white text; icons over artwork, such as back and more, are neutral; a bookmarked heart is a fixed red; success, warning and error colors are easier to read.
- **Shadows instead of lines:** The bottom bar, the comment input and the top bars (with their tabs, and a profile's tab strip) are set off the content by a shadow instead of a line.
- **What can be tapped looks like it:** An author's name on a series page or a pixivision article ends in ›; the page readout in the novel reader's bottom bar is a pill button that opens the progress sheet; on the About page, rows that open a page end in › and the external link ends in an external-link icon; a user search result shows the account as "@account".
- **Download tasks:** The newest are listed first, and multi-page groups sit among single downloads by when they were added; "Clear completed" moved into the ⋮ menu.
- **Consistent wording and look:** Translation that is off shows a notice instead of an error; comment counts in section titles, button wording such as "See all" and "Restore defaults", and the download icon are the same everywhere; the search filter sheet groups by spacing; on pages with tabs, the empty, loading and error states sit as high as on other pages.
- **Smoother:** Drags and slow scrolls move evenly every frame; the other home pages and the tabs either side are built ahead while the screen is still, so the first switch to them no longer stutters; feeds load the next page three screens before the end, and loading no longer rebuilds the cards already shown; text in lists, the novel reader and artwork pages is laid out between frames ahead of time; feeds with muted works scroll more smoothly; showing the novel reader's bars and raising the keyboard on the comments page no longer rebuild the pages underneath; on phones without little cores, such as the Snapdragon 8 Elite family, drawing no longer runs only on two prime cores.
- **Faster, lighter image viewer:** Originals you swipe past stop downloading, and a page is first decoded at twice the screen width and in full only once you zoom in.
- **Smooth with accessibility services on:** Scrolling and the animations after a page change no longer push accessibility updates mid-motion; screen readers and assistive tools get the latest content within 2 seconds.
- **Half-size APK:** arm64 goes from about 31 MB to 15 MB, so downloads and in-app updates are faster; the installed app takes somewhat more storage, as its native libraries are extracted on install. On Android, the login page and reverse image search results use the same WebView component as the desktop app, with no visible change.

### Removed

- The page transition style option in Motion & haptics.
- Notes that explained how pages work: the paragraphs in the translation, account, download, backup, network, bottom bar and motion settings, the hints on the ranking category sheet and in reverse image search, the how-to line under clipboard sign-in on the login page (its credential risk note stays), and the second line of the Watch later, watchlist, history and mute list empty states. Subtitles that say what an option does, states and confirmations stay.

### Fixed

- The artwork page showed a followed artist as not followed until their profile had been opened.
- Paging through the artwork page recorded the works beside the one you viewed in your history (and synced them to pixiv) without them being viewed.
- The history page kept showing the list it first read instead of new entries.
- Closing a long-press sheet popped the bottom bar on top of it.
- Opening or closing the image viewer after opening a work from a feed sometimes flew the image to the wrong place.
- In selection on the artwork page, the badge on a short, wide first image, and on some other shapes, sat halfway down its side instead of in the top corner.
- A green line appeared along the right edge of some thumbnails.
- On Windows and Linux touchscreens, the first touch on a newly opened page did not drag the list.
- The user agreement gave the wrong place for the image source setting, and its third-party services section left out novel translation, Doubao, ascii2d and TinEye.

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

[Unreleased]: https://github.com/Lopution/Parfait/compare/v1.1.1...HEAD
[1.1.1]: https://github.com/Lopution/Parfait/releases/tag/v1.1.1
[1.1.0]: https://github.com/Lopution/Parfait/releases/tag/v1.1.0
[1.0.0]: https://github.com/Lopution/Parfait/releases/tag/v1.0.0
[0.10.0]: https://github.com/Lopution/Parfait/releases/tag/v0.10.0
[0.9.0]: https://github.com/Lopution/Parfait/releases/tag/v0.9.0
