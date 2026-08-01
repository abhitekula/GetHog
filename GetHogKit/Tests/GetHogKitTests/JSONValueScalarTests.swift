import Foundation
import Testing

@testable import GetHogKit

@Suite("JSONValue scalar rendering")
struct JSONValueScalarTests {

    @Test("renders whole numbers without a decimal point")
    func wholeNumbers() {
        #expect(JSONValue.number(42).stringValue == "42")
        #expect(JSONValue.number(-7).stringValue == "-7")
        #expect(JSONValue.number(0).stringValue == "0")
    }

    @Test("keeps the fraction on non-integral numbers")
    func fractionalNumbers() {
        #expect(JSONValue.number(1.5).stringValue == "1.5")
    }

    // `Int(d)` traps on infinity, and a HogQL aggregate reaches it by dividing by
    // a count that turned out to be zero. Rendering it as "inf" in a table cell
    // tells the reader nothing, so an absent value is the honest answer — the
    // property is already Optional and every caller treats nil as "no value".
    @Test("renders infinity as no value rather than trapping")
    func infinite() {
        #expect(JSONValue.number(.infinity).stringValue == nil)
        #expect(JSONValue.number(-.infinity).stringValue == nil)
    }

    // NaN never reached the `Int` conversion anyway, because it compares unequal
    // to its own `rounded()`. Pinned so a rewrite of the guard cannot quietly
    // reintroduce the trap, and so it renders as absent like the other non-finites
    // instead of the literal text "nan".
    @Test("renders NaN as no value")
    func notANumber() {
        #expect(JSONValue.number(.nan).stringValue == nil)
    }

    // JSON permits `1e300` and `JSONDecoder` gives back a `Double`, so this is
    // reachable from any query result. It is finite, and equal to its own
    // `rounded()`, which is exactly what made the old guard let it through to a
    // trapping `Int(d)`.
    @Test("renders a finite number too large for Int without trapping")
    func farBeyondIntRange() {
        let rendered = JSONValue.number(1e300).stringValue
        #expect(rendered != nil)
        #expect(Double(rendered ?? "") == 1e300)
    }

    // Past 2^53 a Double no longer holds every integer, so a long digit string
    // there claims an exactness the value does not have relative to the JSON that
    // produced it. The cutoff matches `InsightCSV.number`: two different
    // thresholds for rendering the same numbers would be a trap for the next
    // reader.
    @Test("stops using the integer form once Double loses integer precision")
    func beyondExactIntegerPrecision() {
        let rendered = JSONValue.number(1e16).stringValue
        #expect(rendered != nil)
        #expect(rendered != "10000000000000000")
        #expect(Double(rendered ?? "") == 1e16)
    }

    @Test("still uses the integer form just below the precision limit")
    func justInsideExactIntegerPrecision() {
        #expect(JSONValue.number(9_000_000_000_000).stringValue == "9000000000000")
    }
}
