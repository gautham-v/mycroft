import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

extension FeedParsingSupport {
    /// A minimal element tree keyed by qualified names ("media:group"), the shape rss-parser's xml2js
    /// gives parse.ts. Built with Foundation's XMLParser; a second, lenient pass repairs the usual feed
    /// breakage (HTML entities, bare ampersands, control characters, junk before the prolog).
    final class XMLElementNode {
        enum Content {
            case text(String, cdata: Bool)
            case element(XMLElementNode)
        }

        let name: String
        let attributes: [String: String]
        private(set) var contents: [Content] = []

        init(name: String, attributes: [String: String]) {
            self.name = name
            self.attributes = attributes
        }

        func append(_ c: Content) {
            if case .text(let new, let cdata) = c, case .text(let old, let oldCdata)? = contents.last, cdata == oldCdata {
                contents[contents.count - 1] = .text(old + new, cdata: cdata)
            } else {
                contents.append(c)
            }
        }

        /// Local name, without any namespace prefix.
        var localName: String {
            name.firstIndex(of: ":").map { String(name[name.index(after: $0)...]) } ?? name
        }

        var elements: [XMLElementNode] {
            contents.compactMap { if case .element(let e) = $0 { e } else { nil } }
        }

        func child(_ name: String) -> XMLElementNode? {
            for c in contents { if case .element(let e) = c, e.name == name { return e } }
            return nil
        }

        func children(_ name: String) -> [XMLElementNode] {
            elements.filter { $0.name == name }
        }

        /// Direct text (text and CDATA), untrimmed. Empty for an empty element.
        var text: String {
            var s = ""
            for c in contents { if case .text(let t, _) = c { s += t } }
            return s
        }

        /// Trimmed direct text, nil when empty (xml2js `_`, or the bare string).
        var trimmedText: String? {
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }

        /// rss-parser getContent: the text, or the inner markup when the element holds child elements
        /// (inline XHTML, Atom type="xhtml").
        var content: String {
            elements.isEmpty ? text : innerXML
        }

        var innerXML: String {
            var s = ""
            for c in contents {
                switch c {
                case .text(let t, let cdata): s += cdata ? t : Self.escape(t)
                case .element(let e): s += e.outerXML
                }
            }
            return s
        }

        var outerXML: String {
            let attrs = attributes.keys.sorted().map { " \($0)=\"\(Self.escape(attributes[$0] ?? "", attribute: true))\"" }.joined()
            let inner = innerXML
            return inner.isEmpty ? "<\(name)\(attrs)/>" : "<\(name)\(attrs)>\(inner)</\(name)>"
        }

        static func escape(_ s: String, attribute: Bool = false) -> String {
            var out = s.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
            if attribute { out = out.replacingOccurrences(of: "\"", with: "&quot;") }
            return out
        }
    }

    enum XMLTreeError: Error {
        case malformed(String)
    }

    /// Parses `data` into its root element; retries once on a repaired copy when strict parsing fails.
    static func parseXMLTree(_ data: Data) throws -> XMLElementNode {
        do {
            return try XMLTreeBuilder.build(trimmedProlog(data))
        } catch {
            guard let repaired = repairedXML(data) else { throw error }
            return try XMLTreeBuilder.build(repaired)
        }
    }

    /// Drops a UTF-8 BOM and whitespace before the first "<" (libxml2 rejects them before `<?xml`).
    private static func trimmedProlog(_ data: Data) -> Data {
        var start = data.startIndex
        if data.count >= 3, data[start] == 0xEF, data[start + 1] == 0xBB, data[start + 2] == 0xBF { start += 3 }
        while start < data.endIndex, [0x20, 0x09, 0x0A, 0x0D].contains(data[start]) { start += 1 }
        return start == data.startIndex ? data : data.subdata(in: start..<data.endIndex)
    }

    /// A UTF-8 copy with HTML named entities made numeric, bare "&" escaped, XML-illegal control
    /// characters removed, and the encoding declaration rewritten to UTF-8.
    static func repairedXML(_ data: Data) -> Data? {
        guard var s = decodeXMLText(data) else { return nil }
        if let first = s.firstIndex(of: "<") { s = String(s[first...]) }
        s = s.replacingOccurrences(of: #"[\u0000-\u0008\u000B\u000C\u000E-\u001F]"#, with: "", options: .regularExpression)
        if let re = try? NSRegularExpression(pattern: #"&(#[0-9]+;|#[xX][0-9a-fA-F]+;|([A-Za-z][A-Za-z0-9]*);)?"#) {
            let ns = s as NSString
            var out = ""
            var last = 0
            for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
                out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
                let whole = ns.substring(with: m.range)
                if m.range(at: 1).location == NSNotFound {
                    out += "&amp;"                                    // bare ampersand
                } else if m.range(at: 2).location != NSNotFound {
                    let name = ns.substring(with: m.range(at: 2))
                    if ["amp", "lt", "gt", "quot", "apos"].contains(name) {
                        out += whole
                    } else if let cp = namedEntities[name] {
                        out += "&#\(cp);"
                    } else {
                        out += "&amp;" + whole.dropFirst()             // unknown entity: keep it as literal text
                    }
                } else {
                    out += whole
                }
                last = m.range.location + m.range.length
            }
            out += ns.substring(from: last)
            s = out
        }
        s = s.replacingOccurrences(of: #"^(<\?xml[^>]*?encoding\s*=\s*["'])[^"']*(["'])"#, with: "$1UTF-8$2", options: .regularExpression)
        return s.data(using: .utf8)
    }

    /// Decodes using the XML declaration's encoding, then UTF-8, then Latin-1.
    private static func decodeXMLText(_ data: Data) -> String? {
        let head = String(decoding: data.prefix(200), as: UTF8.self)
        if let name = firstGroup(#"<\?xml[^>]*encoding\s*=\s*["']([^"']+)["']"#, in: head, options: .caseInsensitive) {
            let cf = CFStringConvertIANACharSetNameToEncoding(name as CFString)
            if cf != kCFStringEncodingInvalidId,
               let s = String(data: data, encoding: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))) {
                return s
            }
        }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    }

    private final class XMLTreeBuilder: NSObject, XMLParserDelegate {
        private var stack: [XMLElementNode] = []
        private var root: XMLElementNode?
        private var failure: String?

        static func build(_ data: Data) throws -> XMLElementNode {
            let builder = XMLTreeBuilder()
            let parser = XMLParser(data: data)
            parser.shouldProcessNamespaces = false
            parser.shouldReportNamespacePrefixes = false
            parser.shouldResolveExternalEntities = false
            parser.delegate = builder
            let ok = parser.parse()
            if let root = builder.root, ok || builder.stack.isEmpty { return root }
            throw XMLTreeError.malformed(builder.failure ?? parser.parserError?.localizedDescription ?? "not valid XML")
        }

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            let node = XMLElementNode(name: elementName, attributes: attributeDict)
            if let parent = stack.last {
                parent.append(.element(node))
            } else if root == nil {
                root = node
            } else {
                return
            }
            stack.append(node)
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            if !stack.isEmpty { stack.removeLast() }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            stack.last?.append(.text(string, cdata: false))
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            let s = String(data: CDATABlock, encoding: .utf8) ?? String(decoding: CDATABlock, as: UTF8.self)
            stack.last?.append(.text(s, cdata: true))
        }

        func parser(_ parser: XMLParser, parseErrorOccurred parseError: any Error) {
            if failure == nil { failure = parseError.localizedDescription }
        }
    }
}
