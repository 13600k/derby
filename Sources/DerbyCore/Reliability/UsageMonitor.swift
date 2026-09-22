import Foundation

/// Keeps every cloud account's plan meter current for the dashboard.
///
/// A provider that publishes a meter is read at most every `pollInterval`;
/// one that does not is shown Derby's own count, recomputed every tick from
/// request history. Accounts signed in through the same CLI login spend one
/// allowance, so that login is read once and the answer shared — the Claude
/// Code CLI and the direct-API path on one Claude login show the same meter,
/// and the endpoint behind it answers a burst with 429s.
///
/// A poll is work nobody asked for, so it never opens the Keychain: a login
/// kept there is read from what a request already loaded, and only a manual
/// refresh — something the user did — may raise the system's dialog.
///
/// Nothing here is on the request path, and the router never reads it.
public actor UsageMonitor {
    /// How often a provider's meter is read.
    public static let pollInterval: Double = 300
    /// How often the loop wakes, which is how stale Derby's own count can get.
    public static let tickInterval: Double = 60
    /// A manual refresh this soon after the last reading reuses it, so a
    /// button pressed repeatedly cannot turn into a burst against a meter.
    public static let minimumRefreshInterval: Double = 30
    static let fetchDeadline: Double = 25

    public typealias Accounts = @Sendable () async -> [ProviderAccount]
    /// `interactive` is true only for a manual refresh, and is the only case
    /// in which reading a login may prompt.
    public typealias Fetch = @Sendable (_ account: ProviderAccount, _ interactive: Bool) async throws -> ProviderUsage?
    public typealias Tallies = @Sendable (_ since: Date) async -> [UUID: ProviderUsage.Tally]
    public typealias Log = @Sendable (LogLevel, String) async -> Void

    private enum Outcome: Sendable {
        /// No adapter on this login publishes a meter.
        case unsupported
        case reported(ProviderUsage)
        /// `local` when the provider never answered — no login yet, no
        /// network — which is worth retrying at the next tick, where a
        /// provider's own refusal waits out the full interval.
        case failed(String, local: Bool)
    }

    private struct Reading {
        var attemptedAt: Date
        var outcome: Outcome
        var lastGood: ProviderUsage?
    }

    private let accounts: Accounts
    private let fetch: Fetch
    private let tallies: Tallies
    private let log: Log

    private var readings: [String: Reading] = [:]
    private var statuses: [UUID: ProviderUsageStatus] = [:]
    private var inFlight: Task<Void, Never>?

    public init(accounts: @escaping Accounts, fetch: @escaping Fetch, tallies: @escaping Tallies,
                log: @escaping Log = { _, _ in }) {
        self.accounts = accounts
        self.fetch = fetch
        self.tallies = tallies
        self.log = log
    }

    /// The latest status of every account that has something to show.
    public func snapshot() -> [UUID: ProviderUsageStatus] { statuses }

    /// Reads whatever is due. `force` shortens "due" to `minimumRefreshInterval`.
    /// A call made while a pass is running waits for that pass instead of
    /// starting another.
    public func refresh(force: Bool = false, now: Date = Date()) async {
        if let running = inFlight {
            await running.value
            return
        }
        let task = Task { await self.pass(force: force, now: now) }
        inFlight = task
        await task.value
        inFlight = nil
    }

    /// Accounts reading the same CLI login share one allowance and one
    /// reading. Anything else is its own.
    static func loginIdentity(_ account: ProviderAccount) -> String {
        if case .cli(let source, _) = account.auth {
            return "cli.\(source.rawValue).\(account.credentialHomeURL?.standardizedFileURL.path ?? "")"
        }
        return "account.\(account.id.uuidString)"
    }

    // MARK: - One pass

    private func pass(force: Bool, now: Date) async {
        // Local servers have no plan; what they are doing is `ModelResidency`'s.
        let cloud = await accounts().filter { $0.enabled && !$0.kind.isLocal }
        let live = Set(cloud.map(\.id))
        statuses = statuses.filter { live.contains($0.key) }

        // Group by login, keeping configuration order within each group.
        var groups: [(key: String, members: [ProviderAccount])] = []
        for account in cloud {
            let key = Self.loginIdentity(account)
            if let i = groups.firstIndex(where: { $0.key == key }) { groups[i].members.append(account) }
            else { groups.append((key, [account])) }
        }
        let liveKeys = Set(groups.map(\.key))
        readings = readings.filter { liveKeys.contains($0.key) }

        let due = groups.filter { group in
            guard let reading = readings[group.key] else { return true }
            let interval: Double
            if force { interval = Self.minimumRefreshInterval }
            else if case .failed(_, local: true) = reading.outcome { interval = Self.tickInterval }
            else { interval = Self.pollInterval }
            return now.timeIntervalSince(reading.attemptedAt) >= interval
        }
        let fetch = self.fetch
        let results = await withTaskGroup(of: (String, Outcome).self) { tasks in
            for group in due {
                tasks.addTask {
                    // The first account whose adapter publishes a meter reads
                    // it for the whole login.
                    for account in group.members {
                        do {
                            // Abandoned, not awaited, at the deadline: one
                            // meter stuck behind a dialog must not hold back
                            // every other account's.
                            let usage = try await withAbandoningDeadline(
                                Self.fetchDeadline, message: "\(account.name) did not report its usage in time") {
                                try await fetch(account, force)
                            }
                            if let usage { return (group.key, .reported(usage)) }
                        } catch let error as DerbyError {
                            return (group.key, .failed(error.message, local: error.providerStatus == nil))
                        } catch {
                            return (group.key, .failed(error.localizedDescription, local: true))
                        }
                    }
                    return (group.key, .unsupported)
                }
            }
            var out: [String: Outcome] = [:]
            for await (key, outcome) in tasks { out[key] = outcome }
            return out
        }

        for (key, outcome) in results {
            let previous = readings[key]
            var reading = Reading(attemptedAt: now, outcome: outcome, lastGood: previous?.lastGood)
            if case .reported(let usage) = outcome { reading.lastGood = usage }
            readings[key] = reading
            let names = groups.first { $0.key == key }?.members.map(\.name).joined(separator: ", ") ?? key
            await logTransition(names, from: previous?.outcome, to: outcome)
        }

        // Derby's own count, only for accounts that have nothing better.
        let needsCount = cloud.filter { account in
            switch readings[Self.loginIdentity(account)]?.outcome {
            case .reported?: return false
            case .failed?: return readings[Self.loginIdentity(account)]?.lastGood == nil
            default: return true
            }
        }
        var counts: [UUID: [String: ProviderUsage.Tally]] = [:]
        if !needsCount.isEmpty {
            for spec in ProviderUsage.countedWindows {
                for (id, tally) in await tallies(now.addingTimeInterval(-spec.seconds)) {
                    counts[id, default: [:]][spec.id] = tally
                }
            }
        }

        for account in cloud {
            guard let reading = readings[Self.loginIdentity(account)] else { continue }
            let counted = { ProviderUsage.counted(tallies: counts[account.id] ?? [:],
                                                  limits: account.rateLimits, now: now) }
            let status: ProviderUsageStatus
            switch reading.outcome {
            case .reported(let usage):
                status = ProviderUsageStatus(usage: usage, attemptedAt: reading.attemptedAt)
            case .unsupported:
                status = ProviderUsageStatus(usage: counted(), attemptedAt: reading.attemptedAt)
            case .failed(let message, _):
                status = ProviderUsageStatus(usage: reading.lastGood ?? counted(), error: message,
                                             attemptedAt: reading.attemptedAt)
            }
            if status.usage == nil && status.error == nil {
                statuses[account.id] = nil
            } else {
                statuses[account.id] = status
            }
        }
    }

    /// Says when a meter starts answering, stops, or changes its complaint —
    /// not on every reading, which would bury the log.
    private func logTransition(_ names: String, from old: Outcome?, to new: Outcome) async {
        switch (old, new) {
        case (.reported?, .reported(let usage)):
            await log(.debug, "Usage for \(names): \(usage.summary)")
        case (_, .reported(let usage)):
            await log(.info, "Usage for \(names): \(usage.summary)")
        case (.failed(let before, _)?, .failed(let now, _)) where before == now:
            break
        case (_, .failed(let message, _)):
            await log(.warn, "Could not read usage for \(names): \(message)")
        case (_, .unsupported):
            break
        }
    }
}
