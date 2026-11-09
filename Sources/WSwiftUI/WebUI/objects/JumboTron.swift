//
//  JumboTron.swift
//  SWWebAppServer
//
//  Created by Adrian on 11/07/2025.
//

import Foundation

/// The “hero” banner at the top of a page
public class WebJumbotronElement: WebElement {}
public class WebJumbotronImageElement: WebElement {}
public class WebJumbotronTitleElement: WebElement {}
public class WebJumbotronSubtitleElement: WebElement {}

public extension CoreWebEndpoint {
  /// Creates a full-width jumbotron banner.
  ///
  /// - Parameters:
  ///   - fluid: if true, uses `.container-fluid`; otherwise auto-picks mobile `.container-fluid` and desktop `.container`
  ///   - bgImageURL: optional URL for a background image (written as a quoted CSS string, like
  ///     `backgroundImage(_:)`), shown with `background-size: cover`
  ///   - content: closure in which to call `JumbotronTitle`, `JumbotronSubtitle`, or any other elements
  @discardableResult
  func Jumbotron(
    fluid: Bool = false,
    bgImageURL: String? = nil,
    _ content: WebComposerClosure
  ) -> WebJumbotronElement {
    // 1) root <div class="p-5 mb-4 bg-light rounded-3">: Bootstrap 5 dropped the `jumbotron` component
    //    (and its class) for these utilities, so `jumbotron` is no longer added
    let jumbo = WebJumbotronElement()
    populateCreatedObject(jumbo)
    jumbo.elementName = "div"
    jumbo.addAttribute(.class("p-5 mb-4 bg-light rounded-3"))
    jumbo.addAttribute(.class("wsui-jumbotron"))
    if let url = bgImageURL {
      // a quoted, escaped CSS string (backgroundImage): the URL used to be written as url('<url>'), so a
      // quote in it ended the string and the rest became CSS declarations
      jumbo.backgroundImage(url)
      jumbo.style("background-size: cover")
    }

    // open the jumbotron
    return withParent(jumbo) {
      // 2) inner container
      let container = WebElement()
      populateCreatedObject(container)
      container.elementName = "div"
      if fluid {
        container.addAttribute(.class("container-fluid"))
      } else {
        container.deviceClass(mobile: "container-fluid", desktop: "container")
      }

      // 3) user content (titles, buttons, etc.)
      withParent(container, content)
    }
  }

  /// A large heading inside a Jumbotron
  @discardableResult
  func JumbotronTitle(_ text: String) -> WebJumbotronTitleElement {
    let h1 = WebJumbotronTitleElement()
    populateCreatedObject(h1)
    h1.elementName = "h1"
    h1.addAttribute(.class("display-4"))
    h1.innerHTML(WebEscape.html(text))
    return h1
  }

  /// A subtitle / lead text inside a Jumbotron
  @discardableResult
  func JumbotronSubtitle(_ text: String) -> WebJumbotronSubtitleElement {
    let p = WebJumbotronSubtitleElement()
    populateCreatedObject(p)
    p.elementName = "p"
    p.addAttribute(.class("lead"))
    p.innerHTML(WebEscape.html(text))
    return p
  }
}
