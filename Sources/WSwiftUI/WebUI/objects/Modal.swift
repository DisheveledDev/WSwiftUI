//
//  Modal.swift
//  SWWebAppServer
//
//  Created by Adrian on 07/07/2025.
//

import Foundation

// 1) Dedicated subclasses for Modal and its parts
public class WebModalElement: WebElement {}
public class WebModalDialogElement: WebElement {}
public class WebModalContentElement: WebElement {}
public class WebModalHeaderElement: WebElement {}
public class WebModalTitleElement: WebElement {}
public class WebModalCloseButtonElement: WebElement {}
public class WebModalBodyElement: WebElement {}
public class WebModalFooterElement: WebElement {}

// 2) Option enum for dialog sizes
public enum ModalSize: String {
    case small  = "modal-sm"
    case large  = "modal-lg"
    case xlarge = "modal-xl"
}

// 3) Fluent modifiers for Modal container
public extension WebModalElement {
    /// Enables fade animation (.fade)
    @discardableResult
    func fade(_ fade: Bool = true) -> Self {
        if fade { addAttribute(.class("fade")) }
        return self
    }

    /// Immediately shows the modal (.show + aria-modal/role)
    @discardableResult
    func show(_ show: Bool = true) -> Self {
        if show {
            addAttribute(.class("show"))
            addAttribute(.custom("aria-modal=\"true\""))
            addAttribute(.custom("role=\"dialog\""))
        }
        return self
    }

    /// Static backdrop (data-bs-backdrop="static", keyboard disabled)
    @discardableResult
    func staticBackdrop(_ static: Bool = true) -> Self {
        if `static` {
            addAttribute(.custom("data-bs-backdrop=\"static\""))
            addAttribute(.custom("data-bs-keyboard=\"false\""))
        }
        return self
    }
}

// 4) Fluent modifiers for Dialog
public extension WebModalDialogElement {
    /// Center vertically (.modal-dialog-centered)
    @discardableResult
    func centered() -> Self {
        addAttribute(.class("modal-dialog-centered"))
        return self
    }

    /// Make scrollable body (.modal-dialog-scrollable)
    @discardableResult
    func scrollable() -> Self {
        addAttribute(.class("modal-dialog-scrollable"))
        return self
    }

    /// Sets dialog size
    @discardableResult
    func size(_ size: ModalSize) -> Self {
        addAttribute(.class(size.rawValue))
        return self
    }
}

// 5) DSL factories on BaseWebEndpoint
public extension CoreWebEndpoint {
    // Internal create helpers
    fileprivate func createModal(_ `init`: (WebModalElement) -> Void) -> WebModalElement {
        let el = WebModalElement()
        populateCreatedObject(el)
        `init`(el)
        return el
    }
    fileprivate func createModalDialog(_ `init`: (WebModalDialogElement) -> Void) -> WebModalDialogElement {
        let el = WebModalDialogElement()
        populateCreatedObject(el)
        `init`(el)
        return el
    }
    fileprivate func createModalContent(_ `init`: (WebModalContentElement) -> Void) -> WebModalContentElement {
        let el = WebModalContentElement()
        populateCreatedObject(el)
        `init`(el)
        return el
    }
    fileprivate func createModalHeader(_ `init`: (WebModalHeaderElement) -> Void) -> WebModalHeaderElement {
        let el = WebModalHeaderElement()
        populateCreatedObject(el)
        `init`(el)
        return el
    }
    fileprivate func createModalTitle(_ `init`: (WebModalTitleElement) -> Void) -> WebModalTitleElement {
        let el = WebModalTitleElement()
        populateCreatedObject(el)
        `init`(el)
        return el
    }
    fileprivate func createModalCloseButton(_ `init`: (WebModalCloseButtonElement) -> Void) -> WebModalCloseButtonElement {
        let el = WebModalCloseButtonElement()
        populateCreatedObject(el)
        `init`(el)
        return el
    }
    fileprivate func createModalBody(_ `init`: (WebModalBodyElement) -> Void) -> WebModalBodyElement {
        let el = WebModalBodyElement()
        populateCreatedObject(el)
        `init`(el)
        return el
    }
    fileprivate func createModalFooter(_ `init`: (WebModalFooterElement) -> Void) -> WebModalFooterElement {
        let el = WebModalFooterElement()
        populateCreatedObject(el)
        `init`(el)
        return el
    }

    /// Main Modal container
    @discardableResult
    func Modal(id: String, fade: Bool = true, staticBackdrop: Bool = false, _ content: WebComposerClosure) -> WebModalElement {
        let modal = createModal { el in
            el.elementName = "div"
            el.class("modal")
            el.class("wsui-modal")
            if fade { el.class("fade") }
            el.addAttribute(.pair("id", id))
            el.addAttribute(.pair("tabindex", "-1"))
            el.addAttribute(.pair("aria-hidden", "true"))
            if staticBackdrop { el.staticBackdrop() }
        }
        stack.append(modal)
        content()
        stack.removeAll(where: { $0.builderId == modal.builderId })
        return modal
    }

    /// Modal dialog wrapper
    @discardableResult
    func ModalDialog(_ content: WebComposerClosure) -> WebModalDialogElement {
        guard let _ = stack.last as? WebModalElement else {
            fatalError("ModalDialog must be inside Modal { ... }")
        }
        let dialog = createModalDialog { el in
            el.elementName = "div"
            el.class("modal-dialog")
        }
        stack.append(dialog)
        content()
        stack.removeAll(where: { $0.builderId == dialog.builderId })
        return dialog
    }

    /// Modal content wrapper
    @discardableResult
    func ModalContent(_ content: WebComposerClosure) -> WebModalContentElement {
        guard let _ = stack.last as? WebModalDialogElement else {
            fatalError("ModalContent must be inside ModalDialog { ... }")
        }
        let contentEl = createModalContent { el in
            el.elementName = "div"
            el.class("modal-content")
        }
        stack.append(contentEl)
        content()
        stack.removeAll(where: { $0.builderId == contentEl.builderId })
        return contentEl
    }

    /// Modal header with optional close button
    @discardableResult
    func ModalHeader(closeButton: Bool = true, _ content: WebComposerClosure) -> WebModalHeaderElement {
        guard let _ = stack.last as? WebModalContentElement else {
            fatalError("ModalHeader must be inside ModalContent { ... }")
        }
        let header = createModalHeader { el in
            el.elementName = "div"
            el.class("modal-header")
        }
        stack.append(header)
        content()
        if closeButton {
            _ = createModalCloseButton { btn in
                btn.elementName = "button"
                btn.type("button")
                btn.class("btn-close")
                btn.addAttribute(.custom("data-bs-dismiss=\"modal\""))
                btn.addAttribute(.custom("aria-label=\"Close\""))
            }
        }
        stack.removeAll(where: { $0.builderId == header.builderId })
        return header
    }

    /// Modal title (<h5 class="modal-title">)
    @discardableResult
    func ModalTitle(_ content: WebComposerClosure) -> WebModalTitleElement {
        guard let _ = stack.last as? WebModalHeaderElement else {
            fatalError("ModalTitle must be inside ModalHeader { ... }")
        }
        let title = createModalTitle { el in
            el.elementName = "h5"
            el.class("modal-title")
        }
        stack.append(title)
        content()
        stack.removeAll(where: { $0.builderId == title.builderId })
        return title
    }

    /// Modal body
    @discardableResult
    func ModalBody(_ content: WebComposerClosure) -> WebModalBodyElement {
        guard let _ = stack.last as? WebModalContentElement else {
            fatalError("ModalBody must be inside ModalContent { ... }")
        }
        let body = createModalBody { el in
            el.elementName = "div"
            el.class("modal-body")
        }
        stack.append(body)
        content()
        stack.removeAll(where: { $0.builderId == body.builderId })
        return body
    }

    /// Modal footer
    @discardableResult
    func ModalFooter(_ content: WebComposerClosure) -> WebModalFooterElement {
        guard let _ = stack.last as? WebModalContentElement else {
            fatalError("ModalFooter must be inside ModalContent { ... }")
        }
        let footer = createModalFooter { el in
            el.elementName = "div"
            el.class("modal-footer")
        }
        stack.append(footer)
        content()
        stack.removeAll(where: { $0.builderId == footer.builderId })
        return footer
    }
    
    /// SwiftUI-like state-driven modal presentation.
    @discardableResult
    func Modal(id: String,
               isPresented: WebVariableElement,
               fade: Bool = true,
               staticBackdrop: Bool = false,
               _ content: WebComposerClosure) -> WebModalElement {
        let modal = Modal(id: id, fade: fade, staticBackdrop: staticBackdrop, content)
        let idJS = ScriptValue.string(id)
        
        modal.script("""
        (function() {
            var el = document.getElementById(\(idJS));
            if (!el) { return; }
        
            function syncModal\(modal.builderId)(value, _meta) {
                var instance = bootstrap.Modal.getOrCreateInstance(el);
                var isShown = el.classList.contains('show');
                if (value && !isShown) {
                    instance.show();
                } else if (!value && isShown) {
                    instance.hide();
                }
            }
        
            addCallback\(isPresented.builderId)(syncModal\(modal.builderId));
            el.addEventListener('shown.bs.modal', function() {
                updateWebVariable\(isPresented.builderId)(true, { source: 'shown.bs.modal', origin: \(idJS) });
            });
            el.addEventListener('hidden.bs.modal', function() {
                updateWebVariable\(isPresented.builderId)(false, { source: 'hidden.bs.modal', origin: \(idJS) });
            });
        })();
        """)
        
        modal.addAttribute(.domLoadedScript("""
        (function() {
            var el = document.getElementById(\(idJS));
            if (!el) { return; }
            if (\(isPresented.builderId) === true) {
                bootstrap.Modal.getOrCreateInstance(el).show();
            }
        })();
        """))
        
        return modal
    }
    
    /// Alias for SwiftUI-style `.sheet(isPresented:)`.
    @discardableResult
    func Sheet(isPresented: WebVariableElement,
               id: String? = nil,
               fade: Bool = true,
               staticBackdrop: Bool = false,
               _ content: WebComposerClosure) -> WebModalElement {
        let sheetId = id ?? "sheet_\(isPresented.builderId)"
        return Modal(id: sheetId, isPresented: isPresented, fade: fade, staticBackdrop: staticBackdrop, content)
    }
}
