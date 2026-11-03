import Foundation

/// When Detail stays open while the selection of its list moves without a click: switching walls, Tab or a click to a
/// tile with nothing selected, rotation, or another preset in the main window that does not list the selected item.
/// Detail follows the selection to an item, but navigation that leaves nothing selected closes it, so it never takes
/// a quarter of the window to say "No Item Selected". Show Detail (Space, ↩, ⌥⌘I) with nothing selected still opens
/// it on the first item, or empty when the list is.
public enum DetailVisibility {
    /// Whether Detail shows after navigation selected `itemID` (nil: nothing) while it was `isPresented`.
    public static func isPresented(_ isPresented: Bool, afterNavigatingTo itemID: String?) -> Bool {
        isPresented && itemID != nil
    }
}
