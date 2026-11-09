//
//  Button.swift
//  SWWebAppServer
//
//  Created by Adrian on 06/07/2025.
//

import Foundation

// 1) Dedicated subclass for Button
public class WebButtonElement: WebElement {}

public enum ButtonSize: String {
    case small = "btn-sm"
    case large = "btn-lg"
}

// 3) Fluent methods for button behaviors
public extension WebButtonElement {
    /// Base class for all buttons (`btn`)
    @discardableResult
    func `default`() -> Self {
        addAttribute(.class("btn"))
        return self
    }

    /// Sets the button variant (e.g. `.primary`, `.secondary`, etc.)
    @discardableResult
    func variant(_ variant: BootstrapVariant) -> Self {
        addAttribute(.variant(variant))
        addAttribute(.class("btn-\(variant.rawValue)"))
        return self
    }

    /// Sets an outline variant (e.g. `.outline(.primary)`)
    @discardableResult
    func outline(_ style: BootstrapVariant) -> Self {
        addAttribute(.class("btn-outline-\(style.rawValue)"))
        return self
    }

    /// Sets size to small or large
    @discardableResult
    func size(_ size: ButtonSize) -> Self {
        addAttribute(.class(size.rawValue))
        return self
    }

    /// Full width button (`d-block w-100`)
    @discardableResult
    func block() -> Self {
        addAttribute(.class("d-block w-100"))
        return self
    }

    /// Toggles the `active` state
    @discardableResult
    func active(_ isActive: Bool = true) -> Self {
        if isActive {
            addAttribute(.class("active"))
        }
        return self
    }

    /// Disables the button via class and attribute
    @discardableResult
    func disabled(_ isDisabled: Bool = true) -> Self {
        if isDisabled {
            addAttribute(.class("disabled"))
            self.disabled()
        }
        return self
    }
    
}

// 4) Factory on BaseWebEndpoint
public extension CoreWebEndpoint {
    /// Internal helper to create a button
    fileprivate func createButton(_ `init`: (_ element: WebButtonElement) -> Void) -> WebButtonElement {
        let element = WebButtonElement()
        populateCreatedObject(element)
        `init`(element)
        return element
    }

    /// Creates a `<button>` with Bootstrap classes. `title` is plain text (HTML-escaped); to put markup inside the
    /// button use `.innerHTML(...)` on the result.
    @discardableResult
    func Button(_ title: String, type buttonType: String = "button") -> WebButtonElement {
        let button = createButton { el in
            el.elementName = "button"
            el.addAttribute(.type(buttonType))
            el.innerHTML(WebEscape.html(title))
        }
        // default bootstrap btn base class
        button.default()
        button.addAttribute(.class("wsui-button"))
        return button
    }
}

