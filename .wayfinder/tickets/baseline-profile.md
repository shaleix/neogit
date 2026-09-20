---
title: 性能基线剖析
slug: baseline-profile
labels: [wayfinder:research]
status: closed
assignee: research-subagent/baseline-profile
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

## Resolution

完整报告:[`.wayfinder/assets/baseline-report.md`](../assets/baseline-report.md)(复现脚本与原始数据在 `baseline-profile-data/`)。核心结论:

- **瓶颈不在解析**(<5%):warm refresh ~187ms 中,status 解析仅 2.6ms、log record.decode(200 commits)22.5ms。构成 ≈ 17% spawn 固定开销(9 spawn × ~3.5ms)+ 32% git 实际工作(其中 1/3 是冗余:`status --porcelain=2 -b` 每刷新跑 3 遍、`log -1 %s` 跑 2 遍)+ 27% UI redraw + 21% 编排/深拷贝/2 核争抢尾部。
- **libgit2 直连(经 fugit2 绑定)对照**:status 打平(~29ms vs CLI ~27ms);log 7×(4.4ms vs 32ms 含解析);refs/branch ~100×(0.05ms vs 5-9ms);diff 必须走 `tree_to_index + index_to_workdir` 组合(~32ms),直接 `tree_to_workdir` 是反模式(259~564ms)。理论全 refresh 收益 ≈ 2~3.3×(spawn 9→2),非数量级。
- **架构输入**:`update_*` 协议接缝正确;收益排序 refs/branch > log > repo 探测 > status;stash/describe 无绑定须留 CLI;迁移前可先在 CLI 框架内消灭 3× status 冗余(省 20~45ms/刷新)。验收线:同规模仓库 spawn ≤ 2、warm ≤ 90ms。
- 勘误:`ProcessResult.time` 注解为 seconds,实为 ms。
