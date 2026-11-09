//
//  HStack.swift
//  SWWebAppServer
//
//  Created by Adrian on 01/07/2025.
//

public extension CoreWebEndpoint {
    
    @discardableResult
    func HStack(alignment: FlexAlignItems = .stretch,
                justify: FlexJustify = .start,
                spacing: Int? = nil,
                _ closure: WebComposerClosure) -> WebElement {
        func gapClass(for spacing: Int) -> String? {
            switch spacing {
            case 0: return "g-0"
            case 4: return "g-1"
            case 8: return "g-2"
            case 16: return "g-3"
            case 24: return "g-4"
            case 48: return "g-5"
            default: return nil
            }
        }
        
        let object = create { element in
            element.class("row")
            element.class("wsui-hstack")
            element.class(alignment.rawValue)
            element.class(justify.rawValue)
            if let spacing {
                if let klass = gapClass(for: spacing) {
                    element.class(klass)
                } else {
                    element.style("gap: \(spacing)px")
                }
            }
            element.layout = .horizontal
        }
        return withParent(object, closure)
    }
    
}
