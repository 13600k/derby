# Provider integration notes

What was investigated, what was verified live, and what remains uncertain.

## Adapter families

Five adapters cover everything:

| Family | Serves |
| --- | --- |
| `openai` | OpenAI, Azure, OpenRouter, Together, Fireworks, Groq, Mistral, DeepSeek, xAI, Qwen/DashScope, Ollama, LM Studio, llama.cpp, vLLM, SGLang, LocalAI, and any custom endpoint |
| `anthropic` | Anthropic Messages API with an API key |
| `anthropic_oauth` | The same API with a Claude subscription token |
| `google` | Gemini `generateContent` / `streamGenerateContent` |
| `chatgpt_codex` | ChatGPT subscription via the Codex backend's Responses API |
| `bedrock` | AWS Bedrock Converse + converse-stream, SigV4-signed |

Anything OpenAI-shaped is a **configuration** difference, not a new adapter.
`OpenAIQuirks.forKind` captures the deviations: auth header style, path style,
`max_completion_tokens` vs `max_tokens`, `stream_options` support, JSON-schema support,
parallel tool calls, and how minimal the payload must be for strict servers.

---

## Subscription-backed accounts

This was the part of the brief that needed real investigation rather than assumption. The
finding: **consumer AI subscriptions do not publish a general inference API**, but the
first-party CLIs that ship with them authenticate with OAuth and store a token locally.
Derby reuses that credential — the same way the CLI does, against the same endpoint.

### Claude subscription — verified working

- **Credential.** Claude Code stores its session in the **`Claude Code-credentials`
  Keychain item on macOS**, and often leaves a stale `~/.claude/.credentials.json`
  behind from an older install. Derby reads **both** and uses whichever expires latest.
  Reading the file first was a real bug: it produced a long-expired token, and managed
  refresh then failed with HTTP 400 because that refresh token had already been superseded.
- **Write-back targets the store the credential came from.** Refresh rotates the refresh
  token, so updating the stale copy while the live store kept the old one would have logged
  the user out of their own CLI — the exact outcome the read-only default exists to prevent.
- **Call.** `POST https://api.anthropic.com/v1/messages` with
  `authorization: Bearer <token>` and `anthropic-beta: oauth-2025-04-20`.
- **Requirement.** The **first system block must identify the caller as Claude Code**, or
  the token is rejected. `AnthropicAdapter` injects it in OAuth mode; a test asserts it is
  first and that the user's own system prompt follows it.
- **Verified live** during development: a real completion returned `200` with usage.
- Later in the same session the token expired, and Derby classified it as `AUTHENTICATION`
  in 1 ms and failed over to a local model — which is exactly the intended behaviour, and
  is the failover shown in the README.

### ChatGPT subscription — endpoint verified, end-to-end unverified

- **Credential.** `~/.codex/auth.json` → `tokens.access_token` and `tokens.account_id`.
  Expiry is read from the JWT's `exp` claim. An API-key-mode Codex install is detected and
  reported as such rather than being treated as a subscription.
- **Call.** `POST https://chatgpt.com/backend-api/codex/responses` with
  `authorization: Bearer <token>`, `chatgpt-account-id`, `OpenAI-Beta: responses=experimental`,
  `originator: codex_cli_rs` and a `session_id`. The endpoint is stream-only, so the
  non-streaming path consumes the stream and accumulates.
- **Models are discovered, not hardcoded.** The backend publishes no model-listing endpoint,
  but the Codex CLI caches the real catalog at `~/.codex/models_cache.json`. Derby reads that
  — slug, display name, ranking and supported reasoning levels — so the list stays current.
  A hardcoded list here was a real bug: it showed two long-superseded models and hid the
  current flagship. Models the catalog marks `visibility: hide` are not offered, and because
  a subscription catalog is authoritative, re-running discovery also removes models the
  account can no longer use.
- **Reasoning levels are clamped per model.** The catalog now lists `xhigh`, `max` and
  `ultra` alongside the classic four. Derby models the full scale and asks each model for the
  strongest level it actually supports; the OpenAI REST API, which only accepts four, gets
  the nearest level it understands rather than a value it would reject.
- **Verified:** the endpoint and header set are correct — the backend answered with a
  specific `token_expired` error rather than rejecting the shape.
- **Unverified:** a successful completion. The local token was already expired, and
  refreshing it would have rotated the user's `codex` credentials without their consent.

### Gemini and Qwen subscriptions — implemented, unverified

`~/.gemini/oauth_creds.json` and `~/.qwen/oauth_creds.json` are read the same way. Neither
CLI was signed in on the development machine, so neither path has been exercised. Qwen's
OAuth response carries a per-account `resource_url`, which the adapter honours as a base URL
override.

### Several accounts of the same service

Each of these CLIs keeps its state in a directory that can be relocated —
`CODEX_HOME` for Codex, `CLAUDE_CONFIG_DIR` for Claude Code — and each directory holds an
independent login. That is the mechanism behind running two ChatGPT (or two Claude)
subscriptions at once; verified directly: with `CODEX_HOME` pointed at a fresh directory,
`codex login status` reports *Not logged in* while the default home stays signed in.

A provider account therefore carries an optional **credential directory**. Point separate
Derby providers at separate directories and they behave as fully independent targets: their
own tokens, their own `chatgpt-account-id`, their own model catalog (`models_cache.json`
lives in the same directory), and their own health and rate-limit state — one account hitting
its usage limit cannot open the other's circuit.

```bash
mkdir -p ~/.codex-work
CODEX_HOME=~/.codex-work codex login     # sign the second account in
```

Derby then lists that directory in the account picker, labelled with the login's email and
plan, which it reads from the id token's profile claims. It warns when two providers point at
the same directory, since those would share one login rather than being independent.

Two details that would otherwise break this quietly:

- The credential cache is keyed on **(source, directory)**. Keying on the CLI alone would
  hand one account's token to the other.
- An isolated Claude directory never falls back to the shared `Claude Code-credentials`
  Keychain item, or two Claude accounts would collapse onto the same credential.

### Credential handling policy

Derby is **read-only by default**. It never writes to another tool's credential store unless
you opt in, because OAuth refresh *rotates* the refresh token and would otherwise silently
log you out of your own CLI.

| Mode | Behaviour |
| --- | --- |
| **Linked** (default) | Read the credential on each request (cached ~30s so a re-login is picked up quickly). If expired, surface `AUTHENTICATION` with the exact command to run. |
| **Managed** (opt-in per account) | Refresh the token through the CLI's own public OAuth client, then **write the rotated token back** so the CLI keeps working. |

`CredentialCache` serializes refreshes so concurrent requests cannot rotate a token twice.

---

## Metered APIs

### OpenAI
Standard. Reasoning-era models need `max_completion_tokens`; `reasoning_effort` is passed
through. `stream_options.include_usage` gives usage on the final chunk.

### Azure OpenAI
Different in three ways, all declarative: `api-key` header instead of a bearer token,
`/openai/deployments/{deployment}/chat/completions` path, and a required `api-version` query
parameter. The model id **is** the deployment name.

### Anthropic
`max_tokens` is mandatory — Derby supplies one from the model catalog when the client omits
it. System messages are hoisted out of the message list; tool results become `tool_result`
blocks inside a *user* turn. Extended thinking sets a `budget_tokens` strictly below
`max_tokens`, and drops `temperature`/`top_p`, which the API rejects while thinking is on.

### Google Gemini
Roles are `user`/`model`; system prompts go in `systemInstruction`. Gemini's schema dialect
rejects several ordinary JSON Schema keywords (`additionalProperties`, `$schema`, `allOf`,
`const`, …), so `sanitizeSchema` strips them rather than letting a routine OpenAI-style tool
definition fail. A prompt blocked by safety returns no candidates at all, which is mapped to
`CONTENT_POLICY`.

### AWS Bedrock
SigV4 signing implemented with CryptoKit; the unified **Converse** API avoids per-model body
shapes. Streaming uses Bedrock's binary `vnd.amazon.eventstream` framing, decoded by
`AWSEventStreamParser` (prelude, string headers, payload; CRCs are skipped). Model discovery
calls the `bedrock` control-plane host, which is a different service name from
`bedrock-runtime`. **Unverified** — no AWS account was available.

### OpenRouter, Together, Fireworks, Groq, Mistral, DeepSeek, xAI, Qwen
All OpenAI-compatible. OpenRouter additionally publishes `context_length`,
`architecture.input_modalities` and `supported_parameters` in `/models`, which discovery uses
to fill in capabilities.

---

## Local servers

| Server | Default probe | Notes |
| --- | --- | --- |
| Ollama | `127.0.0.1:11434/v1` | **Verified live.** Current builds honour `stream_options` and report usage on the final chunk; older ones ignore it, so Derby estimates instead. Reasoning models return `reasoning` alongside `content`. |
| LM Studio | `127.0.0.1:1234/v1` | |
| vLLM | `127.0.0.1:8000/v1` | Full `stream_options` support |
| SGLang | `127.0.0.1:30000/v1` | |
| llama.cpp | `127.0.0.1:8080/v1` | Minimal payload — strict about unknown fields |
| LocalAI | `127.0.0.1:8081/v1` | Minimal payload |

Derby probes these on launch and offers one-click import of whatever models are loaded.
Local targets are flat-rate (zero marginal cost), which is what makes `lowest_cost` and
`local_first` prefer them.

---

## Capability metadata

Three sources, in increasing precedence:

1. **Bundled catalog** — pattern-matched against the model id, carrying capabilities,
   context window, max output and list pricing for ~60 model families.
2. **Discovery** — whatever `/v1/models` (or Gemini's/Bedrock's equivalent) reports.
3. **User overrides** — per model, in the Providers screen.

An unknown model degrades to plain streaming chat with **no assumed tool support**. Claiming
a capability a model lacks causes hard failures; omitting one only costs a routing option the
user can re-enable with a single checkbox.

Pricing is a best-effort estimate and is user-overridable. Missing pricing never blocks
routing — cost simply stops contributing to the score.
