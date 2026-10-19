import AppKit
import DictateCore
#if canImport(ApplicationServices)
import ApplicationServices
#endif

/// The read-only accessibility helper shared by insertion confirmation (`TextInserter`, C2 + paste) and the
/// ST2 learner: the focused element, its value text, and its identity. Every read fails closed outside an
/// app bundle (`TextInserter.isAppRuntime`), so tests and command-line tools never reach live AX.
enum AXFocus {
    static func focusedElement() -> AXUIElement? {
        guard TextInserter.isAppRuntime() else { return nil }
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef)
        guard err == .success, let focusedRef, CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else {
            return nil
        }
        return (focusedRef as! AXUIElement)
    }

    static func readTexts(from element: AXUIElement) -> [String] {
        var texts: [String] = []
        var valueRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef) == .success, let valueRef {
            if let str = valueRef as? String {
                texts.append(str)
            } else if let attr = valueRef as? NSAttributedString {
                texts.append(attr.string)
            }
        }
        return texts
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    /// ST2 identity (see `FocusIdentity`): pid + the element (CFEqual) + role + AXDocument of the element,
    /// else of its window. Metadata reads only; never the value. nil without a pid.
    static func identity(of element: AXUIElement) -> FocusIdentity? {
        guard TextInserter.isAppRuntime() else { return nil }
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success, pid > 0 else { return nil }
        let role = attribute(element, kAXRoleAttribute) as? String
        var document = attribute(element, kAXDocumentAttribute) as? String
        if document == nil, let window = attribute(element, kAXWindowAttribute),
           CFGetTypeID(window) == AXUIElementGetTypeID() {
            document = attribute(window as! AXUIElement, kAXDocumentAttribute) as? String
        }
        return FocusIdentity(pid: pid, role: role, document: document, element: AnyHashable(element))
    }

    /// The learner's observation: the focused element's identity now, and its value on demand (one read).
    static func snapshot() -> FocusSnapshot? {
        guard let element = focusedElement(), let identity = identity(of: element) else { return nil }
        return FocusSnapshot(identity: identity, readValue: { readTexts(from: element).first })
    }
}
