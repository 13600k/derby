import Foundation

/// The little of Prometheus' text format that serving engines use.
///
/// vLLM and SGLang publish their queue depth and cache pressure this way and
/// nowhere else, so reading a handful of gauges is the only way to learn what a
/// server is actually doing. One metric can appear several times with different
/// labels (one set per served model), so samples are kept as a list and the
/// caller decides whether to add them up or take the largest.
enum PrometheusText {
    static func samples(_ text: String) -> [String: [Double]] {
        var out: [String: [Double]] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            // `name{label="a b"} 12.5` — the value is always last, labels are not.
            guard let split = trimmed.lastIndex(of: " ") else { continue }
            guard let value = Double(trimmed[trimmed.index(after: split)...].trimmingCharacters(in: .whitespaces)),
                  value.isFinite else { continue }
            var name = String(trimmed[..<split])
            if let brace = name.firstIndex(of: "{") { name = String(name[..<brace]) }
            name = name.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            out[name, default: []].append(value)
        }
        return out
    }

    /// Every sample of the metric added together — right for counts of requests.
    static func total(_ samples: [String: [Double]], _ name: String) -> Double? {
        samples[name].map { $0.reduce(0, +) }
    }

    /// The largest sample — right for a ratio, which must not be summed across
    /// the models a server happens to host.
    static func peak(_ samples: [String: [Double]], _ name: String) -> Double? {
        samples[name]?.max()
    }
}
