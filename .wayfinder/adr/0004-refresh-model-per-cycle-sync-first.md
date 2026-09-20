---
status: accepted
date: 2026-09-20
---

# 刷新模型:每 refresh 周期重开 Repository,同步 FFI 先行,任务边界取消

混合后端下存在三种写入来源(外部 git CLI、自家 index 写、编辑器),长寿命 `git_repository*` 的缓存失效纪律任何一处遗漏都是静默脏状态;而基线实测重复 open 仅 0.19ms。我们决定 **每个 refresh 周期重开 Repository**(周期内各 `update_*` 共享、周期尾释放),彻底取消失效问题;进程级仅 `git_libgit2_init` 一次;watcher 触发机制不变。线程模型首期用**同步 FFI**(目标规模单任务 ≤30ms、lib-only ≈40ms,满足 warm ≤90ms 验收线),但全部调用经一个可替换的**执行器**抽象,`update_*` 任务边界即未来搬入 `uv.new_work`(fugit2 intptr 传递范式)的接缝。取消语义:**任务边界检查点**——单个任务原子不可中断,取消发生在边界、进行中任务跑完结果丢弃,风暴由现有 200ms debounce 吸收。

## Considered Options

- 长寿命缓存 + 显式失效(fugit2 模式):0.19ms 的重开成本使其只剩风险没有收益,拒绝。
- `uv.new_work` worker 线程一步到位:fugit2 已验证可行,但要先把 neogit 自研 coroutine 库与 uv.new_work 回调模型接通,且大仓库卡顿目前是假设而非实测——列为 gated 可选项(触发条件:几十万文件仓库实测 UI 卡顿),拒绝现在做。

## Consequences

- 「取消一个进行中的刷新」在 libgit2 后端下含义弱化为「丢弃其后结果」——spec 明记此限制。
- 超大仓库(几十万文件)同步阻塞是已接受风险,升级路径(执行器换 worker 实现)已在架构上保留。
- 节流参数两后端统一(200ms),不新增配置面;分后端调优仅实测后作为可选项。
- 证据:[基线报告](../assets/baseline-report.md) §2.7、[fugit2 调研](../assets/fugit2-libgit2-survey.md) §四。
