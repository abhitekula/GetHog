import Foundation

/// One jump target in a VoiceOver rotor, for the case where the entry's label
/// is not a property of the row it lands on.
///
/// SwiftUI's data-driven `accessibilityRotor(_:entries:entryLabel:)` reads its
/// label from a key path on the entry, which covers "jump between the error
/// lines" — severity and message both belong to the line. It does not cover
/// "jump to the head of each time bucket" or "jump to the first dashboard": the
/// word being navigated by belongs to the *grouping*, and the row it lands on
/// knows nothing about the group it fell into. This carries the two apart.
///
/// `id` is always the identity the screen's own `ForEach` uses for that row —
/// never a fresh one. A rotor entry whose id matches no rendered row is an entry
/// that jumps nowhere, and nothing about the code would say so.
///
/// **Two things a rotor needs that nothing in the type system checks**, both
/// measured in `AccessibilityRotorTests` and both silent when broken — the rotor
/// still appears in VoiceOver's list, correctly named, and does nothing:
///
/// - The row the entry resolves to must be a `NavigationLink`. Measured: an
///   identical list of bare `DataRow`s, same ids, same modifier, returns **zero**
///   entries.
/// - The rotor modifier must be applied to the `List` itself. Measured: one
///   level further out — outside the enclosing `NavigationStack` — it registers
///   and returns zero entries.
///
/// So a rotor is never finished when it compiles. Add one and add the test that
/// drives it, or the next person will read a comment claiming an accessibility
/// affordance that is not there.
struct RotorAnchor: Identifiable, Hashable {
    let id: String
    let label: String
}
