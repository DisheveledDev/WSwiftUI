# Changelog

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
