import SwiftUI

/// How to place Gitwall widgets. macOS offers no API to open the widget gallery, so this is a guide.
/// Shared by the help sheet and the last onboarding step.
struct AddWidgetSteps: View {
    private let steps: [(String, String, String)] = [
        ("rectangle.3.group", "Open the widget gallery",
         "Right-click the desktop and choose \u{201C}Edit Widgets\u{2026}\u{201D}, or click the date in the menu bar and scroll down to \u{201C}Edit Widgets\u{201D}."),
        ("magnifyingglass", "Find Gitwall",
         "Type \u{201C}Git\u{201D} in the gallery search and drag a widget to the desktop: Counter (small), List (medium), Board (large) or Wide Board (extra large)."),
        ("slider.horizontal.3", "Choose a preset",
         "Right-click the widget and choose \u{201C}Edit Gitwall\u{201D}, then pick the preset it should show. Presets are managed in Settings \u{203A} Presets."),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .top, spacing: 12) {
                    ZStack {
                        Circle().fill(.quaternary).frame(width: 28, height: 28)
                        Text("\(index + 1)").font(.callout.weight(.semibold))
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Label(step.1, systemImage: step.0).font(.headline)
                        Text(step.2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Label {
                Text("Add as many widgets as you like. Each one keeps its own preset and size, so one can show \u{201C}Waiting for my review\u{201D} while another shows a team\u{2019}s issues.")
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "square.on.square")
            }
            .font(.callout)
            .padding(12)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

struct AddWidgetHelpSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Image(systemName: "rectangle.3.group.fill").font(.title).foregroundStyle(.tint)
                Text("Add widgets to your desktop").font(.title2.weight(.semibold))
            }
            AddWidgetSteps()
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520)
    }
}
