import Foundation
import Testing
@testable import GitwallCore

@Suite("AvatarFiles")
struct AvatarFilesTests {
    @Test("file names are deterministic, distinct per URL and safe")
    func names() {
        let a = URL(string: "https://avatars.githubusercontent.com/u/1?v=4")!
        let b = URL(string: "https://avatars.githubusercontent.com/u/2?v=4")!
        #expect(AvatarFiles.fileName(for: a) == AvatarFiles.fileName(for: a))
        #expect(AvatarFiles.fileName(for: a) != AvatarFiles.fileName(for: b))
        #expect(AvatarFiles.fileName(for: a).hasSuffix(".png"))
        #expect(AvatarFiles.fileName(for: a).count == 32 + 4)
    }

    @Test("files live under avatars/ in the container")
    func location() {
        let container = URL(fileURLWithPath: "/tmp/container")
        let url = AvatarFiles.fileURL(for: URL(string: "https://example.com/a.png")!, in: container)
        #expect(url.path.hasPrefix("/tmp/container/avatars/"))
    }
}
