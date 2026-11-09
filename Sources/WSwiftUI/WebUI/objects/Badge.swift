//
//  Badge.swift
//  SWWebAppServer
//
//  Created by Adrian on 07/07/2025.
//

import Foundation

// 1) Dedicated subclass for Badge
public class WebBadgeElement: WebElement {}

// 2) Variant enum matching Bootstrap badge contextual colors
public enum BootstrapVariant: String {
    case primary, secondary, success, danger, warning, info, light, dark
    var rgb: String {
        switch self {
        case .primary: return "rgb(0, 123, 255)"
        case .secondary: return "rgb(108, 117, 125)"
        case .success: return "rgb(40, 167, 69)"
        case .danger: return "rgb(220, 53, 69)"
        case .warning: return "rgb(255, 193, 7)"
        case .info: return "rgb(23, 162, 184)"
        case .light: return "rgb(248, 249, 250)"
        case .dark: return "rgb(52, 58, 64)"
        }
    }
}

// 3) Fluent modifiers for Badge
public extension WebBadgeElement {
    /// Sets the badge color variant (`bg-<variant>`)
    @discardableResult
    func variant(_ variant: BootstrapVariant) -> Self {
        addAttribute(.variant(variant))
        addAttribute(.class("bg-\(variant.rawValue)"))
        return self
    }

    /// Makes the badge a pill (`rounded-pill`)
    @discardableResult
    func pill(_ isPill: Bool = true) -> Self {
        if isPill {
            addAttribute(.class("rounded-pill"))
        }
        return self
    }

    /// Adds an optional link style (`text-decoration-none`)
    @discardableResult
    func linkStyle(_ enable: Bool = true) -> Self {
        if enable {
            addAttribute(.class("text-decoration-none"))
        }
        return self
    }
}

// 4) DSL factory on BaseWebEndpoint
public extension CoreWebEndpoint {
    /// Renders a `<span class="badge bg-<variant> [rounded-pill]">` with provided text
    @discardableResult
    func Badge(_ title: String,
               variant: BootstrapVariant = .primary,
               pill: Bool = false,
               linkStyle: Bool = false) -> WebBadgeElement {
        let badge = WebBadgeElement()
        populateCreatedObject(badge)
        badge.elementName = "span"
        badge.addAttribute(.class("badge"))
        badge.addAttribute(.class("wsui-badge"))
        badge.addAttribute(.class("bg-\(variant.rawValue)"))
        if pill {
            badge.addAttribute(.class("rounded-pill"))
        }
        if linkStyle {
            badge.addAttribute(.class("text-decoration-none"))
        }
        badge.innerHTML(WebEscape.html(title))
        return badge
    }
}

