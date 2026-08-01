import Foundation
import Testing

@testable import GetHogKit

/// Dashboard templates.
///
/// The synthetic page keeps seven representative rows. One carries full `tiles`
/// and `variables` arrays while six intentionally omit them, matching the two
/// shapes the list endpoint can return.
///
/// The six rows *without* a `tiles` key are therefore not padding: they pin
/// that a template whose tiles were not serialised must decode, and that "the
/// tiles were not returned" stays distinguishable from "this template has no
/// tiles". Reporting the second when the first is true would put "0 insights"
/// on a card for a template that builds twenty.
@Suite("Dashboard templates")
struct DashboardTemplateTests {

    @Test("decodes the synthetic template list")
    func decodesList() throws {
        let page = try Page<DashboardTemplate>.decode(from: Fixture.data("dashboard_templates.json"))
        #expect(page.count == 60)
        #expect(page.results.count == 7)

        let product = try #require(page.results.first { $0.templateName == "Example App metric 127" })
        #expect(product.id == "018f9000-0000-7000-8000-000000000342")
        #expect(product.scope == "global")
        #expect(product.isFeatured)
        #expect(product.summary == "Example dashboard description 0128")
    }

    /// Artwork URLs use an example-reserved host while still exercising the
    /// gallery path rather than reducing the fixture to text-only cards.
    @Test("keeps the artwork URL")
    func artwork() throws {
        let page = try Page<DashboardTemplate>.decode(from: Fixture.data("dashboard_templates.json"))
        let urls = page.results.compactMap(\.imageURL)
        #expect(urls.count == 7)
        #expect(urls.allSatisfy { SyntheticFixtureCatalog.allowedURLHosts.contains($0.host ?? "") })
    }

    /// Not every template has art. A card that reserved space for an image and
    /// then drew nothing would leave a hole where the description should be.
    @Test("tolerates a template with no artwork at all")
    func missingArtwork() throws {
        let json = """
        {"id": "t1", "template_name": "Bare", "dashboard_description": null,
         "image_url": null, "scope": "team", "is_featured": false, "tags": []}
        """
        let template = try JSONDecoder().decode(DashboardTemplate.self, from: Data(json.utf8))
        #expect(template.imageURL == nil)
        #expect(template.summary == nil)
        #expect(template.scope == "team")
    }

    // MARK: - Tiles

    @Test("reads each tile's insight kind out of the wrapping InsightVizNode")
    func tileKinds() throws {
        let page = try Page<DashboardTemplate>.decode(from: Fixture.data("dashboard_templates.json"))
        let product = try #require(page.results.first { $0.templateName == "Example App metric 127" })

        #expect(product.tileCount == 7)
        #expect(product.tiles?.first?.name == "Example App metric 35")

        // `query.kind` is `InsightVizNode` on every tile; the kind worth showing
        // is one level down in `query.source.kind`. Reading the outer one would
        // label all six tiles identically and say nothing.
        let kinds = product.tiles?.map(\.kindTitle) ?? []
        #expect(kinds == ["Trends", "Trends", "Retention", "Lifecycle", "Trends", "Funnels", "Data table"])
    }

    /// What a template *builds*, in one line, without repeating a kind six
    /// times — which is what a gallery card has room for.
    @Test("summarises a template by its distinct insight kinds, in tile order")
    func distinctKinds() throws {
        let page = try Page<DashboardTemplate>.decode(from: Fixture.data("dashboard_templates.json"))
        let product = try #require(page.results.first { $0.templateName == "Example App metric 127" })
        #expect(product.insightKinds == ["Trends", "Retention", "Lifecycle", "Funnels", "Data table"])
    }

    /// The list response this fixture came from omitted `tiles` for five rows.
    /// nil means "not serialised"; it is not zero, and the card must not claim
    /// a count it was never given.
    @Test("keeps the tile count absent rather than reporting zero when tiles were not serialised")
    func absentTilesAreNotZero() throws {
        let page = try Page<DashboardTemplate>.decode(from: Fixture.data("dashboard_templates.json"))
        let landing = try #require(page.results.first { $0.templateName == "Example App metric 125" })
        #expect(landing.tiles == nil)
        #expect(landing.tileCount == nil)
        #expect(landing.insightKinds.isEmpty)
    }

    @Test("distinguishes a template that genuinely has no tiles")
    func emptyTilesIsZero() throws {
        let json = #"{"id": "t2", "template_name": "Empty", "tiles": [], "variables": []}"#
        let template = try JSONDecoder().decode(DashboardTemplate.self, from: Data(json.utf8))
        #expect(template.tileCount == 0)
    }

    /// A tile query that is not an `InsightVizNode` still has to name itself
    /// rather than render blank — templates ship `DataTableNode` tiles too.
    @Test("falls back to the outer query kind when a tile has no source")
    func tileWithoutSource() throws {
        let json = """
        {"id": "t3", "template_name": "Table", "tiles": [
          {"name": "Recent events", "type": "INSIGHT", "query": {"kind": "DataTableNode"}},
          {"name": "Text card", "type": "TEXT", "body": "Read me"}
        ]}
        """
        let template = try JSONDecoder().decode(DashboardTemplate.self, from: Data(json.utf8))
        let tiles = try #require(template.tiles)
        #expect(tiles[0].kindTitle == "Data table")
        // A text card has no query at all. It is still a tile, and saying so is
        // more honest than dropping it from the count.
        #expect(tiles[1].kindTitle == "Text")
        #expect(template.tileCount == 2)
    }

    // MARK: - Variables

    /// The single most important fact about a template, and the one a table
    /// would hide: its tiles are parameterised and need answers before use.
    @Test("decodes the variables a template would ask the user to fill in")
    func variables() throws {
        let page = try Page<DashboardTemplate>.decode(from: Fixture.data("dashboard_templates.json"))
        let product = try #require(page.results.first { $0.templateName == "Example App metric 127" })

        let variables = try #require(product.variables)
        #expect(variables.count == 3)
        #expect(variables.map(\.id) == ["synthetic-id-0020", "synthetic-id-0021", "synthetic-id-0022"])
        #expect(variables[0].name == "Example App metric 133")
        #expect(variables[0].type == "event")
        #expect(variables[0].isRequired == false)
        #expect(variables[0].summary?.contains("fictional Example App behavior") == true)
    }

    @Test("reports whether a template needs answers before it could be applied")
    func parameterisation() throws {
        let page = try Page<DashboardTemplate>.decode(from: Fixture.data("dashboard_templates.json"))
        let product = try #require(page.results.first { $0.templateName == "Example App metric 127" })
        #expect(product.isParameterised)

        let landing = try #require(page.results.first { $0.templateName == "Example App metric 125" })
        #expect(!landing.isParameterised)
    }

    // MARK: - Ordering

    /// PostHog's own picker orders featured first, then by name. Matching it
    /// means the template someone saw on the web is in the same place here.
    @Test("orders featured templates first, then by name")
    func ordering() throws {
        let page = try Page<DashboardTemplate>.decode(from: Fixture.data("dashboard_templates.json"))
        let ordered = page.results.sorted(by: DashboardTemplate.featuredFirst)

        #expect(ordered.prefix(4).allSatisfy { $0.isFeatured })
        #expect(ordered.suffix(3).allSatisfy { !$0.isFeatured })
        #expect(ordered.map(\.templateName) == [
            "Example App metric 125", "Example App metric 127",
            "Example App metric 137", "Example App metric 139",
            "Example App metric 141", "Example App metric 143",
            "Example App metric 145",
        ])
    }

    // MARK: - Endpoint

    @Test("builds the template list endpoint")
    func endpoint() {
        let endpoint = PostHogAPI.dashboardTemplates(projectID: 1_001)
        #expect(endpoint.path == "/api/projects/1001/dashboard_templates/")
        #expect(endpoint.method == "GET")
        // Static reference material that computes nothing.
        #expect(endpoint.category == .crud)
        #expect(endpoint.query.contains { $0.name == "limit" && $0.value == "50" })
    }
}
