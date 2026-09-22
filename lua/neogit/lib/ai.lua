-- Built-in AI Commit generator: an OpenAI-compatible chat/completions client.
-- Covers DeepSeek, Ollama (/v1), LM Studio, vLLM, OpenRouter, Groq, etc. -
-- anything speaking the { url }/chat/completions protocol.
--
-- Deliberately thin: one POST via curl, no streaming, no retries. The
-- user-configurable `generator` callback remains the full-control escape
-- hatch for anything this does not cover.
local M = {}

local function default_prompt()
  return [[You are a commit message generator. Given a list of staged file names and their unified diff, write ONE commit message:
- conventional-commit style: "type: lowercase imperative subject" (e.g. "feat: add b")
- subject line only, no body, no quotes, no trailing punctuation
- keep it under 72 characters
- respond with the message and nothing else]]
end

---Assemble the system+user prompt pair from the staged context.
---@param ctx { files: string[], diff: string }
---@param prompt_config string|fun(ctx): string|nil user override (string or ctx-aware function)
---@return string system_prompt, string user_prompt
function M.build_prompts(ctx, prompt_config)
  local system_prompt = default_prompt()
  if type(prompt_config) == "function" then
    system_prompt = prompt_config(ctx) or system_prompt
  elseif type(prompt_config) == "string" and prompt_config ~= "" then
    system_prompt = prompt_config
  end

  local user_prompt
  if #ctx.files > 0 then
    user_prompt = "Staged files:\n" .. table.concat(ctx.files, "\n") .. "\n\nDiff:\n" .. ctx.diff
  else
    user_prompt = "Empty commit (no staged changes).\n\nDiff:\n" .. ctx.diff
  end

  return system_prompt, user_prompt
end

---Assemble the chat/completions request body.
---@param model string
---@param system_prompt string
---@param user_prompt string
---@return string json encoded body
function M.build_request_body(model, system_prompt, user_prompt)
  return vim.json.encode({
    model = model,
    messages = {
      { role = "system", content = system_prompt },
      { role = "user", content = user_prompt },
    },
    stream = false,
  })
end

---Extract the assistant message from a chat/completions response; empty
---string on any structural mismatch.
---@param raw string response body
---@return string message
function M.parse_response(raw)
  local ok, body = pcall(vim.json.decode, raw)
  if not ok or type(body) ~= "table" then
    return ""
  end

  local choice = body.choices and body.choices[1]
  local content = choice and choice.message and choice.message.content
  if type(content) ~= "string" then
    return ""
  end

  return vim.trim(content)
end

---Resolve the endpoint URL and bearer token for the configured backend.
---@param settings table ai_commit config
---@return string url, string|nil token
function M.resolve_endpoint(settings)
  local url
  if settings.url and settings.url ~= "" then
    url = settings.url
  elseif settings.backend == "ollama" then
    url = "http://localhost:11434/v1"
  else
    url = "https://api.openai.com/v1"
  end
  url = url:gsub("/+$", "")

  local token
  local env = settings.api_token_env
  if env and env ~= "" then
    token = os.getenv(env)
  end

  return url, token
end

---Run the built-in generator: POST the staged context to the configured
---OpenAI-compatible backend and pass the message to `done`. Any failure
---(missing model/token, curl error, bad response) resolves with "" so the
---caller's fallback path (editor) takes over.
---@param ctx { files: string[], diff: string }
---@param settings table ai_commit config
---@param done fun(message: string)
function M.generate(ctx, settings, done)
  if not settings.model or settings.model == "" then
    done("")
    return
  end

  local url, token = M.resolve_endpoint(settings)
  if settings.backend ~= "ollama" and not token then
    done("")
    return
  end

  local system_prompt, user_prompt = M.build_prompts(ctx, settings.prompt)

  local args = {
    "--silent",
    "--show-error",
    "--max-time",
    tostring(math.max((settings.timeout or 30) - 5, 1)),
    "-X",
    "POST",
    "-H",
    "Content-Type: application/json",
    "-H",
    "Accept: application/json",
    "-d",
    M.build_request_body(settings.model, system_prompt, user_prompt),
  }

  if token then
    table.insert(args, "-H")
    table.insert(args, "Authorization: Bearer " .. token)
  end
  table.insert(args, url .. "/chat/completions")

  M.internal.spawn(args, function(result)
    if result.code ~= 0 then
      done("")
      return
    end
    done(M.parse_response(result.stdout or ""))
  end)
end

-- Test seam: process execution; not public API.
M.internal = {
  spawn = function(args, cb)
    vim.system({ "curl", unpack(args) }, { text = true }, cb)
  end,
}

return M
