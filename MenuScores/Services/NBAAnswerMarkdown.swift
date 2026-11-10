import Foundation

/// Native text only, with no HTML engine, executable content or image loader.
enum NBAAnswerMarkdown {
    enum Kind: Equatable { case paragraph, heading, bullet, ordered(String), quote, code }
    struct Block: Identifiable { let id: Int; let kind: Kind; let indent: Int; let text: AttributedString }
    private struct RawBlock { let kind: Kind; let indent: Int; let text: String }
    static func safeLink(_ url: URL, known: [URL] = []) -> Bool {
        guard url.scheme?.lowercased() == "https",url.user == nil,url.password == nil,url.port == nil || url.port == 443,let host = url.host?.lowercased() else { return false }
        guard host.contains("."),!host.hasSuffix(".local"),!host.hasSuffix(".localhost"),!host.hasSuffix(".internal"),!host.allSatisfy({ $0.isNumber || $0 == "." || $0 == ":" }) else { return false }
        return host == "nba.com" || host.hasSuffix(".nba.com") || host == "espn.com" || host.hasSuffix(".espn.com") || known.contains(url)
    }
    private static func replacing(_ text: String, pattern: String, transform: (NSTextCheckingResult,String) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern:pattern) else { return text }
        var result = text
        for match in regex.matches(in:text,range:NSRange(text.startIndex...,in:text)).reversed() {
            if let range = Range(match.range,in:result) { result.replaceSubrange(range,with:transform(match,text)) }
        }
        return result
    }
    private static func normalizeText(_ text: String) -> String {
        var value = text
        for delimiter in ["**","__"] {
            let escaped = NSRegularExpression.escapedPattern(for:delimiter)
            value = replacing(value,pattern:"(?<![\\*_])" + escaped + "(?=\\S)([^\\n]+?)" + escaped + "(?![\\*_])") { match,source in
                guard let range = Range(match.range(at:1),in:source),let full = Range(match.range,in:source) else { return "" }
                var inner = String(source[range])
                while inner.last == " " || inner.last == "\t" { inner.removeLast() }
                guard !inner.isEmpty else { return String(source[full]) }
                let following = full.upperBound < source.endIndex ? source[full.upperBound] : nil
                // CommonMark rejects a punctuation-ending delimiter tightly
                // followed by Chinese text. Move only that punctuation outside
                // emphasis, keeping the exact visible sentence unchanged.
                if let last = inner.last,let following,"。！？；：，、.!?;:”’）】》」』".contains(last),following.unicodeScalars.contains(where:CharacterSet.alphanumerics.contains) {
                    inner.removeLast();return delimiter + inner + delimiter + String(last)
                }
                return delimiter + inner + delimiter
            }
        }
        value = replacing(value,pattern:#"!\[([^\]\n]*)\]\([^\n]*?\)"#) { m,s in Range(m.range(at:1),in:s).map { String(s[$0]) } ?? "" }
        value = replacing(value,pattern:#"!\[([^\]\n]*)\](?:\[[^\]\n]*\])?"#) { m,s in Range(m.range(at:1),in:s).map { String(s[$0]) } ?? "" }
        value = replacing(value,pattern:#"</?[A-Za-z][A-Za-z0-9]*(?:\s[^>\n]*)?/?>"#) { m,s in
            guard let range = Range(m.range,in:s) else { return "" }
            return String(s[range]).replacingOccurrences(of:"<",with:"\\<").replacingOccurrences(of:">",with:"\\>")
        }
        return value
    }
    static func normalizedInline(_ text: String) -> String {
        // Literal code, including asterisks or multiplication, stays intact.
        guard let regex = try? NSRegularExpression(pattern:#"(`+)([^`\n]*?)\1"#) else { return normalizeText(text) }
        var output = "",offset = text.startIndex
        for m in regex.matches(in:text,range:NSRange(text.startIndex...,in:text)) {
            guard let range = Range(m.range,in:text) else { continue }
            output += normalizeText(String(text[offset..<range.lowerBound])) + text[range];offset = range.upperBound
        }
        return output + normalizeText(String(text[offset...]))
    }
    private static func inline(_ text: String, known: [URL]) -> AttributedString {
        var value = (try? AttributedString(markdown:normalizedInline(text),options:.init(interpretedSyntax:.inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
        for run in value.runs { if let url = run.link,!safeLink(url,known:known) { value[run.range].link = nil } }
        return value
    }
    static func blocks(_ answer: NBAReviewAnswer) -> [Block] {
        let text = answer.text
        var prepared = "",offset = 0,tokens: [String:(String,URL)] = [:]
        let known = answer.sources.map(\.url) + (answer.localEvidence?.events.map(\.url) ?? [])
        for (index,c) in answer.citations.sorted(by:{$0.start < $1.start}).enumerated() {
            guard c.start >= offset,c.end <= text.count,c.end > c.start,safeLink(c.url,known:known) else { continue }
            let a = text.index(text.startIndex,offsetBy:offset),b = text.index(text.startIndex,offsetBy:c.start),end = text.index(text.startIndex,offsetBy:c.end)
            let token = "\u{F0000}REF\(index)\u{F0001}"
            prepared += text[a..<b] + token;tokens[token] = (String(text[b..<end]),c.url);offset = c.end
        }
        prepared += text[text.index(text.startIndex,offsetBy:offset)...]
        var raw: [RawBlock] = [],paragraph: [String] = [],code: [String] = [],inCode = false
        func flush() { if !paragraph.isEmpty { raw.append(.init(kind:.paragraph,indent:0,text:paragraph.joined(separator:"\n")));paragraph = [] } }
        func capture(_ pattern: String,_ line: String) -> [String]? {
            guard let re = try? NSRegularExpression(pattern:pattern),let m = re.firstMatch(in:line,range:NSRange(line.startIndex...,in:line)) else { return nil }
            return (1..<m.numberOfRanges).map { Range(m.range(at:$0),in:line).map { String(line[$0]) } ?? "" }
        }
        for line in prepared.components(separatedBy:.newlines) {
            let trimmed = line.trimmingCharacters(in:.whitespaces)
            if trimmed.hasPrefix("```") { flush();if inCode { raw.append(.init(kind:.code,indent:0,text:code.joined(separator:"\n")));code = [] };inCode.toggle();continue }
            if inCode { code.append(line);continue }
            if trimmed.isEmpty { flush();continue }
            if let h = capture(#"^\s{0,3}#{1,6}\s+(.+)$"#,line) { flush();raw.append(.init(kind:.heading,indent:0,text:h[0].replacingOccurrences(of:#"\s+#+\s*$"#,with:"",options:.regularExpression)));continue }
            if let b = capture(#"^([ \t]*)[-+*]\s+(.+)$"#,line) { flush();raw.append(.init(kind:.bullet,indent:min(2,b[0].count/2),text:b[1]));continue }
            if let n = capture(#"^([ \t]*)([0-9]{1,3})[.)]\s+(.+)$"#,line) { flush();raw.append(.init(kind:.ordered(n[1] + "."),indent:min(2,n[0].count/2),text:n[2]));continue }
            if let n = capture(#"^([ \t]*)([0-9一二三四五六七八九十]{1,3})、\s*(.+)$"#,line) { flush();raw.append(.init(kind:.ordered(n[1] + "、"),indent:min(2,n[0].count/2),text:n[2]));continue }
            if let q = capture(#"^\s{0,3}>\s?(.*)$"#,line) { flush();raw.append(.init(kind:.quote,indent:0,text:q[0]));continue }
            paragraph.append(line)
        }
        flush();if inCode { raw.append(.init(kind:.code,indent:0,text:code.joined(separator:"\n"))) }
        return raw.enumerated().map { index,b in
            var value = b.kind == .code ? AttributedString(b.text) : inline(b.text,known:known)
            for (token,(original,url)) in tokens {
                let visible = String(value.characters)
                guard let range = visible.range(of:token),let target = Range(range,in:value) else { continue }
                let enclosing = value[target].inlinePresentationIntent
                var cited = inline(original,known:known);cited.link = url
                if let enclosing { for run in cited.runs { cited[run.range].inlinePresentationIntent = (run.inlinePresentationIntent ?? []).union(enclosing) } }
                value.replaceSubrange(target,with:cited)
            }
            return Block(id:index,kind:b.kind,indent:b.indent,text:value)
        }
    }
    static func combined(_ answer: NBAReviewAnswer) -> AttributedString {
        var result = AttributedString()
        for b in blocks(answer) {
            if !result.characters.isEmpty { result.append(AttributedString("\n\n")) }
            switch b.kind { case .bullet:result.append(AttributedString("• "));case .ordered(let n):result.append(AttributedString(n + " "));default:break }
            result.append(b.text)
        }
        return result
    }
}
