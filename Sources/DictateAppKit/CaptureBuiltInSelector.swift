import Foundation

/// Device-selection boundary shared by the fallback engine and hardware-free fixtures.
struct CaptureBuiltInSelector {
    /// Historical single-attempt behavior, retained for the H2 RED control.
    var legacySingleAttempt = true

    func run(select: () throws -> Void, note: (String) -> Void) throws {
        try select()
    }
}
