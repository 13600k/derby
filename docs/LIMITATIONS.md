# Known limitations

Written plainly. Where something is unverified, it says so rather than implying otherwise.

## Unverified provider paths

| Path | State |
| --- | --- |
| Claude subscription | **Verified live** — real completion, and a real failover when the token later expired |
| Ollama (local) | **Verified live** — streaming and non-streaming, usage, TTFT |
| OpenAI-compatible generally | Verified against stubbed provider payloads in tests; the wire shaping is standard |
| ChatGPT subscription | Endpoint and headers confirmed by the backend's own `token_expired` response; **no successful completion observed** |
| Gemini subscription, Qwen subscription | Implemented from the CLI credential formats; **never exercised** — neither CLI was signed in |
| AWS Bedrock | SigV4 and event-stream decoding are unit-tested; **no live AWS account** was available |
| Azure OpenAI | URL/header/api-version shaping is unit-tested; **no live Azure resource** was available |

Everything unverified is structured so a failure surfaces as a normal Derby failure with an
actionable message, and the router simply moves on.

## The gateway runs inside the app

Quitting Derby stops the gateway. There is no background daemon, so requests fail while the
app is closed. "Keep the gateway running when the window is closed" (on by default) keeps it
alive in the menu bar, and "Launch Derby at login" makes that automatic — but the gateway's
lifetime is still the app's lifetime. This was a deliberate trade (see
[ARCHITECTURE.md](ARCHITECTURE.md)); a launch agent would remove it.

## Keychain prompts after a rebuild

Derby stores secrets in the Keychain, and macOS grants access per **code signature**. A
locally built, ad-hoc-signed app gets a new signature on every build, so macOS re-prompts
each time. Click *Always Allow*.

Derby is built to tolerate an unanswered prompt: the Keychain read happens on a background
thread under a 6-second deadline, so the window still appears and the gateway still starts.
If the key cannot be read, the gateway **fails closed** — it refuses requests with an
explanatory 401 rather than silently serving an unauthenticated endpoint. Signing with a
Developer ID identity (`DERBY_SIGN_IDENTITY=... ./Scripts/build_app.sh`) makes the prompt a
one-time event.

## Streaming

- **No mid-stream failover.** Once content has reached the client, Derby ends the stream with
  an error instead of switching providers. Splicing two models' output would be worse.
- **Hedging is pre-first-token only**, and applies to the non-streaming path. A streaming
  request fails over transparently before the first token but does not run two live streams
  in parallel.
- **Usage on streams** depends on the provider. Servers that never report it get an explicit
  estimate (characters ÷ 4), marked `≈` in the UI and flagged `isEstimated` in the record, so
  approximate numbers are never presented as measured.

## Cost accounting

Costs are **estimates** from bundled list prices, which drift and vary by tier, region and
contract. Per-model overrides are in the Providers screen. Local and subscription targets are
recorded as zero marginal cost, which is right for routing but means Derby is not a substitute
for your provider's billing page.

Daily and monthly budget caps are enforced per target from Derby's own counters, which reset
when Derby is not running.

## Not implemented

- **Audio and image *output*.** Audio input is modelled and passed through where a provider
  accepts it; generation modalities beyond text are not.
- **Legacy `/v1/completions`.** Returns a clear 400 pointing at `/v1/chat/completions`.
- **Pre-tokenized embedding input.** Strings only; integer-array input is rejected explicitly.
- **Chunked request bodies.** `Transfer-Encoding: chunked` on an inbound request returns 501.
  No OpenAI client sends one.
- **HTTP/2 and TLS on the gateway.** Plain HTTP/1.1 on loopback.
- **Active health probing.** The setting exists but health is currently learned passively from
  real traffic. Circuit half-open probes are real; scheduled background probes are not.
- **Multi-tenant / multi-user constraints.** Derby is a single-user local gateway.

## Operational notes

- **Ephemeral counters.** Rolling health statistics, circuit state and rate-limit windows live
  in memory and reset when Derby restarts. Request history and usage are persisted.
- **Round-robin is per logical model, in memory**, so rotation restarts with the app.
- **Config export excludes secrets** by design; after importing, re-enter each provider's
  credentials.
- **Firewall prompt.** macOS may ask whether Derby should accept incoming connections the
  first time it binds. Allowing it is not required for loopback use.
