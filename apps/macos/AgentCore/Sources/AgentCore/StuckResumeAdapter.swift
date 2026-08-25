import Foundation

public enum StuckResumeAdapter {
    public static func overlay(
        _ snapshots: [SessionSnapshot],
        stateURL: URL,
        now: Int64
    ) -> [SessionSnapshot] {
        guard
            let global = GlobalState(fileURL: stateURL.appendingPathComponent("global")),
            global.episode > 0,
            global.generation >= global.recoveredGeneration,
            global.deadline > now,
            global.maximumAttempts == 0 || global.attempts < global.maximumAttempts
        else {
            return snapshots
        }

        let active = ActiveState(global: global, now: now)
        let waiters = queuedWaiters(stateURL: stateURL, global: global)

        return snapshots.map { snapshot in
            guard snapshot.provider == .claude else { return snapshot }

            if let active, active.sessionID == snapshot.sessionID {
                return replacing(
                    snapshot,
                    activity: .resuming,
                    progress: ResumeProgress(
                        cause: active.cause,
                        attempt: global.attempts,
                        maximumAttempts: global.maximumAttempts > 0 ? global.maximumAttempts : nil,
                        nextAttemptAt: global.lastAttempt,
                        deadlineAt: global.deadline
                    ),
                    observedAt: now
                )
            }

            guard let waiter = waiters[snapshot.sessionID] else { return snapshot }
            let (attempt, overflow) = global.attempts.addingReportingOverflow(1)
            guard !overflow else { return snapshot }
            return replacing(
                snapshot,
                activity: waiter.cause == .rateLimit ? .rateLimited : .failed,
                progress: ResumeProgress(
                    cause: waiter.cause,
                    attempt: attempt,
                    maximumAttempts: global.maximumAttempts > 0 ? global.maximumAttempts : nil,
                    nextAttemptAt: waiter.dueAt,
                    deadlineAt: global.deadline
                ),
                observedAt: now
            )
        }
    }

    private static func queuedWaiters(
        stateURL: URL,
        global: GlobalState
    ) -> [String: WaiterState] {
        let waitersURL = stateURL.appendingPathComponent("waiters", isDirectory: true)
        guard let fileURLs = try? FileManager.default.contentsOfDirectory(
            at: waitersURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return [:]
        }

        var selected: [String: WaiterState] = [:]
        for fileURL in fileURLs {
            guard
                let waiter = WaiterState(fileURL: fileURL),
                waiter.episode == global.episode,
                waiter.generation > global.recoveredGeneration,
                waiter.generation <= global.generation
            else {
                continue
            }
            if let current = selected[waiter.sessionID], !waiter.precedes(current) {
                continue
            }
            selected[waiter.sessionID] = waiter
        }
        return selected
    }

    private static func replacing(
        _ snapshot: SessionSnapshot,
        activity: AgentActivity,
        progress: ResumeProgress,
        observedAt: Int64
    ) -> SessionSnapshot {
        (try? SessionSnapshot(
            schemaVersion: snapshot.schemaVersion,
            provider: snapshot.provider,
            sessionID: snapshot.sessionID,
            workspace: snapshot.workspace,
            model: snapshot.model,
            activity: activity,
            usageWindows: snapshot.usageWindows,
            resumeProgress: progress,
            observedAt: observedAt
        )) ?? snapshot
    }
}

private struct GlobalState {
    let episode: Int
    let generation: Int
    let recoveredGeneration: Int
    let lastAttempt: Int64
    let attempts: Int
    let maximumAttempts: Int
    let activeSession: String
    let activeGeneration: Int
    let activeCause: String
    let handoffAt: Int64
    let deadline: Int64

    init?(fileURL: URL) {
        guard let fields = StateFields(fileURL: fileURL) else { return nil }
        let activeCause = fields["active_cause"] ?? "-"
        guard
            let episode = fields.nonnegativeInt("episode"),
            let generation = fields.nonnegativeInt("generation"),
            let recoveredGeneration = fields.nonnegativeInt("recovered_generation"),
            fields.nonnegativeInt("delay") != nil,
            let lastAttempt = fields.nonnegativeInt64("last_attempt"),
            let attempts = fields.nonnegativeInt("attempts"),
            fields.nonnegativeInt("base_delay") != nil,
            let maximumAttempts = fields.nonnegativeInt("max_attempts"),
            let activeSession = fields["active_session"], !activeSession.isEmpty,
            let activeGeneration = fields.nonnegativeInt("active_generation"),
            !activeCause.isEmpty,
            let handoffAt = fields.nonnegativeInt64("handoff_at"),
            let deadline = fields.nonnegativeInt64("deadline")
        else {
            return nil
        }

        self.episode = episode
        self.generation = generation
        self.recoveredGeneration = recoveredGeneration
        self.lastAttempt = lastAttempt
        self.attempts = attempts
        self.maximumAttempts = maximumAttempts
        self.activeSession = activeSession
        self.activeGeneration = activeGeneration
        self.activeCause = activeCause
        self.handoffAt = handoffAt
        self.deadline = deadline
    }
}

private struct ActiveState {
    let sessionID: String
    let cause: ResumeCause

    init?(global: GlobalState, now: Int64) {
        guard
            global.activeSession != "-",
            global.activeGeneration > global.recoveredGeneration,
            global.activeGeneration <= global.generation,
            global.activeCause != "-",
            global.handoffAt > now
        else {
            return nil
        }
        sessionID = global.activeSession
        cause = ResumeCause(stateValue: global.activeCause)
    }
}

private struct WaiterState {
    let filename: String
    let sessionID: String
    let cause: ResumeCause
    let episode: Int
    let generation: Int
    let dueAt: Int64

    init?(fileURL: URL) {
        guard
            let fields = StateFields(fileURL: fileURL),
            let pid = fields.nonnegativeInt("pid"), pid > 0,
            let token = fields["token"], !token.isEmpty,
            let sessionID = fields["session"], !sessionID.isEmpty,
            let cause = fields["cause"], !cause.isEmpty,
            let episode = fields.nonnegativeInt("episode"),
            let generation = fields.nonnegativeInt("generation"),
            fields.nonnegativeInt64("registered_at") != nil,
            let dueAt = fields.nonnegativeInt64("due_at"),
            let initialUsed = fields.nonnegativeInt("initial_used"),
            initialUsed == 0 || initialUsed == 1
        else {
            return nil
        }

        filename = fileURL.lastPathComponent
        self.sessionID = sessionID
        self.cause = ResumeCause(stateValue: cause)
        self.episode = episode
        self.generation = generation
        self.dueAt = dueAt
    }

    func precedes(_ other: WaiterState) -> Bool {
        if dueAt != other.dueAt { return dueAt < other.dueAt }
        if generation != other.generation { return generation < other.generation }
        return filename < other.filename
    }
}

private struct StateFields {
    private let values: [String: String]

    init?(fileURL: URL) {
        guard let contents = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return nil
        }
        var values: [String: String] = [:]
        for line in contents.split(whereSeparator: \.isNewline) {
            guard
                let separator = line.firstIndex(of: "="),
                separator != line.startIndex
            else {
                return nil
            }
            let key = String(line[..<separator])
            guard values[key] == nil else { return nil }
            values[key] = String(line[line.index(after: separator)...])
        }
        guard !values.isEmpty else { return nil }
        self.values = values
    }

    subscript(key: String) -> String? {
        values[key]
    }

    func nonnegativeInt(_ key: String) -> Int? {
        guard let value = values[key], let parsed = Int(value), parsed >= 0 else { return nil }
        return parsed
    }

    func nonnegativeInt64(_ key: String) -> Int64? {
        guard let value = values[key], let parsed = Int64(value), parsed >= 0 else { return nil }
        return parsed
    }
}

private extension ResumeCause {
    init(stateValue: String) {
        switch stateValue {
        case "rate_limit": self = .rateLimit
        case "authentication_failed": self = .authenticationFailed
        case "server_error": self = .serverError
        case "overloaded": self = .overloaded
        default: self = .other
        }
    }
}
