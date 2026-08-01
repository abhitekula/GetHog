import GetHogKit
import SwiftUI

/// The sheet that writes an annotation.
///
/// Deliberately three fields and no more. PostHog's `Annotation` schema also
/// accepts `emoji`, `hidden_in_user_interface` and `deleted`, and none of them
/// belongs on a phone: an emoji picker is decoration on the one screen whose
/// value is being fast, and the other two are ways of writing a note that is
/// already hidden or already deleted.
///
/// The scope choice is offered rather than assumed, but only two of the five
/// values are: `project` and `organization`. `dashboard_item` — which means
/// *insight*, not "an item on a dashboard" — and `dashboard` both need an id, and
/// choosing one would mean picking a specific insight before you can write
/// "we deployed". If an annotation is ever composed from an
/// insight's own screen, that screen already knows the id and passes it in as
/// `AnnotationTarget.insight`; this sheet is the standing-in-a-corridor case.
struct AnnotationComposerView: View {
    let projectName: String
    /// Called with the confirmed values. Returns whether it stuck — `false`
    /// leaves the sheet up with the text intact, because a note lost to a 403 is
    /// a note nobody rewrites.
    let save: (String, Date, AnnotationTarget) async -> Bool
    let isSaving: Bool

    @Environment(\.dismiss) private var dismiss

    @State private var content = ""
    /// Now, and captured once rather than recomputed: the default has to be the
    /// moment the sheet opened, not a value that drifts while you type.
    @State private var dateMarker = Date()
    @State private var scope: WritableScope = .project
    @State private var isConfirming = false
    @FocusState private var isEditorFocused: Bool

    /// The two scopes a note typed in a corridor can have.
    enum WritableScope: String, CaseIterable, Identifiable, Hashable {
        case project
        case organization

        var id: String { rawValue }

        var title: String {
            switch self {
            case .project: "This project"
            case .organization: "Whole organization"
            }
        }

        /// Said in terms of where the note will *show up*, which is the only
        /// thing the choice actually decides. "Project scope" describes the
        /// field; "on every chart in this project" describes the consequence.
        func detail(projectName: String) -> String {
            switch self {
            case .project: "Drawn on every chart in \(projectName)."
            case .organization: "Drawn on every chart in every project your organization has."
            }
        }

        var target: AnnotationTarget {
            switch self {
            case .project: .project
            case .organization: .organization
            }
        }
    }

    private var trimmedContent: String {
        content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSave: Bool { !trimmedContent.isEmpty && !isSaving }

    var body: some View {
        NavigationStack {
            Form {
                Section("Note") {
                    // `axis: .vertical` rather than a fixed-height editor: an
                    // annotation is usually one line and occasionally five, and a
                    // box sized for five wastes the screen for the common case
                    // while a box sized for one hides the rest of an uncommon one.
                    TextField(
                        "What happened?",
                        text: $content,
                        prompt: Text("Deployed 2.14.0"),
                        axis: .vertical
                    )
                    .lineLimit(1...6)
                    .focused($isEditorFocused)
                }

                Section {
                    DatePicker(
                        "Marks",
                        selection: $dateMarker,
                        displayedComponents: [.date, .hourAndMinute]
                    )
                } header: {
                    Text("When it happened")
                } footer: {
                    // The one thing about this screen that is not obvious, and the
                    // reason the feature is worth having on a phone at all.
                    Text("The instant the annotation marks — not the instant you write it. A deploy noticed at 14:40 still happened at 14:05.")
                }

                Section {
                    Picker("Show it on", selection: $scope) {
                        ForEach(WritableScope.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                } footer: {
                    Text(scope.detail(projectName: projectName))
                }
            }
            // The app's ground, for the same measured reason the twelve roots
            // needed it: a `Form` paints its own background over anything behind
            // it, so without this the sheet came up on the system's grouped grey
            // — sampled `#EFEFF0` in light and `#3E3E42` in dark against the
            // app's `#F2EFE9` / `#151413`. The survey sheet beside it already
            // carries this, which is why the two read as different apps.
            .pageSurface()
            .navigationTitle("New annotation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button("Add") {
                            isEditorFocused = false
                            isConfirming = true
                        }
                        .disabled(!canSave)
                    }
                }
            }
            // The confirmation names the object and the direction, exactly as
            // `setFlagActive`'s does. For a write whose whole content is
            // free text, "the object" is that text — quoting it back is the only
            // way the dialog can be checked against what the user meant, and it
            // is also the only chance to notice the marker is on the wrong day.
            .confirmationDialog(
                "Write this annotation?",
                isPresented: $isConfirming,
                titleVisibility: .visible
            ) {
                Button("Add annotation") {
                    Task {
                        if await save(trimmedContent, dateMarker, scope.target) { dismiss() }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(confirmationDetail)
            }
            .onAppear { isEditorFocused = true }
        }
    }

    /// Everything the write will send, in the order it matters.
    ///
    /// Spelled out in full rather than summarised: this is the last moment before
    /// something is written into a real project, and the app has no way to delete
    /// an annotation afterwards — `AnnotationsRoot` reads and creates, and
    /// removing one means opening the web console.
    private var confirmationDetail: String {
        """
        “\(trimmedContent)”

        Marking \(dateMarker.formatted(.dateTime.weekday(.wide).day().month(.wide).year().hour().minute())).
        \(scope.detail(projectName: projectName))

        GetHog can't delete an annotation — that has to be done in PostHog.
        """
    }
}
