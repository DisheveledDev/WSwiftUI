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
    @discardableResult
    func classFooter() -> Self {
        addAttribute(.class("offcanvas-footer"))
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
        off.addAttribute(.custom("aria-labelledby=\"\(WebEscape.attribute("\(id)Label"))\""))
        off.backdrop(backdrop)
        off.scrollable(scrollable)
        off.keyboard(keyboard)
        stack.append(off)
        content()
        stack.removeAll(where: { $0.builderId == off.builderId })
        return off
    }

    @discardableResult
    func OffCanvasHeader(closeButton: Bool = true,
                         _ content: WebComposerClosure) -> WebOffCanvasHeaderElement {
        guard let _ = stack.last as? WebOffCanvasElement else {
            fatalError("OffCanvasHeader must be inside OffCanvas { ... }")
        }
        let hdr = WebOffCanvasHeaderElement()
        populateCreatedObject(hdr)
        hdr.elementName = "div"
        hdr.classHeader()
        stack.append(hdr)
        content()
        if closeButton {
            let btn = WebOffCanvasCloseButtonElement()
            populateCreatedObject(btn)
            btn.elementName = "button"
            btn.addAttribute(.class("btn-close"))
            btn.addAttribute(.custom("data-bs-dismiss=\"offcanvas\""))
            btn.addAttribute(.custom("aria-label=\"Close\""))
        }
        stack.removeAll(where: { $0.builderId == hdr.builderId })
        return hdr
    }

    @discardableResult
    func OffCanvasTitle(_ content: WebComposerClosure) -> WebOffCanvasTitleElement {
        guard let _ = stack.last as? WebOffCanvasHeaderElement else {
            fatalError("OffCanvasTitle must be inside OffCanvasHeader { ... }")
        }
        let title = WebOffCanvasTitleElement()
        populateCreatedObject(title)
        title.elementName = "h5"
        title.classTitle()
        stack.append(title)
        content()
        stack.removeAll(where: { $0.builderId == title.builderId })
        return title
    }

    @discardableResult
    func OffCanvasBody(_ content: WebComposerClosure) -> WebOffCanvasBodyElement {
        guard let _ = stack.last as? WebOffCanvasElement else {
            fatalError("OffCanvasBody must be inside OffCanvas { ... }")
        }
        let body = WebOffCanvasBodyElement()
        populateCreatedObject(body)
        body.elementName = "div"
        body.classBody()
        stack.append(body)
        content()
        stack.removeAll(where: { $0.builderId == body.builderId })
        return body
    }

    @discardableResult
    func OffCanvasFooter(_ content: WebComposerClosure) -> WebOffCanvasFooterElement {
        guard let _ = stack.last as? WebOffCanvasElement else {
            fatalError("OffCanvasFooter must be inside OffCanvas { ... }")
        }
        let footer = WebOffCanvasFooterElement()
        populateCreatedObject(footer)
        footer.elementName = "div"
        footer.classFooter()
        stack.append(footer)
        content()
        stack.removeAll(where: { $0.builderId == footer.builderId })
        return footer
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
