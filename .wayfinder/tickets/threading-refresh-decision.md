---
title: 刷新与线程模型拍板
slug: threading-refresh-decision
labels: [wayfinder:grilling]
status: open
assignee:
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
