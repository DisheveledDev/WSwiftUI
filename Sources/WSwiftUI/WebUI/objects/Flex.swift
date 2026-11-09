//
//  Flex.swift
//  SWWebAppServer
//
//  Created by Adrian on 08/07/2025.
//

import Foundation

// 1) Subclass for Flex container
public class WebFlexElement: WebElement {}

// 2) Enums for Flex properties
public enum FlexDirection: String {
    case row = "flex-row"
    case rowReverse = "flex-row-reverse"
    case column = "flex-column"
    case columnReverse = "flex-column-reverse"
}

public enum FlexWrap: String {
    case noWrap = "flex-nowrap"
    case wrap = "flex-wrap"
    case wrapReverse = "flex-wrap-reverse"
}

public enum FlexJustify: String {
    case start = "justify-content-start"
    case end = "justify-content-end"
    case center = "justify-content-center"
    case between = "justify-content-between"
    case around = "justify-content-around"
    case evenly = "justify-content-evenly"
}

public enum FlexAlignItems: String {
    case start = "align-items-start"
    case end = "align-items-end"
    case center = "align-items-center"
    case baseline = "align-items-baseline"
    case stretch = "align-items-stretch"
}

public enum FlexAlignSelf: String {
    case auto = "align-self-auto"
    case start = "align-self-start"
    case end = "align-self-end"
    case center = "align-self-center"
    case baseline = "align-self-baseline"
    case stretch = "align-self-stretch"
}

public enum FlexAlignContent: String {
    case start = "align-content-start"
    case end = "align-content-end"
    case center = "align-content-center"
    case between = "align-content-between"
    case around = "align-content-around"
    case stretch = "align-content-stretch"
}

// 3) Fluent modifiers on Flex container
public extension WebFlexElement {
    @discardableResult
    func direction(_ dir: FlexDirection) -> Self {
        addAttribute(.class(dir.rawValue))
        return self
    }

    @discardableResult
    func wrap(_ wrap: FlexWrap) -> Self {
        addAttribute(.class(wrap.rawValue))
        return self
    }

    @discardableResult
    func justify(_ justify: FlexJustify) -> Self {
        addAttribute(.class(justify.rawValue))
        return self
    }

    @discardableResult
    func alignItems(_ align: FlexAlignItems) -> Self {
        addAttribute(.class(align.rawValue))
        return self
    }

    @discardableResult
    func alignContent(_ align: FlexAlignContent) -> Self {
        addAttribute(.class(align.rawValue))
        return self
    }

    /// Makes flex container full width
    @discardableResult
    func fullWidth(_ on: Bool = true) -> Self {
        if on { addAttribute(.class("w-100")) }
        return self
    }

    /// Makes flex container full height
    @discardableResult
    func fullHeight(_ on: Bool = true) -> Self {
        if on { addAttribute(.class("h-100")) }
        return self
    }
}

// 4) Fluent modifier on items: align-self
public extension WebElement {
    @discardableResult
    func alignSelf(_ align: FlexAlignSelf) -> Self {
        addAttribute(.class(align.rawValue))
        return self
    }
}

// 5) DSL factory on BaseWebEndpoint
public extension CoreWebEndpoint {
    /// Creates a <div class="d-flex"> flex container
    @discardableResult
    func Flex(_ content: WebComposerClosure) -> WebFlexElement {
        let flex = WebFlexElement()
        populateCreatedObject(flex)
        flex.elementName = "div"
        flex.addAttribute(.class("d-flex"))
        flex.addAttribute(.class("wsui-flex"))
        return withParent(flex, content)
    }
}
