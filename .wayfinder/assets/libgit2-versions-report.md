# libgit2 版本分布与 ABI 风险调研报告

> 由 research subagent(`research-subagent/libgit2-versions`)于 2026-09-20 产出,供 `绑定与分发方案拍板`、`libgit2 直连 PoC` 等 ticket 引用。
> 调研对象:上游 libgit2 官方文档/源码/发布记录 + 主流分发渠道包页面 + fugit2 手写 cdef(`~/workerspace/fugit2.nvim/lua/fugit2/core/libgit2.lua`,1307 行,约 180 个函数声明)。
> 所有网络数据取自 2026-09-20 当天;每条关键事实附来源链接。

## 0. TL;DR

1. **2026-09 的版本主流是 1.9.x**:Debian stable/testing、Ubuntu 26.04、Fedora 42–44、Arch、Gentoo、Homebrew、nixpkgs 当前 stable 全部 ≥1.9.0;长期支持线上限是 Ubuntu 22.04 的 **1.1.0** 和 Debian 12 的 **1.5.1**。
2. **libgit2 官方明确:ABI 只在 minor 版本内稳定**,并在政策文档里点名 FFI 用户(.NET P/Invoke、Rust)是受害者;1.7→1.8→1.9 每个 minor 都有实际 ABI 破坏记录。2.0(未发布)才承诺整个 major 周期的 ABI 稳定。
3. **2.0 截至 2026-09-20 尚未发布**(最新 release 是 2026-08-13 的 v1.9.7 安全更新),但路线图明确:SHA256 转正会让 `git_oid` 从 20 字节变成 `type + id[32]`,一切含 oid 的结构体全部错位——对手写 cdef 是毁灭性的,必须按 major gate 硬拒绝。
4. fugit2 的 cdef **以 1.8 布局为基准**,在 1.9 上有两处已确认的静默错误(GIT_CHECKOUT 枚举值漂移、blame hunk `boundary` 字段错位),在 1.7 上有一处轻错(config entry `level` 偏移);其余关键结构(diff/checkout/status 等 options 结构)1.7–1.9 布局实测一致。
5. **结构体布局无法靠探测发现**(共享库只有符号名没有类型信息),唯一可行方案是 `git_libgit2_version()` 运行时 gate + 按版本注入枚举常量 + 加载失败/版本不符时降级 CLI。fugit2 目前三者全缺(无版本探测、无 gate、无降级),这印证了 ticket 里的差距判断。

## 1. 2026-09 主流渠道版本分布

### 1.1 上游发布状态

- 最新 release:**v1.9.7**(2026-08-13,安全更新,单一修复)。来源:[Releases · libgit2/libgit2](https://github.com/libgit2/libgit2/releases)
- v1.9.0 "Schwibbogen"(2025-01 发布)是 **v1.x 世代最后一个 minor**,官方原话:"This is expected to be the final release in the libgit2 v1.x lineage"。来源:[docs/changelog.md](https://github.com/libgit2/libgit2/blob/main/docs/changelog.md)、[pygit2 CHANGELOG](https://github.com/libgit2/pygit2/blob/master/CHANGELOG.md)(pygit2 1.17.0,2025-01-08,"Upgrade to libgit2 1.9")
- **v2.0 未发布**:官方 2024-12-28 公告了 2.0 破坏性变更清单([discussion #6988](https://github.com/libgit2/libgit2/discussions/6988)),此后 1.x 线持续出安全补丁(1.9.1…1.9.7),无 2.0 tag。来源:[Releases](https://github.com/libgit2/libgit2/releases)

### 1.2 发行版/渠道版本表(2026-09-20 查证)

| 渠道 | 版本 | 备注 / 二进制包(soname) | 来源 |
|---|---|---|---|
| Debian 13 trixie(stable) | **1.9.0**(+deb13u1 安全更新,2026-08-24) | `libgit2-1.9` | [tracker.debian.org/pkg/libgit2](https://tracker.debian.org/pkg/libgit2) |
| Debian testing(forky)/ sid | **1.9.7** | 2026-08-22 迁入 testing | 同上 |
| Debian 12 bookworm(oldstable) | 1.5.1(+deb12u1);backports 有 1.8.4 | `libgit2-1.5` | 同上 |
| Debian 11 bullseye | 1.1.0 | `libgit2-1.1` | 同上 |
| Ubuntu 26.04 LTS "Resolute Raccoon"(当前 stable) | **1.9.1**(+1.1 安全更新,2026-08-12) | `libgit2-1.9` | [launchpad.net/ubuntu/+source/libgit2](https://launchpad.net/ubuntu/+source/libgit2) |
| Ubuntu 26.10 "Stonking Stingray"(dev) | 1.9.6 | 同上 | 同上 |
| Ubuntu 24.04 LTS noble | 1.7.2(+3.1 安全更新) | `libgit2-1.7`,支持到 2029 | 同上 |
| Ubuntu 22.04 LTS jammy | **1.1.0** | `libgit2-1.1`,支持到 2027-04 | 同上 |
| Fedora 43(当前 stable) | 1.9.0 → updates **1.9.7** | 主包 `libgit2`;另有并行兼容包 `libgit2_1.8`(1.8.5) | [packages.fedoraproject.org/pkgs/libgit2](https://packages.fedoraproject.org/pkgs/libgit2/)、[Repology](https://repology.org/project/libgit2/versions) |
| Fedora 42 | 1.9.3(updates)+ `libgit2_1.8` 1.8.5 | | Repology(同上) |
| Fedora 44 / Rawhide | 1.9.7 | | Repology(同上) |
| Arch(rolling) | **1.9.7**(2026-08-14 打包) | 单包含头文件与未版本化 `.so`;`Provides: libgit2.so=1.9-64` | [archlinux.org/packages/extra/x86_64/libgit2](https://archlinux.org/packages/extra/x86_64/libgit2/) |
| Gentoo | 1.9.7(1.9.3/1.9.4/1.9.6/1.9.7 陆续稳定化) | | [packages.gentoo.org/packages/dev-libs/libgit2/changelog](https://packages.gentoo.org/packages/dev-libs/libgit2/changelog) |
| Homebrew(macOS) | **1.9.7** | 版本化 formula:`libgit2@1.8`(1.8.7)、`libgit2@1.7`(1.7.2) | [formulae.brew.sh/api/formula/libgit2.json](https://formulae.brew.sh/api/formula/libgit2.json) |
| nixpkgs 26.05(当前 stable) | **1.9.7** | `withExperimentalSha256 ? false` 默认关 | [pkgs/by-name/li/libgit2/package.nix (release-26.05)](https://github.com/NixOS/nixpkgs/blob/release-26.05/pkgs/by-name/li/libgit2/package.nix) |
| nixpkgs 25.11 / 25.05 / 24.11 / 24.05 | 1.9.2 / 1.9.0 / 1.8.4 / 1.7.2 | | Repology(同上) |
| Alpine 3.23+ / 3.22 / 3.20 | 1.9.7 / 1.9.0 / 1.7.2 | | Repology(同上) |

### 1.3 分布结论

- **分层清晰**:① 1.9.x = 当前一切 stable/rolling 主流(Debian 13+、Ubuntu 26.04+、Fedora 42+、Arch、Gentoo、brew、nix stable);② 1.8.x = 次新环境(Fedora 并行包、brew @1.8、nix 24.11、bookworm-backports);③ 1.7.x = Ubuntu 24.04 noble(仍处 5 年标准支持期,到 2029);④ 1.5.x / 1.1.x = bookworm / jammy / bullseye。
- **支持 1.7–1.9 即可覆盖 Ubuntu 24.04 以后的所有主流渠道**;要覆盖 22.04 就得兼容 1.1.0(结构体差异过大,见 §3,不建议,让 22.04 用户显式安装新版或走 CLI 后端)。
- 发行版有成熟的**多版本共存先例**:Fedora 的并行 soname 子包(`libgit2_1.8` 等,同一系统装多个 minor)、Homebrew 的 `@1.7/@1.8` 版本化 formula、Gentoo/nixpkgs 多版本 slot。这证明"按 soname 显式加载特定 minor"是可运营的策略。

## 2. 官方版本与 ABI 兼容政策

来源:[docs/api-stability.md](https://github.com/libgit2/libgit2/blob/main/docs/api-stability.md)(官方政策原文):

- **标准 API**(`git2/*.h`,即 git2.h 聚合的一切):**在整个 major 内稳定**;签名不变、不删除,可标记 deprecated 但最早下个 major 才删。API 兼容允许用宏做(改名结构体时 `#define old new`),**但这不提供 ABI 兼容**。
- **系统 API**(`git2/sys/*`,扩展机制、cmake 选项):仅在 **minor** 内稳定。
- **ABI(符号名、函数签名、结构体实际布局):仅在 minor 内稳定**。原文:"Our ABI consists of actual symbol names in the library, the function signatures, and the actual layout of structures. These are only stable within minor releases… Since many FFIs use ABIs directly (for example, .NET P/Invoke or Rust), this instability is unfortunate." 并承诺 "In a future major release, we will begin providing ABI stability throughout the major release cycle"(= 2.x 世代)。
- **point release(1.9.x)永不破坏 API/ABI**(只做 bugfix/安全修复;实测 1.9.1–1.9.7 均为安全/bugfix)。

### 2.1 1.x 各 minor 的实际 ABI 破坏记录(均在官方 changelog 标注 "ABI breaking change")

来源:[docs/changelog.md](https://github.com/libgit2/libgit2/blob/main/docs/changelog.md) 各版本 "Breaking changes" 小节:

| 版本 | 破坏点 | 与 fugit2 cdef 的关系 |
|---|---|---|
| v1.7.0 | `git_allocator`(GIT_OPT_SET_ALLOCATOR)只剩 gmalloc/grealloc/gfree | cdef 未用 allocator,无碍 |
| v1.8.0 | ① 新增 `GIT_CONFIG_LEVEL_WORKTREE=6`,`APP` 从 6 改 7;② `git_config_entry` 增 `backend_type`/`origin_path`、删 `payload`;③ `git_push_options` 增字段 | ①② 均命中 cdef(见 §4) |
| v1.8.1 | 移除 v1.8.0 误加的 `git_fetch_options.report_unchanged` bitfield | cdef 未声明 fetch options,无碍 |
| v1.9.0 | ① `git_blame_hunk` 增 committer/summary 字段;② **`GIT_CHECKOUT_SAFE` 从 `1u<<0` 改为 `0`,`NONE` 改为 `1u<<30`**;③ `git_config_entry` 删尾部 `free` 成员;④ config backend 返回 `git_config_backend_entry`;⑤ `git_remote_callbacks` 增 `update_refs` 回调 | ①②③ 均命中 cdef(见 §4);④⑤ cdef 未涉及 |
| (参考) v1.8.2/1.8.4 | 回滚 `git_commit_create` 系列的 const 变更,"regrets the API change" | 说明 1.x 连 API 层都有过点版本内反复 |

### 2.2 SONAME 政策

- 现状:SONAME = `libgit2.so.<major>.<minor>`(如 Arch 包声明 `Provides: libgit2.so=1.9-64`;Debian 二进制包名 `libgit2-1.9`;Cygwin 包名 `libgit2_1.9`)。**minor 间 ABI 断裂直接体现在 soname 变化上**——这是"显式按 soname 加载并锁定布局"的依据。来源:[Arch 包页](https://archlinux.org/packages/extra/x86_64/libgit2/)、[Debian tracker](https://tracker.debian.org/pkg/libgit2)。
- v1.9.0 曾把 soname 提到 2.0 又回滚("Changing our SONAME / ABI version update policy without an announcement is a breaking change")。来源:libgit2 仓库 git 历史(v1.9.0 tag 内 commit 3aeb5bd0)。
- **2.0 起改用 libtool 式 SONAME 规则**(不兼容 ABI 变更才 bump SONAME major,并尽量保持 minor 间 ABI 兼容)。来源:[discussion #6988](https://github.com/libgit2/libgit2/discussions/6988)。

### 2.3 git_buf → git_str 迁移的真相(对 ticket 疑问的直接回答)

- **公共 API 在整个 1.x 从未改名**:v1.4.0 的变更只是内部实现改名("git_buf: now a public-only API (git_str is our internal API)",PR #6078);`git_diff_to_buf`、`git_config_get_string_buf` 等公共签名在 1.1–1.9 全部是 `git_buf*`。来源:[docs/changelog.md v1.4.0](https://github.com/libgit2/libgit2/blob/main/docs/changelog.md)、[v1.9.0 config.h](https://github.com/libgit2/libgit2/blob/v1.9.0/include/git2/config.h)(`git_config_get_path(git_buf *out, …)` 仍在)。
- 布局:`git_buf {char *ptr; size_t reserved; size_t size;}` 与内部 `git_str {char *ptr; size_t asize; size_t size;}` 字段同型同序,**1.x 内二进制兼容**。fugit2 同时 typedef 两者(git_str 用于其复刻的内部 `git_rebase` 结构)没有问题。
- 真正的断裂点不是 buf→str,而是 **2.0 的 SHA256 转正**(见 §2.4)。

### 2.4 2.0 路线图(已公告、未发布)

来源:[discussion #6988](https://github.com/libgit2/libgit2/discussions/6988)(2024-12-28,维护者 ethomson):

1. **SHA256 从实验转正,含 API+ABI 变更**:实验构建里 `git_oid` 已经是 `{unsigned char type; unsigned char id[32]}`(33 字节,见 [v1.9.0 oid.h](https://github.com/libgit2/libgit2/blob/v1.9.0/include/git2/oid.h) 的 `#ifdef GIT_EXPERIMENTAL_SHA256` 分支;默认构建仍是 `id[20]`)。转正后**所有内嵌 git_oid 的结构体(blame_hunk、diff_file/delta、index_entry、rebase_operation…)整体错位**,并伴随回调签名变化——手写 cdef 必须整体重写。
2. TLS 最低 1.2、cipher 套件升级为 Mozilla intermediate。
3. libtool 式 SONAME 版本政策。
4. 移除 chromium zlib / libssh2 内嵌构建;WinHTTP 弃用。
5. `git_object_t` 枚举清理(`GIT_OBJECT_OFS_DELTA`/`REF_DELTA` 等非对象类型项移除)。

**对策含义**:2.0 一旦落地,靠 cdef 前缀兼容毫无意义;必须 `major != 1 → 拒绝加载并降级`,同时把"2.0 适配"当作独立的、可预计的迁移项目(pygit2 的历史表明绑定社区会在数周内跟进)。

### 2.5 一个容易被忽视的现实:实验 SHA256 构建已经存在于发行版

Debian 打包了 `libgit2-experimental1.9` / `libgit2-experimental-dev`([Debian tracker binaries 列表](https://tracker.debian.org/pkg/libgit2));nixpkgs 有 `withExperimentalSha256` 选项(默认 false,来源:[package.nix](https://github.com/NixOS/nixpkgs/blob/master/pkgs/by-name/li/libgit2/package.nix))。这类库里 `git_oid` 是 33 字节,**且 1.9 没有 feature bit 能查询**(`git_libgit2_features()` 只有 SSH/HTTPS/NSEC 位,见 [v1.9.0 common.h](https://github.com/libgit2/libgit2/blob/v1.9.0/include/git2/common.h))。装载到这种库时所有 oid 偏移全部雪崩。缓解:默认只走非 experimental 的 soname/路径,文档声明不支持;必要时做一个"空仓库 oid roundtrip"冒烟检查。

## 3. fugit2 手写 cdef 的兼容性评估

### 3.1 cdef 的版本基准判定:libgit2 1.8

证据(逐字段对照官方头文件):

- `git_config_entry` 含 `backend_type`/`origin_path` 且带尾部 `free` → 恰为 [v1.8.0 config.h](https://github.com/libgit2/libgit2/blob/v1.8.0/include/git2/config.h) 形状(1.7 是 `{name, value, include_depth, level, free, payload}`,1.9 删了 `free`)。
- `git_diff_options` 含 `oid_type`(在 interhunk_lines 与 id_abbrev 之间)→ 与 [v1.8.0](https://github.com/libgit2/libgit2/blob/v1.8.0/include/git2/diff.h)/[v1.9.0 diff.h](https://github.com/libgit2/libgit2/blob/v1.9.0/include/git2/diff.h) 一致;实测 [v1.7.0 diff.h](https://github.com/libgit2/libgit2/blob/v1.7.0/include/git2/diff.h) 也已有同位置 `oid_type`,即 **diff options 布局 1.7–1.9 三代相同**。
- `GIT_CONFIG_LEVEL.APP = 6` → 是 1.7 及以前的值(1.8 起 WORKTREE=6、APP=7)。
- 所有 options 结构 `GIT_*_OPTIONS_VERSION = 1` → 与 1.7–1.9 头文件的 `#define GIT_*_OPTIONS_VERSION 1` 一致。

### 3.2 风险清单(按严重度)

| # | 风险 | 影响版本 | 具体机制 | 证据 |
|---|---|---|---|---|
| 1 | **`GIT_CHECKOUT` 枚举值漂移**(高,静默行为改变) | 1.9+ | 1.9 起 `SAFE=0`、`NONE=1u<<30`、`FORCE=1u<<1` 不变。fugit2 `SAFE=1`:位 1 在 1.9 无定义,[v1.9.0 checkout.c](https://github.com/libgit2/libgit2/blob/v1.9.0/src/libgit2/checkout.c) 只按位检测(FORCE/NONE/UPDATE_ONLY…),未定义位被忽略 → 实践仍走默认安全路径,**纯属巧合兼容**;真正危险的是 `NONE=0` 在 1.9 语义完全反转(0 = SAFE,"不检出"变"安全检出")。fugit2 目前只用 SAFE/FORCE/RECREATE_MISSING(见 git2.lua:2972-2974、view/git_rebase.lua:695-700),没有踩中 NONE,但 neogit 复用 cdef 时**必须按运行时版本注入枚举值** | [v1.9.0 checkout.h](https://github.com/libgit2/libgit2/blob/v1.9.0/include/git2/checkout.h) vs [v1.9.0 changelog "Checkout strategy updates"](https://github.com/libgit2/libgit2/blob/main/docs/changelog.md) |
| 2 | **`git_blame_hunk` 中部插字段**(中,数据错误不崩溃) | 1.9+ | 1.9 在 `final_signature` 后插 `final_committer`,`orig_signature` 后插 `orig_committer`+`summary`。fugit2 cdef 的 `boundary` 偏移因此在 1.9 上读到 `orig_committer` 指针的最低字节(x86-64 小端、指针 16 字节对齐 → 几乎恒为 0/16/…),即 `boundary` 标志永远错误;其余被 fugit2 读取的字段(final_commit_id、final_start_line_number、final_signature、orig_commit_id、orig_path、orig_start_line_number、orig_signature)位于插入点之前/结构前缀,**偏移未变,侥幸兼容** | [v1.9.0 blame.h](https://github.com/libgit2/libgit2/blob/v1.9.0/include/git2/blame.h) vs cdef 79-89 行;fugit2 读 boundary 于 git2.lua:830 |
| 3 | **`GIT_CONFIG_LEVEL.APP=6` 过期**(中低) | 1.8+ | 1.8 起 6 = WORKTREE,APP=7。以 APP=6 调 `git_config_open_level` 会打开 worktree 级配置 | [v1.8.0 config.h](https://github.com/libgit2/libgit2/blob/v1.8.0/include/git2/config.h) |
| 4 | **`git_config_entry` 读 `level` 偏移错误**(低,仅 1.7) | ≤1.7 | 1.7 形状 `{name, value, include_depth, level, …}`,fugit2 按 1.8 形状在 offset 40 读 level → 读到的是 1.7 的 free 指针截断值。fugit2 在 git2.lua:371 读 `entry.level` → 1.7 上显示错误层级;读 name/value(前缀)安全。1.9 删尾部 `free`,前缀不变 → name/value/level 在 1.9 均正确 | [v1.7.0 config.h](https://github.com/libgit2/libgit2/blob/v1.7.0/include/git2/config.h) vs [v1.9.0 config.h](https://github.com/libgit2/libgit2/blob/v1.9.0/include/git2/config.h) |
| 5 | **复刻内部 `git_rebase` 完整结构**(隐患) | 全版本 | 该结构在公共头文件里是 opaque,完整定义在 src 内部,fugit2 从内部源码复刻(含 `git_str state_filename`、位域、内嵌数组)。**实测 fugit2 从不直接访问其字段**(全走 `git_rebase_*` accessor,已 grep 验证),所以当下无害;但内部布局无任何稳定承诺,2.0 必变。neogit 的 cdef 应一律 opaque 化 | cdef 303-322 行;公共声明见 [rebase.h](https://github.com/libgit2/libgit2/blob/v1.9.0/include/git2/rebase.h) |
| 6 | **varargs 函数**(陷阱) | 全版本 | cdef 声明了 `git_libgit2_opts(int, ...)`、`git_commit_create_v(...)`。LuaJIT FFI 调 vararg 时 Lua number 默认转 double 传入,不显式 `ffi.new` 装箱就会传错寄存器/栈槽 → 静默错参;且 LuaJIT callback 不支持 vararg。应只用非 vararg 变体(`git_commit_create` 数组形)并把 opts 调用全部装箱 | [LuaJIT FFI Semantics "Conversions for vararg C function arguments"](https://luajit.org/ext_ffi_semantics.html) |
| 7 | **`git_strarray_readonly` 是自造类型**(无害但注意) | 全版本 | libgit2 无此类型,fugit2 为 const pathspec 自造;布局与 `git_strarray` 一致,可继续用,但对照官方头文件核对时要留意 | fugit2 cdef 52-55 行 vs 官方 types.h |
| 8 | **`git_libgit2_version` 未声明**(缺口) | 全版本 | cdef 只声明了 init/shutdown/opts,没有版本查询函数 → fugit2 连"知道自己加载了什么版本"的能力都没有(见 §5) | fugit2 cdef 370-372 行 |

**1.7–1.9 三代实测兼容性良好的部分**(可以放心作为 cdef 基础):`git_oid`(默认构建 20 字节,见 [v1.9.0 oid.h](https://github.com/libgit2/libgit2/blob/v1.9.0/include/git2/oid.h) 非 experimental 分支)、`git_signature`/`git_time`、`git_index_entry`、`git_diff_*` 系列(options/delta/file/hunk/line,oid_type 位置 1.7–1.9 一致)、`git_checkout_options`(结构本身,只有枚举值变)、`git_status_options`(1.4.0 起有 rename_threshold,1.7+ 同形)、`git_merge_options`、`git_strarray`、`git_buf`。options 结构的 `version` 字段机制(库端校验版本号,不认识就返回 -1)为尾部追加字段提供了官方护栏——但 §2.1 的记录证明**非 options 结构(blame hunk)和枚举值不受此护栏保护**。

### 3.3 加载与分发的现实约束

- `ffi.load("libgit2")` 在 POSIX 上等价于找 `libgit2.so`(名字无点则补 `.so`/`lib` 前缀,LuaJIT 官方语义)→ **需要未版本化 symlink,Debian/Fedora 上它只在 `-dev` 包里**;运行时包只装 `libgit2.so.1.9`。来源:[luajit.org/ext_ffi_api.html#ffi_load](https://luajit.org/ext_ffi_api.html)
- 显式传带点的名字(如 `"libgit2.so.1.9"`)会原样 dlopen → 只依赖运行时包。这是避免强制用户装 dev 包的关键技巧。
- Arch 单包包含一切;Homebrew 的 cellar 路径带版本(`$(brew --prefix libgit2)/lib`)。
- Windows:无包管理器惯例,fugit2 的做法是 wiki 指导用户装 DLL + `setup { libgit2_path = ... }`,neogit 可沿用。
- cdef 声明本身**不会**在加载期校验任何东西:"External symbols are only *declared*, but they are *not* bound";绑定发生在首次索引库命名空间时,"Missing symbol declarations or nonexistent symbol names cause an error"。结构体布局错误则**永远不会**报错——共享库只有符号名没有类型信息(LuaJIT 原话:"There's no way to detect misdeclarations of C functions")。来源:[ext_ffi_semantics.html#clib](https://luajit.org/ext_ffi_semantics.html)

## 4. 运行时探测:现成做法与可借鉴模式

### 4.1 三层探测手段

1. **`git_libgit2_version(int *major, int *minor, int *rev)`**:0.x 时代就存在、属于永不破坏的标准 API,任何 1.x/2.x 库都可调,成本一次 FFI 调用。这是版本 gate 的唯一权威来源(编译期 `LIBGIT2_VERSION` 宏对 FFI 无用)。参考:[v1.9.0 common.h](https://github.com/libgit2/libgit2/blob/v1.9.0/include/git2/common.h)。
2. **符号级探测**:`pcall(function() return lib.git_xxx end)`。LuaJIT 对库命名空间的索引是惰性绑定,缺声明或缺符号都会抛错(见 §3.3 引文),因此可用于 feature 检测,例如探测 `git_commit_create_from_stage`(1.8 新增)区分 <1.8。`ffi.load` 本身失败(dlopen 找不到)同样抛错、同样可 pcall。
3. **布局探测:不可能**。结构体尺寸/偏移无任何运行时 API(1.9 连 experimental SHA256 都没有 feature bit,§2.5)。结论:**结构差异必须映射成版本号差异来 gate**,这是本报告最重要的工程结论之一。

### 4.2 生态里的现成实践

- **pygit2**(官方 Python 绑定):每个 release 锁定一个 libgit2 minor(1.17↔1.9、1.16↔1.8.1、1.13↔1.7.1、1.12↔1.6.3、1.10↔1.5),并**在 wheel 里捆绑精确版本的 libgit2**("Update wheels to libgit2 v1.7.2" 等)。即"绑定与库版本一对一 + 分发物自带库"。来源:[pygit2 CHANGELOG](https://github.com/libgit2/pygit2/blob/master/CHANGELOG.md)。
- **Fedora**:并行 soname 子包让 1.5/1.6/1.7/1.8 与当前版共存([Repology Fedora 各版本条目](https://repology.org/project/libgit2/versions));**Homebrew** `@1.7/@1.8` formula、**Gentoo/nixpkgs** 多版本同理。
- **fugit2 自己**(负面参照,即 ticket 所指差距):`ffi.load(M.library_path)` 裸调、默认 `"libgit2"`(需要 dev 包),无 `git_libgit2_version` 探测、无版本矩阵、加载失败直接向用户抛 Lua 错误、无 CLI 降级路径(核对了 `lua/fugit2/core/libgit2.lua:704-728` 的惰性加载器)。唯一兜底是 `setup { libgit2_path }` 让用户手工指定。

### 4.3 建议的加载器形态(给 PoC/绑定 ticket 的直接输入)

```lua
-- 伪代码
local CANDIDATES = {
  config.libgit2_path,          -- 用户显式配置优先
  "libgit2.so.1.9", "libgit2.so.1.8", "libgit2.so.1.7",  -- 显式 soname:不要求 dev 包
  "libgit2",                    -- dlopen("libgit2.so"),dev 包/Arch/brew
}
for _, name in ipairs(CANDIDATES) do
  local ok, lib = pcall(ffi.load, name)
  if ok then
    local maj, min, rev = probe_version(lib)   -- cdef git_libgit2_version + pcall
    local policy = COMPAT[maj .. "." .. min]   -- {["1.7"]=..., ["1.8"]=..., ["1.9"]=...}
    if maj ~= 1 then return false, ("libgit2 %d.%d 不受支持"):format(maj, min) end
    if policy then
      apply_enum_overrides(min)                -- 1.9: SAFE=0/NONE=1<<30/APP=7 等
      return lib
    end
  end
end
return false, "未找到可用的 libgit2 ≥1.7,回退 CLI 后端"
```

配套原则:

- **major gate 硬拒绝**:`git_libgit2_version` 返回 major≠1 → 不加载、提示 2.0 待适配(§2.4)。
- **枚举值按版本注入**:GIT_CHECKOUT(1.9 重排)、GIT_CONFIG_LEVEL(1.8 插 WORKTREE)、GIT_OPT 表(1.8 追加 33+;fugit2 表已到 42,按版本裁剪)、GIT_BLAME(1.9 无新增位)。
- **版本化的功能开关**:1.9 上忽略 `blame_hunk.boundary`(或读 `summary` 需新版 cdef);1.7 上不读 `config_entry.level`;`git_commit_create_from_stage` 等新 API 用符号探测后启用。
- **降级路径**:加载失败/版本不符 → `vim.notify` 一次性告警 + 回退现有 CLI 后端,进程内永不因 ffi 崩溃。
- **文档化每渠道安装命令**,并说明 dev 包与运行时包的区别(或干脆只用显式 soname 免除 dev 依赖)。

## 5. 结论:给"绑定与分发决策"的输入

1. **最低支持版本建议 1.7,积极支持 1.8/1.9,cdef 以 1.8 布局为基准**:
   - 1.7 覆盖 Ubuntu 24.04(支持到 2029)及以后的一切主流渠道;1.7 与 1.8/1.9 的关键 options 结构实测同形(§3.2),增量成本是三个小的版本补丁(config entry 不读 level / APP 枚举 / 无 from_stage API)。
   - 1.9 是事实上的最大基数(Debian stable、Ubuntu 26.04、Fedora、Arch、brew、nix stable),枚举补丁必须第一天就有。
   - 1.6 及以下(bookworm 的 1.5、jammy 的 1.1)差异过大(config entry 旧形状、无 oid_type(1.5)、旧 blame/checkout 语义),**建议不支持**,引导用户装 backports/新版或走 CLI。
2. **ABI 风险的定量结论**:fugit2 模式(手写 cdef + 系统 libgit2)在 1.7–1.9 区间**可行且风险可控**——90% 的声明三代稳定,已知坑是可枚举的(§3.2 表);2.0 是硬边界,靠 major gate 隔离。
3. **运行时探测必须是第一等公民**:`git_libgit2_version` + 候选 soname 列表 + pcall + 版本矩阵 + CLI 降级,五件套缺一不可(fugit2 五缺其四)。
4. **分发策略参考 pygit2**:文档引导系统包为主;可选支持用户/发行方提供的自备库路径(`libgit2_path`);如果未来要做"免依赖"安装,pygit2 的捆绑式分发(在分发物内附带预编译 .so,加载时优先)是被验证过的模式,但会引入安全更新运维成本,应作为后续独立决策。

## 6. 来源清单

**上游官方(政策/发布/头文件)**

- Releases(版本与日期):https://github.com/libgit2/libgit2/releases
- 官方 changelog(1.4–1.9 全部破坏性变更):https://github.com/libgit2/libgit2/blob/main/docs/changelog.md
- 官方 API/ABI 稳定政策:https://github.com/libgit2/libgit2/blob/main/docs/api-stability.md
- 2.0 破坏性变更公告:https://github.com/libgit2/libgit2/discussions/6988
- 头文件实对照:checkout.h / blame.h / config.h / diff.h / oid.h / common.h @ v1.7.0、v1.8.0、v1.9.0(https://raw.githubusercontent.com/libgit2/libgit2/<tag>/include/git2/…)
- v1.9.0 checkout.c(枚举位检测实现):https://github.com/libgit2/libgit2/blob/v1.9.0/src/libgit2/checkout.c

**发行版**

- Debian:https://tracker.debian.org/pkg/libgit2
- Ubuntu:https://launchpad.net/ubuntu/+source/libgit2
- Fedora:https://packages.fedoraproject.org/pkgs/libgit2/ (各 release 版本经 https://repology.org/project/libgit2/versions )
- Arch:https://archlinux.org/packages/extra/x86_64/libgit2/
- Gentoo:https://packages.gentoo.org/packages/dev-libs/libgit2/changelog
- Homebrew:https://formulae.brew.sh/api/formula/libgit2.json
- nixpkgs:https://github.com/NixOS/nixpkgs/blob/master/pkgs/by-name/li/libgit2/package.nix 及 release-25.05/25.11 分支
- 聚合核对(Alpine/EPEL/多版本):https://repology.org/project/libgit2/versions

**LuaJIT FFI 语义**

- ffi.load:https://luajit.org/ext_ffi_api.html
- 库命名空间惰性绑定/无类型校验/vararg 转换:https://luajit.org/ext_ffi_semantics.html

**绑定生态实践**

- pygit2(版本锁定 + wheel 捆绑):https://github.com/libgit2/pygit2/blob/master/CHANGELOG.md

**本地代码**

- `~/workerspace/fugit2.nvim/lua/fugit2/core/libgit2.lua`(cdef 全文,1-698 行声明区、704-728 加载器)
- `~/workerspace/fugit2.nvim/lua/fugit2/core/git2.lua`(boundary 读取 :830、config level 读取 :371、checkout 策略 :2972-2974)
