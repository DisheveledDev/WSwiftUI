//
//  Progress.swift
//  SWWebAppServer
//
//  Created by Adrian on 07/07/2025.
//

import Foundation

// 1) Dedicated subclasses for Progress container and bars
public class WebProgressElement: WebElement {}
public class WebProgressBarElement: WebElement {}


// 3) Fluent modifiers for Progress container
public extension WebProgressElement {
    /// Adds a height (e.g. "height: 1rem;")
    @discardableResult
    func height(_ cssValue: String) -> Self {
        addAttribute(.style("height: \(cssValue)"))
        return self
    }

    /// Enables stacking multiple bars (no extra class needed)
    @discardableResult
    func stackable() -> Self {
        return self
    }
}

// 4) Fluent modifiers for ProgressBar
public extension WebProgressBarElement {

    /// Sets aria-min and aria-max
    @discardableResult
    func range(min: Int = 0, max: Int = 100) -> Self {
        addAttribute(.custom("aria-valuemin=\"\(min)\""))
        addAttribute(.custom("aria-valuemax=\"\(max)\""))
        return self
    }

    /// Applies a contextual background (e.g. bg-success)
    @discardableResult
    func variant(_ variant: BootstrapVariant) -> Self {
        addAttribute(.variant(variant))
        addAttribute(.class("bg-\(variant.rawValue)"))
        return self
    }

    /// Applies striped styling
    @discardableResult
    func striped(_ on: Bool = true) -> Self {
        if on {
            addAttribute(.class("progress-bar-striped"))
        }
        return self
    }

    /// Animates stripes
    @discardableResult
    func animated(_ on: Bool = true) -> Self {
        if on {
            addAttribute(.class("progress-bar-animated"))
        }
        return self
    }
}

// 5) DSL factories on BaseWebEndpoint
public extension CoreWebEndpoint {
    /// Creates a <div class="progress"> container
    @discardableResult
    func Progress(_ content: WebComposerClosure) -> WebProgressElement {
        let progress = WebProgressElement()
        populateCreatedObject(progress)
        progress.elementName = "div"
        progress.addAttribute(.class("progress"))
        progress.addAttribute(.class("wsui-progress"))
        return withParent(progress, content)
    }

    // Every ProgressBar must sit inside a Progress { ... } (wrapper elements in between are allowed).
    // Anywhere else the mistake is logged, an HTML comment marks the spot and the bar is rendered where it
    // was declared.

    /// Static progress bar with given value
    @discardableResult
    func ProgressBar(value: Int,
                     max: Int = 100,
                     variant: BootstrapVariant? = nil,
                     striped: Bool = false,
                     animated: Bool = false) -> WebProgressBarElement {
        requireStructuralParent({ $0 is WebProgressElement }, among: { $0 is WebProgressElement },
                                "ProgressBar must be used inside Progress { ... } block")
        let bar = WebProgressBarElement()
        populateCreatedObject(bar)
        bar.elementName = "div"
        bar.addAttribute(.class("progress-bar"))
        bar.addAttribute(.pair("role", "progressbar"))
        let maxValue = max > 0 ? max : 1
        let clampedValue = Swift.min(Swift.max(value, 0), maxValue)
        let initialPct = Int((Double(clampedValue) / Double(maxValue)) * 100)
        bar.addAttribute(.style("width: \(initialPct)%"))
        bar.addAttribute(.pair("aria-valuenow", "\(clampedValue)"))
        bar.range(min: 0, max: maxValue)
        if let v = variant { bar.variant(v) }
        if striped { bar.striped() }
        if animated { bar.animated() }
        return bar
    }

    /// Dynamic progress bar bound to an Int variable
    @discardableResult
    func ProgressBar(_ variable: WebVariableElement,
                     max: Int = 100,
                     variant: BootstrapVariant? = nil,
                     striped: Bool = false,
                     animated: Bool = false) -> WebProgressBarElement {
        requireStructuralParent({ $0 is WebProgressElement }, among: { $0 is WebProgressElement },
                                "Bound ProgressBar must be inside Progress { ... } block")
        // create bar
        let bar = WebProgressBarElement()
        populateCreatedObject(bar)
        bar.elementName = "div"
        bar.addAttribute(.class("progress-bar"))
        bar.addAttribute(.pair("role", "progressbar"))
        // assign id for DOM updates
        let barId = "progressBar_\(bar.builderId)"
        bar.id(barId)
        // initial width from variable
        let maxValue = max > 0 ? max : 1
        let initial = variable.asInt()
        let clampedInitial = Swift.min(Swift.max(initial, 0), maxValue)
        let initialPct = Int((Double(clampedInitial) / Double(maxValue)) * 100)
        bar.addAttribute(.style("width: \(initialPct)%"))
        bar.addAttribute(.pair("aria-valuenow", "\(clampedInitial)"))
        bar.range(min: 0, max: maxValue)
        if let v = variant { bar.variant(v) }
        if striped { bar.striped() }
        if animated { bar.animated() }
        // Update immediately on each bound-variable callback (no polling loop).
        bar.addAttribute(.script("""
function updateVariable\(bar.builderId)(value, _meta) {
  var numeric = Number(value);
  if (!Number.isFinite(numeric)) {
    numeric = 0;
  }
  var clamped = Math.min(Math.max(numeric, 0), \(maxValue));
  var pct = (clamped / \(maxValue)) * 100;
  var el = document.getElementById('\(barId)');
  if (el) {
    el.style.width = pct + '%';
    el.setAttribute('aria-valuenow', String(clamped));
  }
}
addCallback\(variable.builderId)(updateVariable\(bar.builderId));
"""))
        return bar
    }

    /// Dynamic progress bar bound to a Double variable
    @discardableResult
    func ProgressBar(_ variable: WebVariableElement,
                     max: Double,
                     variant: BootstrapVariant? = nil,
                     striped: Bool = false,
                     animated: Bool = false) -> WebProgressBarElement {
        requireStructuralParent({ $0 is WebProgressElement }, among: { $0 is WebProgressElement },
                                "Bound ProgressBar must be inside Progress { ... } block")
        let bar = WebProgressBarElement()
        populateCreatedObject(bar)
        bar.elementName = "div"
        bar.addAttribute(.class("progress-bar"))
        bar.addAttribute(.pair("role", "progressbar"))
        let barId = "progressBar_\(bar.builderId)"
        bar.id(barId)
        // initial width from variable. NaN and infinity can't be drawn and would trap the Int conversions
        // (a Double parsed from user input can be either): a max that isn't a positive finite number
        // becomes 1, and a value that isn't finite becomes 0.
        let maxValue = (max.isFinite && max > 0) ? max : 1
        let rawInitial = variable.asDouble()
        let initial = rawInitial.isFinite ? rawInitial : 0
        let clampedInitial = Swift.min(Swift.max(initial, 0), maxValue)
        let initPct = Int((clampedInitial / maxValue) * 100)
        bar.addAttribute(.style("width: \(initPct)%"))
        bar.addAttribute(.pair("aria-valuenow", "\(clampedInitial)"))
        bar.range(min: 0, max: progressIntBound(maxValue))
        if let v = variant { bar.variant(v) }
        if striped { bar.striped() }
        if animated { bar.animated() }
        bar.addAttribute(.script("""
function updateVariable\(bar.builderId)(value, _meta) {
  var numeric = Number(value);
  if (!Number.isFinite(numeric)) {
    numeric = 0;
  }
  var clamped = Math.min(Math.max(numeric, 0), \(maxValue));
  var pct = (clamped / \(maxValue)) * 100;
  var el = document.getElementById('\(barId)');
  if (el) {
    el.style.width = pct + '%';
    el.setAttribute('aria-valuenow', String(clamped));
  }
}
addCallback\(variable.builderId)(updateVariable\(bar.builderId));
"""))
        return bar
    }
}

/// `value` (positive and finite) as an Int without trapping: values too large for an Int become `Int.max`.
fileprivate func progressIntBound(_ value: Double) -> Int {
    // Double(Int.max) rounds up to 2^63, which does not fit; every Double below it does.
    return value >= Double(Int.max) ? Int.max : Int(value)
}
