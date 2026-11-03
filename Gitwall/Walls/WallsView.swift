import AppKit
import GitwallCore
import GitwallUI
import SwiftUI

/// The Walls window: a tab per wall, the tiles of the selected one, and in a corner how fresh the data is.
struct WallsView: View {
    @Bindable var model: WallsModel

    private var environment: AppEnvironment { model.environment }

    var body: some View {
        content
            .frame(minWidth: 560, minHeight: 380)
            .background(Color(nsColor: .underPageBackgroundColor))
            .onExitCommand { model.isEditing = false }
    }

    @ViewBuilder
    private var content: some View {
        if !environment.containerAvailable {
            EmptyStateView(kind: .containerUnavailable, environment: environment)
        } else if environment.needsOnboarding {
            // Every screen that is empty for lack of an account offers sample data (ADR 0010).
            EmptyStateView(kind: .noAccounts, environment: environment)
        } else if let wall = model.currentWall {
            VStack(spacing: 0) {
                tabBar
                Divider()
                if model.isEditing {
                    palette
                    Divider()
                }
                if wall.tiles.isEmpty {
                    emptyWall
                } else {
                    WallGrid(model: model, wall: wall)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                SyncStatusCorner(environment: environment)
            }
        } else {
            noWalls
        }
    }

    // MARK: Tabs

    private var tabBar: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(model.walls) { wall in
                        WallTab(model: model, wall: wall)
                    }
                    Button {
                        model.newWall()
                    } label: {
                        Image(systemName: "plus")
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("New Wall")
                    .accessibilityLabel("New Wall")
                }
                .padding(.horizontal, 12)
            }
            Button(model.isEditing ? "Done" : "Edit") {
                model.isEditing.toggle()
            }
            .help(model.isEditing ? "Finish editing (⌘E)" : "Arrange, resize, add and remove tiles (⌘E)")
            .padding(.trailing, 12)
        }
        .padding(.vertical, 6)
        .background(.bar)
    }

    // MARK: Editing

    /// Presets to add as tiles, and what the keys do while editing.
    private var palette: some View {
        VStack(alignment: .leading, spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    Text("Add a tile:")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    ForEach(environment.config.presets) { preset in
                        Button {
                            model.addTile(presetID: preset.id)
                        } label: {
                            Label(preset.name, systemImage: preset.icon)
                                .lineLimit(1)
                        }
                        .controlSize(.small)
                    }
                }
                .padding(.horizontal, 16)
            }
            Text("Drag a tile to move it. 1–4 set the size of the selected tile, Delete removes it, ⌘Z undoes.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
        }
        .padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: Empty states

    private var noWalls: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "rectangle.3.group").font(.system(size: 34)).foregroundStyle(.secondary)
            Text("No walls yet").font(.headline)
            Text("A wall shows several presets side by side, as tiles the size of desktop widgets. Keep one in a window, or full screen on a second monitor.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 420)
            HStack(spacing: 8) {
                Button("New Wall from Presets") { model.newWallFromPresets() }
                    .disabled(environment.config.presets.isEmpty)
                Button("Paste Configuration…") { ConfigurationPaste.run(environment: environment) }
            }
            .padding(.top, 4)
            Spacer()
        }
        // Texts that wrap need a width to wrap at; see `EmptyStateView`.
        .frame(minWidth: 280)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyWall: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "square.dashed").font(.system(size: 34)).foregroundStyle(.secondary)
            Text("This wall has no tiles").font(.headline)
            if model.isEditing {
                Text("Add a preset from the list above.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Button("Add Tiles") { model.isEditing = true }
            }
            Spacer()
        }
        .frame(minWidth: 280)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One tab. A click selects it, a double click renames it, and its context menu has the rest.
private struct WallTab: View {
    @Bindable var model: WallsModel
    let wall: Wall
    @State private var draft = ""
    @FocusState private var focused: Bool

    private var isSelected: Bool { model.currentWall?.id == wall.id }

    var body: some View {
        Group {
            if model.renamingWallID == wall.id {
                TextField("Wall name", text: $draft)
                    .textFieldStyle(.plain)
                    .frame(width: 160)
                    .focused($focused)
                    .onAppear {
                        draft = wall.name
                        focused = true
                    }
                    .onSubmit { model.rename(wall.id, to: draft) }
                    .onExitCommand { model.renamingWallID = nil }
                    .onChange(of: focused) { _, isFocused in
                        if !isFocused, model.renamingWallID == wall.id { model.rename(wall.id, to: draft) }
                    }
            } else {
                Text(wall.name)
                    .lineLimit(1)
            }
        }
        .font(.callout.weight(isSelected ? .semibold : .regular))
        .foregroundStyle(isSelected ? .primary : .secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isSelected ? Color.primary.opacity(0.1) : .clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .onTapGesture { model.selectWall(wall.id) }
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            model.selectWall(wall.id)
            model.renamingWallID = wall.id
        })
        .contextMenu {
            Button("Rename") {
                model.selectWall(wall.id)
                model.renamingWallID = wall.id
            }
            Button("Duplicate") { model.duplicate(wall.id) }
            Button("Copy as JSON") { ConfigurationPaste.copy(wall, environment: model.environment) }
            Divider()
            Button("Delete", role: .destructive) { model.delete(wall.id) }
        }
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// The tiles of one wall on a grid of cells about the size of a small widget. Zoom scales the whole grid, so a wall
/// on a large monitor reads from across the room with fewer, larger tiles.
private struct WallGrid: View {
    let model: WallsModel
    let wall: Wall

    private static let cellHeight = 170.0
    private static let spacing = 16.0
    private static let margin = 20.0

    private struct Placed: Identifiable {
        let tile: Tile
        let rect: GridRect
        var id: Tile.ID { tile.id }
    }

    var body: some View {
        GeometryReader { proxy in
            let zoom = model.zoom
            let width = max(proxy.size.width - 2 * Self.margin, 200) / zoom
            let columns = WallLayout.columns(forWidth: width)
            let cellWidth = (width - Double(columns - 1) * Self.spacing) / Double(columns)
            let rects = WallLayout.pack(wall.tiles.map(\.size), columns: columns)
            let rows = WallLayout.rowCount(rects)
            let height = Double(rows) * Self.cellHeight + Double(max(rows - 1, 0)) * Self.spacing
            let placed = zip(wall.tiles, rects).map { Placed(tile: $0, rect: $1) }

            ScrollView(.vertical) {
                ZStack(alignment: .topLeading) {
                    ForEach(placed) { placed in
                        WallTileView(model: model, tile: placed.tile)
                            .frame(
                                width: span(placed.rect.width, cell: cellWidth),
                                height: span(placed.rect.height, cell: Self.cellHeight)
                            )
                            .offset(
                                x: Double(placed.rect.column) * (cellWidth + Self.spacing),
                                y: Double(placed.rect.row) * (Self.cellHeight + Self.spacing)
                            )
                    }
                }
                .frame(width: width, height: height, alignment: .topLeading)
                .animation(.snappy, value: rects)
                .scaleEffect(zoom, anchor: .topLeading)
                .frame(width: width * zoom, height: height * zoom, alignment: .topLeading)
                .padding(Self.margin)
                // A tile dropped below the others goes to the end.
                .dropDestination(for: String.self) { ids, _ in
                    guard model.isEditing, let id = ids.first.flatMap(UUID.init(uuidString:)) else { return false }
                    model.moveTile(id, before: nil)
                    return true
                }
            }
        }
    }

    private func span(_ cells: Int, cell: Double) -> Double {
        Double(cells) * cell + Double(cells - 1) * Self.spacing
    }
}

/// "Updated 2 min ago", or in red why the last sync failed, so a wall nobody touches never shows old data as new.
private struct SyncStatusCorner: View {
    let environment: AppEnvironment

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let status = SyncStatus(snapshot: environment.snapshot, accounts: environment.config.accounts, lastError: environment.lastError)
            Button {
                if status.isFailure { environment.openSettings(.accounts) }
            } label: {
                HStack(spacing: 6) {
                    if environment.isRefreshing {
                        ProgressView().controlSize(.mini)
                    } else if status.isFailure {
                        Image(systemName: "exclamationmark.triangle.fill")
                    }
                    Text(status.text(now: context.date))
                        .lineLimit(1)
                }
                .font(.caption)
                .foregroundStyle(status.isFailure ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.regularMaterial, in: Capsule())
            }
            .buttonStyle(.plain)
            .help(status.failure ?? "When the items on this wall were fetched")
            .padding(12)
        }
    }
}
