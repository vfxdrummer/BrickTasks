internal import Domain
internal import Repository
internal import Foundation

/// A message shown above a screen's content. Never blocks the content underneath.
public struct Banner: Hashable, Sendable {
    public enum Style: Hashable, Sendable { case offline, warning, error }
    public let style: Style
    public let message: String

    public init(_ style: Style, _ message: String) {
        self.style = style
        self.message = message
    }
}

/// Whether an action button is usable, and if not, the reason shown under it.
public enum ActionAvailability: Hashable, Sendable {
    case enabled
    case disabled(reason: String)
    case hidden

    public var isEnabled: Bool { self == .enabled }
}

/// Formatting shared by screens. All of it uses the warehouse timezone from the clock.
struct Formatters {
    let clock: any WarehouseClock
    let locale: Locale

    func kindName(_ kind: TaskKind) -> String {
        switch kind {
        case .pick: "Pick"
        case .pack: "Pack"
        case .ship: "Ship"
        case .unknown(let raw): raw.capitalized
        }
    }

    func time(_ time: WallClockTime) -> String {
        let date = CalendarDay(year: 2001, month: 1, day: 1)!.startDate(in: .gmt)
            .addingTimeInterval(TimeInterval(time.hour * 3600 + time.minute * 60))
        return date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, timeZone: .gmt))
    }

    func clockTime(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, timeZone: clock.timeZone))
    }

    /// "Today", "Tomorrow", "Yesterday", or e.g. "Fri, Oct 30".
    func relativeDay(_ day: CalendarDay) -> String {
        switch day {
        case clock.today: return "Today"
        case clock.today.adding(days: 1): return "Tomorrow"
        case clock.today.adding(days: -1): return "Yesterday"
        default: return absoluteDay(day)
        }
    }

    func absoluteDay(_ day: CalendarDay) -> String {
        day.startDate(in: clock.timeZone)
            .formatted(Date.FormatStyle(locale: locale, timeZone: clock.timeZone).weekday(.abbreviated).month(.abbreviated).day())
    }

    /// Plain-language error text that says what to do next.
    func message(for error: RepositoryError) -> String {
        switch error {
        case .offline: "No connection. Nothing was changed."
        case .busy: "The server is busy. Wait a moment and try again."
        case .rejected(let message): "Not allowed: \(message). The task has been refreshed."
        case .taskNotFound: "This task no longer exists. It may have been removed by the office."
        case .listUnavailable: "The task list is unavailable. Contact your supervisor."
        case .outcomeUnknown: "Connection dropped. We couldn't confirm the change. Pull to refresh before trying again."
        case .notApplied: "Connection dropped and the change didn't go through. Try again."
        case .unexpected(let message): message
        }
    }
}
