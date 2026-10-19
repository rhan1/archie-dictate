import Foundation

/// v56 ST2: the personal dictionary (`~/.claude/dictate/keyterms.txt`, one term per line, newest LAST).
public struct KeytermsStore: Sendable {
    public let url: URL
    public static let cap = 200

    public init(url: URL) {
        self.url = url
    }

    /// Appends each term not already present (case-sensitive exact match after trimming), keeping the
    /// newest `cap` lines (oldest dropped). Atomic write (temp file in the same dir + rename). Creates the
    /// parent dir if missing. Returns how many terms were added.
    @discardableResult public func append(_ terms: [String]) throws -> Int {
        let parentDir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)

        let existing: [String]
        if FileManager.default.fileExists(atPath: url.path),
           let content = try? String(contentsOf: url, encoding: .utf8) {
            existing = content
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        } else {
            existing = []
        }

        var existingSet = Set(existing)
        var resultLines = existing
        var addedCount = 0

        for term in terms {
            let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if !existingSet.contains(trimmed) {
                existingSet.insert(trimmed)
                resultLines.append(trimmed)
                addedCount += 1
            }
        }

        if resultLines.count > Self.cap {
            resultLines = Array(resultLines.suffix(Self.cap))
        }

        let tempName = ".\(url.lastPathComponent).tmp.\(UUID().uuidString)"
        let tempURL = parentDir.appendingPathComponent(tempName)

        var renameSucceeded = false
        defer {
            if !renameSucceeded {
                try? FileManager.default.removeItem(at: tempURL)
            }
        }

        let output = resultLines.isEmpty ? "" : (resultLines.joined(separator: "\n") + "\n")
        try output.write(to: tempURL, atomically: false, encoding: .utf8)

        guard Darwin.rename(tempURL.path, url.path) == 0 else {
            let err = errno
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(err),
                userInfo: [NSLocalizedDescriptionKey: "Failed to rename \(tempURL.path) to \(url.path): \(err)"]
            )
        }
        renameSucceeded = true

        return addedCount
    }

    /// The newest `n` non-empty lines, oldest-first order preserved (so `newest(50)` is the last 50 lines).
    public func newest(_ n: Int) -> [String] {
        guard n > 0 else { return [] }
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            return []
        }
        let lines = content
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if lines.count <= n {
            return lines
        }
        return Array(lines.suffix(n))
    }
}
