# Seeing the real model from a client

Derby advertises **logical models** and nothing else. `GET /v1/models` returns `coding`,
`smart`, `local` — never `claude-sonnet-4-5-20250929`. That is deliberate: every request
goes through routing, failover and budgets, and a client that pins a provider model would
bypass all three.

The physical model is therefore something a client *reads*, not something it *picks*. This
page is the complete list of places it can read it, for whoever is writing the client.

## Per response — the authoritative answer

`model` on the response is already the physical model. Nothing Derby-specific is needed:

```python
r = client.chat.completions.create(model="coding", messages=[...])
r.model            # -> "claude-sonnet-4-5-20250929", not "coding"
```

Beside it, `x_derby.model` describes that model. With the OpenAI Python SDK the field
survives as an extra:

```python
derby = (r.model_extra or {}).get("x_derby", {})
derby["logical_model"]        # "coding"       — what was asked for
derby["physical_model"]       # "claude-sonnet-4-5-20250929"
derby["model"]["context_window"]     # 200000
derby["model"]["max_output_tokens"]  # 64000
derby["model"]["capabilities"]       # ["text", "vision", "tools", ...]
derby["model"]["provider"]           # "Claude subscription"  (the account)
derby["model"]["provider_kind"]      # "anthropic_subscription"
derby["model"]["metadata_source"]    # where the numbers came from — see below
derby["model"]["pricing"]            # {"flat_rate": true, ...}
derby["routing_reason"]              # why this target, in one sentence
derby["attempts"]                    # what was tried before it
```

After a failover, all of it describes the target that **actually answered**, not the one
that was ranked first.

### `x_derby.compaction` — the field to check before trusting an answer

Normally absent. It appears only when the conversation you sent was **too long for the model
that answered**, and the logical model was configured to shorten it rather than skip that
target. When present, the model did not see everything you sent:

```python
c = derby.get("compaction")
if c:
    c["strategy"]                  # "summarize" | "drop_oldest"
    c["dropped_messages"]          # 46
    c["kept_messages"]             # 7
    c["original_prompt_tokens"]    # 601234
    c["compacted_prompt_tokens"]   # 22187
    c["context_limit_tokens"]      # 32768
    c["target"]                    # "Ollama · qwen3-coder"
    c["summarized_by"]             # "Groq · llama-3.3-70b", absent if turns were dropped
    c["summary_failure"]           # why summarizing did not happen, when it did not
    c["reason"]                    # the whole thing as one readable sentence
```

If your client keeps its own conversation history, this is the signal that Derby's view of
it and yours have diverged. An agent that cares should either re-send a shortened
conversation itself or route that turn to a larger model. There is a header form too, for
clients that do not parse bodies:

```
x-derby-compacted   601234;22187;summarize
```

A request whose conversation does not fit **any** target fails with HTTP 400 and
`error.code == "context_overflow"` rather than being cut down. That is a different failure
from `capability_mismatch`: it means shorten the conversation or use a larger model, not
that the model cannot do what you asked.

### `x_derby.handoff` — what the answering model was and was not given

Also normally absent. It appears when the model that answered is not the one that wrote the
conversation's latest answer, or when Derby had to withhold or rewrite something so the
history could reach it intact:

```python
h = derby.get("handoff")
if h:
    h["previous_model"]            # "gpt-5.1" — who wrote the latest answer, when Derby knows
    h["model"]                     # "qwen3.6:27b" — who answered this time
    h["affinity"]                  # "identical" | "same_family" | "same_vendor" | "foreign" | "unknown"
    h["reasoning_carried"]         # earlier steps whose reasoning this model continued from
    h["reasoning_withheld"]        # earlier steps whose reasoning it was not given
    h["tool_call_ids_rewritten"]   # ids sent in the format this model's provider accepts
    h["unattributed_turns"]        # turns Derby could not trace to a model; absent when zero
    h["adjustments"]               # each structural repair, one sentence apiece
    h["summary"]                   # the whole thing as one readable sentence
```

`identical` means the same weights — another quantization, or another server — and reasoning
travels with the conversation. Reasoning from a different family is always withheld, by
design: a model that reads another family's reasoning as its own does worse than one that
reads none. The model still saw everything that was *said*; what it lacked was the earlier
model's reasoning, which is worth knowing when an agent changes course mid-task.

Rewritten tool call ids exist only in what Derby sends the provider — your copy of the
conversation keeps its own. On a stream, `handoff` arrives with the `x_derby` on the last
chunk (`response.completed` in the Responses dialect). Non-streaming responses carry a header
too:

```
x-derby-handoff   foreign;gpt-5.1;qwen3.6:27b;carried=0;withheld=2
```

## Streaming

The same object arrives on the **first** chunk, before any content, and again on the last:

```python
for chunk in client.chat.completions.create(model="coding", messages=[...], stream=True):
    chunk.model                                    # physical model, on every chunk
    derby = (chunk.model_extra or {}).get("x_derby")
    if derby:                                      # first chunk, and the tail
        current = derby["model"]["id"]
```

If Derby fails over *before* the first token — where failover is still transparent — it
re-sends `x_derby` on a chunk with empty `choices`, so a client that latched onto the first
announcement is corrected rather than left stale. Read the last `x_derby` you saw, not the
first, if you only keep one.

The Responses dialect carries it on `response.created` (and on `response.in_progress` if the
target changes), under `response.x_derby`.

## Headers

For clients that see headers but not bodies:

```
x-derby-request-id       req_01M1…
x-derby-logical-model    coding
x-derby-model            claude-sonnet-4-5-20250929
x-derby-provider         Claude subscription
x-derby-provider-kind    anthropic_subscription
x-derby-context-window   200000
x-derby-max-output-tokens 64000
x-derby-capabilities     text,vision,tools,parallel-tools,json-schema,reasoning,streaming
x-derby-compacted        601234;22187;summarize      (only when the conversation was shortened)
x-derby-handoff          foreign;gpt-5.1;qwen3.6:27b;carried=0;withheld=2   (only when the conversation changed hands or was adjusted)
```

A **streaming** response must send its headers before any target has run, so there they are
named `x-derby-planned-*` — Derby's intent, not a fact. The first chunk is the fact.

## Ahead of time — `GET /v1/models`

Each alias carries the runtime metadata of what it currently resolves to:

```jsonc
{
  "id": "coding",
  "object": "model",
  "owned_by": "derby",
  "context_window": 200000,        // the active target's
  "max_output_tokens": 64000,
  "derby": {
    "kind": "logical_model",
    "strategy": "priority",
    "target_count": 3,
    "min_context_window": 200000,  // the floor across every usable target
    "active_model": { "id": "claude-sonnet-4-5-20250929", "provider": "…", "…": "…" },
    "targets": [ /* every target: same metadata, plus rank, available, health, circuit */ ],
    "routing_reason": "Always try targets in the order you arranged them."
  }
}
```

`active_model` is computed by the same router the request path uses, so it agrees with the
next request — *for order-sensitive strategies*. Read on.

### If you cache one context length per model, cache `min_context_window`

`priority`, `failover_chain`, `local_first` and `cloud_first` resolve to the same target
every time while it stays healthy. `weighted_random` and `round_robin` deliberately do not:
consecutive requests to the same alias land on different physical models, with different
windows.

So `context_window` (the active target's) is the right thing to *display* and the wrong
thing to *cache*. `derby.min_context_window` is the smallest window across every usable
target — the number that is safe for every request to that alias. It is omitted entirely
when any target's window is unknown, because an unknown one could be smaller than all of
them; treat its absence as "ask per response".

### Trusting the numbers

`metadata_source` says where a target's capability flags came from:

| Value | Meaning |
| --- | --- |
| `discovered` | the provider's own model list said so |
| `user_override` | set by hand in Derby → Providers |
| `builtin` | Derby's bundled catalog, matched on the model name |
| `unknown` | nothing known; conservative defaults assumed |

Context window and max output are *completed* independently: whatever the provider stated is
kept, and only the gaps it left are filled from the bundled catalog. A provider that
publishes a window (the Codex CLI catalog does) always wins over Derby's guess.

## What Derby will not tell you

- **Which model answers next.** For spreading strategies that is decided per request. There
  is no endpoint that reserves a target.
- **A physical model id you can send as `model`.** Only logical model names route. Sending
  `claude-sonnet-4-5-20250929` returns 404 with the list of names that do work.
