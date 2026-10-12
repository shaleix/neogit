# Context: neogit

## Terms

### AI Commit

A commit created without opening the commit editor: a **Generator** produces
the message, and the commit is made directly with it. Offered as `m` in the
Commit popup, next to `Commit` (`c`). Belongs to the same family as
**Instant Fixup / Instant Squash** — "instant" actions skip the editor and
execute immediately — but unlike those (whose message is derived mechanically
from an existing commit), AI Commit delegates message creation to a message
source.

Failure semantics: if the message source is unset, errors, returns an empty
message, or exceeds the timeout, the action falls back to the regular
editor-based commit.

### Generator

The message source for AI Commit, in two tiers:

- **Built-in client** (declarative config: `backend`/`url`/`model`/`prompt`):
  an OpenAI-compatible chat/completions caller covering DeepSeek, Ollama,
  LM Studio, vLLM, OpenRouter, and anything else speaking that protocol.
- **Custom generator** (`ai_commit.generator`): user callback receiving
  `done(message)` and the staged context (`files`, truncated `diff`); takes
  precedence over the built-in client and imposes no opinion on how the
  message is produced.

See `docs/adr/0001-builtin-openai-compatible-generator.md` for why the
built-in client exists alongside the callback tier.

### Commit Graph

The lane-based picture of commit ancestry: a column of connected glyphs
(continuing lines, forks, merges) rendered beside commit rows, with
per-lane colors. One Commit Graph spans many rows and is styled by the
same setting everywhere it appears.
_Avoid_: graph lines, decoration, fake graph

### Connector Row

A graph-only row between commit rows carrying the Commit Graph's
continuation and turn glyphs. It holds no commit: it is never selectable,
never previewed, and navigation skips it.
_Avoid_: padding row, empty row

### Recent Commits

The status buffer section listing the most recent commits on HEAD, capped
by `status.recent_commit_count`. Its rows render the same Commit Graph
styling as the Log view.
_Avoid_: log section, history section

### Head Line

The status buffer's single header row for the checked-out worktree: sync
status (divergence counters or the in-sync ✓), repository name, and branch
name — nothing else. `<cr>` on it opens the Repository Details.
_Avoid_: head block, HEAD section

### Repository Details

The right-side split opened by `<cr>` on the Head Line: a snapshot of the
repository's reference positions (Head, Merge, Push, Tag, divergence) with
the ahead/behind range diffs rendered inline, commit-view style.
_Avoid_: head popup, status details
