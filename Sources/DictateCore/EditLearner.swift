import Foundation

/// v1.19 (ST2): which text element an insertion went into.
///
/// Two identities are the same destination only when ALL fields match: the process (`pid`), the element
/// itself (`element`: in production the retained `AXUIElement`, compared with `CFEqual`, which matches the
/// same UI object in the same process), its accessibility role, and the document the element belongs to
/// (`AXDocument` of the element, else of its window; nil when the app exposes none — then the element
/// itself is the document identity). Same app with another field, window or document is NOT the same.
public struct FocusIdentity: Equatable {
    public let pid: Int32
    public let role: String?
    public let document: String?
    public let element: AnyHashable

    public init(pid: Int32, role: String?, document: String?, element: AnyHashable) {
        self.pid = pid
        self.role = role
        self.document = document
        self.element = element
    }
}

/// The focused element at observation time. `readValue` is the ONE value read; the learner calls it only
/// after the identity matched, so another field's text is never read.
public struct FocusSnapshot {
    public let identity: FocusIdentity
    public let readValue: () -> String?

    public init(identity: FocusIdentity, readValue: @escaping () -> String?) {
        self.identity = identity
        self.readValue = readValue
    }
}

/// What the inserter hands the learner after a CONFIRMED insertion: the payload, the field value before it,
/// the read-back that confirmed it, and the identity of the element that read-back came from.
public struct ConfirmedInsertion {
    public let text: String
    public let initial: String
    public let confirmed: String
    public let identity: FocusIdentity?

    public init(text: String, initial: String, confirmed: String, identity: FocusIdentity?) {
        self.text = text
        self.initial = initial
        self.confirmed = confirmed
        self.identity = identity
    }
}

/// v1.19 (ST2): the personal dictionary learner (HeyClicky's "edit within 20 s → dictionary").
///
/// A separate, delayed, read-only observation. It never touches the insertion: it is told about a
/// confirmation after the result is decided and cannot change it. `delay` (virtual in tests) after a
/// confirmed insertion it takes one look at the focused element; it skips unless the element is the same
/// destination (`FocusIdentity`), the value is readable and the inserted span is found between the SAME
/// anchors (`InsertionAnchor`). Only that span is diffed (`EditDiff`), and replaced words are appended to the
/// keyterms file (`KeytermsStore`: dedupe, cap, newest kept). One observation is pending at most: a newer
/// insertion or a new dictation (`cancelPending`) replaces/cancels it. Main queue only. Logs counts and
/// stage names, never words.
public final class EditLearner {
    public static let delay: TimeInterval = 20

    public enum Skip: String, Equatable, Sendable {
        case noIdentity = "no_identity", noAnchor = "no_anchor", noFocus = "no_focus"
        case appChanged = "app_changed", elementChanged = "element_changed", unreadable
        case spanUnlocatable = "span_unlocatable", spanDrift = "span_drift", storeError = "store_error"
    }

    public enum Outcome: Equatable, Sendable {
        case learned(added: Int)
        case skipped(Skip)
    }

    private struct Pending { let id: UInt64; let identity: FocusIdentity; let anchor: InsertionAnchor }

    private let store: KeytermsStore
    private let focused: () -> FocusSnapshot?
    private let schedule: (TimeInterval, @escaping () -> Void) -> Void
    private let log: (String) -> Void
    private var pending: Pending?
    private var nextID: UInt64 = 0

    /// ST2 RED MUTATION — tests only, never set in production: the learner ignores every confirmation.
    public var redMutationDisabled = false
    /// Tests: every outcome, including silent skips.
    public var onOutcome: ((Outcome) -> Void)?
    /// Tests: how many times the 20-s observation actually ran / read a value.
    public private(set) var observations = 0
    public private(set) var valueReads = 0
    public var hasPending: Bool { pending != nil }

    /// - focused: the focused element now (nil = none/unavailable). Production: `AXFocus.snapshot`.
    /// - schedule: runs work on the main queue after a delay (tests: a manual clock).
    public init(store: KeytermsStore, focused: @escaping () -> FocusSnapshot?,
                schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void, log: @escaping (String) -> Void) {
        self.store = store
        self.focused = focused
        self.schedule = schedule
        self.log = log
    }

    /// Called once per confirmed insertion, after its result was delivered.
    public func insertionConfirmed(_ insertion: ConfirmedInsertion) {
        cancelPending()
        guard !redMutationDisabled else { return }
        // No identity = no accessibility destination to come back to (fakes, private pasteboards): silent.
        guard let identity = insertion.identity else { return report(.skipped(.noIdentity), quiet: true) }
        guard let anchor = InsertionAnchor.capture(inserted: insertion.text, initial: insertion.initial,
                                                   confirmed: insertion.confirmed) else {
            return report(.skipped(.noAnchor))
        }
        nextID &+= 1
        let id = nextID
        pending = Pending(id: id, identity: identity, anchor: anchor)
        schedule(Self.delay) { [weak self] in self?.fire(id) }
    }

    /// A new dictation started: the pending observation (if any) never runs.
    public func cancelPending() {
        pending = nil
    }

    private func fire(_ id: UInt64) {
        guard let current = pending, current.id == id else { return }
        pending = nil
        observations += 1
        report(observe(current))
    }

    private func observe(_ pending: Pending) -> Outcome {
        guard let snapshot = focused() else { return .skipped(.noFocus) }
        guard snapshot.identity.pid == pending.identity.pid else { return .skipped(.appChanged) }
        guard snapshot.identity == pending.identity else { return .skipped(.elementChanged) }
        valueReads += 1
        guard let value = snapshot.readValue() else { return .skipped(.unreadable) }
        guard let span = pending.anchor.span(in: value) else { return .skipped(.spanUnlocatable) }
        // Between unique anchors the span can still have grown (text typed at a boundary anchor): a span
        // far larger than the dictation is new writing, not an edit of it.
        guard span.count <= pending.anchor.inserted.count * 2 + 32 else { return .skipped(.spanDrift) }
        let words = Array(EditDiff.replacedWords(inserted: pending.anchor.inserted, observed: span)
            .prefix(EditDiff.maxPerDictation))
        guard !words.isEmpty else { return .learned(added: 0) }
        do { return .learned(added: try store.append(words)) }
        catch { return .skipped(.storeError) }
    }

    private func report(_ outcome: Outcome, quiet: Bool = false) {
        onOutcome?(outcome)
        guard !quiet else { return }
        switch outcome {
        case .learned(let added): log("dict_learn added=\(added)")
        case .skipped(let skip): log("dict_learn added=0 skip=\(skip.rawValue)")
        }
    }
}
