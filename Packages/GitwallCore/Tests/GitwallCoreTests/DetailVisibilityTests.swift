import Testing
@testable import GitwallCore

@Suite("Detail visibility")
struct DetailVisibilityTests {
    @Test("navigation that leaves nothing selected closes Detail instead of showing an empty panel")
    func clearedSelectionCloses() {
        #expect(!DetailVisibility.isPresented(true, afterNavigatingTo: nil))
        #expect(!DetailVisibility.isPresented(false, afterNavigatingTo: nil))
    }

    @Test("navigation to an item leaves Detail as it was: open follows the item, closed stays closed")
    func selectionKeepsTheState() {
        #expect(DetailVisibility.isPresented(true, afterNavigatingTo: "github:1:o/r#1"))
        #expect(!DetailVisibility.isPresented(false, afterNavigatingTo: "github:1:o/r#1"))
    }
}
