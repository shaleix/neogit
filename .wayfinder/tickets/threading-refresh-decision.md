---
title: 刷新与线程模型拍板
slug: threading-refresh-decision
labels: [wayfinder:grilling]
status: closed
assignee: main-session/ses_f41e510deffeMfC1qkcd4Q5YVY
blocked-by: [backend-architecture-decision]
created: 2026-09-20
---

## Question

**libgit2 后端下,状态刷新链路与线程/取消模型怎么设计?** 需要拍板:

1. **对象缓存与失效**:libgit2 后端持有长生命周期 `git_repository*` 与内存态;现有 watcher 靠 `.git` 目录 fs-event 触发刷新。CLI 写操作走 git 进程会改文件(能触发事件),但 libgit2 后端自身的写入(如果写路径也迁)与内存缓存的一致性策略是什么?(每个 update_* 重新 open?还是缓存 + 按 fs-event 失效?)
2. **线程模型**:重计算(status 大仓库、revwalk 全量 log)用 fugit2 的 `uv.new_work` 范式(指针转整数跨线程、线程内重新 `ffi.load`、主线程回调 free)移出主线程?还是先同步 FFI + `vim.schedule`(fugit2 的默认做法)看基线数据再说?
3. **取消语义**:`Repo:refresh` 现在靠 kill 子进程取消进行中的 refresh;libgit2 内存操作没有同构原语,等价的中断机制是什么(分段检查取消标志?不让取消、靠 debounce 吸收?)
4. **与 200ms debounce/throttle 的配合**:fs-event 风暴下 libgit2 后端的刷新成本模型与 CLI 后端不同,节流参数是否需要分后端配置。

输入:`混合后端架构边界拍板` 的接缝与写路径结论 + `.wayfinder/assets/fugit2-libgit2-survey.md` 的异步章节。

## Resolution

**四项决策全部拍板(2026-09-20,grilling):**

1. **Repository 句柄 = 每 refresh 周期重开**:周期开始 `git_repository_open_ext`(0.19ms,基线实测),周期内各 `update_*` 任务共享,周期结束释放。彻底消除缓存失效问题(外部 CLI 写、自家 index 写、mtime 变化都由新句柄看到),worktree 切换自然处理;watcher 触发机制不变。不采用长寿命缓存 + 显式失效(0.19ms 的成本使后者只剩风险没有收益)。进程级只保留 `git_libgit2_init` 一次。
2. **线程模型 = 同步先行 + 执行器接缝**:首期全部 libgit2 调用走同步 FFI(目标规模单任务 ≤30ms,lib-only ≈40ms,满足 warm ≤90ms 验收线);但所有调用必须经一个**可替换的执行器抽象**,`update_*` 任务边界即未来搬入 `uv.new_work` 的天然接缝(fugit2 的 intptr 传递范式已验证可行)。「worker 线程升级」列为 spec 后续阶段项,触发条件 = 大仓库(几十万文件)实测 UI 卡顿。
3. **取消语义 = 任务边界检查点**:单个 `update_*` 任务为原子单位(同步 FFI 跑完 ≤几十 ms,不可中断);取消检查点在任务边界,进行中任务跑完、结果丢弃;刷新风暴由现有 200ms debounce/throttle 吸收。spec 明记此限制(雾区「取消语义」随之解决)。
4. **节流参数 = 统一、后测后调**:两后端共用现有 200ms debounce/throttle;libgit2 刷新成本已降一个量级,频繁触发不再昂贵;「分后端调优」仅作为实测后的可选项记入 spec,不新增配置面。

**给后续 ticket 的输入**:阶段划分票可直接排布「worker 线程升级」为可选后续阶段;spec 风险章节记录「超大仓库同步 FFI 阻塞 UI」为已知限制与升级路径。
