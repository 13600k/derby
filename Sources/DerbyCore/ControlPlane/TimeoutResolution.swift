import Foundation

/// How long one endpoint takes. A property of the server on the other end — its
/// hardware, its queue, how much of the prompt it must prefill before it can say
/// anything — not of the client's patience. Either field is nil when nobody has
/// said, which is different from saying "the default".
public struct AccountTimeouts: Codable, Sendable, Hashable {
    /// Ceiling for one whole attempt against this endpoint.
    public var requestSeconds: Double?
    /// How long this endpoint may stay silent before a stream counts as stalled.
    public var firstTokenSeconds: Double?

    public init(requestSeconds: Double?, firstTokenSeconds: Double?) {
        self.requestSeconds = requestSeconds
        self.firstTokenSeconds = firstTokenSeconds
    }

    public static let unstated = AccountTimeouts(requestSeconds: nil, firstTokenSeconds: nil)
}

/// The timeouts one planned attempt actually runs under.
///
/// Timeouts arrive from two places that mean different things, so they are
/// combined in exactly one place rather than at each call site:
///
/// * A logical model's `TimeoutConfig` is the **caller's patience** — how long
///   the client waits, and the only thing that sets the overall deadline.
/// * A provider account's `AccountTimeouts` is the **endpoint's requirement** —
///   how long that particular server needs before it produces anything.
///
/// These are not two ceilings on one quantity, so they are not `min`'d. A `min`
/// meant a provider setting could only ever make Derby *stricter*: an account
/// raised to 600 s changed nothing while its logical model still said 120 s, and
/// there was no account-level first-token setting at all, so a local server
/// prefilling a long tool loop was called stalled at the logical model's 120 s
/// however the provider was configured.
///
/// One attempt gets the **longer** of the two, so a provider can say "this
/// endpoint needs longer" and be believed. A provider that says nothing loosens
/// nothing — the logical model decides alone, and can always be the stricter of
/// the pair. What still bounds the client's wait is `overallSeconds`, which the
/// executor applies to every wait: a slow endpoint may take the whole request
/// budget, never more than it.
public struct ResolvedTimeouts: Sendable, Hashable {
    /// Ceiling for one attempt, before the executor clips it by what is left of
    /// the overall deadline.
    public var attemptSeconds: Double
    /// How long silence is tolerated before the first token arrives.
    public var firstTokenSeconds: Double

    public init(attemptSeconds: Double, firstTokenSeconds: Double) {
        self.attemptSeconds = attemptSeconds
        self.firstTokenSeconds = firstTokenSeconds
    }

    /// Pure, so the router stays a function of (request, snapshot, config) and
    /// what a pairing resolves to is testable without running a request.
    public static func resolve(logicalModel: TimeoutConfig,
                               account: AccountTimeouts,
                               targetOverrideSeconds: Double? = nil) -> ResolvedTimeouts {
        // A per-target override states exactly how long *this* target gets in
        // *this* logical model. It is the most specific thing anyone can say, so
        // it replaces the pair rather than joining it.
        // Nothing may plan to outlast the request it belongs to. The executor
        // clips every wait by what is left of the overall deadline anyway; doing
        // it here as well is what keeps a printed plan honest about the budget
        // it will actually run under.
        let ceiling = logicalModel.overallSeconds
        if let exact = targetOverrideSeconds, exact > 0 {
            let attempt = min(exact, ceiling)
            return ResolvedTimeouts(attemptSeconds: attempt,
                                    firstTokenSeconds: min(logicalModel.firstTokenSeconds, attempt))
        }
        let attempt = min(max(logicalModel.perAttemptSeconds, account.requestSeconds ?? 0), ceiling)
        // Waiting for a first token can never usefully outlast the attempt that
        // is waiting for it.
        let firstToken = min(max(logicalModel.firstTokenSeconds, account.firstTokenSeconds ?? 0), attempt)
        return ResolvedTimeouts(attemptSeconds: attempt, firstTokenSeconds: firstToken)
    }

    public var summary: String {
        "attempt \(attemptSeconds.msString), first token \(firstTokenSeconds.msString)"
    }
}
