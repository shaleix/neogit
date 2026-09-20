# neogit git 层调研报告(charting 资产)

> 由 explore agent 于 2026-09-20 产出;供 `性能基线剖析`、`混合后端架构边界拍板` 等 ticket 缩放引用。

## 一、CLI 执行与解析架构

### 1.1 四层关系(自上而下)

```
client.lua (编辑器 RPC 层,只服务于"需要弹编辑器"的命令)
     │  .env(GIT_EDITOR...) 注入
     ▼
lib/git/cli.lua (命令构造层:链式 Builder → process.new)
     │
     ▼
runner.lua (执行策略层:同步/异步/PTY 交互/认证重试)
     │
     ▼
process.lua (进程层:vim.fn.jobstart spawn、输出收集、错误展示)
```

### 1.2 cli.lua — 命令构造层(`lua/neogit/lib/git/cli.lua`)

- **声明式命令注册表** `configurations`(L426–1023):每个 git 子命令(`status`、`log`、`rebase`、`merge`、`stash`、`bisect` 等 40+ 个)用 `config { flags, options, aliases, short_opts }` 声明可用旗标。如 `status` 在 L481–491 声明 `-z`、`--porcelain`。
- **链式 Builder 元表** `mt_builder`(L1069–1170):`args/arg_list/files/paths/input/stdin/prefix/env/in_pty` 全部返回 self,支持 `git.cli.rebase.interactive.onto.args(...)` 式链式调用;`__tostring`(L1158)可输出完整命令字符串(测试用,`tests/specs/neogit/lib/git/cli_spec.lua:9-12`)。
- **`new_builder(subcommand)`**(L1172–1298)中 `to_process`(L1187–1244)拼接最终 argv,固定注入全局参数(L1216–1225):

  ```
  git --no-pager --no-optional-locks -c core.preloadindex=true -c color.ui=always -c diff.noprefix=false <subcmd>
  ```

  并根据 hooks 情况加 `--literal-pathspecs`(L1227–1229),最后 `process.new{ cmd, cwd = git.repo.worktree_root, ... }`(L1233–1243)。
- **调用选项** `make_options`(L1246–1284):`await`(同步)、`hidden`、`trim`、`remove_ansi`、`long`(长时间命令)、`pty`、`ignore_error`、`on_error`。
- `call(options)`(L1291–1296)→ `runner.call(p, opts)`。
- 特例:`worktree_root/git_dir/worktree_git_dir/is_inside_worktree`(L1031–1063)不走 process,直接 `vim.system(cmd):wait()` 同步阻塞。
- git 可执行文件路径可配置:`get_git_executable()`(L9–12),来自 `config.get_git_executable()`(`lua/neogit/config.lua:1333`),默认 `"git"`(README L138)。

### 1.3 process.lua — 进程层(`lua/neogit/process.lua`)

- **实际 spawn 用的是 `vim.fn.jobstart`**(L431–440,带 `on_stdout/on_stderr/on_exit/pty/cwd/env`),即 libuv 的 Neovim 封装,**不是裸 `vim.loop.spawn`**。
- 输出收集:`handle_output`(L283–307)处理跨 chunk 的断行,把完整行推入 `res.stdout/res.stderr`(ProcessResult,L69–76);`trim()`/`remove_ansi()`(L86–99)按 opts 事后处理。
- `on_exit`(L361–428):非零退出时区分 git hook 失败(L383–391,强制弹 Git Console)与普通错误(通知/console),受 `on_error` 回调控制。
- stdin:启动后立即 `nvim_chan_send` 写入 input 并发送 EOT `\04`(L461–472,`git apply -` 依赖此)。
- 同步等待:`Process:wait(timeout)` 用 **`vim.fn.jobwait`**(L231–242)。
- 异步封装:`spawn_async`(L261–272)用 `neogit.lib.async` 的 `a.wrap` 包成可 await 的叶子,任务取消时会 kill job(cancel handle)。
- UI 副作用:慢命令自动开 ProcessBuffer/Spinner/Timer(L134–226)。

### 1.4 runner.lua — 执行策略层(`lua/neogit/runner.lua`)

- `M.call(process, opts)`(L132–228)是所有命令的单一入口:
  - `opts.await` → `run_await()`:`spawn()` + `proc:wait()` **同步阻塞**(L158–164);
  - 否则 `run_async()`:`proc:spawn_async()`(L151–156);若不在 async 上下文抛错则 **fallback 到同步**(L171–175);
  - PTY 交互(L138–147):`on_partial_line` → `handle_line_interactive`(L80–127),正则匹配 `Are you sure you want to continue connecting`/`Username for`/`Password for`/`Enter passphrase`/`fatal`,用 Neovim 输入 UI 向用户要凭据后 `process:send(value .. "\r\n")`(L118);
  - 认证失败重试至多 3 次,克隆进程重跑(L186–211),`on_retry` 钩子被 `client.lua` 用来保住用户已写的 commit message(`client.lua:148-176`);
  - 结果压入 `M.history`(L11–34),即 `$` 命令历史缓冲的数据源。

### 1.5 client.lua — 编辑器 RPC 层(`lua/neogit/client.lua`)

- **不执行 git 命令**,而是让 git 自己 fork 出一个 `nvim --headless --clean` 作为 `GIT_EDITOR/GIT_SEQUENCE_EDITOR`(L12–53),headless 实例通过 `NVIM` 环境变量找到主实例 RPC 连回(`M.client`,L57–72),再由主实例打开 `buffers/editor` 或 `buffers/rebase_editor`(L96–116)。
- `M.wrap(cmd, opts)`(L133–199):给任意 builder 命令注入编辑器 env 并 `call{pty=interactive}`(L179–182),成功后触发 autocmd(如 `NeogitCommitComplete`)。被 rebase.reword、tag、commit popup 等使用。

### 1.6 同步等待发生的位置(汇总)

| 位置 | 机制 |
|---|---|
| `runner.lua:163` | `proc:wait()` → `vim.fn.jobwait`(所有 `await=true` 调用) |
| `lua/neogit/lib/async.lua:113-118, 372-391` | `Task:wait`/`block_on` → `vim.wait` |
| `lua/neogit/lib/git/diff.lua:291` | `a.util.block_on` 惰性加载文件 diff |
| `lua/neogit/lib/git/cli.lua:1033/1042/1051/1060` | `vim.system():wait()`(repo 探测) |
| `lua/neogit/buffers/status/init.lua:292` | `vim.wait` 等 chdir 目录就绪 |

`lib/async.lua`(L1–22)是**自研 coroutine 库**,plenary.async 的子集替代(wrap/run/void/scheduler/run_all/block_on),这是理解全库异步的钥匙。

## 二、模块读写分类清单(`lua/neogit/lib/git/`)

### 纯"读"(解析型)

| 模块 | 包装的子命令 | 关键行号 |
|---|---|---|
| `status.lua` | `status --porcelain=2 -z`(读)+ `add/reset`(写,见下) | 读:L101;`anything_staged/unstaged`:L253–266 |
| `log.lua` | `log --format=<record>`、`show --format=fuller`、`rev-list --parents`、`verify-commit`、`merge-base --is-ancestor` | `M.list`:L363–400;`M.parse`:L39–178;`graph`(带 ANSI 解析):L308–321 |
| `diff.lua` | `diff [--cached/--no-index] [--shortstat/--stat]` | raw_* 工厂:L305–359;hunk 解析:L163–222 |
| `refs.lua` | `for-each-ref --format --sort` | L10–16、L59–67、L91–127 |
| `rev_parse.lua` | `rev-parse [--short/--verify/--abbrev-ref/--symbolic-full-name]` | L10–47(全读) |
| `branch.lua`(读半) | `branch`/`branch -r`、`branch --show-current`、`reflog show`、`rev-parse --verify`(存在性)、`cherry` | L44–58、L100–110、L142–148、L190–210、L403–418 |
| `files.lua`(读半) | `ls-files`、`ls-tree`、`diff --name-only` | L9–53 |
| `config.lua` | `config --list --null --local` / `--get` / `--set` / `--unset` | 缓存构建:L93–119 |
| `reflog.lua` | `reflog show --format=<record>` | L53–81 |
| `cherry.lua` | `cherry -v` | L7–13 |
| `remote.lua`(读半) | `remote`、`remote get-url` | L64–72 |
| `stash.lua`(读半) | `stash list`、stash reflog | L10–17、L69–71、L90–134 |
| `submodule.lua` | `submodule`(读) | L7–12 |
| `tag.lua`(读半) | `tag --list`、`describe --long --tags`、`for-each-ref`、`ls-remote --tags` | L9–15、L41–57、L61–77 |
| `worktree.lua`(读半) | `worktree list --porcelain` | L49–82 |

### "写"(一次性变更)

| 模块 | 操作 | 关键行号 |
|---|---|---|
| `status.lua` | `add`(stage/`-u`/`-A`)、`reset`(unstage) | L218–245 |
| `branch.lua` | `branch <name>`、`branch -d/-D`、`checkout`、`branch -m`、`--set-upstream-to`、push 分支删除 | L87–96、L166–186、L329–331 |
| `reset.lua` | `reset --soft/--mixed/--hard/--keep`、`checkout-index`(worktree reset)、`checkout/reset -- files` | L8–65 |
| `stash.lua` | `stash push/--staged/--keep-index/apply/--index/drop/store` | L20–81 |
| `index.lua` | `apply`(stdin patch)、`add`、`checkout --`、`reset --`、`read-tree`(临时 index)、`update-index -q --refresh`、备份快照(add+commit+update-ref+reset) | L90–182 |
| `files.lua` | `rm --cached`(untrack)、`mv` | L63–72 |
| `remote.lua` | `remote add/rename/rm/prune` + pushRemote config 清理 | L30–61 |
| `log.lua` | `update-ref`(reset: moving to) | L445–447 |
| `init.lua` | `init` + chdir + refresh | L8–42 |

### 交互式/长时流程(PTY、编辑器、多步)

| 模块 | 流程 | 关键行号 |
|---|---|---|
| `rebase.lua` | `rebase -i [--onto/--autosquash/--autostash]`、`--continue/--skip/--edit-todo/--abort`;`reword` 经 `client.wrap` + `commit --amend!`;`modify/drop` 用 **nvim 内联命令作 GIT_SEQUENCE_EDITOR** | rebase_command:L10–12;instantly:L18–32;continue/skip/edit/abort:L127–141;reword:L82–97;modify/drop:L99–125 |
| `merge.lua` | `merge`、`merge --continue/--abort`(editor env + pty) | L9–30 |
| `cherry_pick.lua` | `cherry-pick [--edit]`、`--continue/--skip/--abort`;`move` 内嵌一次 `rebase -i` | pick:L13–30;move:L52–102;continue/skip/abort:L104–114 |
| `revert.lua` | `revert --no-commit`、`--continue/--skip/--abort`(continue 用 pty) | L10–46 |
| `sequencer.lua` | **不执行命令**,只读 `.git/REVERT_HEAD`、`.git/CHERRY_PICK_HEAD`、`.git/sequencer/todo` 判定进行中状态 | L31–78 |
| `bisect.lua` | `bisect start/good/bad/skip/reset/run`(`long=true`);状态读 `.git/BISECT_LOG` 文件 | L8–55、L64–102 |
| `push.lua`/`pull.lua`/`fetch.lua` | 网络命令 `pty=true`(走 runner 的凭据交互) | push:L12–14;pull:L7–11;fetch:L11–20 |
| `worktree.lua`(写半) | `worktree add/move/remove` | L12–37 |
| `hooks.lua` | 无 CLI,直接扫 `.git/hooks` 目录的 exec bit | L46–65 |

## 三、解析耦合分析

**集中度中等偏散**,分三类:

1. **相对集中:record 分隔符协议**(`lib/record.lua` L1–68)。`log.list`(L323–355 的 `%H/%h/%s...` 字段表)、`refs.list_parsed`(L59–67)、`reflog.list`(L53–61)统一用 `\x1E/\x1F/\x1D` 控制字符分隔,由 `record.decode` 一次解析。这是设计最好的一块。

2. **重 porcelain 依赖、手工正则散落**:
   - `status.lua:72–75` 定义 `match_u/match_1/match_2` 三个模式,手工解析 `--porcelain=2 -z` 输出(L90–212),含 rename 行 `\t` 拼接逻辑(L103–113)——**最脆弱的一处**,对 git porcelain v2 格式硬编码;
   - `branch.lua`:`parse_branches` 解析 `git branch` 人读输出(L13–41),`status()` 解析 `# branch.*` 行(L403–418);
   - `diff.lua`:unified diff hunk 头正则 `^@@ ...` / 组合 diff `^@@@*`(L163–222),以及 `--stat` 表格解析(L394–414);
   - `stash.lua:93` `stash@{(%d*)}: (.*)`;
   - `tag.lua:59` `describe` 输出模式 `(.-)%-([0-9]+)%-g%x+$`;
   - `worktree.lua:54–71` `worktree list --porcelain` 三元组解析;
   - `log.parse`(L39–178)解析 `show --format=fuller` 的**人读格式**头部(bisect 用,bisect.lua:97–99);
   - `runner.lua:86–97` 解析 stderr 交互提示。

3. **完全绕开 CLI、直读 `.git` 内部文件**(libgit2 迁移时的"意外盟友"或"暗雷"):
   - `rebase.lua:192–279`:`rebase-merge|rebase-apply/{head-name,onto,done,git-rebase-todo}`;
   - `sequencer.lua:34–77`:`REVERT_HEAD/CHERRY_PICK_HEAD/sequencer/todo`;
   - `merge.lua:51–68`:`MERGE_HEAD/MERGE_MSG`;
   - `bisect.lua:74–96`:`BISECT_LOG/BISECT_EXPECTED_REV`;
   - `hooks.lua:54–63`、`refs.heads`(L131–141)、`config.lua:86–91`(以 config mtime 做缓存 key)。

## 四、刷新链路

### 4.1 watcher(`lua/neogit/watcher.lua`)

- `vim.uv.new_fs_event()`(L24)单句柄监听**整个 worktree git dir**(非递归,L87 `fs_event_handler:start(self.git_dir, {}, ...)`,改自 gitsigns,L1);
- 回调过滤:`index/ORIG_HEAD/FETCH_HEAD/COMMIT_EDITMSG`、`*.lock`、`~` 结尾、含 4 位数字(备份 ref)忽略(L107–148);
- `debounce_trailing(200ms)` + `throttle_by_id` 合并风暴(L115–121)→ `dispatch_refresh`(L150–160)。
- 注册方:status buffer(L257)、refs_view(L323)、popup 内 config 修改/动作执行后(`lib/popup/init.lua:357、384`)、diffview 集成(`integrations/diffview.lua:104`)。

### 4.2 状态汇聚(`lib/git/repository.lua`)

- `modules` 列表(L8–21)的每个模块通过 `M.register(meta)` 注入 `update_*(state, filter)`;`Repo:tasks`(L249–260)把它们变成任务集,`Repo:refresh`(L294–332)用 `a.util.run_all` **并行执行**,期间写 `tmp_state`(深拷贝,L283–292),完成后原子换 `set_state` 并跑回调;进行中的 refresh 可被 cancel 并 kill 子进程(L308–313)。
- `Repo.instance()` 首次注册即 `dispatch_refresh`(L196–200)。

### 4.3 完整触发链

```
fs event(.git/) ─┐
BufWritePost/ShellCmdPost/VimResume (autocmds.lua:35-51, partial update_diffs)
popup 动作结束 (popup/init.lua:384)
NeogitReset/NeogitBranchReset/NeogitEditorClosed/FocusGained (status/init.lua:264-269 → deferred_refresh)
用户 <c-r> RefreshBuffer (status:195)
     │
     ▼
Watcher:dispatch_refresh / StatusBuffer:refresh (status/init.lua:311-330)
     │
     ▼ git.repo: dispatch_refresh { source, partial, callback }
Repo:refresh → run_all(12 个 update_*) → set_state → run_callbacks
     │
     ▼ callback
buffer:redraw (ui.Status(git.repo.state)) + event "StatusRefreshed" (status/init.lua:325-327)
     │
     ▼ User autocmd
vim.cmd "set autoread | checktime" (autocmds.lua:64-69)
```

## 五、可替换接缝分析(引入 git 后端抽象)

### 5.1 现有组织方式

- `lib/git.lua`(L34–42)是**唯一的模块入口**:`__index` 惰性 `require("neogit.lib.git." .. k)`,`repo` 键特殊化为单例。**没有统一 service/facade**,但这个元表本身就是天然的"按模块整体替换"切点。
- 上层调用习惯:
  - popups/buffers **绝大多数**调用高层模块函数(`git.branch.checkout`、`git.merge.continue` 等,如 `popups/merge/actions.lua:9-17`、`popups/rebase/actions.lua:15-17`);
  - 但有约 **20 处直接 `git.cli.*`** 绕过高层模块(`popups/commit/actions.lua:88,114,134,142,150`、`popups/tag/actions.lua:32,113,229`、`popups/branch/actions.lua:80,90,255,301,331,349...`、`popups/fetch/actions.lua:121` 等);
  - UI 渲染直接消费 `git.repo.state`(`buffers/status/init.lua:252` `ui.Status(git.repo.state, ...)`)。

### 5.2 天然接缝(按性价比排序)

1. **读侧(最划算)**:`repository.lua` 的 `register(meta)` + `update_*(state, filter)` 协议(L228–230、L249–260)。只要新后端能产出相同形状的 `NeogitRepoState`(完整类型标注在 L23–99),状态缓冲/refs 视图**零改动**。status/log/diff/refs/branch 这些高频读路径换成 libgit2 内存对象后,可消灭每次 refresh 的十几个子进程。
2. **模块整体替换**:`lib/git.lua:34-42` 的 `__index` 改为查表(如 `git.branch → backends.cli.branch or backends.libgit2.branch`)。前提是把 popups 里 20 处裸 `git.cli` 调用收拢回模块函数——这是**迁移前的必要清理**。
3. **`ProcessResult` 接口**(`process.lua:69-76`):`stdout/stderr/code + success()/failure()` 被 popup action 广泛检查。后端抽象要么模拟该结构,要么把"命令式返回值"改成"结果对象"并全面改写调用点(工作量最大的方案)。
4. **写侧**:单条写命令(add/reset/checkout 等)语义简单,逐个替换风险低。
5. **不可切**:交互式流程(见下)。

### 5.3 不可替换/最难替换

- **编辑器驱动流程**:`client.lua` 的 GIT_EDITOR headless-nvim RPC 机制 + `runner.lua` 的 PTY 行交互(用户名/密码/passphrase/fatal 处理,L80–127)+ 认证重试(L186–211)。libgit2 没有"交互式 rebase"、没有 ssh 凭据提示协议、不会启动用户 hooks 编辑器——这些**必须永久保留 CLI 实现**。
- `absorb`(cli.lua:745–757,外部工具)、`bisect run`(执行任意 shell 命令)、`log_pager`(diff.lua:239–253 调外部 delta 等)。

## 六、分发与测试约束

### 6.1 分发

- 纯 Lua、零原生依赖、无构建步骤:`plugin/neogit.lua` 只注册 `:Neogit` 等命令;`lua/neogit/lib/async.lua` 自研异步库(明确是 plenary 替代,L1–22),**运行时硬依赖仅为 Neovim ≥ 0.10(`lua/neogit.lua:8-11`)+ 系统 git CLI**。
- README L26–53:可选依赖全部 optional(telescope/fzf-lua/mini.pick/snacks、diffview/codediff、baleia)。
- 安装即 lazy.nvim 拉取,Lua badge(README L14),MIT。支持平台 = Neovim 支持的平台(Win 路径处理见 `client.lua:171`、`index.lua:9`),CI 只测 ubuntu(`.github/workflows/test.yml:16`)。

### 6.2 测试体系

| 命令 | 内容 | 证据 |
|---|---|---|
| `make test` | **headless nvim + plenary(busted 风格)单测**,`sequential=true` | `Makefile:1-2`、`tests/init.lua:14-19`、CONTRIBUTING.md:91–98 |
| `make specs` | **Ruby rspec E2E**,`bundle exec rspec --format Fuubar` | `Makefile:4-5` |
| `make lint` | selene + typos + stylua | `Makefile:7-10` |
| `make typecheck` | llscheck(lua-language-server) | `Makefile:15-16` |
| CI | ubuntu + nvim stable/nightly + ruby/bundler,先 rspec 再 make test | `.github/workflows/test.yml:12-47` |

- Ruby 侧(`Gemfile`:rspec、`neovim`(ruby↔nvim RPC client)、`git`(ruby git 绑定做仓库准备)、fuubar、super_diff 等):`spec/spec_helper.rb:40–50` 在 tmpdir 里 `Git.init` 建 local+remote 裸库,再通过 ruby neovim client 驱动真实 UI(`spec/popups/*.rb` 18 个 popup spec + 8 个 buffer spec)。
- **含义:E2E 断言基于真实 git CLI 行为与真实 UI 文本**,这对换后端是有效的安全网,但也意味着 libgit2 与 CLI 的任何行为差异都会被 rspec 捕获。

## 七、迁移到 libgit2 的主要风险点

1. **交互式流程对 CLI 的结构性依赖**(最大风险):`rebase -i`(含 `GIT_SEQUENCE_EDITOR=":"`、nvim 内联 sed 式 editor 的 modify/drop hack,`rebase.lua:99-125`)、merge/cherry-pick 编辑、push/pull/fetch 的 PTY 认证(`runner.lua:80-127`)、`client.lua` 整个 RPC 编辑器机制——libgit2 均无对应能力,只能"混合后端":交互走 CLI、读写走 libgit2,代码路径分裂。
2. **状态解析散落度**:porcelain v2 手工解析(`status.lua:72-212`)、branch 人读输出(`branch.lua:13-41`)、diff hunk 正则(`diff.lua:163-222`)、stash/describe/worktree 各自为政;换后端等于重写全部读路径。但反过来,`repository.lua` 的 `update_*` 协议是良好的收敛点(风险可控)。
3. **`.git` 内部文件直读与 fs 刷新假设**:rebase/sequencer/merge/bisect 状态靠直读文件;`config.lua:86-91` 靠 config mtime 失效缓存;**watcher 靠 `.git` 目录 fs event 触发刷新**——若 libgit2 后端直接写 ref/config 而不经文件可见变更或写入方式不同(wal/原子 rename 仍会触发,但内存态更新不会),刷新链会静默失效。
4. **`ProcessResult` 接口泄漏到 UI**:popup action 大量检查 `result:success()/stdout/stderr`(如 `stash.pop` L43–51、`worktree.add` L13–18),后端抽象必须提供等价物或改写所有调用点(含 popups 里约 20 处裸 `git.cli` 用法)。
5. **git hooks 语义**:CLI 层会探测 hooks 存在(`cli.lua:14-28, 1240`、`hooks.lua`)、hook 失败特殊弹 console、`--no-verify` 处理;libgit2 的 hooks 触发时序与编辑器行为不同,commit/rebase/merge/push 体验可能回归。
6. **分发破坏**:当前"plugin manager 即装即用 + 零编译";引入 libgit2 绑定(FFI 或 native module)需要每平台预编译产物或本地工具链,与 `typos/selene/stylua/llscheck` 的纯 Lua 工具链和"Neovim 0.10 即可"的承诺冲突;rspec/plenary CI 也需装库。
7. **行为差异面**:status 的 submodule/ignore 语义、`--no-optional-locks`/`core.preloadindex` 等性能旗标、`merge-base`/reflog/`describe` 边缘行为、GPG 签名/SSH agent 集成——libgit2 与 git CLI 存在已知差异,而 neogit 用户配置(如自定义 `git_executable` 包装脚本,README L137-138)天然假设走真实 git。
8. **并发/取消模型耦合**:refresh 取消依赖"kill 子进程"(`async.lua:19-21` cancel handle → `Process:stop`);libgit2 内存操作没有同构的取消原语,`Repo:refresh` 的 cancel 逻辑(L308–313)需要新的中断机制。

**结论**:最划算的切入顺序是——先收拢 popups 中的裸 `git.cli` 调用到 `lib/git/*` 模块;再以 `lib/git.lua` 元表 + `repository.lua` 的 `update_*` 协议为界做"读后端"替换(status/log/diff/refs);写命令次之;交互式流程(rebase/merge/编辑器/网络认证)永久保留 CLI 实现,作为混合后端的固定部分。
