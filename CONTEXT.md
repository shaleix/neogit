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

### Drop

Removing a commit from history by rewriting it: commits before the target
stay untouched, commits after it are replayed. Triggered on a Recent Commits
row by the Discard key (`x`); dropping a merge commit also removes the
commits it merged in. Distinct from Discard (working-tree changes) and from
revert (an inverse commit that leaves history alone).
_Avoid_: delete commit, remove commit

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

### File Tree

A status buffer section's items rendered as a nested directory tree:
foldable directory rows (single-child chains merged into one row) with
nested rows showing only the basename.
_Avoid_: file list, folder view

### Indent Guide

The File Tree's vertical markers linking a directory row to its nested
rows: one two-column block per tree level, the marker in the block's first
column — directly under the parent row's leading glyph — `│` while later
siblings follow, `└` on the last child's own row. The base column under a
section header never carries a marker.
_Avoid_: graph lines (that's Commit Graph), tree connectors

### Cold Open

The span between opening the status buffer and the completion of its first
refresh wave: the buffer paints the banner and a loading line, and the
Banner Transition (when enabled) plays. Ends the moment repository state
first becomes ready.
_Avoid_: first open (session-dependent), startup, splash screen

### Banner Transition

The Cold Open animation that pulses the banner between dimmed and full
gradient colors for as long as repository state is still loading, settling
on the final colors the moment state becomes ready. Never plays on later
opens, and never shows without the banner.
_Avoid_: loading banner (that's the in-buffer operation indicator), spinner
