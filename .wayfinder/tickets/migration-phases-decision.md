---
title: 迁移阶段划分拍板
slug: migration-phases-decision
labels: [wayfinder:grilling]
status: closed
assignee: main-session/ses_f41e510deffeMfC1qkcd4Q5YVY
blocked-by: [backend-architecture-decision, threading-refresh-decision, binding-distribution-decision]
created: 2026-09-20
---

## Question

**Spec 的主体骨架:迁移分几阶段、每阶段迁什么、每阶段怎么验收?** 需要拍板:

1. **阶段序列**:典型候选——Phase 0:收拢裸 `git.cli` 调用(清理性重构,与后端无关但为抽象铺路)→ Phase 1:vendor 绑定层 + auto 探测骨架 → Phase 2:status/refs 读路径切换 → Phase 3:log/diff/blame → Phase 4:写命令(若边界决策包含)→ 每阶段的入口/出口条件。基线数据决定 Phase 2 从哪个模块开始收益最大。
2. **每阶段验收标准**:性能对比基线的量化指标(如"status refresh P95 < X ms,spawn 次数 12→0") + 功能不回归的判定(rspec E2E + plenary 双后端跑)。
3. **回退策略**:每阶段如何保证 `kind = "cli"` 一键回退完整功能。
4. **写路径与雾的毕业**:本 ticket 定阶段时,把地图 Not yet specified 里因写路径边界而成形的项(GPG/hooks/取消/长尾读操作/测试矩阵)按需毕业成执行项或排除。

输入:前三个决策 ticket 的全部结论 + `性能基线剖析` 数据。

## Resolution

**四项决策拍板 + 完整阶段骨架(2026-09-20,grilling)——spec 的主体章节由此展开:**

**排序原则**:按基线收益倍数降序(refs 100× → log 7× → status 冗余/编排收益);量化门禁沿用基线报告 §5.2.4 方法与脚本(`assets/baseline-profile-data/`)。

| 阶段 | 内容 | 出口条件(验收) |
|---|---|---|
| **P0 清理与重测基线** | ~20 处裸 `git.cli` 收拢进模块函数(返回 GitResult);CLI 去冗余(`status -b` ×3→1 共享、`log -1 %s` ×2→1);重测基线入册 | popups 零直接 `git.cli`;rspec/plenary 全绿;spawn 9→6;新基线成为后续对照 |
| **P1 绑定基建(零行为变化)** | vendor 三文件(pin `7783d33`)+ overlay(soname 序列、`git_libgit2_version` cdef、版本 gate 1.7/1.8/1.9、枚举注入)+ 惰性探测/一次性提示/降级 + 同步执行器 + 每周期 Repository + 模块能力表(默认全 CLI) | 探测与降级路径可用;全部模块仍走 CLI、行为零变化;无 libgit2 的 CI 环境全绿 |
| **P2 读迁移 wave 1** | refs、branch 读半、rev_parse、log 近期(`update_recent` + `log -1`) | refresh spawn ≤4;refs/branch 列表交互零 spawn;rspec 双后端双跑全绿 |
| **P3 读迁移 wave 2** | `update_status`(含 rename 富模型字段);status 计算吸收 `-b` 数据消费方(pull/push/branch 头) | refresh spawn ≤2(stash list + describe 留 CLI);warm ≤90ms(对照 P0 重测基线);log 视图 ≤15ms |
| **P4 index 写** | stage/unstage、hunk apply、`checkout -- file` 经 libgit2;写后仍走现有 watcher/popup 刷新 | 上述动作零 spawn;切分支/commit/stash 仍 CLI;rspec popup 双跑全绿 |

**可选项(gated,不承诺)**:worker 线程升级(触发 = 大仓库实测卡顿)、diff 迁移(基线:组合路径 32ms vs CLI 17ms,无收益;触发 = 出现明确受益场景)、stash 迁移(绑定已证实存在)。

**其他三项**:①验收 = 量化线 + 双后端 E2E 双跑,不达标视同反模式警报(如误用 `tree_to_workdir`);②回退 = 全局 `kind` 配置一键回 CLI,能力表纯内部、不暴露每模块配置;③测试矩阵 = CI(ubuntu)装 libgit2,单测按后端分文件、无库 skip,rspec E2E 跑两遍(`kind=cli` 与 `kind=auto`)——CI 时长翻倍换两后端行为等价的持续验证(雾区「测试矩阵」随之解决)。
