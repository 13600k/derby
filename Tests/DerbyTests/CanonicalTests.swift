import Foundation
@testable import DerbyCore

func registerCanonicalTests() {
    suite("Canonical / JSON") {
        test("JSONValue round-trips and encodes integers without a decimal point") {
            let v = JSONValue.object(["a": .number(64), "b": .string("x"), "c": .array([.bool(true), .null])])
            let encoded = v.compactJSONString
            try expectContains(encoded, "\"a\":64")
            try expect(!encoded.contains("64.0"), "integral numbers must not encode as floats")
            let decoded = try expectNotNil(JSONValue.parse(encoded))
            try expectEqual(decoded["a"]?.intValue, 64)
            try expectEqual(decoded["c"]?[0]?.boolValue, true)
        }

        test("merging overlays nested objects") {
            let base = JSONValue.object(["a": .object(["x": .number(1), "y": .number(2)]), "b": .number(3)])
            let overlay = JSONValue.object(["a": .object(["y": .number(9)]), "c": .number(4)])
            let merged = base.merging(overlay)
            try expectEqual(merged["a"]?["x"]?.intValue, 1)
            try expectEqual(merged["a"]?["y"]?.intValue, 9, "overlay wins")
            try expectEqual(merged["c"]?.intValue, 4)
        }
    }

    suite("Canonical / OpenAI request normalization") {
        test("parses a plain chat request") {
            let json = try expectNotNil(JSONValue.parse("""
            {"model":"coding","messages":[{"role":"system","content":"be brief"},
                                          {"role":"user","content":"hello"}],
             "temperature":0.3,"max_tokens":128,"stop":["END"],"stream":true}
            """))
            let r = try OpenAIRequestParser.parseChatCompletions(json)
            try expectEqual(r.requestedModel, "coding")
            try expectEqual(r.messages.count, 2)
            try expectEqual(r.messages[0].role, .system)
            try expectEqual(r.messages[1].joinedText, "hello")
            try expectEqual(r.temperature, 0.3)
            try expectEqual(r.maxOutputTokens, 128)
            try expectEqual(r.stop, ["END"])
            try expect(r.stream)
        }

        test("max_completion_tokens takes precedence over max_tokens") {
            let json = try expectNotNil(JSONValue.parse("""
            {"model":"m","messages":[],"max_tokens":10,"max_completion_tokens":99}
            """))
            let r = try OpenAIRequestParser.parseChatCompletions(json)
            try expectEqual(r.maxOutputTokens, 99)
        }

        test("parses multimodal content including data URIs") {
            let json = try expectNotNil(JSONValue.parse("""
            {"model":"m","messages":[{"role":"user","content":[
               {"type":"text","text":"what is this?"},
               {"type":"image_url","image_url":{"url":"data:image/jpeg;base64,QUJD","detail":"high"}}]}]}
            """))
            let r = try OpenAIRequestParser.parseChatCompletions(json)
            try expect(r.hasImages)
            guard case .image(let img) = r.messages[0].content[1] else {
                throw TestFailure(message: "expected an image part", file: #fileID, line: #line)
            }
            try expectEqual(img.base64, "QUJD")
            try expectEqual(img.mimeType, "image/jpeg")
            try expectEqual(img.detail, "high")
            try expect(r.capabilityRequirements.required.contains(.vision))
        }

        test("parses tools, tool_choice and assistant tool calls") {
            let json = try expectNotNil(JSONValue.parse("""
            {"model":"m","messages":[
               {"role":"assistant","tool_calls":[{"id":"c1","type":"function",
                  "function":{"name":"get_weather","arguments":"{\\"city\\":\\"Paris\\"}"}}]},
               {"role":"tool","tool_call_id":"c1","content":"18C"}],
             "tools":[{"type":"function","function":{"name":"get_weather","description":"w",
                       "parameters":{"type":"object","properties":{"city":{"type":"string"}}}}}],
             "tool_choice":{"type":"function","function":{"name":"get_weather"}}}
            """))
            let r = try OpenAIRequestParser.parseChatCompletions(json)
            try expectEqual(r.tools.count, 1)
            try expectEqual(r.tools[0].name, "get_weather")
            try expectEqual(r.messages[0].toolCalls.first?.name, "get_weather")
            try expectEqual(r.messages[0].toolCalls.first?.argumentsValue["city"]?.stringValue, "Paris")
            try expectEqual(r.messages[1].toolCallID, "c1")
            guard case .function(let name)? = r.toolChoice else {
                throw TestFailure(message: "expected a named tool choice", file: #fileID, line: #line)
            }
            try expectEqual(name, "get_weather")
            try expect(r.capabilityRequirements.required.contains(.tools))
        }

        test("parses json_schema response format") {
            let json = try expectNotNil(JSONValue.parse("""
            {"model":"m","messages":[],"response_format":{"type":"json_schema",
              "json_schema":{"name":"out","strict":true,"schema":{"type":"object"}}}}
            """))
            let r = try OpenAIRequestParser.parseChatCompletions(json)
            guard case .jsonSchema(let name, _, let strict)? = r.responseFormat else {
                throw TestFailure(message: "expected json_schema", file: #fileID, line: #line)
            }
            try expectEqual(name, "out")
            try expect(strict)
            try expect(r.capabilityRequirements.required.contains(.jsonSchema))
        }

        test("rejects a request with no model") {
            _ = try await expectFailure(.invalidRequest) {
                _ = try OpenAIRequestParser.parseChatCompletions(.object(["messages": .array([])]))
            }
        }

        test("keeps unmapped client fields for the inspector") {
            let json = try expectNotNil(JSONValue.parse("""
            {"model":"m","messages":[],"some_future_field":{"a":1}}
            """))
            let r = try OpenAIRequestParser.parseChatCompletions(json)
            try expectEqual(r.unmappedFields["some_future_field"]?["a"]?.intValue, 1)
        }

        test("parses the Responses API dialect") {
            let json = try expectNotNil(JSONValue.parse("""
            {"model":"smart","instructions":"be terse",
             "input":[{"type":"message","role":"user","content":[{"type":"input_text","text":"hi"}]},
                      {"type":"function_call","call_id":"c9","name":"f","arguments":"{}"},
                      {"type":"function_call_output","call_id":"c9","output":"done"}],
             "max_output_tokens":50}
            """))
            let r = try OpenAIRequestParser.parseResponses(json)
            try expectEqual(r.dialect, .responses)
            try expectEqual(r.messages.count, 4)
            try expectEqual(r.messages[0].role, .system)
            try expectEqual(r.messages[1].joinedText, "hi")
            try expectEqual(r.messages[2].toolCalls.first?.id, "c9")
            try expectEqual(r.messages[3].role, .tool)
            try expectEqual(r.maxOutputTokens, 50)
        }

        test("parses embeddings and rejects tokenized input") {
            let ok = try OpenAIRequestParser.parseEmbeddings(
                .object(["model": .string("e"), "input": .array([.string("a"), .string("b")])]))
            try expectEqual(ok.inputs.count, 2)
            _ = try await expectFailure(.invalidRequest) {
                _ = try OpenAIRequestParser.parseEmbeddings(
                    .object(["model": .string("e"), "input": .array([.number(1), .number(2)])]))
            }
        }
    }

    suite("Canonical / streaming accumulation") {
        test("accumulates text, reasoning, tool calls and usage") {
            var acc = StreamAccumulator()
            acc.ingest(.start(id: "abc", model: "m1"))
            acc.ingest(.reasoningDelta("think"))
            acc.ingest(.textDelta("Hello "))
            acc.ingest(.textDelta("world"))
            acc.ingest(.toolCallStart(index: 0, id: "c1", name: "f"))
            acc.ingest(.toolCallArgumentsDelta(index: 0, delta: "{\"a\":"))
            acc.ingest(.toolCallArgumentsDelta(index: 0, delta: "1}"))
            acc.ingest(.usage(CanonicalUsage(inputTokens: 7, outputTokens: 3)))
            acc.ingest(.finish(.toolCalls))

            let r = acc.makeResponse(fallbackModel: "fallback")
            try expectEqual(r.model, "m1")
            try expectEqual(r.message.joinedText, "Hello world")
            try expectEqual(r.message.reasoning, "think")
            try expectEqual(r.message.toolCalls.count, 1)
            try expectEqual(r.message.toolCalls[0].argumentsJSON, "{\"a\":1}")
            try expectEqual(r.message.toolCalls[0].argumentsValue["a"]?.intValue, 1)
            try expectEqual(r.usage.inputTokens, 7)
            try expectEqual(r.finishReason, .toolCalls)
        }
    }

    suite("Canonical / cost") {
        test("computes cost with cached-token discount") {
            let p = Pricing(inputPerMTok: 3, outputPerMTok: 15, cachedInputPerMTok: 0.3)
            let usage = CanonicalUsage(inputTokens: 1_000_000, outputTokens: 100_000, cachedInputTokens: 500_000)
            let cost = try expectNotNil(p.cost(for: usage))
            // 500k fresh @ $3 + 500k cached @ $0.30 + 100k output @ $15
            try expectClose(cost, 1.5 + 0.15 + 1.5, tolerance: 0.0001)
        }
        test("flat-rate targets cost nothing at the margin") {
            let cost = try expectNotNil(Pricing.free.cost(for: CanonicalUsage(inputTokens: 999, outputTokens: 999)))
            try expectEqual(cost, 0)
        }
        test("unknown pricing yields nil rather than zero") {
            try expectNil(Pricing().cost(for: CanonicalUsage(inputTokens: 10)))
        }
    }
}
