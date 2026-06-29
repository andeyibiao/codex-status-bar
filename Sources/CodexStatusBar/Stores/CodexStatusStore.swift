import Foundation

@MainActor
final class CodexStatusStore: ObservableObject {
    @Published var phase: ExecutionPhase = .disconnected
    @Published var activity = "Starting Codex app-server"
    @Published var prompt = "Summarize this workspace."
    @Published var workingDirectory = NSHomeDirectory()
    @Published var quota: RateLimitSnapshot?
    @Published var activeItems: [ActiveItemSummary] = []
    @Published var lastAgentMessage = ""
    @Published var isConnected = false

    private let client = CodexAppServerClient()
    private let activityLogMonitor = CodexActivityLogMonitor()
    private var currentThreadID: String?
    private var currentTurnID: String?
    private var didStart = false
    private var quotaRefreshTask: Task<Void, Never>?
    private var activityRefreshTask: Task<Void, Never>?

    var menuTitle: String {
        switch phase {
        case .running: "Codex Running"
        case .waiting: "Codex Waiting"
        case .failed: "Codex Failed"
        case .disconnected, .connecting: "Codex"
        default: "Codex \(phase.title)"
        }
    }

    var menuSystemImage: String {
        phase.systemImage
    }

    var statusBarText: String {
        let fiveHour = StatusFormatters.percentText(quota?.shortWindow?.remainingPercent)
        let fiveHourReset = StatusFormatters.statusBarTimeText(quota?.shortWindow?.resetsAt)
        let weekly = StatusFormatters.percentText(quota?.longWindow?.remainingPercent)
        let weeklyReset = StatusFormatters.statusBarDateTimeText(quota?.longWindow?.resetsAt)
        let resets = quota?.resetCreditsAvailable ?? "--"
        let resetExpiry = StatusFormatters.statusBarDateTimeText(quota?.resetCreditsExpiresAt)
        return "\(taskStatusText) | 5h \(fiveHour)/\(fiveHourReset) | 周 \(weekly)/\(weeklyReset) | 重置 \(resets)/\(resetExpiry)"
    }

    private var taskStatusText: String {
        guard phase == .running, activity != phase.title, !activity.isEmpty else {
            return phase.title
        }
        return "\(phase.title):\(activity)"
    }

    init() {
        client.onNotification = { [weak self] message in
            Task { @MainActor in
                self?.handleNotification(message)
            }
        }
        client.onServerRequest = { [weak self] message in
            Task { @MainActor in
                self?.handleServerRequest(message)
            }
        }

        Task {
            await connect()
        }
        startActivityRefreshLoop()
    }

    deinit {
        quotaRefreshTask?.cancel()
        activityRefreshTask?.cancel()
        client.stop()
    }

    func connect() async {
        guard !didStart else { return }
        didStart = true
        phase = .connecting
        activity = "Connecting"

        do {
            try client.start()
            try await client.initialize()
            isConnected = true
            if phase == .connecting || phase == .disconnected {
                phase = .idle
                activity = "空闲"
            }
            await refreshQuota()
            startQuotaRefreshLoop()
        } catch {
            isConnected = false
            if phase == .connecting {
                phase = .disconnected
                activity = "未连接"
            }
        }
    }

    func refreshQuota() async {
        guard isConnected else { return }
        do {
            async let accountResponse = client.request(method: "account/read", params: ["refreshToken": false])
            async let limitsResponse = client.request(method: "account/rateLimits/read")
            let (account, limits) = try await (accountResponse, limitsResponse)
            quota = parseRateLimitSnapshot(account: account, limits: limits)
        } catch {
            // Product choice: silent failure. Keep the last successful snapshot.
        }
    }

    func startTask() async {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else { return }

        if !isConnected {
            didStart = false
            await connect()
        }
        guard isConnected else { return }

        phase = .running
        activity = "Starting task"
        activeItems.removeAll()
        lastAgentMessage = ""

        do {
            let cwd = normalizedWorkingDirectory()
            let threadResponse = try await client.request(
                method: "thread/start",
                params: [
                    "cwd": cwd,
                    "sandbox": "workspace-write",
                    "approvalPolicy": "never"
                ]
            )

            guard
                let thread = threadResponse["thread"] as? [String: Any],
                let threadID = thread["id"] as? String
            else {
                throw CodexClientError.invalidResponse
            }

            currentThreadID = threadID
            let turnResponse = try await client.request(
                method: "turn/start",
                params: [
                    "threadId": threadID,
                    "input": [
                        [
                            "type": "text",
                            "text": trimmedPrompt,
                            "text_elements": []
                        ]
                    ],
                    "cwd": cwd,
                    "approvalPolicy": "never"
                ]
            )

            if
                let turn = turnResponse["turn"] as? [String: Any],
                let turnID = turn["id"] as? String
            {
                currentTurnID = turnID
            }
        } catch {
            phase = .failed
            activity = error.localizedDescription
        }
    }

    func interruptTask() async {
        guard let currentThreadID, let currentTurnID else { return }
        do {
            _ = try await client.request(
                method: "turn/interrupt",
                params: [
                    "threadId": currentThreadID,
                    "turnId": currentTurnID
                ]
            )
            phase = .interrupted
            activity = "Interrupted"
        } catch {
            phase = .failed
            activity = error.localizedDescription
        }
    }

    private func handleNotification(_ message: CodexAppServerClient.JSONObject) {
        guard let method = message["method"] as? String else { return }
        let params = message["params"] as? [String: Any] ?? [:]

        switch method {
        case "thread/status/changed":
            handleThreadStatus(params)
        case "turn/started":
            handleTurnStarted(params)
        case "turn/completed":
            handleTurnCompleted(params)
        case "item/started":
            handleItemStarted(params)
        case "item/completed":
            handleItemCompleted(params)
        case "item/agentMessage/delta":
            if let delta = params["delta"] as? String {
                lastAgentMessage += delta
                activity = "Writing response"
            }
        case "item/commandExecution/outputDelta":
            activity = "Running command"
        case "item/fileChange/patchUpdated":
            activity = "Editing files"
        case "item/mcpToolCall/progress":
            activity = "Calling tool"
        case "account/rateLimits/updated":
            if let rateLimits = params["rateLimits"] as? [String: Any] {
                quota = parseRateLimitSnapshot(account: [:], limits: ["rateLimits": rateLimits])
            }
        case "error":
            phase = .failed
            activity = params["message"] as? String ?? "Codex error"
        default:
            break
        }
    }

    private func startQuotaRefreshLoop() {
        quotaRefreshTask?.cancel()
        quotaRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { break }
                await self?.refreshQuota()
            }
        }
    }

    private func startActivityRefreshLoop() {
        activityRefreshTask?.cancel()
        activityRefreshTask = Task { [weak self] in
            await self?.refreshActivity()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { break }
                await self?.refreshActivity()
            }
        }
    }

    private func refreshActivity() async {
        let snapshot = await activityLogMonitor.latestSnapshot()
        phase = snapshot.phase
        activity = snapshot.detail
    }

    private func handleServerRequest(_ message: CodexAppServerClient.JSONObject) {
        guard let method = message["method"] as? String else { return }
        switch method {
        case "item/commandExecution/requestApproval",
             "item/fileChange/requestApproval",
             "item/permissions/requestApproval",
             "item/tool/requestUserInput":
            phase = .waiting
            activity = "Waiting for approval"
        default:
            phase = .waiting
            activity = "Waiting for Codex"
        }
    }

    private func handleThreadStatus(_ params: [String: Any]) {
        guard let status = params["status"] as? [String: Any],
              let type = status["type"] as? String
        else { return }

        switch type {
        case "idle":
            if phase == .running || phase == .waiting {
                phase = .idle
                activity = "Idle"
            }
        case "active":
            phase = .running
            if activity == "Ready" || activity == "Idle" {
                activity = "Running"
            }
        case "systemError":
            phase = .failed
            activity = "System error"
        default:
            break
        }
    }

    private func handleTurnStarted(_ params: [String: Any]) {
        currentThreadID = params["threadId"] as? String
        if let turn = params["turn"] as? [String: Any] {
            currentTurnID = turn["id"] as? String
        }
        phase = .running
        activity = "Task started"
        activeItems.removeAll()
    }

    private func handleTurnCompleted(_ params: [String: Any]) {
        guard let turn = params["turn"] as? [String: Any] else { return }
        let status = turn["status"] as? String
        activeItems.removeAll()

        switch status {
        case "completed":
            phase = .completed
            activity = "Completed"
        case "interrupted":
            phase = .interrupted
            activity = "Interrupted"
        case "failed":
            phase = .failed
            if let error = turn["error"] as? [String: Any],
               let message = error["message"] as? String {
                activity = message
            } else {
                activity = "Failed"
            }
        default:
            phase = .idle
            activity = "Idle"
        }

        Task {
            await refreshQuota()
        }
    }

    private func handleItemStarted(_ params: [String: Any]) {
        guard let item = params["item"] as? [String: Any],
              let summary = summarizeItem(item)
        else { return }

        activeItems.removeAll { $0.id == summary.id }
        activeItems.insert(summary, at: 0)
        phase = .running
        activity = summary.title
    }

    private func handleItemCompleted(_ params: [String: Any]) {
        guard let item = params["item"] as? [String: Any],
              let id = item["id"] as? String
        else { return }

        if let summary = summarizeItem(item) {
            activity = summary.title
        }
        activeItems.removeAll { $0.id == id }
    }

    private func summarizeItem(_ item: [String: Any]) -> ActiveItemSummary? {
        guard let type = item["type"] as? String,
              let id = item["id"] as? String
        else { return nil }

        switch type {
        case "commandExecution":
            let command = item["command"] as? String ?? "Command"
            return ActiveItemSummary(
                id: id,
                kind: "Command",
                title: "Running command",
                detail: truncate(command)
            )
        case "fileChange":
            return ActiveItemSummary(id: id, kind: "Files", title: "Editing files", detail: nil)
        case "mcpToolCall":
            let server = item["server"] as? String ?? "MCP"
            let tool = item["tool"] as? String ?? "tool"
            return ActiveItemSummary(id: id, kind: "Tool", title: "Calling \(tool)", detail: server)
        case "dynamicToolCall":
            let tool = item["tool"] as? String ?? "tool"
            return ActiveItemSummary(id: id, kind: "Tool", title: "Calling \(tool)", detail: nil)
        case "agentMessage":
            return ActiveItemSummary(id: id, kind: "Message", title: "Writing response", detail: nil)
        case "reasoning":
            return ActiveItemSummary(id: id, kind: "Reasoning", title: "Thinking", detail: nil)
        case "webSearch":
            let query = item["query"] as? String
            return ActiveItemSummary(id: id, kind: "Search", title: "Searching web", detail: query)
        case "subAgentActivity":
            return ActiveItemSummary(id: id, kind: "Agent", title: "Subagent activity", detail: nil)
        default:
            return ActiveItemSummary(id: id, kind: type, title: type, detail: nil)
        }
    }

    private func parseRateLimitSnapshot(account: [String: Any], limits: [String: Any]) -> RateLimitSnapshot? {
        let accountPlan = (account["account"] as? [String: Any])?["planType"] as? String
        let rateLimitsByID = limits["rateLimitsByLimitId"] as? [String: Any]
        let codexSnapshot = rateLimitsByID?["codex"] as? [String: Any]
        let fallback = limits["rateLimits"] as? [String: Any]
        guard let snapshot = codexSnapshot ?? fallback else { return nil }

        let resetCredits = limits["rateLimitResetCredits"] as? [String: Any]
        let credits = snapshot["credits"] as? [String: Any]
        return RateLimitSnapshot(
            planType: snapshot["planType"] as? String ?? accountPlan,
            shortWindow: parseWindow(snapshot["primary"] as? [String: Any]),
            longWindow: parseWindow(snapshot["secondary"] as? [String: Any]),
            creditsBalance: credits?["balance"] as? String,
            resetCreditsAvailable: stringValue(resetCredits?["availableCount"]),
            resetCreditsExpiresAt: parseDate(resetCredits?["expiresAt"])
                ?? parseDate(resetCredits?["expiration"])
                ?? parseDate(resetCredits?["expires_at"])
        )
    }

    private func parseWindow(_ window: [String: Any]?) -> RateLimitWindowSnapshot? {
        guard let window,
              let usedPercent = numberValue(window["usedPercent"])
        else { return nil }

        var resetsAt: Date?
        if let timestamp = numberValue(window["resetsAt"]) {
            resetsAt = Date(timeIntervalSince1970: timestamp)
        }

        return RateLimitWindowSnapshot(
            usedPercent: usedPercent,
            windowDurationMins: intValue(window["windowDurationMins"]),
            resetsAt: resetsAt
        )
    }

    private func normalizedWorkingDirectory() -> String {
        let trimmed = workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return NSHomeDirectory() }
        return NSString(string: trimmed).expandingTildeInPath
    }

    private func truncate(_ value: String, limit: Int = 90) -> String {
        guard value.count > limit else { return value }
        return String(value.prefix(limit - 1)) + "..."
    }

    private func numberValue(_ value: Any?) -> Double? {
        switch value {
        case let value as Double: value
        case let value as Int: Double(value)
        case let value as NSNumber: value.doubleValue
        case let value as String: Double(value)
        default: nil
        }
    }

    private func intValue(_ value: Any?) -> Int? {
        switch value {
        case let value as Int: value
        case let value as NSNumber: value.intValue
        case let value as String: Int(value)
        default: nil
        }
    }

    private func stringValue(_ value: Any?) -> String? {
        switch value {
        case let value as String: value
        case let value as NSNumber: value.stringValue
        case let value as Int: String(value)
        default: nil
        }
    }

    private func parseDate(_ value: Any?) -> Date? {
        guard let timestamp = numberValue(value) else { return nil }
        let seconds = timestamp > 10_000_000_000 ? timestamp / 1000 : timestamp
        return Date(timeIntervalSince1970: seconds)
    }
}
