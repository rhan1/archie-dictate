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

    @Test func pillGeometryMatchesWispr() {
        // Measured from Wispr's own pill (2x capture ÷ 2), 2026-10-09 01:01.
        #expect(PillPanel.capsuleSize == NSSize(width: 102, height: 30))
        #expect(PillPanel.dockGap == 14)
        let view = PillView(frame: NSRect(origin: .zero, size: PillPanel.size))
        let capsule = view.capsuleRect
        #expect(view.cancelRect.size == NSSize(width: 18, height: 18))
        #expect(view.cancelRect.minX - capsule.minX == 6)
        #expect(capsule.maxX - view.finishRect.maxX == 6)
        #expect(view.cancelRect.midY == capsule.midY)
        #expect(PillView.barCount == 10)
        #expect(PillView.barWidth + PillView.barGap == 4)
        #expect(PillView.barIdleHeight == 2)
        #expect(view.barX(0) - capsule.minX == 32)
        #expect(view.barX(9) + PillView.barWidth - capsule.minX == 70)
    }

    @Test func barsScaleInPlaceAndNeverMoveSideways() {
        let view = PillView(frame: NSRect(origin: .zero, size: PillPanel.size))
        let xs = (0..<PillView.barCount).map(view.barX)
        var heights: [[CGFloat]] = []
        for step in 0..<12 {
            view.push(level: step < 6 ? 0.9 : 0.1)
            view.tick()
            heights.append((0..<PillView.barCount).map(view.barHeight))
            #expect((0..<PillView.barCount).map(view.barX) == xs)   // no horizontal motion, ever
        }
        #expect(heights[3].contains { $0 > PillView.barIdleHeight })      // common scale rises
        #expect(heights[3] != heights[4])                                    // still alive, not frozen
        #expect(view.smoothed > 0.1 && view.smoothed < 0.9)                  // slow decay after the drop
        #expect(heights.joined().allSatisfy { $0 <= PillView.barPeakHeight })
    }
}
