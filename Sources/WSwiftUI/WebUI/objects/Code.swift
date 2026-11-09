//
//  Code.swift
//  WSwiftUI
//
//  Created by Adrian on 25/07/2025.
//

import Foundation

internal extension String {
    /// Escapes the string for display inside `<pre><code>`, so it shows *literally* (a `<b>` in a code
    /// sample is displayed as `<b>`, not rendered as bold).
    ///
    /// Only `&`, `<`, `>`, `"` and `'` are replaced with entities. Spaces, tabs and line breaks are left as they
    /// are: `<pre>` preserves them, and keeping real spaces means copied code (e.g. a shell command) still works.
    func escapedForCode() -> String {
        return WebEscape.html(self)
    }
}

public enum CodeLanguage: String, CaseIterable {
    case swift = "swift"
    case javascript = "javascript"
    case python = "python"
    case html = "html"
    case css = "css"
    case xml = "xml"
    case json = "json"
    case sql = "sql"
    case bash = "bash"
    case csharp = "csharp"
    case java = "java"
    case kotlin = "kotlin"
}

public extension CoreWebEndpoint {
    
    // MARK: – Plain text
    @discardableResult
    func Code(language: CodeLanguage, _ text: String) -> WebElement {
        var result: WebElement?

        WrapInLayoutContainer {
            result = create { element in
                element.elementName  = "pre"
                element.class("wsui-code")
                // the code is shown literally: escape it exactly once
                element.innerHTML("<code class = \"language-\(language.rawValue)\">\(text.escapedForCode())</code>")
            }
        }
        
        return result!
        
    }
    
}
