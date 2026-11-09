//
//  Callout.swift
//  WSwiftUI
//
//  Created by Adrian Herridge on 13/08/2025.
//

import Foundation

public extension CoreWebEndpoint {
    
    /// A padded box with a 4px leading border in the colour of `type` and a light grey border on the other
    /// sides; `content` goes inside it.
    @discardableResult
    func Callout(_ type: BootstrapVariant, _ content: WebComposerClosure)
    -> WebElement {
        
        let callout = create { el in
            el.elementName = "div"
            el.class("p-3")
            el.class("wsui-callout")
            el.border(.leading, .custom(type.rgb), width: 4)
            el.border(.top, .lightgrey, width: 1)
            el.border(.bottom, .lightgrey, width: 1)
            el.border(.trailing, .lightgrey, width: 1)
        }
        // items go here
        return withParent(callout, content)
    }
    
}
