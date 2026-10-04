import SwiftUI

/// 轻量 Markdown 渲染，够用于 README：标题 / 段落 / 列表 / 代码块 / 引用 / 表格 / 分割线 / 图片。
/// 不引入第三方依赖，纯 SwiftUI + AttributedString 做内联样式。
///
/// 两个容易踩的坑，这里都专门处理了：
///  - **badge / 行内图片**：形如 `[![alt](img)](link)`，或段落里夹着 `![](img)`，
///    必须渲染成图片，而不是把 `![alt](img)` 当成普通链接文字吐出来；
///  - **表格列对齐**：每行各画各的宽度，各列当然对不齐。这里先量出整列的内容宽度，
///    再让同一列所有单元格用同一个宽度，上下才会对齐。

/// 一段行内内容：要么是文字（交给 `MarkdownInline` 上样式），要么是一张图片。
///
/// badge（shields.io 那种）在 README 里随处可见，必须能被真的画出来 ——
/// 而 `AttributedString` 里塞不了异步加载的图片，所以图片要单独拎出来当一段。
enum MDInline: Hashable, Sendable {
    case text(String)
    case picture(url: String, alt: String, link: String?)
}

enum MDBlock: Hashable, Sendable {
    case heading(level: Int, text: String)
    case paragraph([MDInline])
    case bullet(segments: [MDInline], indent: Int)
    case ordered(number: String, segments: [MDInline], indent: Int)
    case quote([MDInline])
    case code(language: String?, content: String)
    case table(header: [[MDInline]], rows: [[[MDInline]]])
    case rule
    case image(url: String, alt: String)
}

enum MarkdownParser {

    /// README 里大量存在的**内嵌 HTML**（GitHub 允许 Markdown 里直接写 HTML）：
    /// `<div align="center">`、`<h1>`、`<img>` badge、`<a>`、`<sub>`……
    /// 我们的解析器只认 Markdown，HTML 标签会被当成纯文本吐出来，
    /// 界面上就是一屏源码。
    ///
    /// 这里在解析前做一遍归一化：常见标签转成等效 Markdown（走既有渲染管线），
    /// 不认识的标签剥壳保内容，HTML 实体解码（badge URL 里的 `&amp;` 全靠它）。
    /// ``` 围栏代码块里的内容原样保留 —— 那是用户想展示的代码。
    static func normalizeHtml(_ source: String) -> String {
        // 按 ``` 围栏切开，围栏内的段落原样保留
        let fence = try? NSRegularExpression(pattern: "(```[\\s\\S]*?```|```[\\s\\S]*)")
        guard let fence else { return transformHtml(source) }
        let ns = source as NSString
        var out = ""
        var last = 0
        fence.enumerateMatches(in: source, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
            guard let m else { return }
            if m.range.location > last {
                out += transformHtml(ns.substring(with: NSRange(location: last, length: m.range.location - last)))
            }
            out += ns.substring(with: m.range)   // 围栏内原样保留
            last = m.range.location + m.range.length
        }
        if last < ns.length { out += transformHtml(ns.substring(from: last)) }
        return out
    }

    private static func transformHtml(_ text: String) -> String {
        var s = text

        // HTML 注释
        s = regexReplace(s, "<!--[\\s\\S]*?-->") { _ in "" }

        // <img src="X" alt="Y" ...> → ![Y](X)（属性任意顺序；width/height 忽略）
        s = regexReplace(s, "<img\\s[^>]*>") { groups in
            guard let src = htmlAttr(groups[0], "src") else { return "" }
            let alt = htmlAttr(groups[0], "alt") ?? ""
            return "![\(alt)](\(src))"
        }

        // <a href="X">内容</a> → [内容](X)（内容可能已含上面转换出的图片 → badge）
        s = regexReplace(s, "<a\\s[^>]*href\\s*=\\s*[\"']([^\"']*)[\"'][^>]*>([\\s\\S]*?)</a>") { g in
            "[\(g[2].trimmingCharacters(in: .whitespacesAndNewlines))](\(g[1]))"
        }

        // <h1>~<h6> → 标题；内容里有图片就降级成段落（标题渲染不了图）
        s = regexReplace(s, "<h([1-6])(\\s[^>]*)?>([\\s\\S]*?)</h\\1>") { g in
            let level = Int(g[1]) ?? 1
            let inner = g[3].trimmingCharacters(in: .whitespacesAndNewlines)
            if inner.isEmpty { return "" }
            if inner.contains("](") { return "\n\(inner)\n" }
            return "\n\(String(repeating: "#", count: level)) \(inner)\n"
        }

        // <b>/<strong>/<i>/<em> → Markdown 强调
        s = replacing(s, "</?(?:b|strong)>", "**")
        s = replacing(s, "</?(?:i|em)>", "*")

        // <br> / <hr>
        s = replacing(s, "<br\\s*/?>", "\n")
        s = replacing(s, "<hr\\s*/?>", "\n---\n")

        // <li> → 列表行（必须在通用剥壳之前）
        s = replacing(s, "<li(\\s[^>]*)?>", "\n- ")

        // 已知的纯排版标签：剥壳保内容（div/p/span/sub/sup/center/details…）
        s = replacing(s, "</?(?:div|p|span|sub|sup|center|details|summary|kbd|samp|small|big|font|picture|source|figure|figcaption|ins|del|u|s|strike)(\\s[^>]*)?/?>", "")

        // 兜底：其余任何未知标签也剥掉 —— 绝不让源码出现在界面上。
        // 注意这在解码 HTML 实体**之前**：正文里的 `&lt;div&gt;` 此时还不是真标签，不受影响。
        s = replacing(s, "</?[a-zA-Z][a-zA-Z0-9-]*(\\s[^<>]*)?/?>", "")

        // HTML 实体解码（&amp; 常见于 shields badge URL 的参数里，不解会 404）
        s = s.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ")

        return s
    }

    /// 从 HTML 标签里取属性值（任意属性顺序，单双引号都认；要求属性名前有空白，避免误命中 data-src 之类）
    private static func htmlAttr(_ tag: String, _ name: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: "(?:^|\\s)\(name)\\s*=\\s*[\"']([^\"']*)[\"']",
                                                options: [.caseInsensitive]) else { return nil }
        let ns = tag as NSString
        guard let m = re.firstMatch(in: tag, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges > 1, m.range(at: 1).location != NSNotFound else { return nil }
        return ns.substring(with: m.range(at: 1))
    }

    /// 正则模板替换（$1/$2 引用分组）
    private static func replacing(_ input: String, _ pattern: String, _ template: String,
                                  caseInsensitive: Bool = true) -> String {
        var options: NSRegularExpression.Options = []
        if caseInsensitive { options.insert(.caseInsensitive) }
        guard let re = try? NSRegularExpression(pattern: pattern, options: options) else { return input }
        let ns = input as NSString
        return re.stringByReplacingMatches(in: input, range: NSRange(location: 0, length: ns.length),
                                           withTemplate: template)
    }

    /// 带闭包的正则替换：handler 收到「整段匹配 + 各分组」
    private static func regexReplace(_ input: String, _ pattern: String,
                                     caseInsensitive: Bool = true,
                                     _ handler: @escaping ([String]) -> String) -> String {
        var options: NSRegularExpression.Options = []
        if caseInsensitive { options.insert(.caseInsensitive) }
        guard let re = try? NSRegularExpression(pattern: pattern, options: options) else { return input }
        let ns = input as NSString
        var out = ""
        var last = 0
        re.enumerateMatches(in: input, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
            guard let m else { return }
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            var groups: [String] = []
            for i in 0..<m.numberOfRanges {
                let r = m.range(at: i)
                groups.append(r.location != NSNotFound && r.location <= ns.length ? ns.substring(with: r) : "")
            }
            out += handler(groups)
            last = m.range.location + m.range.length
        }
        if last < ns.length { out += ns.substring(from: last) }
        return out
    }

    static func parse(_ source: String) -> [MDBlock] {
        var blocks: [MDBlock] = []
        let normalized = normalizeHtml(source)
        let lines = normalized.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var index = 0

        while index < lines.count {
            let raw = lines[index]
            let line = raw.trimmingCharacters(in: .whitespaces)

            if line.isEmpty { index += 1; continue }

            // ``` 代码块
            if line.hasPrefix("```") {
                let language = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var buffer: [String] = []
                index += 1
                while index < lines.count,
                      !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    buffer.append(lines[index])
                    index += 1
                }
                index += 1
                blocks.append(.code(language: language.isEmpty ? nil : language,
                                    content: buffer.joined(separator: "\n")))
                continue
            }

            // 分割线（至少 3 个 -, *, _）
            if isRule(line) {
                blocks.append(.rule)
                index += 1
                continue
            }

            // 标题
            if line.hasPrefix("#") {
                let hashes = line.prefix { $0 == "#" }.count
                if (1...6).contains(hashes) {
                    let text = String(line.dropFirst(hashes)).trimmingCharacters(in: .whitespaces)
                    if !text.isEmpty {
                        blocks.append(.heading(level: min(hashes, 4), text: text))
                        index += 1
                        continue
                    }
                }
            }

            // 表格
            if line.contains("|"), index + 1 < lines.count, isTableSeparator(lines[index + 1]) {
                let header = splitTableRow(line).map { InlineScanner($0).scan() }
                var rows: [[[MDInline]]] = []
                index += 2
                while index < lines.count, lines[index].contains("|") {
                    rows.append(splitTableRow(lines[index]).map { InlineScanner($0).scan() })
                    index += 1
                }
                blocks.append(.table(header: header, rows: rows))
                continue
            }

            // 引用
            if line.hasPrefix(">") {
                var buffer: [String] = []
                while index < lines.count {
                    let current = lines[index].trimmingCharacters(in: .whitespaces)
                    guard current.hasPrefix(">") else { break }
                    buffer.append(String(current.dropFirst()).trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                blocks.append(.quote(InlineScanner(buffer.joined(separator: " ")).scan()))
                continue
            }

            // 列表
            if let marker = parseListMarker(raw) {
                let segments = InlineScanner(marker.text).scan()
                switch marker.kind {
                case .bullet:
                    blocks.append(.bullet(segments: segments, indent: marker.indent))
                case .ordered(let number):
                    blocks.append(.ordered(number: number, segments: segments, indent: marker.indent))
                }
                index += 1
                continue
            }

            // 段落：连续的非空、非结构性行合并成一段
            var buffer: [String] = [line]
            index += 1
            while index < lines.count {
                let current = lines[index]
                let trimmed = current.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty
                    || isRule(trimmed)
                    || trimmed.hasPrefix("#")
                    || trimmed.hasPrefix("```")
                    || trimmed.hasPrefix(">")
                    || (trimmed.contains("|") && index + 1 < lines.count && isTableSeparator(lines[index + 1]))
                    || parseListMarker(current) != nil {
                    break
                }
                buffer.append(trimmed)
                index += 1
            }
            // 逐行扫描：图片之间的换行不能被吞成空格，否则 badge 会连成一条缝
            blocks.append(.paragraph(buffer.flatMap { InlineScanner($0).scan() }))
        }

        return blocks
    }

    // MARK: - 辅助

    private static func isRule(_ line: String) -> Bool {
        guard line.count >= 3, let first = line.first else { return false }
        guard first == "-" || first == "*" || first == "_" else { return false }
        let meaningful = line.filter { $0 != " " }
        return meaningful.count >= 3 && meaningful.allSatisfy { $0 == first }
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("-"), trimmed.contains("|") else { return false }
        let allowed = CharacterSet(charactersIn: "-|: ")
        return trimmed.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    private static func splitTableRow(_ line: String) -> [String] {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("|") { trimmed.removeFirst() }
        if trimmed.hasSuffix("|") { trimmed.removeLast() }
        return splitOutsideCode(trimmed, separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// 按分隔符切分，但跳过 `` ` `` 代码段里的分隔符（列名里常有 `a|b`）
    private static func splitOutsideCode(_ source: String, separator: Character) -> [String] {
        var result: [String] = []
        var current = ""
        var inCode = false
        for ch in source {
            if ch == "`" {
                inCode.toggle()
                current.append(ch)
            } else if ch == separator && !inCode {
                result.append(current)
                current = ""
            } else {
                current.append(ch)
            }
        }
        result.append(current)
        return result
    }

    private struct ListMarker {
        enum Kind { case bullet, ordered(String) }
        let kind: Kind
        let text: String
        let indent: Int
    }

    private static func parseListMarker(_ raw: String) -> ListMarker? {
        let leading = raw.prefix { $0 == " " || $0 == "\t" }
        let indent = leading.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) } / 2
        let line = raw.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return nil }

        for prefix in ["- ", "* ", "+ "] where line.hasPrefix(prefix) {
            let text = String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            return ListMarker(kind: .bullet, text: text, indent: indent)
        }

        let digits = line.prefix { $0.isNumber }
        if !digits.isEmpty {
            let rest = line.dropFirst(digits.count)
            if rest.hasPrefix(". ") || rest.hasPrefix(") ") {
                let text = String(rest.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                return ListMarker(kind: .ordered(String(digits)), text: text, indent: indent)
            }
        }
        return nil
    }
}

// MARK: - 行内扫描

/// 行内扫描器：把文字切成「文本 / 图片」两态。
///
/// 支持的图片写法：
///  - `![alt](url)`               → 直接图片
///  - `[![alt](img)](link)`       → 可点击的 badge（README 里最常见的形态）
///  - `<img src="..." alt="...">` → 部分 README 会直接写 HTML
///
/// 普通链接 `[文字](url)` 仍走文字路径，不会被误判成图片。
struct InlineScanner {
    private let source: String

    init(_ source: String) {
        self.source = source
    }

    func scan() -> [MDInline] {
        var out: [MDInline] = []
        var text = ""
        let chars = Array(source)
        var i = 0

        func flush() {
            if !text.isEmpty {
                out.append(.text(text))
                text = ""
            }
        }

        while i < chars.count {
            // HTML <img ...>
            if chars[i] == "<", let close = indexOf(chars, ">", from: i), close > i {
                let tag = String(chars[i...close])
                if let picture = Self.parseHTMLImage(tag) {
                    flush()
                    out.append(picture)
                    i = close + 1
                    continue
                }
            }

            // [![alt](img)](link) —— badge
            if hasPrefix(chars, i, "[!["), let parsed = Self.parseBadge(chars, start: i) {
                flush()
                out.append(parsed.inline)
                i = parsed.next
                continue
            }

            // ![alt](img)
            if chars[i] == "!", i + 1 < chars.count, chars[i + 1] == "[",
               let parsed = Self.parseImage(chars, start: i) {
                flush()
                out.append(parsed.inline)
                i = parsed.next
                continue
            }

            text.append(chars[i])
            i += 1
        }
        flush()
        return out
    }

    private func hasPrefix(_ chars: [Character], _ start: Int, _ prefix: String) -> Bool {
        let p = Array(prefix)
        guard start + p.count <= chars.count else { return false }
        return Array(chars[start..<(start + p.count)]) == p
    }

    private func indexOf(_ chars: [Character], _ target: Character, from: Int) -> Int? {
        var i = from
        while i < chars.count {
            if chars[i] == target { return i }
            i += 1
        }
        return nil
    }

    // MARK: - 解析

    private struct Parsed {
        let inline: MDInline
        let next: Int
    }

    /// `[![alt](img)](link)` → 可点击图片
    private static func parseBadge(_ chars: [Character], start: Int) -> Parsed? {
        guard start + 3 <= chars.count else { return nil }
        // 跳到 alt 的结尾 ]
        guard let altEnd = find(chars, "]", from: start + 3) else { return nil }
        let alt = String(chars[(start + 3)..<altEnd])
        guard altEnd + 1 < chars.count, chars[altEnd + 1] == "(" else { return nil }
        guard let imgUrlEnd = find(chars, ")", from: altEnd + 2) else { return nil }
        let imgURL = String(chars[(altEnd + 2)..<imgUrlEnd]).trimmingCharacters(in: .whitespaces)
        guard imgUrlEnd + 1 < chars.count, chars[imgUrlEnd + 1] == "]" else { return nil }

        // 后面可能还跟着 ](链接)
        if imgUrlEnd + 2 < chars.count, chars[imgUrlEnd + 2] == "(",
           let linkEnd = find(chars, ")", from: imgUrlEnd + 3) {
            let link = String(chars[(imgUrlEnd + 3)..<linkEnd]).trimmingCharacters(in: .whitespaces)
            let picture = MDInline.picture(url: imgURL,
                                           alt: alt,
                                           link: link.isEmpty ? nil : link)
            return Parsed(inline: picture, next: linkEnd + 1)
        }
        return Parsed(inline: .picture(url: imgURL, alt: alt, link: nil), next: imgUrlEnd + 2)
    }

    /// `![alt](url)` → 图片
    private static func parseImage(_ chars: [Character], start: Int) -> Parsed? {
        let altStart = start + 2
        guard let altEnd = find(chars, "]", from: altStart) else { return nil }
        guard altEnd + 1 < chars.count, chars[altEnd + 1] == "(" else { return nil }
        let urlStart = altEnd + 2
        guard let urlEnd = findClosingParen(chars, from: urlStart) else { return nil }
        let alt = String(chars[altStart..<altEnd])
        let rawURL = String(chars[urlStart..<urlEnd])
        guard let url = parseURLAndTitle(rawURL) else { return nil }
        return Parsed(inline: .picture(url: url, alt: alt, link: nil), next: urlEnd + 1)
    }

    /// URL 可能带可选标题（`url "title"`），也可能虽然带空格但仍是合法地址
    private static func parseURLAndTitle(_ body: String) -> String? {
        var value = body.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return nil }
        if let quote = value.firstIndex(of: "\""), quote != value.startIndex {
            value = String(value[value.startIndex..<quote]).trimmingCharacters(in: .whitespaces)
        }
        if value.hasPrefix("<"), value.hasSuffix(">") {
            value = String(value.dropFirst().dropLast())
        }
        return value.isEmpty ? nil : value
    }

    /// URL 里可能含括号（少数 shields 地址），按配对计数找真正的右括号
    private static func findClosingParen(_ chars: [Character], from: Int) -> Int? {
        var depth = 1
        var i = from
        while i < chars.count {
            if chars[i] == "(" { depth += 1 }
            if chars[i] == ")" {
                depth -= 1
                if depth == 0 { return i }
            }
            i += 1
        }
        return nil
    }

    private static func find(_ chars: [Character], _ target: Character, from: Int) -> Int? {
        var i = from
        while i < chars.count {
            if chars[i] == target { return i }
            i += 1
        }
        return nil
    }

    /// `<img src="..." alt="...">`
    private static func parseHTMLImage(_ tag: String) -> MDInline? {
        guard tag.lowercased().hasPrefix("<img") else { return nil }
        guard let src = attribute(tag, "src") else { return nil }
        let alt = attribute(tag, "alt") ?? ""
        return .picture(url: src, alt: alt, link: nil)
    }

    private static func attribute(_ tag: String, _ name: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "\(name)\\s*=\\s*([\"'])(.*?)\\1",
                                                  options: [.caseInsensitive]) else { return nil }
        let range = NSRange(tag.startIndex..<tag.endIndex, in: tag)
        guard let match = regex.firstMatch(in: tag, options: [], range: range),
              match.numberOfRanges >= 3,
              let valueRange = Range(match.range(at: 2), in: tag) else { return nil }
        return String(tag[valueRange])
    }
}

// MARK: - 内联样式

enum MarkdownInline {
    /// 把 `**粗**`、`` `代码` ``、`[文字](链接)` 解析为 AttributedString
    static func render(_ text: String, baseFont: Font, baseColor: Color) -> AttributedString {
        var attributed = AttributedString()
        var index = text.startIndex

        while index < text.endIndex {
            let remainder = text[index...]

            // ***粗斜***
            if remainder.hasPrefix("***") {
                if let end = remainder.dropFirst(3).range(of: "***")?.lowerBound {
                    let inner = remainder.dropFirst(3)[remainder.dropFirst(3).startIndex..<end]
                    var piece = AttributedString(String(inner))
                    piece.font = baseFont.bold().italic()
                    piece.foregroundColor = baseColor
                    attributed.append(piece)
                    index = text.index(end, offsetBy: 3, limitedBy: text.endIndex) ?? text.endIndex
                    continue
                }
            }

            if remainder.hasPrefix("**") {
                if let end = remainder.dropFirst(2).range(of: "**")?.lowerBound {
                    let inner = remainder.dropFirst(2)[remainder.dropFirst(2).startIndex..<end]
                    var piece = AttributedString(String(inner))
                    piece.font = baseFont.bold()
                    piece.foregroundColor = baseColor
                    attributed.append(piece)
                    // 关掉的是 2 个字符，必须整体跳过，否则会漏出半个 `**`
                    index = text.index(end, offsetBy: 2, limitedBy: text.endIndex) ?? text.endIndex
                    continue
                }
            }

            if remainder.hasPrefix("`") {
                if let end = remainder.dropFirst(1).range(of: "`")?.lowerBound {
                    let inner = remainder.dropFirst(1)[remainder.dropFirst(1).startIndex..<end]
                    var piece = AttributedString(String(inner))
                    piece.font = .system(.footnote, design: .monospaced)
                    piece.foregroundColor = Theme.red
                    piece.backgroundColor = Theme.border.opacity(0.35)
                    attributed.append(piece)
                    index = text.index(end, offsetBy: 1, limitedBy: text.endIndex) ?? text.endIndex
                    continue
                }
            }

            if remainder.hasPrefix("[") {
                if let link = parseLink(remainder) {
                    var piece = AttributedString(link.label)
                    piece.font = baseFont
                    piece.foregroundColor = Theme.blue
                    piece.underlineStyle = .single
                    if let url = URL(string: link.url) { piece.link = url }
                    attributed.append(piece)
                    index = link.next
                    continue
                }
            }

            var piece = AttributedString(String(remainder.prefix(1)))
            piece.font = baseFont
            piece.foregroundColor = baseColor
            attributed.append(piece)
            index = text.index(after: index)
        }

        return attributed
    }

    private static func parseLink(_ slice: Substring) -> (label: String, url: String, next: String.Index)? {
        var work = slice
        guard work.hasPrefix("[") else { return nil }
        work = work.dropFirst(1)
        guard let closeBracket = work.firstIndex(of: "]") else { return nil }
        let label = String(work[work.startIndex..<closeBracket])
        let afterBracket = work.index(after: closeBracket)
        guard afterBracket < work.endIndex, work[afterBracket] == "(" else { return nil }
        let urlStart = work.index(after: afterBracket)
        guard let closeParen = work[urlStart...].firstIndex(of: ")") else { return nil }
        let url = String(work[urlStart..<closeParen])
        return (label, url, work.index(after: closeParen))
    }
}

// MARK: - 渲染

struct MarkdownContentView: View {
    let markdown: String

    /// 解析结果。**不能在 body 里同步 parse**：
    /// 超长 README 会把主线程顶住，表现就是「点了返回没反应」。
    @State private var blocks: [MDBlock] = []
    @State private var parsed = false

    var body: some View {
        Group {
            if parsed {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                        view(for: block)
                    }
                }
            } else {
                // 解析期间先占位，保证导航随时可返回
                SkeletonBlock(lines: 6)
            }
        }
        .task(id: markdown) {
            let source = markdown
            let result = await Task.detached(priority: .userInitiated) {
                MarkdownParser.parse(source)
            }.value
            guard !Task.isCancelled else { return }
            blocks = result
            parsed = true
        }
    }

    @ViewBuilder
    private func view(for block: MDBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(MarkdownInline.render(text, baseFont: headingFont(level), baseColor: Theme.strongText))
                .font(headingFont(level))
                .padding(.top, level <= 2 ? 6 : 2)

        case .paragraph(let segments):
            MarkdownSegmentFlow(segments: segments, font: .subheadline, color: Theme.muted)

        case .bullet(let segments, let indent):
            listRow(bullet: "•", segments: segments, indent: indent)

        case .ordered(let number, let segments, let indent):
            listRow(bullet: "\(number).", segments: segments, indent: indent, monospacedDigit: true)

        case .quote(let segments):
            HStack(alignment: .top, spacing: 10) {
                Rectangle().fill(Theme.border).frame(width: 3)
                MarkdownSegmentFlow(segments: segments, font: .subheadline, color: Theme.subtle, italic: true)
            }
            .fixedSize(horizontal: false, vertical: true)

        case .code(let language, let content):
            VStack(alignment: .leading, spacing: 0) {
                if let language {
                    Text(language)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.subtle)
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(content)
                        .font(.system(size: 12.5, design: .monospaced))
                        .foregroundStyle(Theme.strongText)
                        .padding(12)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.canvas, in: RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                    .stroke(Theme.border, lineWidth: 1)
            }

        case .table(let header, let rows):
            MarkdownTable(header: header, rows: rows)

        case .rule:
            Hairline()

        case .image(let url, let alt):
            markdownImage(url: url, alt: alt)
        }
    }

    private func listRow(bullet: String,
                         segments: [MDInline],
                         indent: Int,
                         monospacedDigit: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(bullet)
                .font(monospacedDigit ? .subheadline.monospacedDigit() : .subheadline)
                .foregroundStyle(Theme.subtle)
            MarkdownSegmentFlow(segments: segments, font: .subheadline, color: Theme.muted)
        }
        .padding(.leading, CGFloat(min(indent, 4)) * 14)
    }

    @ViewBuilder
    private func markdownImage(url: String, alt: String) -> some View {
        // README 里相对路径的图片没法直接加载，提示一下而不是留个空白
        if let target = resolveMarkdownURL(url), let parsed = URL(string: target) {
            AsyncImage(url: parsed) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFit()
                case .failure:
                    Label(alt.isEmpty ? "图片加载失败" : alt, systemImage: "photo")
                        .font(.caption)
                        .foregroundStyle(Theme.subtle)
                default:
                    RoundedRectangle(cornerRadius: Theme.Radius.small)
                        .fill(Theme.border.opacity(0.3))
                        .frame(height: 140)
                        .overlay { ProgressView() }
                }
            }
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
        } else {
            Label(alt.isEmpty ? "README 内的相对路径图片" : "\(alt)（相对路径）", systemImage: "photo")
                .font(.caption)
                .foregroundStyle(Theme.subtle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Theme.canvas, in: RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .title3.weight(.bold)
        case 2: return .headline.weight(.bold)
        case 3: return .subheadline.weight(.bold)
        default: return .footnote.weight(.bold)
        }
    }
}

/// 行内序列的排版容器。
///
/// 纯文字时就是一个普通 `Text`；一旦混进图片（badge），
/// 就换成自动换行的布局，让 badge 一个挨一个排好，而不是排成一条长线被裁掉。
private struct MarkdownSegmentFlow: View {
    let segments: [MDInline]
    let font: Font
    let color: Color
    var italic: Bool = false

    private var hasPicture: Bool {
        segments.contains { if case .picture = $0 { return true }; return false }
    }

    var body: some View {
        if !hasPicture {
            let text = segments.compactMap { segment -> String? in
                if case .text(let value) = segment { return value }
                return nil
            }.joined()
            Text(MarkdownInline.render(text, baseFont: font, baseColor: color))
                .font(font)
                .italic(italic)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            FlowLayout(spacing: 4) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                    switch segment {
                    case .text(let value):
                        if !value.trimmingCharacters(in: .whitespaces).isEmpty {
                            Text(MarkdownInline.render(value, baseFont: font, baseColor: color))
                                .font(font)
                                .italic(italic)
                        }
                    case .picture(let url, let alt, let link):
                        MarkdownBadge(url: url, alt: alt, link: link)
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// 内联 badge / 图片：限高以免撑破版面，加载失败就退回 alt 文字
private struct MarkdownBadge: View {
    let url: String
    let alt: String
    let link: String?

    var body: some View {
        if let target = resolveMarkdownURL(url), let parsed = URL(string: target) {
            AsyncImage(url: parsed) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFit()
                case .failure:
                    if !alt.isEmpty {
                        Text(alt).font(.system(size: 11)).foregroundStyle(Theme.subtle)
                    }
                default:
                    RoundedRectangle(cornerRadius: Theme.Radius.extraSmall)
                        .fill(Theme.border.opacity(0.25))
                        .frame(width: 56, height: 20)
                }
            }
            .frame(maxHeight: 28)
            .frame(maxWidth: 220)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.extraSmall, style: .continuous))
            .modifier(MarkdownBadgeLink(link: link))
        } else if !alt.isEmpty {
            Text(alt).font(.system(size: 11)).foregroundStyle(Theme.subtle)
        }
    }
}

/// badge 常带一个外链：点击能跳转就跳转，不能就保持普通展示
private struct MarkdownBadgeLink: ViewModifier {
    let link: String?

    func body(content: Content) -> some View {
        if let link, let url = URL(string: link), url.scheme != nil {
            Link(destination: url) { content }
        } else {
            content
        }
    }
}

/// 极简自动换行布局：把子视图按行摆放，放不下就换行。
/// SwiftUI 自带 `Layout` 协议，不需要第三方依赖。
private struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var totalHeight: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth > 0, rowWidth + spacing + size.width > maxWidth {
                totalHeight += rowHeight + spacing
                rowWidth = size.width
                rowHeight = size.height
            } else {
                rowWidth += (rowWidth > 0 ? spacing : 0) + size.width
                rowHeight = max(rowHeight, size.height)
            }
        }
        totalHeight += rowHeight
        return CGSize(width: maxWidth == .infinity ? rowWidth : maxWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y),
                          anchor: .topLeading,
                          proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - 表格

/// 表格：先量宽，再统一绘制。
///
/// 旧实现每行各自 `frame(minWidth: 80, maxWidth: 220)`，内容长短不同列宽就不同，
/// 于是「上下格没对齐」。正确做法是 ——
/// 先按整列里最宽的那个单元格定出列宽，再让该列所有行都用这个宽度。
private struct MarkdownTable: View {
    let header: [[MDInline]]
    let rows: [[[MDInline]]]

    private var columnCount: Int {
        max(header.count, rows.map(\.count).max() ?? 0)
    }

    /// 每列统一的宽度：取整列里最宽单元格的估算宽度
    private var columnWidths: [CGFloat] {
        guard columnCount > 0 else { return [] }
        var widths = [Int](repeating: 6, count: columnCount)

        func measure(_ cells: [[MDInline]]) {
            for (index, cell) in cells.enumerated() where index < columnCount {
                let chars = visualLength(plainText(cell))
                if chars > widths[index] { widths[index] = chars }
            }
        }
        measure(header)
        rows.forEach { measure($0) }

        // 每字符约 7pt，再留出左右 padding；限制在合理区间
        return widths.map { chars in
            min(max(CGFloat(chars) * 7 + 24, 72), 260)
        }
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                row(header, isHeader: true)
                ForEach(Array(rows.enumerated()), id: \.offset) { _, cells in
                    Hairline()
                    row(cells, isHeader: false)
                }
            }
            .background(Theme.surface)
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                    .stroke(Theme.border, lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
        }
    }

    private func row(_ cells: [[MDInline]], isHeader: Bool) -> some View {
        let widths = columnWidths
        return HStack(spacing: 0) {
            ForEach(0..<columnCount, id: \.self) { index in
                let cell = index < cells.count ? cells[index] : []
                MarkdownSegmentFlow(segments: cell,
                                    font: isHeader ? .footnote.bold() : .footnote,
                                    color: isHeader ? Theme.strongText : Theme.muted)
                    .frame(width: widths[index], alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                if index < columnCount - 1 {
                    Rectangle().fill(Theme.border).frame(width: 0.5)
                }
            }
        }
        .frame(minHeight: 32, alignment: .center)
        .background(isHeader ? Theme.canvas : Color.clear)
    }

    /// 估算显示宽度：CJK 字符按 2 个宽度算，其余按 1
    private func visualLength(_ text: String) -> Int {
        text.unicodeScalars.reduce(0) { $0 + ($1.value > 0x2E80 ? 2 : 1) }
    }

    private func plainText(_ cells: [MDInline]) -> String {
        cells.map { segment in
            switch segment {
            case .text(let value): return value
            case .picture(_, let alt, _): return alt
            }
        }.joined()
    }
}

/// README 里的图片地址常见几种形态，统一归一化：
///  - `https://...` / `http://...` 直接用；
///  - `//host/path` 补成 https；
///  - 相对路径 / `data:` 没法直接加载，返回 nil 让它走占位提示。
private func resolveMarkdownURL(_ url: String) -> String? {
    let trimmed = url.trimmingCharacters(in: .whitespaces)
    if trimmed.isEmpty { return nil }
    if trimmed.hasPrefix("https://") || trimmed.hasPrefix("http://") { return trimmed }
    if trimmed.hasPrefix("//") { return "https:" + trimmed }
    return nil
}
