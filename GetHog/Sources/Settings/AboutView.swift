import GetHogUI
import SwiftUI

/// Version, attribution, and trademark distance.
///
/// An unofficial client for someone else's product has one obligation it can't
/// discharge with a footnote: never letting a user believe it's first-party.
/// That statement is the first thing on this screen, not the last.
struct AboutView: View {
    private static let appName = Bundle.main
        .object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
        ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
        ?? "GetHog"

    private static let version = Bundle.main
        .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"

    private static let build = Bundle.main
        .object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"

    private static let docsURL = URL(string: "https://posthog.com/docs")!
    private static let apiDocsURL = URL(string: "https://posthog.com/docs/api")!
    private static let scopesURL = URL(string: "https://posthog.com/docs/api#personal-api-keys")!

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    // GetHog's original mark, not a PostHog logo. The app name
                    // below already supplies the accessible identity.
                    BrandMarkView(size: 64)
                    Text(Self.appName)
                        .font(.title2.bold())
                    Text("Version \(Self.version) (\(Self.build))")
                        .font(.footnote)
                        .foregroundStyle(Theme.Ink.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
                .accessibilityElement(children: .combine)
            }

            Section {
                Text("GetHog is a third-party app and operates independently from PostHog.")
                    .font(.callout.weight(.medium))
            } footer: {
                Text("PostHog is a trademark of PostHog, Inc. GetHog is not affiliated with, endorsed by, or sponsored by PostHog, and uses none of its logos or wordmarks. It reaches your PostHog instance only with the personal API key you supply.")
            }

            Section {
                Label("Your API key stays in this device's Keychain", systemImage: "lock.shield")
                Label("Requests go only to your own PostHog host", systemImage: "network")
                Label("Cached responses stay on this device", systemImage: "internaldrive")
            } header: {
                SectionLabel(text: "Privacy", systemImage: "hand.raised")
            }

            #if !os(tvOS)
            // The whole section, not three seamed rows: every entry in it is a
            // `Link`, and an Apple TV has no browser to open one in. `Link`
            // compiles there and silently does nothing, which on a focus
            // platform is three more stops on the walk that lead nowhere. A
            // section headed "Learn more" with nothing that can be learned
            // from is worse than its absence.
            Section {
                Link(destination: Self.docsURL) {
                    Label("PostHog documentation", systemImage: "book")
                }
                Link(destination: Self.apiDocsURL) {
                    Label("PostHog API reference", systemImage: "curlybraces")
                }
                Link(destination: Self.scopesURL) {
                    Label("About personal API keys and scopes", systemImage: "key")
                }
            } header: {
                SectionLabel(text: "Learn more", systemImage: "book")
            }
            #endif
        }
        .listStyle(.insetGrouped)
        .pageSurface()
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
    }
}
