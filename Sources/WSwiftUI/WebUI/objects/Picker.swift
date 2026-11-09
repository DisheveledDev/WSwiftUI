//
//  Picker.swift
//  SWWebAppServer
//
//  Created by Adrian on 07/07/2025.
//

import Foundation

public enum PickerAlignment {
    case horizontal
    case vertical
}

public enum WebPickerType : Equatable {
    case combo
    case segmented(BootstrapVariant)
    case radio(PickerAlignment)
    case colorPicker
}

public enum PickerStyle {
    case menu
    case segmented(BootstrapVariant)
    case radio(PickerAlignment)
    case color
}

// 1) Dedicated subclasses for Picker (dropdown) and its parts
public class WebPickerElement: WebElement {
    
    var value: WebVariableElement? = nil
    var type: WebPickerType = .combo
    var variant: BootstrapVariant = .primary
    
    @discardableResult
    func variant(_ variant: BootstrapVariant) -> Self {
        self.variant = variant
        return self
    }
    
}

// 7) DSL on BaseWebEndpoint
public extension CoreWebEndpoint {
    // Internal creators
    fileprivate func createPicker(_ init: (WebPickerElement) -> Void) -> WebPickerElement {
        let el = WebPickerElement()
        populateCreatedObject(el)
        `init`(el)
        return el
    }
    
    /*
     
     <select class="form-select" aria-label="Default select example">
     <option selected>Open this select menu</option>
     <option value="1">One</option>
     <option value="2">Two</option>
     <option value="3">Three</option>
     </select>
     
     */
    
    /// Main Picker container (dropdown)
    @discardableResult
    func Picker(type: WebPickerType,
                binding: WebVariableElement,
                _ content: WebComposerClosure)
    -> WebPickerElement {
        
        // update with previous session data. A color picker renders no control, so it leaves the field to
        // the variable's hidden input.
        updateWithEphermeralData(binding, claimsFieldName: type != .colorPicker)

        switch type {
            case .combo:
                let picker = createPicker { el in
                    el.elementName = "select"
                    el.class("form-select")
                    el.class("wsui-picker")
                    el.value = binding
                    if let message = binding.errorMessage {
                        el.addAttribute(.errorMessage(message))
                    }
                    el.type = type
                    el.addAttribute(.custom("onchange=\"updateWebVariable\(binding.builderId)(this.value, { source: 'change', origin: '\(el.builderId)' });\""))
                    // register callbacks for updates to the bound variable
                    el.script("""
                        function updateVariable\(el.builderId)(value, _meta) {
                                \(el.builderId).value = value;
                        }
                        addCallback\(binding.builderId)(updateVariable\(el.builderId));
                    """)
                    if let binding = binding.internalName {
                        el.name(binding)
                    }
                }
                // items go here
                return withParent(picker, content)
            case .segmented:
                let picker = createPicker { el in
                    el.elementName = "div"
                    // (no `btn-group-toggle`: a Bootstrap 4 class that Bootstrap 5 doesn't define)
                    el.class("btn-group")
                    el.addAttribute(.pair("role", "group"))
                    if let message = binding.errorMessage {
                        el.addAttribute(.errorMessage(message))
                    }
                    el.value = binding
                    el.type = type
                }
                // items go here
                withParent(picker, content)
                // The hidden input goes after the group, not inside it: as the group's last child it would
                // match `.btn-group > .btn:not(:last-child)`'s sibling rules and square off the last button.
                if let varName = binding.internalName {
                    _ = create { element in
                        element.elementName = "input"
                        element.type("hidden")
                        element.name(varName)
                        element.value(binding.asString())
                        element.class("wsui-picker-hidden-binding")
                        element.script("""
                            function updateVariable\(element.builderId)(value, _meta) {
                                \(element.builderId).value = value;
                            }
                            addCallback\(binding.builderId)(updateVariable\(element.builderId));
                        """)
                    }
                }
                return picker
            case .radio:
                // basically, we do nothing as a radio is all controlled from it's parents id
                let picker = createPicker { el in
                    el.elementName = "div"
                    el.value = binding
                    if let message = binding.errorMessage {
                        el.addAttribute(.errorMessage(message))
                    }
                    el.type = type
                }
                // items go here
                return withParent(picker, content)
            case .colorPicker:
                // Not implemented: nothing is rendered and the content is not run. This used to happen
                // silently; it is now reported like other builder misuse.
                misuse("Picker type .colorPicker (style .color) is not implemented: the picker and its content are not rendered")
        }

        return WebPickerElement()

    }
    
    @discardableResult
    func Picker(_ title: String,
                selection binding: WebVariableElement,
                style: PickerStyle = .menu,
                _ content: WebComposerClosure) -> WebPickerElement {
        let mappedType: WebPickerType
        switch style {
            case .menu:
                mappedType = .combo
            case .segmented(let variant):
                mappedType = .segmented(variant)
            case .radio(let alignment):
                mappedType = .radio(alignment)
            case .color:
                mappedType = .colorPicker
        }
        
        let picker = Picker(type: mappedType, binding: binding, content)
        picker.label(title)
        return picker
    }
    
    @discardableResult
    func Picker(selection binding: WebVariableElement,
                style: PickerStyle = .menu,
                _ content: WebComposerClosure) -> WebPickerElement {
        return Picker("", selection: binding, style: style, content)
    }
    
}
