import Foundation

enum ExecutionPhase: Equatable {
    case disconnected
    case connecting
    case idle
    case running
    case waiting
    case completed
    case failed

    var title: String {
        switch self {
        case .disconnected: "未连接"
        case .connecting: "连接中"
        case .idle: "空闲"
        case .running: "运行中"
        case .waiting: "等待"
        case .completed: "已完成"
        case .failed: "失败"
        }
    }
}

struct RateLimitWindowSnapshot: Equatable {
    var usedPercent: Double
    var resetsAt: Date?

    var remainingPercent: Double {
        max(0, 100 - usedPercent)
    }
}

struct RateLimitSnapshot: Equatable {
    var shortWindow: RateLimitWindowSnapshot?
    var longWindow: RateLimitWindowSnapshot?
    var resetCreditsAvailable: String?
    var resetCreditsExpiresAt: Date?
    var resetCredits: [ResetCreditSnapshot] = []
}

struct ResetCreditSnapshot: Identifiable, Equatable {
    var id: Int
    var expiresAt: Date?
}

struct CodexActivitySnapshot: Equatable {
    var phase: ExecutionPhase
    var detail: String

    static let idle = CodexActivitySnapshot(
        phase: .idle,
        detail: "空闲"
    )
}
