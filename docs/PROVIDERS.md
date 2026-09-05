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

### Claude subscription — two paths, and they bill differently

Anthropic distinguishes first-party clients from third-party ones, which is what produces:

> Third-party apps now draw from your extra usage, not your plan limits.

Running the `claude` CLI is unambiguously a first-party client, so the request draws on the plan
you already pay for. The CLI reports `"provider": "firstParty"` for these calls, which is how
that is confirmed rather than assumed.

The direct API path is the uncertain one. **The classification is not made on the token** — it
is made on the identity the request presents, and the token is only part of that. Derby sends
the whole set the CLI does (see `ClaudeCodeIdentity`): the `oauth-2025-04-20` and
`claude-code-20250219` betas, a `user-agent` naming the installed CLI version, `x-app: cli`, and
the Claude Code system block. Which lane that lands in has been reported both ways and appears
to depend on the account, so Derby does not claim an answer for yours — **read the response
headers and find out**:

| Response headers | Lane |
| --- | --- |
| `anthropic-ratelimit-unified-*` (5h / 7d windows) | Plan limits |
| `anthropic-ratelimit-requests-*`, `...-input-tokens-*` | Metered — API billing or extra usage |

Derby offers both transports:

| Provider kind | Transport | Billing |
| --- | --- | --- |
| **Claude Code (plan limits)** | Spawns the `claude` CLI | Your subscription's plan limits |
| **Claude subscription (direct API)** | `POST /v1/messages` with the OAuth token | Account-dependent — verify with the headers above |

The CLI path is what discovery now offers. Its cost:

- **No tool calling and no images.** The CLI runs its own agent loop and accepts no
  caller-supplied tool schemas, so this provider does not advertise those capabilities and
  such requests route to another target.
- **No sampling parameters.** `temperature` and friends are not exposed by the CLI.
- **Process overhead.** Claude Code's own system prompt, tool schemas and project context cost
  about 27k tokens per call; `--tools "" --setting-sources "" --strict-mcp-config` with an
  explicit `--system-prompt` brings that down to roughly 300.
- **One turn per call.** The CLI answers every input message in sequence, so a conversation is
  rendered into a single prompt rather than replayed as separate messages.

In exchange it reports **live plan utilization** — the rolling five-hour and seven-day windows —
which Derby converts into quota pressure, so routing moves away from a nearly-exhausted plan on
its own.

**One-time macOS prompt.** The first time Derby launches the CLI, macOS raises a Keychain
authorization dialog for it, and the process waits silently until it is answered. Derby gives
up after 20 seconds and says exactly that rather than hanging for the request deadline. Choose
**Always Allow**, or run `claude` once in Terminal.

### Claude subscription (direct API) — verified working

- **Credential.** Claude Code stores its session in the **`Claude Code-credentials`
  Keychain item on macOS**, and often leaves a stale `~/.claude/.credentials.json`
  behind from an older install. Derby reads **both** and uses whichever expires latest.
  Reading the file first was a real bug: it produced a long-expired token, and managed
  refresh then failed with HTTP 400 because that refresh token had already been superseded.
- **Write-back targets the store the credential came from.** Refresh rotates the refresh
  token, so updating the stale copy while the live store kept the old one would have logged
  the user out of their own CLI — the exact outcome the read-only default exists to prevent.
- **Call.** `POST https://api.anthropic.com/v1/messages` with `authorization: Bearer <token>`
  plus the rest of the CLI's identity, which is one unit and lives in `ClaudeCodeIdentity`:
  `anthropic-beta: interleaved-thinking-2025-05-14,fine-grained-tool-streaming-2025-05-14,claude-code-20250219,oauth-2025-04-20`,
  `user-agent: claude-code/<version> (external, cli)`, and `x-app: cli`.
- **Requirement.** The **first system block must identify the caller as Claude Code**, or
  the token is rejected. `AnthropicAdapter` injects it in OAuth mode; a test asserts it is
  first and that the user's own system prompt follows it.
- **Version.** The user-agent must name a version close to the current release, so it is read
  from the installed CLI (`claude --version`, probed once per process behind a 5s deadline) and
  only falls back to a constant when there is no CLI to ask.
- **Withheld deliberately.** `context-1m-2025-08-07`. An account without the long-context beta
  answers HTTP 400 to *every* request carrying it, so claiming it would break short calls to
  buy a window most subscriptions cannot use.
- **Not done:** rewriting the caller's own system prompt. Other gateways substitute their
  product name out of it to avoid being fingerprinted; that silently alters what the client
  sent, which Derby does not do to a conversation anywhere else.
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
- **Verified end to end.** Completions now succeed through this backend, on two separate
  accounts simultaneously. Getting there required dropping `max_output_tokens`, which this
  endpoint rejects as an unsupported parameter, and surfacing the backend's `{"detail": …}`
  body — it answers with a bare status otherwise, and "HTTP 400" alone is not actionable.

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
| Ollama | `127.0.0.1:11434/v1` | **Verified live.** Discovery uses the native `/api/tags`, not the OpenAI shim: the shim returns only an id, while the native endpoint reports real context length, the model's own capability list (vision/tools/thinking/embedding), parameter size, quantization and family — in one request. Current builds honour `stream_options` and report usage on the final chunk; older ones ignore it, so Derby estimates instead. Reasoning models return `reasoning` alongside `content`. |
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

Derby collects the attributes it can **obtain** and **act on** — the ones that change a
routing decision or that a client needs in order to use a model:

| Attribute | Used for |
| --- | --- |
| Context window, max input, max output | Filtering targets a conversation fits, context-headroom scoring |
| Input modalities (text, image, audio) | Capability filtering — a vision request only reaches vision models |
| Output modalities (text, image, audio, embedding) | Group compatibility — a model that emits no text cannot serve chat |
| Tools, parallel tools | Capability filtering for tool-calling requests |
| JSON mode, JSON schema | Structured-output requests |
| Reasoning support and effort levels | Reasoning requests, per-model effort clamping |
| Embedding dimensions | Embedding routing |
| Price per input/output/cached token | Cost-aware routing and spend reporting |
| Parameter size, quantization, family | Displayed so a person can judge a local model |
| Latency, TTFT, success rate, rate-limit headroom | Measured by Derby itself, not declared |

Benchmark scores, training compute, safety certifications and hardware requirements are not
collected: no provider API reports them, and Derby has no routing decision that would consume
them. The one subjective dimension is a per-model **quality score**, which the user sets and
weighted-score routing reads.

### Parameters, as distinct from capabilities

What a model *can do* and what it will *accept being sent* are different things. Reasoning-era
models are highly capable yet reject `temperature` outright — the request fails with a
deprecation error rather than the parameter being ignored. In the current index, **1357 of
7526 models** declare `temperature: false`, including every `gpt-5.x` and most of the Claude 5
family.

Derby therefore records `unsupportedParameters` per model and omits them when building a
request. It is a **deny-list**: a model nothing is known about still receives every parameter,
so this can only ever remove one a provider would have rejected. Sources are the live index's
`temperature` flag and reasoning levels, and OpenRouter's `supported_parameters` array, which
enumerates exactly what it accepts and is therefore treated as authoritative.

Reasoning effort is clamped the same way — a request for `ultra` becomes the strongest level
the model actually publishes, and OpenAI's vocabulary spelling of the weakest level (`none`)
is mapped rather than sent as `minimal`.

Endpoint quirks are separate from model quirks and stay in the adapter. The Codex backend, for
instance, rejects `max_output_tokens` even though the public Responses API accepts it.

### Where the numbers come from

Provider `/models` endpoints almost never report a context window — OpenAI and Anthropic
return little more than an id. A hand-written table cannot cover that gap for long: a model
released after the table was written falls through to "unknown" and loses not just its
window but its tool and vision support.

So Derby's bundled table is the **offline fallback**, and the source of truth is
[models.dev](https://models.dev), a community-maintained index carrying context and output
limits, modalities, tool/reasoning/structured-output support and list pricing. It is fetched
on launch, cached to `model-catalog.json`, and re-read from disk thereafter, so Derby works
offline and never blocks on the network. Settings → *Model metadata* shows how many models are
known and when it last updated, with a manual refresh.

Model metadata is **re-resolved on every snapshot**, not frozen when a model was added, so an
improved catalog corrects a stored guess without the user re-running discovery. What the
provider itself reported is never overwritten, and a user override still beats everything.

Three sources, in increasing precedence:

1. **Bundled catalog** — pattern-matched against the model id; the offline fallback.
2. **Live catalog** (models.dev) — keyed by vendor and model id, with dated snapshots,
   aggregator namespaces and Ollama tags all resolved to the same entry.
3. **Discovery** — whatever the provider itself reports; always wins where it says anything.
4. **User overrides** — only for facts nothing else could supply.

An unknown model degrades to plain streaming chat with **no assumed tool support**. Claiming
a capability a model lacks causes hard failures; omitting one only costs a routing option the
user can re-enable with a single checkbox.

Pricing is a best-effort estimate and is user-overridable. Missing pricing never blocks
routing — cost simply stops contributing to the score.
