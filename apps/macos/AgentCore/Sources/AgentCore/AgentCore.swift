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
        case .failed: 6
        case .stale: 7
        }
    }
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

public struct SessionSnapshot: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let provider: AgentProvider
    public let sessionID: String
    public let workspace: String
    public let model: String?
    public let activity: AgentActivity
    public let usageWindows: [UsageWindow]
    public let observedAt: Int64

    public init(
        schemaVersion: Int = currentSchemaVersion,
        provider: AgentProvider,
        sessionID: String,
        workspace: String,
        model: String? = nil,
        activity: AgentActivity,
        usageWindows: [UsageWindow],
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
            observedAt: values.decode(Int64.self, forKey: .observedAt)
        )
    }
}
