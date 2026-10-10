import Foundation

/// Why a key read failed when it is worth logging (counts/labels only, never the key).
public enum KeyReadError: Error, Equatable, Sendable {
    /// The read would have needed a keychain dialog (or the tool hung, likely on one).
    case promptSuppressed
}

/// Reads an API key through `/usr/bin/security`. The keychain ACL names that tool, whose
/// identity never changes, so a rebuilt (re-signed) Dictate or host never triggers the
/// "wants to access key … in your keychain" dialog the in-process SecItem path can raise.
public struct KeychainToolReader: Sendable {
    public struct Output: Sendable, Equatable {
        public let status: Int32
        public let stdout: String
        public init(status: Int32, stdout: String) { self.status = status; self.stdout = stdout }
    }
    public static let tool = "/usr/bin/security"
    /// A tool that does not answer in time is treated as blocked on a dialog and killed.
    public static let timeout: TimeInterval = 3
    public let account: String
    private let run: @Sendable (String, [String]) throws -> Output

    public init(account: String = NSUserName(),
                run: @escaping @Sendable (String, [String]) throws -> Output = { try KeychainToolReader.runTool($0, $1) }) {
        self.account = account
        self.run = run
    }

    public func read(service: String) throws -> String {
        let out = try run(Self.tool, ["find-generic-password", "-s", service, "-a", account, "-w"])
        if out.status == -1 { throw KeyReadError.promptSuppressed }   // killed after the timeout
        let key = out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard out.status == 0, !key.isEmpty else { throw TranscriptionError.missingKey }
        return key
    }

    /// Runs a tool with no stdin; kills it after `timeout` (status then non-zero).
    public static func runTool(_ executable: String, _ arguments: [String], timeout: TimeInterval = timeout) throws -> Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        try process.run()
        if done.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = done.wait(timeout: .now() + 1)
            return Output(status: -1, stdout: "")
        }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        return Output(status: process.terminationStatus, stdout: String(decoding: data, as: UTF8.self))
    }
}
