//
//  WrapInLayoutContainer.swift
//  SWWebAppServer
//
//  Created by Adrian on 16/07/2025.
//

public extension CoreWebEndpoint {

    /// Puts `closure`'s content in a layout container that fits the current parent: in a horizontal parent
    /// (an `HStack`) a `VStack` holding a `div.col`, in a vertical one a `VStack` holding a `div.row`, and
    /// elsewhere a `div.row`. Returns the outermost element it added.
    @discardableResult
    func WrapInLayoutContainer(_ closure: WebComposerClosure) -> Any {
        return withLayoutContainer(closure).container
    }

}

internal extension CoreWebEndpoint {

    /// Opens the layout container `WrapInLayoutContainer` adds, runs `build` inside it, and returns the
    /// outermost element it added together with what `build` returned (the control created inside it).
    func withLayoutContainer<T>(_ build: () -> T) -> (container: WebElement, built: T) {
        if parent?.layout == .horizontal {
            let column = createVStack()
            let built = building(inside: column) { () -> T in
                let object = create { element in
                    element.class("col")
                }
                return building(inside: object, build)
            }
            return (column, built)
        } else if parent?.layout == .vertical {
            let column = createVStack()
            let built = building(inside: column) { () -> T in
                let object = create { element in
                    element.class("row")
                }
                return building(inside: object, build)
            }
            return (column, built)
        } else {
            let object = create { element in
                element.class("row")
            }
            return (object, building(inside: object, build))
        }
    }
}
