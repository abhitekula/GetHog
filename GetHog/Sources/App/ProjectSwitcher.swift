import GetHogKit
import GetHogUI
import SwiftUI

/// Always-visible project context.
///
/// Showing one project's numbers under another project's name is a correctness
/// bug, not a cosmetic one, so this sits in the toolbar of every root screen.
struct ProjectSwitcher: ToolbarContent {
    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            ProjectSwitcherMenu()
        }
    }
}

#if os(macOS)
/// The same control, declared as an *identified* item, for the two Mac screens
/// whose toolbars are user-customizable.
///
/// Not a second spelling for its own sake. A plain `.toolbar { }` and a
/// `.toolbar(id:)` applied to one view resolve to a window toolbar with
/// `allowsUserCustomization == false`, which is what left View ▸ Customize
/// Toolbar… greyed out on Dashboards and Sessions even after `ToolbarCommands()`
/// put the item in the menu. Measured with a standalone SwiftUI probe that read
/// `NSWindow.toolbar` directly: the `.sidebarAdaptable` `TabView`, the
/// declaration sitting inside a navigation column, `.searchable` and
/// `.toolbar(removing: .sidebarToggle)` each left the toolbar customizable, and
/// adding the plain modifier alone was enough to turn it off. So the fixed
/// items have to *join* the identified toolbar rather than sit beside it.
///
/// `.customizationBehavior(.disabled)` is what keeps "fixed" true: the item
/// cannot be moved or removed and never reaches the customization palette.
/// Project context is not optional chrome — see `ProjectSwitcher` above for why
/// that is a correctness rule rather than a preference.
struct PinnedProjectSwitcher: CustomizableToolbarContent {
    var body: some CustomizableToolbarContent {
        ToolbarItem(id: "project", placement: .topBarLeading) {
            ProjectSwitcherMenu()
        }
        .customizationBehavior(.disabled)
    }
}
#endif

/// The control itself, so the plain and the identified item above are two
/// placements of one menu rather than two menus.
struct ProjectSwitcherMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Menu {
            projectList
        } label: {
            #if os(tvOS)
            // One focus target and one visual address. The prior composition
            // put the project name in a separate toolbar item above this
            // icon-only menu, so the remote saw a cyan circle disconnected from
            // the text that explained it.
            HStack(spacing: Theme.Space.s) {
                BrandProductMarkView(
                    mark: .projectStamp,
                    size: 24,
                    tint: Theme.televisionControlInk
                )
                Text(visibleProjectAddress)
                    .font(.headline)
                    .lineLimit(1)
            }
            .frame(minWidth: 260, alignment: .leading)
            #else
            // A glyph, not the project name. The name is permanently
            // visible elsewhere, and repeating it here made the item wide
            // enough that it could not share the bar with a back button —
            // costing a whole row of chrome on every pushed screen.
            //
            // Where "elsewhere" is depends on the platform. On iOS, iPadOS
            // and macOS it is the navigation subtitle `ScreenChrome`
            // applies. visionOS has no `navigationSubtitle` at all, so
            // `ScreenChrome` puts the name in a toolbar item immediately
            // beside this glyph instead — which is why the two read as one
            // address there rather than as a label and a control.
            BrandProductMarkView(mark: .projectStamp, size: 18)
            #endif
        }
        .televisionAccentControlInk()
        // The label names the thing; the hint says what happens to it.
        //
        // It used to end "Double tap to switch." — which VoiceOver already
        // appends itself, so the instruction was spoken twice on every
        // screen in the app, and it named a gesture that Switch Control,
        // Voice Control and a keyboard do not have.
        //
        // The organization is spoken only when there is more than one. For
        // the single-organization user it is a constant, and a constant read
        // aloud on every screen is noise; for everyone else it is the half of
        // the answer that decides whose numbers these are.
        .accessibilityLabel(spokenLabel)
        .accessibilityHint(
            model.isMultiOrganization
                ? "Switches to a different project or organization"
                : "Switches to a different project"
        )
    }

    private var spokenLabel: String {
        let project = model.selectedProject?.name ?? "none"
        guard model.isMultiOrganization, let organization = model.selectedOrganization else {
            return "Current project: \(project)"
        }
        return "Current project: \(project), in organization \(organization.name)"
    }

    /// The visible tvOS address. A project name alone is enough for the common
    /// single-organization case; two organizations can each contain a
    /// "Default project", so the organization joins it when it disambiguates.
    private var visibleProjectAddress: String {
        let project = model.selectedProject?.name ?? "No project"
        guard model.isMultiOrganization, let organization = model.selectedOrganization else {
            return project
        }
        return "\(organization.name) · \(project)"
    }

    /// Every project the key can reach, under the organisation that owns them.
    ///
    /// The organisation is the *heading over* the projects, not an entry beneath
    /// them.
    ///
    /// It used to be a plain `Text` after a `Divider`, which is the shape a menu
    /// uses for a second group of *commands* — same size, same weight, same
    /// leading inset as the project row above it, with only a missing checkmark
    /// to say it was not selectable. A heading styled like an entry can appear
    /// to be another selectable project, which risks showing the wrong data.
    ///
    /// A titled `Section` is the system's own vocabulary for "these items belong
    /// to this": drawn smaller and grey, above the selectable run rather than
    /// inside it, with no divider implying a second group of choices.
    ///
    /// Buttons rather than the `Picker` this used to be, and that is not a
    /// preference — it is what makes the heading appear at all. Both arrangements
    /// were built and photographed: with a `Picker` inside it, the section's title
    /// is dropped and the organisation vanishes from the menu entirely, and
    /// `.pickerStyle(.inline)` with the organisation as the picker's own label
    /// does the same. Either would have traded a misreading for a blank. A menu
    /// of buttons with a checkmark on the current one is what a `Picker` compiles
    /// to anyway; writing it out is what keeps the title.
    @ViewBuilder
    private var projectList: some View {
        // The heading is the *selected* organization, not `me.organization`.
        // Those are the same thing until somebody switches, and after that
        // `me.organization` is the organization the identity request happened to
        // be centred on — which would leave the menu heading one organization's
        // name over another organization's projects. Precisely the misreading
        // the heading was introduced to prevent.
        Section(model.selectedOrganization?.name ?? model.me?.organization?.name ?? "") {
            ForEach(model.projects) { project in
                let isCurrent = project.id == model.selectedProject?.id
                Button {
                    model.selectedProject = project
                } label: {
                    if isCurrent {
                        Label(project.name, systemImage: "checkmark")
                    } else {
                        Text(project.name)
                    }
                }
                // The checkmark is the only thing distinguishing the current
                // project, and a glyph inside a menu item is not announced — so
                // written out, the way `Picker` announced "selected" before.
                .accessibilityLabel(isCurrent ? "\(project.name), current project" : project.name)
            }
        }

        // Absent entirely for the single-organization user, which is most of
        // them: a second section headed "Organization" listing exactly the
        // organization already named above it says nothing and invites the
        // reading that there is somewhere else to go.
        if model.isMultiOrganization {
            organizationList
        }
    }

    /// The other organizations this credential can see.
    ///
    /// Buttons in a titled `Section`, for the same reason the projects above are:
    /// a `Picker` inside a `Section` drops the title, and an untitled run of
    /// organization names directly under a run of project names is two lists that
    /// look like one. Both arrangements were built and photographed when the
    /// project half of this menu was written.
    ///
    /// Switching costs a request the first time, so each button is disabled while
    /// one is in flight — a menu is dismissed on tap and gives the second tap
    /// nowhere to report to, so two switches racing would be resolved by whichever
    /// response arrived last rather than by whichever the user meant.
    private var organizationList: some View {
        Section("Organization") {
            ForEach(model.organizations) { organization in
                let isCurrent = organization.id == model.selectedOrganizationID
                Button {
                    Task { await model.selectOrganization(id: organization.id) }
                } label: {
                    if isCurrent {
                        Label(organization.name, systemImage: "checkmark")
                    } else {
                        Label(organization.name, systemImage: "building.2")
                    }
                }
                .disabled(model.isSwitchingOrganization)
                .accessibilityLabel(
                    isCurrent
                        ? "\(organization.name), current organization"
                        : "\(organization.name), organization"
                )
            }
        }
    }
}
