import Foundation

/// v1.19 (ST2): where a confirmed insertion sits in its field, so a later read can compare ONLY that span.
///
/// Captured from the confirmation read-back the inserter already has: the read-back must equal the
/// pre-insertion value with exactly one placement of the verbatim payload (pure insertion at the caret, or a
/// replaced selection). Anchors are up to `length` characters on each side; a shorter anchor means it reaches
/// the start/end of the value, and the document boundary then is the anchor. Every ambiguity is a skip:
/// no verbatim placement, more than one placement, an anchor not found or found more than once.
public struct InsertionAnchor: Equatable, Sendable {
    public static let length = 24
    /// A payload repeated more often than this in the field is treated as ambiguous without checking each copy.
    static let maxCandidates = 64

    public let inserted: String
    public let prefix: String
    public let suffix: String
    /// The prefix reaches the start of the value (the start is part of the anchor).
    public let prefixAtStart: Bool
    /// The suffix reaches the end of the value (the end is part of the anchor).
    public let suffixAtEnd: Bool

    public init(inserted: String, prefix: String, suffix: String, prefixAtStart: Bool, suffixAtEnd: Bool) {
        self.inserted = inserted
        self.prefix = prefix
        self.suffix = suffix
        self.prefixAtStart = prefixAtStart
        self.suffixAtEnd = suffixAtEnd
    }

    /// nil when the placement of `inserted` in `confirmed` is absent or not unique.
    public static func capture(inserted: String, initial: String, confirmed: String) -> InsertionAnchor? {
        guard !inserted.isEmpty else { return nil }
        var placements: [Range<String.Index>] = []
        let candidates = occurrences(of: inserted, in: confirmed[...], limit: maxCandidates + 1)
        guard candidates.count <= maxCandidates else { return nil }
        for range in candidates {
            let before = confirmed[..<range.lowerBound]
            let after = confirmed[range.upperBound...]
            // Everything outside the payload is unchanged text from before the insertion.
            guard before.count + after.count <= initial.count, initial.starts(with: before),
                  initial.reversed().starts(with: after.reversed()) else { continue }
            placements.append(range)
            if placements.count > 1 { return nil }
        }
        guard let range = placements.first else { return nil }
        let before = confirmed[..<range.lowerBound]
        let after = confirmed[range.upperBound...]
        return InsertionAnchor(inserted: inserted,
                               prefix: String(before.suffix(length)), suffix: String(after.prefix(length)),
                               prefixAtStart: before.count <= length, suffixAtEnd: after.count <= length)
    }

    /// The text now between the SAME prefix and suffix, or nil when either anchor is missing or not unique.
    public func span(in observed: String) -> String? {
        let start: String.Index
        if prefixAtStart {
            guard observed.starts(with: prefix) else { return nil }
            start = observed.index(observed.startIndex, offsetBy: prefix.count)
        } else {
            let hits = Self.occurrences(of: prefix, in: observed[...], limit: 2)
            guard hits.count == 1 else { return nil }
            start = hits[0].upperBound
        }
        let rest = observed[start...]
        let end: String.Index
        if suffixAtEnd {
            guard rest.reversed().starts(with: suffix.reversed()) else { return nil }
            end = observed.index(observed.endIndex, offsetBy: -suffix.count)
        } else {
            let hits = Self.occurrences(of: suffix, in: rest, limit: 2)
            guard hits.count == 1 else { return nil }
            end = hits[0].lowerBound
        }
        guard start <= end else { return nil }
        return String(observed[start..<end])
    }

    /// Every placement of `needle`, overlapping ones included (a non-overlapping search would call an
    /// ambiguous anchor unique), stopping after `limit`.
    static func occurrences(of needle: String, in text: Substring, limit: Int) -> [Range<String.Index>] {
        var found: [Range<String.Index>] = []
        var from = text.startIndex
        while found.count < limit, from < text.endIndex, let hit = text[from...].firstRange(of: needle) {
            found.append(hit)
            from = text.index(after: hit.lowerBound)
        }
        return found
    }
}
