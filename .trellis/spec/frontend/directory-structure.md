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
│   │   ├── follow_switch_button.dart  跨 feature 复用的 FollowSwitchButton
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
- **共享 widget 的所有权**：跨 feature 使用的 widget 由 `lib/app/widgets/` 持有；feature 只能从
  `app/widgets` 引入，不能直接引入另一个 feature 的实现。例如 profile 与 search 共用
  `FollowSwitchButton`，其关注状态仍由 `core/user/` 的 `FollowStore`/`followActionsProvider` 持有。
- **新增跨层契约（host/header、偏好键、i18n 访问、反馈、日志、JSON 读取）**：先找 owner，
  一律派生自 owner，不新建第二份声明（见 `frontend/` 各契约文档）。

## Cross-Feature Shared Widget Contract

### 1. Scope / Trigger

Use this contract when the same interactive widget is rendered by two or more
feature directories. The widget belongs to the app component layer; its data
and mutation owner remains in `core/`.

### 2. Signature

```dart
const FollowSwitchButton({
  required int userId,
  required String userName,
  String userAccount = '',
  bool compact = false,
});
```

### 3. Contracts

- `FollowSwitchButton` is implemented in `lib/app/widgets/` and may depend on
  `core/user/` and app-level feedback/theme helpers.
- Feature callers pass IDs and display values; they do not pass a feature
  widget or maintain a second follow boolean.
- Confirmed, pending and failed states are read from `FollowStore`; mutations
  go through `followActionsProvider`.

### 4. Validation & Error Matrix

| Condition | Required behavior |
|---|---|
| Widget is used by multiple features | Keep one implementation under `app/widgets/` |
| Follow request is pending | Render the store-owned pending state and keep the confirmed value authoritative |
| Follow request fails | Surface the store error through the existing app feedback path |
| A feature imports another feature's widget | Move the shared widget to `app/widgets/` and update both callers |

### 5. Good / Base / Bad Cases

- Good: profile and search import `app/widgets/follow_switch_button.dart` and
  read the same `FollowStore` entry for a user.
- Base: a feature-only widget stays under that feature's `widgets/` directory.
- Bad: search imports `features/profile/follow_switch_button.dart` because
  the button was first implemented for the profile page.

### 6. Tests Required

- `test/architecture/layering_test.dart` asserts zero cross-feature edges and
  zero unlisted shared-widget files.
- Profile and search widget tests assert the button is still rendered at its
  existing compact/full sizes and that confirmed/pending/error transitions
  remain observable.

### 7. Wrong vs Correct

Wrong:

```dart
import '../profile/follow_switch_button.dart';
```

Correct:

```dart
import '../../app/widgets/follow_switch_button.dart';
```

## Visibility and Color Ownership

- A top-level declaration referenced only inside its defining library should be
  private (`_Name`) unless it is a public signature, a tested compatibility
  surface, or a cross-library contract. Renaming must preserve observable
  strings such as exception `toString()` values.
- Stable semantic colors belong in `FuncTokens` (for example
  `FuncTokens.transparent` or an exact Material shade). Preserve the rendered
  ARGB value when replacing `MaterialColor.shade*` expressions.
- Direct `Colors.black`/`Colors.black38` is allowed only for a deliberately
  replica-locked canvas or scrim, with a nearby comment explaining why it is
  independent of the app theme.

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
