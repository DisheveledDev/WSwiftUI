//
//  Phase1FormsValidationTests.swift
//  WSwiftUITests
//
//  H10 (DATA-16 / ERG-6 / CORE-04): validateData checks every field, reports a missing field instead of
//  silently aborting, and records the submitted value of every field so a form re-rendered after a failed
//  validation keeps what the user typed. Password inputs are still never re-populated.
//

import Foundation
import Testing
@testable import WSwiftUI

/// A sign-up form with one control per kind of binding, validated server-side.
final class Phase1FormsSignupPage: CoreWebEndpoint, WebEndpoint, WebContent {
    var controller: String? = "phase1-forms-signup"
    var method: String? = nil
    var authenticationRequired: [WebAuthenticationStatus] = [.unauthenticated]

    func acceptedRoles(for action: WebRequestActivity) -> [String]? { nil }

    static var rules: [ValidateField] { [
        .named("name", [.notEmpty, .atLeast(2)]),
        .named("email", [.notEmpty, .validEmail]),
        .named("age", [.validNumber]),
        .named("website", [.validURL]),
        .named("password", [.atLeast(8)]),
        .named("bio", [.atLeast(3)]),
        .named("plan", [.notEmpty]),
        // no control on the page: its error is listed as text
        .named("terms", [.notEmpty]),
    ] }

    override func content() -> Any? {
        return webpage {
            Form {
                TextField("Name", text: WString("").name("name"))
                TextField("Email", text: WString("").name("email"), type: .email)
                TextField("Age", text: WInt(0).name("age"), type: .number)
                TextField("Website", text: WString("").name("website"), type: .url)
                SecureField("Password", text: WString("").name("password"))
                TextArea("Bio", text: WString("").name("bio"))
                Picker("Plan", selection: WString("starter").name("plan")) {
                    Text("Starter").value("starter")
                    Text("Pro").value("pro")
                }
            }
            if let message = ephemeralData["error_terms"] as? String {
                Text("error[terms]: \(message)")
            }
        }
    }

    override func persist() -> Any? {
        if validateData(Self.rules) == false {
            return content()
        }
        return HttpResponse().status(.ok).content(.text).body("saved")
    }
}

/// Reports what validateData decided for a liveUpdate-style JSON transaction.
final class Phase1FormsTransactionAPI: CoreWebEndpoint, WebEndpoint, WebApiEndpoint {
    var controller: String? = "phase1-forms-transaction"
    var method: String? = nil
    var authenticationRequired: [WebAuthenticationStatus] = [.unauthenticated]

    func acceptedRoles() -> [String]? { nil }

    func call() -> Any? {
        let valid = validateData([
            .named("tags", [.notEmpty, .validJSON]),
            .named("profile", [.validJSON]),
            .named("count", [.validNumber]),
            .named("absent", [.notEmpty]),
        ])
        var errors: [String: String] = [:]
        var previous: [String: String] = [:]
        for name in ["tags", "profile", "count", "absent"] {
            if let message = ephemeralData["error_\(name)"] as? String { errors[name] = message }
            if let stored = ephemeralData["previous_\(name)"], stored != nil { previous[name] = "stored" }
        }
        return Phase1FormsTransactionVerdict(valid: valid, errors: errors, previous: previous)
    }
}

struct Phase1FormsTransactionVerdict: Codable {
    var valid: Bool
    var errors: [String: String]
    var previous: [String: String]
}

@Suite("Phase 1 forms: validation round trip (H10)")
struct Phase1FormsValidationTests {

    private func submit(_ fields: [(String, String)]) -> String {
        let server = TestHTTP.server()
        server.register(Phase1FormsSignupPage())
        return FormsHTML.post(server, "/phase1-forms-signup", fields).bodyString
    }

    /// The rendered control posting under `name` (TextField / SecureField / TextArea / Picker).
    private func control(_ html: String, named name: String) -> FormsHTML.Tag? {
        FormsHTML.controls(in: FormsHTML.firstForm(in: html)).first {
            $0.all("name").contains(name) && ($0.attribute("type") ?? "") != "hidden"
        }
    }

    /// The server-side error message rendered right after the control posting under `name`.
    private func errorAfter(_ html: String, named name: String) -> String? {
        let pattern = "<(?:input|textarea|select)\\b[^>]*name=\"\(NSRegularExpression.escapedPattern(for: name))\"[\\s\\S]*?"
            + "<div style=\"font-size: x-small; color: red;\">([^<]*)</div>"
        let regex = try! NSRegularExpression(pattern: pattern)
        let ns = html as NSString
        // stop at the next control so a later field's message is not attributed to this one
        guard let match = regex.firstMatch(in: html, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let span = ns.substring(with: match.range)
        let controlsInSpan = FormsHTML.controls(in: span).filter { ($0.attribute("type") ?? "") != "hidden" }
        guard controlsInSpan.count <= 1 else { return nil }
        return FormsHTML.decode(ns.substring(with: match.range(at: 1)))
    }

    @Test func everyErrorIsShownAndValidValuesAreKept() throws {
        let secret = "Zq7Pw"          // too short: fails .atLeast(8)
        let bio = "Hi <b>there</b> & \"friends\""
        let html = submit([
            ("name", "Jane O'Neil"),            // valid
            ("email", "not-an-email"),          // invalid
            ("age", "41"),                      // valid
            // website: missing
            ("password", secret),               // invalid + secret
            ("bio", bio),                       // valid
            ("plan", "pro"),                    // valid
            // terms: missing (no control on the page)
        ])
        #expect(html != "saved")

        // every failing field reports its own error, including the missing ones
        #expect(errorAfter(html, named: "email") == "Field must be a valid email address")
        #expect(errorAfter(html, named: "password") == "Field must be at least 8 characters")
        #expect(errorAfter(html, named: "website") == "This field is required")
        #expect(html.contains("error[terms]: This field is required"))
        // fields that passed show no error
        for valid in ["name", "age", "bio", "plan"] {
            #expect(errorAfter(html, named: valid) == nil, "\(valid) should have no error")
            #expect(control(html, named: valid)?.attribute("class")?.contains("border-danger") == false)
        }

        // valid values survive the re-render (escaped once)
        #expect(control(html, named: "name")?.attribute("value") == "Jane O'Neil")
        #expect(html.contains("value=\"Jane O&#39;Neil\""))
        #expect(control(html, named: "age")?.attribute("value") == "41")
        #expect(control(html, named: "bio")?.inner == WebEscape.html(bio))
        let plan = try #require(control(html, named: "plan"))
        #expect(FormsHTML.optionTags(in: plan.inner ?? "").first { $0.has("selected") }?.attribute("value") == "pro")
        // the invalid value is shown back for correction
        #expect(control(html, named: "email")?.attribute("value") == "not-an-email")

        // the password is never echoed anywhere
        #expect(html.contains(secret) == false)
        #expect(control(html, named: "password")?.has("value") == false)
    }

    /// validateData records a password that passed like any other field; it is still never written back
    /// into the page when another field fails.
    @Test func validPasswordBesideAFailingFieldIsNeverEchoed() {
        let secret = "Valid-Long-Secret-77"
        let html = submit([
            ("name", "Jane"), ("email", "not-an-email"), ("age", "41"), ("website", "https://example.com"),
            ("password", secret), ("bio", "Hello"), ("plan", "pro"), ("terms", "on"),
        ])
        #expect(html != "saved")
        #expect(errorAfter(html, named: "email") == "Field must be a valid email address")
        #expect(errorAfter(html, named: "password") == nil)
        // the password is nowhere: not the input, not its variable's hidden input or definition script
        #expect(html.contains(secret) == false)
        #expect(control(html, named: "password")?.has("value") == false)
        // the other values are kept
        #expect(control(html, named: "website")?.attribute("value") == "https://example.com")
        #expect(control(html, named: "name")?.attribute("value") == "Jane")
    }

    @Test func emptySubmissionReportsEveryMissingField() {
        let html = submit([])
        // one message per control, plus the field without a control
        #expect(ScriptScan.occurrences(of: ">This field is required</div>", in: html) == Phase1FormsSignupPage.rules.count - 1)
        #expect(html.contains("error[terms]: This field is required"))
        for name in ["name", "email", "age", "website", "password", "bio", "plan"] {
            #expect(errorAfter(html, named: name) == "This field is required", "\(name)")
        }
    }

    @Test func validSubmissionPasses() {
        let html = submit([
            ("name", "Jane"), ("email", "jane@example.com"), ("age", "41"), ("website", "https://example.com"),
            ("password", "long-enough-pw"), ("bio", "Hello"), ("plan", "pro"), ("terms", "on"),
        ])
        #expect(html == "saved")
    }

    /// validateData records the submitted value of every validated field, passing or failing, and nothing
    /// for a field that was not submitted.
    @Test func previousValuesAreRecordedForEverySubmittedField() {
        let page = Phase1FormsSignupPage()
        page.data.consume(["name": "Ann", "email": "bad", "age": "12"])
        let ok = page.validateData([
            .named("name", [.atLeast(2)]),
            .named("email", [.validEmail]),
            .named("age", [.validNumber]),
            .named("missing", [.notEmpty]),
        ])
        #expect(ok == false)
        #expect(page.ephemeralData["previous_name"] as? String == "Ann")
        #expect(page.ephemeralData["previous_email"] as? String == "bad")
        #expect(page.ephemeralData["previous_age"] as? String == "12")
        #expect(page.ephemeralData["previous_missing"] == nil)
        #expect(page.ephemeralData["error_name"] == nil)
        #expect(page.ephemeralData["error_email"] as? String == "Field must be a valid email address")
        #expect(page.ephemeralData["error_missing"] as? String == "This field is required")
    }

    /// Values posted by liveUpdate (a WebVariableTransaction) are validated as JSON text, and a field the
    /// transaction lacks is reported instead of aborting the whole check.
    @Test func transactionValuesAreValidatedAsJSON() throws {
        let server = TestHTTP.server()
        server.register(Phase1FormsTransactionAPI())
        let body = #"{"reference":"r","read":false,"write":true,"data":{"tags":["a","b"],"profile":{"k":[1,true,null]},"count":3}}"#
        let response = server.respond(to: TestHTTP.request(.POST, "/phase1-forms-transaction",
                                                           headers: [("Content-Type", "application/json")],
                                                           body: Data(body.utf8)))
        let verdict = try JSONDecoder().decode(Phase1FormsTransactionVerdict.self, from: Data(response.bodyBytes))
        #expect(verdict.valid == false)
        #expect(verdict.errors == ["absent": "This field is required"])
        #expect(verdict.previous == ["tags": "stored", "profile": "stored", "count": "stored"])
    }
}
