//
//  BuilderStack.swift
//  WSwiftUI
//
//  Helpers for the builder stack: the stack of open container elements that DSL calls append their
//  children to. Compound controls (Table, Card, Modal, ...) use them to open a container and to find the
//  container a part belongs to, looking through any wrapper elements (a Form, a VStack, a helper's <div>)
//  the page puts in between. (Tables are the exception: anything but a table part declared directly in
//  table structure is reported, because browsers move it out of the table; see Table.swift.)
//

import Foundation

internal extension CoreWebEndpoint {

    /// Makes `element` the current parent while `content` runs, then unwinds the stack back to (and
    /// including) `element`. Unwinding to the element, rather than removing only the element, means a child
    /// builder that forgot to pop itself can't capture the elements declared after this container.
    ///
    /// Every container in WebUI/objects opens its element(s) with this (or `building(inside:_:)`), so the
    /// builder stack has the same depth after a container as before it, whatever its content did.
    @discardableResult
    func withParent<T: WebElement>(_ element: T, _ content: () -> Void) -> T {
        building(inside: element, content)
        return element
    }

    /// Like `withParent(_:_:)`, but returns what `content` returns (for a builder that opens a container and
    /// hands back an element created inside it, such as `Toggle` or `Text` in a layout container).
    @discardableResult
    func building<R>(inside element: WebElement, _ content: () -> R) -> R {
        stack.append(element)
        defer { unwindStack(to: element) }
        return content()
    }

    /// Removes `element`, and everything pushed after it, from the builder stack. Does nothing when the
    /// element isn't on the stack.
    func unwindStack(to element: WebElement) {
        guard let index = stack.lastIndex(where: { $0 === element }) else { return }
        stack.removeSubrange(index...)
    }

    /// The innermost open container of type `T`, looking through any other elements in between.
    /// `nil` when no such container is open.
    func nearestAncestor<T: WebElement>(of type: T.Type) -> T? {
        for element in stack.reversed() {
            if let match = element as? T {
                return match
            }
        }
        return nil
    }

    /// The innermost open container for which `predicate` is true.
    func nearestAncestor(where predicate: (WebElement) -> Bool) -> WebElement? {
        return stack.last(where: predicate)
    }

    /// Checks where a part of a compound control is being declared.
    ///
    /// The part's *structural parent* is the innermost open element that belongs to the control
    /// (`isPartOfControl`). Elements that don't belong to it (forms, stacks, plain wrappers) are looked
    /// through, so `Card { VStack { CardBody { ... } } }` finds the `Card`. When the structural parent
    /// is one `isValidParent` accepts it is returned. Otherwise the misuse is reported with
    /// `misuse(_:file:line:)` (a log line and an HTML comment, never a crash) and `nil` is returned; the
    /// caller then renders the part where it was declared.
    ///
    /// Tables are stricter: the HTML parser moves anything that is not a table part out of a table, so
    /// Table.swift also reports any non-table element declared directly in a Table, TableHeader, TableBody
    /// or Row, which includes a wrapper between table parts (see `withTablePart`).
    @discardableResult
    func requireStructuralParent(_ isValidParent: (WebElement) -> Bool,
                                 among isPartOfControl: (WebElement) -> Bool,
                                 _ message: @autoclosure () -> String,
                                 file: StaticString = #fileID,
                                 line: UInt = #line) -> WebElement? {
        if let container = nearestAncestor(where: isPartOfControl), isValidParent(container) {
            return container
        }
        misuse(message(), file: file, line: line)
        return nil
    }
}
