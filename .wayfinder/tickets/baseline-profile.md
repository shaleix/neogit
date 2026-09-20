---
title: 性能基线剖析
slug: baseline-profile
labels: [wayfinder:research]
status: open
assignee:
blocked-by: []
created: 2026-09-20
---

## Question

在锁定混合后端架构之前,需要用数据回答:**neogit 关键读操作(status refresh、log、diff)的耗时到底花在哪——git 子进程 spawn、CLI 输出解析、还是刷新/UI 链路?大仓库下 libgit2 直连(经 fugit2 绑定层 FFI 调用)与 CLI 的延迟差有多大?**

具体要测:
1. 构造(或选取)一个有压力的本地仓库(如数千文件、数百提交),保持可控可复现。
2. 测量一次 status buffer refresh 全链路:触发了多少次 git 子进程 spawn、每次 spawn 的固定开销、解析耗时占比、UI 渲染占比。
3. 测量 `git status --porcelain=2 -z`、`git log`、`git diff` 裸命令耗时,与经 fugit2 绑定层调用 `git_status_list_new` / revwalk / diff 的耗时做同仓库对比。
4. 结论要能支撑取舍:如果瓶颈不在 spawn 而在解析或刷新链路,架构重点就不同。

产出:可复现的测量方法 + 基线数据表(操作 × 耗时 × spawn 次数),作为后续架构决策与迁移验收的对照基准。

背景资产:`.wayfinder/assets/neogit-git-layer-survey.md`(刷新链路与 spawn 点位)、`.wayfinder/assets/fugit2-libgit2-survey.md`(绑定层用法)。
