import Foundation

public enum MotionIntensity: String, Codable, Sendable, CaseIterable {
    case subtle, standard, lively

    public var scale: Double {
        switch self {
        case .subtle: 0.55
        case .standard: 1
        case .lively: 1.3
        }
    }

    public var displayName: String { rawValue.capitalized }
}

/// User preferences (PRD FR-10). Stored as one JSON blob in UserDefaults.
public struct AppSettings: Codable, Sendable, Equatable {
    public var hasCompletedOnboarding = false
    public var soundEnabled = true
    public var motionIntensity = MotionIntensity.standard
    /// Forces reduced motion even if the system setting is off.
    public var reduceMotion = false
    public var quietMode = false
    public var quietHoursEnabled = false
    public var quietHoursStart = 22 * 60    // minutes after midnight
    public var quietHoursEnd = 8 * 60
    public var respectFocus = true
    public var enabledCategories = Set(EventCategory.allCases)
    public var enabledAgents = Set(AgentKind.allCases)
    /// 0 turns reminders off.
    public var reminderMinutes = 5
    public var historyRetentionDays = 7
    public var hotkeyEnabled = true

    public init() {}

    public func isQuietHours(at date: Date = Date(), calendar: Calendar = .current) -> Bool {
        guard quietHoursEnabled else { return false }
        let c = calendar.dateComponents([.hour, .minute], from: date)
        let minute = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        if quietHoursStart <= quietHoursEnd {
            return minute >= quietHoursStart && minute < quietHoursEnd
        }
        return minute >= quietHoursStart || minute < quietHoursEnd
    }

    // Decoding tolerates fields added in later versions, and a value this
    // version can't read (written by a newer one) falls back to its default
    // instead of resetting every other preference.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func read<T: Decodable>(_ key: CodingKeys, as _: T.Type = T.self) -> T? {
            try? c.decodeIfPresent(T.self, forKey: key)
        }
        let d = AppSettings()
        hasCompletedOnboarding = read(.hasCompletedOnboarding) ?? d.hasCompletedOnboarding
        soundEnabled = read(.soundEnabled) ?? d.soundEnabled
        motionIntensity = read(.motionIntensity) ?? d.motionIntensity
        reduceMotion = read(.reduceMotion) ?? d.reduceMotion
        quietMode = read(.quietMode) ?? d.quietMode
        quietHoursEnabled = read(.quietHoursEnabled) ?? d.quietHoursEnabled
        quietHoursStart = read(.quietHoursStart) ?? d.quietHoursStart
        quietHoursEnd = read(.quietHoursEnd) ?? d.quietHoursEnd
        respectFocus = read(.respectFocus) ?? d.respectFocus
        // Set members are read one by one, so an unknown category or agent is skipped.
        enabledCategories = read(.enabledCategories, as: [String].self)
            .map { Set($0.compactMap(EventCategory.init(rawValue:))) } ?? d.enabledCategories
        enabledAgents = read(.enabledAgents, as: [String].self)
            .map { Set($0.compactMap(AgentKind.init(rawValue:))) } ?? d.enabledAgents
        reminderMinutes = read(.reminderMinutes) ?? d.reminderMinutes
        historyRetentionDays = read(.historyRetentionDays) ?? d.historyRetentionDays
        hotkeyEnabled = read(.hotkeyEnabled) ?? d.hotkeyEnabled
    }

    public static func load(from defaults: UserDefaults = .standard) -> AppSettings {
        guard let data = defaults.data(forKey: "settings"),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data) else { return AppSettings() }
        return settings
    }

    public func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: "settings") }
    }
}
