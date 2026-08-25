import Foundation

public enum CodexSessionAdapter {
    public static func snapshot(from fileURL: URL) throws -> SessionSnapshot? {
        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        let timestampParser = TimestampParser()
        var sessionID: String?
        var workspace: String?
        var model: String?
        var activity = AgentActivity.idle
        var usageWindows: [UsageWindow] = []
        var observedAt: Int64?

        // ponytail: one full-file scan is enough; add a tail index only after profiling shows a bottleneck.
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            guard let record = try? decoder.decode(Record.self, from: line),
                  let timestamp = timestampParser.epochSeconds(from: record.timestamp)
            else {
                continue
            }

            switch record.type {
            case .sessionMeta:
                if let identifier = record.payload?.sessionID ?? record.payload?.id {
                    sessionID = identifier
                }
                if let cwd = record.payload?.cwd {
                    workspace = cwd
                }
            case .turnContext:
                if let cwd = record.payload?.cwd {
                    workspace = cwd
                }
                if let latestModel = record.payload?.model {
                    model = latestModel
                }
            case .eventMessage:
                switch record.payload?.eventType {
                case .taskStarted:
                    activity = .working
                case .taskComplete:
                    activity = .idle
                case .tokenCount:
                    usageWindows = record.payload?.rateLimits?.usageWindows ?? []
                case nil:
                    continue
                }
            }

            observedAt = timestamp
        }

        guard let sessionID, let workspace, let observedAt else {
            return nil
        }
        return try SessionSnapshot(
            provider: .codex,
            sessionID: sessionID,
            workspace: workspace,
            model: model,
            activity: activity,
            usageWindows: usageWindows,
            observedAt: observedAt
        )
    }

    public static func snapshots(in sessionsRootURL: URL) -> [SessionSnapshot] {
        guard let enumerator = FileManager.default.enumerator(
            at: sessionsRootURL,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }

        var snapshots: [(url: URL, snapshot: SessionSnapshot)] = []
        for case let fileURL as URL in enumerator where fileURL.pathExtension.lowercased() == "jsonl" {
            if let snapshot = try? snapshot(from: fileURL) {
                snapshots.append((fileURL, snapshot))
            }
        }

        return snapshots.sorted {
            if $0.snapshot.observedAt != $1.snapshot.observedAt {
                return $0.snapshot.observedAt > $1.snapshot.observedAt
            }
            return $0.url.path < $1.url.path
        }.map(\.snapshot)
    }
}

private struct Record: Decodable {
    let timestamp: String
    let type: RecordType
    let payload: Payload?
}

private enum RecordType: String, Decodable {
    case sessionMeta = "session_meta"
    case turnContext = "turn_context"
    case eventMessage = "event_msg"
}

private struct Payload: Decodable {
    let sessionID: String?
    let id: String?
    let cwd: String?
    let model: String?
    let eventType: EventType?
    let rateLimits: RateLimits?

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case id
        case cwd
        case model
        case eventType = "type"
        case rateLimits = "rate_limits"
    }
}

private enum EventType: String, Decodable {
    case taskStarted = "task_started"
    case taskComplete = "task_complete"
    case tokenCount = "token_count"
}

private struct RateLimits: Decodable {
    let primary: RateLimitWindow?
    let secondary: RateLimitWindow?

    var usageWindows: [UsageWindow] {
        [
            primary?.usageWindow(id: "codex-primary", fallbackLabel: "Primary"),
            secondary?.usageWindow(id: "codex-secondary", fallbackLabel: "Secondary"),
        ].compactMap { $0 }
    }
}

private struct RateLimitWindow: Decodable {
    let usedPercent: Double?
    let windowMinutes: Int?
    let resetsAt: Double?

    enum CodingKeys: String, CodingKey {
        case usedPercent = "used_percent"
        case windowMinutes = "window_minutes"
        case resetsAt = "resets_at"
    }

    func usageWindow(id: String, fallbackLabel: String) -> UsageWindow? {
        guard let usedPercent,
              usedPercent.isFinite,
              0...100 ~= usedPercent,
              let windowMinutes,
              let resetsAt,
              resetsAt.isFinite,
              resetsAt >= Double(Int64.min),
              resetsAt <= Double(Int64.max)
        else {
            return nil
        }

        let label = switch windowMinutes {
        case 300: "5 hour"
        case 10_080: "7 day"
        default: fallbackLabel
        }
        return try? UsageWindow(
            id: id,
            label: label,
            usedPercent: Int(usedPercent),
            resetsAt: Int64(resetsAt),
            windowMinutes: windowMinutes
        )
    }
}

private struct TimestampParser {
    private let fractional: ISO8601DateFormatter
    private let wholeSeconds: ISO8601DateFormatter

    init() {
        fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        wholeSeconds = ISO8601DateFormatter()
        wholeSeconds.formatOptions = [.withInternetDateTime]
    }

    func epochSeconds(from value: String) -> Int64? {
        guard let date = fractional.date(from: value) ?? wholeSeconds.date(from: value) else {
            return nil
        }
        return Int64(date.timeIntervalSince1970)
    }
}
