//
//  Pagination.swift
//  SWWebAppServer
//
//  Created by Adrian on 07/07/2025.
//

import Foundation

// 1) Dedicated subclasses for pagination container, items, and links
public class WebPaginationElement: WebElement {}
public class WebPaginationItemElement: WebElement {}
public class WebPaginationLinkElement: WebElement {}

// 2) Enums for size and alignment
public enum PaginationSize: String {
    case small = "pagination-sm"
    case large = "pagination-lg"
}

public enum PaginationAlignment: String {
    case start = ""
    case center = "justify-content-center"
    case end = "justify-content-end"
}

// 3) Fluent modifiers for pagination container
public extension WebPaginationElement {
    /// Sets pagination size (`pagination-sm` or `pagination-lg`)
    @discardableResult
    func size(_ size: PaginationSize) -> Self {
        addAttribute(.class(size.rawValue))
        return self
    }

    /// Aligns pagination (`justify-content-*`)
    @discardableResult
    func align(_ alignment: PaginationAlignment) -> Self {
        if !alignment.rawValue.isEmpty {
            addAttribute(.class(alignment.rawValue))
        }
        return self
    }
}

// 4) Fluent modifiers for pagination items
public extension WebPaginationItemElement {
    /// Marks the item as active
    @discardableResult
    func active(_ isActive: Bool = true) -> Self {
        if isActive {
            addAttribute(.class("active"))
        }
        return self
    }

    /// Disables the item
    @discardableResult
    func disabled(_ isDisabled: Bool = true) -> Self {
        if isDisabled {
            addAttribute(.class("disabled"))
        }
        return self
    }
}

// 5) DSL factories on BaseWebEndpoint
public extension CoreWebEndpoint {
    /// Creates a <ul class="pagination [pagination-sm|lg] [justify-content-*]"> container
    @discardableResult
    func Pagination(size: PaginationSize? = nil,
                    alignment: PaginationAlignment = .start,
                    _ content: WebComposerClosure) -> WebPaginationElement {
        let pagination = WebPaginationElement()
        populateCreatedObject(pagination)
        pagination.elementName = "ul"
        pagination.addAttribute(.class("pagination"))
        pagination.addAttribute(.class("wsui-pagination"))
        if let sz = size { pagination.class(sz.rawValue) }
        pagination.align(alignment)
        return withParent(pagination, content)
    }

    /// Creates a pagination item with a link or span
    /// - Parameters:
    ///   - page: page number (used as text)
    ///   - href: optional URL; when nil and not active, renders a <span>
    ///   - active: marks this item active
    ///   - disabled: marks this item disabled
    ///
    /// Must sit inside a `Pagination { ... }` (wrapper elements in between are allowed). Anywhere else the
    /// mistake is logged, an HTML comment marks the spot and the item is rendered where it was declared.
    @discardableResult
    func PaginationItem(page: Int,
                        href: String? = nil,
                        active: Bool = false,
                        disabled: Bool = false) -> WebPaginationItemElement {
        requireStructuralParent({ $0 is WebPaginationElement }, among: { $0 is WebPaginationElement },
                                "PaginationItem must be inside Pagination { ... } block")
        // li.page-item
        let item = WebPaginationItemElement()
        populateCreatedObject(item)
        item.elementName = "li"
        item.class("page-item")
        item.active(active)
        item.disabled(disabled)
        return withParent(item) {
            // link or span
            let tagName: String
            if disabled || href == nil {
                tagName = "span"
            } else {
                tagName = "a"
            }
            let link = WebPaginationLinkElement()
            populateCreatedObject(link)
            link.elementName = tagName
            link.class("page-link")
            if let url = href, tagName == "a" {
                link.href(url)
            }
            link.innerHTML("\(page)")
            // span also gets aria-current if active
            if active {
                link.addAttribute(.custom("aria-current=\"page\""))
            }
        }
    }
}
