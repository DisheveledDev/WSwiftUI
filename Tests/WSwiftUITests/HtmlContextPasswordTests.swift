//
//  HtmlContextPasswordTests.swift
//  WSwiftUITests
//
//  A password input must never be re-populated (C3 / CORE-04 / ERG-6 / DATA-16 / core-MISSED-2):
//  not with the value submitted to a form that failed validateData, and not with its bound value.
//

import Foundation
import Testing
@testable import WSwiftUI

/// A sign-up style form: one ordinary field and three password-type fields, all of which fail validation.
final class HtmlContextSignupPage: CoreWebEndpoint, WebEndpoint, WebContent {
    var controller: String? = "htmlctx-signup"
    var method: String? = nil
    var authenticationRequired: [WebAuthenticationStatus] = [.unauthenticated]

    func acceptedRoles(for action: WebRequestActivity) -> [String]? { nil }

    override func content() -> Any? {
        return webpage {
            Form {
                TextField("Email", text: WString("").name("email"))
                SecureField("Password", text: WString("").name("password"))
                TextField("PIN", text: WString("").name("pin"), type: .password)
                TextField(binding: WString("").name("otp"), type: .password)
                // a later (non-secret) control bound to the same name must not get the secret back either
                TextField(binding: WString("").name("password"))
            }
        }
    }

    override func persist() -> Any? {
        let ok = validateData([
            .named("email", [.validEmail]),
            .named("password", [.atLeast(64)]),
            .named("pin", [.atLeast(64)]),
            .named("otp", [.atLeast(64)]),
        ])
        if ok == false {
            return content()
        }
        return HttpResponse().status(.ok)
    }
}

@Suite("html-context: password fields are never re-populated")
struct HtmlContextPasswordTests {

    private func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private func submit(_ fields: [(String, String)]) -> String {
        let body = fields.map { "\($0.0)=\(formEncode($0.1))" }.joined(separator: "&")
        let server = TestHTTP.server()
        server.register(HtmlContextSignupPage())
        let response = server.respond(to: TestHTTP.request(
            .POST, "/htmlctx-signup",
            headers: [("Content-Type", "application/x-www-form-urlencoded")],
            body: Data(body.utf8)))
        return response.bodyString
    }

    @Test func submittedPasswordsAreNotEchoedAfterFailedValidation() {
        let password = "Hunter2-Sup3rSecret-PW"
        let pin = "PIN-7731-Secret"
        let otp = "OTP-9921-Secret"
        let html = submit([("email", "not-an-email"), ("password", password), ("pin", pin), ("otp", otp)])

        // the form was re-rendered with validation errors...
        #expect(html.contains("Field must be at least 64 characters"))
        #expect(html.contains("Field must be a valid email address"))
        // ...but none of the secrets appear anywhere in the page (value=, scripts, text)
        #expect(html.contains(password) == false)
        #expect(html.contains(pin) == false)
        #expect(html.contains(otp) == false)
        #expect(html.contains("type=\"password\""))
    }

    @Test func passwordWithSpecialCharactersIsNotEchoedInAnyEncoding() {
        let password = "x'y\"<z>&Pw-Unique"
        let html = submit([("email", "bad"), ("password", password), ("pin", "p"), ("otp", "o")])
        #expect(html.contains("Pw-Unique") == false)
    }

    @Test func ordinaryFieldsStillRoundTripEscaped() {
        let hostile = "\" autofocus onfocus=\"alert(1)"
        let html = submit([("email", hostile), ("password", "pw-123"), ("pin", "p"), ("otp", "o")])
        #expect(html.contains("value=\"&quot; autofocus onfocus=&quot;alert(1)\""))
        #expect(html.contains("value=\"\" autofocus") == false)
        #expect(html.contains("Field must be a valid email address"))
    }

    @Test func boundValueIsNotRenderedIntoPasswordInputs() throws {
        let box = HtmlCtxBox()
        let html = renderHTML { page in
            box.ids = [
                page.SecureField("Password", text: page.WString("bound-secret-1")).builderId,
                page.TextField("PIN", text: page.WString("bound-secret-2"), type: .password).builderId,
                page.TextField("Name", text: page.WString("visible-name")).builderId,
            ]
        }
        let secure = try #require(htmlCtxLine(html, tag: "input", builderId: box.ids[0]))
        let pin = try #require(htmlCtxLine(html, tag: "input", builderId: box.ids[1]))
        let name = try #require(htmlCtxLine(html, tag: "input", builderId: box.ids[2]))
        #expect(secure.contains("value=") == false)
        #expect(pin.contains("value=") == false)
        #expect(html.contains("value=\"bound-secret-1\"") == false)
        #expect(html.contains("value=\"bound-secret-2\"") == false)
        // ordinary text fields are unchanged
        #expect(name.contains("value=\"visible-name\""))
        // the page-load sync of the bound value is ignored by password inputs
        #expect(html.contains("if (_meta && _meta.source === 'initial') { return; }\n    \(box.ids[0]).value = value;"))
    }
}
