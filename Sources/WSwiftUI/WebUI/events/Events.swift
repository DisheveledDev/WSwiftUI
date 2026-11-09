//
//  Events.swift
//  SWWebAppServer
//
//  Created by Adrian on 04/07/2025.
//

import Foundation

// Common options to configure event listeners and handler behavior
public struct EventOptions {
    public var capture: Bool = false
    public var passive: Bool = false
    public var once: Bool = false

    // Handler flow control
    public var preventDefault: Bool = false
    public var stopPropagation: Bool = false

    // Performance helpers (if both are set, debounce takes precedence)
    public var throttleMs: Int? = nil
    public var debounceMs: Int? = nil

    public init(
        capture: Bool = false,
        passive: Bool = false,
        once: Bool = false,
        preventDefault: Bool = false,
        stopPropagation: Bool = false,
        throttleMs: Int? = nil,
        debounceMs: Int? = nil
    ) {
        self.capture = capture
        self.passive = passive
        self.once = once
        self.preventDefault = preventDefault
        self.stopPropagation = stopPropagation
        self.throttleMs = throttleMs
        self.debounceMs = debounceMs
    }
}

public extension WebElement {
    // Internal helper to attach an event listener with options, filtering, and timing controls
    @discardableResult
    private func addEventListener(_ eventName: String,
                                  actions: [WebAction],
                                  options: EventOptions = EventOptions(),
                                  keyFilter: String? = nil,
                                  uniqueSuffix: String? = nil) -> Self {
        // Build the listener options object for addEventListener
        let optionsObject = "{ capture: \(options.capture ? "true" : "false"), passive: \(options.passive ? "true" : "false"), once: \(options.once ? "true" : "false") }"

        // Pre-handler flow control (preventDefault/stopPropagation)
        var flowControl = ""
        if options.preventDefault {
            flowControl += "event.preventDefault();\n"
        }
        if options.stopPropagation {
            flowControl += "event.stopPropagation();\n"
        }

        // Key filter condition if provided (e.g., Enter/Escape)
        let keyConditionOpen: String
        let keyConditionClose: String
        if let key = keyFilter {
            // The key name is emitted as a script-safe string literal. (Previously the interpolation was
            // escaped by mistake, emitting the literal text `'\(key)'`, so the filter never matched.)
            keyConditionOpen = "if (event.key === \(ScriptValue.string(key))) {\n"
            keyConditionClose = "}\n"
        } else {
            keyConditionOpen = ""
            keyConditionClose = ""
        }

        // Unique identifiers for debounce/throttle per element + event
        let safeEvent = eventName.replacingOccurrences(of: "-", with: "_")
        let unique = uniqueSuffix ?? safeEvent

        let actionsJS = compileActions(actions)

        var js: String
        if let debounce = options.debounceMs {
            js = """
var debounceTimer_\(unique)\(builderId);
\(builderId).addEventListener('\(eventName)', function(event) {
    \(keyConditionOpen)if (typeof debounceTimer_\(unique)\(builderId) !== 'undefined' && debounceTimer_\(unique)\(builderId)) { clearTimeout(debounceTimer_\(unique)\(builderId)); }
    debounceTimer_\(unique)\(builderId) = setTimeout(function() {
        \(flowControl)\n        \(actionsJS)
    }, \(debounce));
\(keyConditionClose)}, \(optionsObject));
"""
        } else if let throttle = options.throttleMs {
            js = """
var lastTime_\(unique)\(builderId) = 0;
\(builderId).addEventListener('\(eventName)', function(event) {
    var now = Date.now();
    \(keyConditionOpen)if (now - lastTime_\(unique)\(builderId) < \(throttle)) { return; }
    lastTime_\(unique)\(builderId) = now;
    \(flowControl)\n    \(actionsJS)
\(keyConditionClose)}, \(optionsObject));
"""
        } else {
            js = """
\(builderId).addEventListener('\(eventName)', function(event) {
    \(keyConditionOpen)\(flowControl)\n    \(actionsJS)
\(keyConditionClose)}, \(optionsObject));
"""
        }

        addAttribute(.script(js))
        return self
    }

    // MARK: – Click Event

    @discardableResult
    func onClick(_ actions: [WebAction]) -> Self {
        let js = """
\(builderId).addEventListener('click', function() {
    \(compileActions(actions))
});
"""
        addAttribute(.script(js))
        return self
    }

    @discardableResult
    func onClick(_ action: WebAction) -> Self {
        return onClick([action])
    }

    // MARK: – Disable Event

    @discardableResult
    func onDisable(_ actions: [WebAction]) -> Self {
        let js = """
var lastDisableValue\(builderId) = false;
var disableInterval\(builderId) = setInterval(function() {
    if (\(builderId).disabled != lastDisableValue\(builderId)) {
        if (\(builderId).disabled) { \(builderId).onDisable(); }
        lastDisableValue\(builderId) = \(builderId).disabled;
    }
}, 500);
\(builderId).onDisable = function() {
    \(compileActions(actions))
};
"""
        addAttribute(.script(js))
        return self
    }

    @discardableResult
    func onDisable(_ action: WebAction) -> Self {
        return onDisable([action])
    }

    // MARK: – Mouse Leave Event

    @discardableResult
    func onMouseLeave(_ actions: [WebAction]) -> Self {
        let js = """
\(builderId).addEventListener('mouseleave', function() {
    \(compileActions(actions))
});
"""
        addAttribute(.script(js))
        return self
    }

    @discardableResult
    func onMouseLeave(_ action: WebAction) -> Self {
        return onMouseLeave([action])
    }

    // MARK: – Mouse Over Event

    @discardableResult
    func onMouseover(_ actions: [WebAction]) -> Self {
        let js = """
\(builderId).addEventListener('mouseover', function() {
    \(compileActions(actions))
});
"""
        addAttribute(.script(js))
        return self
    }

    @discardableResult
    func onMouseover(_ action: WebAction) -> Self {
        return onMouseover([action])
    }

    // MARK: – Options-based overloads for common events

    @discardableResult
    func onClick(_ actions: [WebAction], options: EventOptions) -> Self {
        addEventListener("click", actions: actions, options: options)
    }

    @discardableResult
    func onClick(_ action: WebAction, options: EventOptions) -> Self {
        onClick([action], options: options)
    }

    @discardableResult
    func onMouseLeave(_ actions: [WebAction], options: EventOptions) -> Self {
        addEventListener("mouseleave", actions: actions, options: options)
    }

    @discardableResult
    func onMouseLeave(_ action: WebAction, options: EventOptions) -> Self {
        onMouseLeave([action], options: options)
    }

    @discardableResult
    func onMouseover(_ actions: [WebAction], options: EventOptions) -> Self {
        addEventListener("mouseover", actions: actions, options: options)
    }

    @discardableResult
    func onMouseover(_ action: WebAction, options: EventOptions) -> Self {
        onMouseover([action], options: options)
    }

    @discardableResult
    func onDblClick(_ actions: [WebAction], options: EventOptions) -> Self {
        addEventListener("dblclick", actions: actions, options: options)
    }

    @discardableResult
    func onDblClick(_ action: WebAction, options: EventOptions) -> Self {
        onDblClick([action], options: options)
    }

    @discardableResult
    func onContextMenu(_ actions: [WebAction], options: EventOptions) -> Self {
        addEventListener("contextmenu", actions: actions, options: options)
    }

    @discardableResult
    func onContextMenu(_ action: WebAction, options: EventOptions) -> Self {
        onContextMenu([action], options: options)
    }

    @discardableResult
    func onInput(_ actions: [WebAction], options: EventOptions) -> Self {
        addEventListener("input", actions: actions, options: options)
    }

    @discardableResult
    func onInput(_ action: WebAction, options: EventOptions) -> Self {
        onInput([action], options: options)
    }

    @discardableResult
    func onChange(_ actions: [WebAction], options: EventOptions) -> Self {
        addEventListener("change", actions: actions, options: options)
    }

    @discardableResult
    func onChange(_ action: WebAction, options: EventOptions) -> Self {
        onChange([action], options: options)
    }

    @discardableResult
    func onFocus(_ actions: [WebAction], options: EventOptions) -> Self {
        addEventListener("focus", actions: actions, options: options)
    }

    @discardableResult
    func onFocus(_ action: WebAction, options: EventOptions) -> Self {
        onFocus([action], options: options)
    }

    @discardableResult
    func onBlur(_ actions: [WebAction], options: EventOptions) -> Self {
        addEventListener("blur", actions: actions, options: options)
    }

    @discardableResult
    func onBlur(_ action: WebAction, options: EventOptions) -> Self {
        onBlur([action], options: options)
    }

    @discardableResult
    func onKeyDown(_ actions: [WebAction], options: EventOptions) -> Self {
        addEventListener("keydown", actions: actions, options: options)
    }

    @discardableResult
    func onKeyDown(_ action: WebAction, options: EventOptions) -> Self {
        onKeyDown([action], options: options)
    }

    @discardableResult
    func onKeyUp(_ actions: [WebAction], options: EventOptions) -> Self {
        addEventListener("keyup", actions: actions, options: options)
    }

    @discardableResult
    func onKeyUp(_ action: WebAction, options: EventOptions) -> Self {
        onKeyUp([action], options: options)
    }

    @discardableResult
    func onKeyPress(_ actions: [WebAction], options: EventOptions) -> Self {
        addEventListener("keypress", actions: actions, options: options)
    }

    @discardableResult
    func onKeyPress(_ action: WebAction, options: EventOptions) -> Self {
        onKeyPress([action], options: options)
    }

    @discardableResult
    func onSubmit(_ actions: [WebAction], options: EventOptions) -> Self {
        addEventListener("submit", actions: actions, options: options)
    }

    @discardableResult
    func onSubmit(_ action: WebAction, options: EventOptions) -> Self {
        onSubmit([action], options: options)
    }

    @discardableResult
    func onScroll(_ actions: [WebAction], options: EventOptions) -> Self {
        addEventListener("scroll", actions: actions, options: options)
    }

    @discardableResult
    func onScroll(_ action: WebAction, options: EventOptions) -> Self {
        onScroll([action], options: options)
    }

    @discardableResult
    func onTouchStart(_ actions: [WebAction], options: EventOptions) -> Self {
        addEventListener("touchstart", actions: actions, options: options)
    }

    @discardableResult
    func onTouchStart(_ action: WebAction, options: EventOptions) -> Self {
        onTouchStart([action], options: options)
    }

    @discardableResult
    func onTouchEnd(_ actions: [WebAction], options: EventOptions) -> Self {
        addEventListener("touchend", actions: actions, options: options)
    }

    @discardableResult
    func onTouchEnd(_ action: WebAction, options: EventOptions) -> Self {
        onTouchEnd([action], options: options)
    }

    @discardableResult
    func onTouchMove(_ actions: [WebAction], options: EventOptions) -> Self {
        addEventListener("touchmove", actions: actions, options: options)
    }

    @discardableResult
    func onTouchMove(_ action: WebAction, options: EventOptions) -> Self {
        onTouchMove([action], options: options)
    }

    @discardableResult
    func onPointerDown(_ actions: [WebAction], options: EventOptions) -> Self {
        addEventListener("pointerdown", actions: actions, options: options)
    }

    @discardableResult
    func onPointerDown(_ action: WebAction, options: EventOptions) -> Self {
        onPointerDown([action], options: options)
    }

    @discardableResult
    func onPointerUp(_ actions: [WebAction], options: EventOptions) -> Self {
        addEventListener("pointerup", actions: actions, options: options)
    }

    @discardableResult
    func onPointerUp(_ action: WebAction, options: EventOptions) -> Self {
        onPointerUp([action], options: options)
    }

    @discardableResult
    func onPointerMove(_ actions: [WebAction], options: EventOptions) -> Self {
        addEventListener("pointermove", actions: actions, options: options)
    }

    @discardableResult
    func onPointerMove(_ action: WebAction, options: EventOptions) -> Self {
        onPointerMove([action], options: options)
    }

    // MARK: – Timer Event

    @discardableResult
    func onTimer(seconds: Double, _ actions: [WebAction]) -> Self {
        let ms = ScriptValue.milliseconds(fromSeconds: seconds)
        let actionsJS = compileActions(actions)
        let js = """
var timerInterval_\(builderId);
if (typeof timerInterval_\(builderId) !== 'undefined' && timerInterval_\(builderId)) { clearInterval(timerInterval_\(builderId)); }
timerInterval_\(builderId) = setInterval(function() {
    \(actionsJS)
}, \(ms));
"""
        addAttribute(.script(js))
        return self
    }

    @discardableResult
    func onTimer(seconds: Double, _ action: WebAction) -> Self {
        return onTimer(seconds: seconds, [action])
    }

    // MARK: – Keyboard convenience helpers

    @discardableResult
    func onEnterKey(_ actions: [WebAction], options: EventOptions = EventOptions()) -> Self {
        addEventListener("keydown", actions: actions, options: options, keyFilter: "Enter", uniqueSuffix: "EnterKey")
    }

    @discardableResult
    func onEnterKey(_ action: WebAction, options: EventOptions = EventOptions()) -> Self {
        onEnterKey([action], options: options)
    }

    @discardableResult
    func onEscapeKey(_ actions: [WebAction], options: EventOptions = EventOptions()) -> Self {
        addEventListener("keydown", actions: actions, options: options, keyFilter: "Escape", uniqueSuffix: "EscapeKey")
    }

    @discardableResult
    func onEscapeKey(_ action: WebAction, options: EventOptions = EventOptions()) -> Self {
        onEscapeKey([action], options: options)
    }
}

