import Foundation

@MainActor
final class CodexStatusStore: ObservableObject {
    @Published var phase: ExecutionPhase = .disconnected
    @Published var activity = "连接中"
    @Published var quota: RateLimitSnapshot?
    @Published var isAttentionDimmed = false

    private let client = CodexAppServerClient()
    private let resetCreditsClient = CodexResetCreditsClient()
    private let activityLogMonitor = CodexActivityLogMonitor()

    private var didStart = false
    private var isConnected = false
    private var quotaRefreshTask: Task<Void, Never>?
    private var activityRefreshTask: Task<Void, Never>?
    private var attentionBlinkTask: Task<Void, Never>?

    var statusBarText: String {
        "\(statusBarTaskText) | \(statusBarQuotaText)"
    }

    var statusBarTaskText: String {
        taskStatusText
    }

    var statusBarQuotaText: String {
        let fiveHour = StatusFormatters.percentText(quota?.shortWindow?.remainingPercent)
        let fiveHourReset = StatusFormatters.statusBarTimeText(quota?.shortWindow?.resetsAt)
        let weekly = StatusFormatters.percentText(quota?.longWindow?.remainingPercent)
        let weeklyReset = StatusFormatters.statusBarDateTimeText(quota?.longWindow?.resetsAt)
        let resets = resetCreditsCountText(quota?.resetCreditsAvailable)
        let resetExpiry = StatusFormatters.statusBarDateTimeText(quota?.resetCreditsExpiresAt)
        return "5h \(fiveHour)/\(fiveHourReset) | 周 \(weekly)/\(weeklyReset) | 重置 \(resets)/\(resetExpiry)"
    }

    var needsUserAttention: Bool {
        phase == .waiting
    }

    private var taskStatusText: String {
        if (phase == .running || phase == .waiting), activity != phase.title, !activity.isEmpty {
            return "\(phase.title):\(activity)"
        }
        return phase.title
    }

    func resetCreditsCountText(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "--" }
        return "\(value)次"
    }

    init() {
        Task {
            await connect()
        }
        startActivityRefreshLoop()
        startAttentionBlinkLoop()
    }

    deinit {
        quotaRefreshTask?.cancel()
        activityRefreshTask?.cancel()
        attentionBlinkTask?.cancel()
        client.stop()
    }

    func connect() async {
        guard !didStart else { return }
        didStart = true
        phase = .connecting
        activity = "连接中"

        do {
            try client.start()
            try await client.initialize()
            isConnected = true
            phase = .idle
            activity = "空闲"
            await refreshQuota()
            startQuotaRefreshLoop()
        } catch {
            isConnected = false
            phase = .disconnected
            activity = "未连接"
        }
    }

    func refreshQuota() async {
        guard isConnected else { return }

        do {
            async let limitsResponse = client.request(method: "account/rateLimits/read")
            async let resetCreditsResponse = resetCreditsClient.fetch()

            let limits = try await limitsResponse
            var snapshot = parseRateLimitSnapshot(limits: limits)
            if let resetCredits = try? await resetCreditsResponse {
                let availableCount = resetCredits.availableCount
                    ?? snapshot?.resetCreditsAvailable
                snapshot?.resetCreditsAvailable = availableCount
                snapshot?.resetCreditsExpiresAt = resetCredits.expiresAt
                snapshot?.resetCredits = resetCredits.credits
            } else {
                snapshot?.resetCreditsExpiresAt = nil
                snapshot?.resetCredits = []
            }
            quota = snapshot
        } catch {
            // Keep the last successful snapshot; quota failures should be silent.
        }
    }

    private func startQuotaRefreshLoop() {
        quotaRefreshTask?.cancel()
        quotaRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
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

    private func startAttentionBlinkLoop() {
        attentionBlinkTask?.cancel()
        attentionBlinkTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(650))
                guard !Task.isCancelled else { break }
                guard let self else { break }

                if self.needsUserAttention {
                    self.isAttentionDimmed.toggle()
                } else {
                    self.isAttentionDimmed = false
                }
            }
        }
    }

    private func refreshActivity() async {
        let snapshot = await activityLogMonitor.latestSnapshot()
        phase = snapshot.phase
        activity = snapshot.detail
    }

    private func parseRateLimitSnapshot(limits: [String: Any]) -> RateLimitSnapshot? {
        let rateLimitsByID = limits["rateLimitsByLimitId"] as? [String: Any]
        let codexSnapshot = rateLimitsByID?["codex"] as? [String: Any]
        let fallback = limits["rateLimits"] as? [String: Any]
        guard let snapshot = codexSnapshot ?? fallback else { return nil }

        let resetCredits = limits["rateLimitResetCredits"] as? [String: Any]
        return RateLimitSnapshot(
            shortWindow: parseWindow(snapshot["primary"] as? [String: Any]),
            longWindow: parseWindow(snapshot["secondary"] as? [String: Any]),
            resetCreditsAvailable: stringValue(resetCredits?["availableCount"]),
            resetCreditsExpiresAt: parseDate(resetCredits?["expiresAt"])
                ?? parseDate(resetCredits?["expiration"])
                ?? parseDate(resetCredits?["expires_at"]),
            resetCredits: []
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
            resetsAt: resetsAt
        )
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

    private func stringValue(_ value: Any?) -> String? {
        switch value {
        case let value as String: value
        case let value as NSNumber: value.stringValue
        case let value as Int: String(value)
        default: nil
        }
    }

    private func parseDate(_ value: Any?) -> Date? {
        if let value = value as? String {
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: value) {
                return date
            }

            let standard = ISO8601DateFormatter()
            standard.formatOptions = [.withInternetDateTime]
            return standard.date(from: value)
        }

        guard let timestamp = numberValue(value) else { return nil }
        let seconds = timestamp > 10_000_000_000 ? timestamp / 1000 : timestamp
        return Date(timeIntervalSince1970: seconds)
    }
}
