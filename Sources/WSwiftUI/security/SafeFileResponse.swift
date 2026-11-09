//
//  SafeFileResponse.swift
//  WSwiftUI
//
//  Serving a file named by the client without letting the name escape the
//  directory it is meant to come from.
//

import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

public extension HttpResponse {

    /// Serves a regular file that lies inside `root`, or answers 404.
    ///
    /// `relativePath` is a file-system path relative to `root` (a leading "/" is
    /// allowed and ignored). It is used as-is and is NOT percent-decoded, so pass a
    /// decoded path: the value returned by `RequestPathValidator.validate(uri:)` is
    /// suitable, whereas `request.head.path` and `request.head.uri` are still encoded
    /// (a file named "my file.txt" arrives as "my%20file.txt"). For example:
    ///
    ///     let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    ///     guard case .success(let path) = RequestPathValidator.validate(uri: request.head.uri) else {
    ///         return HttpResponse().status(.badRequest)
    ///     }
    ///     return HttpResponse.file(relativePath: path, under: root)
    ///
    /// Both `root` and the requested file are standardised and have every symlink
    /// resolved. The resolved file must lie strictly inside the resolved root, so
    /// `..` segments and symlinks that point elsewhere are refused. Missing files,
    /// directories and non-regular files (FIFOs, devices) also give 404.
    ///
    /// The response is 200 with `X-Content-Type-Options: nosniff`, and with
    /// `Content-Type` set to `contentType` when one is passed. Otherwise the type is
    /// guessed from the file extension, but only for passive formats (images, fonts,
    /// CSS, JSON, plain text, PDF, archives). Formats a browser would render or run as
    /// script on your origin (HTML, XHTML, SVG, XML, JavaScript) and unknown extensions
    /// are sent as `application/octet-stream` with `Content-Disposition: attachment`,
    /// so a file uploaded by one user cannot run script in another user's session when
    /// it is opened directly. Pass `contentType` to serve such a file inline, and only
    /// do that for directories whose contents you trust. Content-Length is added when
    /// the response is written.
    static func file(relativePath: String, under root: URL, contentType: String? = nil) -> HttpResponse {
        guard let resolved = SafeFileResolver.resolve(relativePath: relativePath, under: root) else {
            return HttpResponse().status(.notFound).content(.text).body("Not Found")
        }
        let response = HttpResponse().status(.ok)
        if let contentType {
            response.header("Content-Type", contentType)
        } else {
            let guessed = SafeFileResolver.contentType(forExtension: resolved.pathExtension)
            response.header("Content-Type", guessed)
            if guessed == SafeFileResolver.downloadOnlyType {
                response.header("Content-Disposition", "attachment")
            }
        }
        response.header("X-Content-Type-Options", "nosniff")
        return response.body(resolved)
    }
}

internal enum SafeFileResolver {

    /// The resolved URL of a regular, readable file inside `root`, or nil.
    static func resolve(relativePath: String, under root: URL) -> URL? {
        guard relativePath.utf8.contains(0) == false else { return nil }
        guard let rootReal = realPath(root.standardizedFileURL.path) else { return nil }

        let joined = rootReal.hasSuffix("/") ? rootReal + relativePath : rootReal + "/" + relativePath
        guard let fileReal = realPath(joined) else { return nil }

        let prefix = rootReal.hasSuffix("/") ? rootReal : rootReal + "/"
        // byte-wise comparison: String.hasPrefix compares Characters, which can merge a "/" with a combining mark
        guard fileReal.utf8.count > prefix.utf8.count, fileReal.utf8.starts(with: prefix.utf8) else { return nil }

        guard let attributes = try? FileManager.default.attributesOfItem(atPath: fileReal),
              (attributes[.type] as? FileAttributeType) == .typeRegular,
              FileManager.default.isReadableFile(atPath: fileReal) else {
            return nil
        }
        return URL(fileURLWithPath: fileReal)
    }

    /// realpath(3): absolute, with "." / ".." removed and every symlink resolved. Nil if it does not exist.
    static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Sent for unknown extensions and for formats that are never guessed inline.
    static let downloadOnlyType = "application/octet-stream"

    /// Extensions a browser renders as an active document, or runs as script, on the serving
    /// origin. They are never guessed as their real type; serving them inline needs an explicit
    /// `contentType`.
    static let activeExtensions: Set<String> = [
        "html", "htm", "shtml", "xhtml", "xht", "mht", "mhtml",
        "svg", "svgz", "xml", "xsl", "xslt", "plist", "rdf",
        "js", "mjs", "cjs",
    ]

    /// The Content-Type for a file sent with the legacy `HttpResponse.body(_ file: URL)` when the app
    /// set none (file bodies also always get `nosniff`).
    ///
    /// Formats a browser renders as a document that can run script on this origin when the file is
    /// opened directly (HTML, SVG, XML, ...) and unknown extensions are `application/octet-stream`, so
    /// they download instead of rendering: `body(URL)` is often pointed at an upload directory. Set the
    /// Content-Type explicitly to serve a trusted document inline. JavaScript keeps a script type
    /// (opening a .js file directly never runs it, and `<script src>` needs the type under nosniff).
    static func legacyContentType(forExtension ext: String) -> String {
        switch ext.lowercased() {
            case "js", "mjs": return "text/javascript; charset=utf-8"
            default: return contentType(forExtension: ext)
        }
    }

    /// The Content-Type guessed for a file extension. Active formats (`activeExtensions`) and
    /// unknown extensions give `downloadOnlyType`.
    static func contentType(forExtension ext: String) -> String {
        let ext = ext.lowercased()
        if activeExtensions.contains(ext) {
            return downloadOnlyType
        }
        switch ext {
            case "css": return "text/css; charset=utf-8"
            case "json": return "application/json"
            case "txt": return "text/plain; charset=utf-8"
            case "png": return "image/png"
            case "jpg", "jpeg": return "image/jpeg"
            case "gif": return "image/gif"
            case "webp": return "image/webp"
            case "ico": return "image/x-icon"
            case "pdf": return "application/pdf"
            case "zip": return "application/zip"
            case "wasm": return "application/wasm"
            case "woff": return "font/woff"
            case "woff2": return "font/woff2"
            case "mp4": return "video/mp4"
            case "apk": return "application/vnd.android.package-archive"
            default: return downloadOnlyType
        }
    }
}
