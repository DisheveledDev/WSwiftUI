//
//  Phase1FormsCarrierTests.swift
//  WSwiftUITests
//
//  H11 (DATA-5 / ERG-21): a variable's hidden carrier input has one `name` (the builderId until `.name()`
//  replaces it) and always renders an escaped `value=` holding the current value, serialized the way the
//  server parses it back. Round trip: render a form, post the fields a browser would post, read them with
//  `data.*`, restore them with `updateWithEphermeralData` and re-render.
//

import Foundation
import Testing
@testable import WSwiftUI

/// Original values for the round trip, one per variable type.
enum Phase1CarrierValues {
    static let string = "a \"quoted\" <tag> & 'x' ünï, plus+sign"
    static let int = -42
    static let double = 2.5
    static let bool = true
    static let array = ["x", "y,z", "<q> & \"r\""]

    // what the page starts with when the values are restored instead
    static let otherString = "other"
    static let otherInt = 1
    static let otherDouble = 9.75
    static let otherBool = false
    static let otherArray = ["other"]
}

/// A form made only of hidden carriers. GET renders them; POST with `mode=read` echoes what `data.*`
/// read back; POST with `mode=restore` records them (validateData) and re-renders, restoring each carrier
/// with `updateWithEphermeralData`.
final class Phase1FormsCarrierPage: CoreWebEndpoint, WebEndpoint, WebContent {
    var controller: String? = "phase1-forms-carriers"
    var method: String? = nil
    var authenticationRequired: [WebAuthenticationStatus] = [.unauthenticated]

    func acceptedRoles(for action: WebRequestActivity) -> [String]? { nil }

    override func content() -> Any? {
        let restoring = ephemeralData["phase1_restore"] as? Bool == true
        return webpage {
            Form {
                let variables = [
                    WString(restoring ? Phase1CarrierValues.otherString : Phase1CarrierValues.string).name("s"),
                    WInt(restoring ? Phase1CarrierValues.otherInt : Phase1CarrierValues.int).name("i"),
                    WDouble(restoring ? Phase1CarrierValues.otherDouble : Phase1CarrierValues.double).name("d"),
                    WBool(restoring ? Phase1CarrierValues.otherBool : Phase1CarrierValues.bool).name("b"),
                    WArray(restoring ? Phase1CarrierValues.otherArray : Phase1CarrierValues.array).name("a"),
                    WString("mode").name("mode"),
                ]
                if restoring {
                    for variable in variables.dropLast() {
                        updateWithEphermeralData(variable)
                    }
                }
            }
        }
    }

    override func persist() -> Any? {
        if data.string("mode") == "restore" {
            _ = validateData(["s", "i", "d", "b", "a"].map { .named($0, []) })
            ephemeralData["phase1_restore"] = true
            return content()
        }
        var array: [String]? = nil
        if let raw = data.string("a"), let decoded = try? JSONDecoder().decode([String].self, from: Data(raw.utf8)) {
            array = decoded
        }
        return Phase1CarrierEcho(s: data.string("s"), i: data.int("i"), d: data.double("d"), b: data.bool("b"), a: array)
    }
}

struct Phase1CarrierEcho: Codable, Equatable {
    var s: String?
    var i: Int?
    var d: Double?
    var b: Bool?
    var a: [String]?
}

@Suite("Phase 1 forms: hidden carrier inputs (H11)")
struct Phase1FormsCarrierTests {

    final class Box: @unchecked Sendable { var ids: [String] = [] }

    @Test func namedCarriersHaveOneNameAndAValue() throws {
        let box = Box()
        let html = renderHTML { page in
            box.ids = [
                page.WString(Phase1CarrierValues.string).name("s").builderId,
                page.WInt(Phase1CarrierValues.int).name("i").builderId,
                page.WDouble(Phase1CarrierValues.double).name("d").builderId,
                page.WBool(Phase1CarrierValues.bool).name("b").builderId,
                page.WArray(Phase1CarrierValues.array).name("a").builderId,
                page.WBool(false).name("off").builderId,
            ]
        }
        let expected: [(String, String)] = [
            ("s", Phase1CarrierValues.string), ("i", "-42"), ("d", "2.5"), ("b", "true"), ("a", ""), ("off", "false"),
        ]
        for (index, (name, value)) in expected.enumerated() {
            let carrier = try #require(FormsHTML.carrier(html, id: box.ids[index]), "carrier \(name)")
            #expect(carrier.all("name") == [name], "\(name): \(carrier.all("name"))")
            #expect(carrier.all("value").count == 1, "\(name) has no single value attribute")
            if name == "a" {
                let json = try #require(carrier.attribute("value"))
                #expect(try JSONDecoder().decode([String].self, from: Data(json.utf8)) == Phase1CarrierValues.array)
            } else {
                #expect(carrier.attribute("value") == value, "\(name)")
            }
        }
        // escaped exactly once
        #expect(html.contains("value=\"\(WebEscape.attribute(Phase1CarrierValues.string))\""))
    }

    @Test func unnamedCarrierPostsUnderItsBuilderId() throws {
        let box = Box()
        let html = renderHTML { page in
            box.ids = [page.WInt(5).builderId, page.WString("v").builderId]
        }
        for id in box.ids {
            let carrier = try #require(FormsHTML.carrier(html, id: id))
            #expect(carrier.all("name") == [id])
        }
        #expect(FormsHTML.carrier(html, id: box.ids[0])?.attribute("value") == "5")
        #expect(FormsHTML.carrier(html, id: box.ids[1])?.attribute("value") == "v")
    }

    @Test func lastNameWins() throws {
        let box = Box()
        let html = renderHTML { page in
            box.ids = [page.WInt(5).name("first").name("second").builderId,
                       page.WString("x").name("one").name("two").builderId]
        }
        #expect(FormsHTML.carrier(html, id: box.ids[0])?.all("name") == ["second"])
        #expect(FormsHTML.carrier(html, id: box.ids[1])?.all("name") == ["two"])
    }

    /// A control that submits the variable under its name owns the field: the carrier does not post it
    /// a second time (so `getElementsByName` and the server both see one field).
    @Test func boundControlsOwnTheFieldName() throws {
        let box = Box()
        let html = renderHTML { page in
            page.Form {
                let email = page.WString("me@example.com").name("email")
                let age = page.WInt(30).name("age")
                let notes = page.WString("n").name("notes")
                let plan = page.WString("pro").name("plan")
                let secret = page.WString("pw").name("secret")
                box.ids = [email.builderId, age.builderId, notes.builderId, plan.builderId, secret.builderId]
                page.TextField(binding: email)
                page.TextField(binding: age, type: .number)
                page.TextArea(value: notes)
                page.Picker(selection: plan) { page.Text("Pro").value("pro") }
                page.SecureField("Secret", text: secret)
            }
        }
        let fields = FormsHTML.submission(of: FormsHTML.firstForm(in: html))
        for name in ["email", "age", "notes", "plan", "secret"] {
            #expect(fields.filter { $0.0 == name }.count == 1, "\(name) posted \(fields.filter { $0.0 == name }.count) times")
        }
        #expect(Dictionary(fields, uniquingKeysWith: { a, _ in a })["age"] == "30")
        for id in box.ids {
            let carrier = try #require(FormsHTML.carrier(html, id: id))
            #expect(carrier.has("value"), "carrier keeps its value")
        }
        // the secret's carrier is empty
        #expect(FormsHTML.carrier(html, id: box.ids[4])?.attribute("value") == "")
        #expect(html.contains("value=\"pw\"") == false)
    }

    /// Any element has one name and one value: `.name` / `.pair("name", …)` and `.value` / `.pair("value", …)`
    /// share a slot (the last one wins), and a password input renders no value however it was set.
    @Test func elementsHaveOneNameAndValueSlot() throws {
        let box = Box()
        let html = renderHTML { page in
            let a = page.TextField(binding: page.WString("x"))
            a.addAttribute(.pair("name", "pair-name"))
            a.name("final-name")
            let b = page.TextField(binding: page.WString("y"))
            b.name("first")
            b.addAttribute(.pair("NAME", "last"))
            b.addAttribute(.pair("value", "pair-value"))
            let secret = page.TextField(binding: page.WString(""), type: .password)
            secret.addAttribute(.pair("value", "Leak-Pair-123"))
            secret.value("Leak-Value-456")
            box.ids = [a.builderId, b.builderId, secret.builderId]
        }
        let a = try #require(FormsHTML.control(html, builderId: box.ids[0]))
        let b = try #require(FormsHTML.control(html, builderId: box.ids[1]))
        let secret = try #require(FormsHTML.control(html, builderId: box.ids[2]))
        #expect(a.all("name") == ["final-name"])
        #expect(b.all("name") == ["last"])
        #expect(b.all("value") == ["pair-value"])
        #expect(secret.has("value") == false)
        #expect(html.contains("Leak-Pair-123") == false)
        #expect(html.contains("Leak-Value-456") == false)
    }

    @Test(arguments: [Hostile.payload, "\" autofocus onfocus=\"alert(1)", "</script><script>alert(1)</script>"])
    func carrierValueIsEscaped(_ payload: String) throws {
        let box = Box()
        let html = renderHTML { page in
            box.ids = [page.WString(payload).name("p").builderId, page.WArray([payload]).name("q").builderId]
        }
        ScriptScan.expectNoBreakout(html)
        let carrier = try #require(FormsHTML.carrier(html, id: box.ids[0]))
        #expect(carrier.attribute("value") == payload)
        #expect(html.contains("value=\"\(WebEscape.attribute(payload))\""))
        let array = try #require(FormsHTML.carrier(html, id: box.ids[1])?.attribute("value"))
        #expect(try JSONDecoder().decode([String].self, from: Data(array.utf8)) == [payload])
    }

    /// The value the carrier renders is the value the client sync writes later (JS `String(value)` /
    /// `JSON.stringify`), so the field does not change when the page loads.
    @Test func carrierValueMatchesTheClientSerialization() throws {
        let box = Box()
        let html = renderHTML { page in
            box.ids = [page.WDouble(3).builderId, page.WDouble(1e21).builderId, page.WDouble(0.00001).builderId,
                       page.WArray(["a/b"]).builderId]
        }
        #expect(FormsHTML.carrier(html, id: box.ids[0])?.attribute("value") == "3")
        #expect(FormsHTML.carrier(html, id: box.ids[1])?.attribute("value") == "1e+21")
        #expect(FormsHTML.carrier(html, id: box.ids[2])?.attribute("value") == "0.00001")
        #expect(FormsHTML.carrier(html, id: box.ids[3])?.attribute("value") == "[\"a/b\"]")
    }

    /// render -> post the fields a browser would post -> data.*
    @Test func carriersRoundTripThroughDataAccessors() throws {
        let server = TestHTTP.server()
        server.register(Phase1FormsCarrierPage())
        let form = FormsHTML.firstForm(in: FormsHTML.get(server, "/phase1-forms-carriers").bodyString)
        let fields = FormsHTML.submission(of: form)
        #expect(fields.map { $0.0 } == ["s", "i", "d", "b", "a", "mode"])
        let response = FormsHTML.post(server, "/phase1-forms-carriers", fields.map { $0.0 == "mode" ? ("mode", "read") : $0 })
        let echo = try JSONDecoder().decode(Phase1CarrierEcho.self, from: Data(response.bodyBytes))
        #expect(echo == Phase1CarrierEcho(s: Phase1CarrierValues.string, i: Phase1CarrierValues.int,
                                          d: Phase1CarrierValues.double, b: Phase1CarrierValues.bool,
                                          a: Phase1CarrierValues.array))
    }

    /// render -> post -> validateData records -> updateWithEphermeralData -> re-render: the re-rendered
    /// carriers hold the posted values, not the page's defaults.
    @Test func carriersRoundTripThroughRestore() throws {
        let server = TestHTTP.server()
        server.register(Phase1FormsCarrierPage())
        let first = FormsHTML.firstForm(in: FormsHTML.get(server, "/phase1-forms-carriers").bodyString)
        let posted = FormsHTML.submission(of: first).map { $0.0 == "mode" ? ("mode", "restore") : $0 }
        let second = FormsHTML.firstForm(in: FormsHTML.post(server, "/phase1-forms-carriers", posted).bodyString)

        let carriers = FormsHTML.controls(in: second).filter { $0.attribute("type") == "hidden" }
        #expect(carriers.count == 6)
        let values = carriers.prefix(5).map { $0.attribute("value") ?? "<none>" }
        let originals = FormsHTML.controls(in: first).filter { $0.attribute("type") == "hidden" }.prefix(5).map { $0.attribute("value") ?? "<none>" }
        #expect(values == originals)
        #expect(values.first == Phase1CarrierValues.string)
        #expect(values.contains(Phase1CarrierValues.otherString) == false)
        // the variable definitions carry the restored values too (not only the page-load sync)
        #expect(second.isEmpty == false)
        let fullPage = FormsHTML.post(server, "/phase1-forms-carriers", posted).bodyString
        #expect(fullPage.contains(" = \(WebJSON.scriptString(Phase1CarrierValues.string));"))
        #expect(fullPage.contains(" = -42;"))
        #expect(fullPage.contains(" = 2.5;"))
        #expect(fullPage.contains(" = true;"))
        #expect(fullPage.contains(WebJSON.scriptString(Phase1CarrierValues.otherString)) == false)
    }
}
