---
status: accepted
date: 2026-09-20
---

# 引入原生依赖:系统 libgit2 + LuaJIT FFI

neogit 是纯 Lua 零构建插件,但响应性能的验收目标(基线:warm refresh 187ms / 9 spawn)依赖消灭进程 spawn,我们决定引入编译型原生依赖——用户系统自备 libgit2,插件经 LuaJIT FFI 直连(PoC 已验证零改动 vendor 可加载)。加载用 soname 候选序列(`libgit2_path` → `libgit2.so.1.9/.1.8/.1.7` → `libgit2`),避免强制安装 dev 包;版本 gate 以 `git_libgit2_version()` 为唯一权威:最低支持 1.7,积极支持 1.8/1.9,major≠1 一律硬拒并降级 CLI 后端。

## Considered Options

- 预编译二进制分发(pygit2 模式):免版本漂移,但需要每平台构建/发布流水线,超出「先自用后现上游」定位,拒绝。
- 纯 CLI 优化(不引原生依赖):天花板是去冗余后 ~6 spawn,达不到 spawn ≤2 的验收线。
- 外部 helper 常驻进程:无 ABI 耦合,但引入进程管理、协议设计与延迟,复杂度不低于 FFI 且收益更低。

## Consequences

- ABI 级耦合:cdef 硬编码结构体布局,布局错误**无运行时探测手段**,只能靠版本号硬门;2.0(公告将改 `git_oid` 为 33 字节)到达时必须显式适配。
- 用户安装摩擦:无库环境自动降级 CLI(功能不缺失,仅失去性能收益),一次性提示安装命令。
- 证据:[libgit2 版本分布与 ABI 风险调研](../assets/libgit2-versions-report.md)、[PoC 报告](../assets/binding-poc-report.md)。
