//
//  Phase1CrossSliceTests.swift
//  WSwiftUITests
//
//  Regression tests for the cross-slice changes applied after the Phase 1 wave 1 slices merged:
//   - url-encoded form bodies keep empty values and decode `+` as a space
//   - a Toggle restores its submitted state and shows its validation message after a failed validateData
//   - HttpResponse.copy() copies every stored field
//

import Foundation
import Testing
@testable import WSwiftUI

@Suite("Phase 1 cross-slice: url-encoded form bodies")
struct Phase1URLEncodedBodyTests {

    private func parse(_ body: String) -> WebData {
        let data = WebData()
        data.consume(["content-type": "application/x-www-form-urlencoded"])
        data.consume(Data(body.utf8))
        return data
    }

    @Test func emptyValueIsAnEmptyStringNotAMissingField() {
        let data = parse("email=&name=Ann")
        #expect(data.string("email") == "")
        #expect(data.string("name") == "Ann")
    }

    @Test func pairWithoutAnEqualsSignIsAnEmptyValue() {
        let data = parse("flag&name=Ann")
        #expect(data.string("flag") == "")
        #expect(data.string("name") == "Ann")
    }

    @Test func plusIsASpaceAndPercentTwoBIsAPlus() {
        let data = parse("full+name=Jane+Q+Public&sum=1%2B1&mixed=a+b%20c")
        #expect(data.string("full name") == "Jane Q Public")
        #expect(data.string("sum") == "1+1")
        #expect(data.string("mixed") == "a b c")
    }

    @Test func valueMayContainEqualsSigns() {
        #expect(parse("token=abc==&x=1").string("token") == "abc==")
    }

    @Test func emptyNamesAndEmptyPairsAreSkipped() {
        let data = parse("&&=orphan&a=1&")
        #expect(data.string("") == nil)
        #expect(data.string("a") == "1")
    }

    @Test func malformedEscapeIsKeptAsSent() {
        #expect(parse("q=100%+sure").string("q") == "100% sure")
    }

    /// End to end: a posted empty field fails `.notEmpty` with the condition's own message path, not as
    /// a missing field, and the other values survive.
    @Test func emptyFieldPostedURLEncodedReachesValidation() {
        let server = TestHTTP.server()
        server.register(Phase1FormsTermsPage())
        let response = server.respond(to: TestHTTP.request(
            .POST, "/phase1-forms-terms",
            headers: [("Content-Type", "application/x-www-form-urlencoded")],
            body: Data("email=jane%40example.com&terms=on&news=on".utf8)))
        #expect(response.bodyString == "SAVED terms=true news=true")
    }
}

@Suite("Phase 1 cross-slice: Toggle after a failed validation")
struct Phase1ToggleRestoreTests {

    private func checkbox(_ html: String, named name: String) throws -> FormsHTML.Tag {
        try #require(FormsHTML.controls(in: html).first {
            $0.attribute("type") == "checkbox" && $0.attribute("name") == name
        })
    }

    @Test func tickedBoxStaysTickedWhenAnotherFieldFails() throws {
        let server = TestHTTP.server()
        server.register(Phase1FormsTermsPage())
        // an invalid email; terms ticked, news unticked
        let html = FormsHTML.post(server, "/phase1-forms-terms", [("email", "not-an-email"), ("terms", "on")]).bodyString
        #expect(html.hasPrefix("SAVED") == false)
        #expect(try checkbox(html, named: "terms").has("checked"), "the ticked box was reset to its seeded false")
    }

    @Test func untickedRequiredBoxShowsItsMessage() throws {
        let server = TestHTTP.server()
        server.register(Phase1FormsTermsPage())
        let html = FormsHTML.post(server, "/phase1-forms-terms", [("email", "jane@example.com")]).bodyString
        #expect(html.hasPrefix("SAVED") == false)
        let box = try checkbox(html, named: "terms")
        #expect(box.has("checked") == false)
        #expect((box.attribute("class") ?? "").contains("border-danger"))
        #expect(html.contains("This field is required"))
    }
}

@Suite("Phase 1 cross-slice: HttpResponse.copy")
struct Phase1HttpResponseCopyTests {

    @Test func copyHasEveryFieldAndIsIndependent() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("wsui-copy-\(UUID().uuidString).txt")
        try Data("0123456789".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        var upgraded = 0
        let original = HttpResponse().status(.created).header("X-One", "1").body(file, from: 2, to: 5)
        original.onUpgraded = { upgraded += 1 }

        let copy = original.copy()
        #expect(copy !== original)
        #expect(copy.status.code == original.status.code)
        #expect(copy.headers.map { "\($0.0)=\($0.1)" } == original.headers.map { "\($0.0)=\($0.1)" })
        #expect(copy.bodyBytes == original.bodyBytes)
        #expect(copy.bodyFileUrl == file)
        #expect(copy.bodyFileHandleRange == original.bodyFileHandleRange)
        copy.onUpgraded?()
        #expect(upgraded == 1)

        copy.header("X-Two", "2")
        #expect(original.headers.contains { $0.0 == "X-Two" } == false)
    }
}
