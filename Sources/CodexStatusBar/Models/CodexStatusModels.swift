import Foundation

enum ExecutionPhase: Equatable {
    case disconnected
    case connecting
    case idle
    case running
    case waiting
    case completed
    case failed
    case interrupted

    var title: String {
        switch self {
        case .disconnected: "未连接"
        case .connecting: "连接中"
        case .idle: "空闲"
        case .running: "运行中"
        case .waiting: "等待"
        case .completed: "已完成"
        case .failed: "失败"
        case .interrupted: "已中断"
        }
    }

    var systemImage: String {
        switch self {
        case .disconnected: "bolt.slash"
        case .connecting: "arrow.triangle.2.circlepath"
        case .idle: "checkmark.circle"
        case .running: "play.circle.fill"
        case .waiting: "pause.circle"
        case .completed: "checkmark.circle.fill"
        case .failed: "xmark.octagon.fill"
        case .interrupted: "stop.circle.fill"
        }
    }
}

struct RateLimitWindowSnapshot: Equatable {
    var usedPercent: Double
    var windowDurationMins: Int?
    var resetsAt: Date?

    var remainingPercent: Double {
        max(0, 100 - usedPercent)
    }
}

struct RateLimitSnapshot: Equatable {
    var planType: String?
    var shortWindow: RateLimitWindowSnapshot?
    var longWindow: RateLimitWindowSnapshot?
    var creditsBalance: String?
    var resetCreditsAvailable: String?
    var resetCreditsExpiresAt: Date?
}

struct ActiveItemSummary: Equatable, Identifiable {
    var id: String
    var kind: String
    var title: String
    var detail: String?
}

struct CodexActivitySnapshot: Equatable {
    var phase: ExecutionPhase
    var detail: String
    var observedAt: Date?

    static let idle = CodexActivitySnapshot(
        phase: .idle,
        detail: "空闲",
        observedAt: nil
    )
}
