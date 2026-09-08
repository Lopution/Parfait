# Directory Structure

> How frontend code is organized in this project (Dart, `lib/`).

---

## Overview

`lib/` 是三层架构，由 `test/architecture/layering_test.dart` 以 import 图断言（CI 执行）：

| 层 | 职责 | 可 import |
|---|---|---|
| `lib/app/` | 应用壳：`MaterialApp`、主题、共享 UI 基件（组件层）、路由门面 | `core`、`app` |
| `lib/features/<f>/` | 仅 widget / 页面 / 页面级 controller 的 UI 胶水 | `core`、`app`；features 之间**只能** import `lib/app/navigation/routes.dart` 门面 |
| `lib/core/<domain>/` | entity / repository / controller(Notifier) / store / platform 适配器 | `core`（同层）——**不得** import `features` 或 `app` |

唯一被批准的环：`lib/app/navigation/routes.dart`（路由门面）import 各 feature 页面入口，
页面 import 门面——这是唯一例外，并在 layering_test 中显式标注。

## Directory Layout

```text
lib/
├── main.dart                 进程入口
├── app/
│   ├── app.dart              应用壳（MaterialApp、路由表）
│   ├── startup_gate.dart     启动 gate（首帧等待项 = settings + 账号）
│   ├── theme/                func_tokens.dart（颜色/间距/字号 token）、replica_theme.dart
│   ├── motion/               replica_page_route.dart、hero_rect_clip.dart、motion_tokens.dart（时长/曲线单一来源）
│   ├── navigation/           routes.dart（门面：openIllust(context, id)…）、route_observer.dart、home_shell_metrics.dart
│   ├── widgets/
│   │   ├── feed/             illust_card.dart、feed_grid.dart（IllustFeedGrid + illustColumnsFor）、feed_states.dart
│   │   ├── pixiv_image.dart  PixivImage（decode 策略变体）、person_avatar.dart
│   │   ├── feedback.dart     showAppSnackBar（唯一 SnackBar 出口）
│   │   └── …                 其余共享基件（replica_button/scaffold/switch_tile/empty_state…）
│   └── icons/                应用图标字体
├── features/<feature>/       页面与页面级胶水（每 feature 一个目录）
│   ├── <feature>_page.dart   页面
│   └── widgets/              仅该 feature 专用的私有 widget
└── core/<domain>/            数据与平台层（entity/repository/controller/store/适配器）
```

## Module Organization

- **新增 repository/controller/entity**：一律放 `lib/core/<domain>/`，controller 与 repository 分文件；
  `features/` 不得出现 `*repository.dart`、`*_controller.dart`、`*_models.dart`（entity）。
- **新增页面**：放 `lib/features/<feature>/`；页面间导航经 `lib/app/navigation/routes.dart` 门面，
  不得直接 import 其它 feature 的页面文件。
- **新增共享组件**：先盘点是否存在 ≥3 处重复，再放入 `lib/app/widgets/`（组件层）；
  `features/` 不得定义 `_*Tail/_*Error/_*Empty/_*Card/_*Status/_*Placeholder` 之类与组件层同职责的
  私有 widget（layering_test 以名称模式检查）。
- **新增跨层契约（host/header、偏好键、i18n 访问、反馈、日志、JSON 读取）**：先找 owner，
  一律派生自 owner，不新建第二份声明（见 `frontend/` 各契约文档）。

## Naming Conventions

- 页面：`<name>_page.dart`，类 `<Name>Page`。
- core 域：目录名 = 域名（如 `core/search/`），文件按职责命名（`*_repository.dart`、`*_controller.dart`）。
- 共享组件：PascalCase 类名，目录按用途分组（`widgets/feed/`、`widgets/settings/`）。

## Examples

- `lib/app/widgets/feed/feed_states.dart`：`FeedTail`/`FeedEmpty`/`FeedError` 消费 `PagedFeedState`。
- `lib/app/navigation/routes.dart`：唯一允许 import 多个 feature 页面的文件。
- `lib/core/network/pixiv_client_identity.dart`：Pixiv 主机/头/UA 的单一 owner。

## Enforcement

- `test/architecture/layering_test.dart`：import 图断言 + 数据层文件检查 + 组件命名检查，
  白名单随收敛逐项删除，白名单为空是本重构（child C）的完成条件之一。
- CI `dart` job 运行 `flutter test`（含 layering_test）。
