import Foundation

/// What a model's chat template says about itself, for servers that publish the
/// template they render: llama.cpp in `/props`, Ollama in `/api/show`.
///
/// The template is the authority on what these weights accept, because it is
/// what turns a request into a prompt. Qwen 3.8's names its reasoning levels
/// and raises on any other, and no catalog agrees with it: other hosts list the
/// same weights with anything from `low, medium` to nothing at all.
public enum ChatTemplateFacts {

    /// The reasoning levels the template enumerates, weakest first, with `none`
    /// when it also has a switch that turns thinking off. Nil when it names no
    /// levels, since a template that reads the variable unchecked says nothing
    /// about which values it takes.
    public static func reasoningEfforts(in template: String) -> [String]? {
        // `resolved_reasoning_effort not in ('xhigh', 'medium', 'low')`
        guard let list = firstCapture(#"\w*reasoning_effort\w*\s+(?:not\s+)?in\s+[\(\[]([^\)\]]*)[\)\]]"#,
                                      in: template) else { return nil }
        var levels = captures(#"['"]([^'"]+)['"]"#, in: list)
        guard !levels.isEmpty else { return nil }
        if template.contains("enable_thinking"), !levels.contains("none") { levels.append("none") }
        func rank(_ level: String) -> Int {
            level == "none" ? -1 : ReasoningEffort.allCases.firstIndex { $0.rawValue == level } ?? .max
        }
        return levels.sorted { rank($0) < rank($1) }
    }

    /// Whether the template renders every tool call an assistant turn made,
    /// which is what llama.cpp tests before reporting
    /// `supports_parallel_tool_calls`. One that renders only the first shows
    /// the model a history in which it never made two.
    public static func rendersParallelToolCalls(_ template: String) -> Bool {
        firstCapture(#"(for\s+\w+\s+in\s+message(?:\.tool_calls|\[['"]tool_calls['"]\]))"#, in: template) != nil
            || firstCapture(#"(range[^}]*\.ToolCalls)"#, in: template) != nil
    }

    private static func firstCapture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    private static func captures(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range(at: 1), in: text).map { String(text[$0]) }
        }
    }
}
