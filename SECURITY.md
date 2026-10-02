# 安全策略 Security policy

## 支持的版本

只有[最新正式版本](https://github.com/Lopution/Parfait/releases/latest)会收到安全修复。报告前请先确认问题在最新版本上仍然存在。

## 报告漏洞

请通过 GitHub 的[私密漏洞报告](https://github.com/Lopution/Parfait/security/advisories/new)提交，不要开公开 Issue。也请不要在任何公开的地方贴出日志、登录凭据或复现用的文件。

报告中请写明：受影响的版本、复现步骤、可能造成的影响；有概念验证的话一并附上。

Please report vulnerabilities privately through [GitHub private vulnerability reporting](https://github.com/Lopution/Parfait/security/advisories/new). Do not open a public issue.

## 关注的问题

- 应用内更新：更新清单的签名校验、APK 的哈希与签名证书校验
- 登录凭据的存储与导出
- 网络连接与 TLS 校验，包括直连与兼容通道
- 下载文件的路径处理

## 不在范围内

- pixiv 服务本身的问题，请直接报告给 pixiv
- 需要 root 权限或物理接触设备才能实施的攻击
- 来自 GitHub Releases 以外渠道、可能已被改动的安装包

## 响应

这是个人维护的项目，会尽力处理，目标是在 7 天内回复。确认的问题修复并发布后，会在 Security Advisories 中公开说明。
