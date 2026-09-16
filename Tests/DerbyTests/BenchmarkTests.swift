import Foundation
@testable import DerbyCore

func registerBenchmarkTests() {

    /// An Artificial Analysis v2 shaped fixture: nested `evaluations`,
    /// `pricing` and `model_creator`, which is how the live endpoint answers.
    /// The ids are deliberately spelled the way the index spells them, not the
    /// way the providers Derby talks to do — that mismatch is the whole problem
    /// this feature has to solve.
    /// An Artificial Analysis v2 shaped fixture: nested `evaluations`,
    /// `pricing` and `model_creator`, which is how the live endpoint answers.
    ///
    /// The rows are spelled exactly the way the live index spells them, which
    /// is the opposite of the obvious guess: the *bare* slug is usually the
    /// reasoning row and the suffixed one is not, the level is stated in the
    /// name rather than the slug, and a slug token can belong to the model's
    /// own name (`mistral-medium-3-1`).
    let sample = """
    {"status":200,"intelligence_index_version":4.3,
     "data":[
      {"id":"1","name":"Claude 4.5 Sonnet","slug":"claude-4-5-sonnet",
       "release_date":"2025-09-29",
       "model_creator":{"id":"a","name":"Anthropic","slug":"anthropic"},
       "evaluations":{"artificial_analysis_intelligence_index":63.2,
                      "artificial_analysis_coding_index":57.1,
                      "artificial_analysis_agentic_index":49.8},
       "pricing":{"price_1m_input_tokens":3,"price_1m_output_tokens":15,
                  "price_1m_cache_hit_tokens":0.3},
       "median_output_tokens_per_second":61.4,
       "median_time_to_first_token_seconds":1.82,
       "context_window_tokens":200000},
      {"id":"2","name":"Claude 4.5 Sonnet (Thinking)","slug":"claude-4-5-sonnet-thinking",
       "model_creator":{"id":"a","name":"Anthropic","slug":"anthropic"},
       "evaluations":{"artificial_analysis_intelligence_index":70.0},
       "pricing":{"price_1m_input_tokens":3,"price_1m_output_tokens":15}},
      {"id":"3","name":"GPT-5.1","slug":"gpt-5-1",
       "model_creator":{"id":"o","name":"OpenAI","slug":"openai"},
       "evaluations":{"artificial_analysis_intelligence_index":71.5},
       "pricing":{"price_1m_input_tokens":1.25,"price_1m_output_tokens":10},
       "median_output_tokens_per_second":120.0},
      {"id":"4","name":"Qwen3.5 32B","slug":"qwen3-5-32b",
       "model_creator":{"id":"q","name":"Alibaba","slug":"alibaba"},
       "evaluations":{"artificial_analysis_intelligence_index":44.0},
       "pricing":{"price_1m_input_tokens":0.2,"price_1m_output_tokens":0.6}},
      {"id":"5","name":"Qwen3.8 27B (Reasoning)","slug":"qwen3-8-27b",
       "model_creator":{"id":"q","name":"Alibaba","slug":"alibaba"},
       "evaluations":{"artificial_analysis_intelligence_index":58.0}},
      {"id":"6","name":"Qwen3.8 27B (Non-reasoning)","slug":"qwen3-8-27b-non-reasoning",
       "model_creator":{"id":"q","name":"Alibaba","slug":"alibaba"},
       "evaluations":{"artificial_analysis_intelligence_index":22.4}},
      {"id":"7","name":"Qwen3.5 122B A10B (Reasoning)","slug":"qwen3-5-122b-a10b",
       "model_creator":{"id":"q","name":"Alibaba","slug":"alibaba"},
       "evaluations":{"artificial_analysis_intelligence_index":16.2}},
      {"id":"8","name":"Qwen3.5 122B A10B (Non-reasoning)","slug":"qwen3-5-122b-a10b-non-reasoning",
       "model_creator":{"id":"q","name":"Alibaba","slug":"alibaba"},
       "evaluations":{"artificial_analysis_intelligence_index":17.7}},
      {"id":"9","name":"Gemini 3.5 Flash (high)","slug":"gemini-3-5-flash",
       "model_creator":{"id":"g","name":"Google","slug":"google"},
       "evaluations":{"artificial_analysis_intelligence_index":33.0}},
      {"id":"10","name":"Gemini 3.5 Flash (minimal)","slug":"gemini-3-5-flash-minimal",
       "model_creator":{"id":"g","name":"Google","slug":"google"},
       "evaluations":{"artificial_analysis_intelligence_index":20.0}},
      {"id":"11","name":"GPT-5.2 Codex (xhigh)","slug":"gpt-5-2-codex",
       "model_creator":{"id":"o","name":"OpenAI","slug":"openai"},
       "evaluations":{"artificial_analysis_intelligence_index":28.5}},
      {"id":"12","name":"Mistral Medium 3.1","slug":"mistral-medium-3-1",
       "model_creator":{"id":"m","name":"Mistral","slug":"mistral"},
       "evaluations":{"artificial_analysis_intelligence_index":9.9}},
      {"id":"13","name":"Grok 4","slug":"grok-4",
       "model_creator":{"id":"x","name":"xAI","slug":"xai"},
       "evaluations":{"artificial_analysis_intelligence_index":55.0}},
      {"id":"14","name":"Grok 4 Max","slug":"grok-4-max",
       "model_creator":{"id":"x","name":"xAI","slug":"xai"},
       "evaluations":{"artificial_analysis_intelligence_index":68.0}}
     ]}
    """

    func withCatalog(_ body: () throws -> Void) rethrows {
        _ = BenchmarkCatalog.shared.loadForTesting(Data(sample.utf8))
        defer { BenchmarkCatalog.shared.clearForTesting() }
        try body()
    }

    /// Asserts a lookup landed on the Sonnet 4.5 weights, whichever reasoning
    /// row of them it picked — which level is chosen is covered on its own.
    func expectSonnet45(_ entry: BenchmarkCatalog.Entry) throws {
        try expect(entry.slug.hasPrefix("claude-4-5-sonnet"),
                   "matched \(entry.slug), which is not Sonnet 4.5")
    }

    // MARK: - Parsing

    suite("Benchmarks / parsing") {
        test("nested evaluations, pricing and creator are all read") {
            try withCatalog {
                let entry = try expectNotNil(
                    BenchmarkCatalog.shared.entries.first { $0.slug == "claude-4-5-sonnet" })
                try expectClose(entry.intelligenceIndex ?? 0, 63.2)
                try expectClose(entry.codingIndex ?? 0, 57.1)
                try expectClose(entry.agenticIndex ?? 0, 49.8)
                try expectClose(entry.inputPricePerMTok ?? 0, 3)
                try expectClose(entry.outputPricePerMTok ?? 0, 15)
                try expectClose(entry.cachedInputPricePerMTok ?? 0, 0.3)
                try expectClose(entry.outputTokensPerSecond ?? 0, 61.4)
                try expectClose(entry.timeToFirstTokenSeconds ?? 0, 1.82)
                try expectEqual(entry.contextWindow, 200_000)
                try expectEqual(entry.creator, "Anthropic")
            }
        }

        test("the index methodology version is kept, since scores mean nothing without it") {
            try withCatalog {
                // A decimal version must survive as written: 4.3 is not 4.
                try expectEqual(BenchmarkCatalog.shared.indexVersion, "4.3")
            }
        }

        test("the same fields published flat on the row are read too") {
            // The endpoint has documented both shapes. Reading only the nested
            // one would import every model with no score at all.
            let flat = """
            {"data":[{"slug":"gpt-9","name":"GPT-9",
              "artificial_analysis_intelligence_index":80.5,
              "price_1m_input_tokens":2,"price_1m_output_tokens":8}]}
            """
            _ = BenchmarkCatalog.shared.loadForTesting(Data(flat.utf8))
            defer { BenchmarkCatalog.shared.clearForTesting() }
            let entry = try expectNotNil(BenchmarkCatalog.shared.lookup("gpt-9"))
            try expectClose(entry.intelligenceIndex ?? 0, 80.5)
            try expectClose(entry.inputPricePerMTok ?? 0, 2)
        }

        test("a body that is not the expected shape leaves the cache alone") {
            try expect(BenchmarkCatalog.shared.loadForTesting(Data("{\"data\":[]}".utf8)) == false)
            try expect(BenchmarkCatalog.shared.loadForTesting(Data("not json".utf8)) == false)
        }
    }

    // MARK: - Matching

    suite("Benchmarks / matching") {
        test("a provider's id finds the index's differently-ordered spelling") {
            // Anthropic ships claude-sonnet-4-5; the index lists
            // claude-4-5-sonnet. Same weights, and a string compare misses it.
            try withCatalog {
                let entry = try expectNotNil(BenchmarkCatalog.shared.lookup("claude-sonnet-4-5"))
                try expectSonnet45(entry)
            }
        }

        test("a dated snapshot matches the undated entry") {
            try withCatalog {
                let entry = try expectNotNil(
                    BenchmarkCatalog.shared.lookup("claude-sonnet-4-5-20250929"))
                try expectSonnet45(entry)
            }
        }

        test("an aggregator's namespaced id matches") {
            try withCatalog {
                let entry = try expectNotNil(
                    BenchmarkCatalog.shared.lookup("anthropic/claude-sonnet-4-5"))
                try expectSonnet45(entry)
            }
        }

        test("a Bedrock id matches through its vendor prefix and version suffix") {
            try withCatalog {
                let entry = try expectNotNil(
                    BenchmarkCatalog.shared.lookup("us.anthropic.claude-sonnet-4-5-20250929-v1:0"))
                try expectSonnet45(entry)
            }
        }

        test("dots and underscores in an id are the index's dashes") {
            try withCatalog {
                try expectEqual(BenchmarkCatalog.shared.lookup("gpt-5.1")?.slug, "gpt-5-1")
                try expectEqual(BenchmarkCatalog.shared.lookup("GPT_5_1")?.slug, "gpt-5-1")
            }
        }

        test("an Ollama tag matches, and its quantization is not part of identity") {
            try withCatalog {
                try expectEqual(BenchmarkCatalog.shared.lookup("qwen3.5:32b")?.slug, "qwen3-5-32b")
            }
        }

        test("an id that names no reasoning level is scored at the highest one") {
            // The case the user cannot spell: a custom endpoint serving
            // qwen3.8-27b will run it at any effort a request asks for, so its
            // ceiling is the reasoning row (58.0), not the no-reasoning one
            // (22.4) that happens to be the row whose slug says a level.
            try withCatalog {
                let entry = try expectNotNil(BenchmarkCatalog.shared.lookup("qwen3.8-27b"))
                try expectEqual(entry.slug, "qwen3-8-27b")
                try expectClose(entry.intelligenceIndex ?? 0, 58.0)
            }
        }

        test("the level is read from the name, because the slug often omits it") {
            // gemini-3-5-flash carries no level in its slug at all; only its
            // name says "(high)". Reading slugs alone scored it as a baseline.
            try withCatalog {
                let entry = try expectNotNil(BenchmarkCatalog.shared.lookup("gemini-3.5-flash"))
                try expectEqual(entry.slug, "gemini-3-5-flash")
                try expectClose(entry.intelligenceIndex ?? 0, 33.0)
                try expectEqual(BenchmarkCatalog.shared.lookup("gemini-3.5-flash-minimal")?.slug,
                                "gemini-3-5-flash-minimal")
            }
        }

        test("the strongest level wins even when a weaker one scores higher") {
            // Qwen3.5 122B scores 17.7 without reasoning and 16.2 with it.
            // Ordering by score would take the non-reasoning row and undo the
            // whole rule; ordering by level takes 16.2.
            try withCatalog {
                let entry = try expectNotNil(BenchmarkCatalog.shared.lookup("qwen3.5-122b-a10b"))
                try expectEqual(entry.slug, "qwen3-5-122b-a10b")
                try expectClose(entry.intelligenceIndex ?? 0, 16.2)
            }
        }

        test("an id that does name a level gets exactly that level") {
            // The ceiling rule must not override what the id actually says, or
            // a deployment pinned to non-reasoning would be ranked as if it
            // were not.
            try withCatalog {
                try expectEqual(BenchmarkCatalog.shared.lookup("qwen3.8-27b-non-reasoning")?.slug,
                                "qwen3-8-27b-non-reasoning")
                try expectEqual(BenchmarkCatalog.shared.lookup("claude-sonnet-4-5-thinking")?.slug,
                                "claude-4-5-sonnet-thinking")
            }
        }

        test("a level the index does not publish falls to the strongest below it") {
            try withCatalog {
                // Nothing between minimal and high, so medium takes minimal.
                try expectEqual(BenchmarkCatalog.shared.lookup("gemini-3.5-flash-medium")?.slug,
                                "gemini-3-5-flash-minimal")
            }
        }

        test("a word in the model's own name is not read as an effort level") {
            // Mistral Medium 3.1 states no level, so "medium" is part of what
            // it is called. Reading it as an effort would group it with a
            // "Mistral 3.1" and score one model with another's number.
            try withCatalog {
                let entry = try expectNotNil(BenchmarkCatalog.shared.lookup("mistral-medium-3.1"))
                try expectEqual(entry.slug, "mistral-medium-3-1")
                try expectClose(entry.intelligenceIndex ?? 0, 9.9)
            }
        }

        test("a model merely named -max is not folded into the family it resembles") {
            // Grok 4 Max is different weights, not Grok 4 run harder.
            try withCatalog {
                try expectEqual(BenchmarkCatalog.shared.lookup("grok-4")?.slug, "grok-4")
                try expectEqual(BenchmarkCatalog.shared.lookup("grok-4-max")?.slug, "grok-4-max")
            }
        }

        test("grouping never widens to a single token") {
            try withCatalog {
                try expectEqual(BenchmarkCatalog.shared.lookup("qwen3.5:32b")?.slug, "qwen3-5-32b")
            }
        }

        test("a model the index has never heard of matches nothing at all") {
            // Precision over coverage: a near-miss would write another model's
            // score and prices into a target the router then ranks by.
            try withCatalog {
                try expectNil(BenchmarkCatalog.shared.lookup("honcho-internal-7b"))
                try expectNil(BenchmarkCatalog.shared.lookup("claude-sonnet-3-5"))
                try expectNil(BenchmarkCatalog.shared.lookup(""))
            }
        }
    }

    // MARK: - Applying

    let anthropicEntry = BenchmarkCatalog.Entry(
        slug: "claude-4-5-sonnet", name: "Claude 4.5 Sonnet", creator: "Anthropic",
        releaseDate: "2025-09-29", intelligenceIndex: 63.2, codingIndex: 57.1,
        agenticIndex: 49.8, outputTokensPerSecond: 61.4, timeToFirstTokenSeconds: 1.82,
        inputPricePerMTok: 3, outputPricePerMTok: 15, cachedInputPricePerMTok: 0.3,
        contextWindow: 200_000)

    suite("Benchmarks / applying") {
        test("the intelligence index becomes the score weighted routing reads") {
            var model = PhysicalModel(modelID: "claude-sonnet-4-5", qualityScore: 60)
            let changes = BenchmarkApplication.apply(anthropicEntry, to: &model, kind: .anthropic,
                                                     settings: .default, knownContextWindow: 200_000,
                                                     indexVersion: "3")
            try expectClose(model.qualityScore, 63.2)
            try expect(changes.contains { $0.field == "intelligence score" })
        }

        test("prices are written where the user has none") {
            var model = PhysicalModel(modelID: "claude-sonnet-4-5")
            BenchmarkApplication.apply(anthropicEntry, to: &model, kind: .anthropic,
                                       settings: .default, knownContextWindow: 200_000,
                                       indexVersion: "3")
            try expectClose(model.pricingOverride?.inputPerMTok ?? 0, 3)
            try expectClose(model.pricingOverride?.outputPerMTok ?? 0, 15)
            try expectClose(model.pricingOverride?.cachedInputPerMTok ?? 0, 0.3)
        }

        test("prices the user typed are kept unless overwriting is asked for") {
            var model = PhysicalModel(modelID: "claude-sonnet-4-5",
                                      pricingOverride: Pricing(inputPerMTok: 1, outputPerMTok: 2))
            BenchmarkApplication.apply(anthropicEntry, to: &model, kind: .anthropic,
                                       settings: .default, knownContextWindow: nil, indexVersion: "3")
            try expectClose(model.pricingOverride?.inputPerMTok ?? 0, 1)

            var overwriting = BenchmarkSettings.default
            overwriting.overwriteExistingPricing = true
            BenchmarkApplication.apply(anthropicEntry, to: &model, kind: .anthropic,
                                       settings: overwriting, knownContextWindow: nil, indexVersion: "3")
            try expectClose(model.pricingOverride?.inputPerMTok ?? 0, 3)
        }

        test("a local or subscription target never takes the hosted model's prices") {
            // Its marginal cost is zero, and writing $3/Mtok onto the copy
            // running on this Mac would make cost-aware routing avoid the one
            // target that is actually free.
            for kind in [ProviderKind.ollama, .vllm, .chatgptSubscription, .claudeCodeCLI] {
                var model = PhysicalModel(modelID: "claude-sonnet-4-5")
                BenchmarkApplication.apply(anthropicEntry, to: &model, kind: kind,
                                           settings: .default, knownContextWindow: nil,
                                           indexVersion: "3")
                try expectNil(model.pricingOverride?.inputPerMTok, "\(kind.rawValue) took a price")
                // The score still applies: the weights are as good wherever they run.
                try expectClose(model.qualityScore, 63.2)
            }
        }

        test("a context window the provider already stated is never contradicted") {
            var model = PhysicalModel(modelID: "claude-sonnet-4-5")
            BenchmarkApplication.apply(anthropicEntry, to: &model, kind: .anthropic,
                                       settings: .default, knownContextWindow: 500_000,
                                       indexVersion: "3")
            try expectNil(model.capabilityOverrides.contextWindow)
        }

        test("a context window nobody reported is filled in") {
            var model = PhysicalModel(modelID: "claude-sonnet-4-5")
            BenchmarkApplication.apply(anthropicEntry, to: &model, kind: .anthropic,
                                       settings: .default, knownContextWindow: nil,
                                       indexVersion: "3")
            try expectEqual(model.capabilityOverrides.contextWindow, 200_000)
        }

        test("turning every field off still records what was measured") {
            // The scores are then reference material, not routing input — which
            // is the point of keeping the record separate from the fields.
            var settings = BenchmarkSettings.default
            settings.applyIntelligenceScore = false
            settings.applyPricing = false
            settings.applyContextWindow = false
            try expect(settings.appliesNothing)

            var model = PhysicalModel(modelID: "claude-sonnet-4-5", qualityScore: 60)
            let changes = BenchmarkApplication.apply(anthropicEntry, to: &model, kind: .anthropic,
                                                     settings: settings, knownContextWindow: nil,
                                                     indexVersion: "3")
            try expect(changes.isEmpty)
            try expectClose(model.qualityScore, 60)
            try expectClose(model.benchmark?.intelligenceIndex ?? 0, 63.2)
        }

        test("what was matched is recorded, so a wrong match is findable") {
            var model = PhysicalModel(modelID: "claude-sonnet-4-5")
            BenchmarkApplication.apply(anthropicEntry, to: &model, kind: .anthropic,
                                       settings: .default, knownContextWindow: nil, indexVersion: "3")
            let benchmark = try expectNotNil(model.benchmark)
            try expectEqual(benchmark.sourceSlug, "claude-4-5-sonnet")
            try expectEqual(benchmark.sourceName, "Claude 4.5 Sonnet")
            try expectEqual(benchmark.creator, "Anthropic")
            try expectEqual(benchmark.indexVersion, "3")
            try expectNotNil(benchmark.fetchedAt)
        }

        test("a second fetch that changes nothing reports no changes") {
            var model = PhysicalModel(modelID: "claude-sonnet-4-5")
            BenchmarkApplication.apply(anthropicEntry, to: &model, kind: .anthropic,
                                       settings: .default, knownContextWindow: nil, indexVersion: "3")
            let again = BenchmarkApplication.apply(anthropicEntry, to: &model, kind: .anthropic,
                                                   settings: .default, knownContextWindow: nil,
                                                   indexVersion: "3")
            try expect(again.isEmpty, "a repeat fetch reported \(again.count) changes")
        }

        test("a score outside 0-100 is clamped to the scale routing uses") {
            var entry = anthropicEntry
            entry.intelligenceIndex = 143
            var model = PhysicalModel(modelID: "x")
            BenchmarkApplication.apply(entry, to: &model, kind: .anthropic, settings: .default,
                                       knownContextWindow: nil, indexVersion: nil)
            try expectClose(model.qualityScore, 100)
        }
    }

    // MARK: - Fetching

    suite("Benchmarks / fetching") {
        test("a rejected key is an authentication failure, not a silent empty catalog") {
            let transport = MockTransport()
            transport.stub("/api/v2/language/models/free", status: 401, json: "{\"error\":\"bad key\"}")
            let result = await BenchmarkCatalog.shared.refresh(apiKey: "nope", tier: .free,
                                                              transport: transport)
            guard case .failure(let error) = result else {
                throw TestFailure(message: "expected a failure", file: #file, line: #line)
            }
            try expectEqual(error.kind, .authentication)
            try expectContains(error.message, "API key")
        }

        test("a rate-limited fetch says so and leaves the cached scores alone") {
            _ = BenchmarkCatalog.shared.loadForTesting(Data(sample.utf8))
            defer { BenchmarkCatalog.shared.clearForTesting() }
            let transport = MockTransport()
            transport.stub("/api/v2/language/models/free", status: 429, json: "{}")
            let result = await BenchmarkCatalog.shared.refresh(apiKey: "k", tier: .free,
                                                              transport: transport)
            guard case .failure(let error) = result else {
                throw TestFailure(message: "expected a failure", file: #file, line: #line)
            }
            try expectEqual(error.kind, .rateLimit)
            // A failed refresh must never make Derby know less than it did.
            try expectNotNil(BenchmarkCatalog.shared.lookup("claude-sonnet-4-5"))
        }

        test("the key travels in the header the API documents, and the tier picks the path") {
            let transport = MockTransport()
            transport.stub("/api/v2/language/models", status: 500, json: "{}")
            _ = await BenchmarkCatalog.shared.refresh(apiKey: "secret-key", tier: .pro,
                                                      transport: transport)
            let sent = try expectNotNil(transport.requests.last)
            try expectEqual(sent.headers["x-api-key"], "secret-key")
            try expectEqual(sent.url.path, "/api/v2/language/models")
            try expectEqual(sent.method, "GET")
        }

        test("every page of the index is fetched, not just the first") {
            // The endpoint answers 200 rows and says how many pages exist.
            // Reading page 1 alone hid three quarters of the index — including,
            // for a model split across pages, every reasoning level but one.
            let transport = MockTransport()
            func page(_ n: Int, slug: String, totalPages: Int) -> OutboundResponse {
                OutboundResponse(status: 200, headers: [:], body: Data("""
                {"intelligence_index_version":4.3,
                 "pagination":{"page":\(n),"page_size":1,"total_pages":\(totalPages),
                               "has_more":\(n < totalPages)},
                 "data":[{"slug":"\(slug)","name":"\(slug)",
                          "evaluations":{"artificial_analysis_intelligence_index":\(n * 10)}}]}
                """.utf8))
            }
            transport.responder = { request in
                let page_ = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?
                    .queryItems?.first { $0.name == "page" }?.value
                switch page_ {
                case nil: return page(1, slug: "alpha-one", totalPages: 3)
                case "2": return page(2, slug: "beta-two", totalPages: 3)
                case "3": return page(3, slug: "gamma-three", totalPages: 3)
                default: return OutboundResponse(status: 404, headers: [:], body: Data())
                }
            }
            let result = await BenchmarkCatalog.shared.refresh(apiKey: "k", tier: .free,
                                                              transport: transport)
            defer { BenchmarkCatalog.shared.clearForTesting() }
            guard case .success(let count) = result else {
                throw TestFailure(message: "expected success, got \(result)", file: #file, line: #line)
            }
            try expectEqual(count, 3)
            try expectEqual(transport.requestCount, 3)
            // A model that landed on the last page is as findable as one on the first.
            try expectNotNil(BenchmarkCatalog.shared.lookup("gamma-three"))
            try expectEqual(BenchmarkCatalog.shared.indexVersion, "4.3")
        }

        test("a server that ignores the page parameter is asked only twice") {
            // Otherwise a quota counted per request is spent re-reading page 1
            // until `total_pages` runs out.
            let transport = MockTransport()
            transport.stub("/api/v2/language/models/free", json: """
            {"pagination":{"page":1,"page_size":1,"total_pages":9,"has_more":true},
             "data":[{"slug":"only-row","name":"Only Row",
                      "evaluations":{"artificial_analysis_intelligence_index":5}}]}
            """)
            let result = await BenchmarkCatalog.shared.refresh(apiKey: "k", tier: .free,
                                                              transport: transport)
            defer { BenchmarkCatalog.shared.clearForTesting() }
            guard case .success(let count) = result else {
                throw TestFailure(message: "expected success", file: #file, line: #line)
            }
            try expectEqual(count, 1)
            try expectEqual(transport.requestCount, 2)
        }

        test("a page that fails keeps the pages already in hand") {
            let transport = MockTransport()
            transport.responder = { request in
                let paged = request.url.query?.contains("page=") == true
                guard !paged else { return OutboundResponse(status: 500, headers: [:], body: Data()) }
                return OutboundResponse(status: 200, headers: [:], body: Data("""
                {"pagination":{"page":1,"page_size":1,"total_pages":4,"has_more":true},
                 "data":[{"slug":"kept-row","name":"Kept Row",
                          "evaluations":{"artificial_analysis_intelligence_index":5}}]}
                """.utf8))
            }
            let result = await BenchmarkCatalog.shared.refresh(apiKey: "k", tier: .free,
                                                              transport: transport)
            defer { BenchmarkCatalog.shared.clearForTesting() }
            guard case .success(let count) = result else {
                throw TestFailure(message: "expected the first page to be kept", file: #file, line: #line)
            }
            try expectEqual(count, 1)
            try expectNotNil(BenchmarkCatalog.shared.lookup("kept-row"))
        }

        test("no key configured sends no key header rather than an empty one") {
            let transport = MockTransport()
            transport.stub("/api/v2/language/models/free", status: 500, json: "{}")
            _ = await BenchmarkCatalog.shared.refresh(apiKey: "   ", tier: .free, transport: transport)
            try expectNil(transport.requests.last?.headers["x-api-key"])
        }
    }

    // MARK: - Persistence

    suite("Benchmarks / logical model pins") {
        /// An engine over a throwaway directory, with the fixture catalog
        /// already loaded so no fetch is attempted.
        func engine(_ config: DerbyConfig) throws -> DerbyEngine {
            let dir = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("derby-pin-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let store = ConfigStore(url: dir.appendingPathComponent("config.json"))
            try store.save(config)
            _ = BenchmarkCatalog.shared.loadForTesting(Data(sample.utf8))
            return DerbyEngine(configStore: store, secrets: InMemorySecretStore(),
                               transport: MockTransport(),
                               telemetry: TelemetryStore(
                                path: dir.appendingPathComponent("t.sqlite3").path,
                                settings: config.logging))
        }

        /// A provider with one model, and a logical model targeting it.
        func fixture(score: Double, pin: Double?) -> (DerbyConfig, UUID) {
            var model = PhysicalModel(modelID: "claude-sonnet-4-5", qualityScore: score)
            model.capabilities = ModelCapabilities(flags: [.text, .streaming], contextWindow: 200_000)
            let account = ProviderAccount(name: "Anthropic", kind: .anthropic, models: [model])
            var logical = LogicalModel(name: "smart")
            logical.targets = [TargetRef(providerID: account.id, modelUUID: model.id,
                                         qualityOverride: pin)]
            var config = DerbyConfig(providers: [account], logicalModels: [logical])
            config.benchmarks = .default
            return (config, account.id)
        }

        test("a pin that merely mirrored the old score stops shadowing a fetched one") {
            // The quality field in the logical model view writes a pin on any
            // commit, so tabbing through it froze the target at that moment.
            // Left alone, the fetch below would change the model and change
            // nothing about how it is actually routed.
            let (config, providerID) = fixture(score: 74, pin: 74)
            let engine = try engine(config)
            defer { BenchmarkCatalog.shared.clearForTesting() }
            let report = await engine.applyBenchmarks(providerID: providerID)
            try expectEqual(report.matched.count, 1)

            let saved = await engine.config()
            try expectClose(saved.providers[0].models[0].qualityScore, 70.0)
            try expectNil(saved.logicalModels[0].targets[0].qualityOverride,
                          "the stale pin still shadows the fetched score")
            try expect(report.stillPinned.isEmpty)
        }

        test("a pin that says something different is kept, and reported") {
            let (config, providerID) = fixture(score: 74, pin: 20)
            let engine = try engine(config)
            defer { BenchmarkCatalog.shared.clearForTesting() }
            let report = await engine.applyBenchmarks(providerID: providerID)

            let saved = await engine.config()
            try expectClose(saved.providers[0].models[0].qualityScore, 70.0)
            try expectClose(saved.logicalModels[0].targets[0].qualityOverride ?? 0, 20,
                            "a deliberate pin was discarded")
            try expectEqual(report.stillPinned.count, 1)
            try expectContains(report.stillPinned[0], "stays pinned at 20")
        }

        test("a model whose score does not move leaves every pin alone") {
            // Already at the ceiling row's 70.0, so nothing changes and the
            // pin is not something this fetch has any business touching.
            let (config, providerID) = fixture(score: 70.0, pin: 70.0)
            let engine = try engine(config)
            defer { BenchmarkCatalog.shared.clearForTesting() }
            _ = await engine.applyBenchmarks(providerID: providerID)
            let saved = await engine.config()
            try expectClose(saved.logicalModels[0].targets[0].qualityOverride ?? 0, 70.0)
        }
    }

    suite("Benchmarks / persistence") {
        test("a configuration written before benchmarks existed still decodes cleanly") {
            // The regression this whole codebase is careful about: a new
            // non-optional field on a persisted type once made `providers`
            // undecodable and silently emptied it.
            let legacy = """
            {"schemaVersion":2,"gateway":{"port":8787,"bindAddress":"127.0.0.1",
             "requireAPIKey":false,"localKeyRef":{"account":"gateway.localKey"},
             "autoStart":true,"allowRemoteAccess":false,"maxConcurrentRequests":64,
             "allowedOrigins":[]},
             "providers":[{"id":"\(UUID().uuidString)","name":"OpenAI","kind":"openai",
               "enabled":true,"auth":{"none":{}},"extraHeaders":{},
               "requestTimeoutSeconds":120,"connectTimeoutSeconds":10,
               "rateLimits":{"maxConcurrentRequests":8},
               "models":[{"id":"\(UUID().uuidString)","modelID":"gpt-5.1","enabled":true,
                 "capabilities":{"flags":["text"],"unsupportedParameters":[],"source":"builtin"},
                 "capabilityOverrides":{},"qualityScore":72}],
               "notes":"","createdAt":0,"allowInsecureTLS":false,"preferenceScore":50}],
             "logicalModels":[],"pricingOverrides":{}}
            """
            let config = try JSONDecoder().decode(DerbyConfig.self, from: Data(legacy.utf8))
            try expect(config.decodeFailures.isEmpty,
                       "decode failures: \(config.decodeFailures.joined(separator: "; "))")
            try expectEqual(config.providers.count, 1)
            try expectEqual(config.providers.first?.models.count, 1)
            try expectNil(config.providers.first?.models.first?.benchmark)
            // Absent means the defaults, not a reset of everything else.
            try expect(config.benchmarks.applyIntelligenceScore)
            try expectEqual(config.benchmarks.tier, .free)
        }

        test("a fetched benchmark survives a save and load") {
            var config = DerbyConfig.seeded()
            var model = PhysicalModel(modelID: "claude-sonnet-4-5")
            BenchmarkApplication.apply(anthropicEntry, to: &model, kind: .anthropic,
                                       settings: .default, knownContextWindow: nil, indexVersion: "3")
            config.providers = [ProviderAccount(name: "Anthropic", kind: .anthropic, models: [model])]
            config.benchmarks.tier = .pro
            config.benchmarks.overwriteExistingPricing = true

            let data = try JSONEncoder().encode(config)
            let decoded = try JSONDecoder().decode(DerbyConfig.self, from: data)
            try expect(decoded.decodeFailures.isEmpty)
            let restored = try expectNotNil(decoded.providers.first?.models.first?.benchmark)
            try expectClose(restored.intelligenceIndex ?? 0, 63.2)
            try expectEqual(restored.sourceSlug, "claude-4-5-sonnet")
            try expectEqual(decoded.benchmarks.tier, .pro)
            try expect(decoded.benchmarks.overwriteExistingPricing)
        }

        test("the benchmark key is kept when the Keychain is pruned") {
            let config = DerbyConfig.seeded()
            try expect(config.allSecretRefs.contains(config.benchmarks.apiKeyRef),
                       "pruning would delete the benchmark API key")
        }
    }
}
