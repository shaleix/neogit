---
title: 混合后端架构边界拍板
slug: backend-architecture-decision
labels: [wayfinder:grilling]
status: closed
assignee: main-session/ses_f41e510deffeMfC1qkcd4Q5YVY
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

## Resolution

**六项决策全部拍板(2026-09-20,grilling 两轮):**

1. **接缝形态 = 并行后端模块**:`lib/git/` 下为同一 `update_*` 契约提供两套实现(CLI/libgit2),`repository.lua` 按**模块能力表**选择实现;auto 降级 = 全部解析到 CLI 实现;可逐模块灰度启用;popups/buffers 零感知。不采用模块内 if 分支、不新立 service 层。基线 §5.2.1 证实 update_* 协议正确且够用;27% redraw + 21% 编排成本换后端仍在——**增量渲染列入 spec 风险章节**(端到端 2× 的必要补充,不属本接缝)。
2. **结果对象 = 后端中立 GitResult**(`{ok, code, message}`):libgit2 后端把 GIT_ERROR 码映射为用户可读消息;CLI 后端内部保留 ProcessResult 并包一层;popup 调用点改写随 Phase 0 收拢一起做。不伪造 ProcessResult。
3. **Phase 0 = 收拢 + CLI 去冗余 + 重测基线**:~20 处 popups 裸 `git.cli` 收拢进模块函数(返回 GitResult);CLI 框架内去冗余(`status -b` ×3 → 共享 1 次、`log -1 %s` ×2 → 1 次,省 20–45ms/刷新,CLI 降级用户也受益);完成后重新测基线,迁移验收对照新基线。
4. **写路径边界 = 读 + index 写**:libgit2 写面 = stage/unstage(`git_index_add_bypath`/`git_index_remove_bypath` + `git_reset_default`)、hunk 级 stage/apply(`git_apply`)、`checkout -- file`(恢复工作区文件,无 hook)。**切分支留 CLI**(HEAD 移动 + 工作区重写 + post-checkout hook,libgit2 不跑该 hook);commit、stash、branch 删除等其余写全部留 CLI(stash 绑定经勘误确认存在,但非热点,留作后续可选项)。由此:~~GPG 签名链路~~与~~hooks 触发语义~~两个雾区议题**化解**(commit 不迁就无此二问题)。
5. **`.git` 内部文件直读保持现状**:rebase/sequencer/merge/bisect 进行中检测、config mtime 缓存继续直读文件——后端无关(交互流程留 CLI 且写这些文件,libgit2 写面只动 index),零改动零风险。
6. **长尾读操作 = 留 CLI**:`describe`(无绑定)、reflog 遍历(无绑定)、submodule 状态;迁移验收线沿用基线报告 §5.2.4(spawn ≤ 2、warm ≤ 90ms、log 视图 ≤ 15ms),**diff 禁用 `tree_to_workdir` 直连**(组合 `tree_to_index` + `index_to_workdir`,基线 §4.1)。

**给后续 ticket 的输入**:模块迁移优先级按基线收益排序 refs/branch(100×)→ log(7×)→ repo 探测 → status(收益主要来自消灭冗余与编排);vendor 目录落位(`lib/git/backends/` 旁)与能力表机制交由 spec 统一布线。
