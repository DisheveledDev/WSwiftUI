//
//  Phase1SessionMenuTests.swift
//  WSwiftUITests
//
//  Phase 1 / session (PERM-9): menu entries are listed by whether the user may
//  view each page (.Content roles), not by what the current request is doing,
//  and the entry for the page being served (and its primary) is selected.
//

import Foundation
import Testing
@testable import WSwiftUI

// MARK: - Endpoints

/// Answers with a one-line description of `menuEntries`: entries are separated by " | ",
/// children are listed in brackets, and a selected entry is marked with "*".
/// For example: `Notes* | Records[List, New]`.
class P1MenuPage: CoreWebEndpoint {

    static func describe(_ entries: [MenuEntry]) -> String {
        return entries.map { entry in
            var text = entry.title + (entry.selected ? "*" : "")
            if entry.children.isEmpty == false {
                text += "[" + entry.children.map { $0.title + ($0.selected ? "*" : "") }.joined(separator: ", ") + "]"
            }
            return text
        }.joined(separator: " | ")
    }

    func menuResponse() -> HttpResponse {
        return HttpResponse().status(.ok).content(.text).body(P1MenuPage.describe(menuEntries))
    }

    override func content() -> Any? { menuResponse() }
    // the validation-failure pattern: persist() answers with the page again
    override func persist() -> Any? { menuResponse() }
}

final class P1MenuHome: P1MenuPage, WebEndpoint, WebContent, MenuIndexable {
    var controller: String? = "p1m-home"
    var method: String? = nil
    var authenticationRequired: [WebAuthenticationStatus] = [.unauthenticated]
    var menuPrimary: String = "Home"
    var menuSecondary: String? = nil
    func acceptedRoles(for action: WebRequestActivity) -> [String]? { nil }
}

final class P1MenuNotes: P1MenuPage, WebEndpoint, WebContent, MenuIndexable {
    var controller: String? = "p1m-notes"
    var method: String? = nil
    var authenticationRequired: [WebAuthenticationStatus] = [.authenticated]
    var menuPrimary: String = "Notes"
    var menuSecondary: String? = nil
    func acceptedRoles(for action: WebRequestActivity) -> [String]? { nil }
}

/// Viewers may read the records; only editors may write them.
final class P1MenuRecords: P1MenuPage, WebEndpoint, WebContent, MenuIndexable {
    var controller: String? = "p1m-records"
    var method: String? = nil
    var authenticationRequired: [WebAuthenticationStatus] = [.authenticated]
    var menuPrimary: String = "Records"
    var menuSecondary: String? = "List"
    func acceptedRoles(for action: WebRequestActivity) -> [String]? {
        action == .Content ? ["viewer", "editor"] : ["editor"]
    }
}

final class P1MenuRecordsNew: P1MenuPage, WebEndpoint, WebContent, MenuIndexable {
    var controller: String? = "p1m-records"
    var method: String? = "new"
    var authenticationRequired: [WebAuthenticationStatus] = [.authenticated]
    var menuPrimary: String = "Records"
    var menuSecondary: String? = "New"
    func acceptedRoles(for action: WebRequestActivity) -> [String]? {
        action == .Content ? ["viewer", "editor"] : ["editor"]
    }
}

/// Editors only, whatever the action.
final class P1MenuAdmin: P1MenuPage, WebEndpoint, WebContent, MenuIndexable {
    var controller: String? = "p1m-admin"
    var method: String? = nil
    var authenticationRequired: [WebAuthenticationStatus] = [.authenticated]
    var menuPrimary: String = "Admin"
    var menuSecondary: String? = nil
    func acceptedRoles(for action: WebRequestActivity) -> [String]? { ["editor"] }
}

enum P1Menu {
    static func server() -> WSwiftServer {
        let server = TestHTTP.server()
        server.register(P1MenuHome())
        server.register(P1MenuNotes())
        server.register(P1MenuRecords())
        server.register(P1MenuRecordsNew())
        server.register(P1MenuAdmin())
        server.onGetUserRoles { token, _ in
            switch token {
                case "viewer": return ["viewer"]
                case "editor": return ["editor"]
                default: return []
            }
        }
        return server
    }

    static func menu(_ server: WSwiftServer, _ method: HttpMethod, _ uri: String, as user: String) -> String {
        let response = server.respond(to: TestHTTP.request(method, uri, headers: [("Cookie", "auth=\(user)")]))
        #expect(response.status.code == 200, "\(method) \(uri) as \(user)")
        return response.bodyString
    }
}

// MARK: - Tests

@Suite("Phase 1 session: menu")
struct P1SessionMenuTests {

    @Test func postDoesNotShrinkTheMenu() {
        let server = P1Menu.server()
        let onGet = P1Menu.menu(server, .GET, "/p1m-notes", as: "viewer")
        let onPost = P1Menu.menu(server, .POST, "/p1m-notes", as: "viewer")
        #expect(onGet == "Notes* | Records[List, New]")
        #expect(onPost == onGet)
    }

    @Test func entriesStillFollowViewRoles() {
        let server = P1Menu.server()
        #expect(P1Menu.menu(server, .GET, "/p1m-notes", as: "editor") == "Notes* | Records[List, New] | Admin")
        #expect(P1Menu.menu(server, .POST, "/p1m-admin", as: "editor") == "Notes | Records[List, New] | Admin*")
        // a viewer is still not shown the editors-only page on a POST
        #expect(P1Menu.menu(server, .POST, "/p1m-notes", as: "viewer").contains("Admin") == false)
    }

    @Test func currentPageAndItsPrimaryAreSelected() {
        let server = P1Menu.server()
        #expect(P1Menu.menu(server, .GET, "/p1m-records/new", as: "viewer") == "Notes | Records*[List, New*]")
        #expect(P1Menu.menu(server, .GET, "/p1m-records", as: "viewer") == "Notes | Records*[List*, New]")
        #expect(P1Menu.menu(server, .GET, "/p1m-records?x=1", as: "editor") == "Notes | Records*[List*, New] | Admin")
    }

    @Test func publicPageSelectsItsEntry() {
        let server = P1Menu.server()
        let response = server.respond(to: TestHTTP.request(.GET, "/p1m-home"))
        #expect(response.bodyString == "Home*")
    }

    @Test func markSelectedClearsStaleSelection() {
        let child = MenuEntry()
        child.path = "/a/b"
        child.selected = true
        let primary = MenuEntry()
        primary.path = "/a"
        primary.children = [child]
        let other = MenuEntry()
        other.path = "/c"
        #expect([primary, other].markSelected(paths: ["/c"]))
        #expect(primary.selected == false && child.selected == false && other.selected)
        #expect([primary, other].markSelected(paths: ["/zzz"]) == false)
    }
}
