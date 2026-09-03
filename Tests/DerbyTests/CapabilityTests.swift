import Foundation
@testable import DerbyCore

func registerCapabilityTests() {
    suite("Capabilities") {
        test("flags serialize as stable names") {
            let flags: CapabilityFlags = [.text, .tools, .vision]
            let data = try JSONEncoder().encode(flags)
            let text = String(data: data, encoding: .utf8) ?? ""
            try expectContains(text, "tools")
            let back = try JSONDecoder().decode(CapabilityFlags.self, from: data)
            try expectEqual(back, flags)
        }

        test("unmet requirement names the missing capability") {
            let caps = ModelCapabilities(flags: [.text, .streaming], contextWindow: 8192)
            let need = CapabilityRequirements(required: [.text, .tools])
            let reason = try expectNotNil(need.unmetReason(for: caps))
            try expectContains(reason, "tools")
        }

        test("context window that is too small is rejected") {
            let caps = ModelCapabilities(flags: [.text], contextWindow: 4096)
            let need = CapabilityRequirements(required: [.text], minContextTokens: 40_000)
            let reason = try expectNotNil(need.unmetReason(for: caps))
            try expectContains(reason, "context window too small")
        }

        test("unknown context window never blocks routing") {
            let caps = ModelCapabilities(flags: [.text], contextWindow: nil)
            let need = CapabilityRequirements(required: [.text], minContextTokens: 1_000_000)
            try expectNil(need.unmetReason(for: caps))
        }

        test("user overrides win over discovered metadata") {
            let base = ModelCapabilities(flags: [.text], contextWindow: 8192, source: .discovered)
            let overridden = base.overridden(by: PartialCapabilities(flags: [.text, .tools], contextWindow: 200_000))
            try expect(overridden.flags.contains(.tools))
            try expectEqual(overridden.contextWindow, 200_000)
            try expectEqual(overridden.source, .userOverride)
        }

        test("catalog knows well-known models and degrades safely for unknown ones") {
            let known = ModelCatalog.metadata(for: "claude-sonnet-4-5-20250929", kind: .anthropic)
            try expect(known.capabilities.flags.contains(.tools))
            try expect(known.capabilities.contextWindow ?? 0 >= 200_000)
            try expect(known.pricing?.isKnown == true)

            let unknown = ModelCatalog.metadata(for: "totally-made-up-model", kind: .openai)
            try expect(unknown.capabilities.flags.contains(.text))
            try expect(!unknown.capabilities.flags.contains(.tools), "must not claim unverified tool support")
            try expectNil(unknown.pricing)
        }

        test("local models are treated as flat-rate") {
            let local = ModelCatalog.metadata(for: "qwen3.5:9b", kind: .ollama)
            try expectEqual(local.pricing?.isFlatRate, true)
        }
    }
}
