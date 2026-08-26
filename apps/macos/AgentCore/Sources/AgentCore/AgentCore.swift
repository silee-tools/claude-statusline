import Foundation

public enum AgentProvider: String, Codable, Equatable, Sendable {
    case claude
    case codex
}

public enum AgentActivity: String, Codable, Equatable, Sendable {
    case inactive
    case idle
    case working
    case waitingInput
    case waitingApproval
    case rateLimited
    case resuming
    case failed
    case stale

    public static func resolve(
        _ activities: [AgentActivity],
        observedAt: Int64,
        now: Int64,
        staleAfter: Int64
    ) -> AgentActivity {
        precondition(staleAfter >= 0, "staleAfter must not be negative")

        if now >= observedAt {
            let (age, overflow) = now.subtractingReportingOverflow(observedAt)
            if overflow || age >= staleAfter {
                return .stale
            }
        }

        var resolved = AgentActivity.inactive
        for activity in activities where activity.priority > resolved.priority {
            resolved = activity
        }
        return resolved
    }

    var priority: Int {
        switch self {
        case .inactive: 0
        case .idle: 1
        case .working: 2
        case .waitingInput: 3
        case .waitingApproval: 4
        case .rateLimited: 5
        case .resuming: 6
        case .failed: 7
        case .stale: 8
        }
    }
}

public enum ResumeCause: String, Codable, Equatable, Sendable {
    case rateLimit
    case authenticationFailed
    case serverError
    case overloaded
    case other
}

public enum AgentContractError: Error, Equatable, Sendable {
    case unsupportedSchemaVersion(Int)
    case invalidUsedPercent(Int)
}

public struct UsageWindow: Codable, Equatable, Sendable {
    public let id: String
    public let label: String
    public let usedPercent: Int
    public let resetsAt: Int64
    public let windowMinutes: Int?

    public init(
        id: String,
        label: String,
        usedPercent: Int,
        resetsAt: Int64,
        windowMinutes: Int? = nil
    ) throws {
        guard 0...100 ~= usedPercent else {
            throw AgentContractError.invalidUsedPercent(usedPercent)
        }
        self.id = id
        self.label = label
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.windowMinutes = windowMinutes
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: values.decode(String.self, forKey: .id),
            label: values.decode(String.self, forKey: .label),
            usedPercent: values.decode(Int.self, forKey: .usedPercent),
            resetsAt: values.decode(Int64.self, forKey: .resetsAt),
            windowMinutes: values.decodeIfPresent(Int.self, forKey: .windowMinutes)
        )
    }
}

public struct ResumeProgress: Codable, Equatable, Sendable {
    public let cause: ResumeCause
    public let attempt: Int
    public let maximumAttempts: Int?
    public let nextAttemptAt: Int64
    public let deadlineAt: Int64

    public init(
        cause: ResumeCause,
        attempt: Int,
        maximumAttempts: Int? = nil,
        nextAttemptAt: Int64,
        deadlineAt: Int64
    ) {
        self.cause = cause
        self.attempt = attempt
        self.maximumAttempts = maximumAttempts
        self.nextAttemptAt = nextAttemptAt
        self.deadlineAt = deadlineAt
    }
}

public struct SessionSnapshot: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let provider: AgentProvider
    public let sessionID: String
    public let workspace: String
    public let model: String?
    public let activity: AgentActivity
    public let usageWindows: [UsageWindow]
    public let resumeProgress: ResumeProgress?
    public let observedAt: Int64

    public init(
        schemaVersion: Int = currentSchemaVersion,
        provider: AgentProvider,
        sessionID: String,
        workspace: String,
        model: String? = nil,
        activity: AgentActivity,
        usageWindows: [UsageWindow],
        resumeProgress: ResumeProgress? = nil,
        observedAt: Int64
    ) throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw AgentContractError.unsupportedSchemaVersion(schemaVersion)
        }
        self.schemaVersion = schemaVersion
        self.provider = provider
        self.sessionID = sessionID
        self.workspace = workspace
        self.model = model
        self.activity = activity
        self.usageWindows = usageWindows
        self.resumeProgress = resumeProgress
        self.observedAt = observedAt
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            schemaVersion: values.decode(Int.self, forKey: .schemaVersion),
            provider: values.decode(AgentProvider.self, forKey: .provider),
            sessionID: values.decode(String.self, forKey: .sessionID),
            workspace: values.decode(String.self, forKey: .workspace),
            model: values.decodeIfPresent(String.self, forKey: .model),
            activity: values.decode(AgentActivity.self, forKey: .activity),
            usageWindows: values.decode([UsageWindow].self, forKey: .usageWindows),
            resumeProgress: values.decodeIfPresent(ResumeProgress.self, forKey: .resumeProgress),
            observedAt: values.decode(Int64.self, forKey: .observedAt)
        )
    }
}
