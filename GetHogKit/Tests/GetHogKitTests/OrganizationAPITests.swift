import Foundation
import Testing

@testable import GetHogKit

@Suite("Organizations")
struct OrganizationAPITests {

    @Test("builds the per-organization project listing")
    func organizationProjects() {
        let endpoint = PostHogAPI.organizationProjects(
            organizationID: "018f7e00-0000-7000-8000-000000000001"
        )
        #expect(endpoint.method == "GET")
        #expect(endpoint.path == "/api/organizations/018f7e00-0000-7000-8000-000000000001/projects/")
        #expect(endpoint.query.contains { $0.name == "limit" && $0.value == "100" })
        // `.crud`. Listing projects is not an analytics read and must not be
        // charged to the budget the charts need.
        #expect(endpoint.category == .crud)
    }

    /// The gap this whole feature exists to close: `/api/users/@me/` hydrates
    /// `teams` for **one** organization, and `organizations` is summaries only.
    /// This authored contract example keeps only the relevant keys. The second
    /// organization deliberately carries no `teams` key.
    private static let twoOrganizations = Data(#"""
        {
          "id": 71301,
          "email": "someone@example.com",
          "first_name": "Someone",
          "distinct_id": "abc",
          "team": {"id": 1, "name": "Default project", "api_token": "phc_a", "timezone": "UTC"},
          "organization": {
            "id": "org-a",
            "name": "Automorphism",
            "teams": [
              {"id": 1, "name": "Default project", "api_token": "phc_a", "timezone": "UTC"},
              {"id": 2, "name": "Staging", "api_token": "phc_b", "timezone": "UTC"}
            ]
          },
          "organizations": [
            {"id": "org-a", "name": "Automorphism", "slug": "automorphism",
             "membership_level": 15, "is_active": true},
            {"id": "org-b", "name": "Second Org", "slug": "second-org",
             "membership_level": 8, "is_active": true}
          ]
        }
        """#.utf8)

    @Test("reads both organizations but only one organization's projects")
    func meExposesOrganizationsWithoutTheirProjects() throws {
        let me = try MeResponse.decode(from: Self.twoOrganizations)

        #expect(me.allOrganizations.map(\.id) == ["org-a", "org-b"])
        #expect(me.currentOrganizationID == "org-a")
        // `projects` is the current organization's, and is not — and never was —
        // "every project reachable with this credential". Reaching org-b's
        // projects costs `organizationProjects`.
        #expect(me.projects.map(\.id) == [1, 2])
    }

    /// The current organization leads, and appears exactly once even though it is
    /// present in both `organization` and `organizations`.
    @Test("puts the current organization first without duplicating it")
    func currentOrganizationIsFirstAndUnique() throws {
        let me = try MeResponse.decode(from: Self.twoOrganizations)
        #expect(me.allOrganizations.count == 2)
        #expect(me.allOrganizations.first?.id == "org-a")
        #expect(me.allOrganizations.first?.name == "Automorphism")
        #expect(Set(me.allOrganizations.map(\.id)).count == me.allOrganizations.count)
    }

    /// A response whose `organizations` array omitted the current organization
    /// would leave the switcher listing organizations without listing the one
    /// whose numbers are on screen. The merge makes that state impossible.
    @Test("keeps the current organization even if the array leaves it out")
    func currentOrganizationSurvivesAnIncompleteArray() throws {
        let data = Data(#"""
            {"organization": {"id": "org-a", "name": "Automorphism", "teams": []},
             "organizations": [{"id": "org-b", "name": "Second Org"}]}
            """#.utf8)
        let me = try MeResponse.decode(from: data)
        #expect(me.allOrganizations.map(\.id) == ["org-a", "org-b"])
    }

    /// The single-organization case, which is most users: the merge changes
    /// nothing and nothing in the app ever fetches an organization's projects.
    @Test("leaves a one-organization response exactly as it was")
    func singleOrganizationIsUnchanged() throws {
        let data = Data(#"""
            {"organization": {"id": "org-a", "name": "Automorphism",
              "teams": [{"id": 1, "name": "Default project"}]},
             "organizations": [{"id": "org-a", "name": "Automorphism"}]}
            """#.utf8)
        let me = try MeResponse.decode(from: data)
        #expect(me.allOrganizations.count == 1)
        #expect(me.projects.count == 1)
    }

    /// `ProjectBackwardCompatBasic` — what `/organizations/:id/projects/` returns
    /// — is a superset of `Project`, so the type the app already passes around is
    /// the type that comes back. Decoded here from the document's field set so a
    /// change to `Project` cannot quietly stop fitting it.
    @Test("decodes an organization's project page into the app's own Project")
    func organizationProjectsDecodeAsProjects() throws {
        let data = Data(#"""
            {"count": 2, "next": null, "previous": null, "results": [
              {"id": 7, "uuid": "u", "organization": "org-b", "api_token": "phc_c",
               "name": "Marketing site", "completed_snippet_onboarding": true,
               "ingested_event": true, "is_demo": false, "timezone": "Europe/London",
               "access_control": false, "has_completed_onboarding_for": {}, "project_id": 7},
              {"id": 8, "uuid": "v", "organization": "org-b", "api_token": null,
               "name": null, "timezone": null, "is_demo": true, "project_id": 8}
            ]}
            """#.utf8)
        let page = try JSONDecoder().decode(Page<Project>.self, from: data)

        #expect(page.results.map(\.id) == [7, 8])
        #expect(page.results[0].name == "Marketing site")
        #expect(page.results[0].timezone == "Europe/London")
        // A nameless project still lists, under the fallback `Project` already
        // has — a project that cannot be selected is a project that cannot be
        // switched away from either.
        #expect(page.results[1].name == "Project 8")
        #expect(page.results[1].apiToken == nil)
    }
}
