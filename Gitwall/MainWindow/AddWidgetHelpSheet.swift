import SwiftUI

/// How to place Gitwall widgets. macOS offers no API to open the widget gallery, so this is a guide.
struct AddWidgetHelpSheet: View {
    @Environment(\.dismiss) private var dismiss

    private let steps: [(String, String, String)] = [
        ("rectangle.3.group", "Open the widget gallery",
         "Right-click the desktop and choose “Edit Widgets…”, or click the date in the menu bar and scroll down to “Edit Widgets”."),
        ("magnifyingglass", "Find Gitwall",
         "Type “Git” in the gallery search, pick a size (small, medium, large or extra large) and drag the widget to the desktop."),
        ("slider.horizontal.3", "Choose a preset",
         "Right-click the widget and choose “Edit Gitwall”, then pick the preset it should show. Presets are managed in Settings › Presets."),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Image(systemName: "rectangle.3.group.fill").font(.title).foregroundStyle(.tint)
                Text("Add widgets to your desktop").font(.title2.weight(.semibold))
            }
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
                Text("Add as many widgets as you like. Each one keeps its own preset and size, so one can show “Waiting for my review” while another shows a team’s issues.")
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "square.on.square")
            }
            .font(.callout)
            .padding(12)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520)
    }
}
