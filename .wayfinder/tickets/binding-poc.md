---
title: libgit2 直连 PoC
slug: binding-poc
labels: [wayfinder:prototype]
status: closed
assignee: main-session/ses_f41e510deffeMfC1qkcd4Q5YVY
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

## Resolution

**三问全部得到肯定答案,证据链完整(2026-09-20,本机 libgit2 1.9.1 / nvim 0.12.5 / git 2.53):**

1. **能加载 ✅**:fugit2 绑定层 3 个文件(libgit2.lua + git2.lua + util/stat.lua,共 ~5800 行)**零改动** vendor,`package.path` 前缀即可解析;惰性 `ffi.load` + `git_libgit2_init` 一次性行为正常;`table.new` 内建可用。缺口:`git_libgit2_version` 未被 cdef(vendor 时必须补——正好是版本探测所需)。
2. **能对齐 ✅ + 两个已定差异**:
   - staged/untracked/branch/ahead-behind 与 porcelain v2 语义等价,含歧义 rename 配对(libgit2 与 git CLI 对同内容文件做出相同配对);
   - **工作区 rename(用户已拍板:富模型、CLI 降级)**——NeogitRepoState 增加可选重命名字段,libgit2 后端填入、CLI 后端留空,UI 仅在有信息时显示 rename;
   - fugit2 封装坑:untracked 条目的 `index_status` 也被置为 UNTRACKED,消费侧须过滤;
   - 附带发现:`vim.fn.system` 破坏 NUL 字节,读 `-z` 输出必须用 `vim.system`/jobstart(neogit 现有 process 层无此问题)。
3. **有收益(指示性)**:小仓库上 status 全量读 FFI 快 2–4x,log 前 200 条快 ~139x(0.09ms vs 12.4ms)。

**交叉影响(来自 `libgit2 版本分布与 ABI 风险调研`)**:fugit2 cdef 以 1.8 为基准,在 1.9 上有 `GIT_CHECKOUT` 枚举漂移与 `blame_hunk.boundary` 错位两处静默错误——本 PoC 未触及这些 API 故结论不受影响,但 vendor 进 neogit 时必须按该报告的"运行时版本 gate + 枚举补丁"方案处理。

**产物**:复现方法与数据见 `.wayfinder/assets/binding-poc-report.md`;scratch(make-fixture.sh + runner.lua + vendor/)在 `prototype/binding-poc` 分支 `.wayfinder/scratch/binding-poc/`(THROWAWAY,不进 master)。
