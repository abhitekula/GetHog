import GetHogKit

struct SessionOverviewFacts {
    let recordingCount: Int
    let withErrorCount: Int
    let withErrors: [SessionRecording]
    let notPlayableCount: Int
    let totalDurationText: String
    let entryPaths: [(path: String, count: Int)]

    init(recordings: [SessionRecording]) {
        recordingCount = recordings.count
        let errored = recordings.filter(\.hasErrors)
        withErrorCount = errored.count
        withErrors = Array(
            errored
                .sorted { $0.consoleErrorCount > $1.consoleErrorCount }
                .prefix(5)
        )
        notPlayableCount = recordings.filter { !$0.isReplayable }.count

        let total = Int(recordings.reduce(0) { $0 + ($1.recordingDuration ?? 0) })
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        totalDurationText = hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"

        var counts: [String: Int] = [:]
        for recording in recordings where recording.startURL != nil {
            counts[recording.pathComponent, default: 0] += 1
        }
        entryPaths = counts
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(5)
            .map { (path: $0.key, count: $0.value) }
    }
}

enum SessionBrandAppearance {
    static func glyph(
        hasErrors: Bool,
        isReplayable: Bool,
        hasFriction: Bool = false
    ) -> BrandObjectGlyph {
        if hasErrors { return .errorSession }
        if hasFriction { return .frictionSession }
        if !isReplayable { return .mobileSession }
        return .session
    }
}
