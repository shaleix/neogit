---
title: libgit2 版本分布与 ABI 风险调研
slug: libgit2-versions
labels: [wayfinder:research]
status: open
assignee: research-subagent/libgit2-versions
blocked-by: []
created: 2026-09-20
---

## Question

neogit 计划 `ffi.load` 系统安装的 libgit2(fugit2 模式),必须先弄清:**2026 年主流环境预装的 libgit2 版本分布如何?libgit2 的 ABI 稳定性承诺与已知破坏性变迁(如 git_buf→git_str)对手写 cdef 的威胁有多大?运行时版本探测有哪些现成做法?**

具体要查:
1. 主流分发渠道当前提供的 libgit2 版本:Debian stable/testing、Ubuntu LTS、Fedora、Arch、Homebrew、nixpkgs(各自默认/可装的 1.x/2.x 版本)。
2. libgit2 官方的版本与 ABI 兼容策略(semver 承诺、1.x 内 ABI 稳定性、2.0 计划或已发生的破坏性变更)。
3. 已知 ABI 断裂点清单(结构体布局变更、字段增删、回调签名变化),并对照 fugit2 手写 cdef(`~/workerspace/fugit2.nvim/lua/fugit2/core/libgit2.lua`,约 180 个函数声明)的暴露面评估风险。
4. 运行时探测方案:`git_libgit2_version()`、符号级 pcall 探测、加载前 dlopen 探测等实践;fugit2 是否有可借鉴的失败降级路径(看起来没有——这是差距)。

产出:版本分布表 + ABI 风险清单 + "最低支持版本 + 运行时探测"的策略建议输入,供绑定与分发决策 ticket 使用。
