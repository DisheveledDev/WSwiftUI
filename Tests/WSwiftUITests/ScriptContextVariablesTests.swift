//
//  ScriptContextVariablesTests.swift
//  WSwiftUITests
//
//  C2: values bound to variables are written into <script> as script-safe literals; liveUpdate
//  descriptors are encoded; DATA-15: non-string bindings render their value server-side.
//

import Foundation
import Testing
@testable import WSwiftUI

private let H = Hostile.payload

/// Records from the sandbox whose path matches.
func sandboxRecords(_ result: NodeJS.Result, path: String) -> [[String: Any]] {
    return result.records.compactMap { $0 as? [String: Any] }.filter { ($0["path"] as? String) == path }
}

@Suite("Script context: variables")
struct ScriptContextVariablesTests {

    @Test func variableDefinitionsAreScriptSafe() throws {
        var definitions: [String: (id: String, literal: String)] = [:]
        let html = renderHTML { page in
            let variables: [(String, WebVariableElement)] = [
                ("string", page.WString(H).name(H)),
                ("array", page.WArray([H, "x"]).name(H)),
                ("int", page.WInt(42).name(H)),
                ("double", page.WDouble(1.5)),
                ("nan", page.WDouble(.nan)),
                ("inf", page.WDouble(.infinity)),
                ("ninf", page.WDouble(-.infinity)),
                ("bool", page.WBool(true)),
            ]
            for (key, variable) in variables {
                variable.onValueChanged([.alert(H)])
                definitions[key] = (variable.builderId, variable.asJSValue())
            }
        }
        ScriptScan.expectNoBreakout(html)
        for (key, definition) in definitions {
            #expect(html.contains("var \(definition.id) = \(definition.literal);"), "\(key): definition not rendered")
        }

        guard NodeJS.isAvailable else { return }
        let result = try NodeJS.run(scripts: ScriptScan.inlineScripts(in: html),
                                    literals: definitions.mapValues { $0.literal })
        #expect(result.syntaxErrors.isEmpty, "\(result.syntaxErrors.joined(separator: "\n"))")

        func value(_ key: String) -> (type: String?, str: String?, json: String?) {
            let v = result.values[key]
            return (v?["type"] as? String, v?["str"] as? String, v?["json"] as? String)
        }
        #expect(value("string").type == "string")
        #expect(value("string").str == H)
        let arrayJSON = try #require(value("array").json)
        #expect(try JSONDecoder().decode([String].self, from: Data(arrayJSON.utf8)) == [H, "x"])
        #expect(value("int").type == "number" && value("int").str == "42")
        #expect(value("double").type == "number" && value("double").str == "1.5")
        #expect(value("nan").type == "number" && value("nan").str == "NaN")
        #expect(value("inf").type == "number" && value("inf").str == "Infinity")
        #expect(value("ninf").type == "number" && value("ninf").str == "-Infinity")
        #expect(value("bool").type == "boolean" && value("bool").str == "true")
    }

    /// Reflected input (AppGrill's /2fa?code=… pattern) can't close the script element.
    @Test func requestDataSeededVariableCannotBreakOut() {
        let html = renderHTML(uri: "/test?code=%3C%2Fscript%3E%3Cscript%3Ealert(document.domain)%3C%2Fscript%3E") { page in
            _ = page.WString(page.data.string("code") ?? "").name("code")
        }
        #expect(html.contains("alert(document.domain)"), "the request value should be rendered (encoded)")
        #expect(html.contains("<script>alert(document.domain)") == false)
        #expect(ScriptScan.scriptOpeners(in: html) == ScriptScan.scriptClosers(in: html))
    }

    /// The same with an upper-case / slash-terminated end tag, which an HTML parser also honours.
    @Test func requestDataSeededVariableCannotBreakOutWithEndTagVariants() {
        let html = renderHTML(uri: "/test?code=%3C%2FSCRIPT%20%3E%3CScRiPt%3Ealert(1)%3C%2Fscript%2F%3E") { page in
            _ = page.WString(page.data.string("code") ?? "").name("code")
        }
        #expect(html.contains("alert(1)"), "the request value should be rendered (encoded)")
        #expect(ScriptScan.containsIgnoringCase(html, "</script >") == false)
        #expect(ScriptScan.containsIgnoringCase(html, "<script>alert") == false)
        #expect(ScriptScan.scriptOpeners(in: html) == ScriptScan.scriptClosers(in: html))
        ScriptScan.expectNoBreakout(html)
    }

    /// Ordinary values keep their JS meaning (strings switch from '…' to "…" quoting).
    @Test func ordinaryLiteralsKeepTheirMeaning() {
        var literals: [String] = []
        _ = renderHTML { page in
            literals = [
                page.WString("Hello world").asJSValue(),
                page.WArray(["a", "b"]).asJSValue(),
                page.WArray([]).asJSValue(),
                page.WInt(42).asJSValue(),
                page.WDouble(1.5).asJSValue(),
                page.WDouble(3).asJSValue(),
                page.WBool(false).asJSValue(),
            ]
        }
        #expect(literals == ["\"Hello world\"", "[\"a\",\"b\"]", "[]", "42", "1.5", "3.0", "false"])
    }

    @Test(.enabled(if: NodeJS.isAvailable))
    func liveUpdateEncodesNamesReferenceAndURL() throws {
        let variable = WebVariableElement()
        variable.builderId = "lv"
        variable.variableType = .string
        variable.internalName = H
        let related = WebVariableElement()
        related.builderId = "lr"
        related.variableType = .int
        related.internalName = H + "2"
        variable.liveUpdate(url: H, reference: H + "ref", actions: [.read, .write], related: [related],
                            onRequest: [.text(ref: H, H)], pollEverySeconds: 5)
        let scripts = variable.attributes.compactMap { attribute -> String? in
            if case .script(let js) = attribute { return js }
            return nil
        }
        let script = try #require(scripts.last)
        ScriptScan.expectScriptSafe(script)

        let result = try NodeJS.run(scripts: [script],
                                    code: script,
                                    globals: ["window": "{ lv: 'v1', lr: 7 }"],
                                    after: "window['liveSync_lv']();")
        #expect(result.syntaxErrors.isEmpty, "\(result.syntaxErrors.joined(separator: "\n"))")
        #expect(result.error == nil, "\(result.error ?? "")")
        #expect(result.observedStrings.contains(H), "onRequest action did not receive the value")

        let fetches = sandboxRecords(result, path: "fetch")
        #expect(fetches.count == 1)
        let args = try #require(fetches.first?["args"] as? [Any])
        #expect(args.first as? String == H)
        let options = try #require(args.dropFirst().first as? [String: Any])
        let body = try #require(options["body"] as? String)
        let payload = try #require(try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
        #expect(payload["reference"] as? String == H + "ref")
        let data = try #require(payload["data"] as? [String: Any])
        #expect(data[H] as? String == "v1")
        #expect(data[H + "2"].map { "\($0)" } == "7")
    }

    /// DATA-15: Int/Double/Bool bindings render their value server-side instead of an empty string.
    @Test func nonStringBindingsRenderTheirValue() {
        var strings: [String] = []
        let html = renderHTML { page in
            let quantity = page.WInt(42).name("qty")
            page.TextField(binding: quantity, type: .number)
            strings = [
                page.WInt(42).asString(),
                page.WDouble(3).asString(),
                page.WDouble(2.5).asString(),
                page.WDouble(.nan).asString(),
                page.WBool(true).asString(),
                page.WBool(false).asString(),
                page.WString("plain").asString(),
                page.WArray(["a"]).asString(),
            ]
        }
        #expect(strings == ["42", "3", "2.5", "NaN", "true", "false", "plain", ""])
        #expect(html.contains("value=\"42\""))
    }

    /// DATA-15 follow-up: a WDouble renders server-side exactly the text the client's sync later writes
    /// (JS `String(number)`), so the value does not visibly change on load. The expected strings are what
    /// node prints; `numberTextMatchesNode` cross-checks the formatter itself against node.
    @Test func doubleBindingsRenderLikeJavaScriptString() throws {
        let cases: [(Double, String)] = [
            (0.00001, "0.00001"), (1e16, "10000000000000000"), (1e15, "1000000000000000"),
            (123456789012.5, "123456789012.5"), (1e21, "1e+21"), (1e-7, "1e-7"), (-0.0, "0"), (3, "3"),
        ]
        var rendered: [String] = []
        var literals: [String: String] = [:]
        let html = renderHTML { page in
            for (index, (value, _)) in cases.enumerated() {
                let variable = page.WDouble(value).name("d\(index)")
                page.TextField(binding: variable, type: .number)
                rendered.append(variable.asString())
                literals["d\(index)"] = "String(\(variable.asJSValue()))"
            }
        }
        #expect(rendered == cases.map { $0.1 })
        for (_, text) in cases {
            #expect(html.contains("value=\"\(text)\""), "TextField should render value=\"\(text)\"")
        }
        guard NodeJS.isAvailable else { return }
        let result = try NodeJS.run(literals: literals)
        for (index, (_, text)) in cases.enumerated() {
            #expect(result.values["d\(index)"]?["str"] as? String == text, "client String() of d\(index)")
        }
    }
}
