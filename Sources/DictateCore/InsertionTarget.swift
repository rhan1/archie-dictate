/// The application that was frontmost when recording began.
public struct InsertionTarget: Equatable, Sendable {
    public var pid: Int32
    public var bundleID: String

    public init(pid: Int32, bundleID: String) {
        self.pid = pid
        self.bundleID = bundleID
    }

    public enum Decision: Equatable, Sendable { case paste, hold }

    public static func decide(start: InsertionTarget?, now: InsertionTarget?) -> Decision {
        guard let start else { return .paste }
        return start.pid == now?.pid ? .paste : .hold
    }
}
