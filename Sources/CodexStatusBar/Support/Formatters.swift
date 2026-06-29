import Foundation

enum StatusFormatters {
    static let percent: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter
    }()

    static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    static let statusBarTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    static let statusBarDateTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "M/d HH:mm"
        return formatter
    }()

    static func percentText(_ value: Double?) -> String {
        guard let value else { return "--" }
        return "\(percent.string(from: NSNumber(value: value)) ?? "\(Int(value))")%"
    }

    static func resetText(_ date: Date?) -> String {
        guard let date else { return "--" }
        return time.string(from: date)
    }

    static func statusBarTimeText(_ date: Date?) -> String {
        guard let date else { return "--" }
        return statusBarTime.string(from: date)
    }

    static func statusBarDateTimeText(_ date: Date?) -> String {
        guard let date else { return "--" }
        return statusBarDateTime.string(from: date)
    }
}
