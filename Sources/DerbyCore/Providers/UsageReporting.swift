import Foundation

// Plan meters, one per provider that publishes one to the credential Derby
// already holds. Each is a GET that spends nothing; `UsageMonitor` decides
// how often they run.

// MARK: - Shared

extension ProviderAdapter {
    /// `path` against the scheme and host of `base`, discarding the base's
    /// own path: a meter usually sits beside the inference API, not under it.
    func hostURL(_ base: String, path: String) throws -> URL {
        guard var comps = URLComponents(string: base), comps.host != nil else {
            throw DerbyError(kind: .invalidRequest, message: "Invalid base URL: \(base)")
        }
        comps.path = "/" + path.trimmingLeadingSlash
        comps.query = nil
        guard let u = comps.url else {
            throw DerbyError(kind: .invalidRequest, message: "Invalid URL built from \(base)")
        }
        return u
    }

    /// GETs a meter, classifying a failure the way the adapter classifies any.
    func fetchUsageDocument(_ ctx: ProviderContext, url: URL, headers: [String: String]) async throws -> JSONValue {
        var h = headers
        h["accept"] = "application/json"
        let response = try await ctx.transport.send(OutboundRequest(
            url: url, method: "GET", headers: h,
            timeout: min(ctx.account.outOfBandTimeoutSeconds, 20),
            allowInsecureTLS: ctx.account.allowInsecureTLS))
        guard (200..<300).contains(response.status) else {
            throw classifyError(status: response.status, headers: response.headers,
                                body: response.body, model: "")
        }
        guard let json = response.bodyJSON else {
            throw DerbyError(kind: .transient, message: "The usage report was not JSON.")
        }
        return json
    }
}

/// Timestamps as meters write them: ISO 8601 with anything from zero to six
/// fractional digits, or Unix seconds (occasionally milliseconds).
enum UsageTime {
    static func date(_ value: JSONValue?) -> Date? {
        guard let value, !value.isNull else { return nil }
        if case .number(let n) = value { return unix(n) }
        guard let s = value.stringValue?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        if let n = Double(s) { return unix(n) }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: s) { return d }
        // Microsecond precision is more than the formatter accepts.
        if let dot = s.firstIndex(of: "."),
           let end = s[s.index(after: dot)...].firstIndex(where: { !$0.isNumber }) {
            return f.date(from: String(s[..<dot]) + String(s[end...]))
        }
        return nil
    }

    private static func unix(_ n: Double) -> Date? {
        guard n > 0 else { return nil }
        return Date(timeIntervalSince1970: n > 1e12 ? n / 1000 : n)
    }
}

// MARK: - Claude subscription

/// The meter behind Claude Code's `/usage`: `GET /api/oauth/usage` on the API
/// host, with the same OAuth identity the Messages API takes.
enum ClaudePlanUsage {
    static let path = "api/oauth/usage"
    static let defaultHost = "https://api.anthropic.com"

    /// Utilization is a percentage, always — `1.0` is one percent, not all of it.
    static func parse(_ json: JSONValue, now: Date = Date()) -> ProviderUsage {
        var windows: [ProviderUsage.Window] = []

        func add(_ id: String, _ label: String, _ node: JSONValue?, duration: Double?) {
            guard let node, !node.isNull, let percent = node["utilization"]?.doubleValue else { return }
            windows.append(.init(id: id, label: label, usedFraction: percent / 100,
                                 duration: duration, resetsAt: UsageTime.date(node["resets_at"])))
        }

        add("five_hour", "5-hour", json["five_hour"], duration: ProviderUsage.fiveHours)
        add("seven_day", "Weekly", json["seven_day"], duration: ProviderUsage.week)
        // Per-model weekly caps, in the older flat form (`seven_day_opus`, …).
        // Accounts moved to `limits[]` still send these keys, as null.
        for (key, node) in (json.objectValue ?? [:]).sorted(by: { $0.key < $1.key })
        where key.hasPrefix("seven_day_") {
            let scope = String(key.dropFirst("seven_day_".count))
            add("seven_day.\(scope)", "Weekly · \(prettyScope(scope))", node, duration: ProviderUsage.week)
        }

        // The newer form: every limit in one list, per-model caps included.
        for entry in json["limits"]?.arrayValue ?? [] {
            guard let percent = entry["percent"]?.doubleValue ?? entry["utilization"]?.doubleValue else { continue }
            let active = entry["is_active"]?.boolValue == true
            let resets = UsageTime.date(entry["resets_at"])
            let id: String, label: String, duration: Double
            switch entry["kind"]?.stringValue {
            case "session":
                (id, label, duration) = ("five_hour", "5-hour", ProviderUsage.fiveHours)
            case "weekly_all":
                (id, label, duration) = ("seven_day", "Weekly", ProviderUsage.week)
            case "weekly_scoped":
                let model = entry["scope"]?["model"]
                let name = model?["display_name"]?.stringValue ?? model?["id"]?.stringValue ?? "one model"
                (id, label, duration) = ("weekly_scoped.\(name.lowercased())", "Weekly · \(name)", ProviderUsage.week)
            default:
                continue
            }
            // A window both forms describe is shown once; the list only adds
            // whether it is the one blocking right now.
            if let i = windows.firstIndex(where: { $0.id == id || $0.label.lowercased() == label.lowercased() }) {
                windows[i].isLimiting = windows[i].isLimiting || active
                if windows[i].resetsAt == nil { windows[i].resetsAt = resets }
                continue
            }
            windows.append(.init(id: id, label: label, usedFraction: percent / 100,
                                 duration: duration, resetsAt: resets, isLimiting: active))
        }

        if let extra = json["extra_usage"], extra["is_enabled"]?.boolValue == true,
           let percent = extra["utilization"]?.doubleValue {
            windows.append(.init(id: "extra_usage", label: "Extra usage", usedFraction: percent / 100))
        }

        return ProviderUsage(source: .provider, windows: windows,
                             providerSaysLimited: windows.contains(where: \.isLimiting),
                             observedAt: now)
    }

    static func prettyScope(_ scope: String) -> String {
        switch scope {
        case "oauth_apps": return "OAuth apps"
        default:
            return scope.split(separator: "_").enumerated()
                .map { $0.offset == 0 ? $0.element.prefix(1).uppercased() + $0.element.dropFirst() : String($0.element) }
                .joined(separator: " ")
        }
    }
}

extension AnthropicAdapter {
    /// Only a subscription login has a plan meter. A metered API key's
    /// allowance sits behind an admin key Derby does not hold.
    public func usage(_ ctx: ProviderContext) async throws -> ProviderUsage? {
        guard case .cli = ctx.account.auth else { return nil }
        let auth = try await authenticate(ctx)
        let base = ctx.account.baseURL.isEmpty ? ClaudePlanUsage.defaultHost : ctx.account.baseURL
        let json = try await fetchUsageDocument(ctx, url: hostURL(base, path: ClaudePlanUsage.path),
                                                headers: headers(ctx, auth: auth))
        return ClaudePlanUsage.parse(json)
    }
}

extension ClaudeCLIAdapter {
    /// The CLI spends the same plan as the direct-API path, so its meter is
    /// the same endpoint, read with the same login. `authenticate` never reads
    /// that login because a Keychain dialog on the request path hung every
    /// request; a meter read is safe where that was not, because a poll never
    /// opens the Keychain (`ProviderContext.mayPromptForCredentials`) and one
    /// stuck behind a dialog is abandoned at its deadline.
    public func usage(_ ctx: ProviderContext) async throws -> ProviderUsage? {
        // Never refreshed from here: the CLI renews its own token when it runs.
        var account = ctx.account
        account.auth = .cli(source: .claudeCode, allowRefresh: false)
        return try await AnthropicAdapter(oauth: true).usage(
            ProviderContext(account: account, transport: ctx.transport, secrets: ctx.secrets,
                            credentials: ctx.credentials, attemptTimeout: ctx.attemptTimeout,
                            mayPromptForCredentials: ctx.mayPromptForCredentials))
    }
}

// MARK: - ChatGPT subscription

extension ChatGPTCodexAdapter {
    /// The meter the Codex CLI shows in `/status`. Under the ChatGPT backend it
    /// is `wham/usage`, beside `codex/`; the Codex API's own host names it
    /// `api/codex/usage`.
    static func usageURL(base: String) throws -> URL {
        var root = base.trimmedTrailingSlash
        if root.hasSuffix("/codex") { root = String(root.dropLast("/codex".count)) }
        let path = root.contains("/backend-api") ? "/wham/usage" : "/api/codex/usage"
        guard let u = URL(string: root + path) else {
            throw DerbyError(kind: .invalidRequest, message: "Invalid base URL: \(base)")
        }
        return u
    }

    public func usage(_ ctx: ProviderContext) async throws -> ProviderUsage? {
        let auth = try await authenticate(ctx)
        let json = try await fetchUsageDocument(
            ctx, url: Self.usageURL(base: auth.baseURLOverride ?? ctx.account.baseURL),
            headers: headers(ctx, auth: auth))
        return Self.parsePlanUsage(json)
    }

    static func parsePlanUsage(_ json: JSONValue, now: Date = Date()) -> ProviderUsage {
        func windows(_ limit: JSONValue?, idPrefix: String, suffix: String?) -> [ProviderUsage.Window] {
            guard let limit, !limit.isNull else { return [] }
            let reached = limit["limit_reached"]?.boolValue == true
            return ["primary_window", "secondary_window"].compactMap { slot -> ProviderUsage.Window? in
                guard let w = limit[slot] ?? limit[camel(slot)], !w.isNull,
                      let percent = (w["used_percent"] ?? w["usedPercent"])?.doubleValue else { return nil }
                let seconds = (w["limit_window_seconds"] ?? w["limitWindowSeconds"])?.doubleValue
                    ?? (w["window_minutes"] ?? w["windowMinutes"])?.doubleValue.map { $0 * 60 }
                let resets = UsageTime.date(w["reset_at"] ?? w["resets_at"] ?? w["resetAt"])
                    ?? (w["reset_after_seconds"] ?? w["resetAfterSeconds"])?.doubleValue
                        .map { now.addingTimeInterval($0) }
                // Named by length: a weekly-only plan's one window arrives in
                // the slot a five-hour window usually fills.
                var label = seconds.map(ProviderUsage.label(forWindowSeconds:)) ?? "Usage"
                if let suffix { label += " · \(suffix)" }
                return .init(id: "\(idPrefix).\(slot)", label: label, usedFraction: percent / 100,
                             duration: seconds, resetsAt: resets, isLimiting: reached && percent >= 100)
            }
            .sorted { ($0.duration ?? .infinity) < ($1.duration ?? .infinity) }
        }

        let main = json["rate_limit"] ?? json["rateLimit"]
        var all = windows(main, idPrefix: "codex", suffix: nil)
        var limited = main?["limit_reached"]?.boolValue == true || main?["allowed"]?.boolValue == false
        // Model-level limits a plan meters separately; one can be spent while
        // the account-wide windows still read zero.
        for extra in (json["additional_rate_limits"] ?? json["additionalRateLimits"])?.arrayValue ?? [] {
            let name = (extra["limit_name"] ?? extra["metered_feature"])?.stringValue ?? "model"
            let limit = extra["rate_limit"] ?? extra["rateLimit"]
            all += windows(limit, idPrefix: "extra.\(name)", suffix: name)
            if limit?["limit_reached"]?.boolValue == true { limited = true }
        }

        var amounts: [ProviderUsage.Amount] = []
        if let credits = json["credits"], credits["has_credits"]?.boolValue == true,
           credits["unlimited"]?.boolValue != true,
           let balance = credits["balance"]?.doubleValue {
            amounts.append(.init(label: "Credits", value: balance, unit: .credits))
        }
        return ProviderUsage(source: .provider,
                             plan: json["plan_type"]?.stringValue.map(planName),
                             windows: all, amounts: amounts,
                             providerSaysLimited: limited, observedAt: now)
    }

    static func planName(_ raw: String) -> String {
        switch raw.lowercased() {
        case "prolite": return "Pro Lite"
        default:
            return raw.split(separator: "_").map { $0.prefix(1).uppercased() + $0.dropFirst() }
                .joined(separator: " ")
        }
    }

    private static func camel(_ snake: String) -> String {
        let parts = snake.split(separator: "_")
        return String(parts.first ?? "") + parts.dropFirst().map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
    }
}

// MARK: - OpenAI-compatible metered APIs

extension OpenAIAdapter {
    public func usage(_ ctx: ProviderContext) async throws -> ProviderUsage? {
        switch quirks(ctx).usageStyle {
        case .unreported:
            return nil
        case .openRouterKey:
            let auth = try await authenticate(ctx)
            let h = headers(ctx, auth: auth)
            let key = try await fetchUsageDocument(ctx, url: url(ctx, path: "key", auth: auth), headers: h)
            // The account's balance is a separate document, and not every key
            // may read it; the key's own limit stands without it.
            let credits = try? await fetchUsageDocument(ctx, url: url(ctx, path: "credits", auth: auth), headers: h)
            return Self.parseOpenRouter(key: key, credits: credits)
        case .deepSeekBalance:
            let auth = try await authenticate(ctx)
            let json = try await fetchUsageDocument(
                ctx, url: hostURL(auth.baseURLOverride ?? ctx.account.baseURL, path: "user/balance"),
                headers: headers(ctx, auth: auth))
            return Self.parseDeepSeek(json)
        }
    }

    static func parseOpenRouter(key: JSONValue, credits: JSONValue?, now: Date = Date()) -> ProviderUsage {
        let d = key["data"] ?? key
        var windows: [ProviderUsage.Window] = []
        if let limit = d["limit"]?.doubleValue, limit > 0 {
            let remaining = d["limit_remaining"]?.doubleValue ?? max(0, limit - (d["usage"]?.doubleValue ?? 0))
            let used = max(0, limit - remaining)
            let label: String
            switch d["limit_reset"]?.stringValue {
            case "daily": label = "Daily key limit"
            case "weekly": label = "Weekly key limit"
            case "monthly": label = "Monthly key limit"
            default: label = "Key limit"
            }
            windows.append(.init(id: "openrouter.key", label: label, usedFraction: used / limit,
                                 used: used, limit: limit, unit: .usd))
        }
        var amounts: [ProviderUsage.Amount] = []
        if let c = credits?["data"], let total = c["total_credits"]?.doubleValue,
           let spent = c["total_usage"]?.doubleValue {
            amounts.append(.init(label: "Credits left", value: total - spent, unit: .usd))
        }
        for (field, label) in [("usage_daily", "Today"), ("usage_weekly", "This week"), ("usage_monthly", "This month")] {
            if let v = d[field]?.doubleValue { amounts.append(.init(label: label, value: v, unit: .usd)) }
        }
        let broke = amounts.first { $0.label == "Credits left" }.map { $0.value <= 0 } ?? false
        return ProviderUsage(source: .provider,
                             plan: d["is_free_tier"]?.boolValue == true ? "Free tier" : nil,
                             windows: windows, amounts: amounts,
                             providerSaysLimited: broke, observedAt: now)
    }

    static func parseDeepSeek(_ json: JSONValue, now: Date = Date()) -> ProviderUsage {
        let infos = json["balance_infos"]?.arrayValue ?? []
        let amounts = infos.compactMap { info -> ProviderUsage.Amount? in
            guard let total = info["total_balance"]?.doubleValue else { return nil }
            let currency = info["currency"]?.stringValue ?? "USD"
            let label = infos.count > 1 ? "Balance · \(currency)" : "Balance"
            return .init(label: label, value: total,
                         unit: currency == "USD" ? .usd : .currency(currency))
        }
        return ProviderUsage(source: .provider, amounts: amounts,
                             providerSaysLimited: json["is_available"]?.boolValue == false,
                             observedAt: now)
    }
}
