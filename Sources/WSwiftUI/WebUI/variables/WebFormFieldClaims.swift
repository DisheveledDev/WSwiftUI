//
//  WebFormFieldClaims.swift
//  WSwiftUI
//
//  Decides which form fields a variable's hidden carrier input leaves to another control.
//

import Foundation

/// A variable's hidden carrier input submits the variable under its name, unless another control in the
/// same form already submits a field of that name. Bound text fields, text areas and pickers claim their
/// field when they are built (`updateWithEphermeralData`). Every other control is found here, when the
/// page is rendered: a `Toggle`'s checkbox, a radio button, or a hand-made `<input>` / `<select>` /
/// `<textarea>`. A checkbox therefore behaves as in plain HTML: an unchecked box submits nothing, so
/// `validateData` reports the field as missing and `data.bool(name)` is `nil`.
internal enum WebFormFieldClaims {

    /// Input types that submit nothing unless they are the button that submitted the form.
    private static let buttonInputTypes: Set<String> = ["submit", "button", "reset", "image"]

    /// Walks the page once and gives every variable carrier on it the field names that the other controls
    /// in its form submit. Controls outside any form are grouped together. (Nested forms are not valid
    /// HTML; the nearest enclosing form is used.)
    static func resolve(page root: WebElement?) {
        guard let root else { return }
        var namesByForm: [ObjectIdentifier?: Set<String>] = [:]
        var carriers: [(WebVariableElement, ObjectIdentifier?)] = []
        var pending: [(WebElement, ObjectIdentifier?)] = [(root, nil)]
        while let next = pending.popLast() {
            let (element, enclosingForm) = next
            let form = element.elementName.lowercased() == "form" ? ObjectIdentifier(element) : enclosingForm
            if let carrier = element as? WebVariableElement {
                carriers.append((carrier, form))
            } else if let field = submittedFieldName(of: element) {
                namesByForm[form, default: []].insert(field)
            }
            for child in element.subElements {
                pending.append((child, form))
            }
        }
        for (carrier, form) in carriers {
            carrier.fieldNamesSubmittedInForm = namesByForm[form] ?? []
        }
    }

    /// The name of the field `element` submits when it is a form control: an `<input>` (other than a
    /// button), `<select>` or `<textarea>` with a name. Like the renderer, the last `.name(...)` /
    /// `.pair("name", ...)` (and `.type` / `.pair("type", ...)`) wins. Disabled controls still count: the
    /// carrier never takes over a field that a visible control is for.
    private static func submittedFieldName(of element: WebElement) -> String? {
        let tag = element.elementName.lowercased()
        guard tag == "input" || tag == "select" || tag == "textarea" else { return nil }
        var name: String? = nil
        var type: String? = nil
        for attribute in element.attributes {
            switch attribute {
                case .name(let value):
                    name = value
                case .type(let value):
                    type = value
                case .pair(let key, let value):
                    switch key.lowercased() {
                        case "name": name = value
                        case "type": type = value
                        default: break
                    }
                default:
                    break
            }
        }
        if tag == "input", let type, buttonInputTypes.contains(type.lowercased()) {
            return nil
        }
        guard let name, name.isEmpty == false else { return nil }
        return name
    }
}
