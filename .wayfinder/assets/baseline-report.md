# 性能基线剖析报告(baseline-profile)

> 由 research subagent 于 2026-09-20 产出。对象:本仓库 neogit(worktree `research/baseline-profile`,基线 commit `51c0fac0`)。
> 复现脚本与原始数据:`.wayfinder/assets/baseline-profile-data/`。
> 结论速览见文末"五、结论与架构建议输入"。

## 一、测量方法

### 1.1 环境

| 项 | 值 |
|---|---|
| CPU | Intel Xeon Platinum,2 核(nproc=2),3.5Gi 内存 |
| OS | Ubuntu 26.04.1 LTS |
| nvim | NVIM v0.12.5(Release),headless(`--clean --headless -u minimal.lua`) |
| git | 2.53.0(/usr/bin/git) |
| libgit2 | 1.9.1 rev0(apt `libgit2-1.9`,软链 `/usr/local/lib/libgit2.so`,fugit2 CI 同款做法) |
| fugit2 绑定层 | `~/workerspace/fugit2.nvim`(`fugit2.core.libgit2` + `fugit2.core.git2`) |

### 1.2 压力仓库(可复现:`baseline-profile-data/gen-stress-repo.sh`)

- 生成方式:awk 单进程生成 3000 个文本文件(100 目录 × 30 文件,每文件 40 行 × 12 字符随机小写,固定种子 20260920)→ 初始提交导入 → 199 个混合提交(每第 7 个提交改 300 个文件,其余改 3 个)→ `git gc` 打包 → 末尾人为留脏:50 个未暂存修改 + 20 个已暂存修改 + 10 个未跟踪。
- 规模数字:**200 commits、3000 tracked files、15627 packed objects、`.git` 3.6MiB、80 条脏条目**。
- 生成耗时约 39s。所有测量在 FS 缓存热(重复运行)状态下进行。

### 1.3 测量手段

| 测量 | 方法 | 重复次数 |
|---|---|---|
| neogit refresh 全链路 | headless nvim 驱动(`neogit-refresh.lua`):`neogit.open()` 后监听 `User NeogitStatusRefreshed` 计时;cold=首次打开、warm=对既有 status buffer 二次 `:refresh()`、lib-only=`git.repo:refresh{callback=...}`(无 UI redraw) | 5 个独立 nvim 进程 |
| spawn 计数与 argv | `git_executable = "/tmp/opencode/git-probe"`(C 编译的 execv 包装,`CLOCK_MONOTONIC` ns 时间戳 + tab 分隔 argv 落盘,内部 exec 真 git);进程墙钟时间取 `neogit.runner.history` 的 `ProcessResult.time`(ms,经实证) | 随上 |
| 每模块刷新耗时 | `NEOGIT_LOG_LEVEL=debug NEOGIT_LOG_FILE=1` 读 `[REPO]: Refreshed X in N ms` 日志 | 1 次(代表性) |
| 裸 CLI 基准 | bash 循环计时(`EPOCHREALTIME`,无额外 spawn;`cli-bench.sh`) | spawn 类 n=50,其余 n=10(预热 2 次后) |
| 解析微基准 | `parse-bench.lua`:捕获真实输出后 stub 掉 `cli.status`/直接调 `record.decode`,分离 spawn 与解析 | n=10 |
| libgit2 对照 | `libgit2-bench.lua` 经 fugit2 绑定层调 `Repository:status()/walker()/diff_*`,`vim.uv.hrtime` 打点 | n=10 |
| 单进程固定开销 | bash 循环(`/usr/bin/true`、`git --version`)+ 空闲 nvim 的 jobstart 往返(`spawn-bench.lua`) | n=50 / n=20 |

> 方法论说明:(1) probe 包装自身开销经实测约 **+1.7~2.5ms/次**(`git --version` 4.3ms vs probe 版 6.0ms,C 版包装仍含 fopen/execv),neogit 各表未扣除,量级已注明;(2) 本机 2 核,9 路并行 spawn 会互相争抢 CPU,单进程墙钟会显著膨胀(见 3.3),这是真实负载形态但需在归因时区分。

## 二、原始数据

### 2.1 neogit refresh 全链路(5 次独立 nvim 进程)

| 指标 | run1 | run2 | run3 | run4 | run5 | 中位数 |
|---|---|---|---|---|---|---|
| cold_full_ms(打开 status buffer 到 StatusRefreshed) | 458.8 | 608.4 | 518.1 | 507.2 | 515.6 | **~515** |
| cold 记录在案的 spawn 数(runner.history) | 20 | 20 | 20 | 20 | 20 | **20** |
| warm_full_ms(二次刷新,含 UI redraw) | 141.9 | 187.3 | 188.2 | 200.0 | 178.8 | **~187** |
| warm spawn 数 | 9 | 9 | 9 | 9 | 9 | **9** |
| lib_only_ms(纯 repo:refresh,无 redraw) | 107.5 | 140.4 | 129.6 | 132.1 | 143.0 | **~133** |
| lib spawn 数 | 9 | 9 | 9 | 9 | 9 | **9** |

- **UI redraw 成本 ≈ warm − lib ≈ 34~54ms**(约 27%)。
- cold 的 probe 日志额外记录到 8 次**被取消**的 spawn(首次 `Repo.instance()` 的 dispatch_refresh 被 status buffer 的 refresh 取消杀死,不进 history)与 6 次 `vim.system` 直连的 repo 探测(`git -C <dir> rev-parse --show-toplevel/--git-dir/--git-common-dir/--is-inside-work-tree`)。即冷启动实际 fork git 次数 ≈ 20 + 8 + 6 = **34**。
- 状态规模 sanity check:staged=20 / unstaged=50 / untracked=10 / recent=10,与仓库构造一致。

### 2.2 warm refresh 的 9 个子进程(argv 去重归类 + 单进程墙钟,取 run1)

| 命令(argv 除去固定前缀 `git --no-pager --literal-pathspecs --no-optional-locks -c core.preloadindex=true -c color.ui=always -c diff.noprefix=false`) | 次数 | 单次墙钟(争抢下) | 裸 CLI 基准(见 2.4) | 调用方 |
|---|---|---|---|---|
| `status --porcelain=2 -b` | **3** | 75–93ms | 21.2ms | pull.lua:14、push.lua:35、branch.lua:404(各自解析 `# branch.*` 头) |
| `status -z --porcelain=2` | 1 | 73ms | 24.1ms | status.lua:101 |
| `stash list` | 1 | 56ms | 5.8ms | stash.lua |
| `rev-parse HEAD` | 1 | 45ms | 3.1ms | tag/branch |
| `describe --long --tags HEAD` | 1 | 32ms | 3.9ms | tag.lua |
| `log --max-count=1 --format=%s <HEAD>` | **2** | 9–12ms | — | 重复的 HEAD 主题读取 |
| 合计 | **9** | Σ≈468ms(重叠并行) | | |

### 2.3 每模块刷新耗时(debug 日志,单次代表)

| update_* 模块 | 耗时 | | update_* 模块 | 耗时 |
|---|---|---|---|---|
| update_status | 86ms | | update_stashes | 52ms |
| update_unpulled | 81ms | | update_tags | 54ms |
| update_branch_information | 70ms | | update_recent / rebase / hooks / bisect | 0ms |
| update_unmerged | 64ms | | update_sequencer_status | 64ms |
| **Repo:refresh 总墙钟(12 模块并行)** | **107ms** | | | |

### 2.4 裸 CLI 基准(n=10~50,预热后;min/med/mean/max,ms)

| 命令 | min | med | mean | max |
|---|---|---|---|---|
| `/usr/bin/true`(spawn 固定开销) | 1.6 | **3.5** | 3.9 | 11.8 |
| `git --version`(git 启动开销) | 2.5 | **4.3** | 4.8 | 11.6 |
| `git-probe --version`(probe 自身偏置) | 3.3 | 6.0 | 6.6 | 16.2 |
| `git status --porcelain=2 -z`(裸) | 15.7 | **22.1** | 26.8 | 56.7 |
| 同上(neogit 完整 argv) | 17.9 | **24.1** | 26.8 | 50.6 |
| `git status --porcelain=2 -b`(neogit argv) | 15.2 | **21.2** | 22.0 | 32.3 |
| `git log --oneline -n 500`(实际 200) | 5.6 | **7.5** | 8.1 | 12.5 |
| `git log`(neogit 23 字段 record 格式)-500 | 7.3 | **9.4** | 9.9 | 14.5 |
| `git diff HEAD`(裸 / neogit argv) | 14.7/16.1 | **16.7 / 20.2** | 19.0/20.2 | 26.5/24.4 |
| `git diff --stat HEAD`(neogit argv) | 14.9 | 16.2 | 20.1 | 33.3 |
| `git rev-parse HEAD` | 2.7 | **3.1** | 3.7 | 6.6 |
| `git describe --long --tags HEAD` | 2.8 | 3.9 | 5.0 | 13.9 |
| `git stash list` | 3.5 | 5.8 | 5.6 | 7.2 |
| `git for-each-ref`(refs.lua 格式) | 3.7 | 5.1~9.1 | 6.5~9.8 | 16.9 |

### 2.5 空闲 nvim 单进程 jobstart 往返(无争抢;`spawn-bench.lua`)

| 命令 | med(n=20/10) |
|---|---|
| `/usr/bin/true` | **3.3ms** |
| `git rev-parse HEAD` | **3.8ms** |
| `git status -z`(neogit argv,含输出管道收集) | **33.2ms** |

→ jobstart 封装的 spawn+reap 固定开销 ≈ **3~4ms/进程**,与裸 fork+exec 相同;refresh 期间单进程墙钟膨胀到 45~111ms 的主因是 **9 路并行对 2 核的争抢**,不是 nvim 进程层慢。

### 2.6 解析微基准(n=10)

| 解析对象 | med | 说明 |
|---|---|---|
| `status.lua` update_status 全解析(80 项,含 item 构建/惰性 diff metatable) | **2.6ms**(首次冷 13.4ms) | stub 喂入捕获的真实 `-z` 输出 |
| `record.decode` 200 commits(23 字段) | **22.5ms** | log.list 的解析路径 |
| 附:捕获管道开销(io.popen 含 `tr`) | status 43.5ms / log 38.4ms | 含管道+冷启动,仅参考 |

> 实证补充:`status -z` 输出经 nvim 通道层 NUL→NL 转换后作为**单条字符串**落在 `result.stdout[1]`(`inspect-stdout.txt`:1 entry、9421 字节、无 NUL),`status.lua:102` 再 `vim.split` 拆记录。

### 2.7 libgit2 对照(经 fugit2 绑定层,同仓库,n=10)

| 操作 | med | min~max | 对照 CLI 路径 |
|---|---|---|---|
| 首次 open(含 dlopen + git_libgit2_init) | 55~70ms(一次性) | — | — |
| 重复 `git_repository_open_ext` | **0.19ms** | 0.11~4.7 | `rev-parse` 探测 3.1ms × 6 次 |
| `git_status_list_new` 全量(untracked+renames,转 Lua items,80 项) | **28.9ms** | 8.1~78.6 | CLI 24.1ms + 解析 2.6ms + 收集 ≈ 27~33ms |
| revwalk 全仓库 200 commits(topo + commit lookup) | **4.4ms** | 1.1~11.2 | `git log` 9.4ms + record.decode 22.5ms ≈ 32ms |
| `git_diff_tree_to_index`(head→index,20 deltas) | **3.1ms** | 1.8~5.3 | — |
| `git_diff_index_to_workdir`(index→workdir) | **29.2ms** | 8.8~70.0 | — |
| `git diff HEAD` 等价快路径(上两者相加) | **≈32ms** | — | CLI `git diff HEAD` 16.7~20.2ms(CLI 更快) |
| `diff_head_to_workdir`(fugit2 包装:untracked+find_similar) | **563.7ms** | 259~765 | ⚠️ 反模式,见 4.3 |
| 裸 C `git_diff_tree_to_workdir`(最小 flags) | **258.8ms** | 211~481 | ⚠️ 同上 |
| 分支列表 `git_branch_iterator` | **0.048ms** | 0.03~0.54 | `for-each-ref` 5.1~9.1ms |

## 三、归因分析

### 3.1 warm refresh 187ms 的去向(中位数口径)

| 成分 | 估算 | 占比 | 依据 |
|---|---|---|---|
| spawn 固定开销(9 × ~3.5ms) | ~32ms | **17%** | 2.5 true/rev-parse 往返 |
| git 自身 CPU 工作(含 3× 冗余 status) | ~60ms 墙钟 | **32%** | 2.4 裸 CLI 中位数;3 个 status 重复 + 9.4ms log 等,2 核并行折叠 |
| Lua 解析(status 2.6 + log 等) | ~5ms | **3%** | 2.6 |
| UI redraw(ui.Status 渲染) | ~50ms | **27%** | 2.1 warm − lib |
| 其余(异步编排、tmp_state 深拷贝、调度延迟、争抢尾部) | ~40ms | **21%** | 残差 |

**结论:瓶颈不是解析(<5%),也不纯粹是 spawn 固定开销(17%),而是"冗余调用 × git 实际工作 × 2 核争抢 + UI/编排开销"的组合。**

### 3.2 冗余调用(不换后端也能省的)

- `status --porcelain=2 -b` 每次刷新跑 **3 遍**(pull/push/branch 三模块各自要 branch 头信息);`status -z` 另跑 1 遍。同一份 status 数据被计算 4 次(其中 3 次内容完全相同)。
- `log --max-count=1 --format=%s <HEAD>` 跑 **2 遍**。
- 冷启动还有 6 次 `rev-parse` repo 探测(`vim.system` 直连,绕过 runner)与 8 个被取消的僵尸 spawn。

### 3.3 并行争抢效应

- 单进程 `status -z`:空闲 33.2ms → refresh 期间 73~105ms;`rev-parse HEAD`:3.8ms → 45ms。9 进程 / 2 核,单进程墙钟膨胀 **3~12×**,但 `run_all` 并行使总墙钟(133ms)远低于串行和(468ms),并行度收益约 3.5×。**在核多的机器上 spawn 固定开销占比会更接近 17% 的下限;在少核机器上争抢放大一切。**

### 3.4 libgit2 直连的收益边界

| 操作 | CLI 全路径 | libgit2 直连 | 倍数 |
|---|---|---|---|
| status(含解析/结构化) | 24.1+2.6 ≈ 27~33ms | 28.9ms | **≈1×(打平)** |
| log 200 commits(含解析) | 9.4+22.5 ≈ 32ms | 4.4ms | **~7×** |
| refs/branch 列表 | 5.1~9.1ms | 0.05ms | **~100×** |
| repo 句柄(摊销后) | 3.1ms×6(冷启动) | 0.19ms | ~16× |
| diff(单次调用) | 16.7~20.2ms | 快路径 32ms / 慢路径 259~564ms | **CLI 更快或打平** |

### 3.5 理论全 refresh 收益(替代估算)

warm lib-only 133ms 的 9 个 spawn 若换成 libgit2 内存对象:
`status`(28.9,吸收 3× `-b` 冗余)+ revwalk-10(~1ms)+ 分支/refs(0.05ms)+ describe/stash(无绑定,保留 2 个 CLI spawn ≈ 10ms)≈ **40ms,且 spawn 数 9 → 2**,对比 133ms ≈ **3.3×**;若加上 redraw(~50ms 不变),端到端 187ms → ~90ms ≈ **2×**。收益真实但不是数量级的,且 **status 单调用并不变快**——变快的是消除冗余、消除进程编排与把 log/refs 提速 7~100×。

## 四、风险与勘误(测量过程中的发现)

1. **libgit2 `tree_to_workdir` 是性能陷阱**:裸 C 调用(无 find_similar/untracked)也要 259ms,因为它绕过 index 直接对全工作区 stat+hash;git CLI 的 `diff HEAD` 走 tree→index(内存)+ index→workdir(stat 缓存)所以只要 17ms。**任何 libgit2 后端必须组合 `diff_tree_to_index` + `diff_index_to_workdir`,禁止直接 `tree_to_workdir`**(fugit2 的 `diff_head_to_workdir` 包装踩了这个坑还要叠 find_similar,563ms)。
2. **`Repository:status()` 的 flags 含 rename 检测**(RENAMES_HEAD_TO_INDEX/INDEX_TO_WORKDIR + RECURSE_UNTRACKED_DIRS),这解释了它 28.9ms 高于裸 `git status`(22ms)——语义对齐 neogit 需要 rename 信息,属公平对比,不是绑定层慢。
3. probe 包装引入约 +2ms/调用的偏置(2.4),neogit 各表的绝对值略偏高,不影响占比结论。
4. 本机 2 核是保守环境;多核机上"git 工作 + 争抢"份额会下降,spawn 固定开销与解析占比相对上升,libgit2 的"零 spawn"优势更聚焦在延迟下限而非吞吐。
5. `ProcessResult.time` 的类型注解写的是 seconds,实测为 **ms**(`process.lua:363`,`vim.uv.now()` 差值),本报告按 ms 采信。

## 五、结论与架构建议输入

### 5.1 对 ticket 问题的直接回答

- **耗时花在哪**:warm refresh(187ms)≈ 17% spawn 固定开销 + 32% git 实际工作(其中 1/3 是冗余调用)+ <5% 解析 + 27% UI redraw + 21% 编排/深拷贝/争抢尾部。**解析不是瓶颈;spawn 是显著但非主导成本;最大的单点是 3× 重复 status 与 UI redraw。**
- **libgit2 直连延迟差**:status 打平(~29ms vs ~27ms);log 7×;refs 100×;diff 需走 index 组合路径(32ms vs 17ms,略慢);整体理论 refresh 收益 ≈ 2~3.3×(spawn 9→2),不是数量级提升。

### 5.2 给"混合后端架构"的输入

1. **接缝选择**:`repository.lua` 的 `update_*` 协议作为读后端接缝**正确且够用**——12 个 update_* 已天然并行,换成 libgit2 只需各模块内部改数据来源;但注意 27% 的 redraw 成本和 ~21% 编排成本在换后端后仍在,若目标是端到端 2×,需同时考虑 redraw 优化(如增量渲染)。
2. **收益最大的模块排序**:refs/branch(100×,且消灭 6 次冷启动 rev-parse)→ log(7×,revwalk 免解析)→ repo 探测(重复 open 0.19ms)→ status(收益主要来自消灭 3× 冗余 `-b` 调用与进程编排,而非单调用速度)。**stash/describe 无 libgit2 绑定(fugit2 未声明),必须保留 CLI。**
3. **不换后端也该做的**(CLI 框架内即可兑现):把 `status --porcelain=2 -b` 的结果在三个模块间复用(一次调用,省 2 个 spawn ≈ 20~45ms);合并 2 次 `log -1 %s`;这些是低垂果实,应作为迁移前的基线优化。
4. **迁移验收基准**:用本报告方法与数据表作为对照——相同仓库规模下,refresh spawn 数 ≤ 2、warm 端到端 ≤ 90ms、log 视图打开(500 commits)≤ 15ms 是 libgit2 后端的合理验收线;若达不到,说明实现走了 `tree_to_workdir` 类反模式。
5. **分发与环境的现实约束**:libgit2 1.9.1 经 apt 安装 + 软链 `libgit2.so` 后 fugit2 绑定层在本机开箱可用(首次 dlopen+init 55~70ms 一次性);但仍需用户自备系统库(与 survey 的分发风险结论一致),这本身是架构决策要消化的成本,不是性能问题。

### 5.3 复现清单(`baseline-profile-data/`)

`gen-stress-repo.sh`(造库)→ `git-probe.c`(编译后作 git_executable)→ `neogit-refresh.lua` + `neogit-minimal.lua`(refresh 全链路,配 `NEOGIT_LOG_LEVEL=debug NEOGIT_LOG_FILE=1` 取每模块耗时)→ `cli-bench.sh`(裸 CLI)→ `parse-bench.lua`(解析分离)→ `libgit2-bench.lua`(fugit2 对照)→ `spawn-bench.lua`(单进程固定开销)。原始输出见同名 `.txt` / `rep-*.txt` / `probe-5.log`。

---

> **勘误(2026-09-20,main session 复核)**:§5.2.2 所称 "stash 无 libgit2 绑定(fugit2 未声明)" **有误**——fugit2 cdef 已声明 `git_stash_save/apply/pop/drop/foreach`(libgit2.lua:672–686,封装在 git2.lua:4152–4201),stash 读(list 经 `git_stash_foreach`)与写均可走 libgit2;**describe 确实无绑定**,保留 CLI 的结论不变。本条已由 `混合后端架构边界拍板` 票采信。

---

## 六、P0 后重测基线(2026-09-20,`libgit2-p0` 分支,spec §4 Phase 0 出口)

方法与 §一 完全一致(同压力仓库重新生成、同机、同 nvim/git/libgit2、neogit-refresh.lua 驱动,3 次独立 nvim 进程):

| 指标 | 基线(5 次中位) | P0 后(3 次) | 变化 |
|---|---|---|---|
| cold_full_ms | ~515 | 359.5 / 371.6 / 373.5 | ~**-28%** |
| cold spawn(runner 记录) | 20 | 16 | -4 |
| warm_full_ms | ~187 | 80.1 / 86.8 / 93.8 | ~**-53%** |
| warm spawn | 9 | **6** | **-3(9→6 精确达成)** |
| lib_only_ms | ~133 | 62.3 / 70.0 / 70.2 | ~**-47%** |

warm 6 spawn 构成:`status -b` ×1(原 ×3)、`status -z` ×1、`stash list`、`rev-parse HEAD`、`describe`、`log -1 --format=%s` ×1(原 ×2)。

注意事项:
- 去冗余之外,削减并行 spawn 也降低了 2 核争抢,故 wall-time 改善大于"3 × 3.5ms 固定开销"的朴素估计;两轮测量不同时段,wall-time 幅度供参考,**spawn 计数是硬指标**。
- warm ~87ms(中位)已提前触及 P3 的「warm ≤90ms」验收线——但该线的完整含义是"在 libgit2 后端下达成";P2/P3 的收益将体现在 spawn 6→2 与 log/refs 的延迟下限上。
- 小 fixture 交叉验证:master 10 spawn → P0 7(Δ-3 一致;多出的一条为该 fixture 特有的 `rev-parse --verify` 范围解析,两轮均有)。
- 测试:plenary 0 失败可归因于 P0(2 个 `git cli root detection` 失败为本机 mktemp 模板环境问题,master 同样失败;`lib.git.instance` 在 master 失败而 P0 通过);rspec 与 lint 工具本机缺失,留 CI 验证。
