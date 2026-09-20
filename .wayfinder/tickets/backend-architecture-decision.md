---
title: 混合后端架构边界拍板
slug: backend-architecture-decision
labels: [wayfinder:grilling]
status: open
assignee:
blocked-by: [baseline-profile]
created: 2026-09-20
---

## Question

**libgit2 后端从哪里切入 neogit,读写边界具体划在哪?** 需要拍板:

1. **接缝选择**:以 `repository.lua` 的 `update_*` 协议为界(新后端只须产出同形 `NeogitRepoState`,UI 零改动),还是在 `lib/git.lua` 元表下做模块级双实现,或引入新的 service 层?(基线数据会指出真正的热点在哪里,从而决定接缝的深浅。)
2. **ProcessResult 等价物**:popup action 大量检查 `result:success()/stdout/stderr`,libgit2 后端提供什么样的结果对象?错误信息(GIT_ERROR 码 → 用户可读消息)怎么映射?
3. **裸 `git.cli` 收拢**:popups 里约 20 处直接调 `git.cli.*` 的用法,收拢到 `lib/git/*` 模块函数的方案(这是任何后端抽象的前置清理)。
4. **写路径边界**:add/reset/checkout/stash/commit 这类一次性写命令迁不迁 libgit2?(迁 → 必须处理 GPG 签名链路与 hooks 语义,见地图 fog;不迁 → GPG/hooks 雾散。)此决定直接决定地图上哪些雾毕业成票。
5. **直读 `.git` 内部文件的状态模块**(rebase/sequencer/merge/bisect 状态、config mtime 缓存)在双后端下如何统一语义。

输入:`性能基线剖析` 的数据 + `.wayfinder/assets/neogit-git-layer-survey.md` 的接缝分析。
