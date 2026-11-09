//
//  BuilderMisuse.swift
//  WSwiftUI
//
//  Reporting for DSL misuse found while a page is built (for example a `Cell` outside any `Row`).
//  Misuse never terminates the process: it is logged once per endpoint type and guard site, marked in the
//  page with an HTML comment, and the page goes on rendering.
//

import Foundation

/// Remembers which misuse reports have already been logged, so a page that is rendered on every request
/// logs its mistake once instead of flooding the log. A key is the endpoint type plus the guard site
/// (`"MyPage|WSwiftUI/Table.swift:160"`, see `CoreWebEndpoint.misuseLogKey`), so the same mistake in a
/// second endpoint is logged too, and the set stays bounded by endpoint types x guard sites.
/// Thread-safe: pages render on many threads at once.
internal final class BuilderMisuseLog: @unchecked Sendable {

    static let shared = BuilderMisuseLog()

    private let lock = NSLock()
    private var reported: Set<String> = []

    /// Records `key` and returns `true` the first time it is seen, `false` afterwards.
    func markReported(_ key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return reported.insert(key).inserted
    }

    /// `true` once `key` has been recorded.
    func hasReported(_ key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return reported.contains(key)
    }

    /// Every key recorded so far.
    var reportedSites: Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return reported
    }
}

/// The marker left in a page where builder misuse was found:
/// `<template data-wsui-misuse><!-- WSwiftUI: message --></template>`.
///
/// The comment is wrapped in a `<template>` because a template is valid in every HTML context, including
/// directly inside `<table>`, `<tbody>`, `<tr>`, `<ul>` and `<select>`, so the marker never changes how the
/// browser builds the surrounding DOM; it renders nothing and runs no script.
internal final class WebBuilderMisuseElement: WebElement {

    let message: String
    /// The guard that reported it (`#fileID:#line`). Kept on the element for diagnostics and tests only; it
    /// is never rendered, so source paths don't reach the browser.
    let site: String

    init(message: String, site: String = "") {
        self.message = message
        self.site = site
        super.init()
        elementName = "template"
        addAttribute(.dontRegisterObject)
        addAttribute(.data("wsui-misuse"))
        addAttribute(.innerHTML("<!-- \(WebHTMLSyntax.commentText("WSwiftUI: \(message)")) -->"))
    }
}

internal extension CoreWebEndpoint {

    /// Reports DSL misuse without stopping the server: prints one `[WSwiftUI]` log line the first time this
    /// endpoint type reports from this guard site, and leaves an HTML comment at the current position in the
    /// page (see `WebBuilderMisuseElement`). The caller then carries on and renders the element where it was
    /// declared.
    ///
    /// - Parameters:
    ///   - message: what is wrong, e.g. "Cell must be used inside a Row { ... } block".
    ///   - file, line: the reporting guard; leave them defaulted.
    func misuse(_ message: String, file: StaticString = #fileID, line: UInt = #line) {
        let marker = misuseMarker(message, file: file, line: line)
        if let parent = stack.last ?? webRootElement {
            parent.subElements.append(marker)
        }
    }

    /// Logs a misuse like `misuse(_:file:line:)` and returns its marker without placing it, for checks that
    /// run after a container's content is built and put the marker in front of the offending child.
    func misuseMarker(_ message: String, file: StaticString = #fileID, line: UInt = #line) -> WebBuilderMisuseElement {
        let site = "\(file):\(line)"
        let endpoint = String(describing: type(of: self))
        if BuilderMisuseLog.shared.markReported(Self.misuseLogKey(endpoint: endpoint, site: site)) {
            WSwiftUIDiagnostics.log("[WSwiftUI] Builder misuse in \(endpoint): \(WSwiftUIDiagnostics.printable(message, limit: 300)). The element is rendered where it was declared and an HTML comment marks the spot; the request is not affected. (\(site), logged once for this endpoint)")
        }
        return WebBuilderMisuseElement(message: message, site: site)
    }

    /// The `BuilderMisuseLog` key of a report: the endpoint type and the guard site.
    static func misuseLogKey(endpoint: String, site: String) -> String {
        return "\(endpoint)|\(site)"
    }
}
