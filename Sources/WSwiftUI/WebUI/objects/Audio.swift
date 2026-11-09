//
//  Audio.swift
//  SWWebAppServer
//
//  Created by Adrian on 30/01/2026.
//
import Foundation

public class WebAudioElement: WebElement {}

public extension WebAudioElement {

    /// Hides the audio player from the page
    @discardableResult
    func hidden() -> Self {
        addAttribute(.style("display: none;"))
        return self
    }

    /// Enables autoplay on the audio element
    @discardableResult
    func autoplay() -> Self {
        addAttribute(.custom("autoplay"))
        return self
    }

    /// Shows playback controls (enabled by default)
    @discardableResult
    func controls(_ show: Bool = true) -> Self {
        if !show {
            attributes.removeAll(where: {
                if case .custom(let v) = $0, v == "controls" { return true }
                return false
            })
        }
        return self
    }

    /// Loops the audio playback
    @discardableResult
    func loop() -> Self {
        addAttribute(.custom("loop"))
        return self
    }

    /// Mutes the audio by default
    @discardableResult
    func muted() -> Self {
        addAttribute(.custom("muted"))
        return self
    }

    /// Sets the preload strategy ("none", "metadata", "auto")
    @discardableResult
    func preload(_ value: String) -> Self {
        addAttribute(.custom("preload=\"\(WebEscape.attribute(value))\""))
        return self
    }
}


public extension CoreWebEndpoint {

    fileprivate func create(_ init: (_ element: WebAudioElement) -> Void) -> WebAudioElement {
        let element = WebAudioElement()
        populateCreatedObject(element)
        `init`(element)
        return element
    }

    @discardableResult
    func Audio(_ src: String) -> WebAudioElement {
        let audio: WebAudioElement = create { el in
            el.elementName = "audio"
            el.class(el.builderId)
            el.src(src)
            el.addAttribute(.custom("controls"))
        }
        return audio
    }
}
