import Foundation

internal extension CoreWebEndpoint {
    func applyPageSEO(_ config: PageSEO?, baseURL: String, path: String) {
        guard let config else {
            return
        }
        
        if let title = config.title, hasHeadTitle() == false {
            head(.title(title))
        }
        
        if let description = config.description {
            addMetaNameIfMissing("description", content: description)
        }
        
        if let robots = config.robots {
            addMetaNameIfMissing("robots", content: robots)
        }
        
        if config.keywords.isEmpty == false {
            addMetaNameIfMissing("keywords", content: config.keywords.joined(separator: ", "))
        }
        
        let canonicalURL = resolveCanonicalURL(config, baseURL: baseURL, path: path)
        if let canonicalURL, hasCanonicalLink() == false {
            head(.link(rel: .other("canonical"), href: canonicalURL))
        }
        
        if let openGraph = config.openGraph {
            if let type = openGraph.type {
                addMetaPropertyIfMissing("og:type", content: type)
            }
            
            if let title = openGraph.title ?? config.title {
                addMetaPropertyIfMissing("og:title", content: title)
            }
            
            if let description = openGraph.description ?? config.description {
                addMetaPropertyIfMissing("og:description", content: description)
            }
            
            let graphURL = openGraph.url ?? canonicalURL ?? absoluteURL(path: path, baseURL: baseURL)
            addMetaPropertyIfMissing("og:url", content: graphURL)
            
            if let imageURL = openGraph.imageURL {
                addMetaPropertyIfMissing("og:image", content: makeAbsoluteURL(imageURL, baseURL: baseURL))
            }
            
            if let siteName = openGraph.siteName {
                addMetaPropertyIfMissing("og:site_name", content: siteName)
            }
            
            if let locale = openGraph.locale {
                addMetaPropertyIfMissing("og:locale", content: locale)
            }
        }
        
        if let twitter = config.twitter {
            addMetaNameIfMissing("twitter:card", content: twitter.card)
            
            if let title = twitter.title ?? config.title {
                addMetaNameIfMissing("twitter:title", content: title)
            }
            
            if let description = twitter.description ?? config.description {
                addMetaNameIfMissing("twitter:description", content: description)
            }
            
            if let imageURL = twitter.imageURL ?? config.openGraph?.imageURL {
                addMetaNameIfMissing("twitter:image", content: makeAbsoluteURL(imageURL, baseURL: baseURL))
            }
            
            if let site = twitter.site {
                addMetaNameIfMissing("twitter:site", content: site)
            }
        }
        
        for document in config.jsonLD where document.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            head(.custom(tag: "script", attributes: ["type":"application/ld+json"], innerHTML: WebJSON.makeScriptSafe(document)))
        }
    }
    
    private func hasHeadTitle() -> Bool {
        for headElement in headAttributes {
            if case .title = headElement {
                return true
            }
        }
        return false
    }
    
    private func hasCanonicalLink() -> Bool {
        for headElement in headAttributes {
            if case .link(let rel, _, _, _, _, _) = headElement {
                if case .other(let value) = rel,
                   value.caseInsensitiveCompare("canonical") == .orderedSame {
                    return true
                }
            }
        }
        return false
    }
    
    private func hasMetaName(_ name: String) -> Bool {
        for headElement in headAttributes {
            switch headElement {
                case .metaName(let existingName, _):
                    if existingName.caseInsensitiveCompare(name) == .orderedSame {
                        return true
                    }
                case .metaDescription:
                    if name.caseInsensitiveCompare("description") == .orderedSame {
                        return true
                    }
                default:
                    break
            }
        }
        return false
    }
    
    private func hasMetaProperty(_ property: String) -> Bool {
        for headElement in headAttributes {
            if case .metaProperty(let existingProperty, _) = headElement,
               existingProperty.caseInsensitiveCompare(property) == .orderedSame {
                return true
            }
        }
        return false
    }
    
    private func addMetaNameIfMissing(_ name: String, content: String) {
        let value = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.isEmpty == false else {
            return
        }
        
        guard hasMetaName(name) == false else {
            return
        }
        
        if name.caseInsensitiveCompare("description") == .orderedSame {
            head(.metaDescription(value))
            return
        }
        
        head(.metaName(name: name, content: value))
    }
    
    private func addMetaPropertyIfMissing(_ property: String, content: String) {
        let value = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.isEmpty == false else {
            return
        }
        
        guard hasMetaProperty(property) == false else {
            return
        }
        
        head(.metaProperty(property: property, content: value))
    }
    
    private func resolveCanonicalURL(_ config: PageSEO, baseURL: String, path: String) -> String? {
        if let canonicalURL = config.canonicalURL?.trimmingCharacters(in: .whitespacesAndNewlines),
           canonicalURL.isEmpty == false {
            return makeAbsoluteURL(canonicalURL, baseURL: baseURL)
        }
        
        if let canonicalPath = config.canonicalPath?.trimmingCharacters(in: .whitespacesAndNewlines),
           canonicalPath.isEmpty == false {
            return makeAbsoluteURL(canonicalPath, baseURL: baseURL)
        }
        
        return nil
    }
    
    private func absoluteURL(path: String, baseURL: String) -> String {
        if path.hasPrefix("/") {
            return "\(baseURL)\(path)"
        }
        return "\(baseURL)/\(path)"
    }
    
    private func makeAbsoluteURL(_ value: String, baseURL: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            return trimmed
        }
        
        if trimmed.hasPrefix("/") {
            return "\(baseURL)\(trimmed)"
        }
        
        return "\(baseURL)/\(trimmed)"
    }
}
