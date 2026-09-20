---
title: 绑定与分发方案拍板
slug: binding-distribution-decision
labels: [wayfinder:grilling]
status: open
assignee: main-session/ses_f41e510deffeMfC1qkcd4Q5YVY
blocked-by: [libgit2-versions, binding-poc]
created: 2026-09-20
---

## Question

**libgit2 绑定的获取与库的分发方案是什么?** 需要拍板:

1. **最低支持版本**:基于版本分布调研,声明支持哪个 libgit2 起步版本?对更旧版本的行为(降级 CLI?硬报错?)。
2. **库获取方式**:fugit2 模式(用户系统装 libgit2,插件 `ffi.load` + `setup({ libgit2_path = ... })` 覆盖)是否照搬?是否需要预编译产物兜底?(倾向 fugit2 模式,但要看过 PoC 与版本调研后再定。)
3. **运行时探测与降级**:版本/ABI 探测放在哪个时机(setup 时?首次打开 repo 时?)、探测失败的降级与用户提示如何设计,才能兑现"auto 切换、不可用自动降级 CLI"的既定约束。
4. **vendor 边界**:fugit2 绑定层拷进 `lua/neogit/lib/git2/` 的范围(哪些模块要、哪些不要,如 gpgme 先不带)、MIT 归属声明怎么留。

输入:`libgit2 版本分布与 ABI 风险调研` 的版本分布与风险清单、`libgit2 直连 PoC` 的加载/对齐/收益证据。
