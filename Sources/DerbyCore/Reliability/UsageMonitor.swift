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
/// It also keeps each login's short window running (`PlanWarmUp`): a fresh
/// reading that shows the window idle starts it with one tiny request through
/// a member of that login, and the next tick reads the meter again to see that
/// it did. A member whose request fails or leaves the window idle is passed
/// over for the next, so the account that lands in the plan's lane is found
/// without anything here knowing which provider it is.
///
/// Nothing here is on the request path. Routing reads one thing from it —
/// each plan's `PlanAllowance`, handed over in the snapshot — and never waits
/// on a meter.
public actor UsageMonitor {
    /// How often a provider's meter is read.
    public static let pollInterval: Double = 300
    /// How often the loop wakes, which is how stale Derby's own count can get.
    public static let tickInterval: Double = 60
    /// A manual refresh this soon after the last reading reuses it, so a
    /// button pressed repeatedly cannot turn into a burst against a meter.
    public static let minimumRefreshInterval: Double = 30
    static let fetchDeadline: Double = 25
    /// How long a warm-up may take: long enough for a CLI-backed account to
    /// start its process and answer.
    public static let warmDeadline: Double = 60

    public typealias Accounts = @Sendable () async -> [ProviderAccount]
    /// `interactive` is true only for a manual refresh, and is the only case
    /// in which reading a login may prompt.
    public typealias Fetch = @Sendable (_ account: ProviderAccount, _ interactive: Bool) async throws -> ProviderUsage?
    public typealias Tallies = @Sendable (_ since: Date) async -> [UUID: ProviderUsage.Tally]
    /// Sends one warm-up through `account`. Always background work, so it
    /// must not prompt for a login either.
    public typealias Warm = @Sendable (_ account: ProviderAccount) async throws -> PlanWarmUp.Receipt
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

    /// One login's warm-ups.
    private struct WarmState {
        /// When Derby last started the window. Holds off the next warm-up for
        /// one window length, whatever the meter says.
        var warmedAt: Date?
        /// What the dashboard says Derby started; cleared when the window
        /// turned out not to have started.
        var shownSince: Date?
        var duration: Double = ProviderUsage.fiveHours
        var sender: UUID?
        /// Set by a warm-up that answered: the next tick reads the meter
        /// again to see whether the window is running.
        var verifying = false
        /// Members whose warm-up failed or left the window idle. Passed over
        /// until every member has been tried.
        var passedOver: Set<UUID> = []
        var error: String?
        /// The last complaint per member, so a repeated one is logged once.
        var lastErrors: [UUID: String] = [:]
    }

    private typealias Login = (key: String, members: [ProviderAccount])

    private let accounts: Accounts
    private let fetch: Fetch
    private let tallies: Tallies
    private let warm: Warm?
    private let log: Log

    private var readings: [String: Reading] = [:]
    private var statuses: [UUID: ProviderUsageStatus] = [:]
    private var inFlight: Task<Void, Never>?
    private var warming: [String: WarmState] = [:]
    private var warmTasks: [String: Task<Void, Never>] = [:]
    private var warmingSuspended = false

    /// `warm` nil means windows are never started, which keeps a monitor a
    /// test builds from sending anything.
    public init(accounts: @escaping Accounts, fetch: @escaping Fetch, tallies: @escaping Tallies,
                warm: Warm? = nil, log: @escaping Log = { _, _ in }) {
        self.accounts = accounts
        self.fetch = fetch
        self.tallies = tallies
        self.warm = warm
        self.log = log
    }

    /// Stops warm-ups while routing is paused: paused means nothing is sent
    /// to a provider, and a warm-up is something sent.
    public func setWarmingSuspended(_ suspended: Bool) { warmingSuspended = suspended }

    /// Waits for warm-ups already sent to finish. For tests.
    func settleWarmUps() async {
        while let task = warmTasks.values.first { await task.value }
    }

    /// The latest status of every account that has something to show.
    public func snapshot() -> [UUID: ProviderUsageStatus] { statuses }

    /// What routing reads of each account's meter: its short window, from the
    /// last good reading. Derby's own count has none to give.
    public func planAllowances() -> [UUID: PlanAllowance] {
        statuses.compactMapValues { $0.usage.flatMap(PlanAllowance.init(usage:)) }
    }

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
    public static func loginIdentity(_ account: ProviderAccount) -> String {
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
        var groups: [Login] = []
        for account in cloud {
            let key = Self.loginIdentity(account)
            if let i = groups.firstIndex(where: { $0.key == key }) { groups[i].members.append(account) }
            else { groups.append((key, [account])) }
        }
        let liveKeys = Set(groups.map(\.key))
        readings = readings.filter { liveKeys.contains($0.key) }
        warming = warming.filter { liveKeys.contains($0.key) }

        let due = groups.filter { group in
            guard let reading = readings[group.key] else { return true }
            // A warm-up is checked at the next tick, and a window that has
            // just reset is started again within one, not at the next poll.
            if warm != nil, Self.keepsWarm(group.members) {
                if warming[group.key]?.verifying == true { return true }
                if let resets = reading.lastGood.flatMap(PlanWarmUp.sessionWindow)?.resetsAt,
                   resets > reading.attemptedAt, resets <= now { return true }
            }
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

        // Only a reading just taken decides a warm-up: a stale one says
        // nothing about whether the clock is running now.
        for group in groups {
            if case .reported(let usage)? = results[group.key] {
                await considerWarming(group, usage: usage, now: now)
            }
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
            var status: ProviderUsageStatus
            switch reading.outcome {
            case .reported(let usage):
                status = ProviderUsageStatus(usage: usage, attemptedAt: reading.attemptedAt)
            case .unsupported:
                status = ProviderUsageStatus(usage: counted(), attemptedAt: reading.attemptedAt)
            case .failed(let message, _):
                status = ProviderUsageStatus(usage: reading.lastGood ?? counted(), error: message,
                                             attemptedAt: reading.attemptedAt)
            }
            (status.warmedAt, status.warmError) = warmFields(Self.loginIdentity(account), now: now)
            if status.usage == nil && status.error == nil {
                statuses[account.id] = nil
            } else {
                statuses[account.id] = status
            }
        }
    }

    // MARK: - Keeping the window running

    /// A login is kept warm unless one of its accounts says otherwise: they
    /// share one window, so one "off" has to mean off.
    public static func keepsWarm(_ members: [ProviderAccount]) -> Bool {
        !members.contains { $0.keepPlanWindowRunning == false }
    }

    private func warmFields(_ key: String, now: Date) -> (Date?, String?) {
        guard let state = warming[key] else { return (nil, nil) }
        let since = state.shownSince.flatMap { now.timeIntervalSince($0) < state.duration ? $0 : nil }
        return (since, state.error)
    }

    /// Checks the last warm-up against a fresh reading, then starts the
    /// window if it is idle. The request itself runs off the pass, so neither
    /// the poll loop nor a manual refresh waits for a CLI to answer.
    private func considerWarming(_ group: Login, usage: ProviderUsage, now: Date) async {
        guard let warm, warmTasks[group.key] == nil else { return }
        var state = warming[group.key] ?? WarmState()
        var messages: [(LogLevel, String)] = []
        let names = group.members.map(\.name).joined(separator: ", ")
        let window = PlanWarmUp.sessionWindow(usage)
        let label = window?.label ?? "5-hour"
        if let duration = window?.duration { state.duration = duration }
        // Only accounts with a model to ask can send one.
        let eligible = group.members.filter { $0.warmUpModel != nil }

        if state.verifying {
            state.verifying = false
            let idle = window.map { PlanWarmUp.isIdle($0, observedAt: usage.observedAt) } ?? false
            if idle, let sender = state.sender {
                // It answered without starting the window — most likely it
                // landed outside the plan. The next account tries now.
                state.passedOver.insert(sender)
                state.shownSince = nil
                let senderName = group.members.first { $0.id == sender }?.name ?? "one account"
                if let next = eligible.first(where: { !state.passedOver.contains($0.id) }) {
                    state.warmedAt = nil
                    messages.append((.warn, "A request through \(senderName) did not start the \(label) window for \(names); trying \(next.name)."))
                } else {
                    let retry = (state.warmedAt ?? now).addingTimeInterval(state.duration)
                    messages.append((.warn, "Requests through \(names) did not start the \(label) window. Derby tries again after \(retry.formatted(date: .omitted, time: .shortened))."))
                }
            }
        }

        var sender: ProviderAccount?
        if !warmingSuspended, Self.keepsWarm(group.members),
           PlanWarmUp.shouldWarm(usage, lastWarmedAt: state.warmedAt, now: now) {
            var remaining = eligible.filter { !state.passedOver.contains($0.id) }
            if remaining.isEmpty {
                // Every account has had its turn; start the round again.
                state.passedOver = []
                remaining = eligible
            }
            sender = remaining.first
        }
        warming[group.key] = state

        if let sender {
            let memberIDs = Set(group.members.map(\.id))
            warmTasks[group.key] = Task {
                let result: Result<PlanWarmUp.Receipt, Error>
                do {
                    result = .success(try await withAbandoningDeadline(
                        Self.warmDeadline, message: "\(sender.name) did not answer its warm-up in time") {
                        try await warm(sender)
                    })
                } catch {
                    result = .failure(error)
                }
                await self.finishWarm(group.key, sender: sender, memberIDs: memberIDs, names: names,
                                      label: label, result: result, now: now)
            }
        }
        for (level, message) in messages { await log(level, message) }
    }

    private func finishWarm(_ key: String, sender: ProviderAccount, memberIDs: Set<UUID>, names: String,
                            label: String, result: Result<PlanWarmUp.Receipt, Error>, now: Date) async {
        warmTasks[key] = nil
        var state = warming[key] ?? WarmState()
        var message: (LogLevel, String)?
        switch result {
        case .success(let receipt):
            state.warmedAt = now
            state.shownSince = now
            state.sender = sender.id
            state.verifying = true
            state.error = nil
            state.lastErrors[sender.id] = nil
            let through = names == sender.name ? "" : " through \(sender.name)"
            message = (.info, "Started the \(label) window for \(names) with one request to \(receipt.model)\(through) (\(receipt.usage.inputTokens) in / \(receipt.usage.outputTokens) out).")
        case .failure(let error):
            let text = (error as? DerbyError)?.message ?? error.localizedDescription
            // The next reading tries the next account on this login.
            state.passedOver.insert(sender.id)
            state.error = "\(sender.name): \(text)"
            if state.lastErrors[sender.id] != text {
                state.lastErrors[sender.id] = text
                message = (.warn, "Could not start the \(label) window through \(sender.name): \(text)")
            }
        }
        warming[key] = state
        // Shown now rather than at the next pass.
        let (since, error) = warmFields(key, now: now)
        for id in memberIDs where statuses[id] != nil {
            statuses[id]?.warmedAt = since
            statuses[id]?.warmError = error
        }
        if let message { await log(message.0, message.1) }
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
