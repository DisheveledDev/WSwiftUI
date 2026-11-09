//
//  ScriptContextSupportTests.swift
//  WSwiftUITests
//
//  Shared helpers for the script-context slice tests: the hostile payload, static "no breakout"
//  checks on rendered HTML, and a Node.js harness that (1) syntax-checks every inline script as a
//  classic browser script and (2) runs compiled action code in a recording sandbox so the values the
//  code actually passes to the DOM/BOM can be compared with the Swift values.
//

import Foundation
import Testing
@testable import WSwiftUI

// MARK: - Hostile input

enum Hostile {
    /// U+2028 / U+2029, built from scalars so the source file never contains them (or an escape for them).
    static let lineSeparator = String(Character(Unicode.Scalar(0x2028)!))
    static let paragraphSeparator = String(Character(Unicode.Scalar(0x2029)!))

    /// Every character class that has broken out of a script context: `</script>` (also upper-case with
    /// a space, and with a `/`, both of which an HTML parser accepts as the end tag), both quote kinds, a
    /// backtick + `${…}` (template literal injection), line/paragraph separators, newline, tab, backslash and
    /// an HTML comment opener. It deliberately contains no `.`, `?` or `#` so it can be used as a JSON key
    /// path and as a URL without being split.
    static let payload = "</script><script>alert(1)</script> </SCRIPT >x</script/x O'Brien \"quoted\" `tick` ${alert(1)} "
        + lineSeparator + paragraphSeparator + " line1\nline2\ttab back\\slash <!-- x -->"

    /// Substrings that must never appear anywhere in rendered HTML: each is only present if the payload
    /// was written out unescaped (HTML escaping and script-literal encoding both remove them).
    /// Matched case-insensitively.
    static let rawHTMLMarkers = ["<script>alert(1)", "</script >x", "</script/x", "O'Brien", "\"quoted\""]

    /// Substrings that must never appear inside an inline script body. Matched case-insensitively.
    static let rawScriptMarkers = ["</script", "<script>alert", "<!--", "O'Brien", "\"quoted\"", "`", "back\\slash",
                                   lineSeparator, paragraphSeparator]

    /// A JSON string literal for `value`, produced independently of the code under test.
    static func jsonLiteral(_ value: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [value], options: [])
        let array = String(decoding: data, as: UTF8.self)
        return String(array.dropFirst().dropLast())
    }
}

// MARK: - Static HTML checks

enum ScriptScan {

    /// A script start tag as an HTML parser recognises it: `<script` (any case) followed by whitespace,
    /// `/` or `>`.
    static let openerPattern = "<script[\\t\\n\\f\\r />]"
    /// A script end tag as an HTML parser recognises it inside script data: `</script` (any case)
    /// followed by whitespace, `/` or `>` (so `</SCRIPT >` and `</script/` close the element too).
    static let closerPattern = "</script[\\t\\n\\f\\r />]"

    /// Bodies of all inline `<script>` elements (scripts with a `src` and empty bodies are skipped),
    /// split the way an HTML parser splits them: at the first end tag, in any letter case.
    static func inlineScripts(in html: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: "<script(\\s[^>]*)?>([\\s\\S]*?)\(closerPattern)",
                                             options: [.caseInsensitive])
        let ns = html as NSString
        return regex.matches(in: html, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            let body = ns.substring(with: match.range(at: 2))
            return body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : body
        }
    }

    static func occurrences(of needle: String, in haystack: String) -> Int {
        return haystack.components(separatedBy: needle).count - 1
    }

    /// Case-insensitive count of the matches of a regular expression.
    static func matches(of pattern: String, in haystack: String) -> Int {
        let regex = try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        return regex.numberOfMatches(in: haystack, range: NSRange(location: 0, length: (haystack as NSString).length))
    }

    /// Script start tags in `html` (any letter case).
    static func scriptOpeners(in html: String) -> Int { matches(of: openerPattern, in: html) }

    /// Script end tags in `html` (any letter case, `>`, whitespace or `/` after the name).
    static func scriptClosers(in html: String) -> Int { matches(of: closerPattern, in: html) }

    static func containsIgnoringCase(_ haystack: String, _ needle: String) -> Bool {
        return haystack.range(of: needle, options: [.caseInsensitive]) != nil
    }

    /// Records an issue for every sign that the payload escaped its context.
    static func expectNoBreakout(_ html: String, sourceLocation: SourceLocation = #_sourceLocation) {
        let openers = scriptOpeners(in: html)
        let closers = scriptClosers(in: html)
        #expect(openers == closers, "unbalanced <script> elements: \(openers) openers vs \(closers) closers", sourceLocation: sourceLocation)
        for marker in Hostile.rawHTMLMarkers {
            #expect(containsIgnoringCase(html, marker) == false, "raw payload fragment \(marker.debugDescription) in HTML", sourceLocation: sourceLocation)
        }
        for (index, body) in inlineScripts(in: html).enumerated() {
            for marker in Hostile.rawScriptMarkers where containsIgnoringCase(body, marker) {
                Issue.record("script #\(index) contains raw \(marker.debugDescription): \(body.prefix(400))", sourceLocation: sourceLocation)
            }
        }
    }

    /// Same as `expectNoBreakout` for a bare JavaScript string (e.g. `CompileActions` output).
    static func expectScriptSafe(_ js: String, sourceLocation: SourceLocation = #_sourceLocation) {
        for marker in Hostile.rawScriptMarkers where containsIgnoringCase(js, marker) {
            Issue.record("generated JS contains raw \(marker.debugDescription): \(js.prefix(400))", sourceLocation: sourceLocation)
        }
    }
}

// MARK: - Node.js harness

enum NodeJS {

    static let path: String? = {
        let candidates = ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    static var isAvailable: Bool { path != nil }

    /// Result of one harness run.
    struct Result {
        var syntaxErrors: [String] = []
        /// Everything the sandboxed code did to the DOM/BOM stubs: `{op, path, args|value}` records.
        var records: [Any] = []
        var error: String? = nil
        /// name -> {type, json, str} for evaluated literals.
        var values: [String: [String: Any]] = [:]

        /// Every string observed in the records (argument values, assigned values, JSON object keys and
        /// values; strings that hold JSON containers are decoded and searched too).
        var observedStrings: Set<String> {
            var strings = Set<String>()
            var keys = Set<String>()
            NodeJS.collect(records, strings: &strings, keys: &keys)
            return strings
        }

        var observedKeys: Set<String> {
            var strings = Set<String>()
            var keys = Set<String>()
            NodeJS.collect(records, strings: &strings, keys: &keys)
            return keys
        }
    }

    fileprivate static func collect(_ value: Any, strings: inout Set<String>, keys: inout Set<String>) {
        switch value {
        case let s as String:
            strings.insert(s)
            if let first = s.first, first == "{" || first == "[",
               let obj = try? JSONSerialization.jsonObject(with: Data(s.utf8), options: []) {
                collect(obj, strings: &strings, keys: &keys)
            }
        case let array as [Any]:
            for item in array { collect(item, strings: &strings, keys: &keys) }
        case let dict as [String: Any]:
            for (k, v) in dict {
                keys.insert(k)
                collect(v, strings: &strings, keys: &keys)
            }
        default:
            break
        }
    }

    /// Runs the harness.
    /// - Parameters:
    ///   - scripts: script bodies to syntax-check as classic scripts (`vm.Script`, i.e. what a browser
    ///     `<script>` parses; stricter than `node --check`, which wraps files in a CommonJS function).
    ///   - literals: name -> JS expression, evaluated and reported in `values`.
    ///   - code: JS to execute inside the recording sandbox (every unknown global is a recording proxy).
    ///   - globals: name -> JS expression preloaded as a sandbox global before `code` runs. The expression
    ///     can call `__deep(path)` to create a recording proxy.
    ///   - after: JS run in the same sandbox after `code` (e.g. to fire a registered handler).
    static func run(scripts: [String] = [],
                    literals: [String: String] = [:],
                    code: String? = nil,
                    globals: [String: String] = [:],
                    after: String? = nil) throws -> Result {
        guard let node = path else { throw HarnessError.nodeMissing }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wsui-script-context-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let driverURL = dir.appendingPathComponent("driver.js")
        try Data(driverSource.utf8).write(to: driverURL)

        var input: [String: Any] = ["scripts": scripts, "literals": literals, "globals": globals]
        if let code { input["code"] = code }
        if let after { input["after"] = after }
        let inputURL = dir.appendingPathComponent("input.json")
        try JSONSerialization.data(withJSONObject: input, options: []).write(to: inputURL)

        let outputURL = dir.appendingPathComponent("output.json")
        let errorURL = dir.appendingPathComponent("stderr.txt")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        FileManager.default.createFile(atPath: errorURL.path, contents: nil)
        let outHandle = try FileHandle(forWritingTo: outputURL)
        let errHandle = try FileHandle(forWritingTo: errorURL)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: node)
        process.arguments = [driverURL.path, inputURL.path]
        process.standardOutput = outHandle
        process.standardError = errHandle
        try process.run()
        process.waitUntilExit()
        try? outHandle.close()
        try? errHandle.close()

        let outData = try Data(contentsOf: outputURL)
        guard let json = try JSONSerialization.jsonObject(with: outData, options: []) as? [String: Any] else {
            let stderr = (try? String(contentsOf: errorURL, encoding: .utf8)) ?? ""
            throw HarnessError.badOutput(String(decoding: outData, as: UTF8.self) + "\n" + stderr)
        }
        var result = Result()
        result.syntaxErrors = (json["syntaxErrors"] as? [String]) ?? []
        result.records = (json["records"] as? [Any]) ?? []
        result.error = json["error"] as? String
        result.values = (json["values"] as? [String: [String: Any]]) ?? [:]
        return result
    }

    /// Runs the real `node --check` on every script (one file each, in parallel via xargs).
    /// Returns node's diagnostics for the scripts that failed (empty when all pass).
    static func nodeCheck(_ scripts: [String]) throws -> String {
        guard let node = path else { throw HarnessError.nodeMissing }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wsui-node-check-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        var list = Data()
        for (index, body) in scripts.enumerated() {
            let url = dir.appendingPathComponent("script\(index).js")
            try Data(body.utf8).write(to: url)
            list.append(Data(url.path.utf8))
            list.append(0)
        }
        let listURL = dir.appendingPathComponent("files.list")
        try list.write(to: listURL)
        let errorURL = dir.appendingPathComponent("stderr.txt")
        FileManager.default.createFile(atPath: errorURL.path, contents: nil)
        let errHandle = try FileHandle(forWritingTo: errorURL)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xargs")
        process.arguments = ["-0", "-n", "1", "-P", "8", node, "--check"]
        process.standardInput = try FileHandle(forReadingFrom: listURL)
        process.standardOutput = errHandle
        process.standardError = errHandle
        try process.run()
        process.waitUntilExit()
        try? errHandle.close()
        let diagnostics = (try? String(contentsOf: errorURL, encoding: .utf8)) ?? ""
        if process.terminationStatus != 0 && diagnostics.isEmpty {
            return "xargs/node exited with status \(process.terminationStatus)"
        }
        return process.terminationStatus == 0 ? "" : diagnostics
    }

    /// Runs `code` as a node script with *real* timers for `waitMs`, with `window.alert` stubbed as a
    /// counter, and reports how often it was called and what node wrote to stderr (e.g. a
    /// `TimeoutOverflowWarning` for a delay above 2^31 - 1 ms).
    static func alertsWithRealTimers(_ code: String, waitMs: Int) throws -> (alerts: Int, stderr: String) {
        guard let node = path else { throw HarnessError.nodeMissing }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wsui-timers-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let script = """
        var __alerts = 0;
        var window = { alert: function () { __alerts++; } };
        setTimeout(function () { process.stdout.write(String(__alerts)); process.exit(0); }, \(waitMs));
        \(code)
        """
        let scriptURL = dir.appendingPathComponent("timers.js")
        try Data(script.utf8).write(to: scriptURL)
        let outputURL = dir.appendingPathComponent("stdout.txt")
        let errorURL = dir.appendingPathComponent("stderr.txt")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        FileManager.default.createFile(atPath: errorURL.path, contents: nil)
        let outHandle = try FileHandle(forWritingTo: outputURL)
        let errHandle = try FileHandle(forWritingTo: errorURL)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: node)
        process.arguments = [scriptURL.path]
        process.standardOutput = outHandle
        process.standardError = errHandle
        try process.run()
        process.waitUntilExit()
        try? outHandle.close()
        try? errHandle.close()

        let stdout = (try? String(contentsOf: outputURL, encoding: .utf8)) ?? ""
        let stderr = (try? String(contentsOf: errorURL, encoding: .utf8)) ?? ""
        guard let alerts = Int(stdout.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw HarnessError.badOutput(stdout + "\n" + stderr)
        }
        return (alerts, stderr)
    }

    enum HarnessError: Error {
        case nodeMissing
        case badOutput(String)
    }

    /// The Node.js side of the harness. Written as a raw string so no escape sequence is interpreted by Swift.
    static let driverSource = #"""
    'use strict';
    const fs = require('fs');
    const vm = require('vm');
    const input = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
    const out = { syntaxErrors: [], records: [], error: null, values: {} };

    (input.scripts || []).forEach(function (code, i) {
      try { new vm.Script(code, { filename: 'inline-script-' + i + '.js' }); }
      catch (e) { out.syntaxErrors.push('script #' + i + ': ' + e.message + '\n' + code.slice(0, 400)); }
    });

    Object.keys(input.literals || {}).forEach(function (name) {
      try {
        const v = new Function('return (' + input.literals[name] + ');')();
        out.values[name] = { type: Array.isArray(v) ? 'array' : typeof v, json: JSON.stringify(v), str: String(v) };
      } catch (e) {
        out.values[name] = { error: String(e) };
      }
    });

    function plain(v) {
      if (typeof v === 'function') return '[fn]';
      if (v === undefined) return null;
      try { return JSON.parse(JSON.stringify(v)); } catch (e) { return String(v); }
    }

    function deep(path) {
      const target = function () {};
      return new Proxy(target, {
        get: function (t, prop) {
          if (prop === Symbol.toPrimitive) return function () { return '[' + path + ']'; };
          if (typeof prop === 'symbol') return undefined;
          return deep(path + '.' + prop);
        },
        set: function (t, prop, value) {
          out.records.push({ op: 'set', path: path + '.' + String(prop), value: plain(value) });
          return true;
        },
        apply: function (t, thisArg, args) {
          out.records.push({ op: 'call', path: path, args: args.map(plain) });
          return deep(path + '()');
        },
        construct: function (t, args) {
          out.records.push({ op: 'new', path: path, args: args.map(plain) });
          return deep('new ' + path);
        }
      });
    }

    if (typeof input.code === 'string') {
      const builtins = {
        JSON: JSON, Math: Math, String: String, Number: Number, Boolean: Boolean, Array: Array, Object: Object,
        RegExp: RegExp, Date: Date, Error: Error, Symbol: Symbol, Promise: Promise, parseInt: parseInt,
        parseFloat: parseFloat, isNaN: isNaN, isFinite: isFinite, encodeURIComponent: encodeURIComponent,
        decodeURIComponent: decodeURIComponent, undefined: undefined, NaN: NaN, Infinity: Infinity
      };
      const vars = {};
      const scope = new Proxy({}, {
        has: function (t, prop) { return typeof prop === 'string'; },
        get: function (t, prop) {
          if (typeof prop === 'symbol') return undefined;
          if (Object.prototype.hasOwnProperty.call(vars, prop)) return vars[prop];
          if (prop === 'setTimeout') return function (fn) { if (typeof fn === 'function') fn(); return 0; };
          if (Object.prototype.hasOwnProperty.call(builtins, prop)) return builtins[prop];
          return deep(prop);
        },
        set: function (t, prop, value) { vars[prop] = value; return true; }
      });
      try {
        Object.keys(input.globals || {}).forEach(function (name) {
          vars[name] = new Function('__deep', 'return (' + input.globals[name] + ');')(deep);
        });
        new Function('__scope', 'with (__scope) {\n' + input.code + '\n}')(scope);
        if (typeof input.after === 'string') {
          new Function('__scope', 'with (__scope) {\n' + input.after + '\n}')(scope);
        }
      } catch (e) {
        out.error = String(e && e.stack || e);
      }
    }

    process.stdout.write(JSON.stringify(out));
    """#
}

// MARK: - Self-tests for the harness

@Suite("Script context harness")
struct ScriptContextHarnessTests {

    @Test func payloadHasEveryDangerousClass() {
        let p = Hostile.payload
        for needle in ["</script>", "</SCRIPT >", "</script/", "'", "\"", "`", "${", "\n", "\t", "\\", "<!--",
                       Hostile.lineSeparator, Hostile.paragraphSeparator] {
            #expect(p.contains(needle), "payload lacks \(needle.debugDescription)")
        }
        for forbidden in [".", "?", "#"] {
            #expect(p.contains(forbidden) == false)
        }
        // the raw payload itself is detected as a breakout: 1 opener vs 4 closers
        #expect(ScriptScan.scriptOpeners(in: p) == 1)
        #expect(ScriptScan.scriptClosers(in: p) == 4)
    }

    @Test func scanSplitsScriptsLikeAnHTMLParser() {
        let html = "<script>var a = 1;</script><script src=\"x.js\"></script><script>var b = '</script><p>';</script>"
            + "<SCRIPT type=\"text/javascript\">var c = 1;</SCRIPT ><script>var d = '</Script/x';</script>"
            + "<script>var e = '</scripts>';</script>"
        let scripts = ScriptScan.inlineScripts(in: html)
        #expect(scripts == ["var a = 1;", "var b = '", "var c = 1;", "var d = '", "var e = '</scripts>';"])
        #expect(ScriptScan.scriptOpeners(in: html) == 6)
        // `</scripts>` is not an end tag; the stray `</script>` after `<p>` and the one after `x'` are
        #expect(ScriptScan.scriptClosers(in: html) == 8)
    }

    @Test(.enabled(if: NodeJS.isAvailable))
    func harnessDetectsBrokenScriptsAndRecordsEffects() throws {
        let result = try NodeJS.run(scripts: ["var ok = 1;", "var broken = 'O'Brien';"],
                                    literals: ["s": Hostile.jsonLiteral(Hostile.payload)],
                                    code: "window.alert(x); document.getElementById('a').textContent = 'b';",
                                    globals: ["x": Hostile.jsonLiteral(Hostile.payload)])
        #expect(result.syntaxErrors.count == 1)
        #expect(result.error == nil)
        #expect(result.observedStrings.contains(Hostile.payload))
        #expect(result.observedStrings.contains("b"))
        #expect((result.values["s"]?["str"] as? String) == Hostile.payload)
    }

    @Test(.enabled(if: NodeJS.isAvailable))
    func nodeCheckReportsSyntaxErrors() throws {
        #expect(try NodeJS.nodeCheck(["var a = 1;", "var b = \"x\";"]).isEmpty)
        #expect(try NodeJS.nodeCheck(["var a = 1;", "var b = 'O'Brien';"]).isEmpty == false)
    }
}
