import Foundation
import Testing
@testable import DictateCore

@Suite("ST2StoreTests", .serialized)
struct ST2StoreTests {
    @Test func diffLearnedWord() {
        let inserted = "send it to Polytrace today"
        let observed = "send it to Politrace today"
        let learned = EditDiff.replacedWords(inserted: inserted, observed: observed)
        print("ST2B DIFF inserted=\"\(inserted)\" observed=\"\(observed)\" learned=\(learned)")
        #expect(learned == ["Politrace"])
    }

    @Test func diffControlCaseOnly() {
        let inserted = "send it to Politrace today"
        let observed = "send it to politrace today"
        let learned = EditDiff.replacedWords(inserted: inserted, observed: observed)
        print("ST2B DIFF CONTROL case_only learned=\(learned)")
        #expect(learned.isEmpty)
    }

    @Test func diffControlShortOrNumeric() {
        let inserted = "to 12 ab"
        let observed = "at 13 cd"
        let learned = EditDiff.replacedWords(inserted: inserted, observed: observed)
        print("ST2B DIFF CONTROL short_or_numeric learned=\(learned)")
        #expect(learned.isEmpty)
    }

    @Test func diffControlInsertionOnly() {
        let inserted = "send it"
        let observed = "send it now please"
        let learned = EditDiff.replacedWords(inserted: inserted, observed: observed)
        print("ST2B DIFF CONTROL insertion_only learned=\(learned)")
        #expect(learned.isEmpty)
    }

    @Test func diffControlCap() {
        let inserted = "wone wtwo wthree wfour wfive wsix wseven"
        let observed = "first second third fourth fifth sixth seventh"
        let learned = EditDiff.replacedWords(inserted: inserted, observed: observed)
        print("ST2B DIFF CONTROL cap learned_count=\(learned.count)")
        #expect(learned.count == 5)
        #expect(learned == ["first", "second", "third", "fourth", "fifth"])
    }

    @Test func storeAppendAndDuplicate() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("dictate-st2b-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let storeURL = tempDir.appendingPathComponent("keyterms.txt")
        let store = KeytermsStore(url: storeURL)

        let added1 = try store.append(["Politrace"])
        let lines1 = store.newest(10)
        print("ST2B STORE append added=\(added1) lines=\(lines1.count)")
        #expect(added1 == 1)
        #expect(lines1.count == 1)

        let added2 = try store.append(["Politrace"])
        let lines2 = store.newest(10)
        print("ST2B STORE duplicate=Politrace added=\(added2) lines=\(lines2.count)")
        #expect(added2 == 0)
        #expect(lines2.count == 1)
    }

    @Test func storeCap() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("dictate-st2b-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let storeURL = tempDir.appendingPathComponent("keyterms.txt")
        let store = KeytermsStore(url: storeURL)

        let terms = (1...205).map { "<term\($0)>" }
        let added = try store.append(terms)
        let lines = store.newest(300)
        let oldestDropped = (!lines.contains("<term1>") && !lines.contains("<term5>")) ? 1 : 0
        let newestKept = (lines.contains("<term6>") && lines.contains("<term205>")) ? 1 : 0
        print("ST2B STORE cap=\(KeytermsStore.cap) lines=\(lines.count) oldest_dropped=\(oldestDropped) newest_kept=\(newestKept)")
        #expect(added == 205)
        #expect(lines.count == 200)
        #expect(oldestDropped == 1)
        #expect(newestKept == 1)
    }

    @Test func storeNewest50() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("dictate-st2b-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let storeURL = tempDir.appendingPathComponent("keyterms.txt")
        let store = KeytermsStore(url: storeURL)

        let terms = (1...205).map { "<term\($0)>" }
        try store.append(terms)
        let n50 = store.newest(50)
        let first = n50.first ?? ""
        let last = n50.last ?? ""
        print("ST2B STORE newest50 first=\(first) last=\(last) count=\(n50.count)")
        #expect(n50.count == 50)
        #expect(first == "<term156>")
        #expect(last == "<term205>")
    }

    @Test func storeAtomic() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("dictate-st2b-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let storeURL = tempDir.appendingPathComponent("nested/dir/keyterms.txt")
        let store = KeytermsStore(url: storeURL)

        try store.append(["first", "second"])
        try store.append(["third"])

        let parentDir = storeURL.deletingLastPathComponent()
        let dirContents = try FileManager.default.contentsOfDirectory(atPath: parentDir.path)
        let tempFiles = dirContents.filter { $0.contains(".tmp.") }
        print("ST2B STORE atomic temp_files_left=\(tempFiles.count)")
        #expect(tempFiles.count == 0)
    }
}
