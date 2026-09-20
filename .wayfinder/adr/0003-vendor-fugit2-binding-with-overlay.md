---
status: accepted
date: 2026-09-20
---

# vendor 复用 fugit2 绑定层:verbatim 快照 + overlay,冻结于 7783d33

fugit2.nvim(MIT)的手写 libgit2 FFI 绑定(`libgit2.lua` cdef + `git2.lua` OOP 封装 + `util/stat.lua`,共 ~5800 行)经 PoC 验证可零改动 vendor 进 Neovim。我们决定三文件**逐字快照**拷入,顶部加 provenance 头(MIT 归属 + pin `7783d33`),**永不改动副本**;所有 neogit 侧修改(soname 加载器、`git_libgit2_version` cdef、版本 gate、按版本注入枚举值、功能开关)放独立的 **overlay 模块**。与上游的关系:冻结快照、按需重同步——仅当需要新增 API 时才从 fugit2 上游拉取并重放 overlay。

## Considered Options

- 拷入后原地补丁:少一层间接,但副本与上游 diff 混杂,后续同步与审计成本高,拒绝。
- 抽独立共享 luarocks 包:最干净但多维护一个项目,超出本目的地,拒绝。
- 只参考思路、FFI 从零自写:工作量最大,且 fugit2 绑定已被生产验证,无必要。

## Consequences

- vendor 副本与上游的 diff 恒为空;所有本地分歧集中在 overlay,一眼可审计。
- 已知必须在 overlay 处理的坑:1.9 `GIT_CHECKOUT` 枚举漂移(SAFE 1→0、NONE 语义反转)、1.9 `blame_hunk` 插字段(`boundary` 偏移错)、1.8 `GIT_CONFIG_LEVEL` 插位、1.7 `config_entry.level` 禁读、varargs 函数须显式装箱、untracked 条目的 `index_status` 污染(fugit2 封装行为)。完整清单见 [libgit2-versions-report §3.2](../assets/libgit2-versions-report.md)。
- 证据:[PoC 报告](../assets/binding-poc-report.md)。
