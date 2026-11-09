//
//  VStack.swift
//  SWWebAppServer
//
//  Created by Adrian on 01/07/2025.
//

public enum VStackContentMode {
    case fit
    case fill
}

public extension CoreWebEndpoint {

    @discardableResult
    func VStack(mode: VStackContentMode = .fill,
                alignment: FlexAlignItems = .stretch,
                spacing: Int? = nil,
                _ closure: WebComposerClosure) -> WebElement {
        let object = createVStack(mode: mode, alignment: alignment, spacing: spacing)
        return withParent(object, closure)
    }

}

internal extension CoreWebEndpoint {

    /// Creates the `VStack` element (a flex column) in the current parent, without opening it.
    func createVStack(mode: VStackContentMode = .fill,
                      alignment: FlexAlignItems = .stretch,
                      spacing: Int? = nil) -> WebElement {
        func gapClass(for spacing: Int) -> String? {
            switch spacing {
            case 0: return "gap-0"
            case 4: return "gap-1"
            case 8: return "gap-2"
            case 16: return "gap-3"
            case 24: return "gap-4"
            case 48: return "gap-5"
            default: return nil
            }
        }

        return create { element in
            element.class("col")
            element.class("wsui-vstack")
            element.class("d-flex")
            element.class("flex-column")
            element.class(alignment.rawValue)
            if let spacing {
                if let klass = gapClass(for: spacing) {
                    element.class(klass)
                } else {
                    element.style("gap: \(spacing)px")
                }
            }
            if mode == .fit {
                element.deviceClass(mobile: "col-12", desktop: "col-md-auto")
            }
            element.layout = .vertical
        }
    }
}
