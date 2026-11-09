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
    
    internal func setInitialValue(_ value: Any) {
        initial = value
    }
    
    /// Called when the variable is bound to a password input. The bound value must never be written into
    /// the page, so the variable starts out empty: its definition script is rewritten with the empty value
    /// of its type, and no initial value is synced on page load.
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
        // the definition is one line, `var <id> = <literal>;` (literals never contain a raw line break)
        let definitionPrefix = "var \(builderId) = "
        let definition = "\(definitionPrefix)\(asJSValue());"
        var rewritten = false
        attributes = attributes.compactMap { attribute in
            switch attribute {
                case .initialValue, .value:
                    return nil
                case .script(let js):
                    guard rewritten == false, let start = js.range(of: definitionPrefix) else { return attribute }
                    rewritten = true
                    let end = js[start.lowerBound...].firstIndex(of: "\n") ?? js.endIndex
                    return .script(js.replacingCharacters(in: start.lowerBound..<end, with: definition))
                default:
                    return attribute
            }
        }
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
    
    @discardableResult
    override public func name(_ name: String) -> Self {
        internalName = name
        
        // String bindings are usually represented by visible text controls that
        // should own the public form field name. Keep the hidden variable input
        // on its generated builderId name to avoid duplicate name fields.
        if variableType != .string {
            attributes.removeAll(where: { if case .name(_) = $0 { return true } else { return false } })
            addAttribute(.name(name))
        }
        return self
    }
    
    @discardableResult
    public func onValueEvent(_ event: WebVariableLifecycleEvent, _ actions: [WebAction]) -> Self {
        attributes.append(.script("""
                            addWebVariableEventListener\(builderId)('\(event.rawValue)', function(_eventPayload) {
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

    @discardableResult
    public func liveUpdate(
        url: String,
        reference: String,
        actions: [WebVariableLiveUpdateActions] = [.read],
        related: [WebVariableElement]? = nil,
        onRequest: [WebAction]? = nil,
        onResponse: [WebAction]? = nil,
        pollEverySeconds: Int?
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
        let pollJS       = pollEverySeconds.map { String(max(0, $0)) } ?? "0"

        addAttribute(.script("""
        (function(){
            var vars_\(builderId) = \(varsArrayJS);
            var nameToId_\(builderId) = \(nameToIdMapJS);

            // Prevent feedback loops when applying server responses
            var isApplying_\(builderId) = false;

            // Polling (fixed interval, seconds)
            var pollEverySec_\(builderId) = \(pollJS);
            var pollTimer_\(builderId) = null;
            var readInFlight_\(builderId) = false;

            // Skip the very first callback each var fires (from DOMContentLoaded init)
            var skippedFirst_\(builderId) = {};
            for (var i=0;i<vars_\(builderId).length;i++){ skippedFirst_\(builderId)[vars_\(builderId)[i].id] = false; }

            function collectData_\(builderId)(){
                var d = {};
                for (var i=0; i<vars_\(builderId).length; i++){
                    var v = vars_\(builderId)[i];
                    try { d[v.name] = window[v.id]; } catch(_){ d[v.name] = undefined; }
                }
                return d;
            }

            function buildPayload_\(builderId)(doRead, doWrite){
                var payload = {
                    reference: \(ScriptValue.string(reference)),
                    read: !!doRead,
                    write: !!doWrite,
                    data: {}
                };
                var curr = collectData_\(builderId)();
                for (var n in curr) if (Object.prototype.hasOwnProperty.call(curr, n)) {
                    payload.data[n] = curr[n]; // raw JS var values
                }
                return payload;
            }

            function doFetch_\(builderId)(payload){
                return fetch(\(ScriptValue.string(url)), {
                    method: "POST",
                    headers: { "Content-Type": "application/json" },
                    credentials: "same-origin",
                    body: JSON.stringify(payload)
                }).then(function(r){
                    if(!r.ok) throw new Error('HTTP ' + r.status);
                    return r.json();
                });
            }

            function applyResponse_\(builderId)(resp){
                if (!resp || !resp.data) return;
                isApplying_\(builderId) = true;
                try {
                    for (var key in resp.data) if (Object.prototype.hasOwnProperty.call(resp.data, key)) {
                        var targetId = nameToId_\(builderId)[key];
                        if (!targetId) continue;
                        var val = resp.data[key];
                        // Use generated updater to keep hidden input + callbacks in sync
                        var fn = window['updateWebVariable' + targetId];
                        if (typeof fn === 'function') {
                            fn(val, { source: 'liveUpdate.read', origin: '\(builderId)' });
                        } else {
                            // Fallback (should rarely be needed)
                            try { window[targetId] = val; } catch(_){}
                            var hidden = document.getElementById('hiddenInput_' + targetId);
                            if (hidden) {
                                hidden.value = (Array.isArray(val) || (val && typeof val === 'object'))
                                    ? JSON.stringify(val)
                                    : String(val ?? '');
                            }
                        }
                    }
                } finally {
                    isApplying_\(builderId) = false;
                }
            }

            function send_\(builderId)(doRead, doWrite){
                if (!doRead && !doWrite) return Promise.resolve();
                \(onRequestJS)
                return doFetch_\(builderId)(buildPayload_\(builderId)(doRead, doWrite))
                    .then(applyResponse_\(builderId))
                    .catch(function(e){ console && console.warn && console.warn(e); })
                    .finally(function(){ \(onResponseJS) });
            }

            // Register callbacks: on any callback (after first), push WRITE (no READ)
            (function(){
                for (var i=0; i<vars_\(builderId).length; i++){
                    (function(v){
                        var addCb = window['addCallback' + v.id];
                        if (typeof addCb === 'function') {
                            addCb(function(_newVal, meta){
                                if (!\(allowWrite ? "true" : "false")) return;
                                if (isApplying_\(builderId)) return; // ignore our own updates from server
                                if (skippedFirst_\(builderId)[v.id] === false) {
                                    // first callback for this var is the DOMContentLoaded init — ignore it
                                    skippedFirst_\(builderId)[v.id] = true;
                                    return;
                                }
                                if (meta && meta.changed === false) return;
                                // Write current values for all involved vars; no read
                                send_\(builderId)(false, true);
                            });
                        }
                    })(vars_\(builderId)[i]);
                }
            })();

            // Polling reads at fixed interval; no initial read
            function startPolling_\(builderId)(){
                if (!\(allowRead ? "true" : "false")) return;
                if (!pollEverySec_\(builderId) || pollEverySec_\(builderId) <= 0) return;
                if (pollTimer_\(builderId)) { try { clearInterval(pollTimer_\(builderId)); } catch(_){ } }
                pollTimer_\(builderId) = setInterval(function(){
                    if (readInFlight_\(builderId)) return;
                    readInFlight_\(builderId) = true;
                    send_\(builderId)(true, false)
                        .finally(function(){ readInFlight_\(builderId) = false; });
                }, pollEverySec_\(builderId) * 1000);
            }

            // Manual hooks if needed
            window['liveWrite_\(builderId)'] = function(){ return send_\(builderId)(false, true); };
            window['liveRead_\(builderId)']  = function(){ return send_\(builderId)(\(allowRead ? "true" : "false"), false); };
            window['liveSync_\(builderId)']  = function(){ return send_\(builderId)(\(allowRead ? "true" : "false"), \(allowWrite ? "true" : "false")); };
        })();
        """))
        
        self.addAttribute(.domLoadedScript("startPolling_\(builderId)();"))

        return self
    }


    
}

public enum WebVariableLiveUpdateActions {
    case write
    case read
}

public extension CoreWebEndpoint {
    
    @discardableResult
    func WBool(_ value: Bool) -> WebVariableElement {
        
        let object = createVariable { element in
            element.variableType = .bool
            element.elementName = "input"
            element.class("hidden-input")
            element.id("hiddenInput_\(element.builderId)")
            element.addAttribute(.pair("name", element.builderId))
            element.addAttribute(.type("hidden"))
            element.setInitialValue(value)
            element.addAttribute(.value(value ? "true" : "false"))
            element.addAttribute(.initialValue(value))
            
            // observer to keep hidden field in sync
            element.createWebVariableFunctions()
            
        }
        
        return object
        
    }
    
    @discardableResult
    func WInt(_ value: Int) -> WebVariableElement {
        
        let object = createVariable { element in
            element.variableType = .int
            element.elementName = "input"
            element.class("hidden-input")
            element.id("hiddenInput_\(element.builderId)")
            element.addAttribute(.pair("name", element.builderId))
            element.addAttribute(.type("hidden"))
            element.setInitialValue(value)
            element.addAttribute(.initialValue(value))
            element.addAttribute(.value(String(value)))
            
            // observer to keep hidden field in sync
            element.createWebVariableFunctions()
        }
        
        return object
    }
    
    @discardableResult
    func WDouble(_ value: Double) -> WebVariableElement {
        
        let object = createVariable { element in
            element.variableType = .double
            element.elementName = "input"
            element.class("hidden-input")
            element.id("hiddenInput_\(element.builderId)")
            element.addAttribute(.pair("name", element.builderId))
            element.addAttribute(.type("hidden"))
            element.setInitialValue(value)
            element.addAttribute(.initialValue(value))
            element.addAttribute(.value(String(value)))
            
            // observer to keep hidden field in sync
            element.createWebVariableFunctions()
        }
        
        return object
        
    }
    
    @discardableResult
    func WString(_ value: String) -> WebVariableElement {
        
        let object = createVariable { element in
            element.variableType = .string
            element.elementName = "input"
            element.class("hidden-input")
            element.id("hiddenInput_\(element.builderId)")
            element.addAttribute(.name(element.builderId))
            element.addAttribute(.type("hidden"))
            element.setInitialValue(value)
            element.addAttribute(.initialValue(value))
            element.addAttribute(.value(value))
            
            // observer to keep hidden field in sync
            element.createWebVariableFunctions()
        }
        
        return object
        
    }
    
    @discardableResult
    func WArray(_ values: [String]) -> WebVariableElement {
        
        let object = createVariable { element in
            element.variableType = .array
            element.elementName = "input"
            element.class("hidden-input")
            element.id("hiddenInput_\(element.builderId)")
            element.addAttribute(.pair("name", element.builderId))
            element.addAttribute(.type("hidden"))
            element.setInitialValue(values)
            element.addAttribute(.initialValue(values))
            if let json = try? JSONSerialization.data(withJSONObject: values, options: []),
               let encoded = String(data: json, encoding: .utf8) {
                element.addAttribute(.value(encoded))
            } else {
                element.addAttribute(.value("[]"))
            }
            
            // observer to keep hidden field in sync
            element.createWebVariableFunctions()
        }
        
        return object
        
    }
    
}
