# WSwiftUI

A Swift package for building server-rendered, interactive web apps with a SwiftUI-style DSL.

WSwiftUI combines:
- A lightweight HTTP/WebSocket server
- Endpoint-based routing
- A fluent HTML/component builder
- Reactive variables for client-side interactivity
- Bootstrap-friendly controls and styling

---

## Table of contents

1. [Requirements](#requirements)
2. [Install](#install)
3. [Quick start](#quick-start)
4. [Core concepts](#core-concepts)
5. [Routing](#routing)
6. [Sitemaps, crawling, and SEO metadata](#sitemaps-crawling-and-seo-metadata)
7. [Building UI](#building-ui)
8. [State and data binding](#state-and-data-binding)
9. [Forms, persist, and validation](#forms-persist-and-validation)
10. [Actions and events](#actions-and-events)
11. [API endpoints and uploads](#api-endpoints-and-uploads)
12. [WebSockets](#websockets)
13. [Authentication and authorization](#authentication-and-authorization)
14. [Run the demo app](#run-the-demo-app)
15. [Project layout](#project-layout)

---

## Requirements

- Swift **6.1+**
- macOS **14+** (per `Package.swift`)

---

## Install

Add WSwiftUI to your `Package.swift` dependencies:

```swift
dependencies: [
    .package(url: "https://github.com/editfmah/WSwiftUI.git", branch: "main")
]
```

Then add the product to your target:

```swift
targets: [
    .executableTarget(
        name: "MyWebApp",
        dependencies: [
            .product(name: "WSwiftUI", package: "WSwiftUI")
        ]
    )
]
```

---

## Quick start

Create a content endpoint and register it with `WSwiftServer`:

```swift
import Foundation
import WSwiftUI

final class HomePage: CoreWebEndpoint, WebEndpoint, WebContent, MenuIndexable {
    var controller: String? = nil     // "/" route
    var method: String? = nil
    var authenticationRequired: [WebAuthenticationStatus] = [.unauthenticated]

    var menuPrimary: String = "Home"
    var menuSecondary: String? = nil

    override func content() -> Any? {
        return webpage {
            head(.title("WSwiftUI Example"))
            head(.metaViewport(content: "width=device-width, initial-scale=1"))
            head(.styleLink(href: "https://cdn.jsdelivr.net/npm/bootstrap@5.3.8/dist/css/bootstrap.min.css"))
            head(.script(src: "https://cdn.jsdelivr.net/npm/bootstrap@5.3.8/dist/js/bootstrap.bundle.min.js"))

            VStack {
                Text("Hello from WSwiftUI").font(.largeTitle).bold()
                Text("Your first endpoint is running.")
            }.padding(32)
        }
    }

    func acceptedRoles(for action: WebRequestActivity) -> [String]? {
        return nil
    }
}

let server = WSwiftServer(port: 4242, bindAddressv4: "0.0.0.0")
server.register(HomePage())

print("Server running at http://localhost:4242")
DispatchSemaphore(value: 0).wait()
```

---

## Core concepts

### 1. Endpoint-driven app structure

You create classes that conform to:
- `WebEndpoint` + `WebContent` for pages
- `WebEndpoint` + `WebApiEndpoint` for API routes

`controller` and `method` determine the route path.

### 2. Request activity lifecycle

- `GET`/`HEAD` -> `content()`
- `POST`/`PUT`/`PATCH`/`DELETE` -> `persist()` for content endpoints
- `call()` for API endpoints

### 3. Fluent DSL

Elements are composed with closures and then configured with chainable modifiers:

```swift
Text("Profile").font(.title).foreground(.blue).padding(.bottom, 12)
```

---

## Routing

Paths are assembled from `controller` and `method`:

| controller | method | path |
| --- | --- | --- |
| `nil` | `nil` | `/` |
| `"users"` | `nil` | `/users` |
| `"users"` | `"edit"` | `/users/edit` |

Wildcard routes are supported by using `*` in route registration (for example via endpoint `method = "*"`, resulting in paths like `/assets/*`).

Matching behavior:
1. Exact routes are matched first.
2. Wildcard routes are matched next.
3. More specific wildcard patterns win over broader ones.

---

## Sitemaps, crawling, and SEO metadata

`WSwiftServer` now serves framework-managed crawl endpoints:

- `/sitemap.xml`
- `/trawl-urls.txt`
- `/robots.txt`

These are generated from registered endpoints and kept current as routes are registered.

By default, public content endpoints (`WebContent` + `.unauthenticated`) are included in sitemap/trawl output.
You can customize with `SitemapIndexable`:

```swift
final class BlogPage: CoreWebEndpoint, WebEndpoint, WebContent, SitemapIndexable {
    var controller: String? = "blog"
    var method: String? = nil
    var authenticationRequired: [WebAuthenticationStatus] = [.unauthenticated]

    func sitemapEntries(baseURL: String) -> [SitemapEntry] {
        [
            SitemapEntry(url: "\(baseURL)/blog", changeFrequency: .daily, priority: 0.8),
            SitemapEntry(url: "\(baseURL)/blog/archive", changeFrequency: .weekly, includeInTrawl: false)
        ]
    }
}
```

For page metadata and social preview tags, adopt `SEOIndexable`.
The framework injects `<title>`, canonical/meta tags, Open Graph, Twitter card tags, and JSON-LD into `<head>` during render:

```swift
final class ArticlePage: CoreWebEndpoint, WebEndpoint, WebContent, SEOIndexable {
    func seo() -> PageSEO? {
        return PageSEO(
            title: "My Article",
            description: "Article summary for search and social previews.",
            canonicalPath: "/article",
            robots: "index,follow",
            openGraph: OpenGraphMetadata(
                type: "article",
                imageURL: "/assets/article-preview.png",
                siteName: "WSwiftUI"
            ),
            twitter: TwitterCardMetadata(),
            jsonLD: [
                #"{"@context":"https://schema.org","@type":"Article","headline":"My Article"}"#
            ]
        )
    }
}
```

If `publicBaseURL` is set on `WSwiftServer`, it is used for canonical/sitemap URL generation; otherwise request headers are used.

---

## Building UI

Common layout/content controls include:
- `VStack`, `HStack`, `Spacer`
- `Text`, `Link`, `Image`, `Code`
- `Card`, `Callout`, `Jumbotron`, `Badge`
- `NavBar`, `Footer`
- `Modal`, `OffCanvas`, `Alert`

Use head helpers to configure page metadata and assets:

```swift
head(.title("My App"))
head(.metaViewport(content: "width=device-width, initial-scale=1"))
head(.styleLink(href: "https://cdn.jsdelivr.net/npm/bootstrap@5.3.8/dist/css/bootstrap.min.css"))
head(.script(src: "https://cdn.jsdelivr.net/npm/bootstrap@5.3.8/dist/js/bootstrap.bundle.min.js"))
```

Useful fluent layout modifiers:
- `padding(...)`, `margin(...)`
- `frame(width:height:minWidth:maxWidth:minHeight:maxHeight:alignment:)`
- `width(...)`, `height(...)`, `minWidth(...)`, `maxWidth(...)`
- `background(...)`, `foreground(...)`, `opacity(...)`
- `deviceClass(mobile:desktop:)`, `mobileClass(...)`, `desktopClass(...)` for automatic mobile/desktop class selection

---

## State and data binding

Create reactive variables with `WBool`, `WInt`, `WDouble`, `WString`, `WArray`.

```swift
let name = WString("").name("name")
let wantsNewsletter = WBool(false).name("newsletter")
let pickerValue = WString("free").name("plan")

TextField("Name", text: name, prompt: "Jane Doe")
Toggle("Subscribe to newsletter", isOn: wantsNewsletter)

Picker("Plan", selection: pickerValue, style: .segmented(.primary)) {
    Text("Free").value("free")
    Text("Pro").value("pro")
}

Text("Welcome $0", name)
```

You can react to variable updates:

```swift
name.onValueChange([
    .text(ref: "live_name", "Name updated")
])
```

---

## Forms, persist, and validation

`Form` automatically wires browser-side validation from `.validate(...)` modifiers.

```swift
override func content() -> Any? {
    let email = WString("").name("email")
    let password = WString("").name("password")

    return webpage {
        Form(action: self.path, method: .post) {
            TextField("Email", text: email, type: .email, prompt: "name@company.com")
                .validate([.notEmpty, .validEmail])

            SecureField("Password", text: password, prompt: "Required")
                .validate([.notEmpty, .atLeast(8)])

            Button("Sign in", type: "submit").variant(.primary)
        }
    }
}

override func persist() -> Any? {
    guard let email = data.string("email"),
          let password = data.string("password"),
          !email.isEmpty,
          !password.isEmpty else {
        return redirect(self.path)
    }

    return HttpResponse().status(.ok).body("Signed in")
}
```

To check the submitted values on the server and show the form again with the user's input when a check fails, use `validateData(_:)` in `persist()` and return `content()`:

```swift
override func persist() -> Any? {
    guard validateData([
        .named("email", [.notEmpty, .validEmail]),
        .named("note", []),                 // no conditions: only keeps what was typed
    ]) else {
        return content()                    // same page; typed values and messages are shown again
    }
    // save, then redirect
    return redirect("/done")
}
```

- Every field listed in `validateData` keeps its submitted value when the form is shown again, whether it passed or failed, so redirect after a successful save rather than returning `content()`. Password fields are never filled in again, including a `TextField` made a password field with `.type(.password)`.
- A listed field that was not submitted fails with "This field is required".
- A `Toggle` submits like a plain checkbox: `<name>=on` when ticked and nothing when not, so `.named("terms", [.notEmpty])` requires it to be ticked.
- A bound variable's hidden input posts under its `.name(...)`, unless another control in the same form already submits that name.

---

## Actions and events

Attach behavior with event helpers like `onClick`, `onChange`, `onInput`, etc.  
Actions are declared with `WebAction`.

```swift
let showModal = WBool(false)

Button("Open modal")
    .variant(.primary)
    .onClick(.setVariable(showModal, to: true))

Modal(id: "welcomeModal", isPresented: showModal) {
    ModalDialog {
        ModalContent {
            ModalHeader {
                ModalTitle {
                    Text("Welcome")
                }
            }
            ModalBody {
                Text("This modal is driven by a bound variable.")
            }
        }
    }
}
```

State-driven overloads are available for:
- `Modal(id:isPresented:...)`
- `Sheet(isPresented:...)`
- `OffCanvas(id:isPresented:...)`
- `Alert(_:isPresented:...)`

### Element ids and page scripts

- Every element gets a `builderId` such as `kq3xa_1f`: a namespace, an underscore and a counter. It is also the element's CSS class.
  - By default the namespace is random for each request, so HTML from two requests inserted into one page never shares an id.
  - Set `elementIdNamespace` (letters and digits, starting with a letter) on an endpoint to render byte-identical HTML for the same page, for example for snapshot tests or ETags. Give each endpoint whose HTML ends up in the same browser page its own namespace.
- All page scripts run at the end of `<body>`, after every element exists. No `<script>` sits between elements, so Bootstrap's sibling selectors (list-group borders, button-group corners) work.
- An element is available as a JavaScript global named after its `builderId` only when page code names it: a script, an inline `on…` handler, a `.pair`/`.data` attribute value, a `javascript:` URL, raw `.custom` attributes or HTML, or head code. If your code builds the name at runtime, look the element up with `document.getElementsByClassName(builderId)[0]`.
- The framework's own scripts share one `<script>` element, and each part runs in its own `try`/`catch`. Scripts you add (`.script(...)`, `.domLoadedScript`, `WebAction.script`, `.handleResponse`, …) each get their own `<script>`, so a mistake in one doesn't stop the others. Each DOMContentLoaded script runs in its own function: `var`s are not shared between them, and a `return` ends only that script.
- A caught exception goes to the browser's `reportError`, so it is logged as uncaught and `window` `error` listeners (error monitoring) still see it. A `reportError` function your page defines itself is never called; the exception then goes to `console.error`.
- Inline handlers and `.onClick` actions work once the browser reaches the scripts at the end of `<body>`; until then, on a slow connection, a typed value can be reset by the page-load sync.
- `.hidden()` hides an element with Bootstrap's `d-none`, the class the `.show(ref:)`/`.hide(ref:)` actions toggle. For content that only screen readers should read, use `.visuallyHidden()`.

---

## API endpoints and uploads

Implement an API endpoint with `WebApiEndpoint`:

```swift
final class UploadAPI: CoreWebEndpoint, WebEndpoint, WebApiEndpoint {
    var controller: String? = "api"
    var method: String? = "upload"
    var authenticationRequired: [WebAuthenticationStatus] = [.unauthenticated]

    func call() -> Any? {
        guard let file = data.file("files[]"),
              let bytes = file.data else {
            return HttpResponse().status(.badRequest).body("No file")
        }

        return HttpResponse().status(.ok).body("Received \(bytes.count) bytes")
    }

    func acceptedRoles() -> [String]? {
        return []
    }
}
```

Client-side uploader:

```swift
FileUploader(action: "/api/upload") {
    Text("Drop files here")
}
```

---

## WebSockets

Server endpoint:

```swift
final class TimeSocket: CoreWebsocketEndpoint, WebEndpoint {
    var controller: String? = "ws-time"
    var method: String? = nil

    override func onTick(connection: WebSocketConnection) {
        try? connection.sendText("{\"time\":\"\(Date())\"}")
    }
}
```

Client usage in page DSL:

```swift
let currentTime = WString("")

Text("Server time: $0", currentTime)
WebSocket(url: "ws://localhost:4242/ws-time", onRecieve: [
    .extractJSONInto(key: "time", into: currentTime)
])
```

---

## Authentication and authorization

Use `authenticationRequired` on endpoints and role callbacks on the server:

```swift
server.onGetUserRoles { token, endpoint in
    guard token != nil else { return nil }
    return ["admin"]
}
```

In content endpoints:
- `acceptedRoles(for: .Content)` and `acceptedRoles(for: .Persist)` can return role requirements.

In API endpoints:
- `acceptedRoles()` can return role requirements.

`MenuIndexable` endpoints are also filtered by auth/roles when the menu tree is built.

### Sessions

Log a user in from a content endpoint with `authenticateSession(token:expiry:)` and out with `deauthenticateSession()`:

```swift
authenticateSession(token: newToken, expiry: Date() + 86400)   // cookie lasts until expiry
authenticateSession(token: newToken)                           // cookie lasts maxAge and slides
deauthenticateSession()                                        // expires the cookie
```

Sessions are stateless: the cookie holds your token, and `onGetUserRoles` checks it on every authenticated request. Clearing the cookie on logout only affects the browser that receives the response. **Register `onSessionEnded` and revoke the token there**, so a copied cookie or another tab can't keep using it:

```swift
server.onSessionEnded { token in
    Database.removeUserToken(token: token)
}
```

The handler gets the token in effect, and also the cookie's token when that is a different one (a Bearer header or `?token=` took precedence over it, or `authenticateSession` set a new token earlier in the request), since the logout clears the cookie either way. On a public `/logout` the token hasn't been checked by `onGetUserRoles`, so treat it as a key to delete, not as proof of who the user is.

- `Set-Cookie` is only sent when the session changes: on login and logout, when a no-expiry session slides on an authenticated page, and when an authenticated page rejects the cookie's token. Public pages and anonymous requests never get a session cookie.
- A token sent as `Authorization: Bearer <token>` authenticates the request but never sets a cookie. Other `Authorization` schemes (such as Basic auth added by a proxy) are ignored. A `?token=` query parameter is ignored unless `acceptQueryToken` is set.
- The cookie is configured with `server.session`. The defaults:

```swift
server.session = WebSessionConfig(cookieName: "auth", secure: .auto, sameSite: .lax,
                                  maxAge: 3600, sliding: true, acceptQueryToken: false)
```

  With `secure: .auto`, cookies are `Secure` when `publicBaseURL` starts with `https://` or the request's `X-Forwarded-Proto` is `https`. Use `.always` or `.never` to override this. A deployment whose `publicBaseURL` says `https://` but which is reached over plain http will not keep a session.

  Set `server.session` before `server.acceptQueryToken`: assigning `session` replaces the whole configuration.
- A response to a request whose credential `onGetUserRoles` accepted (an endpoint that requires `.authenticated`), and a login or sliding renewal, carries `Cache-Control: private` unless it sets Cache-Control itself, so a shared cache doesn't store one user's page for others. Public endpoints never check the credential, so their responses are not marked: a public page that shows something based on `authenticationIdentifier` should set `Cache-Control: private` (or `no-store`) itself.

---

## Run the demo app

This repository includes an executable demo target:

```bash
swift run WSwiftUITest
```

Then open: `http://localhost:4242`

---

## Project layout

| Path | Purpose |
| --- | --- |
| `Sources/WSwiftUI/WebServer.swift` | Server setup, endpoint registration, auth hooks, dispatch |
| `Sources/WSwiftUI/endpoints` | Endpoint base types and protocol contracts |
| `Sources/WSwiftUI/WebUI/objects` | UI/component DSL (forms, layout, modal, picker, etc.) |
| `Sources/WSwiftUI/WebUI/properties` | Fluent visual/layout modifiers |
| `Sources/WSwiftUI/WebUI/actions` | `WebAction` behavior model |
| `Sources/WSwiftUI/WebUI/events` | Event listener helpers |
| `Sources/WSwiftUI/WebUI/variables` | Reactive variable primitives and live-update wiring |
| `Sources/WSwiftUITest` | Demo app with pages, API endpoint, and WebSocket example |

---

## Development notes

- Prefer passing structure-defining inputs in factory methods (for example `Modal(id:...)`, `Picker(selection:...)`).
- Use fluent modifiers for styling and optional behavior.
- Name bound variables used in forms (`.name("fieldName")`) so values are posted as expected.
- Keep Bootstrap JS/CSS available if you use Bootstrap-dependent components (modal, offcanvas, dropdowns, etc.).
- Pages render with `<!DOCTYPE html>` in standards mode, as Bootstrap 5 expects. Percentage heights need a parent with a definite height, and CSS lengths in raw styles need units (`.style("width: 300px")`, not `.style("width: 300")`).
- Builder misuse (for example a `CardBody` outside a `Card`) never crashes the server. The part is still rendered after a `<template data-wsui-misuse>` comment, and a `[WSwiftUI] Builder misuse …` line is logged once per endpoint type.
- State can be declared anywhere in `content()`, including before `webpage { }`.
