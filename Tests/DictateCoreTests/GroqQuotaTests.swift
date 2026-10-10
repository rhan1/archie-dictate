import Foundation
import Testing
import DictateCore

private func response(_ headers: [String: String]) -> HTTPURLResponse {
    HTTPURLResponse(url: URL(string: "https://api.groq.com/openai/v1/chat/completions")!, statusCode: 200,
                    httpVersion: nil, headerFields: headers)!
}
private func limits(_ headers: [String: String], _ endpoint: GroqRateLimit.Endpoint = .stt) -> GroqRateLimit {
    GroqRateLimit(response: response(headers), endpoint: endpoint)
}
private func headers(limit: Int, remaining: Int, reset: String = "2m59.56s") -> [String: String] {
    ["x-ratelimit-limit-requests": "\(limit)", "x-ratelimit-remaining-requests": "\(remaining)",
     "x-ratelimit-limit-tokens": "7000", "x-ratelimit-remaining-tokens": "6500",
     "x-ratelimit-reset-requests": reset, "x-ratelimit-reset-tokens": "1.5s"]
}
private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

@Suite("GroqQuotaTests")
struct GroqQuotaTests {
    @Test func fullHeaderSetIsRecordedPerEndpoint() {
        let quota = GroqQuota().merging(limits(headers(limit: 14400, remaining: 14000), .stt), at: t0)
        #expect(quota.stt.limitRequests == 14400 && quota.stt.remainingRequests == 14000)
        #expect(quota.stt.limitTokens == 7000 && quota.stt.remainingTokens == 6500)
        #expect(quota.stt.resetRequestsAt == t0.addingTimeInterval(179.56))
        #expect(quota.stt.updatedAt == t0)
        #expect(quota.cleanup == GroqQuota.Snapshot())
    }

    @Test func partialResponseKeepsPriorValuesForMissingFieldsOnly() {
        let first = GroqQuota().merging(limits(headers(limit: 100, remaining: 50), .cleanup), at: t0)
        let later = t0.addingTimeInterval(30)
        let merged = first.merging(limits(["x-ratelimit-remaining-requests": "49"], .cleanup), at: later)
        #expect(merged.cleanup.remainingRequests == 49)
        #expect(merged.cleanup.limitRequests == 100 && merged.cleanup.limitTokens == 7000)
        #expect(merged.cleanup.remainingTokens == 6500)
        #expect(merged.cleanup.resetRequestsAt == t0.addingTimeInterval(179.56))
        #expect(merged.cleanup.updatedAt == later)
        // A response with no ratelimit headers must not refresh freshness.
        let empty = merged.merging(limits([:], .cleanup), at: later.addingTimeInterval(600))
        #expect(empty == merged)
    }

    @Test func resetDurationsParseGroqFormats() {
        #expect(GroqRateLimit.parseDuration("2m59.56s") == 179.56)
        #expect(GroqRateLimit.parseDuration("7.66s") == 7.66)
        #expect(GroqRateLimit.parseDuration("1h2m3s") == 3723)
        #expect(GroqRateLimit.parseDuration("120ms") == 0.12)
        #expect(GroqRateLimit.parseDuration("garbage") == nil)
        #expect(GroqRateLimit.parseDuration("") == nil)
        #expect(GroqRateLimit.parseDuration("12") == nil)
        #expect(GroqRateLimit.parseDuration("3x") == nil)
        #expect(GroqRateLimit.parseDuration("-4s") == nil)
        #expect(limits(["x-ratelimit-reset-requests": "2m59.56s", "x-ratelimit-reset-tokens": "7.66s"]).resetRequests == 179.56)
        #expect(limits(["x-ratelimit-reset-tokens": "7.66s"]).resetTokens == 7.66)
        #expect(limits(["x-ratelimit-reset-requests": "soon"]).resetRequests == nil)
    }

    @Test func isLowAtNinePercentNotAtTenAndExpires() {
        func quota(_ remaining: Int, reset: String? = "2m0s") -> GroqQuota {
            var h = headers(limit: 100, remaining: remaining)
            h["x-ratelimit-reset-requests"] = reset
            return GroqQuota().merging(limits(h, .stt), at: t0)
        }
        let soon = t0.addingTimeInterval(60)
        #expect(quota(9).isLow(.stt, at: soon))
        #expect(!quota(10).isLow(.stt, at: soon))
        #expect(!quota(9).isLow(.cleanup, at: soon))          // other endpoint untouched
        #expect(!quota(9).isLow(.stt, at: t0.addingTimeInterval(120)))   // reset passed: now >= resetRequestsAt
        #expect(quota(9).isLow(.stt, at: t0.addingTimeInterval(119)))
        // No reset header: stale after 15 minutes so fallback can end.
        #expect(quota(9, reset: nil).isLow(.stt, at: t0.addingTimeInterval(14 * 60)))
        #expect(!quota(9, reset: nil).isLow(.stt, at: t0.addingTimeInterval(15 * 60)))
        // Unknown limit never counts as low.
        #expect(!GroqQuota().merging(limits(["x-ratelimit-remaining-requests": "0"]), at: t0).isLow(.stt, at: t0))
        #expect(!GroqQuota().isLow(.stt, at: t0))
    }

    @Test func storePersistsAtomicallyCountsOnly() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dictate-quota-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("nested/groq-quota.json")
        let store = GroqQuotaStore(fileURL: file)
        #expect(store.current == GroqQuota())
        var h = headers(limit: 100, remaining: 7)
        h["Authorization"] = "Bearer gsk_secret"   // never a rate-limit header, must never be stored
        store.record(limits(h, .stt), at: t0)
        store.record(limits(headers(limit: 200, remaining: 150), .cleanup), at: t0)
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(!text.contains("Bearer") && !text.contains("gsk_") && !text.contains("secret"))
        let json = try JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
        for (_, endpoint) in json {
            for (_, value) in endpoint as! [String: Any] { #expect(value is NSNumber) }
        }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .secondsSince1970
        #expect(try decoder.decode(GroqQuota.self, from: Data(text.utf8)) == store.current)
        // A fresh store (new process) loads what was written.
        let reloaded = GroqQuotaStore(fileURL: file)
        #expect(reloaded.current == store.current)
        #expect(reloaded.current.stt.remainingRequests == 7 && reloaded.current.cleanup.limitRequests == 200)
        #expect(try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path) == ["groq-quota.json"])
    }

    @Test func corruptOrMissingFileLoadsEmpty() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dictate-quota-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("groq-quota.json")
        #expect(GroqQuotaStore(fileURL: file).current == GroqQuota())
        try Data("{not json".utf8).write(to: file)
        let store = GroqQuotaStore(fileURL: file)
        #expect(store.current == GroqQuota())
        store.record(limits(headers(limit: 100, remaining: 5)), at: t0)   // and recovers by overwriting
        #expect(GroqQuotaStore(fileURL: file).current.stt.remainingRequests == 5)
    }

    @Test func defaultLocationIsApplicationSupportAndSharedCurrentIsReadable() {
        let home = URL(fileURLWithPath: "/tmp/dictate-quota-home")
        #expect(GroqQuotaStore.defaultFileURL(home: home).path == "/tmp/dictate-quota-home/Library/Application Support/Dictate/groq-quota.json")
        _ = GroqQuota.current   // the spec's host-facing accessor exists and does not trap
    }
}
