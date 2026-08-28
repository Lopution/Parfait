# Pixiv Func

SPDX-License-Identifier: AGPL-3.0-only

Pixiv Func 的现代化复刻项目，在尽量保留原版 UI、交互逻辑与使用体验的基础上，使用当前稳定版 Flutter 与现代 Android 技术栈重新实现。

> 项目目标：先复刻体验，再逐步迭代。

## 项目原则

- 第一阶段冻结用户可感知体验：页面结构、导航、手势、信息密度、视觉风格与交互节奏尽量保持原版。
- 内部实现允许彻底现代化：网络、缓存、状态管理、数据库、下载器、Ugoira、原生桥接等均可重写。
- 不把旧 Flutter/Gradle 环境作为目标，仅将原版源码作为行为与视觉参考。
- Android 首要目标为 API 36，并跟随 Flutter stable 当前版本维护。

## 原项目与许可证

本项目基于原 Pixiv Func 项目的公开源码进行现代化复刻。原项目作者为 git-xiaocao（小草），原项目采用 GNU Affero General Public License v3.0。

本仓库同样采用 AGPL-3.0-only 许可，并保留原项目归属与修改说明，详见
`NOTICE` 和 `LICENSE`。

## 当前状态

项目仍在进行 Replica v1 的集成验收，暂未提供可用发行版；当前状态和已知
验证边界记录在 Trellis task evidence 中。
