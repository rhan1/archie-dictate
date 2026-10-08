import Testing
import DictateCore

@Suite("InsertionTarget")
struct InsertionTargetTests {
    @Test(arguments: ["com.apple.SecurityAgent", "com.apple.UserNotificationCenter",
                      "com.apple.coreservices.uiagent", "com.apple.CoreServicesUIAgent"])
    func transientStartIsIgnored(bundleID: String) {
        let start = InsertionTarget(pid: 1, bundleID: bundleID)
        #expect(InsertionTarget.decide(start: start, now: InsertionTarget(pid: 2, bundleID: "dev.warp.Warp-Stable")) == .paste)
        #expect(InsertionTarget.decide(start: start, now: nil) == .paste)
    }
    @Test func injectedAppIdentifierIsIgnored() {
        let start = InsertionTarget(pid: 1, bundleID: "org.example.dictation")
        #expect(InsertionTarget.decide(start: start, now: nil, appBundleID: "org.example.dictation") == .paste)
        #expect(InsertionTarget.decide(start: start, now: nil, appBundleID: "org.example.other") == .hold)
        #expect(InsertionTarget.decide(start: start, now: nil, appBundleID: nil) == .hold)
    }
    @Test func realAppStillLocksToPID() {
        let start = InsertionTarget(pid: 1, bundleID: "dev.warp.Warp-Stable")
        #expect(InsertionTarget.decide(start: start, now: start) == .paste)
        #expect(InsertionTarget.decide(start: start, now: InsertionTarget(pid: 2, bundleID: start.bundleID)) == .hold)
        #expect(InsertionTarget.decide(start: start, now: nil) == .hold)
        #expect(InsertionTarget.decide(start: nil, now: start) == .paste)
    }
}
