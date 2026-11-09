//
//  template.swift
//  SWWebAppServer
//
//  Created by Adrian on 11/07/2025.
//

import Foundation
import WSwiftUI

extension CoreWebEndpoint {
    
    func Template(_ content: WebComposerClosure) -> WebElement {
        
        webpage {
            
            head(.script(src: "https://cdn.jsdelivr.net/npm/bootstrap@5.3.8/dist/js/bootstrap.bundle.min.js"))
            head(.styleLink(href: "https://cdn.jsdelivr.net/npm/bootstrap@5.3.8/dist/css/bootstrap.min.css"))
            head(.styleLink(href: "https://unpkg.com/prismjs@1.29.0/themes/prism.css"))
            head(.script(src: "https://unpkg.com/prismjs@1.29.0/prism.js"))
            head(.script(src: "https://unpkg.com/prismjs@v1.29.0/plugins/autoloader/prism-autoloader.min.js"))
            head(.metaViewport(content: "width=device-width, initial-scale=1"))
            
            // Dynamic navigation bar using menuEntries
            NavBar(brand: "WSwiftUI") {
                for entry in self.menuEntries {
                    if entry.children.isEmpty {
                        NavBarItem(title: entry.title,
                                   href: entry.path ?? "#",
                                   active: entry.selected)
                    } else {
                        // Dropdown for entries with children
                        let dropdownId = "navbarDropdown_\(entry.title.insertDashes())"
                        NavDropdown(title: entry.title,
                                    id: dropdownId,
                                    active: entry.selected) {
                            for child in entry.children {
                                if child.children.isEmpty {
                                    NavDropdownItem(title: child.title,
                                                    href: child.path ?? "#",
                                                    active: child.selected)
                                } else {
                                    NavDropdownHeader(child.title)
                                    for grandChild in child.children {
                                        NavDropdownItem(title: grandChild.title,
                                                        href: grandChild.path ?? "#",
                                                        active: grandChild.selected)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            
            content()
            
            // Footer
            Footer {
                HStack {
                    Text("(C) 2025 WSwiftUI Demo").foreground(.white)
                    Link("/privacy", title: "Privacy Policy").foreground(.white)
                    Link("/terms", title: "Terms of Service").foreground(.white)
                }.height(20).textalign(.center)
            }
            .default()
            .sticky()
            .collapseOnScroll(threshold: 100, collapsedClass: "py-1")
            .background(.darkgrey).opacity(0.7)
            
        }
    }
}
