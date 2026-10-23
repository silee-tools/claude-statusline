import Foundation

public struct SessionLocations: Sendable {
    public let claudeSessionsURL: URL
    public let codexSessionsURL: URL

    public init(claudeSessionsURL: URL, codexSessionsURL: URL) {
        self.claudeSessionsURL = claudeSessionsURL
        self.codexSessionsURL = codexSessionsURL
    }

    public static func defaults(
        homeURL: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> SessionLocations {
        let stateHome = environment["XDG_STATE_HOME"].flatMap { $0.isEmpty ? nil : $0 }
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? homeURL.appendingPathComponent(".local/state", isDirectory: true)
        return SessionLocations(
            claudeSessionsURL: stateHome
                .appendingPathComponent("claude-statusline/agent-status/sessions/claude", isDirectory: true),
            codexSessionsURL: homeURL.appendingPathComponent(".codex/sessions", isDirectory: true)
        )
    }
}

public enum SessionCollector {
    public static func collect(
        locations: SessionLocations,
        codexLimit: Int = 8
    ) throws -> [SessionSnapshot] {
        let decoder = JSONDecoder()
        let fileManager = FileManager.default
        let claudeFiles = if fileManager.fileExists(atPath: locations.claudeSessionsURL.path) {
            try fileManager.contentsOfDirectory(
                at: locations.claudeSessionsURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        } else {
            [URL]()
        }
        let claude = claudeFiles.compactMap { fileURL -> SessionSnapshot? in
            guard fileURL.pathExtension.lowercased() == "json" else { return nil }
            return try? decoder.decode(SessionSnapshot.self, from: Data(contentsOf: fileURL))
        }

        let codex = try recentCodexSessionURLs(in: locations.codexSessionsURL, limit: codexLimit)
            .compactMap { try? CodexSessionAdapter.snapshot(from: $0) }
            .compactMap { $0 }
        return (claude + codex).sorted(by: precedes)
    }

    public static func recentCodexSessionURLs(in rootURL: URL, limit: Int = 8) throws -> [URL] {
        guard limit > 0 else { return [] }
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: rootURL.path, isDirectory: &isDirectory) else {
            return []
        }
        guard isDirectory.boolValue, fileManager.isReadableFile(atPath: rootURL.path) else {
            throw CocoaError(.fileReadNoPermission)
        }
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw CocoaError(.fileReadNoPermission)
        }

        var files: [(url: URL, modifiedAt: Date)] = []
        for case let fileURL as URL in enumerator where fileURL.pathExtension.lowercased() == "jsonl" {
            guard let values = try? fileURL.resourceValues(forKeys: [
                .contentModificationDateKey, .isRegularFileKey,
            ]), values.isRegularFile == true else {
                continue
            }
            files.append((fileURL, values.contentModificationDate ?? .distantPast))
        }
        return files.sorted {
            if $0.modifiedAt != $1.modifiedAt { return $0.modifiedAt > $1.modifiedAt }
            return $0.url.path < $1.url.path
        }.prefix(limit).map(\.url)
    }

    private static func precedes(_ lhs: SessionSnapshot, _ rhs: SessionSnapshot) -> Bool {
        let lhsProvider = lhs.provider == .claude ? 0 : 1
        let rhsProvider = rhs.provider == .claude ? 0 : 1
        if lhsProvider != rhsProvider { return lhsProvider < rhsProvider }
        if lhs.activity.priority != rhs.activity.priority {
            return lhs.activity.priority > rhs.activity.priority
        }
        if lhs.observedAt != rhs.observedAt { return lhs.observedAt > rhs.observedAt }
        return lhs.sessionID < rhs.sessionID
    }
}

public struct SharedSnapshotStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func write(_ snapshots: [SessionSnapshot]) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(snapshots).write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
    }

    /// 배열이 아니거나 항목이 있는데 하나도 디코드하지 못하면 던지고, 일부만 못 읽으면(앱이 이전 판본에서 쓴 폐기된 값 포함) 그 항목만 버린다.
    public func read() throws -> [SessionSnapshot] {
        let entries = try JSONDecoder().decode([Entry].self, from: Data(contentsOf: fileURL))
        let snapshots = entries.compactMap(\.snapshot)
        if snapshots.isEmpty, !entries.isEmpty {
            throw DecodingError.dataCorrupted(
                .init(codingPath: [], debugDescription: "No snapshot entry could be decoded")
            )
        }
        return snapshots
    }

    private struct Entry: Decodable {
        let snapshot: SessionSnapshot?

        init(from decoder: Decoder) {
            snapshot = try? SessionSnapshot(from: decoder)
        }
    }

    public func load() -> SessionLoadState {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return .unavailable
        }
        do {
            return .loaded(try read())
        } catch {
            return .failed
        }
    }
}

public enum SessionLoadState: Equatable, Sendable {
    case loading
    case empty
    case unavailable
    case failed
    case ready([SessionSnapshot])

    public static func loaded(_ snapshots: [SessionSnapshot]) -> SessionLoadState {
        snapshots.isEmpty ? .empty : .ready(snapshots)
    }
}

public enum AgentDisplay {
    public static let emptyTitle = "현재 표시할 세션이 없습니다"
    public static let emptyDetail = "Claude 상태 파일이나 Codex 세션이 생기면 여기에 표시합니다."

    public static func providerLabel(_ provider: AgentProvider) -> String {
        switch provider {
        case .claude: "CLAUDE"
        case .codex: "CODEX"
        }
    }

    public static func activityLabel(_ activity: AgentActivity) -> String {
        switch activity {
        case .inactive: "비활성"
        case .idle: "유휴"
        case .working: "작업 중"
        case .waitingInput: "입력 대기"
        case .waitingApproval: "승인 대기"
        case .rateLimited: "한도 대기"
        case .failed: "실패"
        case .stale: "오래된 상태"
        }
    }

    public static func usageFraction(_ window: UsageWindow) -> Double {
        Double(100 - window.usedPercent) / 100
    }

    public static func stateTitle(_ state: SessionLoadState) -> String {
        switch state {
        case .loading: "상태를 불러오는 중입니다"
        case .empty: emptyTitle
        case .unavailable: "상태 데이터가 아직 없습니다"
        case .failed: "상태를 읽지 못했습니다"
        case .ready: "세션 상태"
        }
    }

    public static func stateDetail(_ state: SessionLoadState) -> String {
        switch state {
        case .loading: "Claude와 Codex 상태를 확인하고 있습니다."
        case .empty: emptyDetail
        case .unavailable: "메뉴바 앱을 실행하거나 파일 접근 권한을 확인해 주세요."
        case .failed: "새로고침해도 계속되면 상태 파일을 확인해 주세요."
        case .ready(let snapshots): "\(snapshots.count)개 세션"
        }
    }

    public static func activity(
        for snapshot: SessionSnapshot,
        now: Int64,
        staleAfter: Int64 = 15 * 60
    ) -> AgentActivity {
        AgentActivity.resolve(
            [snapshot.activity],
            observedAt: snapshot.observedAt,
            now: now,
            staleAfter: staleAfter
        )
    }

    public static func usageLabel(_ window: UsageWindow) -> String {
        "\(100 - window.usedPercent)% 남음"
    }
}
