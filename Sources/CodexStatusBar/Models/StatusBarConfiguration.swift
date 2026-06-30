import Foundation

struct StatusBarConfiguration: Codable, Equatable {
    var showIcon = true
    var showTaskStatus = true
    var showShortWindow = true
    var showLongWindow = true
    var showResetCredits = true

    static let storageKey = "statusBarConfiguration.v1"

    static func load(from defaults: UserDefaults = .standard) -> StatusBarConfiguration {
        guard
            let data = defaults.data(forKey: storageKey),
            let configuration = try? JSONDecoder().decode(StatusBarConfiguration.self, from: data)
        else {
            return StatusBarConfiguration()
        }
        return configuration
    }

    func save(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
