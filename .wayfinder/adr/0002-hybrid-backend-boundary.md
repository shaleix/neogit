---
status: accepted
date: 2026-09-20
---

# 混合后端边界:读路径 + index 写走 libgit2,交互式流程与其余写命令留 CLI

libgit2 没有交互式 rebase、SSH 凭据提示、hooks 编辑器等 porcelain 能力,而基线数据显示性能收益集中在读路径(refs 100×、log 7×)。我们决定:读路径(status/log/refs/rev_parse 等,经 `repository.lua` 的 `update_*` 协议)与 **index 写**(stage/unstage/hunk apply/`checkout -- file`——只写 index 与工作区、不动 HEAD、零 hook 语义)迁 libgit2;**切分支留 CLI**(post-checkout hook,libgit2 不跑)、commit 留 CLI(GPG 签名链路与 pre-commit hooks 语义)、stash/describe/reflog/submodule/diff/blame 留 CLI(无绑定或无收益;diff 组合路径 32ms 反而慢于 CLI 17ms)。由此 GPG 签名链与 hooks 触发语义两个候选议题不存在。

实现形态:**并行后端模块**——`lib/git/` 下同一 `update_*` 契约两套实现,`repository.lua` 按模块能力表选择;auto 降级 = 全表解析到 CLI 实现;逐模块灰度;不采用模块内 if 分支、不新立 service 层。

## Consequences

- 命令结果对象改用后端中立的 **GitResult** `{ok, code, message}`(libgit2 映射 GIT_ERROR;CLI 内部保留 ProcessResult 并包装)——不伪造 ProcessResult。
- 工作区 rename 采用**富模型**:NeogitRepoState 新增可选重命名字段,libgit2 填入(porcelain 检测不到)、CLI 留空显示 D+??;UI 仅在有信息时展示。
- 长期双代码路径是已接受成本;非目标清单(不迁范围)由 [migration-spec 第 2 章](../spec/migration-spec.md)钉死。
- 证据:[基线报告](../assets/baseline-report.md) §5.2、[neogit git 层调研](../assets/neogit-git-layer-survey.md) §五。
