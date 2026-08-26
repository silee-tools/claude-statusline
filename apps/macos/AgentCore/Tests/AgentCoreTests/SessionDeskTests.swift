import Foundation
import Testing
@testable import AgentCore

@Test func collectorReadsValidClaudeSnapshotsAndSkipsMalformedNeighbors() throws {
    try withSessionDeskDirectory(named: "claude-mixed") { root in
        let locations = try makeLocations(in: root)
        try writeSnapshot(
            provider: .claude,
            sessionID: "session-valid",
            activity: .working,
            observedAt: 200,
            to: locations.claudeSessionsURL.appendingPathComponent("valid.json")
        )
        try Data("not-json\n".utf8).write(
            to: locations.claudeSessionsURL.appendingPathComponent("malformed.json")
        )
        try Data(#"{"schemaVersion":2}"#.utf8).write(
            to: locations.claudeSessionsURL.appendingPathComponent("future.json")
        )

        let snapshots = try SessionCollector.collect(locations: locations, now: 200)

        #expect(snapshots.map(\.sessionID) == ["session-valid"])
    }
}

@Test func collectorDoesNotTreatUnreadableSourceAsNoSessions() throws {
    try withSessionDeskDirectory(named: "unreadable-source") { root in
        let locations = try makeLocations(in: root)
        try FileManager.default.removeItem(at: locations.claudeSessionsURL)
        try Data("not-a-directory".utf8).write(to: locations.claudeSessionsURL)

        #expect(throws: CocoaError.self) {
            _ = try SessionCollector.collect(locations: locations, now: 200)
        }
    }
}

@Test func collectorReadsOnlyTheEightMostRecentlyModifiedCodexFiles() throws {
    try withSessionDeskDirectory(named: "codex-recent") { root in
        let locations = try makeLocations(in: root)
        let nested = locations.codexSessionsURL.appendingPathComponent("2026/08/24", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

        for index in 0..<10 {
            let fileURL = nested.appendingPathComponent("session-\(index).jsonl")
            try writeCodexSession(index: index, to: fileURL)
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: Double(index))],
                ofItemAtPath: fileURL.path
            )
        }

        #expect(
            try SessionCollector.recentCodexSessionURLs(in: locations.codexSessionsURL, limit: 8)
                .map(\.lastPathComponent) == (2...9).reversed().map { "session-\($0).jsonl" }
        )
        #expect(try SessionCollector.collect(locations: locations, now: 300).count == 8)
    }
}

@Test func collectorAppliesStuckOverlayAndSortsProviderPriorityAndSession() throws {
    try withSessionDeskDirectory(named: "overlay-sort") { root in
        let locations = try makeLocations(in: root)
        try writeSnapshot(
            provider: .claude,
            sessionID: "session-idle",
            activity: .idle,
            observedAt: 100,
            to: locations.claudeSessionsURL.appendingPathComponent("idle.json")
        )
        try writeSnapshot(
            provider: .claude,
            sessionID: "session-active",
            activity: .idle,
            observedAt: 100,
            to: locations.claudeSessionsURL.appendingPathComponent("active.json")
        )
        try writeCodexSession(index: 1, to: locations.codexSessionsURL.appendingPathComponent("codex.jsonl"))
        try writeActiveStuckState(to: locations.stuckStateURL)

        let snapshots = try SessionCollector.collect(locations: locations, now: 120)

        #expect(snapshots.map(\.sessionID) == ["session-active", "session-idle", "codex-1"])
        #expect(snapshots[0].activity == .resuming)
        #expect(snapshots[0].resumeProgress?.cause == .rateLimit)
    }
}

@Test func defaultLocationsUseNonemptyXDGStateHomeAndHomeCodexRoot() {
    let home = URL(fileURLWithPath: "/tmp/example-home", isDirectory: true)

    let xdg = SessionLocations.defaults(
        homeURL: home,
        environment: ["XDG_STATE_HOME": "/tmp/example-state"]
    )
    #expect(xdg.claudeSessionsURL.path == "/tmp/example-state/claude-statusline/agent-status/sessions/claude")
    #expect(xdg.stuckStateURL.path == "/tmp/example-state/stuck-resume/v2")
    #expect(xdg.codexSessionsURL.path == "/tmp/example-home/.codex/sessions")

    let fallback = SessionLocations.defaults(homeURL: home, environment: ["XDG_STATE_HOME": ""])
    #expect(fallback.claudeSessionsURL.path == "/tmp/example-home/.local/state/claude-statusline/agent-status/sessions/claude")
}

@Test func sharedSnapshotStoreWritesLiteralArrayWithPrivatePermissionsAndDegradesCorruption() throws {
    try withSessionDeskDirectory(named: "shared-store") { root in
        let fileURL = root.appendingPathComponent("group/snapshots.json")
        let store = SharedSnapshotStore(fileURL: fileURL)
        let snapshots = [
            try SessionSnapshot(
                provider: .codex,
                sessionID: "session-shared",
                workspace: "/tmp/example-project",
                activity: .waitingInput,
                usageWindows: [],
                observedAt: 400
            ),
        ]

        try store.write(snapshots)

        #expect(try store.read() == snapshots)
        let data = try Data(contentsOf: fileURL)
        let array = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        #expect(array.first?["schemaVersion"] as? Int == 1)
        #expect(array.first?["provider"] as? String == "codex")
        #expect(array.first?["activity"] as? String == "waitingInput")
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let permissions = try #require(attributes[.posixPermissions] as? NSNumber).intValue
        #expect(permissions & 0o777 == 0o600)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fileURL.deletingLastPathComponent().path) == ["snapshots.json"])

        try Data("broken".utf8).write(to: fileURL)
        #expect(throws: DecodingError.self) {
            _ = try store.read()
        }
    }
}

@Test func agentDisplayMapsEveryStatusAndUsageBoundaries() throws {
    let expected: [(AgentActivity, String)] = [
        (.inactive, "비활성"),
        (.idle, "유휴"),
        (.working, "작업 중"),
        (.waitingInput, "입력 대기"),
        (.waitingApproval, "승인 대기"),
        (.rateLimited, "한도 대기"),
        (.resuming, "재개 중"),
        (.failed, "실패"),
        (.stale, "오래된 상태"),
    ]
    for (activity, label) in expected {
        #expect(AgentDisplay.activityLabel(activity) == label)
    }
    #expect(AgentDisplay.providerLabel(.claude) == "CLAUDE")
    #expect(AgentDisplay.providerLabel(.codex) == "CODEX")
    #expect(AgentDisplay.emptyTitle == "현재 표시할 세션이 없습니다")
    #expect(!AgentDisplay.emptyDetail.isEmpty)
    #expect(AgentDisplay.usageFraction(try UsageWindow(id: "zero", label: "0", usedPercent: 0, resetsAt: 1)) == 1)
    #expect(AgentDisplay.usageFraction(try UsageWindow(id: "full", label: "100", usedPercent: 100, resetsAt: 1)) == 0)
}

@Test func loadAndDisplayStateKeepEveryUserVisibleBranchDistinct() throws {
    let snapshot = try SessionSnapshot(
        provider: .claude,
        sessionID: "session-state",
        workspace: "/tmp/example-project",
        activity: .working,
        usageWindows: [],
        observedAt: 100
    )

    #expect(SessionLoadState.loaded([]) == .empty)
    #expect(SessionLoadState.loaded([snapshot]) == .ready([snapshot]))

    let titles: [(SessionLoadState, String)] = [
        (.loading, "상태를 불러오는 중입니다"),
        (.empty, "현재 표시할 세션이 없습니다"),
        (.unavailable, "상태 데이터가 아직 없습니다"),
        (.failed, "상태를 읽지 못했습니다"),
    ]
    for (state, title) in titles {
        #expect(AgentDisplay.stateTitle(state) == title)
        #expect(!AgentDisplay.stateDetail(state).isEmpty)
    }

    #expect(AgentDisplay.activity(for: snapshot, now: 160, staleAfter: 60) == .stale)

    let window = try UsageWindow(id: "five-hour", label: "5 hour", usedPercent: 42, resetsAt: 200)
    #expect(AgentDisplay.usageLabel(window) == "58% 남음")
    #expect(AgentDisplay.resumeLabel(ResumeProgress(
        cause: .rateLimit,
        attempt: 2,
        maximumAttempts: 5,
        nextAttemptAt: 150,
        deadlineAt: 200
    )) == "재개 2/5")
}

@Test func sharedSnapshotStoreDistinguishesMissingCorruptEmptyAndReady() throws {
    try withSessionDeskDirectory(named: "shared-load-state") { root in
        let fileURL = root.appendingPathComponent("group/snapshots.json")
        let store = SharedSnapshotStore(fileURL: fileURL)
        #expect(store.load() == .unavailable)

        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("broken".utf8).write(to: fileURL)
        #expect(store.load() == .failed)

        try store.write([])
        #expect(store.load() == .empty)

        let snapshot = try SessionSnapshot(
            provider: .codex,
            sessionID: "session-ready",
            workspace: "/tmp/example-project",
            activity: .idle,
            usageWindows: [],
            observedAt: 300
        )
        try store.write([snapshot])
        #expect(store.load() == .ready([snapshot]))
    }
}

private func withSessionDeskDirectory(named name: String, _ body: (URL) throws -> Void) throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("SessionDeskTests-\(name)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try body(directory)
}

private func makeLocations(in root: URL) throws -> SessionLocations {
    let locations = SessionLocations(
        claudeSessionsURL: root.appendingPathComponent("claude", isDirectory: true),
        codexSessionsURL: root.appendingPathComponent("codex", isDirectory: true),
        stuckStateURL: root.appendingPathComponent("stuck", isDirectory: true)
    )
    for directory in [locations.claudeSessionsURL, locations.codexSessionsURL, locations.stuckStateURL] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    return locations
}

private func writeSnapshot(
    provider: AgentProvider,
    sessionID: String,
    activity: AgentActivity,
    observedAt: Int64,
    to fileURL: URL
) throws {
    let snapshot = try SessionSnapshot(
        provider: provider,
        sessionID: sessionID,
        workspace: "/tmp/example-project",
        model: "example-model",
        activity: activity,
        usageWindows: [],
        observedAt: observedAt
    )
    try JSONEncoder().encode(snapshot).write(to: fileURL)
}

private func writeCodexSession(index: Int, to fileURL: URL) throws {
    let minute = String(format: "%02d", index)
    let contents = #"{"timestamp":"2026-08-24T01:\#(minute):00Z","type":"session_meta","payload":{"id":"codex-\#(index)","cwd":"/tmp/example-project"}}"# + "\n"
    try Data(contents.utf8).write(to: fileURL)
}

private func writeActiveStuckState(to stateURL: URL) throws {
    let contents = """
    episode=1
    generation=1
    recovered_generation=0
    delay=30
    last_attempt=110
    attempts=1
    base_delay=30
    max_attempts=5
    active_session=session-active
    active_generation=1
    active_cause=rate_limit
    handoff_at=180
    deadline=300
    """
    try Data(contents.utf8).write(to: stateURL.appendingPathComponent("global"))
}
