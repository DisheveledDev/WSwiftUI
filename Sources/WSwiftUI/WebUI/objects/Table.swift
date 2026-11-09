//
//  Table.swift
//  SWWebAppServer
//
//  Created by Adrian on 06/07/2025.
//

// 1) Dedicated subclasses for table-related elements
public class WebTableElement: WebElement {}
public class WebTableHeaderElement: WebElement {}
public class WebTableBodyElement: WebElement {}
public class WebTableRowElement: WebElement {}
public class WebTableCellElement: WebElement {}

// 2) Fluent methods for table styling
public extension WebTableElement {
    /// Adds base `table` class
    @discardableResult
    func `default`() -> Self {
        addAttribute(.class("table"))
        return self
    }

    /// Adds striped rows (`.table-striped`)
    @discardableResult
    func striped() -> Self {
        addAttribute(.class("table-striped"))
        return self
    }

    /// Adds borders to all cells (`.table-bordered`)
    @discardableResult
    func bordered() -> Self {
        addAttribute(.class("table-bordered"))
        return self
    }

    /// Adds hover effect on rows (`.table-hover`)
    @discardableResult
    func hover() -> Self {
        addAttribute(.class("table-hover"))
        return self
    }

    /// Makes table more compact (`.table-sm`)
    @discardableResult
    func small() -> Self {
        addAttribute(.class("table-sm"))
        return self
    }
}

// 3) Fluent methods for cell customization
public extension WebTableCellElement {
    /// Sets colspan attribute
    @discardableResult
    func colspan(_ span: Int) -> Self {
        addAttribute(.pair("colspan", "\(span)"))
        return self
    }

    /// Sets rowspan attribute
    @discardableResult
    func rowspan(_ span: Int) -> Self {
        addAttribute(.pair("rowspan", "\(span)"))
        return self
    }

    /// Text alignment via Bootstrap 5 classes: "left"/"start" -> `text-start`, "right"/"end" -> `text-end`,
    /// "center" -> `text-center`, "justify" -> `text-align: justify` (Bootstrap 5 has no `text-justify`).
    /// Any other value is passed through as `text-<value>`.
    @discardableResult
    func align(_ alignment: String) -> Self {
        applyTextAlignment(alignment)
        return self
    }
}

// 4) DSL on BaseWebEndpoint
public extension CoreWebEndpoint {
    // Create overloads
    fileprivate func createTable(_ `init`: (_ element: WebTableElement) -> Void) -> WebTableElement {
        let element = WebTableElement()
        populateCreatedObject(element)
        `init`(element)
        return element
    }

    fileprivate func createTableHeader(_ `init`: (_ element: WebTableHeaderElement) -> Void) -> WebTableHeaderElement {
        let element = WebTableHeaderElement()
        populateCreatedObject(element)
        `init`(element)
        return element
    }

    fileprivate func createTableBody(_ `init`: (_ element: WebTableBodyElement) -> Void) -> WebTableBodyElement {
        let element = WebTableBodyElement()
        populateCreatedObject(element)
        `init`(element)
        return element
    }

    fileprivate func createRow(_ `init`: (_ element: WebTableRowElement) -> Void) -> WebTableRowElement {
        let element = WebTableRowElement()
        populateCreatedObject(element)
        `init`(element)
        return element
    }

    fileprivate func createCell(_ `init`: (_ element: WebTableCellElement) -> Void) -> WebTableCellElement {
        let element = WebTableCellElement()
        populateCreatedObject(element)
        `init`(element)
        return element
    }

    /// Builds a `<table>` and applies default `.table` class
    @discardableResult
    func Table(_ content: WebComposerClosure) -> WebTableElement {
        let table = createTable { el in
            el.elementName = "table"
            el.class("table")
            el.class("wsui-table")
        }
        return withTablePart(table, content)
    }

    // Table structure is stricter than the other compound controls. The HTML parser moves anything that is
    // not a table part out of `<table>`, `<thead>`, `<tbody>` and `<tr>` ("foster parenting"), so:
    // - Each part must be a direct child of its table part (TableHeader/TableBody of a Table, Row of a
    //   TableHeader/TableBody, Cell of a Row), and
    // - Anything else declared directly in a Table, TableHeader, TableBody or Row (a Form or VStack wrapped
    //   around rows or cells, a Text in a Row, ...) is reported: the browser would put it in front of the
    //   table, so a per-row `Form { Row { ... } }` ends up as an empty form and loses its fields and its
    //   validation. Put such content inside a Cell (a form per row goes in a Cell), or around the whole
    //   Table. Hidden inputs (bound variables) stay where they are, so they are allowed.
    // Either mistake is logged, an HTML comment marks the spot, and the element is rendered where it was
    // declared.

    /// Builds a `<thead>` directly inside a Table.
    @discardableResult
    func TableHeader(_ content: WebComposerClosure) -> WebTableHeaderElement {
        requireStructuralParent({ $0 is WebTableElement }, among: isTablePart,
                                "TableHeader must be used inside a Table { ... } block")
        let thead = createTableHeader { el in
            el.elementName = "thead"
        }
        return withTablePart(thead, content)
    }

    /// Builds a `<tbody>` directly inside a Table.
    @discardableResult
    func TableBody(_ content: WebComposerClosure) -> WebTableBodyElement {
        requireStructuralParent({ $0 is WebTableElement }, among: isTablePart,
                                "TableBody must be used inside a Table { ... } block")
        let tbody = createTableBody { el in
            el.elementName = "tbody"
        }
        return withTablePart(tbody, content)
    }

    /// Builds a `<tr>` directly inside a `<thead>` or `<tbody>`. For a form per row, put the Form inside a
    /// Cell (or one Form around the whole Table); a Form around the Row is reported, see above.
    @discardableResult
    func Row(_ content: WebComposerClosure) -> WebTableRowElement {
        requireStructuralParent({ $0 is WebTableHeaderElement || $0 is WebTableBodyElement }, among: isTablePart,
                                "Row must be used inside a TableHeader or TableBody block")
        let tr = createRow { el in
            el.elementName = "tr"
        }
        return withTablePart(tr, content)
    }

    /// Builds a `<td>` directly inside a `<tr>` (use `.align()`, `.colspan()`, etc. to customize). Anything
    /// can go inside the Cell.
    @discardableResult
    func Cell(_ content: WebComposerClosure) -> WebTableCellElement {
        requireStructuralParent({ $0 is WebTableRowElement }, among: isTablePart,
                                "Cell must be used inside a Row { ... } block")
        let td = createCell { el in
            el.elementName = "td"
        }
        return withParent(td, content)
    }
}

fileprivate extension CoreWebEndpoint {

    /// Opens a table container (`<table>`, `<thead>`, `<tbody>`, `<tr>`) like `withParent`, then reports
    /// each direct child the HTML parser would move out of the table, with a marker right in front of it.
    func withTablePart<T: WebElement>(_ container: T, _ content: () -> Void) -> T {
        withParent(container, content)
        guard container.subElements.contains(where: { isAllowedInTableStructure($0, in: container) == false }) else {
            return container
        }
        var children: [WebElement] = []
        children.reserveCapacity(container.subElements.count + 1)
        for child in container.subElements {
            if isAllowedInTableStructure(child, in: container) == false {
                children.append(misuseMarker(tableContentMessage(element: child.elementName,
                                                                 container: tablePartName(container))))
            }
            children.append(child)
        }
        container.subElements = children
        return container
    }
}

/// The misuse message for an element declared directly in a table container, e.g. a Form around a Row.
internal func tableContentMessage(element: String, container: String) -> String {
    return "A \(element) element is directly inside a \(container). Browsers move anything that is not a table part out of a table, so it ends up empty or in front of the table (a Form around a Row loses its fields). Put it inside a Cell, or around the whole Table"
}

/// `true` for the direct children a table container may have, which the HTML parser leaves in place:
/// the DSL's table parts (their own position is checked when they are declared), misuse markers, hidden
/// inputs (bound variables), the table tags valid in that container (e.g. a `caption` or `tfoot` made with
/// `create`), and `template`, `script` and `style`.
fileprivate func isAllowedInTableStructure(_ element: WebElement, in container: WebElement) -> Bool {
    if element is WebTableHeaderElement || element is WebTableBodyElement
        || element is WebTableRowElement || element is WebTableCellElement
        || element is WebBuilderMisuseElement {
        return true
    }
    let tag = element.elementName.lowercased()
    if tag == "input" {
        return element.attributes.contains { attribute in
            if case .type(let type) = attribute { return type.lowercased() == "hidden" }
            return false
        }
    }
    switch container.elementName.lowercased() {
    case "table": return ["caption", "colgroup", "thead", "tbody", "tfoot", "tr", "template", "script", "style"].contains(tag)
    case "tr": return ["td", "th", "template", "script", "style"].contains(tag)
    default: return ["tr", "template", "script", "style"].contains(tag)
    }
}

/// The DSL name of a table part, for messages.
fileprivate func tablePartName(_ element: WebElement) -> String {
    switch element {
    case is WebTableElement: return "Table"
    case is WebTableHeaderElement: return "TableHeader"
    case is WebTableBodyElement: return "TableBody"
    case is WebTableRowElement: return "Row"
    case is WebTableCellElement: return "Cell"
    default: return element.elementName
    }
}

/// The elements that make up a table's structure. Anything else on the builder stack is a wrapper.
fileprivate func isTablePart(_ element: WebElement) -> Bool {
    return element is WebTableElement
        || element is WebTableHeaderElement
        || element is WebTableBodyElement
        || element is WebTableRowElement
        || element is WebTableCellElement
}
