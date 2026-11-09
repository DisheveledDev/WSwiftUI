//
//  Phase1FormsLiveUpdateTests.swift
//  WSwiftUITests
//
//  H12 (DATA-4 / DATA-17 / missed "liveUpdate ignores errors"): the rendered liveUpdate runtime is run in a
//  browser-like Node.js context with a scripted fetch and a manual clock. It must not throw, must poll,
//  must register related variables declared after it, must send the first edit, must debounce writes,
//  must ignore stale and out-of-order responses, and must surface the transaction's errors.
//

import Foundation
import Testing
@testable import WSwiftUI

@Suite("Phase 1 forms: liveUpdate runtime (H12)", .enabled(if: NodeJS.isAvailable))
struct Phase1FormsLiveUpdateTests {

    struct Page {
        var html: String
        var name: String       // WString "name", owns the liveUpdate
        var age: String        // WInt "age", related, declared after `name`
        var nameField: String  // TextField bound to name
        var ageField: String   // TextField bound to age
    }

    final class Box: @unchecked Sendable { var ids: [String] = [] }

    /// `name` (with liveUpdate) is created before `age`, so `age`'s functions do not exist yet when the
    /// liveUpdate script runs. A later DOMContentLoaded script records that it ran.
    static func render(pollEverySeconds: Int? = 5, actions: [WebVariableLiveUpdateActions] = [.read, .write]) -> Page {
        let box = Box()
        let html = renderHTML { page in
            let name = page.WString("Ann").name("name")
            let age = page.WInt(7).name("age")
            name.liveUpdate(url: "/live", reference: "cust-1", actions: actions, related: [age],
                            pollEverySeconds: pollEverySeconds)
            let nameField = page.TextField(binding: name)
            let ageField = page.TextField(binding: age, type: .number)
            page.Text("marker").addAttribute(.domLoadedScript("window.__laterScriptRan = true;"))
            box.ids = [name.builderId, age.builderId, nameField.builderId, ageField.builderId]
        }
        return Page(html: html, name: box.ids[0], age: box.ids[1], nameField: box.ids[2], ageField: box.ids[3])
    }

    /// JS prelude giving the scenario the page's ids.
    static func ids(_ page: Page) -> String {
        """
        const NAME = \(WebJSON.scriptString(page.name)), AGE = \(WebJSON.scriptString(page.age));
        const NAME_FIELD = \(WebJSON.scriptString(page.nameField)), AGE_FIELD = \(WebJSON.scriptString(page.ageField));
        const set = function (id, value) { h.win['updateWebVariable' + id](value, { source: 'input', origin: 'test' }); };
        """
    }

    @Test func loadsWithoutErrorsAndRunsLaterScripts() throws {
        let page = Self.render()
        let outcome = try FormsBrowser.run(html: page.html, scenario: Self.ids(page) + """
            h.fireDOMContentLoaded();
            await h.settle();
            return {
              laterRan: h.win.__laterScriptRan === true,
              startPolling: typeof h.win['startPolling_' + NAME],
              ageField: String(h.el('class:' + AGE_FIELD).value),
              ageCarrier: String(h.el('hiddenInput_' + AGE).value),
              fetches: h.fetches.length
            };
            """)
        #expect(outcome.errors.isEmpty, "\(outcome.errors)")
        #expect(outcome.result["laterRan"] as? Bool == true, "a DOMContentLoaded script after liveUpdate did not run")
        #expect(outcome.result["startPolling"] as? String == "function")
        // the initial sync of the related variable ran
        #expect(outcome.result["ageField"] as? String == "7")
        #expect(outcome.result["ageCarrier"] as? String == "7")
        // loading the page (initial syncs) writes nothing
        #expect(outcome.result["fetches"] as? Int == 0)
    }

    @Test func firstEditIsSentAfterTheDebounce() throws {
        let page = Self.render()
        let outcome = try FormsBrowser.run(html: page.html, scenario: Self.ids(page) + """
            h.fireDOMContentLoaded();
            await h.settle();
            set(NAME, 'B');
            set(NAME, 'Bo');
            await h.advance(50);
            set(NAME, 'Bob');
            await h.advance(100);
            const duringTyping = h.fetches.length;
            await h.advance(1000);
            return { duringTyping: duringTyping, bodies: h.bodies() };
            """)
        #expect(outcome.errors.isEmpty, "\(outcome.errors)")
        #expect(outcome.result["duringTyping"] as? Int == 0, "writes are not debounced")
        let bodies = try #require(outcome.result["bodies"] as? [[String: Any]])
        #expect(bodies.count == 1, "expected exactly one write for the first edit, got \(bodies.count)")
        let first = try #require(bodies.first)
        #expect(first["reference"] as? String == "cust-1")
        #expect(first["read"] as? Bool == false)
        #expect(first["write"] as? Bool == true)
        let data = try #require(first["data"] as? [String: Any])
        #expect(data["name"] as? String == "Bob")
        #expect(data["age"] as? Int == 7)
    }

    @Test func relatedVariableDeclaredLaterTriggersWrites() throws {
        let page = Self.render()
        let outcome = try FormsBrowser.run(html: page.html, scenario: Self.ids(page) + """
            h.fireDOMContentLoaded();
            await h.settle();
            set(AGE, 9);
            await h.advance(1000);
            return { bodies: h.bodies() };
            """)
        #expect(outcome.errors.isEmpty, "\(outcome.errors)")
        let bodies = try #require(outcome.result["bodies"] as? [[String: Any]])
        #expect(bodies.count == 1)
        let data = try #require(bodies.first?["data"] as? [String: Any])
        #expect(data["age"] as? Int == 9)
        #expect(data["name"] as? String == "Ann")
    }

    @Test func pollingReadsAndAppliesWithoutEchoingAWrite() throws {
        let page = Self.render()
        let outcome = try FormsBrowser.run(html: page.html, scenario: Self.ids(page) + """
            h.fireDOMContentLoaded();
            await h.settle();
            await h.advance(4999);
            const beforeInterval = h.fetches.length;
            await h.advance(1);
            const poll = h.bodies().slice();
            await h.respond(0, { reference: 'cust-1', read: true, write: false, data: { name: 'Server', age: 12 } });
            await h.advance(1000);
            return {
              beforeInterval: beforeInterval, poll: poll, fetchesAfterApply: h.fetches.length,
              name: h.win[NAME], age: h.win[AGE],
              nameField: String(h.el('class:' + NAME_FIELD).value),
              ageCarrier: String(h.el('hiddenInput_' + AGE).value)
            };
            """)
        #expect(outcome.errors.isEmpty, "\(outcome.errors)")
        #expect(outcome.result["beforeInterval"] as? Int == 0)
        let poll = try #require(outcome.result["poll"] as? [[String: Any]])
        #expect(poll.count == 1)
        #expect(poll.first?["read"] as? Bool == true)
        #expect(poll.first?["write"] as? Bool == false)
        #expect(outcome.result["name"] as? String == "Server")
        #expect(outcome.result["age"] as? Int == 12)
        #expect(outcome.result["nameField"] as? String == "Server")
        #expect(outcome.result["ageCarrier"] as? String == "12")
        // applying the server's values did not schedule a write back
        #expect(outcome.result["fetchesAfterApply"] as? Int == 1)
    }

    @Test func staleAndOutOfOrderResponsesAreIgnored() throws {
        let page = Self.render(pollEverySeconds: nil)
        let outcome = try FormsBrowser.run(html: page.html, scenario: Self.ids(page) + """
            h.fireDOMContentLoaded();
            await h.settle();
            // a read is in flight when the user edits: its (older) answer must not overwrite the edit
            h.win['liveRead_' + NAME]();
            const read = h.last();
            set(NAME, 'Local');
            await h.advance(1000);
            const write = h.last();
            await h.respond(write, { data: { name: 'Local' } });
            await h.respond(read, { data: { name: 'Stale' } });
            const afterStale = h.win[NAME];
            // two reads answered in reverse order: the older answer is dropped
            h.win['liveRead_' + NAME]();
            const r1 = h.last();
            h.win['liveRead_' + NAME]();
            const r2 = h.last();
            await h.respond(r2, { data: { name: 'Newer' } });
            await h.respond(r1, { data: { name: 'Older' } });
            return { read: read, write: write, afterStale: afterStale, afterReorder: h.win[NAME] };
            """)
        #expect(outcome.errors.isEmpty, "\(outcome.errors)")
        #expect(outcome.result["write"] as? Int != outcome.result["read"] as? Int, "the edit was not written")
        #expect(outcome.result["afterStale"] as? String == "Local")
        #expect(outcome.result["afterReorder"] as? String == "Newer")
    }

    @Test func transactionErrorsAndFailuresAreSurfaced() throws {
        let page = Self.render(pollEverySeconds: nil)
        let outcome = try FormsBrowser.run(html: page.html, scenario: Self.ids(page) + """
            h.fireDOMContentLoaded();
            await h.settle();
            const seen = [];
            h.win['addWebVariableEventListener' + AGE]('liveUpdateError', function (p) { seen.push('age:' + p.name + ':' + p.message); });
            h.win['addWebVariableEventListener' + NAME]('liveUpdateError', function (p) { seen.push('name:' + p.message + ':' + p.status); });
            set(AGE, 200);
            await h.advance(1000);
            await h.respond(h.last(), { reference: 'cust-1', read: false, write: true, data: {}, errors: { age: 'Too old' } });
            set(AGE, 201);
            await h.advance(1000);
            await h.respond(h.last(), null, 500);
            return { seen: seen, warnings: h.warnings.length };
            """)
        #expect(outcome.errors.isEmpty, "\(outcome.errors)")
        #expect(outcome.result["seen"] as? [String] == ["age:age:Too old", "name:HTTP 500:500"])
    }

    /// An edit waiting for its debounce is not overwritten by a read sent after it: polling skips while the
    /// edit is unsent, and a manual read's answer is ignored, so the write carries the user's value.
    @Test func readsDoNotOverwriteAnUnsentEdit() throws {
        let page = Self.render(pollEverySeconds: 5)
        let outcome = try FormsBrowser.run(html: page.html, scenario: Self.ids(page) + """
            h.fireDOMContentLoaded();
            await h.settle();
            await h.advance(4900);
            set(NAME, 'Typed');                 // write due at 5200, poll due at 5000
            await h.advance(150);
            const atPoll = h.bodies().slice();
            h.win['liveRead_' + NAME]();        // a manual read while the edit is unsent
            const read = h.last();
            await h.respond(read, { data: { name: 'Server' } });
            const afterRead = h.win[NAME];
            await h.advance(200);
            const write = h.fetches[h.last()].body;
            return { atPoll: atPoll.length, afterRead: afterRead, write: write };
            """)
        #expect(outcome.errors.isEmpty, "\(outcome.errors)")
        #expect(outcome.result["atPoll"] as? Int == 0, "polling read while an edit was unsent")
        #expect(outcome.result["afterRead"] as? String == "Typed")
        let write = try #require(outcome.result["write"] as? [String: Any])
        #expect(write["write"] as? Bool == true)
        #expect((write["data"] as? [String: Any])?["name"] as? String == "Typed")
    }

    /// Writes are not sent concurrently: an edit made while a write is in flight is sent after it.
    @Test func writesAreSerialized() throws {
        let page = Self.render(pollEverySeconds: nil)
        let outcome = try FormsBrowser.run(html: page.html, scenario: Self.ids(page) + """
            h.fireDOMContentLoaded();
            await h.settle();
            set(NAME, 'One');
            await h.advance(1000);
            set(NAME, 'Two');
            await h.advance(1000);
            const whileFirstInFlight = h.fetches.length;
            await h.respond(0, { data: { name: 'One' } });
            await h.advance(10);
            const bodies = h.bodies();
            await h.respond(1, { data: { name: 'Two' } });
            return { whileFirstInFlight: whileFirstInFlight, names: bodies.map(function (b) { return b.data.name; }), final: h.win[NAME] };
            """)
        #expect(outcome.errors.isEmpty, "\(outcome.errors)")
        #expect(outcome.result["whileFirstInFlight"] as? Int == 1)
        #expect(outcome.result["names"] as? [String] == ["One", "Two"])
        #expect(outcome.result["final"] as? String == "Two")
    }

    /// `onLiveUpdateError` runs its actions for the variable an error names; `writeDebounceMilliseconds: 0`
    /// writes immediately.
    @Test func onLiveUpdateErrorRunsActions() throws {
        let box = Box()
        let html = renderHTML { page in
            let name = page.WString("Ann").name("name")
                .onLiveUpdateError([.script("window.__nameErrors = (window.__nameErrors || []).concat([_eventPayload.message + '/' + _eventPayload.reference]);")])
            let age = page.WInt(7).name("age")
                .onLiveUpdateError([.script("window.__ageErrors = (window.__ageErrors || []).concat([_eventPayload.name + '=' + _eventPayload.message]);")])
            name.liveUpdate(url: "/live", reference: "ref-9", actions: [.write], related: [age],
                            pollEverySeconds: nil, writeDebounceMilliseconds: 0)
            box.ids = [name.builderId, age.builderId]
        }
        let page = Page(html: html, name: box.ids[0], age: box.ids[1], nameField: "", ageField: "")
        let outcome = try FormsBrowser.run(html: html, scenario: Self.ids(page) + """
            h.fireDOMContentLoaded();
            await h.settle();
            set(AGE, 8);
            const immediate = h.fetches.length;
            await h.respond(0, { errors: { age: 'Bad age', name: 'Bad name', other: 'Unknown field' } });
            return { immediate: immediate, ageErrors: h.win.__ageErrors || [], nameErrors: h.win.__nameErrors || [] };
            """)
        #expect(outcome.errors.isEmpty, "\(outcome.errors)")
        #expect(outcome.result["immediate"] as? Int == 1)
        #expect(outcome.result["ageErrors"] as? [String] == ["age=Bad age"])
        // errors for names outside the group go to the owner
        #expect(outcome.result["nameErrors"] as? [String] == ["Bad name/ref-9", "Unknown field/ref-9"])
    }

    /// An edit still waiting for its debounce is sent (keepalive) when the page is left.
    @Test func pendingWriteIsSentWhenThePageIsLeft() throws {
        let box = Box()
        let html = renderHTML { page in
            let name = page.WString("Ann").name("name")
            name.liveUpdate(url: "/live", reference: "r", actions: [.write], pollEverySeconds: nil,
                            writeDebounceMilliseconds: 60_000)
            box.ids = [name.builderId]
        }
        let page = Page(html: html, name: box.ids[0], age: "", nameField: "", ageField: "")
        let outcome = try FormsBrowser.run(html: html, scenario: Self.ids(page) + """
            h.fireDOMContentLoaded();
            await h.settle();
            h.fireWindow('pagehide');
            const withoutEdit = h.fetches.length;
            set(NAME, 'Leaving');
            await h.advance(10);
            const beforeLeave = h.fetches.length;
            h.fireWindow('pagehide');
            await h.settle();
            const f = h.fetches[0] || { options: {}, body: {} };
            return { withoutEdit: withoutEdit, beforeLeave: beforeLeave, count: h.fetches.length,
                     keepalive: f.options.keepalive === true, name: f.body && f.body.data && f.body.data.name };
            """)
        #expect(outcome.errors.isEmpty, "\(outcome.errors)")
        #expect(outcome.result["withoutEdit"] as? Int == 0)
        #expect(outcome.result["beforeLeave"] as? Int == 0)
        #expect(outcome.result["count"] as? Int == 1)
        #expect(outcome.result["keepalive"] as? Bool == true)
        #expect(outcome.result["name"] as? String == "Leaving")
    }

    /// An edit queued behind a write in flight (its debounce already fired) is sent when the page is left,
    /// not only an edit still waiting for its debounce.
    @Test func queuedWriteIsSentWhenThePageIsLeft() throws {
        let page = Self.render(pollEverySeconds: nil)
        let outcome = try FormsBrowser.run(html: page.html, scenario: Self.ids(page) + """
            h.fireDOMContentLoaded();
            await h.settle();
            set(NAME, 'One');
            await h.advance(400);               // write #0 in flight
            set(NAME, 'Two');
            await h.advance(400);               // debounced: queued behind #0
            const beforeLeave = h.fetches.length;
            h.fireWindow('pagehide');
            await h.settle();
            const afterLeave = h.fetches.length;  // sent at once, not after #0 is answered
            const leave = h.fetches[h.last()];
            const keepalive = leave.options.keepalive === true;
            // the first write's answer does not send the (already sent) edit again
            await h.respond(0, { data: { name: 'One' } });
            await h.respond(1, { data: { name: 'Two' } });
            await h.advance(1000);
            return { beforeLeave: beforeLeave, afterLeave: afterLeave, count: h.fetches.length, keepalive: keepalive,
                     names: h.bodies().map(function (b) { return b.data.name; }) };
            """)
        #expect(outcome.errors.isEmpty, "\(outcome.errors)")
        #expect(outcome.result["beforeLeave"] as? Int == 1)
        #expect(outcome.result["afterLeave"] as? Int == 2)
        #expect(outcome.result["count"] as? Int == 2)
        #expect(outcome.result["keepalive"] as? Bool == true)
        #expect(outcome.result["names"] as? [String] == ["One", "Two"])
    }

    /// An exception in the onRequest actions is reported to onLiveUpdateError and does not stop later
    /// writes or polls; an exception in the onResponse actions is only logged.
    @Test func aThrowingHookDoesNotStopLaterRequests() throws {
        let box = Box()
        let html = renderHTML { page in
            let name = page.WString("Ann").name("name")
                .onLiveUpdateError([.script("window.__errors = (window.__errors || []).concat([_eventPayload.message]);")])
            name.liveUpdate(url: "/live", reference: "r", actions: [.read, .write],
                            onRequest: [.script("if (!window.__thrown) { window.__thrown = true; throw new Error('boom'); }")],
                            onResponse: [.script("window.__responses = (window.__responses || 0) + 1; if (window.__responses === 1) { throw new Error('after'); }")],
                            pollEverySeconds: 5)
            box.ids = [name.builderId]
        }
        let page = Page(html: html, name: box.ids[0], age: "", nameField: "", ageField: "")
        let outcome = try FormsBrowser.run(html: html, scenario: Self.ids(page) + """
            h.fireDOMContentLoaded();
            await h.settle();
            set(NAME, 'One');
            await h.advance(400);               // onRequest throws: nothing is sent, the failure is reported
            const afterThrow = h.fetches.length;
            set(NAME, 'Two');
            await h.advance(400);               // the next edit is still written
            const afterSecond = h.fetches.length;
            const second = h.fetches[h.last()].body;
            await h.respond(h.last(), { data: { name: 'Two' } });
            await h.advance(5000);              // and polling still runs
            return { afterThrow: afterThrow, afterSecond: afterSecond, secondName: second.data.name,
                     polls: h.bodies().filter(function (b) { return b.read === true; }).length,
                     reported: h.win.__errors || [], responses: h.win.__responses || 0 };
            """)
        #expect(outcome.errors.isEmpty, "\(outcome.errors)")
        #expect(outcome.result["afterThrow"] as? Int == 0)
        #expect(outcome.result["afterSecond"] as? Int == 1)
        #expect(outcome.result["secondName"] as? String == "Two")
        #expect(outcome.result["polls"] as? Int == 1)
        #expect(outcome.result["reported"] as? [String] == ["boom"])
        #expect(outcome.result["responses"] as? Int == 2)
        #expect(outcome.warnings.contains { $0.contains("after") })
    }

    /// A manual read sent while a write is in flight may be answered with the values from before the
    /// write; its answer is ignored even when it arrives after the write was confirmed.
    @Test func aReadSentDuringAWriteIsNotApplied() throws {
        let page = Self.render(pollEverySeconds: nil)
        let outcome = try FormsBrowser.run(html: page.html, scenario: Self.ids(page) + """
            h.fireDOMContentLoaded();
            await h.settle();
            set(NAME, 'Local');
            await h.advance(400);               // write in flight
            const write = h.last();
            h.win['liveRead_' + NAME]();
            const read = h.last();
            await h.respond(write, { data: { name: 'Local' } });
            await h.respond(read, { data: { name: 'OldServer', age: 99 } });
            const afterRead = h.win[NAME];
            const ageAfterRead = h.win[AGE];
            // a read sent once the write was confirmed is applied
            h.win['liveRead_' + NAME]();
            await h.respond(h.last(), { data: { name: 'Fresh' } });
            return { write: write, read: read, afterRead: afterRead, ageAfterRead: ageAfterRead, final: h.win[NAME] };
            """)
        #expect(outcome.errors.isEmpty, "\(outcome.errors)")
        #expect(outcome.result["write"] as? Int == 0)
        #expect(outcome.result["read"] as? Int == 1)
        #expect(outcome.result["afterRead"] as? String == "Local")
        #expect(outcome.result["ageAfterRead"] as? Int == 7)
        #expect(outcome.result["final"] as? String == "Fresh")
    }

    /// A successful answer without a body (204, or a handler that returns none) is not an error. A 2xx
    /// body that is not JSON is, and it does not stop later writes.
    @Test func anEmptySuccessfulAnswerIsNotAnError() throws {
        let page = Self.render(pollEverySeconds: nil)
        let outcome = try FormsBrowser.run(html: page.html, scenario: Self.ids(page) + """
            h.fireDOMContentLoaded();
            await h.settle();
            const seen = [];
            h.win['addWebVariableEventListener' + NAME]('liveUpdateError', function (p) { seen.push(String(p.status)); });
            set(NAME, 'A');
            await h.advance(400);
            await h.respondText(h.last(), '', 200);
            set(NAME, 'B');
            await h.advance(400);
            await h.respondText(h.last(), '', 204);
            set(NAME, 'C');
            await h.advance(400);
            await h.respondText(h.last(), '   ', 200);
            const afterEmpty = seen.slice();
            set(NAME, 'D');
            await h.advance(400);
            await h.respondText(h.last(), '<html>not json</html>', 200);
            set(NAME, 'E');
            await h.advance(400);
            return { afterEmpty: afterEmpty, seen: seen, writes: h.fetches.length,
                     last: h.fetches[h.last()].body.data.name, name: h.win[NAME] };
            """)
        #expect(outcome.errors.isEmpty, "\(outcome.errors)")
        #expect(outcome.result["afterEmpty"] as? [String] == [])
        #expect(outcome.result["seen"] as? [String] == ["null"])
        #expect(outcome.result["writes"] as? Int == 5)
        #expect(outcome.result["last"] as? String == "E")
        #expect(outcome.result["name"] as? String == "E")
    }

    /// The liveUpdate script is valid as a classic browser script and keeps the hostile-input guarantees.
    @Test func liveUpdateScriptIsScriptSafe() throws {
        let html = renderHTML { page in
            let name = page.WString(Hostile.payload).name(Hostile.payload)
            name.liveUpdate(url: Hostile.payload, reference: Hostile.payload, actions: [.read, .write],
                            related: [page.WInt(1).name(Hostile.payload + "2")], pollEverySeconds: Int.max)
        }
        ScriptScan.expectNoBreakout(html)
        #expect(try NodeJS.nodeCheck(ScriptScan.inlineScripts(in: html)).isEmpty)
        // an enormous poll interval is clamped instead of overflowing setInterval
        #expect(html.contains("var pollEveryMs = \(ScriptValue.maxTimerDelay);"))
    }

    /// A read-only liveUpdate never writes, whatever the user does.
    @Test func readOnlyNeverWrites() throws {
        let page = Self.render(pollEverySeconds: 5, actions: [.read])
        let outcome = try FormsBrowser.run(html: page.html, scenario: Self.ids(page) + """
            h.fireDOMContentLoaded();
            await h.settle();
            set(NAME, 'Typed');
            await h.advance(1000);
            const afterEdit = h.fetches.length;
            await h.advance(4000);
            return { afterEdit: afterEdit, bodies: h.bodies() };
            """)
        #expect(outcome.errors.isEmpty, "\(outcome.errors)")
        #expect(outcome.result["afterEdit"] as? Int == 0)
        let bodies = try #require(outcome.result["bodies"] as? [[String: Any]])
        #expect(bodies.count == 1)
        #expect(bodies.first?["write"] as? Bool == false)
    }
}
