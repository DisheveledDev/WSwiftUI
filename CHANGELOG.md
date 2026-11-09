# Changelog

## Unreleased: session and render correctness (Phase 1)

Logout now works, login expiry is honoured, and cookies are only sent when the session changes. Pages render in standards mode with a doctype, state declared before `webpage {}` is no longer lost, and DSL misuse never crashes the server. Element ids are short and namespaced, every script runs from the end of `<body>`, and pages are 16–57% smaller. Forms keep what the user typed after a failed validation, and `liveUpdate` works.

Most apps need no code changes:
- **Register `onSessionEnded` to revoke tokens** (see Sessions).
- Check page layouts once (see "Standards mode" below).
- If your own JavaScript builds an element's global name at runtime, look the element up by class instead (see "Element ids and scripts").

### Sessions

- **Logout logs out.**
  - `deauthenticateSession()` expires the session cookie: an empty value, `Max-Age=0`, an `Expires` in 1970, and the same Path, SameSite and Secure.
  - Previously the request's token was written back.
  - If one request calls both `authenticateSession` and `deauthenticateSession`, the last call wins.
- **New `server.onSessionEnded { token in ... }`: register it, revoking the token there.**
  - It is called from `deauthenticateSession()`, synchronously and at most once per token per request. It receives the token in effect: the one set earlier in the same request by `authenticateSession`, otherwise the request's cookie, Bearer or accepted `?token=` token.
  - The logout clears the session cookie, so when the cookie holds a different token from the one in effect (a Bearer header or `?token=` took precedence over it, or `authenticateSession` set a new token earlier in the request) the handler is called with the cookie's token as well.
  - The token is not necessarily valid: a public endpoint such as a typical `/logout` never runs `onGetUserRoles`. Treat it as a key to delete, not as proof of identity.
  - Sessions are stateless, so clearing the cookie only affects the browser that receives the logout response. A request still carrying the old cookie (an XHR in flight, another tab, a copied cookie) is accepted again unless the token is revoked:

    ```swift
    server.onSessionEnded { token in Database.removeUserToken(token: token) }
    ```

  - Until a handler is registered, the server logs one warning the first time a session ends.
  - It is not called when `onGetUserRoles` rejects a token.
- **`authenticateSession(token:expiry:)` honours `expiry`.**
  - The cookie gets `Max-Age = expiry - now`, clamped to at least 0.
  - A companion cookie `<cookieName>_exp=<unix seconds>` (HttpOnly, same attributes) remembers the expiry, so later requests never shorten or extend that session.
  - Without `expiry`, the cookie lasts `maxAge` (3600 s by default) and slides.
  - A malformed companion is ignored. An expired one makes the next accepted request clear both cookies.
  - The companion only controls the browser's cookie lifetime. Token validity is still checked by `onGetUserRoles`.
- **`Set-Cookie` is sent only when the session changes.**
  - One finalizer applies the session decision to every response: pages, JSON, `redirect(_:)`, a hand-built `HttpResponse` returned from `content()`/`persist()`/`call()` (which used to drop `authenticateSession`), 403/404 and the auth-failure 302.
  - Anonymous responses no longer get `Set-Cookie: auth=; Max-Age=3600`.
  - Bearer and `?token=` requests never get a session cookie by themselves.
  - Public endpoints never validate the cookie, so they neither renew nor clear it.
  - Sliding renewal happens only on `[.authenticated]` endpoints whose `onGetUserRoles` accepted the cookie token, including their 403/404 answers. It never happens for a session that has an explicit expiry.
  - A cookie token rejected on an `[.authenticated]` endpoint is still cleared. A rejected Bearer token, or a request with no token, leaves the cookie alone.
  - `redirect(_:)` no longer sets cookies itself; the server adds them after the endpoint returns.
  - A response that already sets the session cookie is left as it is. A shared `HttpResponse` instance is copied before cookies are added.
- **Signed-in responses are `Cache-Control: private`.** A response to a request whose credential `onGetUserRoles` accepted, and one that starts or renews a session, gets `Cache-Control: private` unless it sets Cache-Control itself. Responses used to carry a Set-Cookie, which most shared caches won't store; now that many authenticated pages have none, this keeps a shared cache (a CDN, or nginx `proxy_cache`) from storing one user's page and serving it to others.
- **Secure cookies.**
  - `WebSessionConfig.secure` defaults to `.auto`. It adds `Secure` when `publicBaseURL` was given with an explicit `https://`, or when the first `X-Forwarded-Proto` value (or the first `Forwarded` element's `proto=`) is `https`.
  - `.always` and `.never` override it.
  - Cookies were never Secure before. A deployment with an https `publicBaseURL` that is reached over plain http will no longer keep a session.
- **Basic auth at a proxy no longer logs users out.**
  - An `Authorization` header that is not `Bearer <token>` is ignored; `?token=` (when enabled) and then the cookie authenticate the request.
  - An empty cookie value (`auth=`) is no longer treated as a token.
- **New `WebSessionConfig`.** The defaults are:

  ```swift
  server.session = WebSessionConfig(cookieName: "auth", secure: .auto, sameSite: .lax, maxAge: 3600, sliding: true, acceptQueryToken: false)
  ```

  - `server.acceptQueryToken` still works and forwards to `session.acceptQueryToken`. Assigning `server.session` afterwards replaces it, so set `session` first or pass `acceptQueryToken:` to `WebSessionConfig`.
  - `SameSite` is `.lax`, `.strict` or `.noRestriction` (`SameSite=None`, always `Secure` under `.auto`).

### Menus

- Menu entries are filtered with `acceptedRoles(for: .Content)` whatever the request is doing, so the navbar no longer loses entries after a POST.
- `MenuEntry.selected` is set for the current page's entry and its primary entry, so `NavBarItem(..., active: entry.selected)` highlights the current page.
- `NavDropdown` and `NavDropdownItem` take `active:` too (`active` on the toggle; `active` and `aria-current="page"` on the item), so pages under a dropdown can be highlighted with `entry.selected` like top-level ones.

### Documents

- **`<!DOCTYPE html>` and `<meta charset="utf-8" />`.**
  - Pages render in standards mode, as Bootstrap 5 requires.
  - The charset meta is always the first element in `<head>`. A page-supplied `.metaCharset(...)`, a `.metaHttpEquiv(httpEquiv: "Content-Type", ...)` or a custom `<meta charset>` head entry is not repeated. A `.metaCharset` naming another encoding, and any `http-equiv` or custom charset declaration, is logged once per endpoint type and kind of declaration.
- **State declared before `webpage {}` / `Template {}` is rendered.** Every element created in `content()` is emitted once, in creation order. Previously the first one created became an invisible root: it was never emitted, and its `addCallback…`/`updateWebVariable…` functions were undefined, which threw a `ReferenceError` in the browser. This affected 5 of the 10 demo routes. This also applies to pages that return a container without `webpage {}`: the container's own element (its classes, id, style, or `<form>`) is now emitted, not only its children.
- **`webpage {}` is a fragment.**
  - Its children go straight into `<body>`. The stray `<div name="HTML" lang="en">` is gone.
  - Scripts attached to it (`.script`, `.domLoadedScript`) are now emitted. Tag attributes set on it are ignored.
  - `parent` is never `nil`: with no open container it returns the document root.
- **Void elements have no end tag.** `<input>`, `<img>`, `<br>`, `<hr>`, `<meta>`, `<link>` and the other void elements no longer get one. A stray `</br>` used to produce a second line break.
- **One failing DOMContentLoaded script no longer stops the rest.** Each runs in its own function inside `try`/`catch`, so a `return` or an exception ends only that script, and `var`s, `let`/`const` names and functions are no longer shared between them.
- **Rendering is pure.** `renderWebPage()` gives the same result when called twice; page-load syncs and DOMContentLoaded scripts are no longer duplicated.
- **Cleaner markup.** An element never carries the same attribute twice (the first wins, as in browsers), repeated class tokens are emitted once, head attribute dictionaries are written in sorted order, and the `validation` attribute lost its leading space.

### Element ids and scripts

- **Element ids are short, namespaced and never collide.**
  - `builderId` (also the element's CSS class) is now `<namespace>_<n>`, e.g. `kq3xa_1f`, instead of 12 random hex characters, which were occasionally as short as 2 (`ef`) and could match a Bootstrap class or a browser global.
  - It is always a valid JavaScript identifier and CSS class, unique in the page, and never a Bootstrap class or a browser global.
  - The namespace is random for each request, so HTML from different requests inserted into one page (`showModal(ref:contentURL:)`, fetched partials) never shares ids.
- **New `CoreWebEndpoint.elementIdNamespace: String?`.** Set a fixed namespace (letters and digits, starting with a letter) to render byte-identical HTML for the same page, e.g. for snapshot tests or ETags. Give each endpoint whose HTML ends up in the same browser page its own namespace.
- **Every script runs from the end of `<body>`.**
  - No `<script>` sits between elements any more, so Bootstrap's sibling selectors work: list-group items get single borders and button groups keep their rounded corners.
  - Element scripts run after the whole body is parsed, in the same order as before, so they can refer to elements declared after them.
  - A 1,000-row table goes from 21,002 inline scripts (4.5 MB) to none (1.9 MB); demo pages are 16–33% smaller.
- **Only elements that page code names become globals.**
  - An element is available as the global `<builderId>` when a script, an inline `on…` handler, a `.pair`/`.data` attribute value, a `javascript:` URL, a raw `.custom` attribute, raw HTML or head code names its id.
  - Code that builds the name at runtime from anything else (`window['ns_' + n]`) must look the element up with `document.getElementsByClassName(builderId)[0]`.
- **Framework scripts are isolated from each other and from yours.**
  - The framework's scripts share one `<script>` element, each part in its own `try`/`catch`, so one failing part doesn't stop the rest. A caught exception is passed to the browser's `reportError`, which logs it as uncaught and fires `window` `error` listeners, so error monitoring (Sentry and the like) still sees it. Your DOMContentLoaded scripts are reported the same way. Browsers without `reportError`, and pages that define a `reportError` function of their own (which the framework never calls), get `console.error`. The reporting function is `__wsuiReport`, defined once at the top of the page's first framework `<script>`.
  - When an app gives an element a `builderId` that isn't a plain identifier (a UUID, say), every script on that page gets a `<script>` element of its own, as before Phase 1, so a syntax error from that id can't stop the others.
  - A script containing `<!--` (with a later `<script`, it would stop `</script>` from ending the element and swallow the rest of the page) is followed by a `//-->` comment before its end tag, so it always ends where it should.
  - Scripts added from app code (`element.script(...)`, `addAttribute(.script/.domLoadedScript)`) and scripts containing `WebAction.script`, `.handleResponse`, `.setVariableFromExpression` or `.animate` code each get a `<script>` element of their own, unwrapped as before. A syntax error in them can't stop the framework's scripts.
  - `WebElement.addAttribute(_:file:)` and `WebElement.script(_:file:)` gained a defaulted `file: StaticString = #fileID` parameter that tells app code from framework code. Leave it defaulted. Calls are unchanged, but an unapplied reference such as `let add = element.addAttribute` or a protocol requirement `func script(_:) -> Self` that these methods used to satisfy no longer compiles; the same goes for `liveUpdate(...)` and its new `writeDebounceMilliseconds:` parameter. A subclass member named `elementIdNamespace` clashes with the new property. `NavDropdown` and `NavDropdownItem` gained an `active:` parameter, which changes their function types in the same way.
- **Inline handlers need the end-of-body script.** An `oninput`/`onclick` attribute that calls `updateWebVariable…` throws a `ReferenceError`, and `.onClick` actions aren't attached, until the browser has reached the script block at the end of `<body>`. On a slow connection a user can type into a control before that; the page-load sync then sets it back to the rendered value.
- **Compiled action variables are deterministic.** `postData`, `xhr`, `randomIndex`, `baseUrl`, … are named after the element (`<builderId>_<n>`) instead of random UUIDs. Raw-JS action code is preceded by the comment `/*<wsui:raw>*/` in `CompileActions` output; the page renderer removes it.

### Forms and variables

- **A form re-rendered after a failed validation keeps what the user typed.**
  - `validateData(_:)` records the submitted value of every field it lists, passing or failing, and the bound controls show it again.
  - To keep a field without validating it, list it with no conditions: `.named("note", [])`.
  - Password inputs are still never re-filled. That now also holds for an input made a password input after it was created (`TextField(binding:).type("password")`, `.type(.password)` or `.addAttribute(.pair("type", "password"))`): its variable, hidden input and page-load sync are emptied, and the submitted value is dropped so a later control bound to the same name doesn't show it, as with `SecureField`.
  - Such an input is now actually a password input: an input's last `type` wins. `TextField` sets one itself, so a later `.type(...)` used to be ignored and the field rendered `type="text"`, showing the password in clear text.
  - Values are recorded whether or not validation passes, so a `persist()` that re-renders the page after a successful save shows the form filled in. Redirect after saving (`return redirect(...)`) or clear the variables.
- **`validateData(_:)` checks every listed field.** A field that was not submitted fails with "This field is required" instead of silently stopping the check.
- **A variable's hidden input submits under one name, with its value.**
  - `WString`, `WInt`, `WDouble`, `WBool` and `WArray` render one `name` (the builderId, or the `.name(...)` given) and an escaped `value=` holding the current value: numbers and booleans as text, arrays and objects as JSON.
  - A carrier such as `_ = WString(record.id).name("record")` inside a `Form` now posts `record=<id>`.
- **A field is never posted twice.**
  - A variable's hidden input leaves its field to any other control in the same form that submits the same name. That includes bound text fields, pickers, a `Toggle`'s checkbox, and hand-made named inputs, selects and textareas. Buttons don't count.
  - Hidden inputs no longer post values under random builderIds.
- **`Toggle` submits like a plain checkbox.**
  - A ticked box posts `<name>=on`; an unticked box posts nothing.
  - So `.named("terms", [.notEmpty])` fails when the box is unticked, and `data.bool(name)` is `nil`.
  - After a failed validation, a ticked box stays ticked and a required box shows its message.
- **One `name` and one `value` per element.** `.name(...)`/`.value(...)` replace any earlier `.name`/`.value` or `.pair("name"|"value", …)`, and each is rendered once.
- **`liveUpdate` works.**
  - The polling `ReferenceError` that also stopped every later page-load script is gone.
  - The page-load sync is no longer sent as an edit, and the first real edit is no longer dropped.
  - Writes are debounced (the new `writeDebounceMilliseconds:` parameter, 300 ms by default) and sent one at a time. An edit not yet sent goes out with `keepalive` when the page is left.
  - Stale or out-of-order answers are ignored. A read never overwrites an edit the server hasn't confirmed.
  - A `204` or an empty 2xx answer is a success with nothing to apply.
- **New `onLiveUpdateError(_:)`** runs actions when the server returns `errors` for the variable or the request fails. `_eventPayload` carries `name`, `message`, `status` and `reference`.
- **liveUpdate values are validated as sent.** Array and object values in a `WebVariableTransaction` are validated as JSON text, so `.validJSON` and `.notEmpty` work on them.

### Builder

- **DSL misuse never crashes the server.**
  - The 28 `fatalError` guards in Modal, Carousel, Table, OffCanvas, Progress, Card, Pagination, ListGroup and Accordion are replaced by a diagnostic.
  - The misplaced part is still rendered. It is preceded by `<template data-wsui-misuse><!-- WSwiftUI: … --></template>`, and a `[WSwiftUI] Builder misuse …` line is logged once per endpoint type and guard site.
- **Compound controls find their parts through wrappers.** For example, `Card { VStack { CardBody { … } } }` now works. Wrong nesting within one control, such as a `CardHeader` inside a `CardBody`, is still reported.
- **Tables are checked the way browsers parse them.**
  - `TableHeader`/`TableBody` must be direct children of a `Table`, a `Row` of a `TableHeader`/`TableBody`, and a `Cell` of a `Row`.
  - Anything else declared directly inside them is reported, e.g. a `Form` around a `Row`. Browsers move such elements out of the table, so a per-row form ends up empty.
  - Put a per-row `Form` inside a `Cell`.
- **Every container unwinds the builder stack to itself.** All containers in WebUI/objects, `webpage {}` included, open their element with `withParent`, so a nested builder that leaves something open can no longer capture the rest of the page. `NavBar`, `Breadcrumb` and `Jumbotron` used to pop the wrong elements and stay open themselves. Valid pages render byte-for-byte as before.
- **Fixed crashes:**
  - `.frame(alignment:)` and `.frame(fillWidth:fillHeight:alignment:)` recursed infinitely.
  - `ProgressBar(_:max: Double)` crashed on NaN or infinite values.
  - `CarouselIndicators(count:)` crashed on a negative count.
  - `Image.reloadImage(seconds:)` crashed on NaN (now reported as misuse) and on infinite or huge intervals (now clamped to the browser's maximum).
  - `Accordion.expandItem(at:)` with `Int.max` crashed.
- **Fixed CSS:**
  - `radius(.topLeft, n)` and the other corners emitted the invalid `border-topleft-radius`.
  - `top/bottom/start/end(.auto)` emitted the nonexistent class `top-auto`; they now emit inline `top: auto` and equivalents.
  - `Cell.align("left"|"right")` and `Card.textAlign(…)` emitted Bootstrap 4 classes; they now emit `text-start`/`text-end`.
  - A gradient with a single colour is now valid CSS.
  - `backgroundImage(_:)` writes a quoted, escaped `url("…")`.
- **No duplicate class tokens.** Image, Link, Audio, Spinner, Toggle, bound and formatted Text, and Accordion no longer repeat their builderId class, and Card no longer repeats `card`.
- **Bootstrap 5.3 classes.**
  - `jumbotron`, `breadcrumb-container`, `btn-group-toggle`, `navbar-light` and `font-weight-light`, which Bootstrap 5.3 does not define, are no longer emitted. The validation message uses `fw-light`.
  - A disabled `ListGroupItem` gets `.disabled` and `aria-disabled="true"`; it used to get only a `disabled` attribute on the `<li>`, which neither styled nor blocked it.
  - `WebLabelElement.textAlign("left"/"right")` gives `text-start`/`text-end`.
- **Accordion.**
  - Item content is placed inside `.accordion-body`, and `Accordion.alwaysOpen(true)` works.
  - Item ids are derived from builderIds (`<accordion>-item-<item>`) instead of random UUID characters.
  - `expandFirst(_:)` / `expandItem(at:expanded:)` render Bootstrap 5.3's open-item markup (no `collapsed`, `aria-expanded="true"`, panel `show`) instead of toggling `show` from a script, which left the button marked collapsed. They count the accordion's own items through wrappers.
  - On an accordion without items (e.g. built from an empty list), and when closing an item that doesn't exist, they do nothing. Opening a negative index or one past the last item is reported as builder misuse.
- **OffCanvas.**
  - `OffCanvasFooter` uses `wsui-offcanvas-footer mt-auto flex-shrink-0 p-3 border-top` instead of the non-existent `offcanvas-footer`, so it is pinned to the bottom of the panel, padded and separated like a modal footer.
  - The header's close button is `type="button"`; inside a form it used to submit it.
  - The first `OffCanvasTitle` gets the `<id>Label` id that `aria-labelledby` names, and a panel without a title has no `aria-labelledby`.
- **Spinner.** `.size(.large)` is Bootstrap's documented inline `width: 3rem; height: 3rem` instead of the undefined `spinner-border-lg` (which rendered at the default size). `.type(_:)` replaces the type instead of adding a second one, and a small growing spinner gets `spinner-grow-sm`.
- **Segmented `Picker`.** The bound hidden input follows the button group instead of being its last child, so the last button keeps its rounded corners.
- **FileUploader.** The progress bar is inside its track; it used to be a separate bar below an empty track.
- **Jumbotron.** `bgImageURL` is written as an escaped CSS string, so a quote in the URL can no longer inject CSS.
- **`Picker(type: .colorPicker)`** (not implemented) is reported as builder misuse instead of silently dropping its content, and its variable still submits.
- **Deterministic JSON.** Chart data and FileUploader `extraFields` are encoded with sorted keys, so the same page renders the same bytes.
- **`.hidden()` hides.**
  - `hidden()`, `hidden(true)` and `hidden(WBool)` now use `d-none` (`display: none`), the same class the `.show(ref:)`/`.hide(ref:)` actions use. The no-argument call used to do nothing, and the others used `visually-hidden`.
  - The `.hidden(ref:_:)` action toggles `d-none` too. Un-hiding also removes `visually-hidden` and an inline `display: none`.
  - New `visuallyHidden(_:)` for screen-reader-only content, which is what `hidden(true)` used to do.
  - `hidden(_: WebAction)` is deprecated; it never did anything.

### Actions

- **`.showModal(ref:)` / `.hideModal(ref:)` work.** They called a `<md5>ModalDialog` global that was never defined (a `ReferenceError`); they now use `bootstrap.Modal.getOrCreateInstance`. `.showModal(ref:contentURL:)` still inserts the fetched HTML without running its scripts.
- **`.spinnerSet(...)`** clears the inline size before applying the new one: `.small` adds `spinner-border-sm`/`spinner-grow-sm` to match the type, `.large` sets the 3rem inline size, and the label is found by `.visually-hidden`.
- **`.load(ref: nil, url:)`** sets the element's `src`. It used to call `src` as a function, which threw.
- **`.addToArray`, `.removeFromArray` and `.toggleArray` work.** They only acted on a variable holding JSON text, but a `WArray` holds a JavaScript array, so they did nothing. They now copy the array, change it and update the variable through its updater, so bound controls and the hidden input follow. A `WArray` gets an array back; a `WString` holding JSON text (or nothing) gets JSON text back.
- **`.extractJSON(key:actions:)` works.** Its nested actions always saw `null`: the extracted value was declared with `var result`, which hid the outer `result` before it was read.
- **`.setVariableName(_:to:)` works.** It called a `set<md5>` function that was never defined (a `ReferenceError`). It now finds the variable by the name given with `.name(...)`, which the variable's hidden input keeps in a new `data-wsui-name` attribute.
- **`.post(...)` and `.get(...)` with `resultInto:`** update the variable through its updater instead of assigning its global, so bound controls, the hidden input and callbacks see the result.
- **`.scrollTo(ref: nil, ...)`** scrolls the element itself. It looked the element up by id, which it doesn't have, and threw.
- **`.showOffCanvas`/`.hideOffCanvas`, `.carouselNext`/`.carouselPrev`/`.carouselTo`, `.accordionToggle` and `.popover`** use the element's Bootstrap instance (`getOrCreateInstance`). A new instance per click meant `.hideOffCanvas` never closed a panel, repeated `.showOffCanvas` stacked backdrops that left the page dimmed and unscrollable, carousels collected competing timers, and a second `.popover` click stacked a popover that couldn't be closed.
- A segmented `Picker`'s selection update no longer adds button classes to the group `div`.

### Requests

- **Url-encoded bodies are parsed the way browsers send them.**
  - `name=` is an empty value, not a missing field, matching multipart.
  - A pair without `=` is a name with an empty value.
  - `+` decodes to a space.
  - So `validateData` reports an empty field with the condition's own message instead of "This field is required".

### Diagnostics

- `[WSwiftUI]` warnings (a missing `onSessionEnded`, builder misuse, a dropped charset declaration, a dropped header) go to standard error, which is unbuffered. They went to standard output, which is block-buffered under a service manager or in a container, so a one-time warning could be delayed or lost. A closed standard error, or a pipe whose reader has gone, loses the line without affecting the server.
- App-supplied text quoted in a warning has control characters and line separators replaced, so it can't forge log lines. A dropped charset declaration is logged once per endpoint type and kind of declaration, whatever its value.

### Performance

- Render time is equal or lower on every demo page, and 2.5x faster on large tables.
- The client device kind is worked out once per request instead of once per `.deviceClass`.
- `Text`'s HTML escaping builds its entity table once instead of on every call (about 2.7x faster, same output).

### Standards mode: check your layouts

Pages used to render in quirks mode. With the doctype:

- percentage heights (`h-100`, `.stretch(.vertical)`, `.frame(fillHeight:)`, `.fullHeight()`) resolve to `auto` inside parents without a definite height;
- unitless lengths in raw CSS (`.style("width: 300")`, `OffCanvas.width("300")`) are ignored;
- table rows inherit `line-height`, so they can be a few pixels taller (35 px to 41 px on the demo's tables);
- rows or cells that contain only an image may grow slightly;
- `<form>` no longer gets a 1em (16 px) bottom margin, so consecutive forms, or a form and the button after it, sit closer together. Add `.margin(.bottom, 16)` or `mb-3` where you want the gap;
- text smaller than the body font inside an `HStack` (`.font(.caption)`, `.font(.custom(11))`) takes at least the 24 px line of its wrapper, so such rows grow from 17–18 px to 24 px and wrapped captions look double-spaced. Set a smaller `line-height` on the `HStack` (its wrappers inherit it) if you need the old height.

## Unreleased: security hardening (Phase 0)

This release fixes several critical vulnerabilities: response splitting and cookie injection through `?token=`, cross-site scripting (XSS) in HTML, attributes and scripts, a crash on bad multipart bodies, a crash on oversized WebSocket frames, and path traversal. It also bounds request heads and JSON bodies.

Most apps need no changes. The list below covers every behaviour change a consumer might notice.

### Output escaping

- **Text and attributes are escaped exactly once by the renderer.** This covers control titles and labels, and the values of `href`, `src`, `title`, `value`, `class`, `style` and `.pair(...)`.
  - Markup inside a title now shows as text. For example, `Button("<i class=\"bi bi-x\"></i> Close")` displays the tag literally. Use `.innerHTML(...)` or `.custom(...)` when you need raw markup; both stay raw by design.
  - `NavBar(brand:)` also stays raw. Never pass user data to it.
  - Do **not** escape values yourself before passing them in. They would be escaped twice.
- **Generated JavaScript uses script-safe literals** (`WebJSON.scriptString`, `WebJSON.scriptLiteral`).
  - String literals are now double-quoted, and `<`, `>`, `&`, `'` and the backtick are `\u`-escaped.
  - `.text`, `.html`, `.appendHTML` and `.prependHTML` no longer use template literals, so `${...}` in their values is no longer interpolated.
  - Raw script bodies (`.script`, `.handleResponse(script:)`, etc.) are emitted as written, except that `</script` becomes `<\/script`.
- **`Code(...)`** escapes its text and no longer turns spaces into `&nbsp;`.
- **`onEnterKey` / `onEscapeKey`** now fire. Their key filter previously never matched.
- **`Int`, `Double` and `Bool` bindings** render their value on the server instead of an empty string.

### Password fields

- A password input (`SecureField`, or `TextField(type: .password)`) is never pre-filled. This applies to a value submitted with a form that failed validation and to a value the app seeded the binding with. The bound variable starts empty.

### Sessions and headers

- **`?token=` no longer authenticates and is never written to the `auth` cookie.**
  - Set `server.acceptQueryToken = true` to accept it again.
  - Even then, it authenticates only that one request and never sets a cookie.
- **`header(...)`, `headers(...)`, `setCookie(...)` and `redirect(to:)` drop unsafe values.** A header whose name is not a token, or whose value contains CR, LF or NUL, is dropped. The same goes for a cookie whose value is not RFC 6265 cookie-octets (spaces, `"`, `,`, `;`, non-ASCII), and for a cookie attribute containing `;`. Each drop is logged once. Percent- or base64-encode cookie values such as JSON.

### Requests

- **Malformed request targets get `400` before routing.** This covers `.` or `..` segments, `%2F`, `%5C`, backslashes, bad percent-escapes, invalid UTF-8 and control characters. The query string is not inspected.
- **Request heads are bounded.**
  - A request line longer than 16 KiB gets `414`.
  - A header line longer than 16 KiB, more than 128 header lines, or more than 64 KiB of header lines in total gets `431`.
  - Over-long lines are refused, never split.
- **Request JSON nested deeper than 64 levels is not parsed.**
  - `WebData` keeps no fields for such a body.
  - `HttpRequest.decodeBody` throws.
  - `validateData(.validJSON)` reports the value as invalid.
- **Multipart bodies use a new bounds-checked parser.** Results are unchanged for well-formed bodies.

### File responses

- **Correct framing for file bodies.**
  - The real `Content-Length` is sent; it was previously `0`.
  - A byte range gets `206` with `Content-Range`, and an unsatisfiable range gets `416`.
  - A missing or unreadable file gets `404`.
- **`body(_ file: URL)` types files and turns off sniffing.**
  - Every file body now gets `X-Content-Type-Options: nosniff`, unless the app set that header itself. A browser will therefore refuse a script or stylesheet served with an explicit `Content-Type` that doesn't match.
  - When the app sets no `Content-Type`, one is derived from the file extension: images, fonts, CSS, JSON, plain text, PDF, archives and JavaScript get their real type.
  - Documents that can run script on your origin when opened directly (HTML, SVG, XML, XSL and similar), and unknown extensions, are sent as `application/octet-stream`, so the browser downloads them instead of rendering them. To serve a trusted document inline, set its `Content-Type` explicitly, for example `.content(.html)`.
- **New `HttpResponse.file(relativePath:under:contentType:)`.** Use it for any directory users can write to, such as uploads.
  - It resolves symlinks and confines the file to the root directory.
  - HTML, SVG, XML, JavaScript and unknown types are sent as attachments.
  - Pair it with `RequestPathValidator.validate(uri:)`:

    ```swift
    guard case .success(let path) = RequestPathValidator.validate(uri: request.head.uri),
          path.hasPrefix("/binaries/") else { return HttpResponse().status(.notFound) }
    return HttpResponse.file(relativePath: String(path.dropFirst("/binaries/".count)),
                             under: URL(fileURLWithPath: FileManager.default.currentDirectoryPath + "/binaries"))
    ```

### WebSockets

- **Frames and messages are limited to 1 MiB by default.**
  - Larger ones are closed with `1009`; set `maxFrameBytes` / `maxMessageBytes` on the endpoint to change this.
  - Protocol violations close with `1002`, and invalid UTF-8 text closes with `1007`.
  - Source break: a `CoreWebsocketEndpoint` subclass that already declares a property named `maxFrameBytes` or `maxMessageBytes` must rename it.
- **The WebSocket loop starts only after the `101` has been written.** Frames sent from `onOpen` can no longer arrive before the handshake.
  - Code that drives `HTTPServer` directly should start its loop from the new `HttpResponse.onUpgraded` hook, not from the route handler.
