import Foundation
import Testing
@testable import AgentCore

@Test func stuckResumeOverlayMapsActiveAndQueuedClaudeSnapshots() throws {
    try withStuckResumeState(named: "active-queued") { stateURL in
        try writeGlobal(
            to: stateURL,
            activeSession: "session-active",
            activeGeneration: 2,
            activeCause: "authentication_failed",
            generation: 4,
            recoveredGeneration: 1,
            lastAttempt: 110,
            attempts: 2,
            maximumAttempts: 5,
            handoffAt: 180,
            deadline: 300
        )
        try writeWaiter(
            named: "session-rate-limit",
            to: stateURL,
            session: "session-rate-limit",
            cause: "rate_limit",
            generation: 3,
            dueAt: 150
        )
        try writeWaiter(
            named: "session-overloaded",
            to: stateURL,
            session: "session-overloaded",
            cause: "overloaded",
            generation: 4,
            dueAt: 160
        )

        let codex = try snapshot(provider: .codex, sessionID: "session-rate-limit")
        let overlaid = StuckResumeAdapter.overlay(
            [
                try snapshot(provider: .claude, sessionID: "session-active"),
                try snapshot(provider: .claude, sessionID: "session-rate-limit"),
                try snapshot(provider: .claude, sessionID: "session-overloaded"),
                codex,
            ],
            stateURL: stateURL,
            now: 120
        )

        #expect(overlaid[0].activity == .resuming)
        #expect(overlaid[0].resumeProgress == ResumeProgress(
            cause: .authenticationFailed,
            attempt: 2,
            maximumAttempts: 5,
            nextAttemptAt: 110,
            deadlineAt: 300
        ))
        #expect(overlaid[0].observedAt == 120)
        #expect(overlaid[1].activity == .rateLimited)
        #expect(overlaid[1].resumeProgress == ResumeProgress(
            cause: .rateLimit,
            attempt: 3,
            maximumAttempts: 5,
            nextAttemptAt: 150,
            deadlineAt: 300
        ))
        #expect(overlaid[2].activity == .failed)
        #expect(overlaid[2].resumeProgress?.cause == .overloaded)
        #expect(overlaid[2].resumeProgress?.nextAttemptAt == 160)
        #expect(overlaid[3] == codex)
    }
}

@Test func queuedNonRateLimitCausesMapToFailed() throws {
    try withStuckResumeState(named: "queued-causes") { stateURL in
        try writeGlobal(to: stateURL, generation: 4, maximumAttempts: 0, deadline: 300)
        let causes = [
            ("session-auth", "authentication_failed", ResumeCause.authenticationFailed),
            ("session-server", "server_error", ResumeCause.serverError),
            ("session-overloaded", "overloaded", ResumeCause.overloaded),
            ("session-other", "future_error", ResumeCause.other),
        ]
        for (index, entry) in causes.enumerated() {
            try writeWaiter(
                named: entry.0,
                to: stateURL,
                session: entry.0,
                cause: entry.1,
                generation: index + 1,
                dueAt: Int64(140 + index)
            )
        }

        let overlaid = StuckResumeAdapter.overlay(
            try causes.map { try snapshot(provider: .claude, sessionID: $0.0) },
            stateURL: stateURL,
            now: 120
        )

        for (index, expected) in causes.enumerated() {
            #expect(overlaid[index].activity == .failed)
            #expect(overlaid[index].resumeProgress?.cause == expected.2)
            #expect(overlaid[index].resumeProgress?.attempt == 1)
            #expect(overlaid[index].resumeProgress?.maximumAttempts == nil)
        }
    }
}

@Test func duplicateWaitersUseDueGenerationAndFilenameOrder() throws {
    try withStuckResumeState(named: "duplicate") { stateURL in
        try writeGlobal(to: stateURL, generation: 4, deadline: 300)
        try writeWaiter(named: "session-duplicate.z", to: stateURL, session: "session-duplicate", cause: "rate_limit", generation: 1, dueAt: 150)
        try writeWaiter(named: "session-duplicate.y", to: stateURL, session: "session-duplicate", cause: "authentication_failed", generation: 3, dueAt: 140)
        try writeWaiter(named: "session-duplicate.b", to: stateURL, session: "session-duplicate", cause: "overloaded", generation: 2, dueAt: 140)
        try writeWaiter(named: "session-duplicate.a", to: stateURL, session: "session-duplicate", cause: "server_error", generation: 2, dueAt: 140)

        let overlaid = StuckResumeAdapter.overlay(
            [try snapshot(provider: .claude, sessionID: "session-duplicate")],
            stateURL: stateURL,
            now: 120
        )

        #expect(overlaid[0].resumeProgress?.cause == .serverError)
        #expect(overlaid[0].resumeProgress?.nextAttemptAt == 140)
    }
}

@Test func legacyGlobalWithoutActiveCauseOverlaysQueuedButNotActive() throws {
    let original = try snapshot(provider: .claude, sessionID: "session-example")

    try withStuckResumeState(named: "legacy-queued") { stateURL in
        try writeGlobal(to: stateURL, generation: 1, deadline: 300)
        try removeActiveCause(from: stateURL)
        try writeWaiter(
            named: "session-example",
            to: stateURL,
            session: "session-example",
            cause: "rate_limit",
            generation: 1,
            dueAt: 140
        )

        let overlaid = StuckResumeAdapter.overlay([original], stateURL: stateURL, now: 120)

        #expect(overlaid[0].activity == .rateLimited)
        #expect(overlaid[0].resumeProgress?.cause == .rateLimit)
        #expect(overlaid[0].resumeProgress?.nextAttemptAt == 140)
    }
    try withStuckResumeState(named: "legacy-active") { stateURL in
        try writeGlobal(
            to: stateURL,
            activeSession: "session-example",
            activeGeneration: 1,
            activeCause: "rate_limit",
            generation: 1,
            handoffAt: 180,
            deadline: 300
        )
        try removeActiveCause(from: stateURL)

        #expect(StuckResumeAdapter.overlay([original], stateURL: stateURL, now: 120) == [original])
    }
}

@Test func expiredRecoveredCappedAndMalformedStatePreserveSnapshots() throws {
    let original = try snapshot(provider: .claude, sessionID: "session-example")

    try withStuckResumeState(named: "expired") { stateURL in
        try writeGlobal(to: stateURL, generation: 1, deadline: 120)
        try writeWaiter(named: "session-example", to: stateURL, session: "session-example", cause: "rate_limit", generation: 1, dueAt: 130)
        #expect(StuckResumeAdapter.overlay([original], stateURL: stateURL, now: 120) == [original])
    }
    try withStuckResumeState(named: "recovered") { stateURL in
        try writeGlobal(to: stateURL, generation: 2, recoveredGeneration: 1, deadline: 300)
        try writeWaiter(named: "session-example", to: stateURL, session: "session-example", cause: "rate_limit", generation: 1, dueAt: 130)
        #expect(StuckResumeAdapter.overlay([original], stateURL: stateURL, now: 120) == [original])
    }
    try withStuckResumeState(named: "active-recovered") { stateURL in
        try writeGlobal(
            to: stateURL,
            activeSession: "session-example",
            activeGeneration: 1,
            activeCause: "rate_limit",
            generation: 2,
            recoveredGeneration: 1,
            handoffAt: 180,
            deadline: 300
        )
        #expect(StuckResumeAdapter.overlay([original], stateURL: stateURL, now: 120) == [original])
    }
    try withStuckResumeState(named: "handoff-expired") { stateURL in
        try writeGlobal(
            to: stateURL,
            activeSession: "session-example",
            activeGeneration: 1,
            activeCause: "rate_limit",
            generation: 1,
            handoffAt: 120,
            deadline: 300
        )
        #expect(StuckResumeAdapter.overlay([original], stateURL: stateURL, now: 120) == [original])
    }
    try withStuckResumeState(named: "capped") { stateURL in
        try writeGlobal(to: stateURL, generation: 1, attempts: 2, maximumAttempts: 2, deadline: 300)
        try writeWaiter(named: "session-example", to: stateURL, session: "session-example", cause: "rate_limit", generation: 1, dueAt: 130)
        #expect(StuckResumeAdapter.overlay([original], stateURL: stateURL, now: 120) == [original])
    }
    try withStuckResumeState(named: "episode") { stateURL in
        try writeGlobal(to: stateURL, generation: 1, deadline: 300)
        try writeWaiter(named: "session-example", to: stateURL, session: "session-example", cause: "rate_limit", episode: 6, generation: 1, dueAt: 130)
        #expect(StuckResumeAdapter.overlay([original], stateURL: stateURL, now: 120) == [original])
    }
    try withStuckResumeState(named: "malformed") { stateURL in
        try Data("episode=7\ngeneration=broken\n".utf8).write(to: stateURL.appendingPathComponent("global"))
        #expect(StuckResumeAdapter.overlay([original], stateURL: stateURL, now: 120) == [original])
    }
    try withStuckResumeState(named: "negative") { stateURL in
        try writeGlobal(to: stateURL, generation: 1, attempts: -1, deadline: 300)
        try writeWaiter(named: "session-example", to: stateURL, session: "session-example", cause: "rate_limit", generation: 1, dueAt: 130)
        #expect(StuckResumeAdapter.overlay([original], stateURL: stateURL, now: 120) == [original])
    }
    try withStuckResumeState(named: "negative-due") { stateURL in
        try writeGlobal(to: stateURL, generation: 1, deadline: 300)
        try writeWaiter(named: "session-example", to: stateURL, session: "session-example", cause: "rate_limit", generation: 1, dueAt: -1)
        #expect(StuckResumeAdapter.overlay([original], stateURL: stateURL, now: 120) == [original])
    }
}

private func snapshot(provider: AgentProvider, sessionID: String) throws -> SessionSnapshot {
    try SessionSnapshot(
        provider: provider,
        sessionID: sessionID,
        workspace: "/tmp/example-project",
        model: "example-model",
        activity: .idle,
        usageWindows: [],
        observedAt: 100
    )
}

private func withStuckResumeState(named name: String, _ body: (URL) throws -> Void) throws {
    let stateURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("StuckResumeAdapterTests-\(name)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
        at: stateURL.appendingPathComponent("waiters", isDirectory: true),
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: stateURL) }
    try body(stateURL)
}

private func writeGlobal(
    to stateURL: URL,
    activeSession: String = "-",
    activeGeneration: Int = 0,
    activeCause: String = "-",
    generation: Int,
    recoveredGeneration: Int = 0,
    lastAttempt: Int64 = 100,
    attempts: Int = 0,
    maximumAttempts: Int = 5,
    handoffAt: Int64 = 0,
    deadline: Int64
) throws {
    let contents = """
    episode=7
    generation=\(generation)
    recovered_generation=\(recoveredGeneration)
    delay=30
    last_attempt=\(lastAttempt)
    attempts=\(attempts)
    base_delay=30
    max_attempts=\(maximumAttempts)
    active_session=\(activeSession)
    active_generation=\(activeGeneration)
    active_cause=\(activeCause)
    handoff_at=\(handoffAt)
    deadline=\(deadline)
    """
    try Data(contents.utf8).write(to: stateURL.appendingPathComponent("global"))
}

private func writeWaiter(
    named filename: String,
    to stateURL: URL,
    session: String,
    cause: String,
    episode: Int = 7,
    generation: Int,
    dueAt: Int64
) throws {
    let contents = """
    pid=12345
    token=invocation-example
    session=\(session)
    cause=\(cause)
    episode=\(episode)
    generation=\(generation)
    registered_at=100
    due_at=\(dueAt)
    initial_used=0
    """
    try Data(contents.utf8).write(
        to: stateURL.appendingPathComponent("waiters", isDirectory: true).appendingPathComponent(filename)
    )
}

private func removeActiveCause(from stateURL: URL) throws {
    let globalURL = stateURL.appendingPathComponent("global")
    let contents = try String(contentsOf: globalURL, encoding: .utf8)
    let legacyContents = contents
        .split(whereSeparator: \.isNewline)
        .filter { !$0.hasPrefix("active_cause=") }
        .joined(separator: "\n") + "\n"
    try Data(legacyContents.utf8).write(to: globalURL)
}
