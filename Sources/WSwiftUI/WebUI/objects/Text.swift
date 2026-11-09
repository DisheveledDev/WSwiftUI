//
//  Text.swift
//  SWWebAppServer
//
//  Created by Adrian on 01/07/2025.
//

import Foundation

/// The entities `escapedForHTML` writes, one per `Character` (compared the way Swift compares
/// characters, i.e. canonically equivalent characters match too). Built once: it used to be built on
/// every call, a 60-entry dictionary for every `Text` and `Toggle` label.
private let htmlTextEscapeMap: [Character: String] = [
    // Basic XML
    "&":  "&amp;",
    "<":  "&lt;",
    ">":  "&gt;",
    "\"": "&quot;",
    "'":  "&#39;",
    "/":  "&#x2F;",
    
    // Whitespace
    " ":  "&nbsp;",    // non‑breaking space U+00A0
    "\t": "&#9;",      // tab
    "\r": "<br>",
    "\n": "<br>",     // line feed
    
    // Punctuation
    "¡": "&iexcl;",
    "¢": "&cent;",
    "£": "&pound;",
    "¤": "&curren;",
    "¥": "&yen;",
    "¦": "&brvbar;",
    "§": "&sect;",
    "¨": "&uml;",
    "©": "&copy;",
    "ª": "&ordf;",
    "«": "&laquo;",
    "¬": "&not;",
    "®": "&reg;",
    "¯": "&macr;",
    "°": "&deg;",
    "±": "&plusmn;",
    "²": "&sup2;",
    "³": "&sup3;",
    "´": "&acute;",
    "µ": "&micro;",
    "¶": "&para;",
    "·": "&middot;",
    "¸": "&cedil;",
    "¹": "&sup1;",
    "º": "&ordm;",
    "»": "&raquo;",
    "¼": "&frac14;",
    "½": "&frac12;",
    "¾": "&frac34;",
    "¿": "&iquest;",
    
    // Mathematical
    "×": "&times;",
    "÷": "&divide;",
    "‰": "&permil;",
    "−": "&minus;",    // U+2212 minus sign
    "–": "&ndash;",    // en dash
    "—": "&mdash;",    // em dash
    "•": "&bull;",     // bullet
    "…": "&hellip;",
    
    // Quotes
    "‘": "&lsquo;",
    "’": "&rsquo;",
    "‚": "&sbquo;",
    "“": "&ldquo;",
    "”": "&rdquo;",
    "„": "&bdquo;",
    
    // Single-angle quotes
    "‹": "&lsaquo;",
    "›": "&rsaquo;",
    
    // Greek (a few)
    "α": "&alpha;",
    "β": "&beta;",
    "γ": "&gamma;",
    "Δ": "&Delta;",
    "π": "&pi;",
    "φ": "&phi;",
    
    // Currency
    "€": "&euro;"
]

internal extension String {
    /// Escapes the string for display as text in HTML (`Text`, a `Toggle` label, a segmented `Picker` option).
    ///
    /// Each character in `htmlTextEscapeMap` becomes its entity: the markup characters `&`, `<`, `>`, `"`, `'`
    /// and `/`; a no-break space (U+00A0) `&nbsp;` (ordinary spaces are kept); a tab `&#9;`; a line feed or
    /// a carriage return `<br>`; and some punctuation, mathematical, Greek and currency characters their
    /// named entities. A character made of several Unicode scalars is escaped scalar by scalar with
    /// `WebEscape.html`.
    /// - Parameter preserveLineBreaks: also turn the line feed of a `\r\n` pair (a single character, which
    ///   the map doesn't match) into `<br>`. Single line feeds always become `<br>`.
    /// - Returns: A new `String` with HTML entities escaped.
    func escapedForHTML(preserveLineBreaks: Bool = true) -> String {
        var result = String()
        result.reserveCapacity(self.utf8.count)
        
        for c in self {
            if let entity = htmlTextEscapeMap[c] {
                result.append(entity)
            } else if c.unicodeScalars.count > 1 {
                // A multi-scalar grapheme cluster can carry a markup character that the per-Character map
                // above can't see (e.g. a Prepend mark such as U+0600 clusters with a following "<"), so
                // escape such clusters scalar by scalar.
                result.append(WebEscape.html(String(c)))
            } else {
                result.append(c)
            }
        }
        
        if preserveLineBreaks {
            return result.replacingOccurrences(of: "\n", with: "<br>")
        }
        return result
    }
}


public extension CoreWebEndpoint {
    
    // MARK: – Plain text
    @discardableResult
    func Text(_ text: String) -> WebElement {
        // inside a picker, the text is one of its options
        if let parent = parent as? WebPickerElement {
            switch parent.type {
            case .combo:
                // an <option> of the <select>
                let option = WebElement()
                option.title(text)
                parent.addAttribute(.item(option))
                return option

            case .radio:
                let value = parent.value
                
                let outer = create { element in
                    element.elementName = "div"
                    element.class("form-check")
                    switch parent.type {
                    case .radio(let alignment):
                        if alignment == .horizontal {
                            element.class("form-check-inline")
                        }
                    default:
                        break
                    }
                    element.class(parent.builderId)
                }
                
                // generate the input inside the form-check div
                return building(inside: outer) {
                    create { element in
                    
                        element.elementName = "input"
                        element.class("form-check-input")
                        element.type("radio")
                        element.id("\(element.builderId)")
                        if let bindingName = value?.internalName {
                            element.name(bindingName)
                        } else {
                            element.name(parent.builderId)
                        }
                        element.label(text)
                    
                        if let value {
                            element.addAttribute(.custom("onchange=\"if (this.checked) { updateWebVariable\(value.builderId)(this.value, { source: 'change', origin: '\(element.builderId)' }); }\""))
                            // register callbacks for updates to the bound variable
                            element.script("""
                                function updateVariable\(element.builderId)(value, _meta) {
                                    // (Optional) keep the attribute in sync for SSR/HTML snapshots
                                    if (value == \(element.builderId).value) {
                                        \(element.builderId).checked = true;
                                        \(element.builderId).setAttribute('checked', 'checked');
                                    } else {
                                        \(element.builderId).checked = false;
                                        \(element.builderId).removeAttribute('checked');
                                    }
                                }
                                addCallback\(value.builderId)(updateVariable\(element.builderId));
                            """)
                        }
                    
                    }
                }

            case .segmented:
                let value = parent.value
                
                return create { element in
                    
                    element.elementName = "button"
                    element.class("btn")
                    var thisVariant = ""
                    switch parent.type {
                    case .segmented(let variant):
                        thisVariant = variant.rawValue
                        element.class("btn-outline-\(thisVariant)")
                    default:
                        break
                    }
                    element.class(parent.builderId)
                    element.type("button")
                    
                    // set the text
                    element.innerHTML(text.escapedForHTML())
                    
                    if let value {
                        element.addAttribute(.custom("onclick=\"updateWebVariable\(value.builderId)(this.value, { source: 'click', origin: '\(element.builderId)' });\""))
                        // register callbacks for updates to the bound variable (the query takes buttons only: the
                        // group div carries the picker's builderId class too)
                        element.script("""
                            function updateVariable\(element.builderId)(value, _meta) {
                                // look through all of the buttons in this group and set them to 
                                var thisGroup = document.querySelectorAll('button.\(parent.builderId)');
                                thisGroup.forEach(function(btn) {
                                    if (btn.value == value) {
                                        btn.classList.remove('btn-outline-\(thisVariant)');
                                        btn.classList.add('btn-\(thisVariant)');
                                    } else {
                                        btn.classList.remove('btn-\(thisVariant)');
                                        btn.classList.add('btn-outline-\(thisVariant)');
                                    }
                                });
                            }
                            addCallback\(value.builderId)(updateVariable\(element.builderId));
                        """)
                    }
                }

            case .colorPicker:
                break
            }
        }
        
        // default (no picker)
        return withLayoutContainer {
            create { element in
                element.elementName  = "span"
                element.class("text")
                // we need to ensure that the text output is safe for HTML, so we escape it
                element.innerHTML(text.escapedForHTML())
                element.class("col")
            }
        }.built
    }
    
    
    // MARK: – WString binding
    @discardableResult
    func Text(_ binding: WebVariableElement) -> WebElement {
        return withLayoutContainer {
            create { element in
                element.elementName = "span"
                
                // initial value, escaped like Text(String); client-side updates below are written as text
                element.addAttribute(.innerHTML(binding.asString().escapedForHTML()))
                
                // register a callback for updates
                element.script("""
                    function updateVariable\(element.builderId)(value, _meta) {
                        \(element.builderId).innerText = value;
                    }
                    addCallback\(binding.builderId)(updateVariable\(element.builderId));
                """)
                
                element.class("col")
            }
        }.built
    }
    
    // MARK: – Formatted text with bound variables
    @discardableResult
    func Text(_ format: String, _ bindings: WebVariableElement...) -> WebElement {
        // Server-side initial render: replace $0, $1, ... with current bound values
        var initial = format
        for (idx, b) in bindings.enumerated() {
            initial = initial.replacingOccurrences(of: "$\(idx)", with: b.asString())
        }

        return withLayoutContainer {
            create { element in
                element.elementName  = "span"
                element.class("text")
                // Safe initial content for SSR/HTML snapshots
                element.innerHTML(initial.escapedForHTML())
                element.class("col")
                element.class("wsui-text")

                // Client-side dynamic updates: when any binding changes, re-render the formatted string
                // (written with textContent). The format is embedded as a script-safe string literal.
                let jsFormat = WebJSON.scriptString(format)
                var script = """
                (function(){
                    var fmt = \(jsFormat);
                    var values = [];
                    function render(){
                        try {
                            var out = fmt.replace(/\\$(\\d+)/g, function(_, idx){
                                var i = parseInt(idx, 10);
                                var v = values[i];
                                return (v == null) ? '' : String(v);
                            });
                            \(element.builderId).textContent = out;
                        } catch(e) {
                            // fail silently
                        }
                    }
                """

                // Register callbacks for each binding to update and re-render
                for (i, b) in bindings.enumerated() {
                    script += """
                        addCallback\(b.builderId)(function(value, _meta){ values[\(i)] = value; render(); });
                    """
                }

                script += """
                    // Note: initial content already SSR-rendered; dynamic rendering occurs on first update
                })();
                """

                element.script(script)
            }
        }.built
    }
    
}
