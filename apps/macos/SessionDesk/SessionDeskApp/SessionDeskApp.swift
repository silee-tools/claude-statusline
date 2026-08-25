import AgentCore
import Foundation
import SwiftUI

@MainActor
@main
struct SessionDeskApp: App {
    @StateObject private var model: SessionDeskModel

    init() {
        let model = SessionDeskModel()
        _model = StateObject(wrappedValue: model)
        model.start()
    }

    var body: some Scene {
        MenuBarExtra("Session Desk", systemImage: "rectangle.3.group") {
            SessionDeskView(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
private final class SessionDeskModel: ObservableObject {
    @Published private(set) var state = SessionLoadState.loading
    @Published private(set) var refreshedAt: Date?

    private let homeURL: URL
    private let sharedFileURL: URL?
    private let clock: @Sendable () -> Date
    private var loop: Task<Void, Never>?
    private var sharedWrite: Task<Void, Never>?

    init(
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        sharedFileURL: URL? = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: "group.tools.silee.claude-statusline")?
            .appendingPathComponent("snapshots.json"),
        clock: @escaping @Sendable () -> Date = Date.init
    ) {
        self.homeURL = homeURL
        self.sharedFileURL = sharedFileURL
        self.clock = clock
    }

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                do {
                    try await Task.sleep(for: .seconds(10))
                } catch {
                    return
                }
            }
        }
    }

    func refreshNow() {
        Task { await refresh() }
    }

    private func refresh() async {
        let observed = clock()
        let locations = SessionLocations.defaults(homeURL: homeURL)
        let snapshots = await Task.detached(priority: .utility) {
            try? SessionCollector.collect(
                locations: locations,
                now: Int64(observed.timeIntervalSince1970)
            )
        }.value
        guard let snapshots else {
            state = .failed
            refreshedAt = observed
            return
        }
        state = .loaded(snapshots)
        refreshedAt = observed
        share(snapshots)
    }

    private func share(_ snapshots: [SessionSnapshot]) {
        guard let sharedFileURL, sharedWrite == nil else { return }
        sharedWrite = Task { [weak self] in
            await Task.detached(priority: .utility) {
                try? SharedSnapshotStore(fileURL: sharedFileURL).write(snapshots)
            }.value
            self?.sharedWrite = nil
        }
    }
}

private struct SessionDeskView: View {
    @ObservedObject var model: SessionDeskModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Session Desk")
                    .font(.system(.headline, design: .rounded, weight: .semibold))
                Spacer()
                Button(action: model.refreshNow) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("지금 새로고침")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)

            Divider()

            switch model.state {
            case .ready(let snapshots):
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(snapshots.enumerated()), id: \.offset) { index, snapshot in
                            SessionRow(snapshot: snapshot, now: model.refreshedAt ?? Date())
                            if index < snapshots.count - 1 {
                                Divider().padding(.leading, 70)
                            }
                        }
                    }
                }
                .frame(height: min(CGFloat(snapshots.count) * 96, 480))
            default:
                stateView
            }

            Divider()
            HStack(spacing: 5) {
                if let refreshedAt = model.refreshedAt {
                    Text(refreshedAt, style: .time)
                    Text("갱신")
                } else {
                    Text("불러오는 중")
                }
                Text("·")
                Text("\(sessionCount) sessions")
                Spacer()
            }
            .font(.system(.caption2, design: .monospaced))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .frame(width: 360)
        .background(colorScheme == .dark ? Color.clear : DeskColors.canvas)
    }

    private var sessionCount: Int {
        if case .ready(let snapshots) = model.state { snapshots.count } else { 0 }
    }

    private var stateView: some View {
        VStack(spacing: 8) {
            HStack(spacing: 4) {
                DiamondDeskTile(provider: .claude)
                DiamondDeskTile(provider: .codex)
            }
            Text(AgentDisplay.stateTitle(model.state))
                .font(.system(.body, design: .rounded, weight: .semibold))
            Text(AgentDisplay.stateDetail(model.state))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 28)
        .accessibilityElement(children: .combine)
    }
}

private struct SessionRow: View {
    let snapshot: SessionSnapshot
    let now: Date

    private var activity: AgentActivity {
        AgentDisplay.activity(for: snapshot, now: Int64(now.timeIntervalSince1970))
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            DiamondDeskTile(provider: snapshot.provider)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Text(AgentDisplay.providerLabel(snapshot.provider))
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(DeskColors.provider(snapshot.provider))
                    Circle()
                        .fill(DeskColors.status(activity))
                        .frame(width: 6, height: 6)
                        .accessibilityHidden(true)
                    Text(AgentDisplay.activityLabel(activity))
                        .font(.caption)
                }

                Text(metadata)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                ForEach(Array(snapshot.usageWindows.prefix(2)), id: \.id) { window in
                    UsageLine(window: window, accent: DeskColors.provider(snapshot.provider))
                }

                if let progress = snapshot.resumeProgress {
                    Text(resumeText(progress))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(DeskColors.wait)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var metadata: String {
        let workspace = URL(fileURLWithPath: snapshot.workspace).lastPathComponent
        return [workspace.isEmpty ? snapshot.workspace : workspace, snapshot.model]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    private var accessibilityText: String {
        let usage = snapshot.usageWindows
            .map { "\($0.label) \($0.usedPercent)퍼센트 사용" }
            .joined(separator: ", ")
        let resume = snapshot.resumeProgress.map {
            "재개 시도 \($0.attempt), 다음 시도 \($0.nextAttemptAt)"
        } ?? ""
        return [
            AgentDisplay.providerLabel(snapshot.provider),
            AgentDisplay.activityLabel(activity),
            metadata,
            usage,
            resume,
        ].filter { !$0.isEmpty }.joined(separator: ", ")
    }

    private func resumeText(_ progress: ResumeProgress) -> String {
        let time = Date(timeIntervalSince1970: TimeInterval(progress.nextAttemptAt))
            .formatted(date: .omitted, time: .shortened)
        return "\(AgentDisplay.resumeLabel(progress)) · \(time) 재시도"
    }
}

private struct UsageLine: View {
    let window: UsageWindow
    let accent: Color

    var body: some View {
        HStack(spacing: 7) {
            Text(window.label)
                .frame(width: 44, alignment: .leading)
            ProgressView(value: AgentDisplay.usageFraction(window))
                .tint(accent)
            Text(AgentDisplay.usageLabel(window))
                .monospacedDigit()
                .frame(width: 52, alignment: .trailing)
            VStack(alignment: .trailing, spacing: 0) {
                Text(Date(timeIntervalSince1970: TimeInterval(window.resetsAt)), style: .time)
                    .monospacedDigit()
                Text("초기화")
                    .font(.system(size: 8))
            }
        }
        .font(.system(.caption2, design: .monospaced))
    }
}

private struct DiamondDeskTile: View {
    let provider: AgentProvider

    var body: some View {
        ZStack {
            Rectangle()
                .fill(DeskColors.provider(provider).opacity(0.18))
                .overlay(Rectangle().stroke(DeskColors.provider(provider), lineWidth: 1.5))
                .frame(width: 27, height: 27)
                .rotationEffect(.degrees(45))
            Text(provider == .claude ? "C" : ">_")
                .font(.system(size: provider == .claude ? 13 : 9, weight: .bold, design: .monospaced))
                .foregroundStyle(DeskColors.provider(provider))
        }
        .frame(width: 42, height: 42)
        .accessibilityHidden(true)
    }
}

private enum DeskColors {
    static let claude = Color(red: 0.894, green: 0.486, blue: 0.380)
    static let codex = Color(red: 0.408, green: 0.455, blue: 0.910)
    static let canvas = Color(red: 0.933, green: 0.953, blue: 0.965)
    static let live = Color(red: 0.216, green: 0.725, blue: 0.510)
    static let wait = Color(red: 0.851, green: 0.604, blue: 0.196)

    static func provider(_ provider: AgentProvider) -> Color {
        provider == .claude ? claude : codex
    }

    static func status(_ activity: AgentActivity) -> Color {
        switch activity {
        case .working, .resuming: live
        case .waitingInput, .waitingApproval, .rateLimited: wait
        case .failed: .red
        case .stale, .inactive: .secondary
        case .idle: .secondary
        }
    }
}
