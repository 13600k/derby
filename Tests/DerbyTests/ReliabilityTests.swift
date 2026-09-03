import Foundation
@testable import DerbyCore

func registerReliabilityTests() {
    let key = TargetKey(providerID: UUID(), modelID: "m")
    let account = UUID()

    func outcome(_ success: Bool, kind: FailureKind? = nil, seconds: Double = 0.1,
                 ttft: Double? = nil, status: Int? = nil, key: TargetKey) -> AttemptOutcome {
        AttemptOutcome(key: key, success: success, failure: kind, totalSeconds: seconds,
                       timeToFirstTokenSeconds: ttft, httpStatus: status)
    }

    suite("Reliability / health statistics") {
        test("rolling success rate and percentiles are computed") {
            let r = HealthRegistry(settings: HealthSettings(windowSize: 10, failureThreshold: 99, errorRateThreshold: 2.0, minimumSamples: 99))
            for s in [0.1, 0.2, 0.3, 0.4, 0.9] {
                await r.record(outcome(true, seconds: s, ttft: s / 2, key: key))
            }
            await r.record(outcome(false, kind: .transient, seconds: 1.0, status: 500, key: key))
            let h = await r.health(for: key)
            try expectEqual(h.successes, 5)
            try expectEqual(h.failures, 1)
            try expectClose(h.successRate, 5.0 / 6.0, tolerance: 0.001)
            try expectClose(try expectNotNil(h.p50Seconds), 0.3, tolerance: 0.001)
            try expect(try expectNotNil(h.p95Seconds) > 0.4)
            try expect(h.ttftP50Seconds != nil)
            try expectClose(h.rate5xx, 1.0 / 6.0, tolerance: 0.001)
        }

        test("the window discards old samples") {
            let r = HealthRegistry(settings: HealthSettings(windowSize: 5, failureThreshold: 99, errorRateThreshold: 2.0, minimumSamples: 99))
            for _ in 0..<5 { await r.record(outcome(false, kind: .transient, key: key)) }
            for _ in 0..<5 { await r.record(outcome(true, key: key)) }
            let h = await r.health(for: key)
            try expectEqual(h.totalSamples, 5)
            try expectEqual(h.failures, 0, "older failures should have rolled out of the window")
        }

        test("errors that are the client's fault do not count against health") {
            let r = HealthRegistry(settings: HealthSettings(windowSize: 10, failureThreshold: 2, minimumSamples: 2))
            await r.record(outcome(false, kind: .invalidRequest, key: key))
            await r.record(outcome(false, kind: .invalidRequest, key: key))
            await r.record(outcome(false, kind: .clientCancelled, key: key))
            let h = await r.health(for: key)
            try expectEqual(h.circuit, .closed, "a bad client request must not trip a provider's circuit")
            try expectEqual(h.failures, 0)
        }

        test("state transitions healthy → degraded → unhealthy with the error rate") {
            let settings = HealthSettings(windowSize: 20, failureThreshold: 99, errorRateThreshold: 0.5,
                                          minimumSamples: 4, degradedErrorRate: 0.2)
            let r = HealthRegistry(settings: settings)
            for _ in 0..<10 { await r.record(outcome(true, key: key)) }
            try expectEqual(await r.health(for: key).state, .healthy)
            for _ in 0..<3 { await r.record(outcome(false, kind: .transient, key: key)) }
            try expectEqual(await r.health(for: key).state, .degraded)
            for _ in 0..<10 { await r.record(outcome(false, kind: .transient, key: key)) }
            try expectEqual(await r.health(for: key).state, .unhealthy)
        }
    }

    suite("Reliability / circuit breaker") {
        test("consecutive failures open the circuit and block admission") {
            let r = HealthRegistry(settings: HealthSettings(failureThreshold: 3, errorRateThreshold: 2.0,
                                                            minimumSamples: 99, openDurationSeconds: 60))
            for _ in 0..<2 { await r.record(outcome(false, kind: .providerDown, key: key)) }
            try expectEqual(await r.health(for: key).circuit, .closed)
            await r.record(outcome(false, kind: .providerDown, key: key))
            try expectEqual(await r.health(for: key).circuit, .open)

            let admission = await r.admit(key, accountID: account, limits: .default,
                                          respectCircuit: true, respectQuota: true)
            guard case .circuitOpen = admission else {
                throw TestFailure(message: "expected admission to be refused, got \(admission)",
                                  file: #fileID, line: #line)
            }
        }

        test("a high error rate opens the circuit even without a failure streak") {
            let r = HealthRegistry(settings: HealthSettings(windowSize: 10, failureThreshold: 99, errorRateThreshold: 0.5, minimumSamples: 4))
            await r.record(outcome(true, key: key))
            await r.record(outcome(false, kind: .transient, key: key))
            await r.record(outcome(true, key: key))
            await r.record(outcome(false, kind: .transient, key: key))
            await r.record(outcome(false, kind: .transient, key: key))
            try expectEqual(await r.health(for: key).circuit, .open)
        }

        test("the circuit half-opens after cooldown and closes on success") {
            let r = HealthRegistry(settings: HealthSettings(failureThreshold: 1, errorRateThreshold: 2.0,
                                                            minimumSamples: 99, openDurationSeconds: 0.25,
                                                            halfOpenSuccessesToClose: 1))
            await r.record(outcome(false, kind: .providerDown, key: key))
            try expectEqual(await r.health(for: key).circuit, .open)

            try await Task.sleep(nanoseconds: 350_000_000)
            let admission = await r.admit(key, accountID: account, limits: .default,
                                          respectCircuit: true, respectQuota: true)
            try expectEqual(admission, .allowed, "cooldown should permit a probe")
            try expectEqual(await r.health(for: key).circuit, .halfOpen)

            await r.acquire(key, accountID: account)
            await r.record(outcome(true, key: key))
            await r.release(key, accountID: account)
            try expectEqual(await r.health(for: key).circuit, .closed)
        }

        test("a failed probe re-opens the circuit immediately") {
            let r = HealthRegistry(settings: HealthSettings(failureThreshold: 1, errorRateThreshold: 2.0,
                                                            minimumSamples: 99, openDurationSeconds: 0.2,
                                                            halfOpenSuccessesToClose: 2))
            await r.record(outcome(false, kind: .providerDown, key: key))
            try await Task.sleep(nanoseconds: 300_000_000)
            _ = await r.admit(key, accountID: account, limits: .default, respectCircuit: true, respectQuota: true)
            try expectEqual(await r.health(for: key).circuit, .halfOpen)
            await r.record(outcome(false, kind: .providerDown, key: key))
            try expectEqual(await r.health(for: key).circuit, .open)
        }

        test("a circuit can be reset by hand") {
            let r = HealthRegistry(settings: HealthSettings(failureThreshold: 1, errorRateThreshold: 2.0, minimumSamples: 99))
            await r.record(outcome(false, kind: .providerDown, key: key))
            try expectEqual(await r.health(for: key).circuit, .open)
            await r.resetCircuit(key)
            try expectEqual(await r.health(for: key).circuit, .closed)
            try expectEqual(await r.admit(key, accountID: account, limits: .default,
                                          respectCircuit: true, respectQuota: true), .allowed)
        }

        test("only one probe is admitted while half-open") {
            let r = HealthRegistry(settings: HealthSettings(failureThreshold: 1, errorRateThreshold: 2.0,
                                                            minimumSamples: 99, openDurationSeconds: 0.2,
                                                            halfOpenMaxProbes: 1))
            await r.record(outcome(false, kind: .providerDown, key: key))
            try await Task.sleep(nanoseconds: 300_000_000)
            try expectEqual(await r.admit(key, accountID: account, limits: .default,
                                          respectCircuit: true, respectQuota: true), .allowed)
            await r.acquire(key, accountID: account)
            let second = await r.admit(key, accountID: account, limits: .default,
                                       respectCircuit: true, respectQuota: true)
            guard case .circuitOpen = second else {
                throw TestFailure(message: "a second concurrent probe should be refused, got \(second)",
                                  file: #fileID, line: #line)
            }
        }
    }

    suite("Reliability / admission control") {
        test("local requests-per-minute limits are enforced") {
            let r = HealthRegistry()
            let limits = RateLimitConfig(requestsPerMinute: 2, maxConcurrentRequests: 10)
            for _ in 0..<2 { await r.record(outcome(true, key: key)) }
            let admission = await r.admit(key, accountID: account, limits: limits,
                                          respectCircuit: true, respectQuota: true)
            guard case .rateLimited(let why) = admission else {
                throw TestFailure(message: "expected a local rate limit, got \(admission)", file: #fileID, line: #line)
            }
            try expectContains(why, "requests/min")
        }

        test("account concurrency limits are enforced") {
            let r = HealthRegistry()
            await r.update(accountLimits: [account: 1])
            await r.acquire(key, accountID: account)
            let admission = await r.admit(key, accountID: account, limits: .default,
                                          respectCircuit: true, respectQuota: true)
            guard case .atCapacity(let inFlight, let limit) = admission else {
                throw TestFailure(message: "expected capacity refusal, got \(admission)", file: #fileID, line: #line)
            }
            try expectEqual(inFlight, 1)
            try expectEqual(limit, 1)
            await r.release(key, accountID: account)
            try expectEqual(await r.admit(key, accountID: account, limits: .default,
                                          respectCircuit: true, respectQuota: true), .allowed)
        }

        test("a manually disabled target is refused") {
            let r = HealthRegistry()
            await r.setDisabled(key, true)
            try expectEqual(await r.admit(key, accountID: account, limits: .default,
                                          respectCircuit: true, respectQuota: true), .disabled)
            try expectEqual(await r.health(for: key).state, .disabled)
        }

        test("quota checks can be skipped by policy") {
            let r = HealthRegistry()
            let limits = RateLimitConfig(requestsPerMinute: 1, maxConcurrentRequests: 10)
            await r.record(outcome(true, key: key))
            try expectEqual(await r.admit(key, accountID: account, limits: limits,
                                          respectCircuit: true, respectQuota: false), .allowed)
        }
    }

    suite("Reliability / rate limit headers") {
        test("parses OpenAI-style headers") {
            let snap = try expectNotNil(RateLimitSnapshot.parseStandardHeaders([
                "x-ratelimit-limit-requests": "500",
                "x-ratelimit-remaining-requests": "499",
                "x-ratelimit-reset-requests": "6m0s",
                "x-ratelimit-limit-tokens": "30000",
                "x-ratelimit-remaining-tokens": "15000",
            ]))
            try expectEqual(snap.requestsLimit, 500)
            try expectEqual(snap.requestsRemaining, 499)
            try expectClose(try expectNotNil(snap.requestsResetSeconds), 360, tolerance: 0.01)
            try expectClose(snap.pressure, 0.5, tolerance: 0.01)
        }

        test("parses Anthropic-style headers") {
            let snap = try expectNotNil(RateLimitSnapshot.parseStandardHeaders([
                "anthropic-ratelimit-requests-limit": "50",
                "anthropic-ratelimit-requests-remaining": "0",
                "anthropic-ratelimit-requests-reset": "60",
            ]))
            try expectEqual(snap.requestsRemaining, 0)
            try expect(snap.isExhausted)
            try expectEqual(snap.pressure, 1)
        }

        test("duration strings in several shapes") {
            try expectClose(try expectNotNil(RateLimitSnapshot.parseDuration("1.5s")), 1.5, tolerance: 0.001)
            try expectClose(try expectNotNil(RateLimitSnapshot.parseDuration("250ms")), 0.25, tolerance: 0.001)
            try expectClose(try expectNotNil(RateLimitSnapshot.parseDuration("1h30m")), 5400, tolerance: 0.001)
            try expectClose(try expectNotNil(RateLimitSnapshot.parseDuration("42")), 42, tolerance: 0.001)
        }

        test("headers with nothing useful yield no snapshot") {
            try expectNil(RateLimitSnapshot.parseStandardHeaders(["content-type": "application/json"]))
        }

        test("an expired reset window clears exhaustion") {
            let snap = RateLimitSnapshot(requestsLimit: 10, requestsRemaining: 0, requestsResetSeconds: 0.01,
                                         observedAt: Date().addingTimeInterval(-5))
            try expect(!snap.isExhausted, "the limit window has passed, so the target is usable again")
        }
    }

    suite("Reliability / failure taxonomy") {
        test("dispositions follow the taxonomy") {
            try expectEqual(FailureKind.transient.defaultDisposition, .retryThenFailover)
            try expectEqual(FailureKind.rateLimit.defaultDisposition, .failover)
            try expectEqual(FailureKind.invalidRequest.defaultDisposition, .returnToClient)
            try expectEqual(FailureKind.clientCancelled.defaultDisposition, .abort)
            try expectEqual(FailureKind.contextOverflow.defaultDisposition, .failoverToLargerContext)
            try expect(!FailureKind.invalidRequest.defaultDisposition.allowsFailover)
            try expect(FailureKind.timeout.defaultDisposition.allowsRetry)
        }

        test("disabling failover turns failing dispositions into client errors") {
            let config = FailoverConfig(enabled: false, maxAttempts: 4)
            try expectEqual(config.disposition(for: .transient), .returnToClient)
            try expectEqual(config.disposition(for: .clientCancelled), .abort)
        }

        test("client HTTP status mapping is sensible") {
            try expectEqual(DerbyError(kind: .rateLimit, message: "").clientHTTPStatus, 429)
            try expectEqual(DerbyError(kind: .authentication, message: "").clientHTTPStatus, 401)
            try expectEqual(DerbyError(kind: .timeout, message: "").clientHTTPStatus, 504)
            try expectEqual(DerbyError(kind: .modelUnavailable, message: "").clientHTTPStatus, 404)
        }
    }
}
