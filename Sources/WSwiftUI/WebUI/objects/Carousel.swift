import Foundation

// 1) Subclasses for Carousel and its parts
public class WebCarouselElement: WebElement {}
public class WebCarouselInnerElement: WebElement {}
public class WebCarouselItemElement: WebElement {}
public class WebCarouselIndicatorContainerElement: WebElement {}
public class WebCarouselIndicatorElement: WebElement {}
public class WebCarouselControlElement: WebElement {}

// 2) Fluent modifiers for Carousel container
public extension WebCarouselElement {
    /// Enables automatic cycling with a given interval (in ms)
    @discardableResult
    func interval(_ ms: Int) -> Self {
        addAttribute(.custom("data-bs-interval=\"\(ms)\""))
        return self
    }
    /// Automatically start cycling on load
    @discardableResult
    func ride(_ on: Bool = true) -> Self {
        if on { addAttribute(.custom("data-bs-ride=\"carousel\"")) }
        return self
    }
    /// Enable wrapping to first/last
    @discardableResult
    func wrap(_ on: Bool = true) -> Self {
        addAttribute(.custom("data-bs-wrap=\"\(on)\""))
        return self
    }
    /// Enable keyboard navigation
    @discardableResult
    func keyboard(_ on: Bool = true) -> Self {
        addAttribute(.custom("data-bs-keyboard=\"\(on)\""))
        return self
    }
    /// Add fade transition
    @discardableResult
    func fade(_ on: Bool = true) -> Self {
        if on { addAttribute(.class("carousel-fade")) }
        return self
    }
}

// 3) Fluent modifiers for inner
public extension WebCarouselInnerElement {
    @discardableResult
    func nameInner() -> Self {
        addAttribute(.class("carousel-inner"))
        return self
    }
}

// 4) Fluent modifiers for items
public extension WebCarouselItemElement {
    @discardableResult
    func active(_ on: Bool = true) -> Self {
        if on { addAttribute(.class("active")) }
        return self
    }
    @discardableResult
    func interval(_ ms: Int) -> Self {
        addAttribute(.custom("data-bs-interval=\"\(ms)\""))
        return self
    }
}

// 5) Fluent modifiers for indicators
public extension WebCarouselIndicatorElement {
    @discardableResult
    func target(_ carouselId: String, index: Int) -> Self {
        addAttribute(.custom("data-bs-target=\"\(WebEscape.attribute("#\(carouselId)"))\""))
        addAttribute(.custom("data-bs-slide-to=\"\(index)\""))
        return self
    }
    @discardableResult
    func active(_ on: Bool = true, label: String? = nil) -> Self {
        if on {
            addAttribute(.class("active"))
            addAttribute(.custom("aria-current=\"true\""))
        }
        if let lbl = label {
            addAttribute(.custom("aria-label=\"\(WebEscape.attribute(lbl))\""))
        }
        return self
    }
}

// 6) Fluent modifiers for controls
public extension WebCarouselControlElement {
    /// Previous control styling
    @discardableResult
    func prev(_ carouselId: String) -> Self {
        addAttribute(.class("carousel-control-prev"))
        addAttribute(.custom("href=\"\(WebEscape.attribute("#\(carouselId)"))\""))
        addAttribute(.custom("role=\"button\""))
        addAttribute(.custom("data-bs-slide=\"prev\""))
        return self
    }
    /// Next control styling
    @discardableResult
    func next(_ carouselId: String) -> Self {
        addAttribute(.class("carousel-control-next"))
        addAttribute(.custom("href=\"\(WebEscape.attribute("#\(carouselId)"))\""))
        addAttribute(.custom("role=\"button\""))
        addAttribute(.custom("data-bs-slide=\"next\""))
        return self
    }
}

// 7) DSL on BaseWebEndpoint
public extension CoreWebEndpoint {
    /// Main carousel container
    @discardableResult
    func Carousel(id: String,
                  interval: Int? = nil,
                  ride: Bool = true,
                  wrap: Bool = true,
                  keyboard: Bool = true,
                  fade: Bool = false,
                  _ content: WebComposerClosure) -> WebCarouselElement {
        let carousel = WebCarouselElement()
        populateCreatedObject(carousel)
        carousel.elementName = "div"
        carousel.addAttribute(.class("carousel"))
        carousel.addAttribute(.class("slide"))
        carousel.addAttribute(.class("wsui-carousel"))
        carousel.addAttribute(.pair("id", id))
        if let iv = interval { carousel.interval(iv) }
        carousel.ride(ride)
        carousel.wrap(wrap)
        carousel.keyboard(keyboard)
        carousel.fade(fade)
        stack.append(carousel)
        content()
        stack.removeAll(where: { $0.builderId == carousel.builderId })
        return carousel
    }
    /// Carousel inner wrapper
    @discardableResult
    func CarouselInner(_ content: WebComposerClosure) -> WebCarouselInnerElement {
        guard let _ = stack.last as? WebCarouselElement else {
            fatalError("CarouselInner must be inside Carousel { ... } block")
        }
        let inner = WebCarouselInnerElement()
        populateCreatedObject(inner)
        inner.elementName = "div"
        inner.nameInner()
        stack.append(inner)
        content()
        stack.removeAll(where: { $0.builderId == inner.builderId })
        return inner
    }
    /// Individual carousel item
    @discardableResult
    func CarouselItem(active: Bool = false,
                      interval: Int? = nil,
                      _ content: WebComposerClosure) -> WebCarouselItemElement {
        guard let _ = stack.last as? WebCarouselInnerElement else {
            fatalError("CarouselItem must be inside CarouselInner { ... } block")
        }
        let item = WebCarouselItemElement()
        populateCreatedObject(item)
        item.elementName = "div"
        item.addAttribute(.class("carousel-item"))
        item.active(active)
        if let iv = interval { item.interval(iv) }
        stack.append(item)
        content()
        stack.removeAll(where: { $0.builderId == item.builderId })
        return item
    }
    /// Carousel indicators container
    @discardableResult
    func CarouselIndicators(id: String,
                             count: Int,
                             activeIndex: Int = 0) -> WebCarouselIndicatorContainerElement {
        guard let _ = stack.last as? WebCarouselElement else {
            fatalError("CarouselIndicators must be inside Carousel { ... } block")
        }
        let container = WebCarouselIndicatorContainerElement()
        populateCreatedObject(container)
        container.elementName = "ol"
        container.addAttribute(.class("carousel-indicators"))
        // Build innerHTML for indicators
        var html = ""
        for idx in 0..<count {
            var classes = ""
            var ariaCurrent = ""
            if idx == activeIndex {
                classes = " active"
                ariaCurrent = " aria-current=\"true\""
            }
            html += "<li data-bs-target=\"\(WebEscape.attribute("#\(id)"))\" data-bs-slide-to=\"\(idx)\" class=\"\(classes)\"\(ariaCurrent)></li>"
        }
        container.addAttribute(.innerHTML(html))
        return container
    }
    /// Previous control
    @discardableResult
    func CarouselControlPrev(id: String, label: String? = nil) -> WebCarouselControlElement {
        guard let _ = stack.last as? WebCarouselElement else {
            fatalError("CarouselControlPrev must be inside Carousel { ... } block")
        }
        let ctrl = WebCarouselControlElement()
        populateCreatedObject(ctrl)
        ctrl.elementName = "a"
        ctrl.prev(id)
        // set inner HTML directly
        let lbl = label ?? "Previous"
        ctrl.addAttribute(.innerHTML("""
<span class=\"carousel-control-prev-icon\" aria-hidden=\"true\"></span>
<span class=\"visually-hidden\">\(WebEscape.html(lbl))</span>
"""))
        return ctrl
    }
    /// Next control
    @discardableResult
    func CarouselControlNext(id: String, label: String? = nil) -> WebCarouselControlElement {
        guard let _ = stack.last as? WebCarouselElement else {
            fatalError("CarouselControlNext must be inside Carousel { ... } block")
        }
        let ctrl = WebCarouselControlElement()
        populateCreatedObject(ctrl)
        ctrl.elementName = "a"
        ctrl.next(id)
        let lbl = label ?? "Next"
        ctrl.addAttribute(.innerHTML("""
<span class=\"carousel-control-next-icon\" aria-hidden=\"true\"></span>
<span class=\"visually-hidden\">\(WebEscape.html(lbl))</span>
"""))
        return ctrl
    }
}

