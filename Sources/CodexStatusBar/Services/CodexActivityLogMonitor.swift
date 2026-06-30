import Foundation

final class CodexActivityLogMonitor {
    private struct LogRow: Decodable {
        var id: Int64
        var ts: TimeInterval
        var ts_nanos: Int64
        var target: String
        var body: String?
    }

    private struct TurnState {
        var lastActivityAt: Date
        var terminalAt: Date?
        var detail = "运行中"
        var failedAt: Date?

        var isTerminal: Bool {
            terminalAt != nil || failedAt != nil
        }
    }

    private struct ActivityEvent {
        var date: Date
        var phase: ExecutionPhase
        var detail: String
        var visibleSeconds: TimeInterval
    }

    private let databaseURL: URL
    private let recentSeconds: Int
    private let activeStaleSeconds: TimeInterval = 600
    private let streamVisibleSeconds: TimeInterval = 4
    private let toolArgumentVisibleSeconds: TimeInterval = 8
    private let fileEditVisibleSeconds: TimeInterval = 45
    private let completedVisibleSeconds: TimeInterval = 12

    init(
        databaseURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/logs_2.sqlite"),
        recentSeconds: Int = 3600
    ) {
        self.databaseURL = databaseURL
        self.recentSeconds = recentSeconds
    }

    func latestSnapshot() async -> CodexActivitySnapshot {
        await Task.detached(priority: .utility) {
            self.readLatestSnapshot()
        }.value
    }

    private func readLatestSnapshot() -> CodexActivitySnapshot {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            return .idle
        }

        let sql = """
        select id, ts, ts_nanos, target, substr(feedback_log_body, 1, 1600) as body
        from logs
        where ts >= strftime('%s','now') - \(recentSeconds)
          and (
            target = 'codex_app_server::outgoing_message'
            or target = 'codex_core::session::turn'
            or target = 'codex_core::stream_events_utils'
            or target = 'codex_api::sse::responses'
            or target = 'codex_api::endpoint::responses_websocket'
            or target = 'codex_otel.trace_safe'
            or target = 'codex_otel.log_only'
            or (
              target = 'log'
              and (
                feedback_log_body like '%otel.name=apply_patch%'
                or feedback_log_body like '%tool_name=apply_patch%'
                or feedback_log_body like '%patchUpdated%'
                or feedback_log_body like '%fileChange%'
                or feedback_log_body like '%dispatch_tool_call%'
                or feedback_log_body like '%custom_tool_call%'
              )
            )
          )
        order by ts desc, ts_nanos desc, id desc
        limit 250;
        """

        do {
            let rows = try fetchRows(sql: sql)
            return inferSnapshot(from: rows)
        } catch {
            return .idle
        }
    }

    private func fetchRows(sql: String) throws -> [LogRow] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = ["-json", databaseURL.path, sql]

        let outputPipe = Pipe()
        process.standardOutput = outputPipe

        try process.run()
        let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CodexClientError.invalidResponse
        }

        if output.isEmpty {
            return []
        }
        return try JSONDecoder().decode([LogRow].self, from: output)
    }

    private func inferSnapshot(from rows: [LogRow]) -> CodexActivitySnapshot {
        let orderedRows = rows.sorted {
            if $0.ts == $1.ts {
                if $0.ts_nanos == $1.ts_nanos {
                    return $0.id < $1.id
                }
                return $0.ts_nanos < $1.ts_nanos
            }
            return $0.ts < $1.ts
        }

        var turns: [String: TurnState] = [:]
        var latestActivityEvent: ActivityEvent?

        for row in orderedRows {
            guard let body = row.body, !body.isEmpty else { continue }
            let date = Date(timeIntervalSince1970: row.ts)

            if row.target == "codex_app_server::outgoing_message",
               let eventName = appServerEventName(from: body),
               let event = appServerActivityEvent(named: eventName, at: date)
            {
                latestActivityEvent = event
            } else if row.target == "codex_api::sse::responses",
                      let event = responseActivityEvent(from: body, at: date)
            {
                latestActivityEvent = event
            } else if row.target == "log",
                      let event = logActivityEvent(from: body, at: date)
            {
                latestActivityEvent = event
                continue
            }

            guard let turnID = turnID(from: body) else { continue }
            var state = turns[turnID] ?? TurnState(
                lastActivityAt: date
            )

            state.lastActivityAt = max(state.lastActivityAt, date)
            state.detail = activityDetail(from: body, fallback: state.detail)

            if isFailure(body) {
                state.failedAt = date
                state.detail = "失败"
            } else if isTerminalTurnEvent(body) {
                state.terminalAt = date
                state.detail = "已完成"
            }

            turns[turnID] = state
        }

        return snapshot(from: Array(turns.values), latestActivityEvent: latestActivityEvent)
    }

    private func snapshot(
        from turns: [TurnState],
        latestActivityEvent: ActivityEvent?
    ) -> CodexActivitySnapshot {
        let now = Date()
        let recentTurns = turns.sorted { $0.lastActivityAt > $1.lastActivityAt }
        let eventSnapshot = latestActivityEvent.flatMap { snapshot(from: $0, now: now) }

        if let activeTurn = recentTurns.first(where: {
            !$0.isTerminal && now.timeIntervalSince($0.lastActivityAt) <= activeStaleSeconds
        }) {
            if let latestActivityEvent,
               let eventSnapshot,
               latestActivityEvent.date >= activeTurn.lastActivityAt,
               eventSnapshot.phase == .completed || eventSnapshot.phase == .failed
            {
                return eventSnapshot
            }

            let phase: ExecutionPhase = activeTurn.detail == "等待确认" ? .waiting : .running
            return CodexActivitySnapshot(
                phase: phase,
                detail: activeTurn.detail
            )
        }

        if let failedTurn = recentTurns.first(where: { $0.failedAt != nil }),
           let failedAt = failedTurn.failedAt,
           now.timeIntervalSince(failedAt) <= completedVisibleSeconds
        {
            return CodexActivitySnapshot(
                phase: .failed,
                detail: failedTurn.detail
            )
        }

        if let completedTurn = recentTurns.first(where: { $0.terminalAt != nil }),
           let terminalAt = completedTurn.terminalAt,
           now.timeIntervalSince(terminalAt) <= completedVisibleSeconds
        {
            return CodexActivitySnapshot(
                phase: .completed,
                detail: "已完成"
            )
        }

        if let eventSnapshot {
            return eventSnapshot
        }

        return .idle
    }

    private func snapshot(from event: ActivityEvent, now: Date) -> CodexActivitySnapshot? {
        let age = now.timeIntervalSince(event.date)
        guard age <= event.visibleSeconds else { return nil }
        return CodexActivitySnapshot(phase: event.phase, detail: event.detail)
    }

    private func appServerActivityEvent(named name: String, at date: Date) -> ActivityEvent? {
        switch name {
        case "turn/started":
            return ActivityEvent(
                date: date,
                phase: .running,
                detail: "运行中",
                visibleSeconds: activeStaleSeconds
            )
        case "item/started":
            return ActivityEvent(
                date: date,
                phase: .running,
                detail: "执行中",
                visibleSeconds: activeStaleSeconds
            )
        case "item/completed":
            return ActivityEvent(
                date: date,
                phase: .running,
                detail: "思考中",
                visibleSeconds: activeStaleSeconds
            )
        case "item/agentMessage/delta":
            return ActivityEvent(
                date: date,
                phase: .running,
                detail: "输出中",
                visibleSeconds: streamVisibleSeconds
            )
        case "turn/completed":
            return ActivityEvent(
                date: date,
                phase: .completed,
                detail: "已完成",
                visibleSeconds: completedVisibleSeconds
            )
        default:
            return nil
        }
    }

    private func responseActivityEvent(from body: String, at date: Date) -> ActivityEvent? {
        guard let eventName = responseEventName(from: body) else { return nil }

        switch eventName {
        case "response.created", "response.in_progress":
            return ActivityEvent(
                date: date,
                phase: .running,
                detail: "思考中",
                visibleSeconds: activeStaleSeconds
            )
        case "response.output_text.delta",
             "response.output_text.done",
             "response.content_part.added",
             "response.content_part.done":
            return ActivityEvent(
                date: date,
                phase: .running,
                detail: "输出中",
                visibleSeconds: streamVisibleSeconds
            )
        case "response.output_item.added", "response.output_item.done":
            let detail = responseOutputItemDetail(from: body)
            return ActivityEvent(
                date: date,
                phase: detail == "等待确认" ? .waiting : .running,
                detail: detail,
                visibleSeconds: responseOutputItemVisibleSeconds(from: detail)
            )
        case "response.function_call_arguments.delta",
             "response.function_call_arguments.done":
            return ActivityEvent(
                date: date,
                phase: .running,
                detail: "调用工具",
                visibleSeconds: toolArgumentVisibleSeconds
            )
        case "response.completed":
            return ActivityEvent(
                date: date,
                phase: .completed,
                detail: "已完成",
                visibleSeconds: completedVisibleSeconds
            )
        case "response.failed", "response.incomplete":
            return ActivityEvent(
                date: date,
                phase: .failed,
                detail: "失败",
                visibleSeconds: completedVisibleSeconds
            )
        default:
            return nil
        }
    }

    private func responseOutputItemDetail(from body: String) -> String {
        if body.contains("\"type\":\"function_call\"") {
            return activityDetail(from: body, fallback: "调用工具")
        }
        if body.contains("\"type\":\"message\"") {
            return "输出中"
        }
        return "运行中"
    }

    private func logActivityEvent(from body: String, at date: Date) -> ActivityEvent? {
        let detail = activityDetail(from: body, fallback: "调用工具")
        guard detail != "思考中" && detail != "输出中" else { return nil }
        return ActivityEvent(
            date: date,
            phase: detail == "等待确认" ? .waiting : .running,
            detail: detail,
            visibleSeconds: responseOutputItemVisibleSeconds(from: detail)
        )
    }

    private func responseOutputItemVisibleSeconds(from detail: String) -> TimeInterval {
        switch detail {
        case "输出中":
            return streamVisibleSeconds
        case "修改文件":
            return fileEditVisibleSeconds
        case "调用工具", "执行命令":
            return toolArgumentVisibleSeconds
        default:
            return activeStaleSeconds
        }
    }

    private func responseEventName(from body: String) -> String? {
        if let typeRange = body.range(of: "\"type\":\"") {
            let suffix = body[typeRange.upperBound...]
            return suffix.split(separator: "\"").first.map(String.init)
        }

        guard let range = body.range(of: "unhandled responses event: ") else {
            return nil
        }
        let suffix = body[range.upperBound...]
        return suffix.split(whereSeparator: { $0.isWhitespace }).first.map(String.init)
    }

    private func appServerEventName(from body: String) -> String? {
        guard let range = body.range(of: "app-server event: ") else { return nil }
        let suffix = body[range.upperBound...]
        return suffix.split(separator: " ").first.map(String.init)
    }

    private func turnID(from body: String) -> String? {
        if let explicit = captureAfter("turn.id=", in: body) {
            return explicit
        }
        if let explicit = captureAfter("turn_id=", in: body) {
            return explicit
        }
        return nil
    }

    private func captureAfter(_ marker: String, in body: String) -> String? {
        guard let range = body.range(of: marker) else { return nil }
        let suffix = body[range.upperBound...]
        let value = suffix.prefix { character in
            character.isLetter || character.isNumber || character == "-"
        }
        return value.isEmpty ? nil : String(value)
    }

    private func activityDetail(from body: String, fallback: String) -> String {
        if body.contains("requestApproval") || body.contains("has_pending_input=true") {
            return "等待确认"
        }
        if isFileEditEvent(body) {
            return "修改文件"
        }
        if body.contains("commandExecution") || body.contains("exec_command") {
            return "执行命令"
        }
        if isBrowserNavigationToolCall(body) {
            return "等待确认"
        }
        if body.contains("ToolCall") || body.contains("function_call") || body.contains("output_item.added") {
            return "调用工具"
        }
        if body.contains("message_from_assistant") || body.contains("agentMessage") {
            return "输出中"
        }
        if body.contains("run_sampling_request") || body.contains("response.create") {
            return "思考中"
        }
        return fallback
    }

    private func isFileEditEvent(_ body: String) -> Bool {
        body.contains("\"name\":\"apply_patch\"")
            || body.contains("name=apply_patch")
            || body.contains("tool_name=apply_patch")
            || body.contains("otel.name=apply_patch")
            || body.contains("patchUpdated")
            || body.contains("fileChange")
    }

    private func isBrowserNavigationToolCall(_ body: String) -> Bool {
        let isBrowserTool = body.contains("mcp__node_repljs")
            || body.contains("codex/browserUse")
            || body.contains("browser.capabilities")
        let opensPage = body.contains(".goto(")
            || body.contains("tab.goto")
            || body.contains("page.goto")
        return isBrowserTool && opensPage
    }

    private func isTerminalTurnEvent(_ body: String) -> Bool {
        body.contains("needs_follow_up=false")
            || body.contains("phase: Some(FinalAnswer)")
    }

    private func isFailure(_ body: String) -> Bool {
        body.contains("event.kind=response.failed")
            || body.contains("status=failed")
            || body.contains("status\":\"failed")
            || body.contains("error=")
            || body.contains("\"error\":{")
    }
}

extension CodexActivityLogMonitor: @unchecked Sendable {}
