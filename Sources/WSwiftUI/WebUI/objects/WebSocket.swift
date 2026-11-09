//
//  WebSocket.swift
//  WSwiftUI
//
//  Created by Adrian Herridge on 08/10/2025.
//

public extension CoreWebEndpoint {
    /// Creates a WebSocket connection to the given URL and wires up lifecycle handlers.
    /// - Parameters:
    ///   - url: The WebSocket endpoint to connect to (ws:// or wss://).
    ///   - onOpenSocket: Actions to run when the socket opens.
    ///   - onRecieve: Actions to run when a message is received (payload available as window._ws_lastMessage_<id>).
    ///   - onError: Actions to run when an error occurs (details available as window._ws_lastError_<id>).
    @discardableResult
    func WebSocket(url: String, onOpenSocket: [WebAction] = [], onRecieve: [WebAction] = [], onError: [WebAction] = [], onClose: [WebAction] = []) -> WebElement {
        let socket = WebElement()
        populateCreatedObject(socket)
        socket.elementName = "websocket"
        // this is the entire setup and implementation of the websocket connection
        socket.script("""
            (function() {
                const rawUrl = \(ScriptValue.string(url));

                // Optional server-provided base (e.g., <meta name="ws-base" content="wss://sockets.example.com">)
                let baseHref = window.location.href;
                try {
                    const metaBase = document.querySelector('meta[name="ws-base"]');
                    if (metaBase && metaBase.content) {
                        baseHref = metaBase.content;
                    }
                } catch (_) { /* ignore */ }

                // Resolve to absolute URL; if already ws:// or wss://, keep as-is.
                let resolved = (/^wss?:\\/\\//i.test(rawUrl)) ? rawUrl : new URL(rawUrl, baseHref).toString();

                // Ensure correct ws/wss scheme to avoid mixed-content issues.
                try {
                    const u = new URL(resolved);
                    const pageIsHttps = (window.location.protocol === "https:");
                    if (u.protocol !== 'ws:' && u.protocol !== 'wss:') {
                        u.protocol = pageIsHttps ? 'wss:' : 'ws:';
                    } else if (pageIsHttps && u.protocol !== 'wss:') {
                        // Upgrade to wss when page is https
                        u.protocol = 'wss:';
                    }
                    resolved = u.toString();
                } catch (_) { /* if URL parsing fails, let the browser handle it */ }

                const wsUri\(socket.builderId) = resolved;
                const websocket\(socket.builderId) = new WebSocket(wsUri\(socket.builderId));

                // Expose a helper to send messages from other actions: window.websocketSend_<id>(data)
                window.websocketSend\(socket.builderId) = function(data) {
                    try { websocket\(socket.builderId).send(data); } catch (e) { console.error(e); }
                };

                websocket\(socket.builderId).addEventListener("open", (event) => {
                    \(CompileActions(onOpenSocket, builderId: socket.builderId))
                });

                websocket\(socket.builderId).addEventListener("message", (event) => {
                    // all actions expect an object called result
                    var result = event.data;
                    \(CompileActions(onRecieve, builderId: socket.builderId))
                });

                websocket\(socket.builderId).addEventListener("error", (event) => {
                    // all actions expect an object called result
                    var result = event.error;
                    \(CompileActions(onError, builderId: socket.builderId))
                });

                websocket\(socket.builderId).addEventListener("close", (event) => {
                    \(CompileActions(onClose, builderId: socket.builderId))
                });
            })();
            """)
        return socket
    }
}

