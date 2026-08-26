import Foundation
import Testing
@testable import AgentCore

@Test func codexJSONLMapsMetadataActivityAndUsageWithoutTranscriptContent() throws {
    try withTemporaryDirectory(named: "mapping") { directory in
        let file = directory.appendingPathComponent("mapping-session.jsonl")
        try writeJSONL(
            [
                #"{"timestamp":"2026-08-24T01:00:00Z","type":"session_meta","payload":{"id":"session-example","cwd":"/tmp/example-project"}}"#,
                #"{"timestamp":"2026-08-24T01:01:00.500Z","type":"turn_context","payload":{"cwd":"/tmp/example-project-updated","model":"example-model"}}"#,
                #"{"timestamp":"2026-08-24T01:02:00Z","type":"event_msg","payload":{"type":"task_started"}}"#,
                #"{"timestamp":"2026-08-24T01:03:00Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":42.9,"window_minutes":300,"resets_at":1787536800},"secondary":{"used_percent":100,"window_minutes":10080,"resets_at":1788141600}}}}"#,
                #"{"timestamp":"2026-08-24T01:05:00Z","type":"event_msg","payload":{"type":"task_complete"}}"#,
                #"{"timestamp":"2026-08-24T01:06:00Z","type":"response_item","payload":{"type":"task_started","content":"do-not-leak@example.com","arguments":{"prompt":"do-not-leak@example.com"}}}"#,
            ],
            to: file
        )

        let snapshot = try #require(try CodexSessionAdapter.snapshot(from: file))

        #expect(snapshot.provider == .codex)
        #expect(snapshot.sessionID == "session-example")
        #expect(snapshot.workspace == "/tmp/example-project-updated")
        #expect(snapshot.model == "example-model")
        #expect(snapshot.activity == .idle)
        #expect(snapshot.observedAt == 1_787_533_500)
        #expect(snapshot.usageWindows == [
            try UsageWindow(
                id: "codex-primary",
                label: "5 hour",
                usedPercent: 42,
                resetsAt: 1_787_536_800,
                windowMinutes: 300
            ),
            try UsageWindow(
                id: "codex-secondary",
                label: "7 day",
                usedPercent: 100,
                resetsAt: 1_788_141_600,
                windowMinutes: 10_080
            ),
        ])

        let encoded = try JSONEncoder().encode(snapshot)
        let output = String(decoding: encoded, as: UTF8.self)
        #expect(snapshot.schemaVersion == 1)
        #expect(!output.contains("do-not-leak@example.com"))
        #expect(!output.contains("task_started"))
    }
}

@Test func codexJSONLUsesLatestTaskEventAndDefaultsToIdle() throws {
    try withTemporaryDirectory(named: "activity") { directory in
        let workingFile = directory.appendingPathComponent("working.jsonl")
        try writeJSONL(
            [
                #"{"timestamp":"2026-08-24T02:00:00Z","type":"session_meta","payload":{"session_id":"session-working","cwd":"/tmp/example-project"}}"#,
                #"{"timestamp":"2026-08-24T02:01:00Z","type":"event_msg","payload":{"type":"task_complete"}}"#,
                #"{"timestamp":"2026-08-24T02:02:00Z","type":"event_msg","payload":{"type":"task_started"}}"#,
            ],
            to: workingFile
        )
        let idleFile = directory.appendingPathComponent("idle.jsonl")
        try writeJSONL(
            [
                #"{"timestamp":"2026-08-24T03:00:00Z","type":"session_meta","payload":{"id":"session-idle","cwd":"/tmp/example-project"}}"#,
            ],
            to: idleFile
        )

        #expect(try CodexSessionAdapter.snapshot(from: workingFile)?.activity == .working)
        #expect(try CodexSessionAdapter.snapshot(from: idleFile)?.activity == .idle)
    }
}

@Test func codexJSONLSkipsMalformedUnknownAndIncompleteLines() throws {
    try withTemporaryDirectory(named: "malformed") { directory in
        let validFile = directory.appendingPathComponent("valid.jsonl")
        let contents = [
            #"{"timestamp":"2026-08-24T04:00:00Z","type":"session_meta","payload":{"id":"session-valid","cwd":"/tmp/example-project"}}"#,
            #"{"timestamp":"2026-08-24T04:01:00Z","type":"future_record","payload":{"type":"task_started"}}"#,
            #"not-json"#,
            #"{"timestamp":"2026-08-24T04:02:00Z","type":"event_msg","payload":{"type":"task_started"}}"#,
            #"{"timestamp":"not-a-timestamp","type":"event_msg","payload":{"type":"task_complete"}}"#,
            #"{"timestamp":"2026-08-24T04:03:00Z","type":"event_msg""#,
        ].joined(separator: "\n")
        try Data(contents.utf8).write(to: validFile)

        let snapshot = try #require(try CodexSessionAdapter.snapshot(from: validFile))
        #expect(snapshot.sessionID == "session-valid")
        #expect(snapshot.activity == .working)
        #expect(snapshot.observedAt == 1_787_544_120)

        let missingMetadata = directory.appendingPathComponent("missing-meta.jsonl")
        try writeJSONL(
            [#"{"timestamp":"2026-08-24T04:04:00Z","type":"event_msg","payload":{"type":"task_started"}}"#],
            to: missingMetadata
        )
        #expect(try CodexSessionAdapter.snapshot(from: missingMetadata) == nil)
    }
}

@Test func codexJSONLDropsInvalidOrIncompleteUsageWindows() throws {
    try withTemporaryDirectory(named: "usage") { directory in
        let file = directory.appendingPathComponent("usage-session.jsonl")
        try writeJSONL(
            [
                #"{"timestamp":"2026-08-24T05:00:00Z","type":"session_meta","payload":{"id":"session-usage","cwd":"/tmp/example-project"}}"#,
                #"{"timestamp":"2026-08-24T05:01:00Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":101,"window_minutes":300,"resets_at":1787536800},"secondary":{"used_percent":50,"resets_at":1788141600}}}}"#,
            ],
            to: file
        )

        #expect(try CodexSessionAdapter.snapshot(from: file)?.usageWindows.isEmpty == true)
    }
}

@Test func codexJSONLKeepsCompleteSecondaryWhenPrimaryIsIncomplete() throws {
    try withTemporaryDirectory(named: "partial-usage") { directory in
        let file = directory.appendingPathComponent("partial-usage-session.jsonl")
        try writeJSONL(
            [
                #"{"timestamp":"2026-08-24T05:10:00Z","type":"session_meta","payload":{"id":"session-partial-usage","cwd":"/tmp/example-project"}}"#,
                #"{"timestamp":"2026-08-24T05:11:00Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"window_minutes":300,"resets_at":1787536800},"secondary":{"used_percent":50,"window_minutes":10080,"resets_at":1788141600}}}}"#,
            ],
            to: file
        )

        #expect(try CodexSessionAdapter.snapshot(from: file)?.usageWindows == [
            try UsageWindow(
                id: "codex-secondary",
                label: "7 day",
                usedPercent: 50,
                resetsAt: 1_788_141_600,
                windowMinutes: 10_080
            ),
        ])
    }
}

@Test func codexSessionsRootReadsOnlyJSONLAndSortsNewestFirst() throws {
    try withTemporaryDirectory(named: "root") { root in
        let nested = root.appendingPathComponent("2026/08/24", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try writeJSONL(
            [#"{"timestamp":"2026-08-24T06:00:00Z","type":"session_meta","payload":{"id":"session-newer","cwd":"/tmp/example-project"}}"#],
            to: nested.appendingPathComponent("newer.jsonl")
        )
        try writeJSONL(
            [#"{"timestamp":"2026-08-24T05:00:00Z","type":"session_meta","payload":{"id":"session-older","cwd":"/tmp/example-project"}}"#],
            to: root.appendingPathComponent("older.jsonl")
        )
        try writeJSONL(
            [#"{"timestamp":"2026-08-24T05:30:00Z","type":"session_meta","payload":{"id":"session-tie-a","cwd":"/tmp/example-project"}}"#],
            to: root.appendingPathComponent("a.jsonl")
        )
        try writeJSONL(
            [#"{"timestamp":"2026-08-24T05:30:00Z","type":"session_meta","payload":{"id":"session-tie-b","cwd":"/tmp/example-project"}}"#],
            to: root.appendingPathComponent("b.jsonl")
        )
        try writeJSONL(
            [#"{"timestamp":"2026-08-24T07:00:00Z","type":"session_meta","payload":{"id":"session-ignored","cwd":"/tmp/example-project"}}"#],
            to: root.appendingPathComponent("ignored.txt")
        )
        try Data("not-json\n".utf8).write(to: root.appendingPathComponent("invalid.jsonl"))

        let snapshots = CodexSessionAdapter.snapshots(in: root)

        #expect(snapshots.map(\.sessionID) == [
            "session-newer", "session-tie-a", "session-tie-b", "session-older",
        ])
    }
}

private func withTemporaryDirectory(named name: String, _ body: (URL) throws -> Void) throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("AgentCoreTests-\(name)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try body(directory)
}

private func writeJSONL(_ lines: [String], to file: URL) throws {
    try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: file)
}
