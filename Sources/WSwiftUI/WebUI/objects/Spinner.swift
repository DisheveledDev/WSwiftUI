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
    @discardableResult
    public func size(_ size: SpinnerSize) -> Self {
        addAttribute(.class(size.rawValue))
        return self
    }

    @discardableResult
    public func type(_ type: SpinnerType) -> Self {
        addAttribute(.class(type.rawValue))
        return self
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
        // use your generic `create(…)` that hands you back a SpinnerElement
        
        let spinner: WebSpinnerElement = create { el in
            el.elementName = "div"
            el.class(el.builderId)
            el.class("spinner-border")
            el.class("wsui-spinner")
            el.addAttribute(.pair("role", "status"))
        }
        stack.append(spinner)
        
        // create the span within
        _ = create { el in
            el.elementName = "span"
            el.innerHTML(WebEscape.html(text ?? "Loading..."))
            el.class("visually-hidden")
        }
        
        stack.removeAll(where: { $0.builderId == spinner.builderId })

        return spinner
    }
}



