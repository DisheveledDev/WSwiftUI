//
//  FileUploader.swift
//  WSwiftUI
//
//  Created by Adrian Herridge on 18/08/2025.
//

import Foundation

// 1) Dedicated subclass
public class WebFileUploaderElement: WebElement {}

// 2) Fluent config
public extension WebFileUploaderElement {
    /// Where to send the uploads
    @discardableResult
    func uploadURL(_ url: String) -> Self {
        addAttribute(.pair("data-upload-url", url))
        return self
    }
    
    /// HTTP method (defaults to POST)
    @discardableResult
    func method(_ method: String) -> Self {
        addAttribute(.pair("data-method", method))
        return self
    }
    
    /// Field name for the file(s) in multipart form
    @discardableResult
    func fieldName(_ name: String) -> Self {
        addAttribute(.pair("data-field-name", name))
        return self
    }
    
    /// Parallel uploads (concurrency)
    @discardableResult
    func parallelUploads(_ n: Int) -> Self {
        addAttribute(.pair("data-parallel", "\(max(1, n))"))
        return self
    }
    
    /// Attach extra fields (e.g. auth tokens) sent with each request. They are written as JSON with sorted
    /// keys, so the same fields always give the same page.
    @discardableResult
    func extraFields(_ fields: [String: String]) -> Self {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if !fields.isEmpty,
           let json = try? String(data: encoder.encode(fields), encoding: .utf8) {
            // Pass the raw JSON: `.pair` values are HTML-escaped by the renderer, so escaping the
            // quotes here as well would double-escape them and break `JSON.parse` on the client.
            addAttribute(.pair("data-extra", json))
        }
        return self
    }
}

// 3) DSL on CoreWebEndpoint
public extension CoreWebEndpoint {
    
    /// Internal helper for creating uploader elements
    fileprivate func createUploader(_ `init`: (_ element: WebFileUploaderElement) -> Void) -> WebFileUploaderElement {
        let element = WebFileUploaderElement()
        populateCreatedObject(element)
        `init`(element)
        return element
    }
    
    /// File drop uploader with overall progress bar
    ///
    /// - Parameters:
    ///   - action: URL to POST/PUT files to
    ///   - method: HTTP method (default "POST")
    ///   - fieldName: multipart key (default "files[]")
    ///   - parallelUploads: number of concurrent uploads (default 3)
    ///   - extraFields: extra multipart fields to include (e.g. ["token": "..."])
    ///   - onUpload: actions to run once per-file when that file completes (success or failure).
    @discardableResult
    func FileUploader(
        action url: String,
        method: String = "POST",
        fieldName: String = "files[]",
        parallelUploads: Int = 3,
        extraFields: [String: String] = [:],
        onUpload: [WebAction]? = nil,
        _ content: WebComposerClosure
    ) -> WebFileUploaderElement {
        
        let uploader = createUploader { el in
            el.elementName = "div"
            el.class("border")
            el.class("rounded")
            el.class("wsui-file-uploader")
            el.class("p-3")
            el.class("file-uploader")
            el.id(el.builderId)
            
            el.uploadURL(url)
                .method(method)
                .fieldName(fieldName)
                .parallelUploads(parallelUploads)
                .extraFields(extraFields)
        }
        
        // Put uploader on the stack so user content nests inside it, followed by the progress UI and the
        // hidden file input
        withParent(uploader) {
            content()

            // Progress UI: the bar inside its track (it used to be created next to the track, so the bar
            // was drawn under an empty grey track)
            let track = createUploader { el in
                el.elementName = "div"
                el.class("progress")
                el.class("mt-2")
                el.addAttribute(.pair("style", "pointer-events:none;"))
                el.addAttribute(.pair("id", "progress_\(uploader.builderId)"))
            }
            withParent(track) {
                _ = createUploader { bar in
                    bar.elementName = "div"
                    bar.class("progress-bar")
                    bar.addAttribute(.pair("role", "progressbar"))
                    bar.addAttribute(.pair("style", "width:0%"))
                    bar.addAttribute(.pair("aria-valuemin", "0"))
                    bar.addAttribute(.pair("aria-valuemax", "100"))
                    bar.addAttribute(.pair("aria-valuenow", "0"))
                    bar.addAttribute(.pair("id", "progressbar_\(uploader.builderId)"))
                }
            }

            // Hidden file input for click-to-upload
            _ = createUploader { input in
                input.elementName = "input"
                input.type("file")
                input.addAttribute(.pair("id", "fileinput_\(uploader.builderId)"))
                input.addAttribute(.pair("multiple","multiple"))
                input.addAttribute(.pair("style", "display:none;"))
            }
        }

        // Compile actions
        let onUploadJS = onUpload.map { CompileActions($0, builderId: uploader.builderId) } ?? ""
        
        // Wire up drag&drop + uploads via XHR (for upload progress events)
        uploader.script("""
(function() {
    var zone = document.getElementById('\(uploader.builderId)');
    if (!zone) return;

    // --- Prevent browser navigation on file drop (outside drop zones only) ---
    if (!window.__wsuFileDropBlockerInstalled) {
        window.__wsuFileDropBlockerInstalled = true;

        document.addEventListener('dragover', function(e) { e.preventDefault(); }, false);

        document.addEventListener('drop', function(e) {
            var t = e.target;
            var insideUploader = false;
            while (t && t !== document) {
                if ((t.classList && t.classList.contains('file-uploader')) ||
                    (t.getAttribute && t.getAttribute('data-upload-url'))) {
                    insideUploader = true;
                    break;
                }
                t = t.parentElement;
            }
            if (!insideUploader) e.preventDefault();
        }, false);
    }

    // Make zone accessible/clickable
    zone.setAttribute('tabindex', '0');
    zone.setAttribute('role', 'button');
    try { zone.style.cursor = 'pointer'; } catch (_) {}

    var progressBar = document.getElementById('progressbar_\(uploader.builderId)');
    var fileInput   = document.getElementById('fileinput_\(uploader.builderId)');

    // Optional accept types via data-accept on the zone
    var accept = zone.getAttribute('data-accept');
    if (accept && fileInput) fileInput.setAttribute('accept', accept);

    function setProgress(p) {
        if (!progressBar) return;
        var pct = Math.max(0, Math.min(100, Math.floor(p)));
        progressBar.style.width = pct + '%';
        progressBar.setAttribute('aria-valuenow', pct);
        progressBar.textContent = pct + '%';
    }

    var uploadURL = zone.getAttribute('data-upload-url') || '';
    if (!uploadURL) { console.warn('FileUploader: missing data-upload-url'); }
    var method    = zone.getAttribute('data-method') || 'POST';
    var fieldName = zone.getAttribute('data-field-name') || 'files[]';
    var parallel  = Math.max(1, parseInt(zone.getAttribute('data-parallel') || '3', 10) || 3);
    var withCreds = zone.getAttribute('data-with-credentials') === 'true';

    var extra = {};
    try {
        var extraAttr = zone.getAttribute('data-extra');
        if (extraAttr) extra = JSON.parse(extraAttr);
    } catch (_) { /* ignore malformed JSON */ }

    function preventDefaults(e) { e.preventDefault(); }

    // Zone-level handlers
    ['dragenter','dragover','dragleave','drop'].forEach(function(ev) {
        zone.addEventListener(ev, preventDefaults, false);
    });

    zone.addEventListener('dragover', function(e) {
        if (e.dataTransfer) e.dataTransfer.dropEffect = 'copy';
        zone.classList.add('bg-light');
    }, false);

    zone.addEventListener('dragleave', function() {
        zone.classList.remove('bg-light');
    }, false);

    zone.addEventListener('drop', function(e) {
        zone.classList.remove('bg-light');
        var files = (e.dataTransfer && e.dataTransfer.files) ? Array.from(e.dataTransfer.files) : [];
        if (files.length) uploadFiles(files);
    }, false);

    // Click/keyboard to open chooser
    if (fileInput) {
        zone.addEventListener('click', function() {
            fileInput.value = "";
            fileInput.click();
        }, false);

        zone.addEventListener('keydown', function(e) {
            if (e.key === 'Enter' || e.key === ' ') {
                e.preventDefault();
                fileInput.value = "";
                fileInput.click();
            }
        }, false);

        fileInput.addEventListener('change', function() {
            var files = Array.from(fileInput.files || []);
            if (files.length) uploadFiles(files);
        }, false);
    }

    // Single place to invoke your compiled actions with a context
    function runOnUpload(ctx) {
        try {
            (function(){
                var upload = ctx; // <- your actions can read upload
                \(onUploadJS)
            })();
        } catch (e) {
            console && console.warn && console.warn('onUpload actions error', e);
        }
    }

    function uploadFiles(files) {
        var totalBytes = files.reduce(function(sum, f) { return sum + (f.size || 0); }, 0);
        var uploadedBytes = 0;
        var inFlight = 0;
        var nextIndex = 0;       // next file position to send
        var completed = 0;       // completed files (success or error)
        var count = files.length;

        function next() {
            while (inFlight < parallel && nextIndex < files.length) {
                var pos = nextIndex++;
                send(files[pos], pos);
            }
            if (inFlight === 0 && completed >= count) {
                setTimeout(function(){ setProgress(0); }, 800);
            }
        }

        function send(file, index) {
            inFlight++;

            var form = new FormData();
            form.append(fieldName, file, file.name);
            Object.keys(extra).forEach(function(k){ form.append(k, extra[k]); });

            var xhr = new XMLHttpRequest();
            var lastLoaded = 0;

            if (withCreds) xhr.withCredentials = true;
            xhr.open(method, uploadURL, true);

            // Overall progress across all files
            xhr.upload.onprogress = function(e) {
                if (e.lengthComputable) {
                    var delta = e.loaded - lastLoaded;
                    lastLoaded = e.loaded;
                    uploadedBytes += Math.max(0, delta);
                    var pct = totalBytes > 0 ? (uploadedBytes / totalBytes) * 100 : 100;
                    setProgress(pct);
                }
            };

            function finalize(ok) {
                // Build a context for actions
                var ctx = {
                    fileName: file && file.name || '',
                    size: file && file.size || 0,
                    type: file && file.type || '',
                    index: index,       // 0-based
                    count: count,       // total files in this batch
                    ok: !!ok,           // did it succeed (2xx)?
                    status: xhr.status || 0,
                    responseText: (function(){ try { return xhr.responseText || ''; } catch(_) { return ''; } })()
                };
                runOnUpload(ctx);
            }

            xhr.onerror = function() {
                console.error('FileUploader: upload network error', { file: file.name });
                finalize(false);
            };

            xhr.onload = function() {
                var ok = (xhr.status >= 200 && xhr.status < 300);
                if (!ok) {
                    console.error('FileUploader: upload failed', { file: file.name, status: xhr.status, response: xhr.responseText });
                }
                finalize(ok);
            };

            xhr.onreadystatechange = function() {
                if (xhr.readyState === 4) {
                    inFlight--;
                    completed++;
                    next();
                }
            };

            xhr.send(form);
        }

        setProgress(1);
        next();
    }
})();
""")
        return uploader
    }
}
