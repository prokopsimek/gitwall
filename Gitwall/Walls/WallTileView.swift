import AppKit
import GitwallCore
import GitwallUI
import SwiftUI

/// One tile of a wall: the widget look of `TileView` on a card, with selection, and while editing a size picker, a
/// remove button and drag and drop. A tile whose preset was deleted says so and waits to be removed.
struct WallTileView: View {
    @Bindable var model: WallsModel
    let tile: Tile

    private var isSelected: Bool { model.selectedTileID == tile.id }

    var body: some View {
        // The card takes exactly its cells. A tile's rows can be taller than that, as in a widget, so they hang from
        // the top and are cut off at the bottom instead of pushing the card out of its cells.
        Color.clear
            .overlay(alignment: .topLeading) {
                Group {
                    if let preset = model.preset(for: tile) {
                        content(preset)
                    } else {
                        deletedPreset
                    }
                }
                .padding(16)
                .allowsHitTesting(!model.isEditing)
            }
            .overlay {
                if model.isEditing {
                    editControls
                }
            }
            .background(Color(nsColor: .windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(
                    isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.separator),
                    style: StrokeStyle(lineWidth: isSelected ? 2 : 1, dash: model.isEditing && !isSelected ? [6, 4] : [])
                )
        }
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .onTapGesture { model.selectTile(tile) }
        .modifier(TileDragAndDrop(model: model, tile: tile))
    }

    private func content(_ preset: Preset) -> some View {
        let items = model.items(for: tile)
        let environment = model.environment
        return TileView(
            icon: preset.icon,
            title: preset.name,
            count: items.count,
            items: items,
            size: tile.size,
            now: Date(),
            avatar: { environment.avatar(for: $0.author.avatarURL).map(Image.init(nsImage:)) },
            isNew: { environment.newItemIDs.contains($0.id) },
            wrap: { item in
                WallItemRow(
                    item: item,
                    isSelected: model.selectedTileID == tile.id && model.selectedItemID == item.id,
                    select: { model.select(item, in: tile) },
                    activate: { model.activate(item) },
                    openInBrowser: { environment.open(item) }
                )
            },
            headerAction: { environment.openMainWindow(presetID: preset.id) },
            replacement: EmptyView?.none
        ) {
            EmptyView()
        } notice: {
            EmptyView()
        }
    }

    private var deletedPreset: some View {
        VStack(spacing: 8) {
            Image(systemName: "questionmark.square.dashed")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("Preset deleted")
                .font(.headline)
            Text("The preset this tile showed no longer exists.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Remove") { model.removeTile(tile.id) }
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var editControls: some View {
        VStack {
            HStack {
                Spacer()
                Button {
                    model.removeTile(tile.id)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .symbolRenderingMode(.hierarchical)
                }
                .buttonStyle(.plain)
                .help("Remove Tile")
                .accessibilityLabel("Remove Tile")
            }
            Spacer()
            Picker("Size", selection: Binding(get: { tile.size }, set: { model.setSize($0, ofTile: tile.id) })) {
                ForEach(TileSize.allCases, id: \.self) { size in
                    Text(size.shortTitle)
                        .help("\(size.title) (\(size.number))")
                        .tag(size)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
        .padding(10)
    }
}

/// While editing, a tile can be dragged onto another to go in front of it.
private struct TileDragAndDrop: ViewModifier {
    let model: WallsModel
    let tile: Tile

    func body(content: Content) -> some View {
        if model.isEditing {
            content
                .draggable(tile.id.uuidString)
                .dropDestination(for: String.self) { ids, _ in
                    guard let id = ids.first.flatMap(UUID.init(uuidString:)) else { return false }
                    model.moveTile(id, before: tile.id)
                    return true
                }
        } else {
            content
        }
    }
}

/// A row of a tile in the window: a click selects and activates it (`WallsModel.activate`), a double click opens
/// it in the browser, and the context menu copies it.
private struct WallItemRow: ViewModifier {
    let item: WorkItem
    let isSelected: Bool
    let select: () -> Void
    let activate: () -> Void
    let openInBrowser: () -> Void

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.18) : .clear)
                    .padding(-3)
            )
            .contentShape(Rectangle())
            .onTapGesture(count: 2, perform: openInBrowser)
            .onTapGesture {
                select()
                activate()
            }
            .contextMenu {
                Button("Open in Browser", action: openInBrowser)
                Button("Copy Link") { copy(item.url.absoluteString) }
                Button("Copy Title") { copy("\(item.title) (\(item.repoFullName)#\(item.number))") }
            }
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
