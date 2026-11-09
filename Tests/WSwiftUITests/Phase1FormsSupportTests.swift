//
//  Phase1FormsSupportTests.swift
//  WSwiftUITests
//
//  Helpers for the Phase 1 forms slice (H10 / H11 / H12):
//   - `FormsHTML` reads a rendered page the way a browser builds a form submission (first `name`
//     attribute wins, unchecked checkboxes are skipped, entities are decoded) and encodes the result as
//     multipart/form-data;
//   - `FormsBrowser` runs every inline script of a rendered page in order inside a Node.js `vm` context
//     that behaves like a browser window (global `var`s are `window` properties, each script and each
//     DOMContentLoaded listener fails on its own), with a fake DOM, a scripted `fetch` and a manual clock.
//

import Foundation
import Testing
@testable import WSwiftUI

// MARK: - Reading forms from rendered HTML

enum FormsHTML {

    struct Tag {
        var name: String
        /// Attributes in source order; a repeated attribute is kept (an HTML parser keeps only the first).
        var attributes: [(String, String?)]
        /// Inner text of a <textarea>, or the raw inner HTML of a <select>.
        var inner: String?

        /// The value an HTML parser sees: the first occurrence of the attribute.
        func attribute(_ key: String) -> String? {
            guard let match = attributes.first(where: { $0.0.lowercased() == key }) else { return nil }
            return FormsHTML.decode(match.1 ?? "")
        }

        func has(_ key: String) -> Bool { attributes.contains { $0.0.lowercased() == key } }

        /// Every value of a (possibly repeated) attribute, decoded.
        func all(_ key: String) -> [String] {
            attributes.filter { $0.0.lowercased() == key }.map { FormsHTML.decode($0.1 ?? "") }
        }
    }

    static func decode(_ s: String) -> String {
        guard s.contains("&") else { return s }
        return s.replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    static func attributes(in raw: String) -> [(String, String?)] {
        let regex = try! NSRegularExpression(pattern: "([^\\s=/>\"]+)(?:\\s*=\\s*\"([^\"]*)\")?")
        let ns = raw as NSString
        return regex.matches(in: raw, range: NSRange(location: 0, length: ns.length)).map { match in
            let key = ns.substring(with: match.range(at: 1))
            let value = match.range(at: 2).location == NSNotFound ? nil : ns.substring(with: match.range(at: 2))
            return (key, value)
        }
    }

    /// `<input>`, `<select>` and `<textarea>` tags in document order.
    static func controls(in html: String) -> [Tag] {
        let regex = try! NSRegularExpression(
            pattern: "<input\\b([^>]*)>|<(select|textarea)\\b([^>]*)>([\\s\\S]*?)</\\2>",
            options: [.caseInsensitive])
        let ns = html as NSString
        return regex.matches(in: html, range: NSRange(location: 0, length: ns.length)).map { match in
            if match.range(at: 1).location != NSNotFound {
                return Tag(name: "input", attributes: attributes(in: ns.substring(with: match.range(at: 1))), inner: nil)
            }
            return Tag(name: ns.substring(with: match.range(at: 2)).lowercased(),
                       attributes: attributes(in: ns.substring(with: match.range(at: 3))),
                       inner: ns.substring(with: match.range(at: 4)))
        }
    }

    /// The part of `html` inside the first <form>…</form>.
    static func firstForm(in html: String) -> String {
        guard let start = html.range(of: "<form"),
              let end = html.range(of: "</form>", range: start.upperBound..<html.endIndex) else { return "" }
        return String(html[start.lowerBound..<end.upperBound])
    }

    /// The fields a browser submits for the controls in `html` (no scripts run): the first `name`
    /// attribute names the field, unchecked checkboxes / radios and disabled controls are skipped, a
    /// `<select>` submits its selected (or first) option.
    static func submission(of html: String) -> [(String, String)] {
        var fields: [(String, String)] = []
        for control in controls(in: html) {
            guard let name = control.attribute("name"), name.isEmpty == false, control.has("disabled") == false else { continue }
            switch control.name {
            case "input":
                let type = (control.attribute("type") ?? "text").lowercased()
                if type == "checkbox" || type == "radio" {
                    if control.has("checked") { fields.append((name, control.attribute("value") ?? "on")) }
                } else {
                    fields.append((name, control.attribute("value") ?? ""))
                }
            case "textarea":
                fields.append((name, decode(control.inner ?? "")))
            case "select":
                let options = optionTags(in: control.inner ?? "")
                if let chosen = options.first(where: { $0.has("selected") }) ?? options.first {
                    fields.append((name, chosen.attribute("value") ?? ""))
                }
            default:
                break
            }
        }
        return fields
    }

    static func optionTags(in html: String) -> [Tag] {
        let regex = try! NSRegularExpression(pattern: "<option\\b([^>]*)>", options: [.caseInsensitive])
        let ns = html as NSString
        return regex.matches(in: html, range: NSRange(location: 0, length: ns.length)).map {
            Tag(name: "option", attributes: attributes(in: ns.substring(with: $0.range(at: 1))), inner: nil)
        }
    }

    /// The hidden carrier input of a variable.
    static func carrier(_ html: String, id builderId: String) -> Tag? {
        controls(in: html).first { $0.attribute("id") == "hiddenInput_\(builderId)" }
    }

    /// The control whose class list contains `builderId`.
    static func control(_ html: String, builderId: String) -> Tag? {
        controls(in: html).first { ($0.attribute("class") ?? "").split(separator: " ").contains(Substring(builderId)) }
    }

    static let boundary = "----wsuiPhase1FormsBoundary7MA4YWxk"

    static func multipart(_ fields: [(String, String)]) -> (contentType: String, body: Data) {
        var body = ""
        for (name, value) in fields {
            body += "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n"
        }
        body += "--\(boundary)--\r\n"
        return ("multipart/form-data; boundary=\(boundary)", Data(body.utf8))
    }

    static func post(_ server: WSwiftServer, _ uri: String, _ fields: [(String, String)]) -> HttpResponse {
        let encoded = multipart(fields)
        return server.respond(to: TestHTTP.request(.POST, uri, headers: [("Content-Type", encoded.contentType)], body: encoded.body))
    }

    static func get(_ server: WSwiftServer, _ uri: String) -> HttpResponse {
        return server.respond(to: TestHTTP.request(.GET, uri))
    }
}

// MARK: - Running a rendered page in a browser-like Node.js context

enum FormsBrowser {

    struct Outcome {
        /// Script and listener errors, in the order they happened.
        var errors: [String]
        var warnings: [String]
        /// Whatever the scenario returned.
        var result: [String: Any]
    }

    /// Runs the inline scripts of `html` in order, then `scenario`: the body of an async function that
    /// receives `h` (`win`, `fireDOMContentLoaded()`, `advance(ms)`, `settle()`, `fetches`, `respond(i, json,
    /// status)`, `respondText(i, text, status)`, `el(key)`, `errors`) and returns a JSON-serialisable object.
    static func run(html: String, scenario: String) throws -> Outcome {
        guard let node = NodeJS.path else { throw NodeJS.HarnessError.nodeMissing }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wsui-phase1-forms-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let driverURL = dir.appendingPathComponent("driver.js")
        try Data(driverSource.utf8).write(to: driverURL)
        let input: [String: Any] = ["scripts": ScriptScan.inlineScripts(in: html), "scenario": scenario]
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
            throw NodeJS.HarnessError.badOutput(String(decoding: outData, as: UTF8.self) + "\n" + stderr)
        }
        return Outcome(errors: (json["errors"] as? [String]) ?? [],
                       warnings: (json["warnings"] as? [String]) ?? [],
                       result: (json["result"] as? [String: Any]) ?? [:])
    }

    /// Written as a raw string so no escape sequence is interpreted by Swift.
    static let driverSource = #"""
    'use strict';
    const fs = require('fs');
    const vm = require('vm');
    const input = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
    const errors = [];
    const warnings = [];
    const fetches = [];
    const documentListeners = {};
    const windowListeners = {};
    const elements = {};
    const timers = new Map();
    let now = 0;
    let nextTimerId = 1;

    function describe(e) { return String((e && e.message) || e); }

    function makeElement(key) {
      const classes = new Set();
      const attributes = {};
      return {
        key: key, value: '', checked: false, disabled: false, textContent: '', innerText: '', innerHTML: '',
        style: {}, dataset: {},
        classList: {
          add: function () { for (const c of arguments) classes.add(c); },
          remove: function () { for (const c of arguments) classes.delete(c); },
          contains: function (c) { return classes.has(c); },
          toggle: function (c) { if (classes.has(c)) { classes.delete(c); return false; } classes.add(c); return true; }
        },
        setAttribute: function (k, v) { attributes[k] = String(v); },
        getAttribute: function (k) { return Object.prototype.hasOwnProperty.call(attributes, k) ? attributes[k] : null; },
        removeAttribute: function (k) { delete attributes[k]; },
        addEventListener: function () {}, removeEventListener: function () {},
        querySelectorAll: function () { return []; }, querySelector: function () { return null; },
        appendChild: function (c) { return c; }, focus: function () {}, scrollIntoView: function () {}
      };
    }
    function el(key) {
      if (!Object.prototype.hasOwnProperty.call(elements, key)) elements[key] = makeElement(key);
      return elements[key];
    }

    const ctx = vm.createContext({});
    const win = vm.runInContext('this', ctx);
    const CtxPromise = vm.runInContext('Promise', ctx);
    win.window = win;
    win.self = win;
    win.console = {
      log: function () {}, info: function () {}, debug: function () {},
      warn: function () { warnings.push(Array.prototype.map.call(arguments, describe).join(' ')); },
      error: function () { warnings.push(Array.prototype.map.call(arguments, describe).join(' ')); }
    };
    win.document = {
      readyState: 'loading', cookie: '', body: el('body'),
      getElementById: function (id) { return el(String(id)); },
      getElementsByClassName: function (c) { return [el('class:' + c)]; },
      getElementsByName: function (n) { return [el('name:' + n)]; },
      querySelectorAll: function () { return []; },
      querySelector: function () { return null; },
      createElement: function (t) { return makeElement('new:' + t); },
      addEventListener: function (type, fn) { (documentListeners[type] = documentListeners[type] || []).push(fn); },
      removeEventListener: function () {}
    };
    win.addEventListener = function (type, fn) { (windowListeners[type] = windowListeners[type] || []).push(fn); };
    win.removeEventListener = function () {};
    win.location = { href: 'http://localhost/test', pathname: '/test', search: '' };
    win.navigator = { userAgent: 'node' };
    win.setTimeout = function (fn, ms) { const id = nextTimerId++; timers.set(id, { id: id, at: now + Math.max(0, Number(ms) || 0), fn: fn, interval: 0 }); return id; };
    win.setInterval = function (fn, ms) { const id = nextTimerId++; const step = Math.max(1, Number(ms) || 0); timers.set(id, { id: id, at: now + step, fn: fn, interval: step }); return id; };
    win.clearTimeout = function (id) { timers.delete(id); };
    win.clearInterval = function (id) { timers.delete(id); };
    win.fetch = function (url, options) {
      const record = { url: String(url), options: options || {}, body: null, settled: false };
      try { record.body = JSON.parse((options && options.body) || 'null'); } catch (e) { record.body = String(options && options.body); }
      fetches.push(record);
      return new CtxPromise(function (resolve, reject) {
        record.resolve = function (json, status) {
          record.resolveText(json === undefined ? '' : JSON.stringify(json), status);
        };
        record.resolveText = function (text, status) {
          const code = status || 200;
          resolve({
            ok: code >= 200 && code < 300, status: code,
            text: function () { return CtxPromise.resolve(text); },
            json: function () { return new CtxPromise(function (ok, fail) { try { ok(JSON.parse(text)); } catch (e) { fail(e); } }); }
          });
        };
        record.reject = reject;
      });
    };

    (input.scripts || []).forEach(function (code, i) {
      try { vm.runInContext(code, ctx, { filename: 'inline-script-' + i + '.js' }); }
      catch (e) { errors.push('script #' + i + ': ' + describe(e)); }
    });

    function settle() {
      let p = Promise.resolve();
      for (let i = 0; i < 8; i++) p = p.then(function () { return new Promise(function (r) { setImmediate(r); }); });
      return p;
    }

    const h = {
      win: win, errors: errors, warnings: warnings, fetches: fetches, el: el, settle: settle,
      now: function () { return now; },
      fireDOMContentLoaded: function () {
        win.document.readyState = 'interactive';
        (documentListeners.DOMContentLoaded || []).forEach(function (fn) {
          try { fn.call(win.document, { type: 'DOMContentLoaded' }); }
          catch (e) { errors.push('DOMContentLoaded listener: ' + describe(e)); }
        });
      },
      fireWindow: function (type) {
        (windowListeners[type] || []).forEach(function (fn) {
          try { fn.call(win, { type: type }); } catch (e) { errors.push(type + ' listener: ' + describe(e)); }
        });
      },
      advance: async function (ms) {
        const end = now + ms;
        for (;;) {
          let next = null;
          for (const t of timers.values()) {
            if (t.at <= end && (next === null || t.at < next.at || (t.at === next.at && t.id < next.id))) next = t;
          }
          if (next === null) break;
          now = next.at;
          if (next.interval > 0) next.at = now + next.interval; else timers.delete(next.id);
          try { next.fn(); } catch (e) { errors.push('timer: ' + describe(e)); }
          await settle();
        }
        now = end;
        await settle();
      },
      respond: async function (index, json, status) {
        const record = fetches[index];
        if (!record) throw new Error('no fetch #' + index);
        record.settled = true;
        record.resolve(json, status);
        await settle();
      },
      /// Answers fetch #index with a raw body (e.g. '' or text that is not JSON).
      respondText: async function (index, text, status) {
        const record = fetches[index];
        if (!record) throw new Error('no fetch #' + index);
        record.settled = true;
        record.resolveText(text, status);
        await settle();
      },
      /// Index of the most recent fetch, or -1.
      last: function () { return fetches.length - 1; },
      bodies: function () { return fetches.map(function (f) { return f.body; }); }
    };

    (async function () {
      const out = { errors: errors, warnings: warnings, result: null };
      try {
        const scenario = new Function('h', 'return (async function () {\n' + input.scenario + '\n})();');
        out.result = await scenario(h);
      } catch (e) {
        errors.push('scenario: ' + String((e && e.stack) || e));
      }
      process.stdout.write(JSON.stringify(out));
      process.exit(0);
    })();
    """#
}

// MARK: - Self-tests

@Suite("Phase 1 forms: test helpers")
struct Phase1FormsSupportSelfTests {

    @Test func submissionFollowsBrowserRules() {
        let html = """
        <form><input name="a" value="1" name="b"><input type="checkbox" name="c"><input type="checkbox" name="d" checked>\
        <input name="e" disabled value="x"><textarea name="f">x &amp; &lt;y&gt;</textarea>\
        <select name="g"><option value="1">One</option><option value="2" selected>Two</option></select>\
        <select name="h"><option value="first">F</option></select><input value="no-name"></form>
        """
        let fields = FormsHTML.submission(of: html)
        #expect(fields.map { $0.0 } == ["a", "d", "f", "g", "h"])
        #expect(fields.map { $0.1 } == ["1", "on", "x & <y>", "2", "first"])
    }

    @Test(.enabled(if: NodeJS.isAvailable))
    func browserHarnessKeepsGoingAfterAFailingScript() throws {
        let html = "<script>var a = 1; function f() { return a + 1; }</script><script>missing();</script>"
            + "<script>document.addEventListener('DOMContentLoaded', function () { window.loaded = f(); });</script>"
            + "<script>setTimeout(function () { window.timed = true; }, 50);</script>"
        let outcome = try FormsBrowser.run(html: html, scenario: """
            h.fireDOMContentLoaded();
            const before = h.win.timed === true;
            await h.advance(50);
            const p = h.win.fetch('/x', { body: '{"k":1}' }).then(function (r) { return r.json(); });
            await h.respond(0, { ok: 1 });
            return { a: h.win.a, loaded: h.win.loaded, before: before, timed: h.win.timed === true, json: await p };
            """)
        #expect(outcome.errors.count == 1)
        #expect(outcome.errors.first?.contains("missing is not defined") == true)
        #expect(outcome.result["a"] as? Int == 1)
        #expect(outcome.result["loaded"] as? Int == 2)
        #expect(outcome.result["before"] as? Bool == false)
        #expect(outcome.result["timed"] as? Bool == true)
        #expect((outcome.result["json"] as? [String: Any])?["ok"] as? Int == 1)
    }
}
