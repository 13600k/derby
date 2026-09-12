# Derby

**A macOS AI model routing gateway.**

Derby exposes **one** OpenAI-compatible endpoint on your Mac and routes each request across
many providers — metered APIs, subscriptions you already pay for, local model servers, and
any custom OpenAI-compatible endpoint.

```text
http://127.0.0.1:8787/v1
```

The `model` field is not a provider model. It is a **logical model group** you define:

```text
coding
├── Claude subscription  ·  claude-sonnet-4-5
├── OpenAI API           ·  gpt-5.1
└── Ollama (local)       ·  qwen3.6:27b
```

Each logical model carries **its own routing policy**, its own retry and failover rules, its
own timeouts and its own budget. `smart` can chase quality while `cheap` chases price, and
neither knows about the other.

---

## Quick start

```bash
git clone <this repo> && cd derby
./Scripts/build_app.sh --run       # builds and launches build/Derby.app
```

On first launch Derby seeds five editable logical models (`smart`, `fast`, `cheap`,
`coding`, `local`), starts the gateway on `127.0.0.1:8787`, and offers to import any local
model servers and signed-in AI CLIs it finds. Clients need nothing but that port.

### Point a client at it

```text
Base URL:   http://127.0.0.1:8787/v1
API key:    none                    (send anything; clients that demand one are humoured)
Model:      coding                  (any logical model name)
```

```bash
curl http://127.0.0.1:8787/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "coding",
    "messages": [{"role": "user", "content": "Explain the CAP theorem."}]
  }'
```

Most tools work by changing two environment variables:

```bash
export OPENAI_BASE_URL="http://127.0.0.1:8787/v1"
export OPENAI_API_KEY="derby"     # ignored; set only because most SDKs refuse to start without it
```

You ask for an alias; you are told what actually ran. The `model` field of every response is
the physical model, and the `x_derby` object beside it says which provider answered, what
that model can do, what was tried before it, and why:

```json
"x_derby": {
  "logical_model": "coding",
  "provider": "Ollama (local)",
  "physical_model": "qwen3.6:27b",
  "model": {
    "id": "qwen3.6:27b",
    "provider": "Ollama (local)",
    "provider_kind": "ollama",
    "context_window": 262144,
    "max_output_tokens": 32768,
    "capabilities": ["text", "vision", "tools", "parallel-tools", "json-mode", "json-schema", "reasoning", "streaming"],
    "metadata_source": "builtin",
    "pricing": {"flat_rate": true, "input_per_mtok_usd": 0, "output_per_mtok_usd": 0},
    "local": true,
    "subscription": false
  },
  "routing_reason": "Failed over past Claude subscription (AUTHENTICATION); Ollama (local) handled the request.",
  "attempts": [
    {"attempt": "attempt_1", "provider": "Claude subscription", "status": "failed", "failure": "AUTHENTICATION", "duration_ms": 1},
    {"attempt": "attempt_2", "provider": "Ollama (local)", "status": "success", "http_status": 200, "duration_ms": 21105}
  ],
  "failovers": 1
}
```

The same metadata arrives three other ways, so a client never has to guess what it is talking
to:

- **Response headers** — `x-derby-model`, `x-derby-provider`, `x-derby-provider-kind`,
  `x-derby-context-window`, `x-derby-max-output-tokens`, `x-derby-capabilities`,
  `x-derby-logical-model`, `x-derby-request-id`. A streaming response has to send its
  headers before any target has run, so there they are named `x-derby-planned-*`: the
  target Derby intends to use, with the stream's first chunk carrying the real one.
- **Streaming** — the *first* chunk carries `x_derby` (the Responses dialect puts it on
  `response.created`), so a stream announces its model before the first token rather than
  after the last one. If Derby fails over before any content is sent, it re-announces.
- **`GET /v1/models`** — each alias reports `derby.active_model`: what it resolves to right
  now, decided by the same router the request path uses, plus `context_window` and
  `max_output_tokens` at the top level and every configured target under `derby.targets`
  with its own metadata, health and rank.

```json
{
  "id": "coding",
  "object": "model",
  "owned_by": "derby",
  "context_window": 200000,
  "max_output_tokens": 64000,
  "derby": {
    "kind": "logical_model",
    "strategy": "priority",
    "target_count": 3,
    "active_model": {"id": "claude-opus-4-5-20251101", "provider": "Claude subscription", "context_window": 200000, "…": "…"},
    "targets": [{"id": "claude-opus-4-5-20251101", "rank": 0, "active": true, "health": "HEALTHY", "…": "…"}],
    "routing_reason": "Always try targets in the order you arranged them."
  }
}
```

Strategies that spread traffic (weighted random, round robin) can resolve elsewhere on the
next request — `derby.targets` lists every possibility, `derby.min_context_window` is the
floor that is safe to cache for the alias, and `x_derby.model` on the response is always the
authoritative answer.

Physical model ids are **not** routable and are never advertised as models: every request
goes through routing, failover and budgets. If you are writing a client that needs to know
what it is talking to, [docs/CLIENTS.md](docs/CLIENTS.md) is the complete list of places to
read it from.

---

## The app

| Screen | What it is for |
| --- | --- |
| **Overview** | Gateway status, endpoint, key, today's traffic, provider health, one-click setup for anything Derby detected |
| **Logical Models** | The routing policy editor: the group's offered contract, strategy, drag-to-reorder targets, score weights, retries, failover, timeouts, hedging, budgets, request defaults |
| **Providers** | Accounts, credentials, discovered model facts (read-only), pricing and intelligence scores, connection tests |
| **Routing** | The simulator — describe a request, see the ranked candidates, the exclusions and the reasons, without sending anything |
| **Test Console** | Send a real prompt through the real pipeline and see the route it took |
| **Requests** | Every request, with its full attempt timeline and the scores behind the decision |
| **Usage** | Tokens and estimated cost by logical model, provider, physical model and client |
| **Logs** | Structured, credential-redacted diagnostics, with a one-click export |
| **Settings** | Port, bind address, optional API key, prompt logging, retention, config import/export |

Derby also lives in the menu bar: status, copy endpoint, restart, **pause routing**, quit.

---

## Endpoints

| Method | Path | Notes |
| --- | --- | --- |
| `GET` | `/v1/models` | Lists your logical models, `owned_by: derby`, each with the physical model it currently resolves to |
| `POST` | `/v1/chat/completions` | Streaming and non-streaming, tools, vision, JSON schema |
| `POST` | `/v1/responses` | The Responses dialect, answered in kind |
| `POST` | `/v1/embeddings` | Routed like everything else |
| `GET` | `/health` | Liveness and per-provider state (no key required) |
| `GET` | `/metrics` | Prometheus text format (no key required) |
| `GET` | `/v1/derby/status` | Per-target runtime metadata, health, circuit state and latency |

Paths work with or without the `/v1` prefix.

---

## Routing strategies

Every logical model picks one, independently:

| Strategy | Behaviour |
| --- | --- |
| **Priority** | Exactly the order you arranged |
| **Failover chain** | Strict sequence; never runs targets in parallel |
| **Weighted random** | Splits traffic by weight; the rest becomes the failover order |
| **Weighted score** | Ranks on quality, latency, cost, health, spare quota, priority, provider preference, locality, context headroom, spare capacity, whether the model is already loaded, and conversation continuity — with weights you set |
| **Lowest latency** | Rolling TTFT / p50 / p95 / total, your choice of metric |
| **Lowest cost** | Cheapest eligible target; free and local count as zero |
| **Round robin** | Even rotation across equivalent targets |
| **Local first** | Local models when healthy, cloud as fallback |
| **Cloud first** | Cloud models first, local as the emergency fallback |
| **Least loaded** | Most spare concurrency right now, counting requests already on their way; ties go to a model already in memory |

Between copies of the *same* model — the same weights on two servers, or two quantizations of
them — Derby tries the one already loaded first, so a request does not wait on a cold load
another copy could have skipped. It never swaps in a *different* model for being loaded: which
model answers stays the strategy's decision. On by default, except under Priority and Failover
chain, where your order is the instruction.

Policies are **data**, not code paths — they live in `config.json` and are edited in the UI.

---

## Providers

**Metered APIs.** OpenAI, Anthropic, Google Gemini, Azure OpenAI, AWS Bedrock (SigV4 +
Converse), OpenRouter, Together, Fireworks, Groq, Mistral, DeepSeek, xAI, Qwen/DashScope.

**Subscriptions you already pay for.** Derby reads the credential your CLI already stored:

| Provider | Source | Status |
| --- | --- | --- |
| Claude subscription | `claude` CLI (`~/.claude/.credentials.json` or Keychain) | **Verified working** |
| ChatGPT subscription | `codex` CLI (`~/.codex/auth.json`) | Endpoint and headers verified; end-to-end unverified (see limitations) |
| Gemini subscription | `gemini` CLI | Implemented, unverified |
| Qwen subscription | `qwen` CLI | Implemented, unverified |

**Several accounts of one service** run side by side: each CLI keeps its login in a directory
you can relocate (`CODEX_HOME`, `CLAUDE_CONFIG_DIR`), so pointing two Derby providers at two
directories gives you two independent accounts — separate tokens, separate model catalogs,
separate health and rate-limit state. Derby labels each with its email and plan so you can
tell them apart.

Derby is a **read-only** consumer of those credentials by default, so it can never log you
out of your own CLI. Token refresh rotates the refresh token, so it is opt-in per account —
and when enabled, Derby writes the rotated token back so the CLI keeps working.

**Local servers.** Ollama, LM Studio, llama.cpp, vLLM, SGLang, LocalAI — auto-detected on
their usual ports, with one-click import of the models they have loaded.

**Anything else.** Add a custom OpenAI-compatible endpoint with a base URL, optional key,
custom headers, timeouts, capability overrides, pricing overrides and a TLS option for
private servers.

---

## Reliability

- **Failure taxonomy.** Every provider error becomes one of thirteen `FailureKind` values.
- **Configurable dispositions.** Each kind maps to an action (retry, fail over, fail over to
  a larger context, return to client, abort) — editable per logical model.
- **Retry ≠ failover.** Retry re-tries the same target; failover advances to the next. They
  have separate budgets.
- **Circuit breakers.** Closed → open → half-open → closed, with probe limits, visible and
  resettable in the UI.
- **Deadlines.** Every request has an overall budget; per-attempt and first-token timeouts
  are capped by whatever remains.
- **Hedging.** Optional, off by default: start a second target if the first is quiet, first
  answer wins, loser recorded as `hedge_lost`.
- **Streaming semantics.** Failover is transparent *only* before the first content token
  reaches the client. After that Derby ends the stream with an error rather than splicing
  two models' output together.
- **Context compaction.** Off by default: a target whose window cannot hold the conversation
  is skipped, and a request that fits nowhere fails with `context_overflow` instead of being
  quietly cut down. Turn it on per logical model and an oversized conversation is shortened
  to fit the smaller target instead — dropping the oldest turns, or replacing them with a
  summary written by a model you nominate. Never silently: the response carries
  `x_derby.compaction` and an `x-derby-compacted` header.
- **Bursts spread.** Requests that arrive together would all read the same idle counts and
  pile onto one target. A load-aware ranking claims its target as it picks it, and a claim
  made on counts that have since moved is refused and routed again.
- **Abandoned requests stop.** When a client disconnects, Derby cancels the provider request
  instead of letting a model keep generating for nobody.
- **Servers that report their own load are believed.** vLLM, SGLang and llama.cpp publish how
  many requests they are running, how many are queued and how full the KV cache is — including
  work Derby never sent. Derby ranks on it, and passes over a server with no free slot while
  another target can answer.

---

## Moving a conversation between models

Consecutive turns, or a failover, can hand a conversation to a different model from the one
that wrote it. Derby makes sure the answer differs because the model does, not because
something was lost on the way:

- **Reasoning stays within a model family.** Qwen at FP8 on vLLM and Qwen at Q4_K_M on
  Ollama are the same weights, so the second picks up the first one's reasoning in the middle
  of a tool loop. GPT's reasoning is never handed to Qwen: a model reading another family's
  thinking as its own does worse than one reading none.
- **Signed reasoning goes back only where it can be verified** — Claude's thinking to Claude,
  ChatGPT's encrypted reasoning to the account that issued it, Gemini's thought signatures to
  Gemini.
- **Structure follows the receiving model.** Tool call ids in a format it accepts, every call
  paired with its result, system prompts where its template reads them, a tool's images in a
  message it can see.
- **What a client drops, Derby restores.** Chat Completions clients discard reasoning and
  never say which model wrote a turn; Derby remembers its own recent answers and puts both
  back.

Whenever the model changed, or anything was withheld or rewritten, the response says so in
`x_derby.handoff`. The details are in
[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md#handing-a-conversation-between-models).

---

## Documentation

- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — layers, data flow, and the rules that keep them apart
- [`docs/DEVELOPMENT.md`](docs/DEVELOPMENT.md) — building, testing, adding providers and strategies
- [`docs/PROVIDERS.md`](docs/PROVIDERS.md) — provider-by-provider integration notes
- [`docs/CLIENTS.md`](docs/CLIENTS.md) — what a client can read about the model that answered, and what it did not see
- [`docs/LIMITATIONS.md`](docs/LIMITATIONS.md) — what is not done, and what is unverified
- [`CLAUDE.md`](CLAUDE.md) — orientation for AI coding agents working in this repo

---

## Building

```bash
swift build                    # library + app
swift run DerbyTests           # 453 tests, no network required
./Scripts/build_app.sh         # → build/Derby.app
./Scripts/build_app.sh --install   # also copy to /Applications
```

Requirements: macOS 14+, Swift 6 toolchain (Command Line Tools are enough — Xcode is not
required). **No third-party dependencies.**

---

## Security

- Provider credentials live in the **macOS Keychain**; `config.json` stores only references.
- The gateway binds to **127.0.0.1 only** by default, and is verified to refuse LAN traffic.
  That bind — not a key — is what keeps Derby off the network, so clients need no API key.
- A local API key is available for anyone who binds beyond loopback (Settings → Access).
  Once required, it is enforced on every route but `/health` and `/metrics`, and if the key
  cannot be read from the Keychain, Derby **fails closed** rather than serving open.
- Authorization headers, API keys and JWTs are redacted from logs, errors and diagnostics.
- Prompt bodies are **not** stored by default — metadata only.
