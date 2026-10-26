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

    // Decoding tolerates fields added in later versions.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        hasCompletedOnboarding = try c.decodeIfPresent(Bool.self, forKey: .hasCompletedOnboarding) ?? d.hasCompletedOnboarding
        soundEnabled = try c.decodeIfPresent(Bool.self, forKey: .soundEnabled) ?? d.soundEnabled
        motionIntensity = try c.decodeIfPresent(MotionIntensity.self, forKey: .motionIntensity) ?? d.motionIntensity
        reduceMotion = try c.decodeIfPresent(Bool.self, forKey: .reduceMotion) ?? d.reduceMotion
        quietMode = try c.decodeIfPresent(Bool.self, forKey: .quietMode) ?? d.quietMode
        quietHoursEnabled = try c.decodeIfPresent(Bool.self, forKey: .quietHoursEnabled) ?? d.quietHoursEnabled
        quietHoursStart = try c.decodeIfPresent(Int.self, forKey: .quietHoursStart) ?? d.quietHoursStart
        quietHoursEnd = try c.decodeIfPresent(Int.self, forKey: .quietHoursEnd) ?? d.quietHoursEnd
        respectFocus = try c.decodeIfPresent(Bool.self, forKey: .respectFocus) ?? d.respectFocus
        enabledCategories = try c.decodeIfPresent(Set<EventCategory>.self, forKey: .enabledCategories) ?? d.enabledCategories
        enabledAgents = try c.decodeIfPresent(Set<AgentKind>.self, forKey: .enabledAgents) ?? d.enabledAgents
        reminderMinutes = try c.decodeIfPresent(Int.self, forKey: .reminderMinutes) ?? d.reminderMinutes
        historyRetentionDays = try c.decodeIfPresent(Int.self, forKey: .historyRetentionDays) ?? d.historyRetentionDays
        hotkeyEnabled = try c.decodeIfPresent(Bool.self, forKey: .hotkeyEnabled) ?? d.hotkeyEnabled
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
