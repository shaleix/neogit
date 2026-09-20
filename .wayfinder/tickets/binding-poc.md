---
title: libgit2 直连 PoC
slug: binding-poc
labels: [wayfinder:prototype]
status: open
assignee:
blocked-by: []
created: 2026-09-20
---

## Question

用最便宜、最具体的证据提高"绑定与分发"讨论的保真度:**把 fugit2 绑定层(`libgit2.lua` + `git2.lua`)临时 vendor 进本仓库(不接任何 UI),headless 驱动真实仓库,验证三件事:**

1. **能加载**:在本机 Neovim(LuaJIT)环境里 `ffi.load` 系统 libgit2 成功,惰性加载与 `git_libgit2_init` 一次性行为正常。
2. **能对齐**:libgit2 产出的 status/revwalk 数据与 neogit 现有 porcelain v2 解析结果在语义上等价(哪些字段全等、哪些缺失/多出——如 rename 检测需 `git_diff_find_similar`、ahead/behind 需 `git_graph_ahead_behind`)。
3. **有收益**:同仓库上单次 status/log 调用,FFI 直连 vs spawn git CLI 的延迟对比数字。

约束:throwaway 性质——脚本/分支可丢弃,产物是"可复现的 scratch 验证 + 观感结论",不是生产代码。做完把资产链接回来,供"绑定与分发方案拍板"与"混合后端架构边界拍板"引用。

参考:`.wayfinder/assets/fugit2-libgit2-survey.md`(绑定层三层结构与 uv.new_work 范式)。
