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
public class WebInputElement: WebElement {

    /// The variable a `TextField` binds this input to, until it is redacted, and the endpoint building it.
    internal weak var redactableBinding: WebVariableElement? = nil
    internal weak var redactionEndpoint: CoreWebEndpoint? = nil

    /// An input has one type, and the last one set wins: `TextField(binding:)` sets one, so a later
    /// `.type("password")`, `.type(.password)` or `.addAttribute(.pair("type", "password"))` replaces it
    /// (the renderer keeps only the first attribute of a name, so it used to be ignored).
    ///
    /// An input made a password input after it was created redacts its binding as `SecureField` does: the
    /// bound variable, its hidden input and the page-load sync are emptied, and the value submitted with a
    /// form that failed `validateData(_:)` is dropped, so it is not restored into a later control bound to
    /// the same name either. Neither a seeded value nor a submitted one is written back into the page.
    @discardableResult
    public override func addAttribute(_ attribute: WebCoreElementAttribute, file: StaticString = #fileID) -> Self {
        if Self.isTypeAttribute(attribute) {
            attributes.removeAll(where: Self.isTypeAttribute)
        }
        super.addAttribute(attribute, file: file)
        if let binding = redactableBinding, Self.makesPasswordInput(attribute) {
            redactableBinding = nil
            binding.redactInitialValue()
            if let name = binding.internalName {
                redactionEndpoint?.ephemeralData.removeValue(forKey: "previous_\(name)")
            }
            attributes.removeAll(where: {
                switch $0 {
                    case .value, .initialValue: return true
                    case .pair(let k, _): return k.lowercased() == "value"
                    default: return false
                }
            })
        }
        return self
    }

    private static func isTypeAttribute(_ attribute: WebCoreElementAttribute) -> Bool {
        switch attribute {
            case .type: return true
            case .pair(let key, _): return key.lowercased() == "type"
            default: return false
        }
    }

    private static func makesPasswordInput(_ attribute: WebCoreElementAttribute) -> Bool {
        switch attribute {
            case .type(let value): return WebHTMLSyntax.isPasswordType(value)
            case .pair(let key, let value): return key.lowercased() == "type" && WebHTMLSyntax.isPasswordType(value)
            default: return false
        }
    }
}
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
    /// Text alignment via Bootstrap 5 classes: "left"/"start" -> `text-start`, "right"/"end" -> `text-end`,
    /// "center" -> `text-center`, "justify" -> `text-align: justify`; other values pass through as
    /// `text-<value>`. ("left"/"right" used to give `text-left`/`text-right`, which Bootstrap 5 dropped.)
    @discardableResult
    func textAlign(_ align: String) -> Self {
        applyTextAlignment(align)
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
    /// The input submits the binding under the variable's `.name(...)`; the variable's hidden input then
    /// leaves that field to it. After a failed `validateData(_:)` the field shows the submitted value again
    /// (when its name was validated) and the error message.
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
        if let message = binding.errorMessage {
            inp.addAttribute(.errorMessage(message))
        }
        let id = "\(inp.builderId)"
        inp.id(id)
        if let varName = binding.internalName { inp.name(varName) }
        if isSecret == false {
            // redacted if the input is made a password input later
            inp.redactableBinding = binding
            inp.redactionEndpoint = self
        }
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
        if let message = value.errorMessage {
            ta.addAttribute(.errorMessage(message))
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
