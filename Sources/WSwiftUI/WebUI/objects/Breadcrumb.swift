// MARK: – Breadcrumb element types
public class WebBreadcrumbElement: WebElement {}
public class WebBreadcrumbListElement: WebElement {}
public class WebBreadcrumbItemElement: WebElement {}

public extension CoreWebEndpoint {
  
  /// `<nav aria-label="breadcrumb"><ol class="breadcrumb">…</ol></nav>`
  @discardableResult
  func Breadcrumb(_ content: WebComposerClosure) -> WebBreadcrumbElement {
    // 1) <nav aria-label="breadcrumb" class="breadcrumb-container">
    let nav = WebBreadcrumbElement()
    populateCreatedObject(nav)
    nav.elementName = "nav"
    nav.addAttribute(.class("breadcrumb-container"))
    nav.addAttribute(.class("wsui-breadcrumb"))
    nav.addAttribute(.pair("aria-label", "breadcrumb"))
    stack.append(nav)
    
    // 2) <ol class="breadcrumb">
    let list = WebBreadcrumbListElement()
    populateCreatedObject(list)
    list.elementName = "ol"
    list.addAttribute(.class("breadcrumb"))
    stack.append(list)
    
    // 3) user items
    content()
    
    // 4) unwind
    stack.removeLast()  // list
    stack.removeLast()  // nav
    return nav
  }
  
  /// `<li class="breadcrumb-item[ active]"><a href="…">title</a></li>`
  @discardableResult
  func BreadcrumbItem(
    title: String,
    url: String,
    active: Bool = false
  ) -> WebBreadcrumbItemElement {
    // <li>
    let li = WebBreadcrumbItemElement()
    populateCreatedObject(li)
    li.elementName = "li"
      li.addAttribute(.dontRegisterObject)
    var cls = "breadcrumb-item"
    if active {
      cls += " active"
      li.addAttribute(.pair("aria-current", "page"))
    }
    li.addAttribute(.class(cls))
    stack.append(li)
    
    // <a>
    let a = WebElement()
    populateCreatedObject(a)
    a.elementName = "a"
    a.addAttribute(.dontRegisterObject)
    a.addAttribute(.pair("href", url))
    a.innerHTML(WebEscape.html(title))
    
    // pop <li>
    stack.removeLast()
    return li
  }
}
