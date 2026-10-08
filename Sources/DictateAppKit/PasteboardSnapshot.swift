import AppKit

/// Every item and every type on a pasteboard, captured as raw data so it can be
/// put back exactly after Dictate borrows the clipboard for a paste (D3).
public struct PasteboardSnapshot: Equatable {
    public struct Item: Equatable {
        public var entries: [(type: NSPasteboard.PasteboardType, data: Data)]

        public static func == (lhs: Item, rhs: Item) -> Bool {
            lhs.entries.map(\.type) == rhs.entries.map(\.type) && lhs.entries.map(\.data) == rhs.entries.map(\.data)
        }
    }

    public var items: [Item]

    public static func capture(_ pasteboard: NSPasteboard) -> PasteboardSnapshot {
        let items = (pasteboard.pasteboardItems ?? []).map { item in
            Item(entries: item.types.compactMap { type in
                item.data(forType: type).map { (type: type, data: $0) }
            })
        }
        return PasteboardSnapshot(items: items)
    }

    /// A copy made while the paste recipient was reading belongs to the user.
    public func restore(to pasteboard: NSPasteboard, ifUnchangedSince changeCount: Int) {
        guard pasteboard.changeCount == changeCount else { return }
        restore(to: pasteboard)
    }

    public func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !items.isEmpty else { return }
        let restored = items.map { item -> NSPasteboardItem in
            let pbItem = NSPasteboardItem()
            for entry in item.entries {
                pbItem.setData(entry.data, forType: entry.type)
            }
            return pbItem
        }
        pasteboard.writeObjects(restored)
    }
}
