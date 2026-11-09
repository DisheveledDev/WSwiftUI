import Foundation

// 1) Dedicated subclasses for Offcanvas and its parts
public class WebOffCanvasElement: WebElement {}
public class WebOffCanvasHeaderElement: WebElement {}
public class WebOffCanvasTitleElement: WebElement {}
public class WebOffCanvasCloseButtonElement: WebElement {}
public class WebOffCanvasBodyElement: WebElement {}
public class WebOffCanvasFooterElement: WebElement {}

// 2) Placement enum
public enum OffCanvasPlacement: String {
    case start  = "offcanvas-start"
    case end    = "offcanvas-end"
    case top    = "offcanvas-top"
    case bottom = "offcanvas-bottom"
}

// 3) Fluent modifiers on the container
public extension WebOffCanvasElement {
    @discardableResult
    func backdrop(_ on: Bool) -> Self {
        addAttribute(.custom("data-bs-backdrop=\"\(on ? "true" : "false")\""))
        return self
    }

    @discardableResult
    func scrollable(_ on: Bool) -> Self {
        addAttribute(.custom("data-bs-scroll=\"\(on ? "true" : "false")\""))
        return self
    }

    @discardableResult
    func keyboard(_ on: Bool) -> Self {
        addAttribute(.custom("data-bs-keyboard=\"\(on ? "true" : "false")\""))
        return self
    }

    @discardableResult
    func show(_ on: Bool = true) -> Self {
        if on {
            addAttribute(.class("show"))
            addAttribute(.custom("aria-modal=\"true\""))
            addAttribute(.pair("role", "dialog"))
        }
        return self
    }

    @discardableResult
    func width(_ css: String) -> Self {
        addAttribute(.style("width: \(css)"))
        return self
    }

    @discardableResult
    func height(_ css: String) -> Self {
        addAttribute(.style("height: \(css)"))
        return self
    }
}

// 4) Fluent modifiers on header
public extension WebOffCanvasHeaderElement {
    @discardableResult
    func classHeader() -> Self {
        addAttribute(.class("offcanvas-header"))
        return self
    }
}

// 5) Fluent modifiers on title
public extension WebOffCanvasTitleElement {
    @discardableResult
    func classTitle() -> Self {
        addAttribute(.class("offcanvas-title"))
        return self
    }
}

// 6) Fluent modifiers on body
public extension WebOffCanvasBodyElement {
    @discardableResult
    func classBody() -> Self {
        addAttribute(.class("offcanvas-body"))
        return self
    }
}

// 7) Fluent modifiers on footer
public extension WebOffCanvasFooterElement {
    /// Styles the element as the panel's footer. Bootstrap 5.3 has no `offcanvas-footer` (it used to be
    /// emitted here, and styled nothing), so the footer is built from utilities: `mt-auto` pins it to the
    /// bottom of the panel (a flex column) when it is a direct child of the `OffCanvas`, `flex-shrink-0`
    /// keeps it whole while a long `OffCanvasBody` scrolls, `p-3` gives it the panel's default padding
    /// (1rem, like the header and body), and `border-top` separates it from the body like a modal footer.
    /// `wsui-offcanvas-footer` is the hook for app styles.
    @discardableResult
    func classFooter() -> Self {
        addAttribute(.class("wsui-offcanvas-footer"))
        addAttribute(.class("mt-auto"))
        addAttribute(.class("flex-shrink-0"))
        addAttribute(.class("p-3"))
        addAttribute(.class("border-top"))
        return self
    }
}

// 8) DSL on BaseWebEndpoint
public extension CoreWebEndpoint {
    @discardableResult
    func OffCanvas(
        id: String,
        placement: OffCanvasPlacement = .start,
        backdrop: Bool = true,
        scrollable: Bool = false,
        keyboard: Bool = true,
        _ content: WebComposerClosure
    ) -> WebOffCanvasElement {
        let off = WebOffCanvasElement()
        populateCreatedObject(off)
        off.elementName = "div"
        off.addAttribute(.class("offcanvas"))
        off.addAttribute(.class("wsui-offcanvas"))
        off.addAttribute(.class(placement.rawValue))
        off.addAttribute(.pair("id", id))
        off.addAttribute(.pair("tabindex", "-1"))
        off.addAttribute(.pair("aria-labelledby", "\(id)Label"))
        off.backdrop(backdrop)
        off.scrollable(scrollable)
        off.keyboard(keyboard)
        withParent(off, content)
        off.labelWithTitle(defaultId: "\(id)Label")
        return off
    }

    // The parts below must sit inside the part named in their message. Wrapper elements in between are
    // allowed. Anywhere else the mistake is logged, an HTML comment marks the spot and the part is
    // rendered where it was declared.

    @discardableResult
    func OffCanvasHeader(closeButton: Bool = true,
                         _ content: WebComposerClosure) -> WebOffCanvasHeaderElement {
        requireStructuralParent({ $0 is WebOffCanvasElement }, among: isOffCanvasPart,
                                "OffCanvasHeader must be inside OffCanvas { ... }")
        let hdr = WebOffCanvasHeaderElement()
        populateCreatedObject(hdr)
        hdr.elementName = "div"
        hdr.classHeader()
        return withParent(hdr) {
            content()
            if closeButton {
                let btn = WebOffCanvasCloseButtonElement()
                populateCreatedObject(btn)
                btn.elementName = "button"
                btn.type("button")   // inside a form, a button without a type submits it
                btn.addAttribute(.class("btn-close"))
                btn.addAttribute(.custom("data-bs-dismiss=\"offcanvas\""))
                btn.addAttribute(.custom("aria-label=\"Close\""))
            }
        }
    }

    @discardableResult
    func OffCanvasTitle(_ content: WebComposerClosure) -> WebOffCanvasTitleElement {
        requireStructuralParent({ $0 is WebOffCanvasHeaderElement }, among: isOffCanvasPart,
                                "OffCanvasTitle must be inside OffCanvasHeader { ... }")
        let title = WebOffCanvasTitleElement()
        populateCreatedObject(title)
        title.elementName = "h5"
        title.classTitle()
        return withParent(title, content)
    }

    @discardableResult
    func OffCanvasBody(_ content: WebComposerClosure) -> WebOffCanvasBodyElement {
        requireStructuralParent({ $0 is WebOffCanvasElement }, among: isOffCanvasPart,
                                "OffCanvasBody must be inside OffCanvas { ... }")
        let body = WebOffCanvasBodyElement()
        populateCreatedObject(body)
        body.elementName = "div"
        body.classBody()
        return withParent(body, content)
    }

    @discardableResult
    func OffCanvasFooter(_ content: WebComposerClosure) -> WebOffCanvasFooterElement {
        requireStructuralParent({ $0 is WebOffCanvasElement }, among: isOffCanvasPart,
                                "OffCanvasFooter must be inside OffCanvas { ... }")
        let footer = WebOffCanvasFooterElement()
        populateCreatedObject(footer)
        footer.elementName = "div"
        footer.classFooter()
        return withParent(footer, content)
    }
    
    /// SwiftUI-like state-driven off-canvas presentation.
    @discardableResult
    func OffCanvas(
        id: String,
        isPresented: WebVariableElement,
        placement: OffCanvasPlacement = .start,
        backdrop: Bool = true,
        scrollable: Bool = false,
        keyboard: Bool = true,
        _ content: WebComposerClosure
    ) -> WebOffCanvasElement {
        let panel = OffCanvas(id: id,
                              placement: placement,
                              backdrop: backdrop,
                              scrollable: scrollable,
                              keyboard: keyboard,
                              content)
        let idJS = ScriptValue.string(id)
        
        panel.script("""
        (function() {
            var el = document.getElementById(\(idJS));
            if (!el) { return; }
        
            function syncOffCanvas\(panel.builderId)(value, _meta) {
                var instance = bootstrap.Offcanvas.getOrCreateInstance(el);
                var isShown = el.classList.contains('show');
                if (value && !isShown) {
                    instance.show();
                } else if (!value && isShown) {
                    instance.hide();
                }
            }
        
            addCallback\(isPresented.builderId)(syncOffCanvas\(panel.builderId));
            el.addEventListener('shown.bs.offcanvas', function() {
                updateWebVariable\(isPresented.builderId)(true, { source: 'shown.bs.offcanvas', origin: \(idJS) });
            });
            el.addEventListener('hidden.bs.offcanvas', function() {
                updateWebVariable\(isPresented.builderId)(false, { source: 'hidden.bs.offcanvas', origin: \(idJS) });
            });
        })();
        """)
        
        panel.addAttribute(.domLoadedScript("""
        (function() {
            var el = document.getElementById(\(idJS));
            if (!el) { return; }
            if (\(isPresented.builderId) === true) {
                bootstrap.Offcanvas.getOrCreateInstance(el).show();
            }
        })();
        """))

        return panel
    }
}

fileprivate extension WebOffCanvasElement {

    /// Points the panel's `aria-labelledby` at its first `OffCanvasTitle` (looking through wrappers, not
    /// into a nested panel), as Bootstrap's markup does: the title gets the id `defaultId` (`<id>Label`)
    /// unless it already has an id, which is then used instead. A panel without a title gets no
    /// `aria-labelledby`, which would name an element that doesn't exist.
    func labelWithTitle(defaultId: String) {
        func firstTitle(in element: WebElement) -> WebOffCanvasTitleElement? {
            for child in element.subElements {
                if let title = child as? WebOffCanvasTitleElement { return title }
                if child is WebOffCanvasElement { continue }
                if let title = firstTitle(in: child) { return title }
            }
            return nil
        }
        let isLabelledBy: (WebCoreElementAttribute) -> Bool = { attribute in
            if case .pair(let name, _) = attribute { return name == "aria-labelledby" }
            return false
        }
        guard let title = firstTitle(in: self) else {
            attributes.removeAll(where: isLabelledBy)
            return
        }
        let existingId = title.attributes.lazy.compactMap { attribute -> String? in
            switch attribute {
            case .id(let id): return id
            case .pair(let name, let id) where name.lowercased() == "id": return id
            default: return nil
            }
        }.first
        if existingId == nil {
            title.id(defaultId)
        }
        let labelId = existingId ?? defaultId
        attributes = attributes.map { isLabelledBy($0) ? .pair("aria-labelledby", labelId) : $0 }
    }
}

/// The elements that make up an off-canvas panel's structure. Anything else on the builder stack is a wrapper.
fileprivate func isOffCanvasPart(_ element: WebElement) -> Bool {
    return element is WebOffCanvasElement
        || element is WebOffCanvasHeaderElement
        || element is WebOffCanvasTitleElement
        || element is WebOffCanvasBodyElement
        || element is WebOffCanvasFooterElement
}
