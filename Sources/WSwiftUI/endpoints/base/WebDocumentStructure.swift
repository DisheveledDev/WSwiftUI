//
//  WebDocumentStructure.swift
//  WSwiftUI
//
//  The parts of the page skeleton that every rendered document shares: the synthetic root that the
//  builder hangs top-level elements from, the doctype and character set, the HTML void elements, element
//  ids, and the script block at the end of `<body>` (element registrations, element scripts and the
//  DOMContentLoaded scripts, each isolated from the others).
//

import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// An element with no tag of its own: it renders only its children, in order, at its own position.
///
/// `CoreWebEndpoint.documentRoot` is a fragment, so every element created outside a container (before,
/// inside or after `webpage {}`) is emitted into `<body>` in creation order, and `webpage {}` is one too,
/// so it adds no wrapper element. Attributes that decorate a tag (class, id, style, name, ...) have
/// nothing to attach to and are ignored. Scripts attached to a fragment still run: `.domLoadedScript`
/// joins the page's DOMContentLoaded scripts and `.script` joins the element scripts after the fragment's
/// children's. There is no DOM node to look up, so a fragment is never registered.
internal final class WebFragmentElement: WebElement {}

internal enum WebHTMLDocument {

    /// Emitted before `<html>`, so browsers render the page in standards mode rather than quirks mode.
    static let doctype = "<!DOCTYPE html>"

    /// The page's character encoding. Pages are always written out as UTF-8 (and served with
    /// `Content-Type: text/html; charset=utf-8`), so this is the only value that can be declared.
    static let charset = "utf-8"

    /// HTML void elements: they have no content and must not have an end tag.
    static let voidElements: Set<String> = [
        "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "source", "track", "wbr"
    ]

    static func isVoidElement(_ elementName: String) -> Bool {
        if voidElements.contains(elementName) { return true }
        // element names are almost always lower case already; only fold the case when there is any
        guard elementName.utf8.contains(where: { $0 >= 0x41 && $0 <= 0x5A }) else { return false }
        return voidElements.contains(elementName.lowercased())
    }

    // MARK: Character set declarations

    /// A head entry that declares the document's character set, which the renderer drops because the page
    /// always declares `<meta charset="utf-8">` first (a document may declare its encoding only once).
    /// `contradicts` is `true` when the entry names another encoding or is a second declaration of a kind
    /// the page did not ask for twice (`http-equiv="Content-Type"`, a custom `<meta charset>`): those are
    /// logged once; a `.metaCharset("utf-8")` is just dropped.
    struct CharsetDeclaration {
        /// Which head entry it is (`metaCharset`, `metaHttpEquiv`, `custom`): what the log-once key uses,
        /// so the set of keys stays bounded whatever values pages declare.
        let kind: String
        let description: String
        let contradicts: Bool
    }

    static func charsetDeclaration(in element: WebCoreHeadElement) -> CharsetDeclaration? {
        switch element {
            case .metaCharset(let value):
                let normalized = value.trimmingCharacters(in: .whitespaces).lowercased()
                return CharsetDeclaration(kind: "metaCharset", description: ".metaCharset(\"\(value)\")",
                                          contradicts: normalized != "utf-8" && normalized != "utf8")
            case .metaHttpEquiv(let httpEquiv, let content):
                guard httpEquiv.trimmingCharacters(in: .whitespaces).lowercased() == "content-type" else { return nil }
                return CharsetDeclaration(kind: "metaHttpEquiv", description: ".metaHttpEquiv(httpEquiv: \"\(httpEquiv)\", content: \"\(content)\")",
                                          contradicts: true)
            case .custom(let tag, let attributes, _):
                guard tag.trimmingCharacters(in: .whitespaces).lowercased() == "meta" else { return nil }
                for (key, value) in attributes {
                    let name = key.lowercased()
                    if name == "charset" || (name == "http-equiv" && value.trimmingCharacters(in: .whitespaces).lowercased() == "content-type") {
                        return CharsetDeclaration(kind: "custom", description: ".custom(tag: \"\(tag)\", \(name)=\"\(value)\")", contradicts: true)
                    }
                }
                return nil
            default:
                return nil
        }
    }

    private static let charsetLogLock = NSLock()
    nonisolated(unsafe) private static var charsetLogged: Set<String> = []

    /// Logs, once per endpoint type and kind of declaration, that a conflicting charset declaration was
    /// dropped. Returns `true` when it logged.
    @discardableResult
    static func logDroppedCharset(endpoint: String, declaration: CharsetDeclaration) -> Bool {
        let key = "\(endpoint)|\(declaration.kind)"
        charsetLogLock.lock()
        let first = charsetLogged.insert(key).inserted
        charsetLogLock.unlock()
        if first {
            WSwiftUIDiagnostics.log("[WSwiftUI] \(endpoint): dropped the head entry \(WSwiftUIDiagnostics.printable(declaration.description)). Pages are always sent as UTF-8 and declare <meta charset=\"utf-8\"> as the first element of <head>; a second character set declaration is invalid. (logged once for this endpoint)")
        }
        return first
    }

    // MARK: DOMContentLoaded

    /// Defined once, at the top of a page's first framework `<script>`, when the page has wrapped scripts:
    /// reports a caught exception with the browser's own `reportError`, which logs it as uncaught and fires
    /// `window` `error` listeners, so error monitoring that listens there (e.g. Sentry's global handlers)
    /// still sees it. A `reportError` the page defined itself (a common helper name, with its own meaning)
    /// is not native and is not called; then, and in browsers without `reportError` (older than 2022), the
    /// exception goes to `console.error`.
    static let reportFunction = "function __wsuiReport(e) { if (typeof reportError === 'function' && /\\[native code\\]/.test(Function.prototype.toString.call(reportError))) { reportError(e); } else { console.error(e); } }\n"

    /// The `catch` clause of the isolation wrappers (see `reportFunction`).
    static let isolatedScriptCatch = "catch (e) { __wsuiReport(e); }"

    /// Wraps one DOMContentLoaded script in a function of its own inside a try/catch: an exception it throws is
    /// reported (see `isolatedScriptCatch`), and a `return` at its top level ends only that script; the scripts
    /// after it still run. Its `var`s and functions are its own. The closing brace goes on its own line, so a
    /// script that ends in a `//` comment can't comment it out.
    static func isolatedDOMContentLoadedScript(_ script: String) -> String {
        return "try { (function () {\n" + script + "\n}).apply(this, arguments); } " + isolatedScriptCatch + "\n"
    }

    /// Wraps one element script in a try/catch, so a runtime exception in it is reported (see
    /// `isolatedScriptCatch`) and the element scripts after it still run. A try block keeps the script's
    /// `var`s and function declarations global, as they were in a `<script>` element of its own.
    static func isolatedElementScript(_ script: String) -> String {
        return "try {\n" + script + "\n} " + isolatedScriptCatch + "\n"
    }
}

// MARK: - Element ids

internal enum WebElementId {

    private static let letters = Array("abcdefghijklmnopqrstuvwxyz".utf8)
    private static let alphanumerics = Array("abcdefghijklmnopqrstuvwxyz0123456789".utf8)

    /// A random namespace: a letter and four letters or digits (26 x 36^4, about 4.4e7 namespaces), so two
    /// requests whose HTML meets in one page share a namespace with a probability of about 2e-8.
    static func randomNamespace() -> String {
        var generator = SystemRandomNumberGenerator()
        var bytes: [UInt8] = [letters.randomElement(using: &generator)!]
        for _ in 0..<4 {
            bytes.append(alphanumerics.randomElement(using: &generator)!)
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// The id of an element not (yet) created through an endpoint: a random namespace and a random suffix.
    /// Never empty, always a valid JavaScript identifier and CSS class.
    static func fallback() -> String {
        var generator = SystemRandomNumberGenerator()
        var suffix: [UInt8] = []
        for _ in 0..<6 {
            suffix.append(alphanumerics.randomElement(using: &generator)!)
        }
        return randomNamespace() + "_" + String(decoding: suffix, as: UTF8.self)
    }

    /// `elementIdNamespace` reduced to ASCII letters and digits, starting with a letter (an `n` is put in
    /// front of a leading digit). `nil` when nothing usable is left.
    static func sanitizedNamespace(_ raw: String) -> String? {
        let kept = raw.unicodeScalars.filter { $0.isASCII && (CharacterSet.alphanumerics.contains($0)) }
        guard let first = kept.first else { return nil }
        var value = String(String.UnicodeScalarView(kept))
        if CharacterSet.decimalDigits.contains(first) {
            value = "n" + value
        }
        return value
    }

    /// JavaScript reserved words, and globals a `var` must never shadow, that an app could have assigned as
    /// a `builderId` by hand. Generated ids (`<namespace>_<n>`) can never be one of them.
    private static let unsafeGlobals: Set<String> = [
        "break", "case", "catch", "class", "const", "continue", "debugger", "default", "delete", "do", "else",
        "enum", "export", "extends", "false", "finally", "for", "function", "if", "implements", "import", "in",
        "instanceof", "interface", "let", "new", "null", "package", "private", "protected", "public", "return",
        "static", "super", "switch", "this", "throw", "true", "try", "typeof", "var", "void", "while", "with",
        "yield", "await", "arguments", "eval", "undefined", "NaN", "Infinity", "globalThis", "window", "self",
        "top", "parent", "frames", "opener", "document", "location", "history", "navigator", "name", "status",
        "length", "origin", "closed", "event", "external", "console", "close", "open", "print", "focus", "blur",
        "stop", "fetch", "alert", "confirm", "prompt"
    ]

    /// Whether an element with this id can be registered as a global `var`: a plain ASCII identifier that is
    /// not a reserved word, not a browser global and not one of the registration block's own names.
    static func isRegistrable(_ id: String) -> Bool {
        var iterator = id.utf8.makeIterator()
        guard let first = iterator.next(), isIdentifierStart(first) else { return false }
        while let byte = iterator.next() {
            guard isIdentifierPart(byte) else { return false }
        }
        if id.hasPrefix("__wsui") { return false }
        return unsafeGlobals.contains(id) == false
    }

    @inline(__always)
    static func isIdentifierStart(_ byte: UInt8) -> Bool {
        return (byte >= 0x61 && byte <= 0x7A) || (byte >= 0x41 && byte <= 0x5A) || byte == 0x5F || byte == 0x24
    }

    @inline(__always)
    static func isIdentifierPart(_ byte: UInt8) -> Bool {
        return isIdentifierStart(byte) || (byte >= 0x30 && byte <= 0x39)
    }
}

// MARK: - Where a script came from

/// Scripts are framework code or raw JavaScript from the app. Framework code (generated by WSwiftUI) shares
/// one `<script>` element at the end of `<body>`; raw JavaScript gets a `<script>` element of its own, so a
/// syntax error in it can't stop the framework's scripts or any other element's.
///
/// Raw JavaScript is: a `.script` / `.domLoadedScript` attribute added from outside the WSwiftUI module
/// (`WebElement.script(_:)` or `addAttribute(_:)` in app code; stored with `rawMarker` in front, which the
/// renderer removes), and any script containing the code of an action that is JavaScript by design
/// (`WebAction.script`, `.handleResponse`, `.setVariableFromExpression`, `.animate`; the action compiler
/// marks it with `rawMarker`, a comment, which the renderer removes from the script it emits).
///
/// Values never produce the marker: it contains `<`, and every value the framework writes into a script goes
/// through `WebJSON` (`scriptString`, `scriptLiteral`, `makeScriptSafe`), which always writes `<` as `\u003c`.
/// So a framework script holds the marker only where the action compiler or `tagged(_:addedFrom:)` put it, and
/// a value that looks like it (`"/*<wsui:raw>*/"`, or the `/*wsui:raw*/` an earlier version used) is neither
/// taken for raw code nor changed.
internal enum WebScriptOrigin {

    /// A JavaScript comment, so it is harmless wherever it ends up. The `<` keeps values from forging it (see
    /// above).
    static let rawMarker = "/*<wsui:raw>*/"

    /// The module name in `#fileID` of the WSwiftUI sources (`"WSwiftUI/File.swift"`), with the slash.
    private static let frameworkFileIDPrefix: [UInt8] = {
        let fileID = "\(#fileID)"
        let module = fileID.prefix(while: { $0 != "/" })
        return Array("\(module)/".utf8)
    }()

    /// Whether `file` (a caller's `#fileID`) is in the WSwiftUI module.
    static func isFramework(_ file: StaticString) -> Bool {
        guard file.hasPointerRepresentation else { return false }
        let prefix = frameworkFileIDPrefix
        guard file.utf8CodeUnitCount >= prefix.count else { return false }
        let start = file.utf8Start
        for index in 0..<prefix.count where start[index] != prefix[index] {
            return false
        }
        return true
    }

    /// The attribute to store for one added from `file`: scripts from app code are marked as raw.
    static func tagged(_ attribute: WebCoreElementAttribute, addedFrom file: StaticString) -> WebCoreElementAttribute {
        switch attribute {
            case .script(let js):
                return isFramework(file) ? attribute : .script(rawMarker + js)
            case .domLoadedScript(let js):
                return isFramework(file) ? attribute : .domLoadedScript(rawMarker + js)
            default:
                return attribute
        }
    }

    private static let rawMarkerBytes = Array(rawMarker.utf8)

    /// A stored script as the renderer emits it: without the app-code marker, and whether it is raw.
    static func chunk(_ stored: String) -> WebPageScriptChunk {
        if stored.utf8.starts(with: rawMarkerBytes) {
            return WebPageScriptChunk(code: String(decoding: stored.utf8.dropFirst(rawMarkerBytes.count), as: UTF8.self), isRaw: true)
        }
        return WebPageScriptChunk(code: stored, isRaw: containsRawMarker(stored))
    }

    /// `code` without the markers the action compiler put in front of raw JavaScript (they only classify the
    /// script; once it has a `<script>` element of its own they have done their job). Only raw scripts go
    /// through this: a value in them can't contain the marker (see above), so only markers that were inserted
    /// are removed, and the app's own raw code is changed only if it spells the marker out itself.
    static func withoutRawMarkers(_ code: String) -> String {
        guard containsRawMarker(code) else { return code }
        return code.replacingOccurrences(of: rawMarker, with: "")
    }

    /// Whether `text` contains `rawMarker`: a byte search (every script of the page goes through it).
    static func containsRawMarker(_ text: String) -> Bool {
        let marker = rawMarkerBytes
        func search(_ buffer: UnsafeBufferPointer<UInt8>) -> Bool {
            let count = buffer.count
            let length = marker.count
            guard count >= length else { return false }
            let first = marker[0]
            var index = 0
            while index <= count - length {
                if buffer[index] == first {
                    var matched = true
                    for offset in 1..<length where buffer[index + offset] != marker[offset] {
                        matched = false
                        break
                    }
                    if matched { return true }
                }
                index += 1
            }
            return false
        }
        if let found = text.utf8.withContiguousStorageIfAvailable(search) {
            return found
        }
        return Array(text.utf8).withUnsafeBufferPointer(search)
    }
}

// MARK: - The script block at the end of <body>

internal struct WebPageScriptChunk {
    var code: String
    var isRaw: Bool
}

/// The scripts of a page, emitted after the last element of `<body>`, in this order:
///
/// 1. the registrations: `<id> = <the element with class id>` for each element whose id a script or inline
///    event handler refers to (and only those), as global `var`s;
/// 2. the element scripts, in the order they used to run when each followed its element (children before
///    their parent), each in a try/catch;
/// 3. one DOMContentLoaded listener running the DOMContentLoaded scripts in order, each in a function and a
///    try/catch of its own.
///
/// Framework code shares one `<script>` element. A raw script (see `WebScriptOrigin`) closes it and gets one
/// of its own, emitted unwrapped exactly as it used to be; framework code after it continues in a new
/// `<script>` element, so the order of all scripts is kept.
internal struct WebPageScripts {
    var registrations: [String] = []
    var elementChunks: [WebPageScriptChunk] = []
    var domLoadedChunks: [WebPageScriptChunk] = []
    /// Set when an element on the page has a `builderId` that is not a plain identifier (an app can assign
    /// any string, e.g. a UUID). Framework code uses builderIds as JavaScript names, so a script mentioning
    /// one would be a syntax error, and in a shared `<script>` it would stop every framework script. Every
    /// chunk then gets a `<script>` element of its own, as each element's scripts used to.
    var isolatesEveryChunk = false

    var isEmpty: Bool { registrations.isEmpty && elementChunks.isEmpty && domLoadedChunks.isEmpty }

    /// Up to this many registered elements are looked up one by one (`getElementsByClassName`, which walks
    /// the document up to the element); more are found in one walk over the document, so registering an
    /// element per table row stays linear in the size of the page.
    static let lookupsPerElementLimit = 32

    func render(indent: String) -> String {
        guard isEmpty == false else { return "" }
        var out = ""
        var blockOpen = false
        // whether the open framework block contains `<!--` (see `WebJSON.scriptElementTerminator`)
        var blockHasCommentOpener = false
        func openBlock() {
            if blockOpen == false {
                out += "\(indent)<script>\n"
                blockOpen = true
                blockHasCommentOpener = false
            }
        }
        func appendToBlock(_ code: String) {
            if blockHasCommentOpener == false && WebJSON.containsHTMLCommentOpener(code) {
                blockHasCommentOpener = true
            }
            out += code
        }
        func closeBlock() {
            if blockOpen {
                if blockHasCommentOpener {
                    out += WebJSON.htmlCommentTerminator
                }
                out += "\(indent)</script>\n"
                blockOpen = false
            }
        }

        // the wrappers' catch clauses call __wsuiReport: define it first, in the first framework block (a raw
        // script that closes the block still runs after it, and so do the DOMContentLoaded scripts)
        let wrapsAnyScript = domLoadedChunks.isEmpty == false
            || (isolatesEveryChunk == false && elementChunks.contains { $0.isRaw == false })
        if wrapsAnyScript {
            openBlock()
            out += WebHTMLDocument.reportFunction
        }

        if registrations.isEmpty == false {
            openBlock()
            out += "var \(registrations.joined(separator: ", "));\n"
            if registrations.count <= Self.lookupsPerElementLimit {
                // a few elements: one lookup each (each walks the document up to the element)
                out += "(function (__wsuiDocument) {\n"
                out += "function __wsuiElement(id) { return __wsuiDocument.getElementsByClassName(id)[0]; }\n"
                for id in registrations {
                    out += "\(id) = __wsuiElement(\"\(id)\");\n"
                }
                out += "})(document);\n"
            } else {
                // many elements (e.g. a handler on every row of a table): one walk over the document, which
                // finds the first element of each class, as `getElementsByClassName(id)[0]` does
                out += "(function (__wsuiDocument, __wsuiIds) {\n"
                out += "var wanted = Object.create(null), all = __wsuiDocument.getElementsByTagName('*'), i, j, list;\n"
                out += "for (i = 0; i < __wsuiIds.length; i++) { wanted[__wsuiIds[i]] = true; }\n"
                out += "for (i = 0; i < all.length; i++) { list = all[i].classList; for (j = 0; j < list.length; j++) { if (wanted[list[j]] === true) { wanted[list[j]] = false; window[list[j]] = all[i]; } } }\n"
                out += "})(document, [\(registrations.map { "\"\($0)\"" }.joined(separator: ", "))]);\n"
            }
        }

        for chunk in elementChunks {
            if chunk.isRaw || isolatesEveryChunk {
                closeBlock()
                let body = WebJSON.scriptElementBody(WebScriptOrigin.withoutRawMarkers(chunk.code))
                out += "\(indent)<script>\(body)\(WebJSON.scriptElementTerminator(for: body))</script>\n"
            } else {
                openBlock()
                appendToBlock(WebHTMLDocument.isolatedElementScript(WebJSON.scriptElementBody(chunk.code)))
            }
        }

        let listenerOpening = "document.addEventListener('DOMContentLoaded', function () {\n"
        let listenerClosing = "});\n"
        var listenerOpen = false
        for chunk in domLoadedChunks {
            let isolated = chunk.isRaw || isolatesEveryChunk
            let body = WebJSON.scriptElementBody(isolated ? WebScriptOrigin.withoutRawMarkers(chunk.code) : chunk.code)
            if isolated {
                if listenerOpen {
                    out += listenerClosing
                    listenerOpen = false
                }
                closeBlock()
                out += "\(indent)<script>\n" + listenerOpening + WebHTMLDocument.isolatedDOMContentLoadedScript(body)
                    + listenerClosing + WebJSON.scriptElementTerminator(for: body) + "\(indent)</script>\n"
            } else {
                openBlock()
                if listenerOpen == false {
                    out += listenerOpening
                    listenerOpen = true
                }
                appendToBlock(WebHTMLDocument.isolatedDOMContentLoadedScript(body))
            }
        }
        if listenerOpen {
            out += listenerClosing
        }
        closeBlock()
        return out
    }
}

/// Finds which element ids the page's scripts and inline event handlers refer to: every identifier-shaped
/// token (inside string literals too, so a lookup such as `window['<id>']` counts) that is one of the
/// candidate ids. One pass over each text; a token becomes a `String` only when its length and first byte
/// can match a candidate.
///
/// Tokens are split where JavaScript splits identifiers: at ASCII punctuation and white space, and at the
/// non-ASCII white space and line terminators (U+00A0, U+1680, U+2000-U+200A, U+2028, U+2029, U+202F,
/// U+205F, U+3000, U+FEFF). Any other non-ASCII character can be part of an identifier, so it continues a
/// token.
///
/// When every candidate contains a `_` (generated ids always do: `<namespace>_<n>`), only a token with a `_`
/// can be one, so the scan jumps from one `_` to the next (`memchr`) and reads just the tokens around them:
/// markup and text, which rarely contain a `_`, are skipped at memory speed. Otherwise every token is read.
/// Both find the same ids.
internal struct WebScriptReferences {

    private let candidates: Set<String>
    private var firstBytes = [Bool](repeating: false, count: 256)
    private var minLength = Int.max
    private var maxLength = 0
    /// Whether every candidate contains a `_`, so the scan may jump between underscores.
    private let everyCandidateHasAnUnderscore: Bool
    /// Tests turn the jumps off to compare both scans.
    internal var jumpsBetweenUnderscores = true
    private(set) var found: Set<String> = []

    init<S: Sequence>(candidates ids: S) where S.Element == String {
        var set = Set<String>()
        for id in ids where WebElementId.isRegistrable(id) {
            set.insert(id)
        }
        candidates = set
        var allHaveUnderscore = true
        for id in set {
            let count = id.utf8.count
            minLength = min(minLength, count)
            maxLength = max(maxLength, count)
            if let first = id.utf8.first {
                firstBytes[Int(first)] = true
            }
            if id.utf8.contains(0x5F) == false {
                allHaveUnderscore = false
            }
        }
        everyCandidateHasAnUnderscore = allHaveUnderscore
    }

    var hasCandidates: Bool { candidates.isEmpty == false }

    /// Whether an attribute value is a `javascript:` URL, as a browser reads it: leading and trailing C0
    /// controls and spaces are ignored, tabs and line breaks anywhere are removed, and the scheme is matched
    /// without regard to case. Its code runs when the link is followed, so it can refer to element globals
    /// like an inline handler.
    static func isJavaScriptURL(_ value: String) -> Bool {
        let scheme = Array("javascript:".utf8)
        var matched = 0
        var leading = true
        for byte in value.utf8 {
            if leading && byte <= 0x20 { continue }
            leading = false
            if byte == 0x09 || byte == 0x0A || byte == 0x0D { continue }
            // `| 0x20` lower-cases an ASCII letter; ':' (0x3A) is compared as it is
            let folded = (byte >= 0x41 && byte <= 0x5A) ? byte | 0x20 : byte
            guard folded == scheme[matched] else { return false }
            matched += 1
            if matched == scheme.count { return true }
        }
        return false
    }

    mutating func scan(_ text: String) {
        guard candidates.isEmpty == false else { return }
        if text.utf8.withContiguousStorageIfAvailable({ scan(buffer: $0) }) != nil {
            return
        }
        let bytes = Array(text.utf8)
        bytes.withUnsafeBufferPointer { scan(buffer: $0) }
    }

    /// For each byte: 1 when it can start a name (ASCII letter, `_`, `$`), 2 for a digit, 3 for a byte of a
    /// non-ASCII character (part of a name unless the character is white space, see
    /// `whiteSpaceLength(_:at:)`), 0 otherwise.
    private static let byteClass: [UInt8] = (0..<256).map { value -> UInt8 in
        let byte = UInt8(value)
        if WebElementId.isIdentifierStart(byte) { return 1 }
        if byte >= 0x30 && byte <= 0x39 { return 2 }
        if byte >= 0x80 { return 3 }
        return 0
    }

    /// The length in bytes of the non-ASCII JavaScript white space or line terminator at `index` (U+00A0,
    /// U+1680, U+2000-U+200A, U+2028, U+2029, U+202F, U+205F, U+3000, U+FEFF), 0 when there is none.
    @inline(__always)
    static func whiteSpaceLength(_ buffer: UnsafeBufferPointer<UInt8>, at index: Int) -> Int {
        let count = buffer.count
        let lead = buffer[index]
        guard index + 1 < count else { return 0 }
        let second = buffer[index + 1]
        if lead == 0xC2 {
            return second == 0xA0 ? 2 : 0                                       // U+00A0
        }
        guard index + 2 < count else { return 0 }
        let third = buffer[index + 2]
        switch lead {
            case 0xE1:
                return second == 0x9A && third == 0x80 ? 3 : 0                    // U+1680
            case 0xE2:
                if second == 0x80 {
                    // U+2000-U+200A, U+2028, U+2029, U+202F
                    return (third >= 0x80 && third <= 0x8A) || third == 0xA8 || third == 0xA9 || third == 0xAF ? 3 : 0
                }
                return second == 0x81 && third == 0x9F ? 3 : 0                    // U+205F
            case 0xE3:
                return second == 0x80 && third == 0x80 ? 3 : 0                    // U+3000
            case 0xEF:
                return second == 0xBB && third == 0xBF ? 3 : 0                    // U+FEFF
            default:
                return 0
        }
    }

    private mutating func scan(buffer: UnsafeBufferPointer<UInt8>) {
        if everyCandidateHasAnUnderscore && jumpsBetweenUnderscores {
            scanTokensWithUnderscores(buffer)
        } else {
            scanEveryToken(buffer)
        }
    }

    /// Whether `buffer[index]` is part of a token (a name or a number): an ASCII letter, digit, `_` or `$`, or
    /// a byte of a non-ASCII character other than white space. `index` must not be inside a white space
    /// character (callers step over them whole).
    @inline(__always)
    private static func isTokenByte(_ buffer: UnsafeBufferPointer<UInt8>, at index: Int, classes: UnsafeBufferPointer<UInt8>) -> Bool {
        let kind = classes[Int(buffer[index])]
        if kind == 0 { return false }
        if kind == 3 && whiteSpaceLength(buffer, at: index) > 0 { return false }
        return true
    }

    /// Whether the bytes just before `index` are a non-ASCII white space character.
    @inline(__always)
    private static func endsWithWhiteSpace(_ buffer: UnsafeBufferPointer<UInt8>, before index: Int) -> Bool {
        if index >= 2 && whiteSpaceLength(buffer, at: index - 2) == 2 { return true }
        if index >= 3 && whiteSpaceLength(buffer, at: index - 3) == 3 { return true }
        return false
    }

    /// The first `_` at or after `from`.
    @inline(__always)
    private static func nextUnderscore(_ buffer: UnsafeBufferPointer<UInt8>, from: Int) -> Int? {
        guard from < buffer.count, let base = buffer.baseAddress else { return nil }
        #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
        guard let hit = memchr(base + from, 0x5F, buffer.count - from) else { return nil }
        return UnsafeRawPointer(base).distance(to: UnsafeRawPointer(hit))
        #else
        var index = from
        while index < buffer.count {
            if buffer[index] == 0x5F { return index }
            index += 1
        }
        return nil
        #endif
    }

    /// Checks the token `buffer[start..<end]` against the candidates.
    @inline(__always)
    private func check(_ buffer: UnsafeBufferPointer<UInt8>, _ start: Int, _ end: Int, classes: UnsafeBufferPointer<UInt8>,
                       first: UnsafeBufferPointer<Bool>, into matches: inout Set<String>) {
        let length = end - start
        // a name (a number such as `1e5` or `0x1f` starts with a digit and is never one)
        guard classes[Int(buffer[start])] == 1, length >= minLength, length <= maxLength, first[Int(buffer[start])] else { return }
        let token = String(decoding: UnsafeBufferPointer(rebasing: buffer[start..<end]), as: UTF8.self)
        if candidates.contains(token) {
            matches.insert(token)
        }
    }

    /// Reads every token.
    private mutating func scanEveryToken(_ buffer: UnsafeBufferPointer<UInt8>) {
        var matches = Set<String>()
        Self.byteClass.withUnsafeBufferPointer { classes in
            firstBytes.withUnsafeBufferPointer { first in
                let count = buffer.count
                var index = 0
                while index < count {
                    let kind = classes[Int(buffer[index])]
                    if kind == 0 {
                        index += 1
                        continue
                    }
                    if kind == 3 {
                        let space = Self.whiteSpaceLength(buffer, at: index)
                        if space > 0 {
                            index += space
                            continue
                        }
                    }
                    // a name, or a number (`10`, `1e5`, `0x1f`) which is skipped whole
                    let start = index
                    index += 1
                    while index < count, Self.isTokenByte(buffer, at: index, classes: classes) {
                        index += 1
                    }
                    check(buffer, start, index, classes: classes, first: first, into: &matches)
                }
            }
        }
        found.formUnion(matches)
    }

    /// Reads only the tokens that contain a `_`, jumping from one `_` to the next. Each token is read once:
    /// back from its first `_` to its start (never before the end of the previous token read), then forward
    /// to its end, where the next jump starts. So the scan stays linear, also for a long token full of
    /// underscores.
    private mutating func scanTokensWithUnderscores(_ buffer: UnsafeBufferPointer<UInt8>) {
        var matches = Set<String>()
        Self.byteClass.withUnsafeBufferPointer { classes in
            firstBytes.withUnsafeBufferPointer { first in
                let count = buffer.count
                var index = 0
                while let underscore = Self.nextUnderscore(buffer, from: index) {
                    var start = underscore
                    while start > index {
                        let previous = start - 1
                        let kind = classes[Int(buffer[previous])]
                        if kind == 0 { break }
                        // the last byte of a non-ASCII white space character ends the token there
                        if kind == 3 && Self.endsWithWhiteSpace(buffer, before: start) { break }
                        start = previous
                    }
                    var end = underscore + 1
                    while end < count, Self.isTokenByte(buffer, at: end, classes: classes) {
                        end += 1
                    }
                    check(buffer, start, end, classes: classes, first: first, into: &matches)
                    index = end
                }
            }
        }
        found.formUnion(matches)
    }
}
