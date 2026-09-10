# Pixiv Func

SPDX-License-Identifier: AGPL-3.0-only

Pixiv Func 的现代化复刻项目，以原版的内容体验与交互行为为基线，使用当前稳定版 Flutter 与现代 Android 技术栈持续演进。

> 项目目标：保留可验证的产品行为，同时让组件、主题与导航模型跟随现代 Flutter 演进。

## 项目原则

- Replica v1 的用户可感知视觉冻结阶段已结束；页面结构、手势、信息密度与交互节奏以既有行为契约为基线持续改进。
- Func 组件层承载可复用的 feed、图片、状态、刷新与动作组件；feature 页面负责组合业务内容，不重复实现共享交互。
- 使用 Material 3 主题与 `FuncTokens` 统一颜色、字号、间距和组件状态，保持 light/dark 与本地化页面的一致性。
- 使用现代导航交互模型：`go_router` 的 typed route、独立 tab 栈、路由与滚动恢复、Predictive Back，以及由 Hero 驱动的查看器返回。
- 内部实现允许彻底现代化：网络、缓存、状态管理、数据库、下载器、Ugoira、原生桥接等均可重写。
- 不把旧 Flutter/Gradle 环境作为目标，仅将原版源码作为行为与视觉参考。
- Android 首要目标为 API 36，并跟随 Flutter stable 当前版本维护。

## 原项目与许可证

本项目基于原 Pixiv Func 项目的公开源码进行现代化复刻。原项目作者为 git-xiaocao（小草），原项目采用 GNU Affero General Public License v3.0。

本仓库同样采用 AGPL-3.0-only 许可，并保留原项目归属与修改说明，详见
`NOTICE` 和 `LICENSE`。

## 当前状态

Replica v1 的视觉冻结阶段已完成，当前进入 Func 组件层、Material 3 和现代导航模型的持续维护；项目暂未提供可用发行版。
当前状态和已知验证边界记录在 [Trellis task evidence](.trellis/tasks/) 与
[Android release artifacts 规范](.trellis/spec/backend/release-artifacts.md) 中。
