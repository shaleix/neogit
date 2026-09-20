---
title: 绑定与分发方案拍板
slug: binding-distribution-decision
labels: [wayfinder:grilling]
status: closed
assignee: main-session/ses_f41e510deffeMfC1qkcd4Q5YVY
blocked-by: [libgit2-versions, binding-poc]
created: 2026-09-20
---

## Question

**libgit2 绑定的获取与库的分发方案是什么?** 需要拍板:

1. **最低支持版本**:基于版本分布调研,声明支持哪个 libgit2 起步版本?对更旧版本的行为(降级 CLI?硬报错?)。
2. **库获取方式**:fugit2 模式(用户系统装 libgit2,插件 `ffi.load` + `setup({ libgit2_path = ... })` 覆盖)是否照搬?是否需要预编译产物兜底?(倾向 fugit2 模式,但要看过 PoC 与版本调研后再定。)
3. **运行时探测与降级**:版本/ABI 探测放在哪个时机(setup 时?首次打开 repo 时?)、探测失败的降级与用户提示如何设计,才能兑现"auto 切换、不可用自动降级 CLI"的既定约束。
4. **vendor 边界**:fugit2 绑定层拷进 `lua/neogit/lib/git2/` 的范围(哪些模块要、哪些不要,如 gpgme 先不带)、MIT 归属声明怎么留。

输入:`libgit2 版本分布与 ABI 风险调研` 的版本分布与风险清单、`libgit2 直连 PoC` 的加载/对齐/收益证据。

## Resolution

**五项决策全部拍板(2026-09-20,grilling):**

1. **最低支持版本 = 1.7**,积极支持 1.8/1.9;`git_libgit2_version` 返回 major ≠ 1 一律**硬拒**(2.0 已公告 SHA256 转正将改 `git_oid` 布局,结构差异不可探测,只能版本号硬门)。覆盖 Ubuntu 24.04 LTS(1.7.2,支持到 2029)起的全部主流渠道。
2. **库获取 = 系统库 + soname 候选序列**:`setup({libgit2_path})` 用户覆盖 → `libgit2.so.1.9 / .1.8 / .1.7`(显式 soname,只依赖运行时包、不需要 -dev)→ `libgit2`(dev 包/Arch/brew);macOS 对应 dylib 序列(spec 细节)。**不做**预编译二进制分发。
3. **探测时机 = 惰性**:首次需要 git 操作时探测(非 setup 时),进程内缓存结果;失败 → 一次性 `vim.notify`(含渠道安装提示)+ 静默降级 CLI,此后不再打扰;显式配置 `kind = "libgit2"` 而环境不满足 → 硬报错。
4. **vendor 边界 = 三文件 verbatim 快照 + overlay**:`libgit2.lua`、`git2.lua`、`util/stat.lua` 逐字拷入,顶部加 provenance 头(MIT 归属 + pin `7783d33`);**所有** neogit 侧修改(soname 加载器、`git_libgit2_version` cdef、按版本注入枚举值——1.9 的 GIT_CHECKOUT 重排、1.8 的 CONFIG_LEVEL 插位、1.7 的 config_entry.level 禁读、blame_hunk.boundary 版本开关)只放独立 **overlay 模块**,vendor 副本永不改动。不含 gpgme/git_gpg(写路径未定,留在地图雾区)、blame CLI 解析器、rebase helper、hooks。vendor 目录的具体落位(lua/neogit/lib/ 下结构)由`混合后端架构边界拍板`统一决定。
5. **上游同步 = 冻结快照、按需重同步**:spec 记录 pin commit;仅当需要新增 API(如将来决定迁移 merge 而上游已有绑定)时才从 fugit2 上游重同步 + 重放 overlay。

**给后续 ticket 的输入**:枚举/字段差异完整清单与加载器伪代码见 [assets/libgit2-versions-report.md](../assets/libgit2-versions-report.md) §3.2/§4.3;验收基线见 [assets/baseline-report.md](../assets/baseline-report.md)。本决策将汇编为 ADR「引入原生依赖」(见 `撰写迁移 Spec 与 ADR`)。
