//
//  Image.swift
//  SWWebAppServer
//
//  Created by Adrian on 05/07/2025.
//
import Foundation

public class WebImageElement: WebElement {
    /// The endpoint that built the image, for reporting misuse found by its modifiers.
    internal weak var builder: CoreWebEndpoint?
}

public extension WebImageElement {

    /// Adds Bootstrap’s `.img-fluid` class
    @discardableResult
    func responsive() -> Self {
        addAttribute(.class("img-fluid"))
        return self
    }

    /// Adds Bootstrap’s `.img-thumbnail` class
    @discardableResult
    func thumbnail() -> Self {
        addAttribute(.class("img-thumbnail"))
        return self
    }

    /// Adds a `rounded` class
    @discardableResult
    func rounded() -> Self {
        addAttribute(.class("rounded"))
        return self
    }
    
    /// Enables native lazy-loading (`loading="lazy"`)
    @discardableResult
    func lazyLoad() -> Self {
        addAttribute(.custom("loading=\"lazy\""))
        return self
    }

    /// Sets object-fit via inline style
    @discardableResult
    func objectFit(_ fit: String) -> Self {
        // e.g. "cover", "contain", etc.
        addAttribute(.style("object-fit: \(fit);"))
        return self
    }
    
    /// Reloads the contents of the image every `seconds` seconds.
    ///
    /// The interval is at least 0.1 s, and at most about 24.8 days (2^31 - 1 ms, the longest delay a
    /// browser timer holds; a longer one would fire after 1 ms), so `.infinity` reloads practically never.
    /// `seconds` that is not a number (NaN) is reported as builder misuse and adds no reload.
    @discardableResult
    func reloadImage(seconds: Double) -> Self {
        guard seconds.isNaN == false else {
            // `Int(NaN * 1000)` used to stop the process
            builder?.misuse("reloadImage(seconds:) needs a number of seconds (got NaN); the image is not reloaded")
            return self
        }
        let intervalMs = imageReloadIntervalMilliseconds(seconds)
        let id = self.builderId

        let js = """
        (function() {
            function setup() {
                var els = document.getElementsByClassName("\(id)");
                if (!els || !els.length) { return; }
                var img = els[0];

                // Clear any existing interval attached to this image
                if (img && img.dataset && img.dataset.reloadIntervalId) {
                    try { clearInterval(Number(img.dataset.reloadIntervalId)); } catch (e) {}
                }

                function reload() {
                    if (!img) { return; }
                    var src = img.getAttribute('src') || '';
                    try {
                        var url = new URL(src, window.location.href);
                        url.searchParams.set('_ts', Date.now().toString());
                        img.src = url.toString();
                    } catch (e) {
                        // Fallback: simple cache-buster if URL constructor fails
                        var sep = src.indexOf('?') === -1 ? '?' : '&';
                        img.src = src + sep + '_ts=' + Date.now();
                    }
                }

                var id = setInterval(reload, \(intervalMs));
                if (img && img.dataset) {
                    img.dataset.reloadIntervalId = String(id);
                }
            }

            if (document.readyState === 'loading') {
                document.addEventListener('DOMContentLoaded', setup, { once: true });
            } else {
                setup();
            }
        })();
        """

        addAttribute(.script(js))
        return self
    }
}


public extension CoreWebEndpoint {
    
    fileprivate func create(_ init: (_ element: WebImageElement) -> Void) -> WebImageElement {
        
        let element = WebImageElement()
        populateCreatedObject(element)
        `init`(element)
        return element
        
    }
    
    @discardableResult
    func Image(_ src: String, alt: String = "") -> WebImageElement {
        // (the builderId class, which `reloadImage` targets, comes from populateCreatedObject)
        let img: WebImageElement = create { el in
            el.elementName = "img"
            el.src(src)
            if !alt.isEmpty { el.alt(alt) }
            el.builder = self
        }
        return img
    }
}

/// The `setInterval` delay for `reloadImage(seconds:)`: `seconds` (not NaN) in whole milliseconds, at least
/// 100 and at most 2^31 - 1. Converting an infinite or huge `seconds` to Int used to stop the process.
fileprivate func imageReloadIntervalMilliseconds(_ seconds: Double) -> Int {
    let maxMilliseconds = 2_147_483_647.0
    let milliseconds = (Swift.max(seconds, 0.1) * 1000).rounded(.towardZero)
    return Int(Swift.min(milliseconds, maxMilliseconds))
}

