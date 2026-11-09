//
//  Html.swift
//  SWWebAppServer
//
//  Created by Adrian on 04/07/2025.
//

public extension CoreWebEndpoint {
    
    /// Groups the page content. The page is a fragment: it adds no element of its own, so its children
    /// are emitted straight into `<body>` (the renderer writes the doctype, `<html lang="en">` and `<head>`).
    /// Elements created before or after it outside any container, such as state declared at the top of
    /// `content()`, are emitted at the top level of `<body>` in creation order.
    @discardableResult
    func webpage(_ closure: WebComposerClosure) -> WebElement {
        let object = WebFragmentElement()
        populateCreatedObject(object)
        // unwinds back to the page even if a builder inside forgot to pop itself
        return withParent(object, closure)
    }
    
}
