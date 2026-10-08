import AppKit
import Testing
@testable import DictateAppKit

/// Every test uses a private, uniquely named pasteboard — never `.general`, so
/// running the suite cannot disturb the live clipboard.
@Suite("PasteboardRestore")
struct PasteboardRestoreTests {
    private func privatePasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("dictate-test-\(UUID().uuidString)"))
    }

    @Test func roundTripRestoresStringAndCustomType() {
        let pb = privatePasteboard()
        defer { pb.releaseGlobally() }
        let custom = NSPasteboard.PasteboardType("com.razakhan.dictate.test")
        let item = NSPasteboardItem()
        item.setString("SENTINEL-123", forType: .string)
        item.setData(Data([0, 1, 2, 255]), forType: custom)
        pb.clearContents()
        pb.writeObjects([item])

        let snapshot = PasteboardSnapshot.capture(pb)
        pb.clearContents()
        pb.setString("transcript goes here", forType: .string)
        snapshot.restore(to: pb)

        #expect(pb.string(forType: .string) == "SENTINEL-123")
        #expect(pb.data(forType: custom) == Data([0, 1, 2, 255]))
        #expect(PasteboardSnapshot.capture(pb) == snapshot)
    }

    @Test func roundTripPreservesMultipleItems() {
        let pb = privatePasteboard()
        defer { pb.releaseGlobally() }
        let a = NSPasteboardItem(); a.setString("first", forType: .string)
        let b = NSPasteboardItem(); b.setString("second", forType: .string)
        pb.clearContents()
        pb.writeObjects([a, b])

        let snapshot = PasteboardSnapshot.capture(pb)
        #expect(snapshot.items.count == 2)
        pb.clearContents()
        snapshot.restore(to: pb)
        #expect(pb.pasteboardItems?.compactMap { $0.string(forType: .string) } == ["first", "second"])
    }

    @Test func emptyPasteboardRestoresToEmpty() {
        let pb = privatePasteboard()
        defer { pb.releaseGlobally() }
        pb.clearContents()
        let snapshot = PasteboardSnapshot.capture(pb)
        #expect(snapshot.items.isEmpty)
        pb.setString("leftover", forType: .string)
        snapshot.restore(to: pb)
        #expect(pb.string(forType: .string) == nil)
    }

    @Test func inserterPastesTextThenRestoresSentinel() async {
        let pb = privatePasteboard()
        defer { pb.releaseGlobally() }
        pb.clearContents()
        pb.setString("SENTINEL-CLIP", forType: .string)

        var seenAtKeystroke: String?
        let inserter = TextInserter(pasteboard: pb, postKeystroke: { seenAtKeystroke = pb.string(forType: .string) })
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async {
                inserter.insert("hello from dictate") { done.resume() }
            }
        }
        #expect(seenAtKeystroke == "hello from dictate")
        #expect(pb.string(forType: .string) == "SENTINEL-CLIP")
    }

    @Test func pillGeometryMatchesSpec() {
        #expect(PillPanel.size == NSSize(width: 250, height: 52))
        #expect(PillPanel.dockGap == 24)
        let view = PillView(frame: NSRect(origin: .zero, size: PillPanel.size))
        #expect(view.cancelRect.width == 36)
        #expect(view.finishRect.width == 36)
        #expect(view.cancelRect.maxX < view.finishRect.minX)
        #expect(view.cancelRect.midY == 26)
    }
}
