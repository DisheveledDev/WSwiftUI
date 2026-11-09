//
//  FormControls.swift
//  SWWebAppServer
//
//  Created by Adrian on 08/07/2025.
//

import Foundation

// 1) Subclasses for form elements
public class WebFormGroupElement: WebElement {}
public class WebLabelElement: WebElement {}
public class WebInputElement: WebElement {}
public class WebTextAreaElement: WebElement {}
public class WebSelectElement: WebElement {}
public class WebOptionElement: WebElement {}

// 2) Input types
public enum InputType: String {
    case text, password, email, url, tel, search, number
}

// 3) Fluent modifiers
public extension WebLabelElement {
    @discardableResult
    func `for`(_ id: String) -> Self {
        addAttribute(.pair("for", id))
        return self
    }
    @discardableResult
    func textAlign(_ align: String) -> Self {
        addAttribute(.class("text-\(align)"))
        return self
    }
}

public extension WebInputElement {
    @discardableResult
    func type(_ t: InputType) -> Self {
        addAttribute(.pair("type", t.rawValue))
        return self
    }
    @discardableResult
    func disabled(_ on: Bool = true) -> Self {
        if on { addAttribute(.pair("disabled","")) }
        return self
    }
    @discardableResult
    func readonly(_ on: Bool = true) -> Self {
        if on { addAttribute(.pair("readonly","")) }
        return self
    }
}

public extension WebTextAreaElement {
    @discardableResult
    func rows(_ cnt: Int) -> Self {
        addAttribute(.pair("rows","\(cnt)"))
        return self
    }
    @discardableResult
    func cols(_ cnt: Int) -> Self {
        addAttribute(.pair("cols","\(cnt)"))
        return self
    }
    @discardableResult
    func disabled(_ on: Bool = true) -> Self {
        if on { addAttribute(.pair("disabled","")) }
        return self
    }
    @discardableResult
    func readonly(_ on: Bool = true) -> Self {
        if on { addAttribute(.pair("readonly","")) }
        return self
    }
}

public extension WebSelectElement {
    @discardableResult
    func multiple(_ on: Bool = true) -> Self {
        if on { addAttribute(.pair("multiple","")) }
        return self
    }
    @discardableResult
    func size(_ cnt: Int) -> Self {
        addAttribute(.pair("size","\(cnt)"))
        return self
    }
    @discardableResult
    func disabled(_ on: Bool = true) -> Self {
        if on { addAttribute(.pair("disabled","")) }
        return self
    }
}

public extension WebOptionElement {
    @discardableResult
    func selected(_ on: Bool = true) -> Self {
        if on { addAttribute(.pair("selected","")) }
        return self
    }
    @discardableResult
    func disabled(_ on: Bool = true) -> Self {
        if on { addAttribute(.pair("disabled","")) }
        return self
    }
}

// 4) DSL factories
public extension CoreWebEndpoint {

    /// Bound <input> element
    ///
    /// A `.password` field is never pre-filled: neither the bound value nor a value submitted with a form that
    /// failed `validateData(_:)` is written back into the page. Validation error messages are still shown.
    @discardableResult
    func TextField(binding: WebVariableElement,
               type: InputType = .text)
    -> WebInputElement {
        
        let isSecret = (type == .password)
        
        // update with previous session data (never the submitted value of a secret field)
        updateWithEphermeralData(binding, restoreValue: !isSecret)
        if isSecret {
            // nor a value the app seeded the binding with
            binding.redactInitialValue()
        }

        let inp = WebInputElement()
        populateCreatedObject(inp)
        inp.elementName = "input"
        inp.type(type)
        inp.class("form-control")
        inp.class("wsui-input")
        if binding.errorMessage != nil {
            inp.addAttribute(.errorMessage(binding.errorMessage!))
        }
        let id = "\(inp.builderId)"
        inp.id(id)
        if let varName = binding.internalName { inp.name(varName) }
        if isSecret {
            // No value attribute, and ignore the page-load sync of the bound value; later client-side
            // updates of the variable (e.g. clearing it) still apply.
            inp.addAttribute(.script("""
function updateVariable\(inp.builderId)(value, _meta) {
    if (_meta && _meta.source === 'initial') { return; }
    \(inp.builderId).value = value;
}
addCallback\(binding.builderId)(updateVariable\(inp.builderId));
"""))
        } else {
            inp.value(binding.asString())
            inp.addAttribute(.script("""
function updateVariable\(inp.builderId)(value, _meta) {
    \(inp.builderId).value = value;
}
addCallback\(binding.builderId)(updateVariable\(inp.builderId));
"""))
        }
        inp.addAttribute(.custom("oninput=\"updateWebVariable\(binding.builderId)(this.value, { source: 'input', origin: '\(inp.builderId)' });\""))
        inp.addAttribute(.custom("onchange=\"updateWebVariable\(binding.builderId)(this.value, { source: 'change', origin: '\(inp.builderId)' });\""))
        return inp
    }

    /// Bound <textarea>
    @discardableResult
    func TextArea(value: WebVariableElement)
    -> WebTextAreaElement {
        
        // update with previous session data
        updateWithEphermeralData(value)
        
        let ta = WebTextAreaElement()
        populateCreatedObject(ta)
        ta.elementName = "textarea"
        if value.errorMessage != nil {
            ta.addAttribute(.errorMessage(value.errorMessage!))
        }
        if let varName = value.internalName { ta.name(varName) }
        ta.class("form-control")
        ta.class("wsui-textarea")
        // Populate visible textarea content from the bound value so submitted
        // form data reflects the current binding even before any client callback.
        ta.innerHTML(WebEscape.html(value.asString()))
        let id = "\(ta.builderId)"
        ta.id(id)
        ta.addAttribute(.script("""
function updateVariable\(ta.builderId)(value, _meta) {
    \(ta.builderId).value = value;
}
addCallback\(value.builderId)(updateVariable\(ta.builderId));
"""))
        ta.addAttribute(.custom("oninput=\"updateWebVariable\(value.builderId)(this.value, { source: 'input', origin: '\(ta.builderId)' });\""))
        ta.addAttribute(.custom("onchange=\"updateWebVariable\(value.builderId)(this.value, { source: 'change', origin: '\(ta.builderId)' });\""))
        return ta
    }
    
    /// SwiftUI-style text field signature with title + bound value.
    @discardableResult
    func TextField(_ title: String,
                   text binding: WebVariableElement,
                   type: InputType = .text,
                   prompt: String? = nil) -> WebInputElement {
        let field = TextField(binding: binding, type: type)
        field.label(title)
        if let prompt {
            field.placeholder(prompt)
        }
        return field
    }
    
    /// SwiftUI-style secure field convenience (`<input type="password">`).
    ///
    /// The field is never pre-filled with the bound value or with a previously submitted value.
    @discardableResult
    func SecureField(_ title: String,
                     text binding: WebVariableElement,
                     prompt: String? = nil) -> WebInputElement {
        let field = TextField(binding: binding, type: .password)
        field.label(title)
        if let prompt {
            field.placeholder(prompt)
        }
        return field
    }
    
    /// SwiftUI-style text area signature with title + bound value.
    @discardableResult
    func TextArea(_ title: String,
                  text value: WebVariableElement,
                  prompt: String? = nil) -> WebTextAreaElement {
        let area = TextArea(value: value)
        area.label(title)
        if let prompt {
            area.placeholder(prompt)
        }
        return area
    }

}
