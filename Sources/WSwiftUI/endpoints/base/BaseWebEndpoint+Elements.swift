//
//  BaseWebEndpoint+HStack.swift
//  SWWebAppServer
//
//  Created by Adrian on 01/07/2025.
//

public extension CoreWebEndpoint {

    /// The element new elements are added to: the innermost open container, or the document root when no
    /// container is open (so it is never `nil`).
    var parent: WebElement? {
        get {
            return stack.last ?? documentRoot
        }
    }

    internal func populateCreatedObject(_ element: WebElement) {

        // a deterministic, page-unique id (see `WebElement.builderId`)
        element.builderId = nextElementId()
        element.class(element.builderId)

        // put this object within its parent: the innermost open container, otherwise the synthetic
        // document root. No created element ever becomes the root, so every one of them is rendered.
        (stack.last ?? documentRoot).subElements.append(element)

    }

    /// The next element id: `<namespace>_<counter in base 36>`. The namespace is `elementIdNamespace` when
    /// it is set (sanitized), otherwise this endpoint's random one; the counter runs across namespaces, so ids
    /// stay unique even if the namespace changes halfway through a page.
    internal func nextElementId() -> String {
        elementIdCounter += 1
        return "\(currentElementIdNamespace)_\(String(elementIdCounter, radix: 36))"
    }

    /// The namespace new element ids use now.
    internal var currentElementIdNamespace: String {
        guard let raw = elementIdNamespace else {
            return randomElementIdNamespace
        }
        if let cached = sanitizedElementIdNamespace, cached.raw == raw {
            return cached.value ?? randomElementIdNamespace
        }
        let value = WebElementId.sanitizedNamespace(raw)
        sanitizedElementIdNamespace = (raw, value)
        return value ?? randomElementIdNamespace
    }

    func create(_ init: (_ element: WebElement) -> Void) -> WebElement {

        // work out if the parent

        let element = WebElement()

        populateCreatedObject(element)
        `init`(element)

        return element
    }





}
