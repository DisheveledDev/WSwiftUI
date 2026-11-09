// Navigation.swift

// MARK: – Navbar element types
public class WebNavBarElement: WebElement {}
public class WebNavBarBrandElement: WebElement {}
public class WebNavBarTogglerElement: WebElement {}
public class WebNavBarCollapseElement: WebElement {}
public class WebNavBarItemElement: WebElement {}
public class WebNavBarDropdownElement: WebElement {}
public class WebNavBarDropdownMenuElement: WebElement {}
public class WebNavBarDropdownMenuItemElement: WebElement {}

// MARK: – Enums
public enum NavBarExpand: String { case sm, md, lg, xl, xxl }
public enum NavBarColorScheme: String { case light, dark }
public enum NavBarBackground: String {
  case light, dark, primary, secondary, success, danger, warning, info, white, transparent
}

// MARK: – DSL
public extension CoreWebEndpoint {
  /// Builds a Bootstrap navbar.
  ///
  /// - Parameters:
  ///   - brand: **Trusted HTML**, emitted raw inside the brand link so it can contain markup such as a logo
  ///     (`<img src="logo.png" height="40">`). Never pass user-supplied or database text here unescaped; wrap
  ///     plain text in `WebEscape.html(_:)` first.
  ///   - href: Destination of the brand link (escaped).
  ///   - content: Closure adding `NavBarItem` / `NavDropdown` entries, whose titles are plain text (escaped).
  @discardableResult
  func NavBar(
    brand: String,
    href: String = "/",
    expand: NavBarExpand = .lg,
    color: NavBarColorScheme = .light,
    bg: NavBarBackground = .light,
    useFluidContainer: Bool = false,
    _ content: WebComposerClosure
  ) -> WebNavBarElement {
    // 1) Create <nav>
    let nav = WebNavBarElement()
    populateCreatedObject(nav)
    nav.elementName = "nav"
    nav.addAttribute(.class(
      "navbar navbar-expand-\(expand.rawValue) navbar-\(color.rawValue) bg-\(bg.rawValue)"
    ))
    nav.addAttribute(.class("wsui-navbar"))

    // Push nav so all children get appended to it
    stack.append(nav)

    // 2) <div class="container[-fluid]">
    let container = WebElement()
    populateCreatedObject(container)
    container.elementName = "div"
    if useFluidContainer {
      container.addAttribute(.class("container-fluid"))
    } else {
      container.deviceClass(mobile: "container-fluid", desktop: "container")
    }
    // push container
    stack.append(container)

    // 3) Brand link
    let brandEl = WebNavBarBrandElement()
    populateCreatedObject(brandEl)
    brandEl.elementName = "a"
    brandEl.addAttribute(.class("navbar-brand"))
    brandEl.addAttribute(.pair("href", href))
    brandEl.innerHTML(brand)   // trusted HTML by design (see doc comment)
    // (no push—brand is leaf)

    // 4) Toggler
    let collapseId = "navbarCollapse_\(nav.builderId)"
    let toggler = WebNavBarTogglerElement()
    populateCreatedObject(toggler)
    toggler.elementName = "button"
    toggler.addAttribute(.class("navbar-toggler"))
    toggler.addAttribute(.pair("type", "button"))
    toggler.addAttribute(.pair("data-bs-toggle", "collapse"))
    toggler.addAttribute(.pair("data-bs-target", "#\(collapseId)"))
    toggler.addAttribute(.pair("aria-controls", collapseId))
    toggler.addAttribute(.pair("aria-expanded", "false"))
    toggler.addAttribute(.pair("aria-label", "Toggle navigation"))
    toggler.innerHTML("<span class=\"navbar-toggler-icon\"></span>")

    // 5) Collapse wrapper
    let collapse = WebNavBarCollapseElement()
    populateCreatedObject(collapse)
    collapse.elementName = "div"
    collapse.addAttribute(.class("collapse navbar-collapse"))
    collapse.addAttribute(.pair("id", collapseId))
    // push collapse
    stack.append(collapse)

    // 6) Nav‐list <ul>
    let navList = WebElement()
    populateCreatedObject(navList)
    navList.elementName = "ul"
    navList.addAttribute(.class("navbar-nav ms-auto mb-2 mb-lg-0"))
    // push navList—your items go here
    stack.append(navList)

    // 7) Invoke user content closure
    content()

    // 8) Pop navList, collapse, container, nav
    stack.removeLast()  // navList
    stack.removeLast()  // collapse
    stack.removeLast()  // container
    stack.removeLast()  // nav

    return nav
  }

  @discardableResult
  func NavBarItem(
    title: String,
    href: String,
    active: Bool = false,
    disabled: Bool = false
  ) -> WebNavBarItemElement {
    let li = WebNavBarItemElement()
    populateCreatedObject(li)
    li.elementName = "li"
    li.addAttribute(.class("nav-item"))

    stack.append(li)

    let a = WebElement()
    populateCreatedObject(a)
    a.elementName = "a"
    var cls = "nav-link"
    if active { cls += " active"; a.addAttribute(.pair("aria-current", "page")) }
    if disabled { cls += " disabled"; a.addAttribute(.pair("aria-disabled", "true")) }
    a.addAttribute(.class(cls))
    a.addAttribute(.pair("href", href))
    a.innerHTML(WebEscape.html(title))

    stack.removeAll(where: { $0.builderId == li.builderId })

    return li
  }

  @discardableResult
  func NavDropdown(
    title: String,
    id: String,
    disabled: Bool = false,
    _ content: WebComposerClosure
  ) -> WebNavBarDropdownElement {
    let li = WebNavBarDropdownElement()
    populateCreatedObject(li)
    li.elementName = "li"
    li.addAttribute(.class("nav-item dropdown"))

    stack.append(li)

    let toggle = WebElement()
    populateCreatedObject(toggle)
    toggle.elementName = "a"
    var cls = "nav-link dropdown-toggle"
    if disabled { cls += " disabled" }
    toggle.addAttribute(.class(cls))
    toggle.addAttribute(.pair("href", "#"))
    toggle.addAttribute(.pair("id", id))
    toggle.addAttribute(.pair("role", "button"))
    toggle.addAttribute(.pair("data-bs-toggle", "dropdown"))
    toggle.addAttribute(.pair("aria-expanded", "false"))
    toggle.innerHTML(WebEscape.html(title))

    let menu = WebNavBarDropdownMenuElement()
    populateCreatedObject(menu)
    menu.elementName = "ul"
    menu.addAttribute(.class("dropdown-menu"))
    menu.addAttribute(.pair("aria-labelledby", id))

    // push menu <ul> for its items
    stack.append(menu)
    content()
    stack.removeAll(where: { $0.builderId == menu.builderId })
    stack.removeAll(where: { $0.builderId == li.builderId })

    return li
  }

  @discardableResult
  func NavDropdownItem(
    title: String,
    href: String,
    disabled: Bool = false
  ) -> WebNavBarDropdownMenuItemElement {
    let li = WebNavBarDropdownMenuItemElement()
    populateCreatedObject(li)
    li.elementName = "li"

    stack.append(li)

    let a = WebElement()
    populateCreatedObject(a)
    a.elementName = "a"
    var cls = "dropdown-item"
    if disabled { cls += " disabled"; a.addAttribute(.pair("aria-disabled", "true")) }
    a.addAttribute(.class(cls))
    a.addAttribute(.pair("href", href))
    a.innerHTML(WebEscape.html(title))

    stack.removeAll(where: { $0.builderId == li.builderId })

    return li
  }
}

// MARK: – Dropdown header element
public class WebNavBarDropdownHeaderElement: WebElement {}

// MARK: – DSL
public extension CoreWebEndpoint {
  /// Renders a non-clickable header inside a dropdown
  @discardableResult
  func NavDropdownHeader(_ title: String) -> WebNavBarDropdownHeaderElement {
    let li = WebNavBarDropdownHeaderElement()
    populateCreatedObject(li)
    li.elementName = "li"
    li.addAttribute(.class("dropdown-header"))
    li.innerHTML(WebEscape.html(title))
    return li
  }
}
