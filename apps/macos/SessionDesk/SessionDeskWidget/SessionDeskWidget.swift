import AgentCore
import Foundation
import SwiftUI
import WidgetKit

private let appGroupID = "group.tools.silee.claude-statusline"

@main
struct SessionDeskWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "SessionDeskWidget", provider: SessionTimelineProvider()) { entry in
            SessionWidgetView(entry: entry)
        }
        .configurationDisplayName("Session Desk")
        .description("Claude와 Codex 세션 상태와 사용량을 표시합니다.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

private struct SessionEntry: TimelineEntry {
    let date: Date
    let state: SessionLoadState
}

private struct SessionTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> SessionEntry {
        SessionEntry(date: Date(), state: .ready(sampleSnapshots))
    }

    func getSnapshot(in context: Context, completion: @escaping (SessionEntry) -> Void) {
        completion(SessionEntry(
            date: Date(),
            state: context.isPreview ? .ready(sampleSnapshots) : loadState()
        ))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SessionEntry>) -> Void) {
        let now = Date()
        completion(Timeline(
            entries: [SessionEntry(date: now, state: loadState())],
            policy: .after(now.addingTimeInterval(5 * 60))
        ))
    }

    private func loadState() -> SessionLoadState {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID
        ) else {
            return .unavailable
        }
        return SharedSnapshotStore(fileURL: container.appendingPathComponent("snapshots.json")).load()
    }

    private var sampleSnapshots: [SessionSnapshot] {
        [
            try? SessionSnapshot(
                provider: .claude,
                sessionID: "claude-example",
                workspace: "/tmp/example-project",
                model: "example-model",
                activity: .working,
                usageWindows: [try UsageWindow(
                    id: "five-hour",
                    label: "5 hour",
                    usedPercent: 42,
                    resetsAt: 1_787_536_800,
                    windowMinutes: 300
                )],
                observedAt: 1_787_533_500
            ),
            try? SessionSnapshot(
                provider: .codex,
                sessionID: "codex-example",
                workspace: "/tmp/example-project",
                model: "example-model",
                activity: .waitingInput,
                usageWindows: [],
                observedAt: 1_787_533_400
            ),
        ].compactMap { $0 }
    }
}

private struct SessionWidgetView: View {
    let entry: SessionEntry
    @Environment(\.widgetFamily) private var family
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            switch family {
            case .systemMedium:
                medium
            default:
                small
            }
        }
        .containerBackground(for: .widget) {
            colorScheme == .dark ? Color.clear : WidgetColors.canvas
        }
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("SESSION DESK")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
            switch entry.state {
            case .ready:
                providerSummary(.claude)
                providerSummary(.codex)
            default:
                Spacer()
                stateMessage(compact: true)
                Spacer()
            }
        }
    }

    private var medium: some View {
        HStack(spacing: 14) {
            ZStack {
                WidgetDiamond(provider: .claude)
                    .offset(x: -13, y: -12)
                WidgetDiamond(provider: .codex)
                    .offset(x: 13, y: 12)
            }
            .frame(width: 82)
            .accessibilityHidden(true)

            Divider()

            switch entry.state {
            case .ready(let snapshots):
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array([AgentProvider.claude, .codex].enumerated()), id: \.offset) { _, provider in
                        if let snapshot = snapshots.first(where: { $0.provider == provider }) {
                            compactRow(snapshot)
                        } else {
                            missingRow(provider)
                        }
                    }
                }
            default:
                stateMessage(compact: false)
            }
            Spacer(minLength: 0)
        }
    }

    private func providerSummary(_ provider: AgentProvider) -> some View {
        let snapshots: [SessionSnapshot]
        if case .ready(let loadedSnapshots) = entry.state {
            snapshots = loadedSnapshots
        } else {
            snapshots = []
        }
        let snapshot = snapshots.first { $0.provider == provider }
        let activity = snapshot.map {
            AgentDisplay.activity(for: $0, now: Int64(entry.date.timeIntervalSince1970))
        } ?? .inactive
        return HStack(spacing: 10) {
            WidgetDiamond(provider: provider)
            VStack(alignment: .leading, spacing: 2) {
                Text(AgentDisplay.providerLabel(provider))
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(WidgetColors.provider(provider))
                Text(AgentDisplay.activityLabel(activity))
                    .font(.caption2)
                if let progress = snapshot?.resumeProgress {
                    Text(AgentDisplay.resumeLabel(progress))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.orange)
                } else if let window = snapshot?.usageWindows.first {
                    HStack(spacing: 3) {
                        Text(AgentDisplay.usageLabel(window))
                        Text(Date(timeIntervalSince1970: TimeInterval(window.resetsAt)), style: .time)
                    }
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
                } else {
                    Text("한도 정보 없음")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private func compactRow(_ snapshot: SessionSnapshot) -> some View {
        let activity = AgentDisplay.activity(
            for: snapshot,
            now: Int64(entry.date.timeIntervalSince1970)
        )
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(AgentDisplay.providerLabel(snapshot.provider))
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(WidgetColors.provider(snapshot.provider))
                Text(AgentDisplay.activityLabel(activity))
                    .font(.caption2)
            }
            if let window = snapshot.usageWindows.first {
                HStack(spacing: 6) {
                    Text(window.label)
                    ProgressView(value: AgentDisplay.usageFraction(window))
                        .tint(WidgetColors.provider(snapshot.provider))
                    Text(AgentDisplay.usageLabel(window)).monospacedDigit()
                    Text(Date(timeIntervalSince1970: TimeInterval(window.resetsAt)), style: .time)
                        .monospacedDigit()
                }
                .font(.system(.caption2, design: .monospaced))
            }
            if let progress = snapshot.resumeProgress {
                Text(AgentDisplay.resumeLabel(progress))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.orange)
            } else {
                Text(URL(fileURLWithPath: snapshot.workspace).lastPathComponent)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(AgentDisplay.providerLabel(snapshot.provider)), "
                + "\(AgentDisplay.activityLabel(activity))"
        )
    }

    private func missingRow(_ provider: AgentProvider) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(AgentDisplay.providerLabel(provider))
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(WidgetColors.provider(provider))
            Text("상태 데이터 없음")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func stateMessage(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(AgentDisplay.stateTitle(entry.state))
                .font(compact ? .caption : .system(.body, design: .rounded, weight: .semibold))
            if !compact {
                Text(AgentDisplay.stateDetail(entry.state))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct WidgetDiamond: View {
    let provider: AgentProvider

    var body: some View {
        ZStack {
            Rectangle()
                .fill(WidgetColors.provider(provider).opacity(0.18))
                .overlay(Rectangle().stroke(WidgetColors.provider(provider), lineWidth: 1.5))
                .frame(width: 27, height: 27)
                .rotationEffect(.degrees(45))
            Text(provider == .claude ? "C" : ">_")
                .font(.system(size: provider == .claude ? 13 : 9, weight: .bold, design: .monospaced))
                .foregroundStyle(WidgetColors.provider(provider))
        }
        .frame(width: 42, height: 42)
    }
}

private enum WidgetColors {
    static let claude = Color(red: 0.894, green: 0.486, blue: 0.380)
    static let codex = Color(red: 0.408, green: 0.455, blue: 0.910)
    static let canvas = Color(red: 0.933, green: 0.953, blue: 0.965)

    static func provider(_ provider: AgentProvider) -> Color {
        provider == .claude ? claude : codex
    }
}
