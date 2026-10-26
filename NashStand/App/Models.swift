import Foundation

/// One song in a setlist, as Nash on the Mac shares it. Placeholders have no chart yet.
struct SharedSlot: Codable, Identifiable, Hashable {
    let id: String
    let songId: String
    let title: String
    let key: String
    let pageCount: Int
    /// Whether the chart as printed, without numbers, came along. Missing from older shares.
    let hasOriginal: Bool?

    var hasChart: Bool { !songId.isEmpty }
}

/// A setlist frozen when "Send to iPad" was pressed on the Mac.
struct SharedSetlist: Codable, Identifiable, Hashable {
    let id: String
    let date: String
    let name: String
    let sharedAt: String
    let songs: [SharedSlot]

    var title: String { name.isEmpty ? "Untitled setlist" : name }

    var formattedDate: String {
        guard let day = Self.dayFormatter.date(from: date) else { return date }
        let sameYear = Calendar.current.isDate(day, equalTo: Date(), toGranularity: .year)
        let style = Date.FormatStyle.dateTime.weekday(.abbreviated).month(.abbreviated).day()
        return day.formatted(sameYear ? style : style.year())
    }

    var isPast: Bool { date < Self.dayFormatter.string(from: Date()) }

    var songSummary: String {
        let missing = songs.filter { !$0.hasChart }.count
        let count = "\(songs.count) \(songs.count == 1 ? "song" : "songs")"
        return missing == 0 ? count : "\(count) · \(missing) without charts"
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
