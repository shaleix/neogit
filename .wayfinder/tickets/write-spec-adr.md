---
title: 撰写迁移 Spec 与 ADR
slug: write-spec-adr
labels: [wayfinder:task]
status: open
assignee:
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
