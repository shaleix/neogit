---
title: 撰写迁移 Spec 与 ADR
slug: write-spec-adr
labels: [wayfinder:task]
status: closed
assignee: main-session/ses_f41e510deffeMfC1qkcd4Q5YVY
blocked-by: [migration-phases-decision]
created: 2026-09-20
---

## Question

**把全部决策汇编成最终交付物,达成目的地:**

1. **Spec 正文**(`.wayfinder/spec/migration-spec.md`):架构(双后端、auto 切换、接缝)、阶段划分与每阶段验收标准(对比基线的量化指标)、回退策略、风险清单、测试策略。
2. **ADR**(`.wayfinder/adr/`):至少包含——① 引入原生依赖(系统 libgit2 + FFI);② 读路径 libgit2 / 写与交互路径 CLI 的混合边界;③ vendor 复用 fugit2 绑定层(MIT 归属)。
3. **上游可行性评估章节**:面向 NeogitOrg/neogit 的可合入性分析(社区对原生依赖的接受度、可选依赖与零编译承诺的冲突、若推进需要的妥协形态),给出"推进/不推进/改造后推进"建议。
4. **词汇表归宿**:把地图词汇表沉淀进 spec(或按 domain-modeling 惯例另立 CONTEXT.md,由届时判断)。
5. 收尾:核对地图 Decisions so far 完整、fog 清空或显式转为 out of scope,地图关闭。

完成即达目的地,交棒执行。

## Resolution

**目的地达成(2026-09-20)。交付物:**

1. **Spec 正文**:[`spec/migration-spec.md`](../spec/migration-spec.md) —— 术语表(地图词汇表全量沉淀 + 新增条目)、背景与基线摘要、目标/非目标、总体架构(双后端/auto 切换/vendor+overlay/接缝/刷新模型/写边界)、五阶段计划(P0–P4 含量化验收)、验收与度量方法、测试策略(双后端双跑)、回退与灰度、七项风险清单、**上游可行性评估**(结论:fork 先行 P0–P4,数据成立后分拆 PR 推进——P0 类纯 CLI 改进可最先单独上游,绑定层以 feature flag 形态后续提案;判据 = P3 验收线达成 + 2–4 周自用无降级故障)、交棒执行入口(P0/P1 起步指引)。
2. **ADR 四份**(`adr/`):0001 引入原生依赖(soname 序列 + 版本 gate,含三个被拒备选)、0002 混合后端边界(读 + index 写;切分支/commit 留 CLI 的原因)、0003 vendor 复用 fugit2 绑定层(verbatim + overlay,冻结 7783d33,含 overlay 必修坑清单)、0004 刷新模型(每周期重开 + 同步先行 + 任务边界取消,含两个被拒备选)。
3. **收尾核对**:地图 Decisions so far 完整(8/8 票关闭);雾区清空(「上游可行性」由 spec 第 9 章完成,其余各项先前已由对应票解决);词汇表归宿 = spec 第 0 章(不另立 CONTEXT.md,避免污染 fork 根目录;将来 PR 上游时随 spec 整理)。地图关闭,交棒执行。
