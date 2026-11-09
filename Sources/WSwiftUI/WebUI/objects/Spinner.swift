//
//  Spinner.swift
//  SWWebAppServer
//
//  Created by Adrian on 04/07/2025.
//

public enum SpinnerSize: String {
    case small = "spinner-border-sm"
    case medium = ""
    case large = "spinner-border-lg"
}

public enum SpinnerType: String {
    case border = "spinner-border"
    case grow = "spinner-grow"
}


// 2) Default-implement the four spinner methods
public class WebSpinnerElement : WebElement {
    internal var spinnerType: SpinnerType = .border
    internal var spinnerSize: SpinnerSize = .medium

    /// Sets the size: `.small` is Bootstrap's `spinner-border-sm` (`spinner-grow-sm` for a growing
    /// spinner), `.medium` Bootstrap's default size, and `.large` 3rem square (Bootstrap has no large class:
    /// `spinner-border-lg`, which used to be added, doesn't exist, so large spinners rendered medium).
    @discardableResult
    public func size(_ size: SpinnerSize) -> Self {
        spinnerSize = size
        applySpinnerStyle()
        return self
    }

    /// Sets the type, replacing the current one (a spinner used to end up with both `spinner-border` and
    /// `spinner-grow`, which drew a growing ring).
    @discardableResult
    public func type(_ type: SpinnerType) -> Self {
        spinnerType = type
        applySpinnerStyle()
        return self
    }

    /// Bootstrap's inline size for a large spinner.
    private static let largeStyle = "width: 3rem; height: 3rem"

    /// Writes `spinnerType` and `spinnerSize` into the element's classes and style.
    private func applySpinnerStyle() {
        func spinnerClass(_ attribute: WebCoreElementAttribute, in names: Set<String>) -> Bool {
            if case .class(let name) = attribute { return names.contains(name) }
            return false
        }
        // the type class stays where it is (Spinner() adds spinner-border first)
        let typeClasses: Set<String> = ["spinner-border", "spinner-grow"]
        if let index = attributes.firstIndex(where: { spinnerClass($0, in: typeClasses) }) {
            attributes[index] = .class(spinnerType.rawValue)
            let rest = attributes[(index + 1)...].filter { spinnerClass($0, in: typeClasses) == false }
            attributes.replaceSubrange((index + 1)..., with: rest)
        } else {
            addAttribute(.class(spinnerType.rawValue))
        }
        let sizeClasses: Set<String> = ["spinner-border-sm", "spinner-grow-sm", "spinner-border-lg", ""]
        attributes.removeAll { attribute in
            if spinnerClass(attribute, in: sizeClasses) { return true }
            if case .style(let style) = attribute { return style == Self.largeStyle }
            return false
        }
        switch spinnerSize {
        case .small: addAttribute(.class("\(spinnerType.rawValue)-sm"))
        case .medium: break
        case .large: addAttribute(.style(Self.largeStyle))
        }
    }
}

// 3) The BaseWebEndpoint factory, no parameters…
public extension CoreWebEndpoint {
    
    fileprivate func create(_ init: (_ element: WebSpinnerElement) -> Void) -> WebSpinnerElement {
        
        let element = WebSpinnerElement()
        populateCreatedObject(element)
        `init`(element)
        return element
        
    }
    
    @discardableResult
    func Spinner(_ text: String? = nil) -> WebSpinnerElement {
        // (the builderId class comes from populateCreatedObject)
        let spinner: WebSpinnerElement = create { el in
            el.elementName = "div"
            el.class("spinner-border")
            el.class("wsui-spinner")
            el.addAttribute(.pair("role", "status"))
        }
        return withParent(spinner) {
            // create the span within
            _ = create { el in
                el.elementName = "span"
                el.innerHTML(WebEscape.html(text ?? "Loading..."))
                el.class("visually-hidden")
            }
        }
    }
}



