# libgit2 直连 PoC(PROTOTYPE — THROWAWAY)

回答 wayfinder ticket `binding-poc` 的三件事。fugit2 绑定层 vendor 自
`~/workerspace/fugit2.nvim @ 7783d33`(MIT),**零改动**拷入 `vendor/fugit2/{core,util}/`,
靠 `package.path` 前缀解析。

## 运行

```bash
bash make-fixture.sh                      # 构造富状态 fixture(可重复执行)
nvim --headless -l runner.lua             # 默认 /tmp/opencode/poc-fixtures/rich
nvim --headless -l runner.lua <repo路径>  # 或指向任意仓库
```

## 2026-09-20 结果(本机 libgit2 1.9.1 / nvim 0.12.5 / git 2.53)

### [A] 能加载 ✅
- 3 个文件(libgit2.lua 1307 行 + git2.lua 4475 行 + stat.lua 55 行)零改动即可在
  Neovim LuaJIT 中 `ffi.load` 系统 libgit2,惰性加载 + `git_libgit2_init` 一次性行为正常。
- `table.new` 在 nvim 内建可用;唯一小缺口:`git_libgit2_version` 未被 cdef(PoC 里自行补了,
  vendor 进 neogit 时需补此声明,用于运行时版本探测)。

### [B] 能对齐:语义等价,附两个真实差异
| 维度 | 结果 |
|---|---|
| staged(A/M/D/R) | ✅ 4/4 全等,**含歧义 rename 配对**(file6+file7 同内容时,libgit2 与 git CLI 做出完全相同的 file6→renamed-staged R100 配对) |
| unstaged(M/D) | ✅ 等价,**除 rename 见下** |
| untracked | ✅ 等价(需 `-uall` 对齐展开) |
| branch / ahead / behind | ✅ `status_head_upstream()` 等价 `# branch.*` 行 |

- **差异 1(信息更丰富)**:工作区 rename——porcelain 报 `D filemv.txt` + `?? filemv-moved.txt`
  (git CLI 在 status 里不做 worktree rename 检测),libgit2(`RENAMES_INDEX_TO_WORKDIR` flag)
  报单条 `WT_RENAMED filemv.txt → filemv-moved.txt`。libgit2 后端可以显示更准确的状态,
  但与 CLI 后端行为不同——迁移时须择一:对齐 CLI(丢弃 rename 信息)或采用富模型(两后端行为分叉)。
- **差异 2(fugit2 封装的坑)**:untracked 条目的 `index_status` 也被置为 UNTRACKED,
  消费侧须过滤,否则 untracked 会混进 staged 列表。
- 顺带发现:`vim.fn.system` 会破坏输出中的 NUL 字节(porcelain `-z` 分隔符),
  必须用 `vim.system`/jobstart 读原始字节——neogit 现有 process 层已是 jobstart,无此问题,
  但任何新代码不许用 `vim.fn.system` 读 `-z` 输出。

### [C] 有收益(指示性,小 fixture;权威数字见 baseline-profile)
| 操作 | CLI(spawn) | FFI 直连 | 倍数 |
|---|---|---|---|
| status 全量读(porcelain -z -b -uall vs status()+head_upstream) | ~10.5–12 ms | ~2.8–5.6 ms | **2–4x** |
| log 前 200 条(git log vs revwalk push_head+iter) | ~12.4 ms | ~0.09 ms | **~139x** |

即便在极小仓库上,FFI 也全面占优;log/revwalk 量级差两个数量级,呼应"读路径优先"的迁移方向。

## 结论

绑定与分发决策 ticket 的三个先决证据齐了:能加载(零改动 vendor)、能对齐(等价 + 2 个已知差异)、
有收益(指示性倍数成立)。剩余拍板项(最低版本、探测时机、vendor 边界)转入
`binding-distribution-decision`。
