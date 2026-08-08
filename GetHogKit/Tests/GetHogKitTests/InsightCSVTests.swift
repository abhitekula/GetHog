import Foundation
import Testing

import GetHogKit

/// Strips the BOM so a test can assert on the payload without restating it.
private func body(_ csv: String) -> String {
    csv.hasPrefix("\u{FEFF}") ? String(csv.dropFirst()) : csv
}

@Suite("Insight CSV — file format")
struct InsightCSVFormatTests {

    @Test("prefixes a UTF-8 BOM so Excel doesn't mangle non-ASCII labels")
    func emitsBOM() throws {
        let csv = try #require(InsightCSV.encode(.bigNumber(BigNumber(label: "Café ☕", value: 3))))
        #expect(csv.hasPrefix("\u{FEFF}"))
    }

    @Test("separates records with CRLF and ends without a trailing break")
    func usesCRLF() throws {
        let csv = try #require(InsightCSV.encode(.bigNumber(BigNumber(label: "Users", value: 1234))))
        #expect(csv == "\u{FEFF}Label,Value\r\nUsers,1234")
        #expect(!csv.hasSuffix("\r\n"))
    }

    @Test("writes whole numbers without a decimal tail")
    func integralNumbers() throws {
        let csv = try #require(InsightCSV.encode(.bigNumber(BigNumber(label: "n", value: 42))))
        #expect(body(csv) == "Label,Value\r\nn,42")
    }

    @Test("writes fractional numbers unrounded")
    func fractionalNumbers() throws {
        let csv = try #require(InsightCSV.encode(.bigNumber(BigNumber(label: "n", value: 1.5))))
        #expect(body(csv) == "Label,Value\r\nn,1.5")
    }

    @Test("never groups thousands, which would inject a comma mid-field")
    func noGroupingSeparator() throws {
        let csv = try #require(InsightCSV.encode(.bigNumber(BigNumber(label: "n", value: 1234567))))
        #expect(body(csv) == "Label,Value\r\nn,1234567")
    }

    @Test("emits an empty field for a non-finite value rather than crashing")
    func nonFiniteValue() throws {
        let csv = try #require(InsightCSV.encode(.bigNumber(BigNumber(label: "n", value: .nan))))
        #expect(body(csv) == "Label,Value\r\nn,")
    }
}

@Suite("Insight CSV — RFC 4180 quoting")
struct InsightCSVQuotingTests {

    @Test("quotes a field containing a comma")
    func quotesComma() throws {
        // PostHog breakdown values are full of these: "Chrome, Windows",
        // "?utm_source=x,y". Unquoted they shift every later column.
        let csv = try #require(InsightCSV.encode(.barValue([BarValue(label: "Chrome, Windows", value: 3)])))
        #expect(body(csv) == "Label,Value\r\n\"Chrome, Windows\",3")
    }

    @Test("doubles inner quotes and wraps the field")
    func quotesDoubleQuote() throws {
        let csv = try #require(InsightCSV.encode(.barValue([BarValue(label: "He said \"hi\"", value: 1)])))
        #expect(body(csv) == "Label,Value\r\n\"He said \"\"hi\"\"\",1")
    }

    @Test("quotes a field containing a line feed")
    func quotesLineFeed() throws {
        let csv = try #require(InsightCSV.encode(.barValue([BarValue(label: "line\nbreak", value: 2)])))
        #expect(body(csv) == "Label,Value\r\n\"line\nbreak\",2")
    }

    @Test("quotes a field containing a carriage return")
    func quotesCarriageReturn() throws {
        let csv = try #require(InsightCSV.encode(.barValue([BarValue(label: "carriage\rreturn", value: 4)])))
        #expect(body(csv) == "Label,Value\r\n\"carriage\rreturn\",4")
    }

    @Test("quotes a field containing a CRLF pair")
    func quotesCRLF() throws {
        // Swift treats "\r\n" as a single Character, so a naive
        // `contains("\r")` scan misses this and emits a field that breaks the
        // record in two.
        let csv = try #require(InsightCSV.encode(.barValue([BarValue(label: "a\r\nb", value: 6)])))
        #expect(body(csv) == "Label,Value\r\n\"a\r\nb\",6")
    }

    @Test("leaves an ordinary field unquoted")
    func leavesPlainFieldAlone() throws {
        let csv = try #require(InsightCSV.encode(.barValue([BarValue(label: "plain label", value: 5)])))
        #expect(body(csv) == "Label,Value\r\nplain label,5")
    }

    @Test("quotes header cells too, since series labels become column names")
    func quotesHeaderCells() throws {
        let model = InsightRenderModel.timeSeries(
            [Series(label: "pageview, signed in", total: 1, points: [Point(day: "2024-01-01", value: 1)])],
            style: .line
        )
        let csv = try #require(InsightCSV.encode(model))
        #expect(body(csv) == "Date,\"pageview, signed in\"\r\n2024-01-01,1")
    }
}

@Suite("Insight CSV — render model coverage")
struct InsightCSVModelTests {

    @Test("lays time series out wide, one column per series")
    func timeSeriesWide() throws {
        let model = InsightRenderModel.timeSeries(
            [
                Series(label: "A", total: 3, points: [
                    Point(day: "2024-01-01", value: 1),
                    Point(day: "2024-01-02", value: 2),
                ]),
                Series(label: "B", total: 11, points: [
                    Point(day: "2024-01-02", value: 5),
                    Point(day: "2024-01-03", value: 6),
                ]),
            ],
            style: .line
        )
        let rows = try #require(InsightCSV.rows(model))
        #expect(rows == [
            ["Date", "A", "B"],
            ["2024-01-01", "1", ""],
            ["2024-01-02", "2", "5"],
            ["2024-01-03", "", "6"],
        ])
    }

    @Test("leaves an absent measurement empty rather than writing zero")
    func missingIsNotZero() throws {
        let model = InsightRenderModel.timeSeries(
            [
                Series(label: "A", total: 1, points: [Point(day: "2024-01-01", value: 1)]),
                Series(label: "B", total: 0, points: [Point(day: "2024-01-02", value: 0)]),
            ],
            style: .line
        )
        let rows = try #require(InsightCSV.rows(model))
        // Row 1 column B is absent; row 2 column B is a real measured zero. They
        // must not read the same downstream.
        #expect(rows[1] == ["2024-01-01", "1", ""])
        #expect(rows[2] == ["2024-01-02", "", "0"])
    }

    @Test("writes the day string the API reported, not a reformatted date")
    func rawDayStrings() throws {
        // Round-tripping through a formatter would re-zone this to 2023-12-31
        // and silently disagree with what PostHog's own export says.
        let day = "2024-01-01T00:00:00+05:30"
        let model = InsightRenderModel.timeSeries(
            [Series(label: "A", total: 1, points: [Point(day: day, value: 1)])],
            style: .line
        )
        let rows = try #require(InsightCSV.rows(model))
        #expect(rows[1][0] == day)
    }

    @Test("encodes bar values as label/value pairs")
    func barValues() throws {
        let rows = try #require(InsightCSV.rows(.barValue([
            BarValue(label: "Chrome", value: 10),
            BarValue(label: "Safari", value: 4),
        ])))
        #expect(rows == [["Label", "Value"], ["Chrome", "10"], ["Safari", "4"]])
    }

    @Test("encodes a big number as a single row")
    func bigNumber() throws {
        let rows = try #require(InsightCSV.rows(.bigNumber(BigNumber(label: "Users", value: 900))))
        #expect(rows == [["Label", "Value"], ["Users", "900"]])
    }

    @Test("encodes funnel steps with their breakdown group")
    func funnel() throws {
        let rows = try #require(InsightCSV.rows(.funnel([
            FunnelGroup(breakdownValue: "US", steps: [
                FunnelStep(name: "Visited", count: 100, order: 0, averageConversionTime: nil),
                FunnelStep(name: "Signed up", count: 40, order: 1, averageConversionTime: 12.5),
            ]),
        ])))
        #expect(rows == [
            ["Breakdown", "Step", "Order", "Count", "Average conversion time (s)"],
            ["US", "Visited", "0", "100", ""],
            ["US", "Signed up", "1", "40", "12.5"],
        ])
    }

    @Test("leaves the breakdown cell empty for an unbroken funnel")
    func funnelWithoutBreakdown() throws {
        let rows = try #require(InsightCSV.rows(.funnel([
            FunnelGroup(breakdownValue: nil, steps: [
                FunnelStep(name: "Visited", count: 100, order: 0, averageConversionTime: nil),
            ]),
        ])))
        #expect(rows[1] == ["", "Visited", "0", "100", ""])
    }

    @Test("keeps dormant lifecycle counts negative, as returned and as drawn")
    func lifecycle() throws {
        let rows = try #require(InsightCSV.rows(.lifecycle([
            LifecycleSeries(status: .new, label: "new", total: 5, points: [Point(day: "2024-01-01", value: 5)]),
            LifecycleSeries(status: .dormant, label: "dormant", total: -3, points: [Point(day: "2024-01-01", value: -3)]),
        ])))
        #expect(rows == [
            ["Date", "Status", "Count"],
            ["2024-01-01", "New", "5"],
            ["2024-01-01", "Dormant", "-3"],
        ])
    }

    @Test("encodes retention counts alongside the cohort-relative rate")
    func retention() throws {
        let rows = try #require(InsightCSV.rows(.retention(RetentionGrid(cohorts: [
            RetentionCohort(label: "Week 0", date: nil, counts: [100, 50, 25]),
        ]))))
        #expect(rows == [
            ["Cohort", "Interval", "Count", "Rate"],
            ["Week 0", "0", "100", "1"],
            ["Week 0", "1", "50", "0.5"],
            ["Week 0", "2", "25", "0.25"],
        ])
    }

    @Test("rounds the derived retention rate to four places")
    func retentionRateRounding() throws {
        let rows = try #require(InsightCSV.rows(.retention(RetentionGrid(cohorts: [
            RetentionCohort(label: "Week 0", date: nil, counts: [3, 1]),
        ]))))
        #expect(rows[2] == ["Week 0", "1", "1", "0.3333"])
    }

    @Test("encodes stickiness buckets as interval/count rows")
    func stickiness() throws {
        let rows = try #require(InsightCSV.rows(.stickiness([
            StickinessSeries(label: "$pageview", total: 518, buckets: [
                StickinessBucket(intervals: 1, count: 500),
                StickinessBucket(intervals: 2, count: 18),
            ]),
        ])))
        #expect(rows == [
            ["Series", "Intervals", "Count"],
            ["$pageview", "1", "500"],
            ["$pageview", "2", "18"],
        ])
    }

    @Test("encodes path edges with the step prefix already stripped")
    func paths() throws {
        let rows = try #require(InsightCSV.rows(.paths(PathsGraph(edges: [
            PathEdge(rawSource: "1_/home", rawTarget: "2_/pricing", value: 90, averageConversionTime: 4),
            PathEdge(rawSource: "1_/home", rawTarget: "2_/docs", value: 10, averageConversionTime: nil),
        ]))))
        #expect(rows == [
            ["Source", "Target", "Value", "Average conversion time (s)"],
            ["/home", "/pricing", "90", "4"],
            ["/home", "/docs", "10", ""],
        ])
    }

    @Test("refuses to export an unsupported insight")
    func unsupported() {
        // There is no truthful CSV for a chart the app never decoded; an empty
        // file shared to a colleague is worse than no share button.
        #expect(InsightCSV.encode(.unsupported(kind: "FutureInsightKind")) == nil)
        #expect(InsightCSV.rows(.unsupported(kind: "FutureInsightKind")) == nil)
    }

    @Test("emits a header-only file when the insight has no data")
    func emptyModel() throws {
        let rows = try #require(InsightCSV.rows(.barValue([])))
        #expect(rows == [["Label", "Value"]])
    }
}

@Suite("Insight CSV — HogQL results")
struct InsightCSVQueryTests {

    @Test("writes the column list as the header row")
    func columnsHeader() {
        let csv = InsightCSV.encode(columns: ["event", "count"], rows: [])
        #expect(body(csv) == "event,count")
    }

    @Test("renders each JSON scalar as a plain field")
    func scalars() {
        let csv = InsightCSV.encode(
            columns: ["event", "count", "flag"],
            rows: [[.string("pageview, click"), .number(1234), .bool(true)]]
        )
        #expect(body(csv) == "event,count,flag\r\n\"pageview, click\",1234,true")
    }

    @Test("writes null as an empty field, not the text null")
    func nullIsEmpty() {
        let csv = InsightCSV.encode(columns: ["a", "b"], rows: [[.string("x"), .null]])
        #expect(body(csv) == "a,b\r\nx,")
    }

    @Test("pads a short row so columns stay aligned")
    func shortRow() {
        let csv = InsightCSV.encode(columns: ["a", "b", "c"], rows: [[.string("x")]])
        #expect(body(csv) == "a,b,c\r\nx,,")
    }

    @Test("serialises a nested value rather than dropping it")
    func nestedValue() {
        // `properties` comes back as an object; emitting nothing would lose the
        // most interesting column in a lot of HogQL exports.
        let csv = InsightCSV.encode(
            columns: ["properties"],
            rows: [[.object(["k": .string("v")])]]
        )
        #expect(body(csv) == "properties\r\n\"{\"\"k\"\":\"\"v\"\"}\"")
    }
}
