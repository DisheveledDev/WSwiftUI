//
//  Phase1FormsToggleTests.swift
//  WSwiftUITests
//
//  H11 follow-up: a variable's hidden carrier leaves its field to any control in its form that submits
//  the same name, found when the page is rendered. A Toggle therefore submits like a plain checkbox
//  (`on` when checked, nothing when unchecked), so a required checkbox still fails validation when it is
//  not ticked. Controls in another form, and buttons, do not take a carrier's field.
//

import Foundation
import Testing
@testable import WSwiftUI

/// A form with an email field, a required "terms" checkbox (unticked) and a "news" checkbox (ticked).
final class Phase1FormsTermsPage: CoreWebEndpoint, WebEndpoint, WebContent {
    var controller: String? = "phase1-forms-terms"
    var method: String? = nil
    var authenticationRequired: [WebAuthenticationStatus] = [.unauthenticated]

    func acceptedRoles(for action: WebRequestActivity) -> [String]? { nil }

    override func content() -> Any? {
        return webpage {
            Form {
                TextField("Email", text: WString("").name("email"), type: .email)
                Toggle("I accept the terms", isOn: WBool(false).name("terms"))
                Toggle("Send me news", isOn: WBool(true).name("news"))
            }
            if let message = ephemeralData["error_terms"] as? String {
                Text("error[terms]: \(message)")
            }
        }
    }

    override func persist() -> Any? {
        if validateData([.named("email", [.validEmail]), .named("terms", [.notEmpty])]) == false {
            return content()
        }
        let terms = data.bool("terms").map { String($0) } ?? "nil"
        let news = data.bool("news").map { String($0) } ?? "nil"
        return HttpResponse().status(.ok).content(.text).body("SAVED terms=\(terms) news=\(news)")
    }
}

@Suite("Phase 1 forms: toggles and other controls take a carrier's field")
struct Phase1FormsToggleTests {

    final class Box: @unchecked Sendable { var ids: [String] = [] }

    /// Every <form>…</form> of the page, in order.
    private func forms(in html: String) -> [String] {
        var result: [String] = []
        var rest = html[...]
        while let start = rest.range(of: "<form"), let end = rest.range(of: "</form>", range: start.upperBound..<rest.endIndex) {
            result.append(String(rest[start.lowerBound..<end.upperBound]))
            rest = rest[end.upperBound...]
        }
        return result
    }

    private func page() -> (server: WSwiftServer, form: String) {
        let server = TestHTTP.server()
        server.register(Phase1FormsTermsPage())
        return (server, FormsHTML.firstForm(in: FormsHTML.get(server, "/phase1-forms-terms").bodyString))
    }

    /// What the browser submits once the user ticked the checkbox posting `name`.
    private func ticking(_ name: String, in form: String, _ fields: [(String, String)]) throws -> [(String, String)] {
        let box = try #require(FormsHTML.controls(in: form).first {
            $0.attribute("type") == "checkbox" && $0.attribute("name") == name
        })
        return fields + [(name, box.attribute("value") ?? "on")]
    }

    @Test func toggleSubmitsLikeAPlainCheckbox() throws {
        let (_, form) = page()
        let fields = FormsHTML.submission(of: form)
        // the unticked box submits nothing; the ticked one submits "on"; the carriers submit nothing
        #expect(fields.map { $0.0 } == ["email", "news"])
        #expect(fields.first { $0.0 == "news" }?.1 == "on")
        let carriers = FormsHTML.controls(in: form).filter { ($0.attribute("id") ?? "").hasPrefix("hiddenInput_") }
        #expect(carriers.count == 3)
        for carrier in carriers {
            #expect(carrier.has("name") == false, "\(carrier.attributes)")
            #expect(carrier.has("value"), "a carrier keeps its value for scripts")
        }
    }

    @Test func requiredToggleFailsWhenUnticked() throws {
        let (server, form) = page()
        var fields = FormsHTML.submission(of: form)
        fields = fields.map { $0.0 == "email" ? ("email", "jane@example.com") : $0 }
        let html = FormsHTML.post(server, "/phase1-forms-terms", fields).bodyString
        #expect(html.hasPrefix("SAVED") == false)
        #expect(html.contains("error[terms]: This field is required"))
        // the valid email is kept
        #expect(html.contains("value=\"jane@example.com\""))
    }

    @Test func requiredTogglePassesWhenTicked() throws {
        let (server, form) = page()
        var fields = FormsHTML.submission(of: form)
        fields = fields.map { $0.0 == "email" ? ("email", "jane@example.com") : $0 }
        let response = FormsHTML.post(server, "/phase1-forms-terms", try ticking("terms", in: form, fields))
        #expect(response.bodyString == "SAVED terms=true news=true")
    }

    /// Unticking a box that started ticked submits nothing, so `data.bool(name) ?? false` reads false
    /// without any script running (the pattern AppGrill uses for permission toggles).
    @Test func untickedBoxIsAbsentFromTheData() throws {
        let (server, form) = page()
        var fields = FormsHTML.submission(of: form).filter { $0.0 != "news" }
        fields = fields.map { $0.0 == "email" ? ("email", "jane@example.com") : $0 }
        let response = FormsHTML.post(server, "/phase1-forms-terms", try ticking("terms", in: form, fields))
        #expect(response.bodyString == "SAVED terms=true news=nil")
    }

    /// A hand-made input in the carrier's form takes the field; a submit button and a control in another
    /// form do not.
    @Test func onlyControlsInTheSameFormTakeTheField() throws {
        let box = Box()
        let html = renderHTML { page in
            page.Form {
                page.TextField(binding: page.WString("typed").name("q"))
                box.ids.append(page.WString("manual-carrier").name("x").builderId)
                _ = page.create { e in
                    e.elementName = "input"
                    e.type("hidden")
                    e.name("x")
                    e.value("manual")
                }
            }
            page.Form {
                box.ids.append(page.WString("carried").name("q").builderId)
                box.ids.append(page.WString("kept").name("action").builderId)
                _ = page.create { e in
                    e.elementName = "input"
                    e.type("submit")
                    e.name("action")
                    e.value("save")
                }
            }
        }
        let all = forms(in: html)
        #expect(all.count == 2)
        let first = FormsHTML.submission(of: all[0])
        #expect(first.map { $0.0 } == ["q", "x"])
        #expect(first.map { $0.1 } == ["typed", "manual"])
        #expect(FormsHTML.carrier(html, id: box.ids[0])?.has("name") == false)

        let second = FormsHTML.submission(of: all[1])
        // the TextField in the first form does not take the second form's `q`; a submit button submits
        // only when it is clicked, so it does not take `action`
        #expect(second.filter { $0.0 == "q" }.map { $0.1 } == ["carried"])
        #expect(second.filter { $0.0 == "action" }.map { $0.1 }.first == "kept")
        #expect(FormsHTML.carrier(html, id: box.ids[1])?.all("name") == ["q"])
        #expect(FormsHTML.carrier(html, id: box.ids[2])?.all("name") == ["action"])
    }

    /// A carrier outside any form is only compared with the controls outside any form.
    @Test func controlsOutsideFormsAreGroupedTogether() throws {
        let box = Box()
        let html = renderHTML { page in
            box.ids.append(page.WBool(true).name("flag").builderId)
            page.Toggle("Flag", isOn: page.WBool(true).name("flag"))
            page.Form {
                box.ids.append(page.WBool(false).name("flag").builderId)
            }
        }
        // outside: the checkbox takes the field from the first carrier
        #expect(FormsHTML.carrier(html, id: box.ids[0])?.has("name") == false)
        // inside the form, with no checkbox there, the carrier still submits it
        #expect(FormsHTML.carrier(html, id: box.ids[1])?.all("name") == ["flag"])
        #expect(FormsHTML.carrier(html, id: box.ids[1])?.attribute("value") == "false")
    }
}
