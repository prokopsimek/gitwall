import GitwallCore
import GitwallUI
import SwiftUI

extension View {
    /// Detail as an inspector on the trailing edge. Any window with a list of items attaches it with this, calls
    /// `model.show(item.id)` on a click and makes its controller an ``ItemWindowController`` for the Item menu.
    /// `preset` is the one the list shows, for "Why it's here".
    /// Esc closes it from anywhere in the window that does not take Esc itself (a search field, a name being typed).
    /// AppKit never hands Esc to the Item menu's Close Detail (keyboard walkthrough 2026-11-03).
    func itemDetailInspector(_ model: DetailModel, environment: AppEnvironment, preset: Preset?) -> some View {
        inspector(isPresented: Bindable(model).isPresented) {
            DetailPanel(model: model, environment: environment, preset: preset)
                .inspectorColumnWidth(min: 320, ideal: 380, max: 620)
        }
        .onExitCommand { model.close() }
    }
}

/// The inspector's content: Detail of the selected item, or a hint to select one.
struct DetailPanel: View {
    let model: DetailModel
    let environment: AppEnvironment
    let preset: Preset?

    /// The selected item and its state, to tell a sync that changed it from a new selection.
    private struct Shown: Equatable {
        var id: String?
        var updatedAt: Date?
    }

    var body: some View {
        let item = model.selectedItem
        Group {
            if let item {
                DetailView(content: model.content(for: item, preset: preset), actions: model.actions(for: item),
                           initiallyExpanded: Self.initiallyExpanded, scrollsToExpanded: !Self.initiallyExpanded.isEmpty)
            } else {
                ContentUnavailableView("No Item Selected", systemImage: "sidebar.trailing",
                                       description: Text("Select an item to see why it is here and what to do next."))
            }
        }
        .onChange(of: Shown(id: item?.id, updatedAt: item?.updatedAt)) { old, new in
            if old.id == new.id, old.updatedAt != nil, old.updatedAt != new.updatedAt { model.selectedItemDidChange() }
        }
    }

    /// `--debug-detail-expand description,conversation` opens folds and scrolls to the first, for screenshots. Debug
    /// builds only.
    private static var initiallyExpanded: Set<DetailFold> {
        #if DEBUG
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--debug-detail-expand"), args.indices.contains(index + 1) {
            return Set(args[index + 1].split(separator: ",").compactMap { DetailFold(rawValue: String($0)) })
        }
        #endif
        return []
    }
}
