import GetHogKit

/// Facts derived only from the event rows the feed already holds.
///
/// No request is made here, and none of these values describe project history.
struct EventOverviewFacts {
    let eventCount: Int
    let kindCount: Int
    let peopleCount: Int
    let reach: String?
    let ranked: [(name: String, count: Int)]
    let custom: [(name: String, count: Int)]

    init(events: [EventRow]) {
        eventCount = events.count
        let counts = events.reduce(into: [String: Int]()) {
            $0[$1.event, default: 0] += 1
        }
        kindCount = counts.count
        peopleCount = Set(events.compactMap(\.distinctID)).count
        ranked = counts
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .map { (name: $0.key, count: $0.value) }
        custom = ranked.filter { EventAppearance.isCustom($0.name) }

        let stamps = events.compactMap(\.timestamp)
        if let oldest = stamps.min(), let newest = stamps.max(), newest > oldest {
            let seconds = Int(newest.timeIntervalSince(oldest))
            if seconds < 3_600 { reach = "\(max(1, seconds / 60))m" }
            else if seconds < 86_400 { reach = "\(seconds / 3_600)h" }
            else { reach = "\(seconds / 86_400)d" }
        } else {
            reach = nil
        }
    }
}
