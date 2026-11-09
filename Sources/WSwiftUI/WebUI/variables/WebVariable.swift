//
//  File.swift
//
//
//  Created by Adrian Herridge on 18/02/2024.
//

import Foundation

public extension CoreWebEndpoint {
    
    fileprivate func createVariable(_ init: (_ element: WebVariableElement) -> Void) -> WebVariableElement {
        
        let element = WebVariableElement()
        populateCreatedObject(element)
        `init`(element)
        return element
        
    }
    
}

internal enum WebVariableType {
    case bool
    case int
    case double
    case string
    case array
    case object
}

public enum WebVariableLifecycleEvent: String {
    case willSet
    case didSet
    case changed
    case unchanged
}

public class WebVariableElement : WebElement {
    
    internal var variableType: WebVariableType = .bool
    internal var internalName: String? = nil
    internal var errorMessage: String? = nil
    
    private var initial: Any? = nil
    
    /// Form field names that a bound control (TextField, SecureField, TextArea, Picker) submits for this
    /// variable. The hidden carrier input does not submit a field that a control already submits.
    private var fieldNamesSubmittedByControls: Set<String> = []

    /// Field names submitted by the other form controls in the carrier's form (or, outside any form, by
    /// the controls outside any form), found when the page is rendered (`WebFormFieldClaims`). `nil` until
    /// then.
    internal var fieldNamesSubmittedInForm: Set<String>? = nil

    internal func setInitialValue(_ value: Any) {
        initial = value
    }

    /// Records that a bound form control submits this variable under `fieldName`.
    internal func claimFormField(_ fieldName: String) {
        fieldNamesSubmittedByControls.insert(fieldName)
    }

    /// Whether the hidden carrier input submits itself under `fieldName` (its name slot) when the page
    /// rooted at `root` is rendered. It does not when a control bound to the variable claimed the field
    /// (`updateWithEphermeralData`), or when another control in the same form submits a field of that
    /// name, e.g. the checkbox of a `Toggle` (so an unchecked box submits nothing, as in plain HTML) or a
    /// hand-made `<input>`. A field is never posted twice.
    internal func carrierSubmits(fieldName: String, onPage root: WebElement?) -> Bool {
        if fieldNamesSubmittedByControls.contains(fieldName) {
            return false
        }
        if fieldNamesSubmittedInForm == nil {
            WebFormFieldClaims.resolve(page: root)
        }
        return fieldNamesSubmittedInForm?.contains(fieldName) != true
    }

    /// The current value as the hidden carrier input submits it, in the form the server parses back
    /// (`WebData`, `updateWithEphermeralData`) and the client runtime writes (`serializeWebVariable`):
    /// strings as they are, `Int` / `Bool` as text, `Double` as JavaScript's `String(number)`, arrays and
    /// objects as JSON.
    internal var formValue: String {
        switch variableType {
        case .string, .bool, .int, .double:
            return asString()
        case .array:
            return Self.json(asArray()) ?? "[]"
        case .object:
            if let dict = initial as? [String: Any], let json = Self.json(dict) {
                return json
            }
            return "{}"
        }
    }

    private static func json(_ object: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]),
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }
        return string
    }

    /// Replaces the variable's value before the page is rendered (e.g. with the value restored from a failed
    /// submission): the definition script, the hidden carrier's `value` and the page-load sync all use it.
    internal func replaceValue(_ value: Any) {
        setInitialValue(value)
        rewriteDefinition()
        attributes.removeAll(where: { if case .initialValue = $0 { return true } else { return false } })
        addAttribute(.initialValue(value))
    }

    /// Rewrites the `var <id> = <literal>;` line of the definition script with the current value.
    private func rewriteDefinition() {
        // the definition is one line, `var <id> = <literal>;` (literals never contain a raw line break)
        let definitionPrefix = "var \(builderId) = "
        let definition = "\(definitionPrefix)\(asJSValue());"
        var rewritten = false
        attributes = attributes.map { attribute in
            guard rewritten == false, case .script(let js) = attribute, let start = js.range(of: definitionPrefix) else {
                return attribute
            }
            rewritten = true
            let end = js[start.lowerBound...].firstIndex(of: "\n") ?? js.endIndex
            return .script(js.replacingCharacters(in: start.lowerBound..<end, with: definition))
        }
    }

    /// Called when the variable is bound to a password input. The bound value must never be written into
    /// the page, so the variable starts out empty: its definition script is rewritten with the empty value
    /// of its type, the hidden carrier renders that empty value, and no initial value is synced on page load.
    internal func redactInitialValue() {
        let emptyValue: Any
        switch variableType {
            case .bool: emptyValue = false
            case .int: emptyValue = 0
            case .double: emptyValue = 0.0
            case .string: emptyValue = ""
            case .array: emptyValue = [String]()
            case .object: emptyValue = [String: Any]()
        }
        setInitialValue(emptyValue)
        rewriteDefinition()
        attributes.removeAll(where: {
            switch $0 {
                case .initialValue, .value: return true
                default: return false
            }
        })
    }
    
    /// The variable's initial value as a JavaScript literal that is safe to embed in a `<script>` element
    /// (strings are encoded with `WebJSON.scriptString`, so `</script>`, quotes, backticks, line
    /// separators etc. can't break out of the literal or the script).
    @discardableResult
    internal func asJSValue() -> String {
        switch variableType {
        case .bool:
            return asBool() ? "true" : "false"
        case .int:
            return String(asInt())
        case .double:
            // NaN / Infinity are emitted as JS identifiers rather than Swift's `nan` / `inf`
            return ScriptValue.number(asDouble())
        case .string:
            return WebJSON.scriptString(asString())
        case .array:
            let array = asArray().map { WebJSON.scriptString($0) }.joined(separator: ",")
            return "[\(array)]"
        case .object:
            // Assuming object is a dictionary of String: Any
            if let dict = initial as? [String: Any],
               let json = WebJSON.scriptLiteral(any: dict) {
                return ScriptValue.json(json)
            }
            return "{}"
        }
    }
    
    @discardableResult
    internal func asArray() -> [String] {
        return initial as? [String] ?? []
    }
    /// The bound value as display text for the server-side render (input `value`, bound `Text`, picker
    /// selection). Strings are returned unchanged. Int/Double/Bool variables used to render as an empty
    /// string until the client runtime synced them; they now render the same text the client shows
    /// (`String(value)` in JS). Arrays and objects still render empty.
    internal func asString() -> String {
        if let stringValue = initial as? String {
            return stringValue
        }
        switch variableType {
        case .bool:
            return asBool() ? "true" : "false"
        case .int:
            return String(asInt())
        case .double:
            // exactly what JS `String(number)` shows after the client sync (no `.0`, `1e+21`, `0.00001`)
            return ScriptValue.numberText(asDouble())
        case .string, .array, .object:
            return ""
        }
    }
    internal func asInt() -> Int {
        return initial as? Int ?? 0
    }
    internal func asDouble() -> Double {
        return initial as? Double ?? 0.0
    }
    internal func asBool() -> Bool {
        return initial as? Bool ?? false
    }
    
    /// Names the variable. The name is the form field its hidden carrier input submits (it replaces the
    /// default, the builderId; the last call wins), the key `validateData` and re-rendering use, and its
    /// key in liveUpdate and `.post` payloads. When a control in the same form submits the field itself (a
    /// bound TextField, SecureField, TextArea or Picker, a Toggle's checkbox, or any other named input,
    /// select or textarea), the carrier leaves the field to that control. A Toggle therefore submits like a
    /// plain checkbox: `on` when checked, nothing when unchecked.
    @discardableResult
    override public func name(_ name: String) -> Self {
        internalName = name
        super.name(name)
        return self
    }
    
    @discardableResult
    public func onValueEvent(_ event: WebVariableLifecycleEvent, _ actions: [WebAction]) -> Self {
        return addVariableEventListener(event.rawValue, actions)
    }

    /// Runs `actions` when a liveUpdate request involving this variable fails: the server answered with an
    /// `errors` entry for the variable's name (`WebVariableTransaction.errors`), or, for the variable that
    /// owns the liveUpdate, the request itself failed (network error or a non-2xx status without field
    /// errors). The actions can read `_eventPayload.name`, `_eventPayload.message`, `_eventPayload.status`
    /// (the HTTP status, or `null`) and `_eventPayload.reference`.
    @discardableResult
    public func onLiveUpdateError(_ actions: [WebAction]) -> Self {
        return addVariableEventListener("liveUpdateError", actions)
    }

    private func addVariableEventListener(_ eventName: String, _ actions: [WebAction]) -> Self {
        attributes.append(.script("""
                            addWebVariableEventListener\(builderId)(\(ScriptValue.string(eventName)), function(_eventPayload) {
                                \(compileActions(actions))
                            });
                        """))
        return self
    }
    
    @discardableResult
    public func onValueWillSet(_ actions: [WebAction]) -> Self {
        onValueEvent(.willSet, actions)
    }
    
    @discardableResult
    public func onValueDidSet(_ actions: [WebAction]) -> Self {
        onValueEvent(.didSet, actions)
    }
    
    @discardableResult
    public func onValueChanged(_ actions: [WebAction]) -> Self {
        onValueEvent(.changed, actions)
    }
    
    @discardableResult
    public func onValueUnchanged(_ actions: [WebAction]) -> Self {
        onValueEvent(.unchanged, actions)
    }
    
    // Backwards-compatible alias retained for existing callsites.
    @discardableResult
    public func onValueChange(_ actions: [WebAction]) -> Self {
        onValueDidSet(actions)
    }
    
    @discardableResult
    internal func createWebVariableFunctions() -> Self {
        
        addAttribute(.dontRegisterObject)
        
        let typeLabel: String
        switch variableType {
            case .bool: typeLabel = "bool"
            case .int: typeLabel = "int"
            case .double: typeLabel = "double"
            case .string: typeLabel = "string"
            case .array: typeLabel = "array"
            case .object: typeLabel = "object"
        }
        
        // create the functions to get/set this variable
        addAttribute(.script("""
        
        // definition of variable for global use
        var \(builderId) = \(asJSValue());
        var webVariableType\(builderId) = '\(typeLabel)';
        
        // array of callback functions that take a single value parameter
        var callbacks\(builderId) = [];
        var variableEventCallbacks\(builderId) = {
            willSet: [],
            didSet: [],
            changed: [],
            unchanged: []
        };
        
        function addCallback\(builderId)(callback) {
            // add a callback function to the array
            callbacks\(builderId).push(callback);
        }
        
        function addWebVariableEventListener\(builderId)(eventName, callback) {
            if (!variableEventCallbacks\(builderId)[eventName]) {
                variableEventCallbacks\(builderId)[eventName] = [];
            }
            variableEventCallbacks\(builderId)[eventName].push(callback);
        }
        
        function emitWebVariableEvent\(builderId)(eventName, payload) {
            var handlers = variableEventCallbacks\(builderId)[eventName] || [];
            for (var i = 0; i < handlers.length; i++) {
                handlers[i](payload);
            }
        }
        
        function normalizeWebVariable\(builderId)(value, fallback) {
            if (webVariableType\(builderId) === 'bool') {
                if (typeof value === 'boolean') return value;
                if (typeof value === 'number') return value !== 0;
                if (typeof value === 'string') {
                    var lowered = value.trim().toLowerCase();
                    if (lowered === 'true' || lowered === '1' || lowered === 'on' || lowered === 'yes') return true;
                    if (lowered === 'false' || lowered === '0' || lowered === 'off' || lowered === 'no' || lowered === '') return false;
                }
                return !!value;
            }
        
            if (webVariableType\(builderId) === 'int') {
                var parsedInt = parseInt(value, 10);
                if (isNaN(parsedInt)) {
                    return (typeof fallback === 'number') ? Math.trunc(fallback) : 0;
                }
                return parsedInt;
            }
        
            if (webVariableType\(builderId) === 'double') {
                var parsedDouble = parseFloat(value);
                if (isNaN(parsedDouble)) {
                    return (typeof fallback === 'number') ? fallback : 0;
                }
                return parsedDouble;
            }
        
            if (webVariableType\(builderId) === 'array') {
                if (Array.isArray(value)) return value;
                if (typeof value === 'string') {
                    var trimmed = value.trim();
                    if (trimmed === '') return [];
                    try {
                        var parsedArray = JSON.parse(value);
                        if (Array.isArray(parsedArray)) return parsedArray;
                    } catch (_) {}
                    return value.split(',').map(function(item){ return item.trim(); });
                }
                if (value === null || typeof value === 'undefined') return [];
                return [String(value)];
            }
        
            if (webVariableType\(builderId) === 'object') {
                if (value && typeof value === 'object' && !Array.isArray(value)) return value;
                if (typeof value === 'string') {
                    try {
                        var parsedObject = JSON.parse(value);
                        if (parsedObject && typeof parsedObject === 'object' && !Array.isArray(parsedObject)) {
                            return parsedObject;
                        }
                    } catch (_) {}
                    return {};
                }
                return {};
            }
        
            // string
            if (value === null || typeof value === 'undefined') return '';
            return String(value);
        }
        
        function serializeWebVariable\(builderId)(value) {
            if (Array.isArray(value) || (value !== null && typeof value === 'object')) {
                try { return JSON.stringify(value); } catch (_) { return ''; }
            }
            if (value === null || typeof value === 'undefined') return '';
            return String(value);
        }
        
        function valuesEqualWebVariable\(builderId)(left, right) {
            if (left === right) return true;
            var leftIsObj = left !== null && typeof left === 'object';
            var rightIsObj = right !== null && typeof right === 'object';
            if (leftIsObj || rightIsObj) {
                try { return JSON.stringify(left) === JSON.stringify(right); } catch (_) { return false; }
            }
            return false;
        }
        
        // create monitor and variable functions for updates and monitoring
        function updateHiddenInput\(builderId)(value) {
            var hiddenInput = document.getElementById('hiddenInput_\(builderId)');
            if (hiddenInput) {
                hiddenInput.value = serializeWebVariable\(builderId)(value);
            }
        }
        
        function notifyWebVariable\(builderId)(context) {
            updateWebVariable\(builderId)(\(builderId), context || { source: 'notify' });
        }
        
        // var updates the hidden input as well as var. Then notifies a change to the bound objects
        function updateWebVariable\(builderId)(value, context) {
            var previousValue = \(builderId);
            var nextValue = normalizeWebVariable\(builderId)(value, previousValue);
            var changed = !valuesEqualWebVariable\(builderId)(previousValue, nextValue);
            var metadata = context || {};
            var payload = {
                value: nextValue,
                previousValue: previousValue,
                changed: changed,
                source: (typeof metadata.source === 'string') ? metadata.source : 'update',
                origin: metadata.origin || null
            };
        
            emitWebVariableEvent\(builderId)('willSet', payload);
            \(builderId) = nextValue;
            updateHiddenInput\(builderId)(nextValue);
         
            // loop through the callbacks and call them with the new value
            for (var i = 0; i < callbacks\(builderId).length; i++) {
                callbacks\(builderId)[i](nextValue, payload);
            }
        
            emitWebVariableEvent\(builderId)('didSet', payload);
            emitWebVariableEvent\(builderId)(changed ? 'changed' : 'unchanged', payload);
        }
        """))
        
        return self
    }
    
    @discardableResult
    public func liveUpdate(
        url: String,
        reference: String,
        actions: [WebVariableLiveUpdateActions] = [.read],
        related: [WebVariableElement]? = nil,
        onRequest: [WebAction]? = nil,
        onResponse: [WebAction]? = nil
    ) -> Self {
        return liveUpdate(url: url,
                          reference: reference,
                          actions: actions,
                          related: related,
                          onRequest: onRequest,
                          onResponse: onResponse,
                          pollEverySeconds: nil)
    }

    /// Keeps this variable (and `related` ones) in sync with `url`, which receives a
    /// `WebVariableTransaction` (`reference`, `read`, `write`, `data` keyed by the variables' names) and
    /// should answer with one as JSON (`data` to apply, `errors` keyed by variable name). An empty body
    /// (e.g. `204 No Content`) is a success with nothing to apply.
    ///
    /// - `.write`: a local edit of any of the variables is sent `writeDebounceMilliseconds` after the last
    ///   change; writes are sent one at a time. The page-load sync and values applied from the server are
    ///   not sent back. An edit not yet sent (waiting for its debounce or queued behind a write) is sent
    ///   with `keepalive` when the page is left.
    /// - `.read`: `pollEverySeconds` (if set) polls for the current values; there is no read on page load.
    /// - A response is applied only if no newer response was applied and no local edit happened after its
    ///   request was sent, so a slow or out-of-order answer cannot overwrite newer values. Polling skips
    ///   while an edit is still on its way to the server, and the answer to a read sent or answered during
    ///   that time (e.g. `liveRead_<id>()`) is ignored.
    /// - Errors (`errors` entries, failed requests, a body that is not JSON, an exception in the
    ///   `onRequest` actions) are reported to `onLiveUpdateError(_:)`. A failure never stops later writes
    ///   or polls.
    ///
    /// The variables may be declared in any order: callbacks are registered once the page has loaded.
    /// `window.liveRead_<id>()`, `liveWrite_<id>()`, `liveSync_<id>()` and `startPolling_<id>()` are
    /// available for manual use.
    @discardableResult
    public func liveUpdate(
        url: String,
        reference: String,
        actions: [WebVariableLiveUpdateActions] = [.read],
        related: [WebVariableElement]? = nil,
        onRequest: [WebAction]? = nil,
        onResponse: [WebAction]? = nil,
        pollEverySeconds: Int?,
        writeDebounceMilliseconds: Int = 300
    ) -> Self {

        let nameSelf = internalName ?? builderId

        func typeString(_ t: WebVariableType) -> String {
            switch t {
            case .bool:   return "bool"
            case .int:    return "int"
            case .double: return "double"
            case .string: return "string"
            case .array:  return "array"
            case .object: return "object"
            }
        }

        // Client-side descriptors (not sent). Names come from `.name(...)` and are encoded as
        // script-safe string literals.
        let selfEntry = "{name:\(ScriptValue.string(nameSelf)),id:\(ScriptValue.string(builderId)),type:'\(typeString(variableType))'}"
        let relatedEntries = (related ?? []).map {
            let n = $0.internalName ?? $0.builderId
            return "{name:\(ScriptValue.string(n)),id:\(ScriptValue.string($0.builderId)),type:'\(typeString($0.variableType))'}"
        }.joined(separator: ",")

        let varsArrayJS = "[\(selfEntry)\(relatedEntries.isEmpty ? "" : ",\(relatedEntries)")]"

        // internalName -> builderId for applying server responses
        let nameToIdMapJS: String = {
            var pairs = ["\(ScriptValue.string(nameSelf)):\(ScriptValue.string(builderId))"]
            if let r = related {
                pairs.append(contentsOf: r.map { "\(ScriptValue.string($0.internalName ?? $0.builderId)):\(ScriptValue.string($0.builderId))" })
            }
            return "{\(pairs.joined(separator: ","))}"
        }()

        let allowRead  = actions.contains(.read)
        let allowWrite = actions.contains(.write)

        let onRequestJS  = onRequest.map { CompileActions($0, builderId: builderId) } ?? ""
        let onResponseJS = onResponse.map { CompileActions($0, builderId: builderId) } ?? ""
        // clamped to what setInterval / setTimeout honour (a larger delay would fire immediately)
        let pollMs       = pollEverySeconds.map { ScriptValue.milliseconds(fromSeconds: Double($0)) } ?? 0
        let debounceMs   = min(max(0, writeDebounceMilliseconds), ScriptValue.maxTimerDelay)

        addAttribute(.script("""
        (function(){
            var ownerId = \(ScriptValue.string(builderId));
            var ownerName = \(ScriptValue.string(nameSelf));
            var reference = \(ScriptValue.string(reference));
            var url = \(ScriptValue.string(url));
            var vars = \(varsArrayJS);
            var nameToId = \(nameToIdMapJS);
            var allowRead = \(allowRead ? "true" : "false");
            var allowWrite = \(allowWrite ? "true" : "false");
            var pollEveryMs = \(pollMs);
            var writeDebounceMs = \(debounceMs);
            var hasOwn = Object.prototype.hasOwnProperty;

            var pollTimer = null;
            var readInFlight = false;
            var writeTimer = null;
            var writePending = false;
            var writeInFlight = false;
            var writeQueued = false;
            // Every request gets a sequence number. A response is applied only when it is newer than the
            // last one applied and no local edit happened after its request was sent.
            var requestSeq = 0;
            var appliedSeq = 0;
            var localEdits = 0;
            // Set while server values are written into the variables, so they are not written back.
            var isApplying = false;

            function warn(e){
                if (typeof console !== 'undefined' && console && console.warn) { console.warn(e); }
            }

            function emit(targetId, eventName, payload){
                var fn = window['emitWebVariableEvent' + targetId];
                if (typeof fn !== 'function') { return; }
                try { fn(eventName, payload); } catch (e) { warn(e); }
            }

            function collectData(){
                var d = {};
                for (var i = 0; i < vars.length; i++) {
                    var v = vars[i];
                    try { d[v.name] = window[v.id]; } catch (_) { d[v.name] = undefined; }
                }
                return d;
            }

            function buildPayload(doRead, doWrite){
                return { reference: reference, read: !!doRead, write: !!doWrite, data: collectData() };
            }

            // The answer's JSON, or null for an empty body (e.g. 204, or a handler that returns no body).
            function readBody(r){
                try {
                    if (r.status === 204 || r.status === 205) { return Promise.resolve(null); }
                    if (typeof r.text === 'function') {
                        return Promise.resolve(r.text()).then(function(text){
                            return (typeof text === 'string' && /\\S/.test(text)) ? JSON.parse(text) : null;
                        });
                    }
                    return Promise.resolve(r.json());
                } catch (e) {
                    return Promise.reject(e);
                }
            }

            function doFetch(payload, keepalive){
                var options = {
                    method: "POST",
                    headers: { "Content-Type": "application/json" },
                    credentials: "same-origin",
                    body: JSON.stringify(payload)
                };
                if (keepalive) { options.keepalive = true; }
                return fetch(url, options).then(function(r){
                    if (r.ok) { return readBody(r); }
                    // keep the body of a failed request: it may carry field errors
                    return readBody(r).then(null, function(){ return null; }).then(function(json){
                        var failure = new Error('HTTP ' + r.status);
                        failure.status = r.status;
                        failure.response = json;
                        throw failure;
                    });
                });
            }

            function reportErrors(errors, status){
                if (!errors || typeof errors !== 'object') { return false; }
                var reported = false;
                for (var key in errors) if (hasOwn.call(errors, key)) {
                    var targetId = hasOwn.call(nameToId, key) ? nameToId[key] : ownerId;
                    emit(targetId, 'liveUpdateError', { name: key, message: String(errors[key]), status: status, reference: reference, origin: ownerId });
                    reported = true;
                }
                return reported;
            }

            function reportFailure(e){
                warn(e);
                var status = (e && e.status) || null;
                if (e && e.response && reportErrors(e.response.errors, status)) { return; }
                emit(ownerId, 'liveUpdateError', { name: ownerName, message: String((e && e.message) || e), status: status, reference: reference, origin: ownerId });
            }

            function applyResponse(resp){
                if (!resp || typeof resp !== 'object') { return; }
                if (resp.data && typeof resp.data === 'object') {
                    isApplying = true;
                    try {
                        for (var key in resp.data) if (hasOwn.call(resp.data, key)) {
                            if (!hasOwn.call(nameToId, key)) { continue; }
                            var targetId = nameToId[key];
                            var val = resp.data[key];
                            // Use the generated updater to keep the hidden input + callbacks in sync
                            var fn = window['updateWebVariable' + targetId];
                            if (typeof fn === 'function') {
                                fn(val, { source: 'liveUpdate.read', origin: ownerId });
                            } else {
                                // Fallback (should rarely be needed)
                                try { window[targetId] = val; } catch (_) {}
                                var hidden = document.getElementById('hiddenInput_' + targetId);
                                if (hidden) {
                                    hidden.value = (Array.isArray(val) || (val && typeof val === 'object'))
                                        ? JSON.stringify(val)
                                        : String(val === null || val === undefined ? '' : val);
                                }
                            }
                        }
                    } finally {
                        isApplying = false;
                    }
                }
                reportErrors(resp.errors, null);
            }

            // An edit is waiting for its debounce, being written, or queued behind a write.
            function hasUnconfirmedWrite(){
                return writePending || writeInFlight || writeQueued;
            }

            // The onRequest / onResponse actions, each in its own scope.
            function runOnRequest(){
                \(onRequestJS)
            }
            function runOnResponse(){
                \(onResponseJS)
            }

            // Never throws, and the promise it returns never rejects: a failure (including an exception in
            // the onRequest actions) is reported, so the write / poll state below is always released.
            function send(doRead, doWrite, keepalive){
                if (!doRead && !doWrite) { return Promise.resolve(); }
                var seq = ++requestSeq;
                var editsAtSend = localEdits;
                // A read sent while an edit is unconfirmed may be answered with the values from before the
                // edit, whatever order the answers arrive in.
                var sentDuringWrite = !doWrite && hasUnconfirmedWrite();
                return new Promise(function(resolve){
                        runOnRequest();
                        resolve(doFetch(buildPayload(doRead, doWrite), keepalive));
                    })
                    .then(function(resp){
                        // stale: a newer response was applied, or the user edited after this request was sent
                        if (seq <= appliedSeq || editsAtSend !== localEdits) { return; }
                        // a read must not overwrite an edit the server has not confirmed yet
                        if (!doWrite && (sentDuringWrite || hasUnconfirmedWrite())) { return; }
                        appliedSeq = seq;
                        applyResponse(resp);
                    })
                    .catch(reportFailure)
                    .finally(function(){
                        try { runOnResponse(); } catch (e) { warn(e); }
                    });
            }

            // Writes are sent one at a time; an edit made while a write is in flight is sent after it.
            function writeNow(keepalive){
                if (writeTimer !== null) { clearTimeout(writeTimer); writeTimer = null; }
                writePending = false;
                if (writeInFlight && !keepalive) { writeQueued = true; return Promise.resolve(); }
                writeInFlight = true;
                return send(false, true, keepalive).finally(function(){
                    writeInFlight = false;
                    if (writeQueued) { writeQueued = false; writeNow(false); }
                });
            }

            function scheduleWrite(){
                writePending = true;
                if (writeTimer !== null) { clearTimeout(writeTimer); writeTimer = null; }
                if (writeDebounceMs <= 0) { writeNow(false); return; }
                writeTimer = setTimeout(function(){ writeTimer = null; writeNow(false); }, writeDebounceMs);
            }

            function onVariableChanged(_newValue, meta){
                if (!allowWrite || isApplying) { return; }
                var source = meta && meta.source;
                // the page-load sync and values applied from a server are not edits
                if (source === 'initial' || source === 'liveUpdate.read') { return; }
                if (meta && meta.changed === false) { return; }
                localEdits++;
                scheduleWrite();
            }

            // Polling reads at a fixed interval; there is no read on page load, and no read while an edit
            // is still on its way to the server.
            function startPolling(){
                if (!allowRead || !(pollEveryMs > 0)) { return; }
                if (pollTimer !== null) { clearInterval(pollTimer); }
                pollTimer = setInterval(function(){
                    if (readInFlight || hasUnconfirmedWrite()) { return; }
                    readInFlight = true;
                    send(true, false).finally(function(){ readInFlight = false; });
                }, pollEveryMs);
            }

            // Callbacks are registered once every variable on the page is defined (related variables may
            // be declared after this script), and before the page-load syncs run.
            var started = false;
            function start(){
                if (started) { return; }
                started = true;
                for (var i = 0; i < vars.length; i++) {
                    var addCallback = window['addCallback' + vars[i].id];
                    if (typeof addCallback === 'function') {
                        addCallback(onVariableChanged);
                    } else {
                        warn('liveUpdate: variable ' + vars[i].name + ' is not on this page');
                    }
                }
                startPolling();
            }

            // Manual hooks
            window['startPolling_' + ownerId] = startPolling;
            window['liveWrite_' + ownerId] = function(){ return writeNow(false); };
            window['liveRead_' + ownerId]  = function(){ return send(allowRead, false); };
            window['liveSync_' + ownerId]  = function(){ return send(allowRead, allowWrite); };

            if (typeof document !== 'undefined' && document && document.readyState === 'loading'
                && typeof document.addEventListener === 'function') {
                document.addEventListener('DOMContentLoaded', start);
            } else {
                start();
            }
            // An edit still waiting for its debounce, or queued behind a write in flight, is sent when the
            // page is left.
            if (typeof window.addEventListener === 'function') {
                window.addEventListener('pagehide', function(){
                    if (writePending || writeQueued) {
                        writeQueued = false;
                        writeNow(true);
                    }
                });
            }
        })();
        """))

        return self
    }


    
}

public enum WebVariableLiveUpdateActions {
    case write
    case read
}

public extension CoreWebEndpoint {
    
    /// Creates a variable and its hidden carrier input. The carrier has one `name` slot (the builderId
    /// until `.name(...)` replaces it) and renders `value` from the variable's current value when the page
    /// is rendered (see `WebVariableElement.formValue`), so it always submits what the server parses back.
    fileprivate func createCarrier(_ type: WebVariableType, _ value: Any) -> WebVariableElement {
        return createVariable { element in
            element.variableType = type
            element.elementName = "input"
            element.class("hidden-input")
            element.id("hiddenInput_\(element.builderId)")
            // not `.name(_:)`, which would also make the builderId the variable's public name
            element.addAttribute(.name(element.builderId))
            element.addAttribute(.type("hidden"))
            element.setInitialValue(value)
            element.addAttribute(.initialValue(value))

            // observer to keep hidden field in sync
            element.createWebVariableFunctions()
        }
    }
    
    @discardableResult
    func WBool(_ value: Bool) -> WebVariableElement {
        return createCarrier(.bool, value)
    }

    @discardableResult
    func WInt(_ value: Int) -> WebVariableElement {
        return createCarrier(.int, value)
    }

    @discardableResult
    func WDouble(_ value: Double) -> WebVariableElement {
        return createCarrier(.double, value)
    }

    @discardableResult
    func WString(_ value: String) -> WebVariableElement {
        return createCarrier(.string, value)
    }

    @discardableResult
    func WArray(_ values: [String]) -> WebVariableElement {
        return createCarrier(.array, values)
    }
    
}
