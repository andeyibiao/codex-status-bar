import Foundation

enum StatusFormatters {
    static let percent: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
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

    static let panelTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    static let panelDateTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "M/d HH:mm"
        return formatter
    }()

    static func percentText(_ value: Double?) -> String {
        guard let value else { return "--" }
        return "\(percent.string(from: NSNumber(value: value)) ?? "\(Int(value))")%"
    }

    static func statusBarTimeText(_ date: Date?) -> String {
        guard let date else { return "--" }
        return statusBarTime.string(from: date)
    }

    static func statusBarDateTimeText(_ date: Date?) -> String {
        guard let date else { return "--" }
        return statusBarDateTime.string(from: date)
    }

    static func panelDateTimeText(_ date: Date?) -> String {
        guard let date else { return "--" }

        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return "今天 \(panelTime.string(from: date))"
        }
        if calendar.isDateInTomorrow(date) {
            return "明天 \(panelTime.string(from: date))"
        }
        return panelDateTime.string(from: date)
    }
}
