import SwiftUI

struct AboutSettingsView: View {
    private let links: [(String, String, String)] = [
        ("Website", "globe", "https://prokopsimek.github.io/gitwall/"),
        ("Privacy Policy", "hand.raised", "https://prokopsimek.github.io/gitwall/privacy"),
        ("Source Code", "chevron.left.forwardslash.chevron.right", "https://github.com/prokopsimek/gitwall"),
        ("Report an Issue", "ladybug", "https://github.com/prokopsimek/gitwall/issues"),
    ]

    var body: some View {
        VStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            VStack(spacing: 4) {
                Text("Gitwall").font(.title.weight(.semibold))
                Text("Version \(Bundle.main.versionDescription)").foregroundStyle(.secondary)
            }
            Text("Pull requests and issues from all your repositories, on your desktop.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                ForEach(links, id: \.0) { title, symbol, url in
                    if let url = URL(string: url) {
                        Link(destination: url) { Label(title, systemImage: symbol) }
                    }
                }
            }
            .padding(.top, 4)
            Text("Copyright 2026 Prokop Simek. Released under the MIT License.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
