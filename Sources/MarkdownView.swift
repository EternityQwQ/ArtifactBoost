import SwiftUI

/// 轻量 Markdown 渲染，够用于 README：标题 / 段落 / 列表 / 代码块 / 引用 / 表格 / 分割线 / 图片。
/// 不引入第三方依赖，纯 SwiftUI + AttributedString 做内联样式。

enum MDBlock: Hashable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case bullet(text: String, indent: Int)
    case ordered(number: String, text: String, indent: Int)
    case quote(String)
    case code(language: String?, content: String)
    case table(header: [String], rows: [[String]])
    case rule
    case image(url: String, alt: String)
}

enum MarkdownParser {
    static func parse(_ source: String) -> [MDBlock] {
        var blocks: [MDBlock] = []
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
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

            // 分割线
            if line == "---" || line == "***" || line == "___" {
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
                let header = splitTableRow(line)
                var rows: [[String]] = []
                index += 2
                while index < lines.count, lines[index].contains("|") {
                    rows.append(splitTableRow(lines[index]))
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
                blocks.append(.quote(buffer.joined(separator: " ")))
                continue
            }

            // 独占一行的图片
            if line.hasPrefix("!["), let image = parseImage(line) {
                blocks.append(.image(url: image.url, alt: image.alt))
                index += 1
                continue
            }

            // 列表
            if let marker = parseListMarker(raw) {
                switch marker.kind {
                case .bullet:
                    blocks.append(.bullet(text: marker.text, indent: marker.indent))
                case .ordered(let number):
                    blocks.append(.ordered(number: number, text: marker.text, indent: marker.indent))
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
                    || trimmed.hasPrefix("#")
                    || trimmed.hasPrefix("```")
                    || trimmed.hasPrefix(">")
                    || trimmed == "---" || trimmed == "***" || trimmed == "___"
                    || parseListMarker(current) != nil {
                    break
                }
                buffer.append(trimmed)
                index += 1
            }
            blocks.append(.paragraph(buffer.joined(separator: " ")))
        }

        return blocks
    }

    // MARK: - 辅助

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
        return trimmed.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func parseImage(_ line: String) -> (url: String, alt: String)? {
        guard let openAlt = line.firstIndex(of: "["),
              let closeAlt = line.firstIndex(of: "]"),
              let openURL = line.firstIndex(of: "("),
              let closeURL = line.lastIndex(of: ")"),
              openAlt < closeAlt, closeAlt < openURL, openURL < closeURL else { return nil }
        let alt = String(line[line.index(after: openAlt)..<closeAlt])
        let url = String(line[line.index(after: openURL)..<closeURL])
        return (url, alt)
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

// MARK: - 内联样式

enum MarkdownInline {
    /// 把 `**粗**`、`` `代码` ``、`[文字](链接)` 解析为 AttributedString
    static func render(_ text: String, baseFont: Font, baseColor: Color) -> AttributedString {
        var attributed = AttributedString()
        var index = text.startIndex

        while index < text.endIndex {
            let remainder = text[index...]

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

            if remainder.hasPrefix("[") || remainder.hasPrefix("![") {
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
        if work.hasPrefix("![") {
            work = work.dropFirst(2)
        } else if work.hasPrefix("[") {
            work = work.dropFirst(1)
        } else {
            return nil
        }
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

    var body: some View {
        let blocks = MarkdownParser.parse(markdown)
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
    }

    @ViewBuilder
    private func view(for block: MDBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(MarkdownInline.render(text, baseFont: headingFont(level), baseColor: Theme.strongText))
                .font(headingFont(level))
                .padding(.top, level <= 2 ? 6 : 2)

        case .paragraph(let text):
            Text(MarkdownInline.render(text, baseFont: .subheadline, baseColor: Theme.muted))
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)

        case .bullet(let text, let indent):
            listRow(bullet: "•", text: text, indent: indent)

        case .ordered(let number, let text, let indent):
            listRow(bullet: "\(number).", text: text, indent: indent, monospacedDigit: true)

        case .quote(let text):
            HStack(alignment: .top, spacing: 10) {
                Rectangle().fill(Theme.border).frame(width: 3)
                Text(MarkdownInline.render(text, baseFont: .subheadline, baseColor: Theme.subtle))
                    .font(.subheadline)
                    .italic()
                    .fixedSize(horizontal: false, vertical: true)
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
            .background(Theme.canvas, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
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
                         text: String,
                         indent: Int,
                         monospacedDigit: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(bullet)
                .font(monospacedDigit ? .subheadline.monospacedDigit() : .subheadline)
                .foregroundStyle(Theme.subtle)
            Text(MarkdownInline.render(text, baseFont: .subheadline, baseColor: Theme.muted))
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, CGFloat(min(indent, 4)) * 14)
    }

    @ViewBuilder
    private func markdownImage(url: String, alt: String) -> some View {
        // README 里相对路径的图片没法直接加载，提示一下而不是留个空白
        if let parsed = URL(string: url), parsed.scheme != nil {
            AsyncImage(url: parsed) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFit()
                case .failure:
                    Label(alt.isEmpty ? "图片加载失败" : alt, systemImage: "photo")
                        .font(.caption)
                        .foregroundStyle(Theme.subtle)
                default:
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Theme.border.opacity(0.3))
                        .frame(height: 140)
                        .overlay { ProgressView() }
                }
            }
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else {
            Label(alt.isEmpty ? "README 内的相对路径图片" : "\(alt)（相对路径）", systemImage: "photo")
                .font(.caption)
                .foregroundStyle(Theme.subtle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Theme.canvas, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
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

private struct MarkdownTable: View {
    let header: [String]
    let rows: [[String]]

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
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Theme.border, lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    private func row(_ cells: [String], isHeader: Bool) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(cells.enumerated()), id: \.offset) { index, cell in
                Text(MarkdownInline.render(cell,
                                           baseFont: isHeader ? .footnote.bold() : .footnote,
                                           baseColor: isHeader ? Theme.strongText : Theme.muted))
                    .font(isHeader ? .footnote.bold() : .footnote)
                    .frame(minWidth: 80, maxWidth: 220, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                if index < cells.count - 1 {
                    Rectangle().fill(Theme.border).frame(width: 0.5)
                }
            }
        }
    }
}
