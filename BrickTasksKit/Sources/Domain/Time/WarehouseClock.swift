import Foundation

/// The single source of "now" for all logic. Not named `Clock`, to avoid clashing with Swift's `Clock`.
public protocol WarehouseClock: Sendable {
    var now: Date { get }
    /// The warehouse's timezone. The API never sends one; we assume the device is in it.
    var timeZone: TimeZone { get }
}

extension WarehouseClock {
    public var today: CalendarDay { CalendarDay(containing: now, in: timeZone) }
}

public struct SystemWarehouseClock: WarehouseClock {
    public init() {}
    public var now: Date { Date() }
    public var timeZone: TimeZone { .current }
}

public struct FixedWarehouseClock: WarehouseClock {
    public var now: Date
    public var timeZone: TimeZone

    public init(now: Date, timeZone: TimeZone) {
        self.now = now
        self.timeZone = timeZone
    }
}
