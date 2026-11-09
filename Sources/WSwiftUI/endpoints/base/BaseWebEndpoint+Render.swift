//
//  BaseWebEndpoint+Render.swift
//  SWWebAppServer
//
//  Created by Adrian on 04/07/2025.
//

import Foundation

let tab = "    "

fileprivate extension WebElement {
    var value: String {
        get {
            if let value = attributes.first(where: { if case .value(_) = $0 { return true }
                return false
            }) {
                switch value {
                    case .value(let v): return v
                    default: return ""
                }
            }
            return ""
        }
    }
    var title: String {
        get {
            if let title = attributes.first(where: { if case .title(_) = $0 { return true }
                return false
            }) {
                switch title {
                    case .title(let v): return v
                    default: return ""
                }
            }
            return ""
        }
    }
    var isSelected: Bool {
        get {
            return attributes.contains { if case .selected = $0 { return true }
                return false
            }
        }
    }
    var isDisabled: Bool {
        get {
            return attributes.contains { if case .disabled = $0 { return true }
                return false
            }
        }
    }
    /// `true` for `<input type="password">`, however the type was set (`.type(...)` or `.pair("type", ...)`).
    var isPasswordInput: Bool {
        get {
            guard elementName.lowercased() == "input" else { return false }
            return attributes.contains { attr in
                switch attr {
                    case .type(let v): return WebHTMLSyntax.isPasswordType(v)
                    case .pair(let k, let v): return k.lowercased() == "type" && WebHTMLSyntax.isPasswordType(v)
                    default: return false
                }
            }
        }
    }
}

/// Everything one `renderWebPage()` call collects while it walks the page. The endpoint and its elements are
/// not modified by rendering (apart from the forms field-claim cache, which is recomputed for every render),
/// so rendering the same page twice gives the same output.
private struct PageRenderState {
    /// The client's device kind, worked out once for the whole page (`.deviceClass` needs it).
    let isMobile: Bool
    /// The page's scripts, emitted after the last element of `<body>`.
    var scripts = WebPageScripts()
    /// Ids of the rendered elements that may be registered as globals, in document order.
    var registrable: [String] = []
    /// Inline event handlers and other `.pair` / `.data` attribute values, `javascript:` URLs, raw attribute
    /// strings, raw HTML and head code: text that can refer to element globals without being a script of the
    /// page.
    var referenceTexts: [String] = []
    /// Whether `WebFormFieldClaims` has run for this render (it runs before the first named variable carrier).
    var fieldClaimsResolved = false
    private var indents: [String] = [""]

    init(isMobile: Bool) {
        self.isMobile = isMobile
    }

    /// `depth` tabs.
    mutating func indent(_ depth: Int) -> String {
        while indents.count <= depth {
            indents.append(indents[indents.count - 1] + tab)
        }
        return indents[depth]
    }

    /// Registers exactly the elements whose id the page's scripts or inline handlers refer to.
    mutating func resolveRegistrations() {
        guard registrable.isEmpty == false,
              scripts.elementChunks.isEmpty == false || scripts.domLoadedChunks.isEmpty == false || referenceTexts.isEmpty == false else {
            return
        }
        var references = WebScriptReferences(candidates: registrable)
        guard references.hasCandidates else { return }
        for chunk in scripts.elementChunks { references.scan(chunk.code) }
        for chunk in scripts.domLoadedChunks { references.scan(chunk.code) }
        for text in referenceTexts { references.scan(text) }
        let found = references.found
        guard found.isEmpty == false else { return }
        var registered = Set<String>()
        for id in registrable where found.contains(id) && registered.insert(id).inserted {
            scripts.registrations.append(id)
        }
    }
}

/// Up to this many classes (or attributes) of one element are de-duplicated by comparing them one by one,
/// which needs no allocation; beyond it a hash set is used, so de-duplication stays linear per element.
private let linearDedupLimit = 8

/// ASCII lower case, without allocating for names that are lower case already (nearly all of them).
@inline(__always)
private func lowercasedAttributeName(_ name: String) -> String {
    guard name.utf8.contains(where: { $0 >= 0x41 && $0 <= 0x5A }) else { return name }
    return name.lowercased()
}

/// The attribute name of a `.custom(...)` string when it holds exactly one attribute (`required`,
/// `onchange="..."`, `loading=lazy`), lower-cased; `nil` otherwise. Only such a string is checked for being
/// a repeated attribute.
private func singleCustomAttributeName(_ raw: String) -> String? {
    let scalars = Array(raw.unicodeScalars)
    var index = 0
    func isSpace(_ s: Unicode.Scalar) -> Bool { s == " " || s == "\t" || s == "\n" || s == "\r" || s == "\u{0C}" }
    while index < scalars.count, isSpace(scalars[index]) { index += 1 }
    let nameStart = index
    while index < scalars.count, !isSpace(scalars[index]), !"=/>\"'<".unicodeScalars.contains(scalars[index]) { index += 1 }
    guard index > nameStart else { return nil }
    let name = String(String.UnicodeScalarView(scalars[nameStart..<index]))
    while index < scalars.count, isSpace(scalars[index]) { index += 1 }
    if index < scalars.count, scalars[index] == "=" {
        index += 1
        while index < scalars.count, isSpace(scalars[index]) { index += 1 }
        guard index < scalars.count else { return nil }
        let quote = scalars[index]
        if quote == "\"" || quote == "'" {
            index += 1
            while index < scalars.count, scalars[index] != quote { index += 1 }
            guard index < scalars.count else { return nil }
            index += 1
        } else {
            while index < scalars.count, !isSpace(scalars[index]) { index += 1 }
        }
    }
    while index < scalars.count, isSpace(scalars[index]) { index += 1 }
    return index == scalars.count ? lowercasedAttributeName(name) : nil
}

internal extension CoreWebEndpoint {

    /// Renders the whole page. Rendering does not change the endpoint, so calling it twice gives the same
    /// output.
    ///
    /// `<body>` holds the elements only: every script runs from the end of `<body>` (see `WebPageScripts`),
    /// so no `<script>` sits between elements and Bootstrap's sibling selectors (`.list-group-item +
    /// .list-group-item`, `.btn-group > .btn:last-child`, ...) see the elements as they are declared.
    func renderWebPage() -> String {
        let deviceKind = clientDeviceKind
        var state = PageRenderState(isMobile: deviceKind == .mobile)
        // DOMContentLoaded scripts queued on the endpoint itself run first (it is not appended to here)
        for script in domLoadedScripts {
            state.scripts.domLoadedChunks.append(WebScriptOrigin.chunk(script))
        }

        // The doctype puts browsers in standards mode; without it every page rendered in quirks mode.
        var pageContent = "\(WebHTMLDocument.doctype)\n<html lang=\"en\">\n"

        // render head
        pageContent += "\(tab)<head>\n"
        let innerIndent = tab + tab
        // The character set is declared once, as the first element of the head (it has to be within the
        // first 1024 bytes). Pages are always written out as UTF-8, so every other character set declaration
        // the page added (`.metaCharset`, a Content-Type `http-equiv`, a custom `<meta charset>`) is dropped:
        // a second declaration is invalid. Each is logged once per endpoint type, except a `.metaCharset` that
        // repeats UTF-8.
        pageContent += render(WebCoreHeadElement.metaCharset(WebHTMLDocument.charset), indent: innerIndent)
        for element in self.headAttributes {
            if let declaration = WebHTMLDocument.charsetDeclaration(in: element) {
                if declaration.contradicts {
                    WebHTMLDocument.logDroppedCharset(endpoint: String(describing: type(of: self)), declaration: declaration)
                }
                continue
            }
            // head code that can refer to element globals: inline scripts, raw inner HTML and attribute values
            // (an `onload` on a script or link, for example)
            switch element {
                case .inlineScript(let code):
                    state.referenceTexts.append(code)
                case .custom(_, let attributes, let innerHTML):
                    state.referenceTexts.append(contentsOf: attributes.values)
                    if let innerHTML { state.referenceTexts.append(innerHTML) }
                case .link(_, _, _, _, _, let attributes?), .script(_, _, _, _, _, _, let attributes?):
                    state.referenceTexts.append(contentsOf: attributes.values)
                default:
                    break
            }
            pageContent += render(element, indent: innerIndent)
        }
        pageContent += "\(tab)</head>\n"

        // render body: the children of the synthetic document root, in creation order
        pageContent += "\(tab)<body class=\"wsui-device-\(deviceKind.rawValue)\" data-wsui-device=\"\(deviceKind.rawValue)\">\n"
        render(documentRoot, depth: 2, into: &pageContent, state: &state)

        // then every script, after the last element of <body>
        state.resolveRegistrations()
        pageContent += state.scripts.render(indent: innerIndent)
        pageContent += "\(tab)</body>\n"

        pageContent += "</html>\n"
        return pageContent
    }

    // MARK: –– Render a WebCoreElement recursively
    private func render(_ element: WebElement, depth: Int, into out: inout String, state: inout PageRenderState) {
        // a fragment (the document root, `webpage {}`) has no tag of its own
        if element is WebFragmentElement {
            renderFragment(element, depth: depth, into: &out, state: &state)
            return
        }
        let indent = state.indent(depth)
        if state.scripts.isolatesEveryChunk == false && WebElementId.isRegistrable(element.builderId) == false {
            state.scripts.isolatesEveryChunk = true
        }

        // 1. collect attributes, grouping multi-valued ones
        // Class tokens in order, each once (the same class twice, e.g. the element's id added again by a
        // control, is emitted once). A few are compared one by one; past `linearDedupLimit` a set takes over,
        // so an element with thousands of classes or attributes still renders in linear time.
        var classValues: [String] = []
        var classSet: Set<String>? = nil
        func addClass(_ value: String) {
            if classSet != nil {
                guard classSet!.insert(value).inserted else { return }
            } else {
                if classValues.contains(value) { return }
                if classValues.count >= linearDedupLimit {
                    var set = Set(classValues)
                    set.insert(value)
                    classSet = set
                }
            }
            classValues.append(value)
        }
        var styleValues: [String] = []
        // Attributes other than class / style / name / value / validation, as (lower-cased name, text). An
        // HTML parser keeps only the first of two attributes with the same name, so a repeated one is dropped
        // here; the DOM is the same and the markup is valid.
        var otherParts: [(name: String?, text: String)] = []
        var partNames: Set<String>? = nil
        func addPart(_ name: String?, _ text: String) {
            if let name {
                if partNames != nil {
                    guard partNames!.insert(name).inserted else { return }
                } else {
                    if otherParts.contains(where: { $0.name == name }) { return }
                    if otherParts.count >= linearDedupLimit {
                        var set = Set(otherParts.compactMap { $0.name })
                        set.insert(name)
                        partNames = set
                    }
                }
            }
            otherParts.append((name, text))
        }
        var innerText: String? = nil
        var scripts: [WebPageScriptChunk] = []
        var items: [String] = [] // internal items for combos, dropdowns, segmented controls etc.
        var label: String? = nil
        var initialValue: Any? = nil
        var value: Any? = nil
        // An element has one name and one value: `.name` / `.pair("name", …)` (and `.value` /
        // `.pair("value", …)`) fill the same slot, the last one wins, and it is emitted once.
        var nameSlot: String? = nil
        var errorMessage: String? = nil
        var validators: [ValidationCondition] = []
        var dontRegister = false

        for attr in element.attributes {
            switch attr {
                case .class(let v):
                    addClass(v)
                case .deviceClass(let mobileClass, let desktopClass):
                    let selectedClass = state.isMobile ? mobileClass : desktopClass
                    if let selectedClass, selectedClass.isEmpty == false {
                        addClass(selectedClass)
                    }

                case .style(let v):
                    styleValues.append(v)

                // All attribute values are HTML-escaped centrally here. Callers must pass raw (unescaped)
                // values; `.custom(...)` is the only raw attribute escape hatch. Attribute *names* supplied by
                // callers (`.pair`, `.data`) are stripped of characters that can't appear in a name.
                case .id(let v):           addPart("id", "id=\"\(WebEscape.attribute(v))\"")
                case .name(let v):         nameSlot = v
                case .value(let v):        value = v
                case .type(let v):         addPart("type", "type=\"\(WebEscape.attribute(v))\"")
                case .placeholder(let v):  addPart("placeholder", "placeholder=\"\(WebEscape.attribute(v))\"")
                case .required:            addPart("required", "required")
                case .disabled:            addPart("disabled", "disabled")
                case .readonly:            addPart("readonly", "readonly")
                case .checked:             addPart("checked", "checked")
                case .selected:            addPart("selected", "selected")
                // Text that can run as code, and so refer to element globals, is collected for the
                // registrations (`PageRenderState.resolveRegistrations`): `javascript:` URLs, `.custom` and
                // `.pair` attributes (inline handlers, `formaction="javascript:..."`, `x-on:click`, `hx-on`, ...)
                // and `.data` values (a script may look an element up by a name kept there). Registering an
                // element no script uses is harmless.
                case .src(let v):
                    if WebScriptReferences.isJavaScriptURL(v) { state.referenceTexts.append(v) }
                    addPart("src", "src=\"\(WebEscape.attribute(v))\"")
                case .href(let v):
                    if WebScriptReferences.isJavaScriptURL(v) { state.referenceTexts.append(v) }
                    addPart("href", "href=\"\(WebEscape.attribute(v))\"")
                case .alt(let v):          addPart("alt", "alt=\"\(WebEscape.attribute(v))\"")
                case .title(let v):        addPart("title", "title=\"\(WebEscape.attribute(v))\"")
                case .data(let key):
                    state.referenceTexts.append(key)
                    let text = Self.dataAttribute(key)
                    addPart(lowercasedAttributeName(String(text.prefix(while: { $0 != "=" }))), text)
                case .custom(let s):
                    // raw by design; may be an inline event handler that refers to element globals
                    state.referenceTexts.append(s)
                    addPart(singleCustomAttributeName(s), s)
                case .pair(let k, let v) where k.lowercased() == "name":  nameSlot = v
                case .pair(let k, let v) where k.lowercased() == "value": value = v
                case .pair(let k, let v):
                    let attributeName = WebHTMLSyntax.attributeName(k)
                    let lowered = lowercasedAttributeName(attributeName)
                    state.referenceTexts.append(v)
                    addPart(lowered, "\(attributeName)=\"\(WebEscape.attribute(v))\"")
                case .script(let js):      scripts.append(WebScriptOrigin.chunk(js))
                case .innerHTML(let html):
                    innerText = html   // raw by design: controls escape their text before storing it
                    // raw markup (escaped text has no `<`) may carry inline handlers
                    if html.utf8.contains(0x3C) {
                        state.referenceTexts.append(html)
                    }
                case .domLoadedScript(let script): state.scripts.domLoadedChunks.append(WebScriptOrigin.chunk(script))
                case .item(_):
                    break;
                case .variant(_):
                    break;
                case .parent(_):
                    break;
                case .label(let text):
                    label = text
                case .initialValue(let value):
                    initialValue = value
                case .errorMessage(let message):
                    errorMessage = message
                    addClass("border-danger")
                case .validation(let condition):
                    validators.append(condition)
                case .dontRegisterObject:
                    dontRegister = true
            }
        }

        // An element can be registered as a global (`<id>` in scripts); whether it is depends on whether any
        // script or inline handler on the page refers to it (`PageRenderState.resolveRegistrations`).
        if !dontRegister {
            state.registrable.append(element.builderId)
        }

        // build the items up now if there are any
        if let picker = element as? WebPickerElement {

            // pick out only the subitems
            let subItems  = element.attributes.filter {
                if case .item = $0 { return true }
                return false
            }

            switch picker.type {
                case .combo:
                    let boundValue = picker.value?.asString()
                    // render all items as <option> elements
                    for item in subItems {
                        if case .item(let item) = item {
                            var option = "<option value=\"\(WebEscape.attribute(item.value))\""
                            if item.isSelected || (boundValue != nil && item.value == boundValue) { option += " selected" }
                            if item.isDisabled { option += " disabled" }
                            option += ">\(WebEscape.html(item.title))</option>"
                            items.append(option)
                        }
                    }
                case .segmented:
                    break;
                case .radio:
                    break;
                case .colorPicker:
                    break;
            }
        }

        // 2. now build the final attribute list
        var parts: [String] = []

        if !classValues.isEmpty {
            // join with spaces
            let allClasses = classValues.joined(separator: " ")
            parts.append("class=\"\(WebEscape.attribute(allClasses))\"")
        }
        if !styleValues.isEmpty {
            // merge multiple style strings with semicolons
            let allStyles = styleValues.joined(separator: ";")
            parts.append("style=\"\(WebEscape.attribute(allStyles))\"")
        }

        // Server -> JS values are always emitted as script-safe literals (see WebJSON).
        func jsLiteral(for raw: Any) -> String? {
            return WebJSON.scriptLiteral(any: raw)
        }

        // A password input is never rendered with a value, whatever was bound or submitted, so a secret
        // can't be echoed back into the page (e.g. when a form is re-rendered after failed validation).
        let suppressValue = element.isPasswordInput

        func appendInitialSync(_ initialValue: Any) {
            if let initialLiteral = jsLiteral(for: initialValue) {
                state.scripts.domLoadedChunks.append(WebPageScriptChunk(
                    code: "if (typeof updateWebVariable\(element.builderId) === 'function') { updateWebVariable\(element.builderId)(\(initialLiteral), { source: 'initial' }); }",
                    isRaw: false))
            }
        }

        var valueEmitted = false
        if let variable = element as? WebVariableElement {
            // A variable's hidden carrier input always submits its current value, serialized the way the
            // server parses it back (`.value(...)` attributes on a variable are ignored). `initialValue`
            // only drives the page-load sync of the client-side variable.
            if !suppressValue {
                parts.append("value=\"\(WebEscape.attribute(variable.formValue))\"")
                valueEmitted = true
            }
            if let initialValue = initialValue {
                appendInitialSync(initialValue)
            }
        } else if let initialValue = initialValue {
            if !suppressValue {
                parts.append("value=\"\(WebEscape.attribute("\(initialValue)"))\"")
                valueEmitted = true
            }
            appendInitialSync(initialValue)
        } else if let value = value, !suppressValue {
            parts.append("value=\"\(WebEscape.attribute("\(value)"))\"")
            valueEmitted = true
        }

        // A variable's carrier leaves its field to a control in its form that submits the same name (a
        // bound TextField, a Toggle's checkbox, ...), so no field is posted twice. Which fields the other
        // controls submit is worked out afresh for every render, before the first named carrier.
        var nameEmitted = false
        if let nameSlot {
            var submits = true
            if let variable = element as? WebVariableElement {
                if state.fieldClaimsResolved == false {
                    WebFormFieldClaims.resolve(page: documentRoot)
                    state.fieldClaimsResolved = true
                }
                submits = variable.carrierSubmits(fieldName: nameSlot, onPage: documentRoot)
            }
            if submits {
                parts.append("name=\"\(WebEscape.attribute(nameSlot))\"")
                nameEmitted = true
            }
        }
        // A named variable's carrier keeps its name in `data-wsui-name` even when it leaves the field to
        // another control, so `.setVariableName(_:to:)` can find the variable at run time.
        if let variable = element as? WebVariableElement, let publicName = variable.internalName {
            parts.append("data-wsui-name=\"\(WebEscape.attribute(publicName))\"")
        }
        // a raw attribute that repeats one emitted above would be ignored by the browser: drop it
        for part in otherParts {
            if let name = part.name {
                if (name == "class" && !classValues.isEmpty) || (name == "style" && !styleValues.isEmpty)
                    || (name == "value" && valueEmitted) || (name == "name" && nameEmitted)
                    || (name == "validation" && !validators.isEmpty) {
                    continue
                }
            }
            parts.append(part.text)
        }

        // now compile an encoded set of validators
        if validators.isEmpty == false {
            parts.append("validation=\"\(WebEscape.attribute(validators.map { $0.encoded }.joined(separator: ",")))\"")
        }

        // check for a label to this element
        if let labelText = label {
            out += "\(indent)<label for=\"\(WebEscape.attribute(element.builderId))\">\(WebEscape.html(labelText))</label>\n"
        }

        // 3. open tag (no “>” or newline yet)
        out += indent
        out += "<"
        out += element.elementName
        if parts.isEmpty == false {
            out += " "
            out += parts.joined(separator: " ")
        }

        // flags
        let hasInner   = innerText != nil
        let hasChildren = !element.subElements.isEmpty

        // A void element (`<input>`, `<img>`, `<br>`, ...) has no content and must not get an end tag.
        let isVoid = WebHTMLDocument.isVoidElement(element.elementName)

        // 4a. nothing inside? close inline
        if !hasInner && !hasChildren && items.isEmpty {
            out += isVoid ? ">\n" : "></\(element.elementName)>\n"
        } else {
            // 4b. there is something—emit children in order
            out += ">"
            if hasChildren {
                out += "\n"
            }
            let childIndent = state.indent(depth + 1)

            // 4b.i innerHTML first
            if let html = innerText, !hasChildren {
                out += html
            } else if let html = innerText {
                out += "\(childIndent)\(html)\n"
            } else if items.isEmpty == false {
                out += items.joined(separator: "\n")
            }

            // 4b.ii then any nested elements
            for child in element.subElements {
                render(child, depth: depth + 1, into: &out, state: &state)
            }

            // 4c. close tag. A void element has none: anything nested in one was emitted after its start tag
            // above, which an HTML parser turns into the element's following siblings.
            if isVoid {
                if !hasChildren {
                    out += "\n"
                }
            } else if hasChildren {
                out += "\(indent)</\(element.elementName)>\n"
            } else {
                out += "</\(element.elementName)>\n"
            }
        }

        // 4d. the element's scripts run after its children's, as they did when they followed the element
        state.scripts.elementChunks.append(contentsOf: scripts)

        let childIndent = state.indent(depth + 1)
        // now see if there is an inline error message to show
        if let errorMessage = errorMessage {
            out += "\(childIndent)<div style=\"font-size: x-small; color: red;\">\(WebEscape.html(errorMessage))</div>\n"
        }

        // now see if there are any validation items, which may need to show an error message
        if validators.isEmpty == false {
            out += "\(childIndent)<div class=\"text-danger fw-light\" id=\"validation_error_\(WebEscape.attribute(element.builderId))\"></div>\n"
        }
    }


    /// Renders a `WebFragmentElement`: its children, in order, at the fragment's own indent. It has no tag, so
    /// attributes that decorate one are ignored, and there is no DOM node for it to be registered as. Its
    /// `.domLoadedScript`s join the page's DOMContentLoaded scripts and its `.script`s run after its children's.
    private func renderFragment(_ fragment: WebElement, depth: Int, into out: inout String, state: inout PageRenderState) {
        var scripts: [WebPageScriptChunk] = []
        for attr in fragment.attributes {
            switch attr {
                case .script(let js): scripts.append(WebScriptOrigin.chunk(js))
                case .domLoadedScript(let script): state.scripts.domLoadedChunks.append(WebScriptOrigin.chunk(script))
                default: break
            }
        }
        for child in fragment.subElements {
            render(child, depth: depth, into: &out, state: &state)
        }
        state.scripts.elementChunks.append(contentsOf: scripts)
    }

    /// Renders a single head element with the given indent and a trailing newline.
    private func render(_ element: WebCoreHeadElement, indent: String) -> String {
        switch element {
            case .title(let text):
                return "\(indent)<title>\(WebEscape.html(text))</title>\n"
                
            case .base(let href):
                return "\(indent)<base href=\"\(WebEscape.attribute(href))\" />\n"
                
                // MARK: Meta tags
            case .metaCharset(let charset):
                return "\(indent)<meta charset=\"\(WebEscape.attribute(charset))\" />\n"
                
            case .metaHttpEquiv(let httpEquiv, let content):
                return "\(indent)<meta http-equiv=\"\(WebEscape.attribute(httpEquiv))\" content=\"\(WebEscape.attribute(content))\" />\n"
                
            case .metaName(let name, let content):
                return "\(indent)<meta name=\"\(WebEscape.attribute(name))\" content=\"\(WebEscape.attribute(content))\" />\n"
                
            case .metaProperty(let prop, let content):
                return "\(indent)<meta property=\"\(WebEscape.attribute(prop))\" content=\"\(WebEscape.attribute(content))\" />\n"
                
            case .metaViewport(let content):
                return "\(indent)<meta name=\"viewport\" content=\"\(WebEscape.attribute(content))\" />\n"
                
            case .metaThemeColor(let color):
                return "\(indent)<meta name=\"theme-color\" content=\"\(WebEscape.attribute(color))\" />\n"
                
            case .metaDescription(let desc):
                return "\(indent)<meta name=\"description\" content=\"\(WebEscape.attribute(desc))\" />\n"
                
            case .metaApplicationName(let name):
                return "\(indent)<meta name=\"application-name\" content=\"\(WebEscape.attribute(name))\" />\n"
                
            case .metaMobileWebAppCapable(let capable):
                let val = capable ? "yes" : "no"
                return "\(indent)<meta name=\"mobile-web-app-capable\" content=\"\(val)\" />\n"
                
                // MARK: Link tags
            case .link(let rel, let href, let type, let sizes, let color, let attrs):
                var parts: [String] = ["rel=\"\(WebEscape.attribute(rel.stringValue))\"", "href=\"\(WebEscape.attribute(href))\""]
                if let t = type        { parts.append("type=\"\(WebEscape.attribute(t))\"") }
                if let s = sizes       { parts.append("sizes=\"\(WebEscape.attribute(s))\"") }
                if let c = color       { parts.append("color=\"\(WebEscape.attribute(c))\"") }
                if let extra = attrs {
                    // sorted, so the output is the same on every render (dictionary order is not)
                    for (k,v) in extra.sorted(by: { $0.key < $1.key }) { parts.append("\(WebHTMLSyntax.attributeName(k))=\"\(WebEscape.attribute(v))\"") }
                }
                return "\(indent)<link \(parts.joined(separator: " ")) />\n"
                
                // MARK: Scripts & Styles
            case .script(let src, let async, let `defer`, let type, let integrity, let crossOrigin, let attributes):
                var parts: [String] = ["src=\"\(WebEscape.attribute(src))\""]
                if async               { parts.append("async") }
                if `defer`             { parts.append("defer") }
                if let t = type        { parts.append("type=\"\(WebEscape.attribute(t))\"") }
                if let i = integrity   { parts.append("integrity=\"\(WebEscape.attribute(i))\"") }
                if let co = crossOrigin{ parts.append("crossorigin=\"\(WebEscape.attribute(co))\"") }
                if let extra = attributes {
                    for (k,v) in extra.sorted(by: { $0.key < $1.key }) { parts.append("\(WebHTMLSyntax.attributeName(k))=\"\(WebEscape.attribute(v))\"") }
                }
                return "\(indent)<script \(parts.joined(separator: " "))></script>\n"
                
            // Inline script/style bodies, and the tag name + inner HTML of `.custom`, are raw by design
            // (trusted, developer-supplied code). Every attribute value in the head is escaped.
            case .inlineScript(let code):
                let body = WebJSON.scriptElementBody(code)
                return "\(indent)<script>\n\(indent)\(tab)\(body)\n\(WebJSON.scriptElementTerminator(for: body))\(indent)</script>\n"
                
            case .styleLink(let href):
                return "\(indent)<link rel=\"stylesheet\" href=\"\(WebEscape.attribute(href))\" />\n"
                
            case .inlineStyle(let css):
                return "\(indent)<style>\n\(indent)\(tab)\(css)\n\(indent)</style>\n"
                
                // MARK: Comment & Custom
            case .comment(let text):
                return "\(indent)<!-- \(WebHTMLSyntax.commentText(text)) -->\n"
                
            case .custom(let tag, let attributes, let innerHTML):
                let attrs = attributes.sorted(by: { $0.key < $1.key })
                    .map { "\(WebHTMLSyntax.attributeName($0.key))=\"\(WebEscape.attribute($0.value))\"" }.joined(separator: " ")
                if let inner = innerHTML {
                    return "\(indent)<\(tag) \(attrs)>\(inner)</\(tag)>\n"
                } else {
                    return "\(indent)<\(tag) \(attrs) />\n"
                }
        }
    }
}

extension CoreWebEndpoint {
    /// Renders `.data(_:)`: `"name"` gives `data-name`, and `"name=value"` (the value optionally quoted, as
    /// callers wrote it before escaping was central) gives `data-name="value"` with the value escaped.
    static func dataAttribute(_ raw: String) -> String {
        guard let eq = raw.firstIndex(of: "=") else {
            return "data-\(WebHTMLSyntax.attributeName(raw))"
        }
        let name = WebHTMLSyntax.attributeName(String(raw[..<eq]).trimmingCharacters(in: .whitespaces))
        var value = Substring(raw[raw.index(after: eq)...].trimmingCharacters(in: .whitespaces))
        if value.count >= 2, let quote = value.first, quote == "\"" || quote == "'", value.last == quote {
            value = value.dropFirst().dropLast()
        }
        return "data-\(name)=\"\(WebEscape.attribute(String(value)))\""
    }
}
