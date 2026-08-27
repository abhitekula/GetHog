enum SyntheticFixtureCatalog {
    static let organizationID = "018f0000-0000-7000-8000-000000000001"
    static let projectID = 1001
    static let primaryPersonID = "018f0000-0000-7000-8000-000000000101"
    static let primaryDistinctID = "person-example-001"
    static let primarySessionID = "018f1000-0000-7000-8000-000000000001"
    static let baseTimestamp = "2026-01-15T12:00:00.000Z"
    static let allowedURLHosts: Set<String> = [
        "example.com", "example.invalid", "app.example.com", "cdn.example.com",
    ]

    /// Every UUID committed in a deterministic fixture or test. New UUIDs must be
    /// declared here rather than inheriting trust from a shared prefix.
    static let allowedUUIDs: Set<String> = {
        var values: Set<String> = []

        func add(_ prefix: String, _ suffixes: [Int64]) {
            for suffix in suffixes {
                let raw = String(suffix)
                let padded = String(repeating: "0", count: 12 - raw.count) + raw
                values.insert("\(prefix)-0000-7000-8000-\(padded)")
            }
        }

        add("018f0000", Array(1...6) + Array(101...105) + [201]
            + Array(3_101...3_104) + Array(3_201...3_204) + [999_999_999_999])
        add("018f1000", Array(1...5) + [10, 11, 99] + Array(201...203))
        add("018f2000", [1, 2] + Array(101...103) + Array(201...202)
            + Array(401...402) + Array(411...413) + Array(501...503)
            + Array(601...603) + Array(611...615))
        add("018f3300", [801, 802, 811, 812] + Array(901...906) + Array(911...913) + [999])
        add("018f4000", Array(1...4))
        add("018f4400", [401])
        add("018f6600", [601])
        add("018f7e00", Array(1...6))
        add("018f9000", Array(1...508) + Array(600...602) + Array(710...712) + [720])
        add("018f9a00", Array(1...5) + Array(7...10) + Array(12...15)
            + Array(17...19) + [21, 22])
        return values
    }()

    /// Numeric identifiers committed in API-shaped JSON. Counts, durations,
    /// status codes and other measurements are intentionally not identifiers and
    /// are validated by their own model tests instead.
    static let allowedNumericIdentifiers: Set<Int> = {
        var values: Set<Int> = [
            -719, -607, -521, -409, -307, -203, -101,
            -7, -6, -5, -4, -3, -2, -1,
            1_001, 1_301,
            7_201, 7_202, 7_203, 7_204,
            7_301, 7_302, 7_303,
            8_204,
            42_017, 48_017, 48_029,
            73_508,
            77_021, 77_022,
            79_001, 79_002,
            700_001, 700_002, 700_006, 700_009, 700_022, 700_027,
            700_034, 700_037, 700_040, 700_067, 700_072, 700_081,
            700_101, 700_102,
            700_201, 700_202,
            700_501, 700_521, 700_537, 700_541, 700_553, 700_558,
            700_567, 700_579, 700_593, 700_607, 880_101, 880_303,
            701_778,
            710_031, 710_399,
            721_001, 721_002, 721_011, 721_012,
            721_021, 721_022, 721_023, 721_024, 721_025,
            721_101, 721_104, 721_201, 721_202,
            722_001, 722_002, 722_011, 722_021, 722_022,
            722_101, 722_104, 722_106,
            730_004, 730_081, 730_082, 730_083, 730_084, 730_085,
            730_202, 730_401, 730_404, 730_499, 730_501,
            810_501,
            910_201,
            3_035_497, 3_078_305, 3_201_675, 3_201_677,
            3_201_679, 3_201_681, 3_328_599,
        ]

        values.formUnion(700_009...700_020)
        values.formUnion(700_043...700_048)
        values.formUnion(700_072...700_079)
        values.formUnion(700_401...700_404)
        values.formUnion(700_501...700_506)
        values.formUnion(700_511...700_513)
        values.formUnion(700_600...700_612)
        values.formUnion(810_600...810_612)
        values.formUnion(710_101...710_104)
        values.formUnion(710_301...710_308)
        values.formUnion(711_01...711_04)
        values.formUnion(731_01...731_04)
        values.formUnion(741_01...741_04)
        values.formUnion(771_00...771_06)
        values.formUnion(725_101...725_111)
        // Dashboard 725_102's committed HogQL gallery. Tile and insight IDs
        // have their own catalog ranges so none can be mistaken for captured
        // tenant identifiers merely because the values look well structured.
        values.formUnion(726_001...726_011)
        values.formUnion(727_002...727_011)
        values.formUnion(401...402)
        values.formUnion(stride(from: 405, through: 450, by: 4))
        values.formUnion(stride(from: 406, through: 450, by: 4))
        values.formUnion([482, 1_773])
        values.formUnion([209, 211, 213, 215, 217, 219, 221, 223])
        values.formUnion(stride(from: 7_401, through: 7_417, by: 2))
        return values
    }()

    static let allowedSourceProjectIDs: Set<Int> = [0, 1, 2, 8, 9, 42, 77, 123, projectID, 1_002]

    static let allowedSensitiveColumnValues: Set<String> = [
        "", "Automation Browser", "FixtureFox", "Mockwave", "ScriptShell", "Testbird",
        "Mira Lane", "Orin Woods", "Tavi Chen",
        "GET /demo/health", "GET widget cache", "POST /demo/widgets", "Render widget preview",
        "cache-service", "edge-service", "render-service",
        "harbor-chain-fingerprint-a", "harbor-ledger-fingerprint-a",
        "harbor-render-fingerprint-a",
        "person-harbor-401", "person-harbor-402", "person-harbor-403", "person-harbor-404",
        "record-263575a7d6", "record-2ad259c8e4", "record-65e88063a7",
        "record-sample-delta",
        "span-health-root", "span-widget-cache", "span-widget-entry", "span-widget-render",
        "trace-event-cache", "trace-event-entry", "trace-event-health", "trace-event-render",
    ]
    static let packageFixtureNames: Set<String> = [
        "activity_log_402.json",
        "alerts.json",
        "annotations_empty.json",
        "batch_exports.json",
        "cohorts.json",
        "comments.json",
        "comments_count.json",
        "dashboard_detail_raw.json",
        "dashboard_templates.json",
        "dashboards_list.json",
        "data_modeling_jobs.json",
        "early_access_features.json",
        "element_stats.json",
        "endpoints_usage_overview.json",
        "error_tracking.json",
        "event_definitions.json",
        "event_taxonomy.json",
        "exception_chained_synthetic.json",
        "exception_resolved_frame.json",
        "exception_unresolved_frames.json",
        "experiment_detail_running.json",
        "experiment_exposures.json",
        "experiment_result_bayesian.json",
        "experiment_result_frequentist.json",
        "experiment_result_insufficient.json",
        "experiments.json",
        "exports.json",
        "external_data_sources.json",
        "feature_flags.json",
        "file_system.json",
        "groups_query.json",
        "groups_types.json",
        "health_issues.json",
        "heatmap_clicks.json",
        "heatmap_deep_tail.json",
        "heatmap_live_depth.json",
        "hog_flows.json",
        "hog_functions.json",
        "ingestion_warnings_empty.json",
        "ingestion_warnings_v2.json",
        "insight_actors.json",
        "insights_list.json",
        "llm_spend.json",
        "llm_traces.json",
        "max_conversation_detail.json",
        "max_conversations.json",
        "notebook_blocks_only.json",
        "notebook_detail.json",
        "notebook_opaque_content.json",
        "notebook_rich_content.json",
        "notebooks.json",
        "paths.json",
        "persons.json",
        "property_definitions.json",
        "query_endpoints.json",
        "query_hogql.json",
        "quota_limits.json",
        "replay_plugin_session.jsonl",
        "replay_plugin_shapes.jsonl",
        "sdk_health_report.json",
        "session_recording_playlist_recordings.json",
        "session_recording_playlist_recordings_empty.json",
        "session_recording_playlists.json",
        "session_events.json",
        "session_recordings.json",
        "session_recordings_filter_rejected.json",
        "session_recordings_filtered.json",
        "signal_reports.json",
        "snapshot_blobs.jsonl",
        "snapshot_sources.json",
        "stickiness.json",
        "subscriptions.json",
        "support_ticket_messages_synthetic.json",
        "support_tickets_synthetic.json",
        "survey_answers.json",
        "survey_answers_synthetic_nps.json",
        "survey_definition_dashboard_feedback.json",
        "survey_definition_synthetic_nps.json",
        "survey_results_summary.json",
        "surveys.json",
        "tasks.json",
        "team_taxonomy.json",
        "trace_spans.json",
        "users_me.json",
        "warehouse_saved_queries.json",
        "warehouse_saved_query_detail.json",
        "warehouse_tables.json",
        "web_external_clicks.json",
        "web_notable_changes.json",
        "web_overview.json",
        "web_vitals.json",
    ]

    static let demoCopies = Dictionary(uniqueKeysWithValues: [
        "comments.json",
        "dashboard_detail_raw.json",
        "dashboard_templates.json",
        "dashboards_list.json",
        "error_tracking.json",
        "exports.json",
        "external_data_sources.json",
        "feature_flags.json",
        "groups_types.json",
        "ingestion_warnings_v2.json",
        "insight_actors.json",
        "llm_spend.json",
        "persons.json",
        "query_hogql.json",
        "quota_limits.json",
        "sdk_health_report.json",
        "session_recording_playlist_recordings.json",
        "session_recording_playlists.json",
        "session_events.json",
        "session_recordings.json",
        "snapshot_blobs.jsonl",
        "snapshot_sources.json",
        "warehouse_tables.json",
        "web_overview.json",
    ].map { ($0, $0) } + [
        ("conversations_ticket_messages.json", "support_ticket_messages_synthetic.json"),
        ("conversations_tickets.json", "support_tickets_synthetic.json"),
    ])

    static let demoOnlyFixtureNames: Set<String> = [
        "actors_property_taxonomy.json", "alerts.json", "cohorts.json",
        "data_modeling_jobs.json", "data_modeling_jobs_healthy.json",
        "endpoints_usage_overview.json", "endpoints_usage_table.json",
        "event_definitions.json", "event_taxonomy.json", "exception_resolved_frame.json",
        "exception_unresolved_frames.json", "experiment_detail_complete.json",
        "experiment_detail_running.json", "experiments.json",
        "experiment_exposures_complete.json", "experiment_exposures_running.json",
        "experiment_result_funnel.json", "experiment_result_mean.json",
        "experiment_result_shipped.json", "group_event_breakdown.json",
        "file_system.json", "group_people.json", "group_session_recordings.json", "groups.json",
        "health_issues_demo.json", "heatmap_screenshots_saved.json", "marketing_analytics.json",
        "dashboard_empty_tiles.json", "dashboard_hogql_visualizations.json",
        "insights_list.json", "llm_traces.json", "notebook_detail.json",
        "max_conversations.json", "notebook_detail_plain.json", "notebooks_list.json",
        "organization_projects.json",
        "organization_projects_second.json", "property_carrier_events.json",
        "property_definitions.json", "property_value_distribution.json", "schema_columns_events.json",
        "schema_columns_persons.json", "schema_columns_sessions.json", "schema_tables.json",
        "replay_vision_observations.json", "replay_vision_summary_query.json",
        "survey_answers.json", "survey_results_summary.json", "surveys.json", "team_taxonomy.json",
        "trace_spans.json",
        "users_me.json", "warehouse_saved_queries.json", "warehouse_saved_query_failed.json",
        "warehouse_saved_query_healthy.json", "warehouse_saved_query_modified.json",
        "warehouse_saved_query_plain.json",
        "web_external_clicks.json", "web_notable_changes.json", "web_stats.json", "web_vitals.json",
    ]

    static let replayFixtureNames: Set<String> = [
        "group_session_recordings.json", "replay_plugin_session.jsonl",
        "replay_plugin_shapes.jsonl", "session_recording_playlist_recordings.json",
        "session_recording_playlist_recordings_empty.json", "session_recording_playlists.json",
        "replay_vision_observations.json", "replay_vision_summary_query.json",
        "session_events.json", "session_recordings.json", "session_recordings_filter_rejected.json",
        "session_recordings_filtered.json",
        "snapshot_blobs.jsonl", "snapshot_sources.json",
    ]
}
