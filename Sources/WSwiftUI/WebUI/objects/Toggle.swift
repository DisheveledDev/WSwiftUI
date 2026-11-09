//
//  Toggle.swift
//  WSwiftUI
//
//  Created by Adrian Herridge on 09/08/2025.
//

import Foundation

public extension CoreWebEndpoint {
    
    fileprivate func createToggle(value: WebVariableElement, title: String?) -> WebElement {

        /*
         
         <div class="form-check">
           <input class="form-check-input" type="radio" name="exampleRadios" id="exampleRadios1" value="option1" checked>
           <label class="form-check-label" for="exampleRadios1">
             Default radio
           </label>
         </div>
         
         */

        // Restore the submitted state (`on` parses to true) and pick up the validation message after a
        // failed validateData. An unticked box submits nothing, so it has nothing to restore.
        updateWithEphermeralData(value)

        return withLayoutContainer { () -> WebElement in
            let outerDiv = create { element in
                
                element.elementName = "div"
                element.class("form-check")
                element.class("wsui-toggle")
                
            }
            
            // the input and its label go inside the div
            return building(inside: outerDiv) { () -> WebElement in
                // generate the input
                let input = create { element in
                
                    element.elementName = "input"
                    element.class("form-check-input")
                    element.type("checkbox")
                    let inputId = "\(element.builderId)"
                    element.id(inputId)
                    if let varName = value.internalName { element.name(varName) }
                    if let message = value.errorMessage { element.addAttribute(.errorMessage(message)) }
                
                    element.addAttribute(.custom("onchange=\"updateWebVariable\(value.builderId)(this.checked, { source: 'change', origin: '\(element.builderId)' });\""))
                
                    // initial value
                    if value.asBool() {
                        element.checked()
                    }
                
                    // register callbacks for updates to the bound variable
                    element.script("""
                        function updateVariable\(element.builderId)(value, _meta) {
                            var isChecked = (value === true || value === 'true' || value === 1 || value === '1');

                            // Update the checkbox state
                            \(element.builderId).checked = isChecked;

                            // (Optional) keep the attribute in sync for SSR/HTML snapshots
                            if (isChecked) {
                                \(element.builderId).setAttribute('checked', 'checked');
                            } else {
                                \(element.builderId).removeAttribute('checked');
                            }
                        }
                        addCallback\(value.builderId)(updateVariable\(element.builderId));
                    """)
                
                }
                
                if let title {
                    _ = create { element in
                        element.elementName = "label"
                        element.class("form-check-label")
                        element.addAttribute(.pair("for", input.builderId))
                        element.innerHTML(title.escapedForHTML())
                    }
                }
                return input
            }
        }.built
    }
    
    // MARK: – WBool binding
    @discardableResult
    func Toggle(value: WebVariableElement) -> WebElement {
        return createToggle(value: value, title: nil)
    }
    
    @discardableResult
    func Toggle(_ title: String, isOn value: WebVariableElement) -> WebElement {
        return createToggle(value: value, title: title)
    }
    
}
