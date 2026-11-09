//
//  ScriptContextObjectsTests.swift
//  WSwiftUITests
//
//  Script-context fixes in the objects that emit their own scripts / raw attributes (Modal, OffCanvas,
//  Carousel, Audio, WebSocket, Chart, FileUploader) and in the event helpers.
//

import Foundation
import Testing
@testable import WSwiftUI

private let H = Hostile.payload

private func scripts(of element: WebElement) -> [String] {
    return element.attributes.compactMap { attribute -> String? in
        switch attribute {
        case .script(let js), .domLoadedScript(let js): return js
        default: return nil
        }
    }
}

private func customAttributes(of element: WebElement) -> [String] {
    return element.attributes.compactMap { attribute -> String? in
        if case .custom(let raw) = attribute { return raw }
        return nil
    }
}

/// A `document` stub whose elements keep their event listeners in `document.listeners`.
private let listeningDocument = """
(function () {
  var listeners = {};
  return {
    listeners: listeners,
    getElementById: function (id) {
      return { id: id, classList: { contains: function () { return false; } },
               addEventListener: function (name, fn) { listeners[name] = fn; } };
    }
  };
})()
"""

@Suite("Script context: objects and events")
struct ScriptContextObjectsTests {

    // MARK: Modal / OffCanvas

    @Test func presentedModalAndOffCanvasAreScriptSafe() throws {
        var modalScripts: [String] = []
        var panelScripts: [String] = []
        var presentedIds: [String] = []
        let html = renderHTML { page in
            let showModal = page.WBool(false)
            let showPanel = page.WBool(false)
            let modal = page.Modal(id: H, isPresented: showModal) {}
            // (with a title: a panel without one gets no aria-labelledby, which would name nothing)
            let panel = page.OffCanvas(id: H + "2", isPresented: showPanel) {
                page.OffCanvasHeader { page.OffCanvasTitle { page.Text("title") } }
            }
            modalScripts = scripts(of: modal)
            panelScripts = scripts(of: panel)
            presentedIds = [showModal.builderId, showPanel.builderId]
        }
        ScriptScan.expectNoBreakout(html)
        #expect(html.contains("aria-labelledby=\"\(WebEscape.attribute(H + "2Label"))\""))
        #expect(html.contains("id=\"\(WebEscape.attribute(H + "2Label"))\""))

        guard NodeJS.isAvailable else { return }
        let syntax = try NodeJS.run(scripts: ScriptScan.inlineScripts(in: html))
        #expect(syntax.syntaxErrors.isEmpty, "\(syntax.syntaxErrors.joined(separator: "\n"))")

        // Fire the bootstrap "shown"/"hidden" events and check the origin passed to the variable update.
        for (scriptsUnderTest, id, eventPrefix, variableId) in [(modalScripts, H, "modal", presentedIds[0]),
                                                                (panelScripts, H + "2", "offcanvas", presentedIds[1])] {
            let main = try #require(scriptsUnderTest.first)
            let result = try NodeJS.run(code: main,
                                        globals: ["document": listeningDocument],
                                        after: "document.listeners['shown.bs.\(eventPrefix)'](); document.listeners['hidden.bs.\(eventPrefix)']();")
            #expect(result.error == nil, "\(result.error ?? "")")
            let updates = sandboxRecords(result, path: "updateWebVariable\(variableId)")
            #expect(updates.count == 2)
            for update in updates {
                let args = try #require(update["args"] as? [Any])
                let meta = try #require(args.last as? [String: Any])
                #expect(meta["origin"] as? String == id)
            }
            // the DOMContentLoaded part looks the element up by the exact id
            let domLoaded = try #require(scriptsUnderTest.last)
            let lookup = try NodeJS.run(code: domLoaded)
            #expect(sandboxRecords(lookup, path: "document.getElementById").first?["args"] as? [String] == [id])
        }
    }

    // MARK: Carousel

    @Test func carouselEscapesIdsAndLabels() {
        let html = renderHTML { page in
            page.Carousel(id: H) {
                page.CarouselIndicators(id: H, count: 2)
                page.CarouselControlPrev(id: H, label: H)
                page.CarouselControlNext(id: H, label: H)
            }
        }
        ScriptScan.expectNoBreakout(html)
        let target = WebEscape.attribute("#" + H)
        #expect(ScriptScan.occurrences(of: "href=\"\(target)\"", in: html) == 2)
        #expect(ScriptScan.occurrences(of: "data-bs-target=\"\(target)\"", in: html) == 2)
        #expect(ScriptScan.occurrences(of: "<span class=\"visually-hidden\">\(WebEscape.html(H))</span>", in: html) == 2)

        let indicator = WebCarouselIndicatorElement().target(H, index: 1).active(true, label: H)
        let custom = customAttributes(of: indicator)
        #expect(custom.contains("data-bs-target=\"\(target)\""))
        #expect(custom.contains("aria-label=\"\(WebEscape.attribute(H))\""))
    }

    @Test func carouselOrdinaryOutputUnchanged() {
        let html = renderHTML { page in
            page.Carousel(id: "demoCarousel") {
                page.CarouselIndicators(id: "demoCarousel", count: 1)
                page.CarouselControlPrev(id: "demoCarousel")
            }
        }
        #expect(html.contains("href=\"#demoCarousel\""))
        #expect(html.contains("<li data-bs-target=\"#demoCarousel\" data-bs-slide-to=\"0\" class=\" active\" aria-current=\"true\"></li>"))
        #expect(html.contains("<span class=\"visually-hidden\">Previous</span>"))
        let indicator = WebCarouselIndicatorElement().target("demoCarousel", index: 0).active(label: "Slide 1")
        #expect(customAttributes(of: indicator).contains("aria-label=\"Slide 1\""))
    }

    // MARK: Audio

    @Test func audioPreloadIsEscaped() {
        let html = renderHTML { page in
            page.Audio("song.mp3").preload(H)
            page.Audio("other.mp3").preload("auto")
        }
        ScriptScan.expectNoBreakout(html)
        #expect(html.contains("preload=\"\(WebEscape.attribute(H))\""))
        #expect(html.contains("preload=\"auto\""))
    }

    // MARK: WebSocket

    @Test func webSocketURLIsScriptSafe() throws {
        var socketScript = ""
        let html = renderHTML { page in
            let socket = page.WebSocket(url: H, onRecieve: [.text(ref: H, H)])
            socketScript = scripts(of: socket).last ?? ""
        }
        ScriptScan.expectNoBreakout(html)
        guard NodeJS.isAvailable else { return }
        let result = try NodeJS.run(scripts: ScriptScan.inlineScripts(in: html), code: socketScript)
        #expect(result.syntaxErrors.isEmpty, "\(result.syntaxErrors.joined(separator: "\n"))")
        #expect(result.error == nil, "\(result.error ?? "")")
        let urlConstruction = sandboxRecords(result, path: "URL").first
        #expect((urlConstruction?["args"] as? [Any])?.first as? String == H)
    }

    // MARK: Chart

    @Test func chartLabelsAndTitleAreScriptSafe() throws {
        var chartScript = ""
        let html = renderHTML { page in
            let chart = page.Chart(id: H, type: .bar, labels: [H, "b"],
                                   dataSets: [ChartDataSet(label: H, values: [1.0, 2.0])],
                                   options: ChartOptions(title: H))
            chartScript = scripts(of: chart).last ?? ""
        }
        ScriptScan.expectNoBreakout(html)
        guard NodeJS.isAvailable else { return }
        let result = try NodeJS.run(scripts: ScriptScan.inlineScripts(in: html), code: chartScript)
        #expect(result.syntaxErrors.isEmpty, "\(result.syntaxErrors.joined(separator: "\n"))")
        #expect(result.error == nil, "\(result.error ?? "")")
        let construction = try #require(sandboxRecords(result, path: "Chart").first)
        let args = try #require(construction["args"] as? [Any])
        let config = try #require(args.last as? [String: Any])
        let data = try #require(config["data"] as? [String: Any])
        #expect(data["labels"] as? [String] == [H, "b"])
        let sets = try #require(data["datasets"] as? [[String: Any]])
        #expect(sets.first?["label"] as? String == H)
        let options = try #require(config["options"] as? [String: Any])
        let plugins = try #require(options["plugins"] as? [String: Any])
        #expect((plugins["title"] as? [String: Any])?["text"] as? String == H)
        #expect(sandboxRecords(result, path: "document.getElementById").first?["args"] as? [String] == [H])
    }

    // MARK: FileUploader

    private static func dataExtra(in html: String) throws -> [String: String] {
        let regex = try NSRegularExpression(pattern: "data-extra=\"([^\"]*)\"", options: [])
        let ns = html as NSString
        let match = try #require(regex.firstMatch(in: html, range: NSRange(location: 0, length: ns.length)))
        let attribute = ns.substring(with: match.range(at: 1))
        // what the browser hands to getAttribute()
        let decoded = attribute
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
        return try JSONDecoder().decode([String: String].self, from: Data(decoded.utf8))
    }

    @Test func fileUploaderExtraFieldsAreNotDoubleEscaped() throws {
        let fields = [H: H, "token": "a\"b&c"]
        let html = renderHTML { page in
            page.FileUploader(action: H, method: "PUT", fieldName: H, extraFields: fields, onUpload: [.alert(H)]) {}
        }
        ScriptScan.expectNoBreakout(html)
        #expect(try Self.dataExtra(in: html) == fields)
        guard NodeJS.isAvailable else { return }
        let result = try NodeJS.run(scripts: ScriptScan.inlineScripts(in: html))
        #expect(result.syntaxErrors.isEmpty, "\(result.syntaxErrors.joined(separator: "\n"))")
    }

    @Test func fileUploaderOrdinaryExtraFieldsUnchanged() throws {
        let html = renderHTML { page in
            page.FileUploader(action: "/api/upload", extraFields: ["token": "abc"]) {}
        }
        #expect(html.contains("data-extra=\"{&quot;token&quot;:&quot;abc&quot;}\""))
        #expect(try Self.dataExtra(in: html) == ["token": "abc"])
    }

    // MARK: Events

    @Test func eventHandlersAreScriptSafe() throws {
        let html = renderHTML { page in
            page.Button("A").onClick([.alert(H)])
            page.Button("B").onClick([.text(ref: H, H)], options: EventOptions(preventDefault: true, stopPropagation: true, debounceMs: 5))
            page.Button("C").onMouseover([.setAttribute(ref: H, name: H, value: H)], options: EventOptions(throttleMs: 10))
            page.Button("D").onMouseLeave([.alert(H)])
            page.Button("E").onDisable([.alert(H)])
            page.Button("F").onEnterKey([.alert(H)])
            page.Button("G").onEscapeKey([.alert(H)], options: EventOptions(debounceMs: 5))
            page.Button("H").onTimer(seconds: 0.5, [.text(ref: H, H)])
            page.Button("I").onInput([.navigate(H)], options: EventOptions())
        }
        ScriptScan.expectNoBreakout(html)
        guard NodeJS.isAvailable else { return }
        let result = try NodeJS.run(scripts: ScriptScan.inlineScripts(in: html))
        #expect(result.syntaxErrors.isEmpty, "\(result.syntaxErrors.joined(separator: "\n"))")
    }

    /// The key filter of onEnterKey/onEscapeKey compares against the real key name (it used to compare
    /// against the literal text "(key)", so the handlers never ran).
    @Test(.enabled(if: NodeJS.isAvailable), arguments: [("Enter", true), ("Escape", false)])
    func keyFilterMatchesTheKey(key: String, enter: Bool) throws {
        let button = WebElement()
        button.builderId = "btn"
        if enter {
            button.onEnterKey([.alert("pressed")])
        } else {
            button.onEscapeKey([.alert("pressed")])
        }
        let script = try #require(scripts(of: button).last)
        #expect(script.contains("if (event.key === \"\(key)\") {"))
        let event = "{ key: %@, preventDefault: function () {}, stopPropagation: function () {} }"
        let result = try NodeJS.run(scripts: [script],
                                    code: script,
                                    globals: ["btn": "{ addEventListener: function (name, fn) { this.handler = fn; } }"],
                                    after: "btn.handler(\(event.replacingOccurrences(of: "%@", with: "'a'"))); btn.handler(\(event.replacingOccurrences(of: "%@", with: "'\(key)'")));")
        #expect(result.syntaxErrors.isEmpty)
        #expect(result.error == nil, "\(result.error ?? "")")
        #expect(sandboxRecords(result, path: "window.alert").count == 1, "handler must run for \(key) only")
    }

    @Test func timerWithNonFiniteIntervalDoesNotTrap() throws {
        let element = WebElement()
        element.builderId = "tm"
        element.onTimer(seconds: .nan, [.reload])
        element.onTimer(seconds: 1.25, [.reload])
        element.onTimer(seconds: .infinity, [.reload])
        element.onTimer(seconds: 1e300, [.reload])
        element.onTimer(seconds: -5, [.reload])
        let all = scripts(of: element)
        #expect(all.count == 5)
        guard all.count == 5 else { return }
        #expect(all[0].contains("}, 0);"))
        #expect(all[1].contains("}, 1250);"))
        // "forever" is the longest interval a timer supports, not an overflow that repeats every ~1 ms
        #expect(all[2].contains("}, 2147483647);"))
        #expect(all[3].contains("}, 2147483647);"))
        #expect(all[4].contains("}, 0);"))
    }

    /// With real timers, an infinite interval never fires (and node reports no TimeoutOverflowWarning),
    /// while an ordinary short interval keeps firing.
    @Test(.enabled(if: NodeJS.isAvailable))
    func infiniteTimerIntervalNeverFires() throws {
        func timerScript(_ seconds: Double) -> String {
            let element = WebElement()
            element.builderId = "tm"
            element.onTimer(seconds: seconds, [.alert("tick")])
            return scripts(of: element).joined(separator: "\n")
        }
        let forever = try NodeJS.alertsWithRealTimers(timerScript(.infinity), waitMs: 150)
        #expect(forever.alerts == 0)
        #expect(forever.stderr.contains("TimeoutOverflowWarning") == false, "\(forever.stderr)")
        let huge = try NodeJS.alertsWithRealTimers(timerScript(1e300), waitMs: 150)
        #expect(huge.alerts == 0)
        let control = try NodeJS.alertsWithRealTimers(timerScript(0.01), waitMs: 150)
        #expect(control.alerts >= 2, "the 10 ms control interval should fire repeatedly")
    }
}
