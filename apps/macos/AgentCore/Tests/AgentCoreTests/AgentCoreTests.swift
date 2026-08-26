import Foundation
import Testing
@testable import AgentCore

@Test func versionOneJSONRoundTripPreservesLiteralContract() throws {
    let fixture = Data(
        #"""
        {
          "schemaVersion": 1,
          "provider": "claude",
          "sessionID": "session-123",
          "workspace": "/tmp/example-project",
          "model": "example-model",
          "activity": "resuming",
          "usageWindows": [
            {
              "id": "five-hour",
              "label": "5 hour",
              "usedPercent": 100,
              "resetsAt": 1787230200,
              "windowMinutes": 300
            }
          ],
          "resumeProgress": {
            "cause": "rateLimit",
            "attempt": 2,
            "maximumAttempts": 5,
            "nextAttemptAt": 1787229900,
            "deadlineAt": 1787230200
          },
          "observedAt": 1787229600
        }
        """#.utf8
    )

    let snapshot = try JSONDecoder().decode(SessionSnapshot.self, from: fixture)
    #expect(snapshot.provider == .claude)
    #expect(snapshot.activity == .resuming)
    #expect(snapshot.resumeProgress?.cause == .rateLimit)

    let encoded = try JSONEncoder().encode(snapshot)
    let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    #expect(Set(object.keys) == [
        "schemaVersion", "provider", "sessionID", "workspace", "model",
        "activity", "usageWindows", "resumeProgress", "observedAt",
    ])
    #expect(object["schemaVersion"] as? Int == 1)
    #expect(object["provider"] as? String == "claude")
    #expect(object["activity"] as? String == "resuming")

    let windows = try #require(object["usageWindows"] as? [[String: Any]])
    #expect(Set(try #require(windows.first).keys) == [
        "id", "label", "usedPercent", "resetsAt", "windowMinutes",
    ])
    #expect(try #require(windows.first?["usedPercent"] as? Int) == 100)

    let progress = try #require(object["resumeProgress"] as? [String: Any])
    #expect(Set(progress.keys) == [
        "cause", "attempt", "maximumAttempts", "nextAttemptAt", "deadlineAt",
    ])
    #expect(progress["cause"] as? String == "rateLimit")
    #expect(try JSONDecoder().decode(SessionSnapshot.self, from: encoded) == snapshot)
}

@Test func providerActivityAndResumeCauseExposeStableLiterals() throws {
    let encoder = JSONEncoder()

    #expect(String(decoding: try encoder.encode(AgentProvider.claude), as: UTF8.self) == #""claude""#)
    #expect(String(decoding: try encoder.encode(AgentProvider.codex), as: UTF8.self) == #""codex""#)

    let activities: [(AgentActivity, String)] = [
        (.inactive, "inactive"),
        (.idle, "idle"),
        (.working, "working"),
        (.waitingInput, "waitingInput"),
        (.waitingApproval, "waitingApproval"),
        (.rateLimited, "rateLimited"),
        (.resuming, "resuming"),
        (.failed, "failed"),
        (.stale, "stale"),
    ]
    for (activity, literal) in activities {
        #expect(String(decoding: try encoder.encode(activity), as: UTF8.self) == "\"\(literal)\"")
    }

    let causes: [(ResumeCause, String)] = [
        (.rateLimit, "rateLimit"),
        (.authenticationFailed, "authenticationFailed"),
        (.serverError, "serverError"),
        (.overloaded, "overloaded"),
        (.other, "other"),
    ]
    for (cause, literal) in causes {
        #expect(String(decoding: try encoder.encode(cause), as: UTF8.self) == "\"\(literal)\"")
    }
}

@Test func usagePercentAcceptsBoundariesAndRejectsValuesOutsideThem() throws {
    #expect(try UsageWindow(id: "low", label: "Low", usedPercent: 0, resetsAt: 10).usedPercent == 0)
    #expect(try UsageWindow(id: "high", label: "High", usedPercent: 100, resetsAt: 20).usedPercent == 100)

    for invalidPercent in [-1, 101] {
        let fixture = Data(
            #"{"id":"invalid","label":"Invalid","usedPercent":\#(invalidPercent),"resetsAt":20}"#.utf8
        )
        #expect(throws: AgentContractError.invalidUsedPercent(invalidPercent)) {
            try JSONDecoder().decode(UsageWindow.self, from: fixture)
        }
    }
}

@Test func unsupportedSchemaVersionIsRejected() {
    let fixture = Data(
        #"{"schemaVersion":2,"provider":"codex","sessionID":"session-456","workspace":"/tmp/example-project","activity":"idle","usageWindows":[],"observedAt":100}"#.utf8
    )

    #expect(throws: AgentContractError.unsupportedSchemaVersion(2)) {
        try JSONDecoder().decode(SessionSnapshot.self, from: fixture)
    }
}

@Test func staleOverridesEveryLiveActivityAtTheThreshold() {
    let liveActivities: [AgentActivity] = [
        .failed, .resuming, .rateLimited, .waitingApproval, .waitingInput,
        .working, .idle, .inactive,
    ]

    #expect(
        AgentActivity.resolve(
            liveActivities,
            observedAt: 100,
            now: 160,
            staleAfter: 60
        ) == .stale
    )
}

@Test func liveActivityPriorityIsStable() {
    let lowerByPriority: [(AgentActivity, [AgentActivity])] = [
        (.failed, [.resuming, .rateLimited, .waitingApproval, .waitingInput, .working, .idle, .inactive]),
        (.resuming, [.rateLimited, .waitingApproval, .waitingInput, .working, .idle, .inactive]),
        (.rateLimited, [.waitingApproval, .waitingInput, .working, .idle, .inactive]),
        (.waitingApproval, [.waitingInput, .working, .idle, .inactive]),
        (.waitingInput, [.working, .idle, .inactive]),
        (.working, [.idle, .inactive]),
        (.idle, [.inactive]),
        (.inactive, []),
    ]

    for (expected, lower) in lowerByPriority {
        #expect(
            AgentActivity.resolve(
                lower + [expected],
                observedAt: 100,
                now: 159,
                staleAfter: 60
            ) == expected
        )
    }
    #expect(
        AgentActivity.resolve(
            [.waitingInput, .waitingApproval],
            observedAt: 100,
            now: 159,
            staleAfter: 60
        ) == .waitingApproval
    )
    #expect(
        AgentActivity.resolve(
            [.waitingApproval, .waitingInput],
            observedAt: 100,
            now: 159,
            staleAfter: 60
        ) == .waitingApproval
    )
    #expect(AgentActivity.resolve([], observedAt: 100, now: 159, staleAfter: 60) == .inactive)
}
