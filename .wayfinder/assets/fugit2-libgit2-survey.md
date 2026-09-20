# fugit2.nvim 的 libgit2 集成方案调研(charting 资产)

> 由 explore agent 于 2026-09-20 产出;供 `libgit2 直连 PoC`、`绑定与分发方案拍板`、`刷新与线程模型拍板` 等 ticket 缩放引用。对象:`~/workerspace/fugit2.nvim`(MIT)。

## 一、架构概述

fugit2 是一个 Magit 风格的 Neovim Git GUI,核心卖点是"git 操作不走 shell 子进程,而是直接通过 LuaJIT FFI 调用系统安装的 libgit2 C 库"(CLAUDE.md:24、58)。分层结构如下(引用 CLAUDE.md:33-54):

```
plugin/fugit2.lua                 # 注册 :Fugit2 / :Fugit2Graph / :Fugit2Diff / :Fugit2Blame / :Fugit2CherryPick / :Gwrite 命令
  └─ lua/fugit2/init.lua          # setup、repo 缓存(按 workdir 前缀缓存,支持 worktree)、命令分发
       ├─ core/libgit2.lua        # 纯手写 FFI cdef(1307 行)
       ├─ core/git2.lua           # Lua OOP 封装层(4475 行,主 API)
       ├─ core/gpgme.lua          # GPGme FFI 绑定(656 行)
       ├─ core/git_gpg.lua        # GPG/SSH 签名编排(265 行)
       ├─ core/blame.lua          # git blame --porcelain 输出解析(CLI 路径用)
       ├─ core/git_rebase_helper.lua # rebase 操作枚举/辅助
       ├─ core/git_hooks.lua      # hook 路径发现
       ├─ git_absorb.lua          # git-absorb 风格 fixup(libgit2 patch/diff)
       └─ view/                   # NUI 浮窗 UI:git_status(约 2700+ 行)/git_graph/git_diff/git_blame(_file)/git_rebase/git_pick + components/
```

- 入口命令注册:`plugin/fugit2.lua:1-24`
- repo 缓存逻辑(worktree 兼容):`lua/fugit2/init.lua:29-82`
- 每个视图是自包含模块,持有 `git2.Repository` 对象并自理生命周期(CLAUDE.md:60-61)

## 二、绑定与构建机制

### 2.1 绑定方式:纯手写 LuaJIT FFI,无第三方绑定库,无内嵌 C

**`core/libgit2.lua`(声明层)与 `core/git2.lua`(封装层)的关系:**

| 文件 | 职责 | 规模 |
|---|---|---|
| `lua/fugit2/core/libgit2.lua` | `ffi.cdef[[...]]` 集中声明所有需要的 libgit2 C 结构体/函数签名(8-698 行);导出枚举常量、错误码、options-INIT 表;提供惰性库加载器 | 1307 行 |
| `lua/fugit2/core/git2.lua` | `require "fugit2.core.libgit2"`(第 2 行)后,把裸 C 符号包装成 Lua 类:`Repository/Object/ObjectId/Blob/Tree/TreeEntry/Tag/Commit/AnnotatedCommit/Reference/Index/RevisionWalker/Signature/Patch/Diff/Blame/BlameHunk/Rebase/Remote/Config/Error`(类定义见 75-243 行;方法如 `Repository:*` 82 个,见 2413-4363 行),全部带 `---@class` EmmyLua 注解 | 4475 行 |

**没有使用 lgit2 等现成绑定,也没有任何内嵌 C 源码(仓库根本没有 `src/` 或 `.c` 文件),没有编译产物。** 它在运行时 `ffi.load` 系统动态库:

- 惰性加载器(关键实现)`lua/fugit2/core/libgit2.lua:704-728`:

  ```lua
  M.library_path = "libgit2"
  local lazy_C = {
    __index = function(table, key)
      local libgit2 = ffi.load(M.library_path)
      if M.libgit2_init_count == 0 then
        M.libgit2_init_count = libgit2.git_libgit2_init()  -- 只 init 一次
      end
      rawset(M, "C", libgit2)
      return libgit2[key]
    end,
  }
  ```

  首次访问任意符号才 dlopen,并保证 `git_libgit2_init()` 只调用一次(线程计数)。
- 路径可配置:`setup_lib(path)`(724-728),由 `init.lua:23` 在 `setup({libgit2_path=...})` 时注入(README.md:134)。

**cdef 覆盖面**(libgit2.lua:370-697):`git_libgit2_init/opts`、blame、blob、checkout、oid、message_prettify、object、apply、commit(含 create/create_buffer/create_with_signature/amend/extract_signature)、config、diff/patch/stats、reference、revwalk、remote(只读)、branch、repository、index、status、tree、reset_default、graph_ahead_behind、signature、tag、annotated_commit、rebase、stash、cherrypick——共约 180 个函数声明。

**C struct 布局用 Lua 表模拟**:`POW` 位移表(760-793)+ 嵌套 options INIT(1263-1306),例如 `GIT_REBASE_OPTIONS_INIT` 内嵌 merge/checkout options(1283-1294),传给 `ffi.new("git_rebase_options[1]", INIT)` 直接按内存布局初始化(git2.lua:4106)。

内存管理:所有 wrapper 用 `ffi.gc` 挂 C 释放函数(如 `Rebase.new` → `ffi.gc(rebase.rebase, git_rebase_free)`,git2.lua:2064-2068;gpgme Context/Data/Key 同理,gpgme.lua:396、481、523)。

### 2.2 构建与分发:零编译,luarocks 只装 Lua,二进制来自系统

- **Makefile:1-11** 只有 `test`(busted via nlua)/`format`(stylua)/`deps`(luarocks install rockspec)三个目标——**没有任何编译步骤**。
- **`fugit2.nvim-scm-1.rockspec:29-36`**:`build.type = 'builtin'`,copy_directories 只有 doc/plugin/ftplugin,**无 C 构建**;依赖只有 `lua>=5.1, nui.nvim, nvim-web-devicons, plenary.nvim`。
- **发布版 rockspec 模板 `.github/workflows/rockspec.template:30-34`** 声明 `external_dependencies = { GIT2 = { library = 'git2' } }`——luarocks 安装时只做系统库探测,不编译。
- **CI 安装系统 libgit2**:
  - Linux(ubuntu-24.04, nvim stable+nightly):`apt install libgit2-1.7` + 软链 `/usr/local/lib/libgit2.so` + `ldconfig`(`.github/workflows/lint-test.yml:46-52`)
  - macOS(macos-14):`brew install libgit2`(lint-test.yml:80-84)
  - LuaRocks 发布:`nix profile install nixpkgs#libgit2` 并把 `GIT2_DIR` 传给 luarocks-tag-release(`.github/workflows/luarocks.yml:27-42`)
- **`.tool-versions`**:仅 `lua 5.1.5`(开发测试环境,配合 nlua + busted,见 `nlua.busted:1-13`、CLAUDE.md:63-65)。
- **用户获得二进制的方式**:不存在插件方分发的 `.so`——用户按 README.md:32 的 wiki 指引用系统包管理器装 libgit2(Linux `libgit2-dev`、macOS `brew install libgit2`,CLAUDE.md:65),或 `setup({ libgit2_path = "..." })` 指到自定义路径;GPGme 为可选依赖(README.md:34-38)。Rocks.nvim 用户 `:Rocks install fugit2.nvim`(README.md:47),Lazy 用户直接 git clone(README.md:57-78,`build = false`——确认无需构建)。
- **平台支持**:官方仅 Linux + macOS(CI 矩阵);Windows 无 CI、无文档,`ffi.load "libgit2"` 在 Windows 需要额外处理 DLL 命名,基本属于未支持状态。

## 三、能力覆盖

### 3.1 libgit2 直连(经 git2.lua 封装)

| 操作 | libgit2 API(cdef 行号) | git2.lua 封装(行号) | 视图调用点 |
|---|---|---|---|
| 打开 repo | `git_repository_open_ext`(libgit2.lua:577) | `Repository.open`(2447) | init.lua:49 |
| status 列表 | `git_status_list_new/byindex`(614-617) | `status/status_file/status_head_upstream`(3338/3163/3209) | git_status.lua:917、1137 |
| diff(全组合) | `git_diff_tree_to_tree/index_to_workdir/tree_to_index/tree_to_workdir`(508-511)、`find_similar`、stats/patch(507-532)、`git_diff_from_buffer`(513) | `diff_helper` 等 6 个 diff 方法(3786-4007) | git_status.lua:1139、1750、1772;git_diff.lua:241、246 |
| apply(hunk 级 stage/unstage) | `git_apply`(420) | `apply_workdir/apply_index/apply`(4008-4051) | git_status.lua:651-653 |
| index 操作 | `git_index_add/add_bypath/add_from_buffer/remove_bypath/remove_directory/write/write_tree/conflict_*/reuc_add`(590-612) | `Index:*`(git2.lua 1445-2000 段) | file_tree_view.lua:364-385;commands.lua:43 |
| unstage/reset | `git_reset_default`(637) | `reset_default`(2938) | git_status.lua:737;file_tree_view.lua:364、374 |
| checkout/切分支 | `git_checkout_head/index/tree`(400-402)+ `GIT_CHECKOUT` 枚举(1207-1233) | `checkout_index/head/tree/checkout`(2991-3068) | git_status.lua:2004、2094;git_rebase.lua:700 |
| commit | `git_commit_create/_v/create_buffer/create_with_signature/amend`(439-490) | `create_commit/create_commit_content/create_commit_with_signature/amend*`(3465-3727) | git_status.lua:1455-1597 |
| log/graph | `git_revwalk_*`(548-556) | `walker`(3728) | git_graph.lua:70;git_status.lua:159、1100 |
| branch | `git_branch_iterator/lookup/create/upstream/upstream_name/remote_name`(567-575) | `create_branch/branches/branch_upstream_name`(2760/2777/3106) | git_graph.lua:132-136;git_status.lua:1996 |
| tag | `git_tag_lookup/list`(645-648) | `tag_list/tag_lookup`(2820/4052) | git_graph.lua:151 |
| blame(单文件) | `git_blame_file/buffer`(384-387) | `blame_file`(2609)、**`blame_file_async`(4278,worker 线程)** | (见 3.2 说明) |
| ahead/behind | `git_graph_ahead_behind/descendant_of`(639-640) | `ahead_behind`(2846) | git2.lua:3244(status_head_upstream 内) |
| **交互式 rebase(in-memory)** | `git_rebase_init/open/next/commit/inmemory_index/operation_*/abort/finish`(656-670) | `Rebase` 类 + `rebase_init/rebase_open`(2008-2350、4104-4140) | git_rebase.lua:98、139、169、515-716 |
| cherry-pick | `git_cherrypick_commit`(697) | `cherry_pick`(4210,纯内存:merge 出 index → write_tree → commit_create) | git_status.lua:2597;init.lua:147 |
| stash | `git_stash_save/foreach/apply/pop/drop`(682-686) | `stash_save/list/apply/pop/drop`(4152-4201) | git_status.lua:2644-2730 |
| config | `git_config_*`(492-505) | `Config:*`(268-385) | git_status.lua:886-892 |
| 引用/reflog 消息 | `git_reference_*`(536-546) | `reference_lookup/create_reference/update_head_for_commit`(2862-2711) | git_rebase.lua:684 |
| commit 签名提取/校验 | `git_commit_extract_signature`(434) | `commit_signature`(2716) | 配合 gpgme(见第五节) |
| git-absorb(fixup 吸收) | patch/diff API | `git_absorb.lua:23-60` 用 `patch:hunk/hunk_line` | status 视图 |

**rebase 的特别设计**:`git_rebase.lua:515-716` 的 `rebase_start/rebase_continue/rebase_finish` 用 `inmemory` rebase(不落 `.git/rebase-merge` 状态),squash/fixup 通过 `rebase:amend`(633-637)实现 libgit2 原生不支持的语义;冲突时检测 `GIT_EUNMERGED` 并读 `inmemory_index`(600-617);完成后 `update_head_for_commit` + `checkout_head(SAFE|ALLOW_CONFLICTS|RECREATE_MISSING)` 同步工作区(678-706)。设计文档:`docs/inmemory-rebase.md:1-60`、`docs/cherry-pick.md`、`docs/stash-management.md`。

### 3.2 CLI fallback(plenary.job 子进程)

| 操作 | 实现位置 | 说明 |
|---|---|---|
| **push** | git_status.lua:2150-2239 → `run_command("git", {"push", ...})` | 支持 `-u`、`--force`、`--force-with-lease=branch:oid`(用 libgit2 拿到的 OID 构造 lease) |
| **fetch** | git_status.lua:2257-2286 | pushremote/upstream 两种目标 |
| **pull** | git_status.lua:2303-2332 | 透传用户额外参数(如 `--rebase`) |
| **blame 全量视图** | git_blame.lua:106-127、git_blame_file.lua:70-86 | `git blame --date=unix --porcelain`,由 `core/blame.lua:37-158` 解析;loading spinner + `job:sync(5000)` |
| **git hooks** | git_status.lua:2338-2348 + git_hooks.lua:40-46 | commit 前执行 `pre-commit`(1443、1490、1586) |
| **SSH 签名** | git_gpg.lua:91-97 | `ssh-keygen -Y sign -n git` |
| 任意 git 命令 | git_status.lua:2355-2402 | Magit 风格命令队列 + 输出回显 popup |

**注意一个"名不副实"**:libgit2 的 `blame_file/blame_file_async` 已完整封装(git2.lua:2609、4278),但两个 blame 视图实际都走 CLI porcelain(推测原因:porcelain 输出一次带全 committer 信息/边界/metadata,libgit2 hunk API 需要逐 commit 二次查询;blame 详情弹窗则回到 libgit2——`core/blame.lua:280-303` 用 `repo:commit_lookup` + `diff_commit_to_commit`)。

### 3.3 不支持

- **clone**(无 `git_clone` 声明)
- **merge**(无 `git_merge()` 函数声明——`git_merge_options` 只是 cherrypick/rebase 的内嵌参数;pull 走 CLI)
- **remote 网络操作直连**:cdef 只有 remote 只读 API(558-565),**没有** `git_remote_fetch/push`、credentials callbacks——这是 push/pull/fetch 走 CLI 的根因(认证/ssh-agent/credential-helper 回调太复杂)
- submodule、worktree 管理、describe、notes、reflog 遍历:均无绑定

## 四、异步与刷新模型

### 4.1 异步模型:默认同步 FFI + 两个 uv.new_work worker 线程 API

- **绝大多数 libgit2 调用是同步阻塞**的,直接在 Neovim 主线程执行;UI 更新一律 `vim.schedule` 包裹(git_status.lua:300、943、1126、1141;git_diff.lua:168、576;git_blame.lua:91、252)。
- **worker 线程(核心亮点)**:`lua/fugit2/core/git2.lua:4272-4363`
  - `Repository:blame_file_async`(4278-4317)与 `Repository:status_async`(4321-4363)用 **`uv.new_work(work_fn, after_work_fn)`**(libuv 线程池,4310、4361)。
  - 跨线程传指针的技巧:**把 `git_repository*` cast 成 `intptr_t` 数字**传入(4313、4362);work_fn 在独立 Lua state 里 `require` libgit2 模块、用**第一个参数传入的 `libgit2.library_path` 重新 `ffi.load`**(4285-4287、4328-4330),执行完把结果指针 cast 回整数返回;主线程回调里 cast 回 `git_blame*`/`git_status_list*` 并 free(4352-4357)。
  - 使用点:`git_status.lua:1137` 用 `status_async` 刷新文件树(状态计算移出主线程,大 repo 不卡 UI)。
- **CLI 路径**:plenary.job 异步,`on_exit = vim.schedule_wrap(...)`(git_status.lua:2442-2473);带命令队列(`command_queue`,2355-2400,250ms uv timer 轮询排队)、超时(`command_timeout`,README.md:140、153,默认 15000ms)。blame 用 `job:sync(5000)` 同步等待 + 100ms timer 动画(git_blame.lua:78-97)。
- **没有** `uv.new_thread`、没有自建线程池;也没有 `fs_event`/`fs_poll` watcher(grep 全仓库仅 git_hooks.lua:24 的 hook 名 `fsmonitor-watchman` 撞词)。

### 4.2 状态刷新:事件驱动 + 手动,非 watcher/轮询

刷新触发点(全部显式):

1. 窗口打开时 `GitStatus:update`(git_status.lua:296;`update` 定义在 900-1155)
2. 每个本地操作(commit/stage/rebase/stash…)完成后 `update_then_render`(1157-1166)
3. **手动按键 `g`**(2824-2827;README.md:200 "g refreshes the status window")
4. CLI 命令(push/pull/fetch/hook)`on_exit` 成功且 `refresh=true` 时(2456-2458)
5. blame split 视图监听 `BufWritePost` autocmd 自动重算(git_blame.lua:236-243、353-354)
6. diff 视图监听 `BufWriteCmd`/`BufModifiedSet`,直接把 fugit2 diff buffer 的修改写回 index(git_diff.lua:405-425)
7. index 改动延迟落盘:unmount 时统一 `write_index`(1241-1276)

**对比 CLI 输出解析的优势**(为什么这套刷新可行且便宜):`git_status_list_new` 一次调用直接返回结构化 `git_status_entry[]`(head_to_index + index_to_workdir 双 delta、flag 位),不需要 `git status --porcelain` 文本解析、没有子进程/格式版本漂移问题;rename 靠 `git_diff_find_similar`;ahead/behind 是 `git_graph_ahead_behind` 而非解析 `git status -sb`;错误是 `GIT_ERROR` 枚举(git_status.lua:931-938 的分支处理)而非 exit code + stderr 猜测。

## 五、GPG 签名

**为什么需要它**:libgit2 自身不执行 GPG 签名——它只提供 `git_commit_create_with_signature`(接收"外部已算好的签名串",libgit2.lua:474)。一旦绕开 `git commit` CLI,签名就必须插件自己做。fugit2 的方案:

1. **`core/gpgme.lua`**:手写 FFI 绑定 GPGme C 库(cdef 11-243 行:context/data/key/signers/op_sign/op_verify 等;`gpgme_check_version "1.18.0"` 在 257;lazy load 同 libgit2 模式,264-290)。高层 API:`sign_string_detach`(583-612,armor detach 签名)、`verify_detach`(620-654)。
2. **`core/git_gpg.lua`**:签名编排层。
   - OpenPGP 路径(142-149):`create_gpgme_context(keyid)`(34-56,gpgme get_key + add_signer)→ 对 commit 内容做 detach 签名。
   - SSH 路径(64-111):`user.signingkey` 为字面 key(`key::` 前缀或 `ssh-` 开头)时先用 `uv.fs_mkstemp` 写临时 key 文件(71-84),再跑 `ssh-keygen -Y sign -n git -f <key> [-U]`(86-97,plenary job 同步等待 2s)。
   - 统一落库(120-133):`repo:create_commit_content`(`git_commit_create_buffer` 拿待签名内容,git2.lua:3498)→ 签名 → `repo:create_commit_with_signature`(git2.lua:3534)→ `update_head_for_commit`。
   - 对外入口:`create_commit_gpg / amend_commit_gpg / reword_commit_gpg / extend_commit_gpg`(177-263),由 status 视图在 commit/amend/reword/extend 时按 git config 调用。
3. **签名提取/验证**:`Repository:commit_signature`(`git_commit_extract_signature`,git2.lua:2716-2732)+ gpgme `verify_detach`。

即:**签名执行 = GPGme(OpenPGP)/ ssh-keygen(SSH),签名落库 = libgit2**,完全不碰 `git commit` CLI。

## 六、对"另一个插件想复用这套方案"的可借鉴点与风险点

### 可借鉴点

1. **三层解耦可直接移植**:`libgit2.lua`(cdef+枚举+INIT)与 `git2.lua`(OOP 封装)不依赖任何 fugit2 UI,可作为独立模块抄走;视图只依赖 `Repository` 对象。
2. **惰性 `ffi.load` + `setup_lib(path)` + `opts.libgit2_path`**:解决发行版库名/路径差异(libtgit2.so.1.7 → 软链,见 CI);`git_libgit2_init` 计数防重复初始化(libgit2.lua:710-721)。
3. **Lua 表模拟 C struct INIT**(1263-1306):`ffi.new("git_rebase_options[1]", M.GIT_REBASE_OPTIONS_INIT)` 一行初始化嵌套结构,比逐字段赋值优雅且可读。
4. **`uv.new_work` + intptr 指针传递 + 线程内重新 ffi.load`**(git2.lua:4278-4363):把 status/blame 等重活移出主线程的成熟范式,复用时注意在 work_fn 里不要触碰任何 vim API。
5. **in-memory rebase / cherry-pick 模式**:不落 `.git` 序列化状态、冲突走 `inmemory_index` + `GIT_EUNMERGED`、完成后 `checkout_head` 同步工作区(git_rebase.lua:600-706)——可作为"改写历史的无痕操作"蓝本。
6. **签名链路** `create_buffer → 外部签名 → create_with_signature`(git_gpg.lua:120-133)对任何需要签名 commit 的插件通用。
7. **repo 缓存按 workdir 前缀建键**(init.lua:44-74),天然支持 worktree。
8. **测试基建**:busted + nlua(headless Neovim runtime)、`GIT2_DIR` 环境变量注入库路径(spec/fugit2/git2_spec.lua:9-10)、CI 三平台装库方式(apt/brew/nix)。

### 风险点

1. **强依赖系统 libgit2,且是 ABI 级耦合**:cdef 硬编码结构体内存布局(checkout/diff options 内嵌回调指针),libgit2 大版本升级(如 git_buf→git_str 迁移期,cdef 里两个都留了,41-61)可能直接崩溃;没有运行时版本探测(仅 gpgme 有 check_version)。用户装插件的摩擦主要在这里(必须先装系统库)。
2. **网络操作是硬骨头,连作者都绕道 CLI**:没有 credentials callbacks/`git_remote_fetch` 绑定,push/pull/fetch 全走 `git` CLI(git_status.lua:2150-2332)。复用方若想"纯 libgit2"做网络,要自绑 libssh2/credential 回调,复杂度远超本地操作。
3. **Windows 无支持**:无 CI、无文档、`ffi.load "libgit2"` 的 DLL 解析未处理。
4. **大 repo 性能**:README.md:236 自己引用 libgit2 上游性能 issue(#4230);同步 FFI 路径(diff/revwalk)在大仓库仍可能卡 UI,只有 status/blame 有 worker 线程版本。
5. **手写 cdef 的维护成本**:约 180 个函数 + 几十个结构体需要与上游头文件人工同步;fugit2 靠 spec 测试兜底,但覆盖有限。
6. **混合双轨(blame 用 CLI、其余用 libgit2)**:说明 libgit2 并非处处够用(porcelain 元数据更全),复用时要做好"哪些操作值得直连"的取舍;两套代码路径(double maintenance)。
7. **线程安全边界微妙**:worker 线程与主线程共享 `git_repository*`,依赖 libgit2 的线程安全保证;对象生命周期(主线程 free vs worker 持有)需谨慎——fugit2 的做法是 worker 只产出新对象、主线程回调里 free(4352-4357)。
8. **GPG pinentry 交互风险**:gpgme 同步调用若触发 pinentry 弹窗,可能阻塞 Neovim UI(需要用户配 loopback pinentry);SSH 签名的临时 key 文件清理路径(git_gpg.lua:99-102)也值得注意。

## 一句话总结

fugit2 的方案 = **"手写 LuaJIT FFI cdef + Lua OOP 封装直连系统 libgit2,零编译零二进制分发;重 IO 用 uv.new_work 线程池,网络与 blame 退回 CLI,GPG 签名用 GPGme/ssh-keygen 补位 libgit2 的留白;刷新靠操作后事件驱动 + 手动按键,不装 watcher"**——是一套可移植性较强但需要用户自备系统库、且网络操作仍离不开 git CLI 的务实混合架构。
