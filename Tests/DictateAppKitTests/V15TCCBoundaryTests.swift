import Foundation
import Testing
@testable import DictateAppKit

@Suite @MainActor struct V15TCCBoundaryTests {
    @Test func permissionBoundaryIsAppRuntimeOnly() {
        let bundle = URL(fileURLWithPath: "/private/fixture/Dictate.app")
        let app = bundle.appendingPathComponent("Contents/MacOS/Dictate")
        let good = TextInserter.isAppRuntime(bundleURL: bundle, executableURL: app)
        let node = TextInserter.isAppRuntime(bundleURL: URL(fileURLWithPath: "/opt/homebrew/bin"),
                                            executableURL: URL(fileURLWithPath: "/opt/homebrew/bin/node"))
        let outside = TextInserter.isAppRuntime(bundleURL: bundle,
            executableURL: URL(fileURLWithPath: "/private/fixture/Dictate.app/Contents/MacOS-other/Dictate"))
        print("DICTATE TCC BOUNDARY app=\(good) node=\(node) outside=\(outside)")
        #expect(good && !node && !outside)
        #expect(AppController.isAppRuntime(bundleURL: bundle, executableURL: app))
        #expect(!AppController.isAppRuntime(bundleURL: bundle, executableURL: nil))
    }
}
