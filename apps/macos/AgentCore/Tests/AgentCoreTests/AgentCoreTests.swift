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
          "activity": "rateLimited",
          "usageWindows": [
            {
              "id": "five-hour",
              "label": "5 hour",
              "usedPercent": 100,
              "resetsAt": 1787230200,
              "windowMinutes": 300
            }
          ],
          "observedAt": 1787229600
        }
        """#.utf8
    )

    let snapshot = try JSONDecoder().decode(SessionSnapshot.self, from: fixture)
    #expect(snapshot.provider == .claude)
    #expect(snapshot.activity == .rateLimited)

    let encoded = try JSONEncoder().encode(snapshot)
    let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    #expect(Set(object.keys) == [
        "schemaVersion", "provider", "sessionID", "workspace", "model",
        "activity", "usageWindows", "observedAt",
    ])
    #expect(object["schemaVersion"] as? Int == 1)
    #expect(object["provider"] as? String == "claude")
    #expect(object["activity"] as? String == "rateLimited")

    let windows = try #require(object["usageWindows"] as? [[String: Any]])
    #expect(Set(try #require(windows.first).keys) == [
        "id", "label", "usedPercent", "resetsAt", "windowMinutes",
    ])
    #expect(try #require(windows.first?["usedPercent"] as? Int) == 100)
    #expect(try JSONDecoder().decode(SessionSnapshot.self, from: encoded) == snapshot)
}

@Test func providerAndActivityExposeStableLiterals() throws {
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
        (.failed, "failed"),
        (.stale, "stale"),
    ]
    for (activity, literal) in activities {
        #expect(String(decoding: try encoder.encode(activity), as: UTF8.self) == "\"\(literal)\"")
    }
}

@Test func retiredResumingActivityIsRejectedAndLegacyResumeProgressIsIgnored() throws {
    func document(activity: String, extra: String = "") -> Data {
        Data(
            #"{"schemaVersion":1,"provider":"claude","sessionID":"session-123","workspace":"/tmp/example-project","activity":"\#(activity)","usageWindows":[],\#(extra)"observedAt":100}"#.utf8
        )
    }

    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(SessionSnapshot.self, from: document(activity: "resuming"))
    }

    let legacy = try JSONDecoder().decode(
        SessionSnapshot.self,
        from: document(
            activity: "rateLimited",
            extra: #""resumeProgress":{"cause":"rateLimit","attempt":1,"nextAttemptAt":110,"deadlineAt":200},"#
        )
    )
    #expect(legacy.activity == .rateLimited)
    let object = try #require(
        JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any]
    )
    #expect(object["resumeProgress"] == nil)
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
        .failed, .rateLimited, .waitingApproval, .waitingInput,
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
        (.failed, [.rateLimited, .waitingApproval, .waitingInput, .working, .idle, .inactive]),
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
