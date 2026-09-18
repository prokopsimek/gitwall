import SwiftUI

/// "Look around with sample data", the demonstration mode App Review asked for under guideline 2.1(a). Every screen
/// that is empty for lack of an account shows it: the walkthrough used to be the only way in, and it does not come
/// back once it has been finished, which is how the second review ended up stuck in Settings.
struct SampleDataOffer: View {
    enum Style {
        /// A quiet link under a more important action, as in the walkthrough and the empty lists.
        case link
        /// A button of its own, where nothing else on the screen competes with it.
        case button
    }

    let environment: AppEnvironment
    var style: Style = .link
    var alignment: HorizontalAlignment = .leading
    var explains = true
    /// Runs after sample data is on, e.g. to close the sheet that offered it.
    var onEnter: () -> Void = {}

    var body: some View {
        if environment.canShowSampleData {
            VStack(alignment: alignment, spacing: 4) {
                switch style {
                case .link:
                    Button("Look around with sample data", action: enter)
                        .buttonStyle(.link)
                        .accessibilityIdentifier("sample-data")
                case .button:
                    Button(action: enter) {
                        Label("Look Around with Sample Data", systemImage: "wand.and.stars")
                    }
                    .accessibilityIdentifier("sample-data")
                }
                if explains {
                    Text("Fictional pull requests and issues, so you can see what Gitwall does before connecting anything. Nothing is saved and no account is needed.")
                        .font(.caption).foregroundStyle(.secondary)
                        .multilineTextAlignment(alignment == .center ? .center : .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func enter() {
        environment.enterSampleData()
        onEnter()
    }
}
