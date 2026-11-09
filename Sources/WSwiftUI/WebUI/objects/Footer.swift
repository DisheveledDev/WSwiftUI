//
//  Footer.swift
//  SWWebAppServer
//
//  Created by Adrian on 08/07/2025.
//

import Foundation

// 1) Subclass for Footer element
public class WebFooterElement: WebElement {}

// 2) Fluent modifiers for Footer
public extension WebFooterElement {
    /// Adds the Bootstrap footer class (for default styling)
    @discardableResult
    func `default`() -> Self {
        addAttribute(.class("footer"))
        return self
    }

    /// Makes the footer sticky at the bottom of the viewport using fixed positioning
    @discardableResult
    func sticky(_ on: Bool = true) -> Self {
        if on {
            // Use Bootstrap's fixed-bottom for persistent footer
            addAttribute(.class("fixed-bottom"))
        }
        return self
    }

    /// Toggles a CSS class when scrolled past threshold to collapse or expand the footer
    @discardableResult
    func collapseOnScroll(threshold: Int = 100,
                          collapsedClass: String = "footer-collapsed") -> Self {
        // Ensure the footer has an ID for targeting
        let idName = "footer_\(builderId)"
        addAttribute(.pair("id", idName))
        // Listen to scroll events to toggle the collapsedClass (embedded as a script-safe string literal)
        let classLiteral = WebJSON.scriptString(collapsedClass)
        addAttribute(.script("""
window.addEventListener('scroll', function() {
  var el = document.getElementById('\(idName)');
  if (!el) return;
  if (window.scrollY > \(threshold)) {
    el.classList.add(\(classLiteral));
  } else {
    el.classList.remove(\(classLiteral));
  }
});
"""))
        return self
    }
}

// 3) DSL factory on BaseWebEndpoint
public extension CoreWebEndpoint {
    /// Creates a <footer> element and nests any content inside
    @discardableResult
    func Footer(_ content: WebComposerClosure) -> WebFooterElement {
        let footer = WebFooterElement()
        populateCreatedObject(footer)
        footer.elementName = "footer"
        footer.addAttribute(.class("wsui-footer"))
        // Default spacing and background (if needed)
        footer.addAttribute(.class("py-3"))
        return withParent(footer, content)
    }
}
