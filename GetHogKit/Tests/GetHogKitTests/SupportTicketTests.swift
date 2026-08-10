import Foundation
import Testing

@testable import GetHogKit

/// PostHog Support — `GET /conversations/tickets/`.
///
/// These fixtures are an authored contract for documented ticket variants. The
/// unknown-value cases matter because adding a channel or workflow state must
/// not make an otherwise valid ticket undecodable.
///
/// Not to be confused with `MaxConversationTests`: `/conversations/` without
/// `/tickets/` is Max's assistant threads, a different product on the same
/// prefix.
@Suite("Support tickets")
struct SupportTicketTests {

    /// Everything in the fixture is dated against this instant, so SLA bands and
    /// snooze windows are decided rather than drifting with the wall clock.
    private static let now = try! Date("2026-01-18T15:00:00.000Z", strategy: .iso8601)

    private func tickets() throws -> [SupportTicket] {
        try Page<SupportTicket>.decode(from: Fixture.data("support_tickets_synthetic.json")).results
    }

    private func ticket(_ number: Int) throws -> SupportTicket {
        try #require(try tickets().first { $0.ticketNumber == number })
    }

    private func demoFixture(_ name: String) throws -> Data {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try Data(
            contentsOf: repositoryRoot.appending(path: "GetHog/Resources/DemoData/\(name)")
        )
    }

    // MARK: - Empty state

    @Test("an empty page decodes")
    func emptyPageDecodes() throws {
        let data = Data(#"{"count":0,"next":null,"previous":null,"results":[]}"#.utf8)
        let page = try Page<SupportTicket>.decode(from: data)
        #expect(page.count == 0)
        #expect(page.results.isEmpty)
    }

    // MARK: - Decoding

    @Test("decodes the documented fields of a ticket")
    func decodesTicket() throws {
        let ticket = try ticket(7_407)
        #expect(ticket.id == "018f9000-0000-7000-8000-000000000001")
        #expect(ticket.status == .open)
        #expect(ticket.priority == .high)
        #expect(ticket.channel == .email)
        #expect(ticket.messageCount == 5)
        #expect(ticket.unreadTeamCount == 4)
        #expect(ticket.emailSubject == "Scheduled report attachments are unreadable")
        #expect(ticket.tags == ["reporting", "attachment"])
        #expect(ticket.person?.name == "Orbit Reader")
        #expect(ticket.sessionID == "018f9000-0000-7000-8000-000000000417")
        #expect(
            ticket.escalationReason
                == "Requester confirmed the file remains corrupted after regeneration"
        )
    }

    @Test("fixture cardinality and source order are explicit")
    func fixtureShape() throws {
        let tickets = try tickets()
        #expect(tickets.count == 9)
        #expect(
            tickets.compactMap(\.ticketNumber)
                == [7_413, 7_407, 7_417, 7_401, 7_411, 7_415, 7_409, 7_405, 7_403]
        )
    }

    /// Demo mode is a product surface, so its Support payload must exercise the
    /// same authored conversation as the package contract. Generated numeric
    /// identifiers used as counts make the inbox render hundreds of thousands
    /// of unread messages and hide the message-thread relationship this demo is
    /// meant to prove.
    @Test("the app demo preserves the curated Support inbox and matching thread")
    func appDemoPreservesCuratedSupportConversation() throws {
        let ticketPage = try Page<SupportTicket>.decode(
            from: demoFixture("conversations_tickets.json")
        )
        let messagePage = try Page<TicketMessage>.decode(
            from: demoFixture("conversations_ticket_messages.json")
        )

        #expect(ticketPage.count == 9)
        #expect(ticketPage.results.count == 9)
        #expect(ticketPage.results.allSatisfy { $0.messageCount < 1_000 })
        #expect(ticketPage.results.allSatisfy { $0.unreadTeamCount < 100 })

        let selected = try #require(ticketPage.results.first { $0.ticketNumber == 7_407 })
        #expect(selected.id == "018f9000-0000-7000-8000-000000000001")
        #expect(selected.messageCount == 5)
        #expect(selected.unreadTeamCount == 4)

        #expect(messagePage.count == 5)
        #expect(
            messagePage.results.map(\.id) == [
                "018f9000-0000-7000-8000-000000000500",
                "018f9000-0000-7000-8000-000000000501",
                "018f9000-0000-7000-8000-000000000502",
                "018f9000-0000-7000-8000-000000000503",
                "018f9000-0000-7000-8000-000000000504",
            ]
        )
        #expect(
            messagePage.results.first?.text
                == "The downloaded archive opens, but every chart image is blank."
        )
        #expect(messagePage.results[2].author == .ai)
        #expect(messagePage.results[2].authorName == "Atlas")
    }

    /// `assignee` is an object even when nobody is assigned — the `TicketAssignment`
    /// component's `id`, `user` and `role` are all nullable and all `required`.
    /// A row that showed "assigned to (blank)" for that shape would be worse than
    /// one that says "Unassigned".
    @Test("an assignment object with a null user reads as unassigned")
    func emptyAssignmentIsUnassigned() throws {
        #expect(try ticket(7_403).assigneeName == nil)
        // A role assignment is an assignment: the queue has an owner, it is just
        // not a person.
        #expect(try ticket(7_401).assigneeName == "Reliability rotation")
        #expect(try ticket(7_407).assigneeName == "Queue Operator")
    }

    /// Three of the fields this model reads have **no type at all** in the
    /// schema — `tags` is `{"items": {}}`, `cc_participants` and `anonymous_traits`
    /// carry only `readOnly`. Modelling them strictly would be inventing a
    /// guarantee the API does not make, so anything that is not a string is
    /// dropped rather than crashing the page it arrived on.
    @Test("untyped fields degrade instead of throwing")
    func untypedFieldsAreLenient() throws {
        // `tags: [{"label": "restricted"}]` — objects, not strings.
        #expect(try ticket(7_409).tags.isEmpty)
        #expect(try ticket(7_407).ccParticipants == ["ops@example.com"])
        #expect(try ticket(7_409).ccParticipants.isEmpty)
        #expect(try ticket(7_413).ccParticipants.isEmpty)
        #expect(try ticket(7_417).zendeskTicketID == 42_017)
        #expect(try ticket(7_411).anonymousTraits["email"] == "telescope.viewer@example.net")

        let raw = try #require(
            JSONSerialization.jsonObject(with: Fixture.data("support_tickets_synthetic.json"))
                as? [String: Any]
        )
        let rows = try #require(raw["results"] as? [[String: Any]])
        let nullCC = try #require(rows.first { ($0["ticket_number"] as? Int) == 7_413 })
        #expect(nullCC["cc_participants"] is NSNull)
    }

    /// `identity_verified` is genuinely three-valued and the schema says so:
    /// "True when verified, false when assessed but not attested, null when
    /// unknown (e.g. created before this signal existed)." Collapsing null into
    /// false would report a ticket as failing a trust check that was never run.
    @Test("identity verification keeps its third state")
    func identityVerifiedIsTriState() throws {
        #expect(try ticket(7_407).identityVerified == true)
        #expect(try ticket(7_403).identityVerified == false)
        #expect(try ticket(7_411).identityVerified == nil)
    }

    // MARK: - Quarantined enums

    @Test("an undocumented status, priority or channel keeps its raw value")
    func unknownEnumsAreQuarantined() throws {
        let ticket = try ticket(7_409)
        #expect(ticket.status == .unknown("awaiting_security_review"))
        #expect(ticket.priority == .unknown("immediate"))
        #expect(ticket.channel == .unknown("community_portal"))
        // And the row still has something true to print.
        #expect(ticket.status.title == "Awaiting security review")
        #expect(ticket.priority.title == "Immediate")
        #expect(ticket.channel.title == "Community portal")
    }

    /// `priority` is `oneOf [TicketPriorityEnum, BlankEnum, NullEnum]`, so the
    /// empty string is a documented value and distinct from an unrecognised one.
    /// Both mean "nobody set a priority", which is not the same as "low" — the
    /// screen says "Not set" rather than inventing a band.
    @Test("a blank or absent priority is unset, not unknown")
    func blankPriorityIsUnset() throws {
        #expect(try ticket(7_413).priority == .unset)
        #expect(try ticket(7_401).priority == .unset)
        #expect(try ticket(7_413).priority.title == "Not set")
    }

    // MARK: - SLA

    /// The bands are PostHog's, not this app's: the `sla` query parameter on this
    /// endpoint documents `breached` = past `sla_due_at`, `at-risk` = due within
    /// the next hour, `on-track` = more than an hour remaining. Inventing a
    /// different threshold would put the app's idea of "at risk" out of step with
    /// the filter the same team uses in the console.
    @Test("SLA bands follow PostHog's own thresholds")
    func slaBands() throws {
        #expect(try ticket(7_407).slaState(now: Self.now) == .breached)
        #expect(try ticket(7_403).slaState(now: Self.now) == .atRisk)
        #expect(try ticket(7_413).slaState(now: Self.now) == .onTrack)
        // "Null means no SLA" — an absent deadline is not a met one.
        #expect(try ticket(7_411).slaState(now: Self.now) == .none)
    }

    // MARK: - Ordering

    /// The whole ranking, in one assertion, because the interesting part is how
    /// the keys break each other's ties rather than any one of them alone.
    ///
    /// 7407 breached · 7403 at-risk · 7411 unread+critical · 7401 unread+unset ·
    /// 7417 read+low · 7409 read+unknown · 7413 read+unset · 7405 snoozed ·
    /// 7415 resolved.
    @Test("ranks by SLA, then unread, then priority, then recency")
    func ordering() throws {
        let ordered = SupportTicket.triaged(try tickets(), now: Self.now)
        #expect(
            ordered.map(\.ticketNumber)
                == [7_407, 7_403, 7_411, 7_401, 7_417, 7_409, 7_413, 7_405, 7_415]
        )
    }

    /// A resolved ticket cannot be urgent, however loud it is. This one carries
    /// the highest `unread_team_count` in the fixture and still sorts last —
    /// which is the case that stops the inbox being led by its noisiest closed
    /// thread.
    @Test("resolved sinks below everything, even with the most unread messages")
    func resolvedSinksDespiteUnread() throws {
        let ordered = SupportTicket.triaged(try tickets(), now: Self.now)
        let resolved = try #require(ordered.last)
        #expect(resolved.ticketNumber == 7_415)
        #expect(resolved.unreadTeamCount == 9)
    }

    /// Snoozing is a human saying "not now". Honouring it is the difference
    /// between a queue and a list.
    @Test("a snoozed ticket drops out of the live band until its snooze expires")
    func snoozeIsHonoured() throws {
        let snoozed = try ticket(7_405)
        #expect(snoozed.isSnoozed(now: Self.now))
        // The same ticket, read after the snooze runs out, is live again — and
        // it has an SLA, so it climbs.
        let later = try #require(Date("2026-01-19T10:00:00.000Z", strategy: .iso8601) as Date?)
        #expect(!snoozed.isSnoozed(now: later))
    }

    /// Unread outranks priority deliberately: `unread_team_count` says something
    /// arrived that nobody has read, and `priority` is a judgement made earlier
    /// that a later message may already have overtaken.
    @Test("an unread ticket outranks a read one of higher priority")
    func unreadOutranksPriority() throws {
        let unreadUnset = try ticket(7_401)   // unread 1, priority unset
        let readUnknown = try ticket(7_409)   // unread 0, priority unrecognised
        #expect(SupportTicket.mostUrgentFirst(unreadUnset, readUnknown, now: Self.now))
        #expect(!SupportTicket.mostUrgentFirst(readUnknown, unreadUnset, now: Self.now))
    }

    /// Counting the messages rather than the tickets: an inbox whose unread total
    /// is invisible is not an inbox.
    @Test("sums unread messages across the tickets that are still open")
    func unreadTotal() throws {
        // Sum every non-resolved row, including a snoozed ticket.
        // The resolved ticket's 9 are excluded, matching what PostHog's own
        // `/unread_count/` sub-resource documents itself as summing.
        #expect(SupportTicket.unreadTeamTotal(try tickets()) == 19)
    }

    // MARK: - Presentation

    @Test("names a ticket by its subject, its requester, or its number — in that order")
    func displayTitle() throws {
        #expect(try ticket(7_407).displayTitle == "Scheduled report attachments are unreadable")
        // No email subject; the widget submitter gave a name.
        #expect(try ticket(7_411).displayTitle == "Telescope Viewer")
        // Neither: a person row exists but its name is empty, which PostHog
        // serialises for an unidentified person.
        #expect(try ticket(7_401).displayTitle == "Ticket #7401")
    }

    /// `last_message_text` is the row's only content, and it arrives as raw body
    /// text — newlines, quoted replies and all.
    @Test("collapses the last message into one scannable line")
    func snippet() throws {
        #expect(try ticket(7_407).snippet == "The downloaded archive opens, but every chart image is blank.")
        // An empty string is absence, not an empty line in the row.
        #expect(try ticket(7_413).snippet == nil)
    }

    // MARK: - Messages

    @Test("decodes a thread, including the private note and the AI author")
    func decodesMessages() throws {
        let page = try Page<TicketMessage>.decode(
            from: Fixture.data("support_ticket_messages_synthetic.json")
        )
        let requesterName = try ticket(7_407).person?.name
        #expect(page.count == 5)
        #expect(page.results.count == 5)
        #expect(page.results[0].author == .customer)
        #expect(page.results[0].authorName == requesterName)
        #expect(page.results[1].author == .support)
        #expect(page.results[1].isPrivate)
        // The schema documents this value as "AI", capitalised, while every other
        // enum on this endpoint is a lowercase slug.
        #expect(page.results[2].author == .ai)
        #expect(page.results[2].authorName == "Atlas")
        #expect(try ticket(7_407).messageCount == page.count)
    }

    /// A message whose body is a TipTap image has an empty `content`. Rendering
    /// that as a blank bubble makes the thread look truncated; it is named
    /// instead, the same way `MaxMessage` names a chart it cannot draw.
    @Test("a rich-content-only message is named rather than left blank")
    func richContentOnlyMessage() throws {
        let page = try Page<TicketMessage>.decode(
            from: Fixture.data("support_ticket_messages_synthetic.json")
        )
        let last = try #require(page.results.last)
        #expect(last.text == nil)
        #expect(last.hasRichContent)
    }

    @Test("an unrecognised author keeps its raw value rather than becoming support")
    func unknownAuthor() throws {
        let json = """
        {"id":"1","content":"hi","rich_content":null,"author_type":"webhook",
         "author_name":"Zapier","is_private":false,"created_at":"2026-01-14T12:00:00.000Z"}
        """
        let message = try JSONDecoder().decode(TicketMessage.self, from: Data(json.utf8))
        #expect(message.author == .unknown("webhook"))
    }

    // MARK: - Endpoints

    /// The collision this whole feature has to survive. `/conversations/` is Max;
    /// `/conversations/tickets/` is Support. Two products, one prefix.
    @Test("the ticket endpoints sit under /conversations/tickets/, not /conversations/")
    func endpointPaths() {
        let list = PostHogAPI.supportTickets(projectID: 1_001)
        #expect(list.path == "/api/projects/1001/conversations/tickets/")
        #expect(list.path != PostHogAPI.conversations(projectID: 1_001).path)
        // A plain listing that computes nothing must not bill against the query
        // budget, which is the scarcest of the three.
        #expect(list.category == .crud)

        let messages = PostHogAPI.supportTicketMessages(projectID: 1_001, ticketID: "abc")
        #expect(messages.path == "/api/projects/1001/conversations/tickets/abc/messages/")
    }

    /// The list is re-ranked on the client because the server cannot express this
    /// ordering — `order_by` accepts only `created_at`, `sla_due_at`,
    /// `ticket_number` and `updated_at`, so neither `priority` nor
    /// `unread_team_count` is available server-side. Asking for `-updated_at`
    /// explicitly rather than relying on the documented default keeps the page
    /// this client re-ranks from changing under it.
    @Test("asks for the most recently active page explicitly")
    func listOrdering() {
        let list = PostHogAPI.supportTickets(projectID: 1_001, limit: 50)
        #expect(list.query.contains(URLQueryItem(name: "order_by", value: "-updated_at")))
        #expect(list.query.contains(URLQueryItem(name: "limit", value: "50")))
    }
}
