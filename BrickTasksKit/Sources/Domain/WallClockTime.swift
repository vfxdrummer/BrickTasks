/// A warehouse-local time of day, `HH:MM`, 24-hour.
public struct WallClockTime: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let hour: Int
    public let minute: Int

    public init?(hour: Int, minute: Int) {
        guard (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        self.hour = hour
        self.minute = minute
    }

    public init?(_ string: String) {
        let parts = string.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].count == 2, parts[1].count == 2,
              let h = Int(parts[0]), let m = Int(parts[1])
        else { return nil }
        self.init(hour: h, minute: m)
    }

    public var description: String { String(format: "%02d:%02d", hour, minute) }

    public static func < (lhs: WallClockTime, rhs: WallClockTime) -> Bool {
        (lhs.hour, lhs.minute) < (rhs.hour, rhs.minute)
    }
}
