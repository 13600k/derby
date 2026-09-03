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
`coding`, `local`), starts the gateway on `127.0.0.1:8787`, generates a local API key, and
offers to import any local model servers and signed-in AI CLIs it finds.

### Point a client at it

```text
Base URL:   http://127.0.0.1:8787/v1
API key:    <Derby local key>       (Derby → Settings → Access, or the Overview screen)
Model:      coding                  (any logical model name)
```

```bash
curl http://127.0.0.1:8787/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $DERBY_KEY" \
  -d '{
    "model": "coding",
    "messages": [{"role": "user", "content": "Explain the CAP theorem."}]
  }'
```

Most tools work by changing two environment variables:

```bash
export OPENAI_BASE_URL="http://127.0.0.1:8787/v1"
export OPENAI_API_KEY="<Derby local key>"
```

Every response carries an `x_derby` object saying which provider answered, what was tried
before it, and why:

```json
"x_derby": {
  "logical_model": "coding",
  "provider": "Ollama (local)",
  "physical_model": "qwen3.6:27b",
  "routing_reason": "Failed over past Claude subscription (AUTHENTICATION); Ollama (local) handled the request.",
  "attempts": [
    {"attempt": "attempt_1", "provider": "Claude subscription", "status": "failed", "failure": "AUTHENTICATION", "duration_ms": 1},
    {"attempt": "attempt_2", "provider": "Ollama (local)", "status": "success", "http_status": 200, "duration_ms": 21105}
  ],
  "failovers": 1
}
```

---

## The app

| Screen | What it is for |
| --- | --- |
| **Overview** | Gateway status, endpoint, key, today's traffic, provider health, one-click setup for anything Derby detected |
| **Logical Models** | The routing policy editor: strategy, drag-to-reorder targets, score weights, retries, failover, timeouts, hedging, budgets, request defaults |
| **Providers** | Accounts, credentials, model lists, capability and pricing overrides, connection tests |
| **Routing** | The simulator — describe a request, see the ranked candidates, the exclusions and the reasons, without sending anything |
| **Test Console** | Send a real prompt through the real pipeline and see the route it took |
| **Requests** | Every request, with its full attempt timeline and the scores behind the decision |
| **Usage** | Tokens and estimated cost by logical model, provider, physical model and client |
| **Logs** | Structured, credential-redacted diagnostics, with a one-click export |
| **Settings** | Port, bind address, API key, prompt logging, retention, config import/export |

Derby also lives in the menu bar: status, copy endpoint, restart, **pause routing**, quit.

---

## Endpoints

| Method | Path | Notes |
| --- | --- | --- |
| `GET` | `/v1/models` | Lists your logical models, `owned_by: derby` |
| `POST` | `/v1/chat/completions` | Streaming and non-streaming, tools, vision, JSON schema |
| `POST` | `/v1/responses` | The Responses dialect, answered in kind |
| `POST` | `/v1/embeddings` | Routed like everything else |
| `GET` | `/health` | Liveness and per-provider state (no key required) |
| `GET` | `/metrics` | Prometheus text format (no key required) |
| `GET` | `/v1/derby/status` | Per-target health, circuit state and latency |

Paths work with or without the `/v1` prefix.

---

## Routing strategies

Every logical model picks one, independently:

| Strategy | Behaviour |
| --- | --- |
| **Priority** | Exactly the order you arranged |
| **Failover chain** | Strict sequence; never runs targets in parallel |
| **Weighted random** | Splits traffic by weight; the rest becomes the failover order |
| **Weighted score** | Ranks on quality, latency, cost, health, spare quota, priority, provider preference, locality and context headroom — with weights you set |
| **Lowest latency** | Rolling TTFT / p50 / p95 / total, your choice of metric |
| **Lowest cost** | Cheapest eligible target; free and local count as zero |
| **Round robin** | Even rotation across equivalent targets |
| **Local first** | Local models when healthy, cloud as fallback |
| **Cloud first** | Cloud models first, local as the emergency fallback |

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

---

## Documentation

- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — layers, data flow, and the rules that keep them apart
- [`docs/DEVELOPMENT.md`](docs/DEVELOPMENT.md) — building, testing, adding providers and strategies
- [`docs/PROVIDERS.md`](docs/PROVIDERS.md) — provider-by-provider integration notes
- [`docs/LIMITATIONS.md`](docs/LIMITATIONS.md) — what is not done, and what is unverified
- [`CLAUDE.md`](CLAUDE.md) — orientation for AI coding agents working in this repo

---

## Building

```bash
swift build                    # library + app
swift run DerbyTests           # 195 tests, no network required
./Scripts/build_app.sh         # → build/Derby.app
./Scripts/build_app.sh --install   # also copy to /Applications
```

Requirements: macOS 14+, Swift 6 toolchain (Command Line Tools are enough — Xcode is not
required). **No third-party dependencies.**

---

## Security

- Provider credentials live in the **macOS Keychain**; `config.json` stores only references.
- The gateway binds to **127.0.0.1 only** by default, and is verified to refuse LAN traffic.
- A local API key is required by default. If the key cannot be read, Derby **fails closed**.
- Authorization headers, API keys and JWTs are redacted from logs, errors and diagnostics.
- Prompt bodies are **not** stored by default — metadata only.
