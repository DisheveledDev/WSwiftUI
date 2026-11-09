import Foundation

// 1) Dedicated subclass for Alert
public class WebAlertElement: WebElement {}


// 3) Fluent methods for alert behaviors
public extension WebAlertElement {
    /// Sets the alert variant (e.g. `.success`, `.danger`, etc.)
    @discardableResult
    func variant(_ variant: BootstrapVariant) -> Self {
        addAttribute(.variant(variant))
        addAttribute(.class("alert-\(variant.rawValue)"))
        return self
    }

    /// Makes the alert dismissible (`.alert-dismissible`)
    @discardableResult
    func dismissible(_ dismissible: Bool = true) -> Self {
        if dismissible {
            addAttribute(.class("alert-dismissible"))
        }
        return self
    }

    /// Applies fade transition (`.fade`)
    @discardableResult
    func fade(_ fade: Bool = true) -> Self {
        if fade {
            addAttribute(.class("fade"))
        }
        return self
    }

    /// Shows the element (`.show`)
    @discardableResult
    func show(_ show: Bool = true) -> Self {
        if show {
            addAttribute(.class("show"))
        }
        return self
    }
}

// 4) DSL on BaseWebEndpoint
public extension CoreWebEndpoint {
    /// Internal helper for creating alert elements
    fileprivate func createAlert(_ `init`: (_ element: WebAlertElement) -> Void) -> WebAlertElement {
        let element = WebAlertElement()
        populateCreatedObject(element)
        `init`(element)
        return element
    }

    /// Builds a Bootstrap alert
    @discardableResult
    func Alert(_ variant: BootstrapVariant = .primary, dismissible: Bool = false, _ content: WebComposerClosure) -> WebAlertElement {
        // Outer <div class="alert alert-<variant>" role="alert">
        let alert = createAlert { el in
            el.elementName = "div"
            el.`class`("alert")
            el.`class`("wsui-alert")
            el.`class`("alert-\(variant.rawValue)")
            el.addAttribute(.pair("role", "alert"))
            if dismissible {
                el.`class`("alert-dismissible")
                el.`class`("fade")
                el.`class`("show")
            }
        }
        return withParent(alert) {
            // User content goes here
            content()
            // Append close button if dismissible
            if dismissible {
                _ = createAlert { el in
                    el.elementName = "button"
                    el.type("button")
                    el.class("btn-close")
                    el.addAttribute(.custom("data-bs-dismiss=\"alert\""))
                    el.addAttribute(.custom("aria-label=\"Close\""))
                }
            }
        }
    }
    
    /// SwiftUI-like state-driven alert.
    @discardableResult
    func Alert(_ title: String,
               isPresented: WebVariableElement,
               variant: BootstrapVariant = .primary,
               message: String? = nil,
               dismissible: Bool = false) -> WebAlertElement {
        let alert = Alert(variant, dismissible: dismissible) {
            Text(title).bold()
            if let message {
                Text(message)
            }
        }
        
        if !isPresented.asBool() {
            alert.class("d-none")
        }
        
        alert.script("""
        function syncAlert\(alert.builderId)(value, _meta) {
            if (value) {
                \(alert.builderId).classList.remove('d-none');
            } else {
                \(alert.builderId).classList.add('d-none');
            }
        }
        addCallback\(isPresented.builderId)(syncAlert\(alert.builderId));
        """)
        
        if dismissible {
            alert.script("""
            \(alert.builderId).addEventListener('closed.bs.alert', function() {
                updateWebVariable\(isPresented.builderId)(false, { source: 'closed.bs.alert', origin: '\(alert.builderId)' });
            });
            """)
        }
        
        return alert
    }
}
