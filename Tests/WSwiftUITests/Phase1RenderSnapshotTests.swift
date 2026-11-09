//
//  Phase1RenderSnapshotTests.swift
//  WSwiftUITests
//
//  Phase 1 render slice: small fixed pages rendered with a fixed element id namespace are compared byte for
//  byte with golden output. Possible only because ids are deterministic now (LAYOUT-16); they also pin the
//  page layout: no <script> among the elements, one script block at the end of <body> (LAYOUT-11, M12).
//

import Foundation
import Testing
@testable import WSwiftUI

@Suite("Phase 1 render: snapshots")
struct Phase1RenderSnapshotTests {

    static func expectSnapshot(_ actual: String, _ golden: String, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(actual == golden, sourceLocation: sourceLocation)
        if actual != golden {
            let a = actual.components(separatedBy: "\n"), g = golden.components(separatedBy: "\n")
            let index = zip(a, g).enumerated().first(where: { $0.element.0 != $0.element.1 })?.offset ?? min(a.count, g.count)
            Issue.record("first difference at line \(index + 1):\nactual: \(index < a.count ? a[index] : "<end>")\ngolden: \(index < g.count ? g[index] : "<end>")\n--- actual ---\n\(actual)", sourceLocation: sourceLocation)
        }
        RenderInvariants.expectValid(actual, "snapshot", sourceLocation: sourceLocation)
    }

    @Test func aStaticPage() {
        let html = buildPage(namespace: "snap") { page in
            page.head(.title("Static"))
            page.VStack {
                page.Text("Hello")
            }
        }.renderWebPage()
        Self.expectSnapshot(html, #"""
        <!DOCTYPE html>
        <html lang="en">
            <head>
                <meta charset="utf-8" />
                <title>Static</title>
            </head>
            <body class="wsui-device-desktop" data-wsui-device="desktop">
                <div class="snap_2 col wsui-vstack d-flex flex-column align-items-stretch">
                    <div class="snap_3 col wsui-vstack d-flex flex-column align-items-stretch">
                        <div class="snap_4 row">
                            <span class="snap_5 text col">Hello</span>
                        </div>
                    </div>
                </div>
            </body>
        </html>

        """#)
    }

    @Test func aListGroupWithAClickableItemAndAnAppDOMContentLoadedScript() {
        let html = buildPage(namespace: "snap") { page in
            page.ListGroup {
                page.ListGroupItem("One")
                page.ListGroupItem("Two").onClick(.navigate("/two"))
            }
            _ = page.create { $0.addAttribute(.domLoadedScript("window.ready = true;")) }
        }.renderWebPage()
        Self.expectSnapshot(html, #"""
        <!DOCTYPE html>
        <html lang="en">
            <head>
                <meta charset="utf-8" />
            </head>
            <body class="wsui-device-desktop" data-wsui-device="desktop">
                <ul class="snap_2 list-group wsui-list-group">
                    <li class="snap_3 list-group-item">One</li>
                    <li class="snap_4 list-group-item">Two</li>
                </ul>
                <div class="snap_5"></div>
                <script>
        function __wsuiReport(e) { if (typeof reportError === 'function' && /\[native code\]/.test(Function.prototype.toString.call(reportError))) { reportError(e); } else { console.error(e); } }
        var snap_4;
        (function (__wsuiDocument) {
        function __wsuiElement(id) { return __wsuiDocument.getElementsByClassName(id)[0]; }
        snap_4 = __wsuiElement("snap_4");
        })(document);
        try {
        snap_4.addEventListener('click', function() {
            window.location.href = "/two";

        });
        } catch (e) { __wsuiReport(e); }
                </script>
                <script>
        document.addEventListener('DOMContentLoaded', function () {
        try { (function () {
        window.ready = true;
        }).apply(this, arguments); } catch (e) { __wsuiReport(e); }
        });
                </script>
            </body>
        </html>

        """#)
    }

    @Test func aButtonWithAnActionAndAFrameworkDOMContentLoadedScript() {
        let html = buildPage(namespace: "snap") { page in
            page.Button("Save").onClick(.random([.addClass("a"), .addClass("b")]))
            _ = page.create { $0.addAttribute(.domLoadedScript("window.loaded = 1;"), file: "WSwiftUI/Fixture.swift") }
        }.renderWebPage()
        Self.expectSnapshot(html, #"""
        <!DOCTYPE html>
        <html lang="en">
            <head>
                <meta charset="utf-8" />
            </head>
            <body class="wsui-device-desktop" data-wsui-device="desktop">
                <button class="snap_2 btn wsui-button" type="button">Save</button>
                <div class="snap_3"></div>
                <script>
        function __wsuiReport(e) { if (typeof reportError === 'function' && /\[native code\]/.test(Function.prototype.toString.call(reportError))) { reportError(e); } else { console.error(e); } }
        var snap_2;
        (function (__wsuiDocument) {
        function __wsuiElement(id) { return __wsuiDocument.getElementsByClassName(id)[0]; }
        snap_2 = __wsuiElement("snap_2");
        })(document);
        try {
        snap_2.addEventListener('click', function() {
            var randomIndexsnap_2_1 = Math.floor(Math.random() * 2);
        var functionssnap_2_1 = [];
        functionssnap_2_1.push(function() {
        snap_2.classList.add("a");
        });
        functionssnap_2_1.push(function() {
        snap_2.classList.add("b");
        });
        functionssnap_2_1[randomIndexsnap_2_1]();

        });
        } catch (e) { __wsuiReport(e); }
        document.addEventListener('DOMContentLoaded', function () {
        try { (function () {
        window.loaded = 1;
        }).apply(this, arguments); } catch (e) { __wsuiReport(e); }
        });
                </script>
            </body>
        </html>

        """#)
    }
}
