import Foundation
import Testing

@testable import GetHogKit

// Tier 3 covers the three "plumbing" surfaces: LLM analytics, the data
// warehouse, and the CDP pipeline functions. Every expectation below is pinned
// to the documented API response shape, because all three of these payloads
// disagree with the obvious reading of PostHog's own docs in at least one place.

@Suite("LLM analytics")
struct LLMAnalyticsTests {

    @Test("decodes traces even though results are objects, not positional rows")
    func decodesTraces() throws {
        // `/query/` responses are normally column-oriented — `results` is an
        // array of positional arrays indexed by `columns`. TracesQuery is not:
        // it returns objects, so the shared `QueryResponse` decoder cannot read
        // it and this response needs its own type.
        let response = try LLMTracesResponse.decode(from: Fixture.data("llm_traces.json"))

        #expect(response.traces.count == 5)
        #expect(!response.hasMore)

        let first = try #require(response.traces.first)
        #expect(first.id == "trace-example-summary")
        #expect(first.distinctID == "system:example-summary")
        #expect(first.createdAt != nil)
        #expect(first.totalLatency == 1.24)
        #expect(first.inputTokens == 420)
        #expect(first.outputTokens == 80)
        #expect(first.totalCost == 0.0042)
        #expect(response.traces.last?.traceName == nil)
        #expect(response.traces.last?.displayName == "trace-exampl…")
    }

    @Test("keys are camelCase and do not match the snake_case column list")
    func keysDisagreeWithColumns() throws {
        // The `columns` array advertises `first_distinct_id`, `first_timestamp`
        // and friends; the row objects are keyed `distinctId` and `createdAt`.
        // Decoding off `columns` would silently produce empty traces.
        let raw = try JSONSerialization.jsonObject(
            with: Fixture.data("llm_traces.json")
        ) as? [String: Any]
        let columns = try #require(raw?["columns"] as? [String])
        let firstRow = try #require((raw?["results"] as? [[String: Any]])?.first)

        #expect(columns.contains("first_distinct_id"))
        #expect(firstRow["first_distinct_id"] == nil)
        #expect(firstRow["distinctId"] != nil)
    }

    @Test("reports an empty event list rather than inventing spans")
    func emptyEvents() throws {
        let response = try LLMTracesResponse.decode(from: Fixture.data("llm_traces.json"))
        // The fixture deliberately carries no child events, so the UI must say
        // so plainly instead of rendering an empty timeline that looks broken.
        #expect(response.traces.allSatisfy { $0.events.isEmpty })
    }

    @Test("decodes child events in both shapes the API can emit")
    func decodesEvents() throws {
        // This pins the two serialisations the HogQL `groupArray(tuple(...))` can produce: the
        // object form the frontend consumes, and the raw positional tuple.
        let json = """
        {"results": [
          {"id": "t1", "events": [
            {"id": "e1", "event": "$ai_generation", "createdAt": "2026-01-13T07:19:25+00:00",
             "properties": {"$ai_model": "gpt-4"}},
            ["e2", "$ai_span", "2026-01-12T07:19:26.000000+00:00", {}]
          ]}
        ]}
        """
        let response = try LLMTracesResponse.decode(from: Data(json.utf8))
        let trace = try #require(response.traces.first)

        #expect(trace.events.count == 2)
        #expect(trace.events[0].id == "e1")
        #expect(trace.events[0].event == "$ai_generation")
        #expect(trace.events[0].timestamp != nil)
        #expect(trace.events[1].event == "$ai_span")
    }

    @Test("totals cost and tokens across the page")
    func totals() throws {
        let response = try LLMTracesResponse.decode(from: Fixture.data("llm_traces.json"))
        #expect(abs(response.totalCost - 0.0364) < 0.000001)
        #expect(response.totalInputTokens == 3_190)
        #expect(response.totalOutputTokens == 574)
        #expect(response.totalTokens == 3_764)
    }

    @Test("ranks by cost when costs exist")
    func ranksByCost() throws {
        let response = try LLMTracesResponse.decode(from: Fixture.data("llm_traces.json"))
        let ranked = response.ranked
        #expect(ranked.first?.id == "trace-example-analysis")
        #expect(ranked.first?.totalCost == 0.0187)
    }

    @Test("falls back to recency when no trace reports a cost")
    func ranksByRecencyWithoutCosts() throws {
        // Costs are null for any project whose SDK does not send token usage,
        // and a list sorted by a column of zeroes is arbitrary. Recency is the
        // honest fallback.
        let json = """
        {"results": [
          {"id": "old", "createdAt": "2025-12-15T00:00:00.000000+00:00", "totalCost": null},
          {"id": "new", "createdAt": "2026-01-03T00:00:00.000000+00:00", "totalCost": null}
        ]}
        """
        let response = try LLMTracesResponse.decode(from: Data(json.utf8))
        #expect(response.totalCost == 0)
        #expect(response.ranked.map(\.id) == ["new", "old"])
    }

    @Test("maps each date range to the API's relative window")
    func dateRanges() {
        #expect(LLMDateRange.day.dateFrom == "-24h")
        #expect(LLMDateRange.week.dateFrom == "-7d")
        #expect(LLMDateRange.month.dateFrom == "-30d")
        #expect(LLMDateRange.allCases.count == 3)
    }
}

@Suite("Data warehouse")
struct WarehouseTests {

    @Test("decodes tables with their column schema")
    func decodesTables() throws {
        let page = try Page<WarehouseTable>.decode(from: Fixture.data("warehouse_tables.json"))
        let table = try #require(page.results.first)

        #expect(table.id == "018f9000-0000-7000-8000-000000000264")
        #expect(table.name == "demo_accounts")
        #expect(table.hogqlName == "demo.accounts")
        #expect(table.format == "DeltaS3Wrapper")
        #expect(table.columns.count == 10)
        #expect(table.columns.first?.name == "Account key")
        #expect(table.columns.first?.type == "string")
    }

    @Test("treats a missing row count as unknown, not zero")
    func missingRowCount() throws {
        // `row_count` is absent from this payload entirely. Defaulting it to 0
        // would display an empty table that in fact has rows.
        let page = try Page<WarehouseTable>.decode(from: Fixture.data("warehouse_tables.json"))
        #expect(page.results.first?.rowCount == nil)
    }

    @Test("carries the nested source and schema a table came from")
    func nestedSource() throws {
        let page = try Page<WarehouseTable>.decode(from: Fixture.data("warehouse_tables.json"))
        let table = try #require(page.results.first)

        #expect(table.sourceType == "S3")
        #expect(table.schemaName == "accounts")
        #expect(table.lastSyncedAt != nil)
        // The source embedded in a table row reports "Running" while the
        // stand-alone source endpoint reports "Completed" for the same id: the
        // nested copy is a snapshot from sync time, so the sources list wins.
        #expect(table.sourceStatus == "Running")
    }

    @Test("decodes sources with their schemas")
    func decodesSources() throws {
        let page = try Page<ExternalDataSource>.decode(
            from: Fixture.data("external_data_sources.json")
        )
        let source = try #require(page.results.first)

        #expect(page.results.count == 2)
        #expect(source.id == "018f9000-0000-7000-8000-000000000222")
        #expect(source.sourceType == "S3")
        #expect(source.status == "Completed")
        #expect(source.prefix == nil)
        #expect(source.latestError == nil)
        #expect(source.lastRunAt != nil)
        #expect(source.schemas.count == 10)
        #expect(source.syncingSchemaCount == 1)

        let github = try #require(page.results.last)
        #expect(github.id == "018f9000-0000-7000-8000-000000000223")
        #expect(github.sourceType == "Github")
        #expect(github.status == "Completed")
        #expect(github.prefix == "example_")

        let raw = try #require(
            JSONSerialization.jsonObject(with: Fixture.data("external_data_sources.json"))
                as? [String: Any]
        )
        let rawSources = try #require(raw["results"] as? [[String: Any]])
        let rawGithub = try #require(rawSources.last)
        let inputs = try #require(rawGithub["job_inputs"] as? [String: Any])
        let auth = try #require(inputs["auth_method"] as? [String: Any])
        #expect(inputs["repository"] as? String == "example-labs/telemetry-sandbox")
        #expect(auth["github_integration_id"] as? String == "integration-example-204")
    }

    @Test("names a source by its prefix when one is set")
    func displayName() throws {
        let page = try Page<ExternalDataSource>.decode(
            from: Fixture.data("external_data_sources.json")
        )
        // No prefix in this fixture, so the type is the only name available.
        #expect(page.results.first?.displayName == "S3")

        let prefixed = try JSONDecoder().decode(
            ExternalDataSource.self,
            from: Data(#"{"id":"x","source_type":"Stripe","status":"Completed","prefix":"eu_"}"#.utf8)
        )
        #expect(prefixed.displayName == "Stripe (eu_)")
    }

    @Test("classifies sync health so a broken source is unmistakable")
    func syncHealth() throws {
        func source(_ json: String) throws -> ExternalDataSource {
            try JSONDecoder().decode(ExternalDataSource.self, from: Data(json.utf8))
        }

        #expect(try source(#"{"id":"a","source_type":"S","status":"Completed"}"#).health == .healthy)
        #expect(try source(#"{"id":"a","source_type":"S","status":"Running"}"#).health == .running)
        #expect(try source(#"{"id":"a","source_type":"S","status":"Error"}"#).health == .failed)
        #expect(try source(#"{"id":"a","source_type":"S","status":"Failed"}"#).health == .failed)
        #expect(try source(#"{"id":"a","source_type":"S","status":"Paused"}"#).health == .paused)
        // A source can report success while carrying an error from its last run.
        #expect(
            try source(#"{"id":"a","source_type":"S","status":"Completed","latest_error":"401"}"#)
                .health == .failed
        )
        // An unrecognised state must not silently read as healthy.
        #expect(try source(#"{"id":"a","source_type":"S","status":"Wat"}"#).health == .unknown)
    }

    @Test("counts a source with nothing left to sync as paused")
    func pausedWhenNothingSyncs() throws {
        let page = try Page<ExternalDataSource>.decode(
            from: Fixture.data("external_data_sources.json")
        )
        let source = try #require(page.results.first)
        // One schema still syncs here, so the source is still doing work.
        #expect(source.health == .healthy)

        let idle = try JSONDecoder().decode(
            ExternalDataSource.self,
            from: Data(#"""
            {"id":"a","source_type":"S","status":"Completed",
             "schemas":[{"id":"s1","name":"one","should_sync":false}]}
            """#.utf8)
        )
        #expect(idle.syncingSchemaCount == 0)
        #expect(idle.health == .paused)
    }
}

@Suite("Pipelines")
struct PipelineTests {

    @Test("decodes hog functions")
    func decodesFunctions() throws {
        let page = try Page<HogFunction>.decode(from: Fixture.data("hog_functions.json"))
        #expect(page.results.count == 3)

        let first = try #require(page.results.first)
        #expect(first.id == "hog-example-normalize-region")
        #expect(first.name == "Normalize example region")
        #expect(first.type == "transformation")
        #expect(first.enabled)
        #expect(first.description == "Adds a fictional region label to demo events.")
    }

    @Test("reads status as an object, not a scalar")
    func statusIsAnObject() throws {
        // `status` is `{"state": 1, "tokens": 10000}`. Decoding it as a string
        // or an int throws and would take the whole page down with it.
        let page = try Page<HogFunction>.decode(from: Fixture.data("hog_functions.json"))
        #expect(page.results.map(\.state) == [.degraded, .disabledTemporarily, .healthy])

        let scalar = try JSONDecoder().decode(
            HogFunction.self,
            from: Data(#"{"id":"a","name":"n","type":"destination","status":2}"#.utf8)
        )
        #expect(scalar.state == .degraded)

        let absent = try JSONDecoder().decode(
            HogFunction.self,
            from: Data(#"{"id":"a","name":"n","type":"destination"}"#.utf8)
        )
        #expect(absent.state == .unknown)
    }

    @Test("folds PostHog's destination variants into one group")
    func kindGrouping() throws {
        let page = try Page<HogFunction>.decode(from: Fixture.data("hog_functions.json"))
        let kinds = page.results.map(\.kind)

        // The fixture uses `internal_destination`, not `destination`, so a
        // literal match on "destination" would leave this row ungrouped.
        #expect(kinds.contains(.transformation))
        #expect(kinds.contains(.destination))
        #expect(HogFunctionKind(rawType: "site_destination") == .destination)
        #expect(HogFunctionKind(rawType: "source_webhook") == .other)
    }

    @Test("groups functions for display in a stable order")
    func groups() throws {
        let page = try Page<HogFunction>.decode(from: Fixture.data("hog_functions.json"))
        let groups = HogFunctionKind.grouped(page.results)

        #expect(groups.map(\.kind) == [.transformation, .destination])
        #expect(groups.first?.functions.count == 2)
    }
}
