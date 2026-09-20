---
title: 迁移阶段划分拍板
slug: migration-phases-decision
labels: [wayfinder:grilling]
status: open
assignee:
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
