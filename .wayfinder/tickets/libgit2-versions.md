---
title: libgit2 版本分布与 ABI 风险调研
slug: libgit2-versions
labels: [wayfinder:research]
status: closed
assignee: research-subagent/libgit2-versions
blocked-by: []
created: 2026-09-20
---

## Question

neogit 计划 `ffi.load` 系统安装的 libgit2(fugit2 模式),必须先弄清:**2026 年主流环境预装的 libgit2 版本分布如何?libgit2 的 ABI 稳定性承诺与已知破坏性变迁(如 git_buf→git_str)对手写 cdef 的威胁有多大?运行时版本探测有哪些现成做法?**

具体要查:
1. 主流分发渠道当前提供的 libgit2 版本:Debian stable/testing、Ubuntu LTS、Fedora、Arch、Homebrew、nixpkgs(各自默认/可装的 1.x/2.x 版本)。
2. libgit2 官方的版本与 ABI 兼容策略(semver 承诺、1.x 内 ABI 稳定性、2.0 计划或已发生的破坏性变更)。
3. 已知 ABI 断裂点清单(结构体布局变更、字段增删、回调签名变化),并对照 fugit2 手写 cdef(`~/workerspace/fugit2.nvim/lua/fugit2/core/libgit2.lua`,约 180 个函数声明)的暴露面评估风险。
4. 运行时探测方案:`git_libgit2_version()`、符号级 pcall 探测、加载前 dlopen 探测等实践;fugit2 是否有可借鉴的失败降级路径(看起来没有——这是差距)。

产出:版本分布表 + ABI 风险清单 + "最低支持版本 + 运行时探测"的策略建议输入,供绑定与分发决策 ticket 使用。

## Resolution

**调研完成(2026-09-20),报告:`.wayfinder/assets/libgit2-versions-report.md`**(分支 `research/libgit2-versions`)。核心结论:

1. **版本分布**:2026-09 主流 stable/rolling 渠道全部 ≥1.9.0(Debian 13=1.9.0、testing=1.9.7、Ubuntu 26.04=1.9.1、Fedora 42-44=1.9.x、Arch/Gentoo/Homebrew/nixpkgs-stable=1.9.7);1.8.x 在 Fedora 并行包/brew@1.8/nix 24.11;1.7.2=Ubuntu 24.04(支持到 2029);1.5.1=Debian 12;1.1.0=Ubuntu 22.04。
2. **ABI 政策**:官方明文 ABI 仅在 minor 内稳定并点名 FFI 用户受害;1.7/1.8/1.9 每个 minor 都有记载的 ABI 破坏。SONAME=major.minor。**2.0 未发布**(最新 v1.9.7,2026-08-13),路线图含 git_oid 变 33 字节等毁灭性变更 → 必须 major gate 硬拒绝。git_buf→git_str 是 1.4.0 的内部改名,公共 API 全 1.x 保持 git_buf,布局兼容,非实际威胁。
3. **fugit2 cdef 评估**:基准为 1.8 布局。1.9 上两处确认的静默错误——GIT_CHECKOUT 枚举值漂移(SAFE 1→0、NONE 0→1u<<30)与 blame_hunk.boundary 错位(读到指针字节);1.7 上 config_entry.level 偏移错;git_rebase 复刻内部结构(未直接访问,暂无害);varargs 与未声明 git_libgit2_version 是缺口。关键 options 结构(diff/checkout/status 等)1.7–1.9 实测同形。
4. **策略建议**:最低支持 **1.7**、积极支持 1.8/1.9、cdef 以 1.8 为基准 + 按运行时版本注入枚举补丁;加载器采用"显式 soname 候选序列(免 dev 包依赖)+ pcall + `git_libgit2_version()` gate + 版本矩阵 + CLI 降级"五件套(fugit2 五缺其四,证实 ticket 的差距判断);结构布局差异无法探测,只能靠版本号 gate。1.6 以下(bookworm/jammy)不支持,引导 backports 或 CLI。

**资产**:`.wayfinder/assets/libgit2-versions-report.md`(含版本分布表、逐条 ABI 风险清单及头文件级证据、探测方案伪代码、全部来源链接)
