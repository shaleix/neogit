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
