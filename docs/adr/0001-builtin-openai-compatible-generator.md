# 1. Built-in OpenAI-compatible generator for AI Commit

Date: 2026-09-22
Status: Accepted

## Context

AI Commit initially shipped as a pure seam: a user-configured `generator`
callback producing the commit message, with neogit deliberately embedding no
LLM client (recorded in CONTEXT.md at the time). After real use, the seam
proved too heavy in practice — a working generator meant ~40 lines of curl,
JSON, and error handling pasted into the user's config, repeated per user.

Meanwhile every serious backend the target users reach for (DeepSeek, Ollama,
LM Studio, vLLM, OpenRouter, Groq) speaks the same protocol:
`POST {base}/chat/completions` with bearer-token auth and a
`choices[0].message.content` response. One client covers them all.

## Decision

Ship a built-in generator speaking the OpenAI-compatible protocol only,
configured declaratively (`backend`/`url`/`model`/`api_token_env`/`prompt`).
The `generator` callback tier remains and takes precedence.

Notably **not** decided: per-vendor presets (HF Inference API, TGI, Gemini,
Anthropic) — they would multiply maintenance surface for one protocol each;
users needing them can write a generator callback.

## Consequences

- Typical config shrinks from ~40 lines to `model = "deepseek-flash"` (plus
  url/token env for non-default backends).
- neogit now owns a network client: curl one-shot POST, no streaming, no
  retries — bounded surface. Failures resolve as empty messages so the
  editor fallback path stays the universal safety net.
- The plugin still depends on no LLM plugin ecosystem (llm.nvim and friends
  remain unusable for this: they expose no prompt→text API).
