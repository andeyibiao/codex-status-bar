import Foundation

final class CodexActivityLogMonitor {
    private struct LogRow: Decodable {
        var id: Int64
        var ts: TimeInterval
        var ts_nanos: Int64
        var target: String
        var thread_id: String?
        var body: String?
    }

    private struct TurnState {
        var turnID: String
        var startedAt: Date
        var lastActivityAt: Date
        var terminalAt: Date?
        var detail = "运行中"
        var failedAt: Date?

        var isTerminal: Bool {
            terminalAt != nil || failedAt != nil
        }
    }

    private struct ServerEvent {
        var date: Date
        var name: String
    }

    private let databaseURL: URL
    private let recentSeconds: Int
    private let activeStaleSeconds: TimeInterval = 600
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
        select id, ts, ts_nanos, target, thread_id, substr(feedback_log_body, 1, 1600) as body
        from logs
        where ts >= strftime('%s','now') - \(recentSeconds)
          and (
            target = 'codex_app_server::outgoing_message'
            or target = 'codex_core::session::turn'
            or target = 'codex_core::stream_events_utils'
            or target = 'codex_api::endpoint::responses_websocket'
            or target = 'codex_otel.trace_safe'
            or target = 'codex_otel.log_only'
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
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

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
        var latestServerEvent: ServerEvent?

        for row in orderedRows {
            guard let body = row.body, !body.isEmpty else { continue }
            let date = Date(timeIntervalSince1970: row.ts)

            if row.target == "codex_app_server::outgoing_message",
               let eventName = appServerEventName(from: body)
            {
                latestServerEvent = ServerEvent(date: date, name: eventName)
            }

            guard let turnID = turnID(from: body) else { continue }
            var state = turns[turnID] ?? TurnState(
                turnID: turnID,
                startedAt: date,
                lastActivityAt: date
            )

            state.startedAt = min(state.startedAt, date)
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

        return snapshot(from: Array(turns.values), latestServerEvent: latestServerEvent)
    }

    private func snapshot(
        from turns: [TurnState],
        latestServerEvent: ServerEvent?
    ) -> CodexActivitySnapshot {
        let now = Date()
        let recentTurns = turns.sorted { $0.lastActivityAt > $1.lastActivityAt }

        if let activeTurn = recentTurns.first(where: {
            !$0.isTerminal && now.timeIntervalSince($0.lastActivityAt) <= activeStaleSeconds
        }) {
            return CodexActivitySnapshot(
                phase: .running,
                detail: activeTurn.detail,
                observedAt: activeTurn.lastActivityAt
            )
        }

        if let failedTurn = recentTurns.first(where: { $0.failedAt != nil }),
           let failedAt = failedTurn.failedAt,
           now.timeIntervalSince(failedAt) <= completedVisibleSeconds
        {
            return CodexActivitySnapshot(
                phase: .failed,
                detail: failedTurn.detail,
                observedAt: failedAt
            )
        }

        if let completedTurn = recentTurns.first(where: { $0.terminalAt != nil }),
           let terminalAt = completedTurn.terminalAt,
           now.timeIntervalSince(terminalAt) <= completedVisibleSeconds
        {
            return CodexActivitySnapshot(
                phase: .completed,
                detail: "已完成",
                observedAt: terminalAt
            )
        }

        if let latestServerEvent {
            return snapshot(from: latestServerEvent, now: now)
        }

        return .idle
    }

    private func snapshot(from event: ServerEvent, now: Date) -> CodexActivitySnapshot {
        let age = now.timeIntervalSince(event.date)
        switch event.name {
        case "turn/started":
            if age <= activeStaleSeconds {
                return CodexActivitySnapshot(phase: .running, detail: "运行中", observedAt: event.date)
            }
        case "item/started":
            if age <= activeStaleSeconds {
                return CodexActivitySnapshot(phase: .running, detail: "执行中", observedAt: event.date)
            }
        case "item/agentMessage/delta":
            if age <= activeStaleSeconds {
                return CodexActivitySnapshot(phase: .running, detail: "输出中", observedAt: event.date)
            }
        case "turn/completed":
            if age <= completedVisibleSeconds {
                return CodexActivitySnapshot(phase: .completed, detail: "已完成", observedAt: event.date)
            }
        default:
            break
        }
        return .idle
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
        if body.contains("apply_patch") || body.contains("patchUpdated") || body.contains("fileChange") {
            return "修改文件"
        }
        if body.contains("commandExecution") || body.contains("exec_command") {
            return "执行命令"
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
