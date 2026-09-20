---
title: neogit 迁移 libgit2 混合后端
labels: [wayfinder:map]
---

# neogit 迁移 libgit2 混合后端

## Destination

一份完整、可执行的迁移 Spec(含 ADR):把 neogit 的 git 操作层改造为**读路径走 libgit2(FFI 直连)、写/交互式流程保留 git CLI** 的混合双后端,以**响应性能**为核心验收标准(对比基线数据),运行时 auto 检测后端、不可用自动降级 CLI。Spec 落在 `.wayfinder/spec/`,架构决策写成 ADR,并包含上游可行性评估章节。Spec 定稿即达目的地,代码施工在地图之外执行。

## Notes

- 域:Neovim 插件 / git 客户端。参考实现:`~/workerspace/fugit2.nvim`(MIT,基于 libgit2,与本仓库同为本地代码库)。
- 决策类 ticket 一律调用 Skill 工具加载 `grilling` + `domain-modeling`;研究类调用 `research`;原型类调用 `prototype`。
- 平台:Linux/macOS 为一等公民;Windows 及无系统 libgit2 的环境自动降级纯 CLI 后端,功能不缺失、仅失去性能收益。
- 原生依赖可接受;fugit2 的绑定层(`libgit2.lua` cdef 声明 + `git2.lua` OOP 封装)按 MIT 直接 vendor 复用,但具体绑定与分发方案须经决策 ticket 拍板。
- 归宿:先 fork 自用验证性能收益,收益成立后再评估是否推进上游(NeogitOrg/neogit)——spec 含上游可行性评估环节。
- 后端切换:运行时 auto 检测(可用 libgit2 则读路径走之,否则全 CLI),不要求用户显式 opt-in。
- Spec 物理形态:正文与 ADR 落在 `.wayfinder/`(spec 与 adr 子目录);将来 PR 上游时再整理。上游的 `notes` 文件是维护者笔记,与本地图无关,勿动。

### 词汇表

| 术语 | 含义 |
|---|---|
| **后端 (backend)** | git 操作的执行通道。**CLI 后端** = 现有 `cli.lua → runner → process` 链路(spawn git 子进程、解析输出);**libgit2 后端** = LuaJIT FFI 直连系统 libgit2 库。 |
| **读路径** | 产出 `NeogitRepoState` 的操作(status/diff/log/refs/blame 等),经 `repository.lua` 的 `update_*` 协议汇聚,是 libgit2 的迁移对象。 |
| **写路径 / 交互式流程** | 一次性变更命令(add/reset/checkout)与编辑器/PTY/网络认证驱动的流程(rebase -i、merge continue、push 凭据交互),长期保留 CLI 后端。 |
| **绑定层** | fugit2 的 `core/libgit2.lua`(FFI cdef + 枚举 + 惰性 `ffi.load`)+ `core/git2.lua`(OOP 封装),计划 vendor 进 neogit。 |
| **auto 切换** | 运行时检测绑定可用性并选择后端;检测失败自动降级 CLI,对用户透明。 |
| **基线** | 迁移前关键读操作的耗时/spawn 次数测量,性能验收的对照组。 |

### Tracker 约定(local-markdown)

- 地图 = 本文件(`.wayfinder/map.md`);ticket = `.wayfinder/tickets/<slug>.md`,每张一个文件;研究资产放 `.wayfinder/assets/`。
- **认领**:把 ticket frontmatter 的 `assignee` 写为自己的 session 标识并提交,先于任何工作。
- **阻塞**:frontmatter `blocked-by` 列 slug;**frontier** = `status: open` 且 blocked-by 全部 `closed` 且 `assignee` 为空。
- **解决**:ticket 文末追加 `## Resolution`(答案/结论 + 资产链接),frontmatter 置 `status: closed`;随后在地图 Decisions so far 追加一行。

## Decisions so far

(尚无已关闭的 ticket;下述约束在 charting 阶段由用户拍板,记录于 Notes 与 Destination:目的地=完整 Spec、读优先混合共存、性能为验收核心、原生依赖可接受、auto 切换、Linux/macOS 优先、vendor 复用 fugit2 绑定层、先自用后现上游、Spec 落 `.wayfinder/` + ADR。)

## Not yet specified

- GPG 签名链路是否需要(gpgme/ssh-keygen 补位)——取决于写路径边界划在哪:commit 若保留 CLI 则无需;若迁 libgit2 则必须补签名链路。
- hooks 触发语义:libgit2 写操作下 pre-commit 等钩子的时序与编辑器行为差异如何处理。
- 取消语义:`Repo:refresh` 靠 kill 子进程取消,libgit2 内存操作的同构中断机制是什么。
- 长尾读操作的取舍:describe、reflog 遍历、submodule 状态等 libgit2 覆盖不全或成本不明的点。
- 测试矩阵:plenary 单测与 Ruby rspec E2E 如何在双后端下组织(等阶段划分成形后再细化)。
- 上游可行性评估的具体形态与判据(等 spec 骨架成形)。

## Out of scope

- 网络操作(push/fetch/pull/clone)改用 libgit2 remote API——fugit2 也绕道 CLI(凭据回调/ssh-agent 复杂度不成比例),永久保留 CLI。
- Windows 的 libgit2 一等公民支持(构建矩阵/预编译 .dll 分发)——Windows 自动降级 CLI 即可。
- 把绑定层抽成独立共享 luarocks 包——多维护一个项目,超出本目的地。
- 交互式流程(rebase -i 编辑器、merge 编辑、PTY 认证)迁离 CLI——结构性不可替换。
- 迁移的实际代码施工——地图终点是 Spec 定稿,施工由后续执行 session 按图作业。
