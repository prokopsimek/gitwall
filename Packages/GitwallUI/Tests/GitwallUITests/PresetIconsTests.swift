import Testing
@testable import GitwallUI

@Suite("PresetIcons")
struct PresetIconsTests {
    @Test("an offered icon keeps the list as it is")
    func offeredIcon() {
        #expect(PresetIcons.choices(including: "eye") == PresetIcons.all)
    }

    @Test("a pasted icon outside the list is added at the end, so the picker can show it")
    func pastedIcon() {
        #expect(PresetIcons.choices(including: "hand.raised") == PresetIcons.all + ["hand.raised"])
    }
}
