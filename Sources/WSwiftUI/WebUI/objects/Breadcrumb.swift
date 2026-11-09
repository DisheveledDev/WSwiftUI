// MARK: – Breadcrumb element types
public class WebBreadcrumbElement: WebElement {}
public class WebBreadcrumbListElement: WebElement {}
public class WebBreadcrumbItemElement: WebElement {}

public extension CoreWebEndpoint {
  
  /// `<nav aria-label="breadcrumb"><ol class="breadcrumb">…</ol></nav>`
  @discardableResult
  func Breadcrumb(_ content: WebComposerClosure) -> WebBreadcrumbElement {
    // 1) <nav aria-label="breadcrumb" class="wsui-breadcrumb"> (no `breadcrumb-container`: Bootstrap has
    //    no such class)
    let nav = WebBreadcrumbElement()
    populateCreatedObject(nav)
    nav.elementName = "nav"
    nav.addAttribute(.class("wsui-breadcrumb"))
    nav.addAttribute(.pair("aria-label", "breadcrumb"))
    return withParent(nav) {
      // 2) <ol class="breadcrumb">
      let list = WebBreadcrumbListElement()
      populateCreatedObject(list)
      list.elementName = "ol"
      list.addAttribute(.class("breadcrumb"))

      // 3) user items
      withParent(list, content)
    }
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
    return withParent(li) {
      // <a>
      let a = WebElement()
      populateCreatedObject(a)
      a.elementName = "a"
      a.addAttribute(.dontRegisterObject)
      a.addAttribute(.pair("href", url))
      a.innerHTML(WebEscape.html(title))
    }
  }
}
