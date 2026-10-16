import Foundation
import IWASchema
import KeynoteGraph
import Rostrum

// R2: a text storage laid out in its shape's frame. Paragraph and character styles resolve
// through their chains; widths come from Rostrum's `FontMetrics` for the face Keynote names;
// lines break greedily at spaces; the browser draws the glyphs.

/// A run's resolved character properties.
struct CharLook: Equatable {
    var fontName = "HelveticaNeue"
    var size = 12.0
    var bold = false, italic = false
    var color = SVG.RGBA(r: 0, g: 0, b: 0, a: 1)
    var tracking = 0.0
    var baselineShift = 0.0
    var superscript: TSWP_CharacterStylePropertiesArchive.SuperscriptType = .kNoScript
    var capitalization: TSWP_CharacterStylePropertiesArchive.CapitalizationType = .kNoCaps
    var underline = false, strikethrough = false
}

/// A paragraph's resolved properties.
struct ParaLook {
    var alignment: TSWP_ParagraphStylePropertiesArchive.TextAlignmentType = .tatvalue4
    var leftIndent = 0.0, rightIndent = 0.0, firstLineIndent = 0.0
    var spaceBefore = 0.0, spaceAfter = 0.0
    var lineSpacingMode: TSWP_LineSpacingArchive.LineSpacingModeType = .kRelativeLineSpacing
    var lineSpacing = 1.0
    var defaultTabStop = 36.0
    var char = CharLook()
    var listStyle: UInt64?
}

extension StyleResolver {
    func paragraphStyles(_ id: UInt64?) -> [TSWP_ParagraphStyleArchive] {
        id.map { chain(TSWP_ParagraphStyleArchive.self, from: $0) { $0.super } } ?? []
    }

    func characterStyles(_ id: UInt64?) -> [TSWP_CharacterStyleArchive] {
        id.map { chain(TSWP_CharacterStyleArchive.self, from: $0) { $0.super } } ?? []
    }

    /// Character properties: the first value met in `props`, nearest style first.
    static func charLook(_ props: [TSWP_CharacterStylePropertiesArchive]) -> CharLook {
        var c = CharLook()
        if let v = first(props, { $0.hasFontName || $0.hasFontNameNull }, { $0.hasFontName ? $0.fontName : nil }), let v { c.fontName = v }
        if let v = first(props, \.hasFontSize, \.fontSize) { c.size = Double(v) }
        if let v = first(props, \.hasBold, \.bold) { c.bold = v }
        if let v = first(props, \.hasItalic, \.italic) { c.italic = v }
        let fill = first(props, { $0.hasTsdFill || $0.hasTsdFillNull || $0.hasFontColor || $0.hasFontColorNull }) { p -> TSP_Color? in
            if p.hasTsdFill {
                if p.tsdFill.hasColor { return p.tsdFill.color }
                if p.tsdFill.hasGradient, let stop = p.tsdFill.gradient.stops.first { return stop.color }
                return nil
            }
            return p.hasFontColor ? p.fontColor : nil
        }
        if let fill, let fill { c.color = SVG.RGBA(fill) }
        if let v = first(props, \.hasTracking, \.tracking) { c.tracking = Double(v) }
        if let v = first(props, \.hasBaselineShift, \.baselineShift) { c.baselineShift = Double(v) }
        if let v = first(props, \.hasSuperscript, \.superscript) { c.superscript = v }
        if let v = first(props, \.hasCapitalization, \.capitalization) { c.capitalization = v }
        if let v = first(props, \.hasUnderline, \.underline) { c.underline = v != .kNoUnderline }
        if let v = first(props, \.hasStrikethru, \.strikethru) { c.strikethrough = v != .kNoStrikethru }
        return c
    }

    func paraLook(_ id: UInt64?) -> ParaLook {
        let chain = paragraphStyles(id)
        let p = chain.map(\.paraProperties)
        var look = ParaLook()
        if let v = Self.first(p, \.hasAlignment, \.alignment) { look.alignment = v }
        if let v = Self.first(p, \.hasLeftIndent, \.leftIndent) { look.leftIndent = Double(v) }
        if let v = Self.first(p, \.hasRightIndent, \.rightIndent) { look.rightIndent = Double(v) }
        if let v = Self.first(p, \.hasFirstLineIndent, \.firstLineIndent) { look.firstLineIndent = Double(v) }
        if let v = Self.first(p, \.hasSpaceBefore, \.spaceBefore) { look.spaceBefore = Double(v) }
        if let v = Self.first(p, \.hasSpaceAfter, \.spaceAfter) { look.spaceAfter = Double(v) }
        if let v = Self.first(p, \.hasDefaultTabStops, \.defaultTabStops), v > 0 { look.defaultTabStop = Double(v) }
        if let s = Self.first(p, { $0.hasLineSpacing || $0.hasLineSpacingNull }, { $0.hasLineSpacing ? $0.lineSpacing : nil }), let s {
            look.lineSpacingMode = s.hasMode ? s.mode : .kRelativeLineSpacing
            look.lineSpacing = s.hasAmount ? Double(s.amount) : 1
        }
        if let v = Self.first(p, { $0.hasListStyle || $0.hasListStyleNull }, { $0.hasListStyle ? $0.listStyle.identifier : nil }) { look.listStyle = v }
        look.char = Self.charLook(chain.map(\.charProperties))
        return look
    }
}

/// One measured piece of a line: text in one character look.
struct Span {
    var text: String
    var look: CharLook
    var width: Double
}

struct Line {
    var spans: [Span] = []
    var width: Double { spans.reduce(0) { $0 + $1.width } }
    var ascent = 0.0, descent = 0.0, leading = 0.0
    var x = 0.0, available = 0.0
    var baseline = 0.0
    var alignment: TSWP_ParagraphStylePropertiesArchive.TextAlignmentType = .tatvalue4
    var justify = false
    var label: (text: String, look: CharLook, x: Double)?
}

extension Canvas {
    /// The face to measure and draw a look in: Keynote's named face, or its family's face with the
    /// requested traits when a bold or italic flag asks for one the name lacks.
    func face(_ look: CharLook) -> (family: String, metrics: FontMetrics?, synthetic: (bold: Bool, italic: Bool)) {
        guard let fonts, let named = fonts.face(postScriptName: look.fontName) else {
            return ("'\(look.fontName)'", nil, (look.bold, look.italic))
        }
        var face = named
        if (look.bold && !named.bold) || (look.italic && !named.italic) {
            if let other = fonts.face(family: named.family, bold: look.bold || named.bold, italic: look.italic || named.italic) { face = other }
        }
        let synthetic = (look.bold && !face.bold, look.italic && !face.italic)
        return ("'\(face.postScriptName)', '\(face.family)'", fonts.metrics(postScriptName: face.postScriptName), synthetic)
    }

    func effectiveSize(_ look: CharLook) -> Double {
        look.superscript == .kNoScript ? look.size : look.size * 0.66
    }

    /// The width of `text` in `look`, tracking included.
    mutating func measure(_ text: String, _ look: CharLook) -> Double {
        let size = effectiveSize(look)
        let tracked = Double(text.count) * look.tracking * size
        if let m = face(look).metrics {
            return m.width(of: text, pointSize: size) + tracked
        }
        problems.insert("font \(look.fontName)")
        return text.unicodeScalars.reduce(0.0) { $0 + ($1.value >= 0x2E80 ? 1.0 : 0.55) } * size + tracked
    }

    func vertical(_ look: CharLook) -> (ascent: Double, descent: Double, leading: Double) {
        let size = effectiveSize(look)
        if let m = face(look).metrics {
            let upem = Double(m.unitsPerEm)
            return (Double(m.ascender) / upem * size, -Double(m.descender) / upem * size, Double(m.lineGap) / upem * size)
        }
        return (0.8 * size, 0.2 * size, 0)
    }

    static func displayed(_ text: String, _ look: CharLook) -> String {
        switch look.capitalization {
        case .kAllCaps: return text.uppercased()
        case .kTitled: return text.capitalized
        default: return text
        }
    }

    static func entryAt<E>(_ entries: [E], _ index: Int, _ position: (E) -> UInt32) -> E? {
        var found: E?
        for e in entries where Int(position(e)) <= index { found = e }
        return found
    }

    /// The text of `storage` laid out in a `width × height` frame, as `<text>` elements.
    mutating func textMarkup(storage: UInt64, width: Double, height: Double, look shape: StyleResolver.ShapeLook) -> String {
        guard let archive = document.decoded(TSWP_StorageArchive.self, storage) else { problems.insert("text storage"); return "" }
        let units = Array(archive.text.joined().utf16)
        guard !units.isEmpty else { return "" }

        // Paragraph boundaries in UTF-16 offsets.
        var paragraphs: [Range<Int>] = []
        var start = 0
        for (i, u) in units.enumerated() where u == 0x0A || u == 0x0D || u == 0x2029 {
            paragraphs.append(start..<i)
            start = i + 1
        }
        paragraphs.append(start..<units.count)

        let paraEntries = archive.tableParaStyle.entries.sorted { $0.characterIndex < $1.characterIndex }
        let charEntries = archive.tableCharStyle.entries.sorted { $0.characterIndex < $1.characterIndex }
        let listEntries = archive.tableListStyle.entries.sorted { $0.characterIndex < $1.characterIndex }
        let levelEntries = archive.tableParaData.entries.sorted { $0.characterIndex < $1.characterIndex }
        let attachments = Dictionary(archive.tableAttachment.entries.map { (Int($0.characterIndex), $0.hasObject ? $0.object.identifier : 0) }, uniquingKeysWith: { a, _ in a })

        // A null paragraph-style entry continues the style before it.
        func paraStyle(at index: Int) -> UInt64? {
            var style = shape.paragraphStyle
            for e in paraEntries where Int(e.characterIndex) <= index && e.hasObject { style = e.object.identifier }
            return style
        }

        let available = max(1, width - shape.padding.left - shape.padding.right)
        var scale = 1.0
        var lines = [Line]()
        var lookCache = [UInt64: CharLook]()
        var paraCache = [UInt64: ParaLook]()

        func layout(scale: Double) -> (lines: [Line], height: Double) {
            var out = [Line]()
            var y = 0.0
            for (pi, range) in paragraphs.enumerated() {
                let paraID = paraStyle(at: range.lowerBound)
                var para: ParaLook
                if let id = paraID, let cached = paraCache[id] { para = cached } else {
                    para = styles.paraLook(paraID)
                    if let id = paraID { paraCache[id] = para }
                }
                let level = Int(Self.entryAt(levelEntries, range.lowerBound, \.characterIndex)?.first ?? 0)
                let listID = Self.entryAt(listEntries, range.lowerBound, \.characterIndex).flatMap { $0.hasObject ? $0.object.identifier : nil } ?? para.listStyle

                // Runs: character style changes and attachments split the paragraph.
                var runs = [(String, CharLook)]()
                var i = range.lowerBound
                while i < range.upperBound {
                    let charEntry = Self.entryAt(charEntries, i, \.characterIndex)
                    let charID = charEntry.flatMap { $0.hasObject ? $0.object.identifier : nil }
                    var look: CharLook
                    if let charID {
                        if let cached = lookCache[charID] { look = cached } else {
                            look = StyleResolver.charLook(styles.characterStyles(charID).map(\.charProperties) + styles.paragraphStyles(paraID).map(\.charProperties))
                            lookCache[charID] = look
                        }
                    } else {
                        look = para.char
                    }
                    look.size *= scale
                    let nextChar = charEntries.first { Int($0.characterIndex) > i }.map { Int($0.characterIndex) } ?? range.upperBound
                    var end = min(nextChar, range.upperBound)
                    if let a = attachments.keys.filter({ $0 >= i && $0 < end }).min() { end = a == i ? i + 1 : a }
                    var text = String(decoding: units[i..<end], as: UTF16.self)
                    if end == i + 1, let object = attachments[i] {
                        text = attachmentText(object)
                    }
                    runs.append((Self.displayed(text, look), look))
                    i = end
                }
                if runs.isEmpty { runs = [("", { var l = para.char; l.size *= scale; return l }())] }

                // The list label and the indents it brings.
                var label: (String, CharLook, Double)?
                var left = para.leftIndent * scale, first = para.firstLineIndent * scale
                if let listID, let list = document.decoded(TSWP_ListStyleArchive.self, listID) {
                    let l = min(level, 8)
                    let type = list.labelTypes.indices.contains(l) ? list.labelTypes[l] : .kNone
                    let indent = list.indents.indices.contains(l) ? Double(list.indents[l]) : 0
                    let textIndent = list.textIndents.indices.contains(l) ? Double(list.textIndents[l]) : 0
                    var labelLook = runs.first?.1 ?? para.char
                    if list.hasFontColor { labelLook.color = SVG.RGBA(list.fontColor) }
                    if list.hasFontName { labelLook.fontName = list.fontName }
                    if list.geometries.indices.contains(l) {
                        let g = list.geometries[l]
                        if g.hasScale { labelLook.size *= Double(g.scale) }
                    }
                    labelLook.underline = false; labelLook.strikethrough = false; labelLook.tracking = 0
                    var text: String?
                    switch type {
                    case .kString: text = list.strings.indices.contains(l) ? list.strings[l] : "•"
                    case .kNumber:
                        let ordinal = numberOf(paragraph: pi, level: level, listID: listID, paragraphs: paragraphs, levels: levelEntries, lists: listEntries)
                        text = "\(ordinal)."
                    case .kImage: text = "•"; problems.insert("image bullet")
                    case .kNone: text = nil
                    }
                    if let text, !runs.allSatisfy({ $0.0.isEmpty }) {
                        let labelWidth = measure(text, labelLook)
                        label = (text, labelLook, indent * scale)
                        // The text starts the list's text indent, in ems of the text's size, past
                        // the label's indent (Basic White: 1.0 at 48 pt puts it 48 pt in).
                        let size = (runs.first?.1.size ?? para.char.size)
                        left += indent * scale + max(labelWidth, textIndent * size)
                        first = 0
                    } else {
                        left += indent * scale
                    }
                }

                // Greedy line breaking over measured pieces: a piece is a word with its spaces.
                var pieces = [(String, CharLook, Bool)]()  // text, look, forced break after
                for (text, look) in runs {
                    var word = ""
                    for ch in text {
                        if ch == "\u{2028}" || ch == "\u{0B}" {
                            pieces.append((word, look, true)); word = ""
                        } else {
                            word.append(ch)
                            if ch == " " || ch == "\t" || ch == "-" || ch == "\u{2014}" || (ch.unicodeScalars.first.map { $0.value >= 0x2E80 && $0.value < 0xA000 } ?? false) {
                                pieces.append((word, look, false)); word = ""
                            }
                        }
                    }
                    if !word.isEmpty { pieces.append((word, look, false)) }
                }
                if pieces.isEmpty { pieces = [("", runs[0].1, false)] }

                var paraLines = [Line]()
                var current = Line()
                func start(_ isFirst: Bool) {
                    current = Line()
                    current.x = shape.padding.left + left + (isFirst ? first : 0)
                    current.available = max(1, available - left - (isFirst ? first : 0) - para.rightIndent * scale)
                    current.alignment = para.alignment
                }
                start(true)
                func append(_ text: String, _ look: CharLook) {
                    let w = measure(text.replacingOccurrences(of: "\t", with: " "), look)
                    if let last = current.spans.last, last.look == look {
                        current.spans[current.spans.count - 1].text += text
                        current.spans[current.spans.count - 1].width += w
                    } else {
                        current.spans.append(Span(text: text, look: look, width: w))
                    }
                    let v = vertical(look)
                    current.ascent = max(current.ascent, v.ascent); current.descent = max(current.descent, v.descent); current.leading = max(current.leading, v.leading)
                }
                func finishLine(justify: Bool) {
                    if current.spans.isEmpty {
                        let v = vertical(runs[0].1)
                        current.ascent = v.ascent; current.descent = v.descent; current.leading = v.leading
                    }
                    // Trailing spaces hang past the margin.
                    if var lastSpan = current.spans.popLast() {
                        let trimmed = String(lastSpan.text.reversed().drop(while: { $0 == " " }).reversed())
                        if trimmed != lastSpan.text { lastSpan.width = measure(trimmed, lastSpan.look); lastSpan.text = trimmed }
                        current.spans.append(lastSpan)
                    }
                    current.justify = justify
                    paraLines.append(current)
                    start(false)
                }
                for (text, look, forced) in pieces {
                    let trimmedWidth = measure(String(text.reversed().drop(while: { $0 == " " }).reversed()), look)
                    if !current.spans.isEmpty && current.width + trimmedWidth > current.available + 0.01 {
                        finishLine(justify: para.alignment == .tatvalue3)
                    }
                    if current.spans.isEmpty && trimmedWidth > current.available + 0.01 {
                        // A word wider than the line breaks between characters.
                        var chunk = ""
                        for ch in text {
                            if !chunk.isEmpty && measure(chunk + String(ch), look) > current.available {
                                append(chunk, look); finishLine(justify: false); chunk = ""
                            }
                            chunk.append(ch)
                        }
                        if !chunk.isEmpty { append(chunk, look) }
                    } else {
                        append(text, look)
                    }
                    if forced { finishLine(justify: false) }
                }
                finishLine(justify: false)
                // The label sits on the paragraph's first line.
                if let label, !paraLines.isEmpty {
                    paraLines[0].label = (label.0, label.1, shape.padding.left + para.leftIndent * scale + label.2)
                }

                // Vertical placement.
                if pi > 0 { y += para.spaceBefore * scale }
                for var line in paraLines {
                    let natural = line.ascent + line.descent + line.leading
                    var height: Double
                    switch para.lineSpacingMode {
                    case .kRelativeLineSpacing: height = natural * para.lineSpacing
                    case .kMinimumLineSpacing: height = max(natural, para.lineSpacing * scale)
                    case .kExactLineSpacing: height = para.lineSpacing * scale
                    case .kMaximumLineSpacing: height = min(natural, para.lineSpacing * scale)
                    case .kSpaceBetweenLineSpacing: height = natural + para.lineSpacing * scale
                    }
                    // Spacing below 1 takes its share from above the baseline (a 0.8 title's
                    // baseline sits 0.8 of an ascent below the line's top).
                    let ascent = para.lineSpacingMode == .kRelativeLineSpacing ? line.ascent * min(para.lineSpacing, 1) + max(0, height - natural) : line.ascent - (natural - height) * (line.ascent / max(natural, 0.001))
                    line.baseline = y + ascent
                    y += height
                    out.append(line)
                }
                y += para.spaceAfter * scale
            }
            return (out, y)
        }

        var result = layout(scale: 1)
        let availableHeight = max(1, height - shape.padding.top - shape.padding.bottom)
        if shape.shrinkToFit, result.height > availableHeight + 0.5 {
            var lo = 0.2, hi = 1.0
            for _ in 0..<12 {
                let mid = (lo + hi) / 2
                if layout(scale: mid).height <= availableHeight + 0.5 { lo = mid } else { hi = mid }
            }
            scale = lo
            result = layout(scale: scale)
        }
        lines = result.lines

        var top = shape.padding.top
        switch shape.verticalAlignment {
        case .kFrameAlignMiddle: top += (availableHeight - result.height) / 2
        case .kFrameAlignBottom: top += availableHeight - result.height
        default: break
        }

        // The first line never starts above the frame's inset: Keynote moves the text down rather
        // than cut its ascent off (a top-aligned title with spacing below 1).
        if let first = lines.first, top + first.baseline - first.ascent < shape.padding.top {
            top = shape.padding.top + first.ascent - first.baseline
        }

        var out = ""
        for line in lines {
            let baseline = top + line.baseline
            if let label = line.label {
                out += textElement([Span(text: label.text, look: label.look, width: 0)], x: label.x, baseline: baseline, anchor: nil, justifyWidth: nil)
            }
            guard !line.spans.isEmpty, line.spans.contains(where: { !$0.text.isEmpty }) else { continue }
            var x = line.x, anchor: String?
            switch line.alignment {
            case .tatvalue1: x = line.x + line.available; anchor = "end"
            case .tatvalue2: x = line.x + line.available / 2; anchor = "middle"
            default: break
            }
            out += textElement(line.spans, x: x, baseline: baseline, anchor: anchor, justifyWidth: line.justify ? line.available : nil)
        }
        return out
    }

    mutating func textElement(_ spans: [Span], x: Double, baseline: Double, anchor: String?, justifyWidth: Double?) -> String {
        var s = "<text x=\"\(SVG.n(x))\" y=\"\(SVG.n(baseline))\" xml:space=\"preserve\""
        if let anchor { s += " text-anchor=\"\(anchor)\"" }
        if let justifyWidth { s += " textLength=\"\(SVG.n(justifyWidth))\" lengthAdjust=\"spacing\"" }
        s += ">"
        for span in spans where !span.text.isEmpty {
            let look = span.look
            let f = face(look)
            s += "<tspan font-family=\"\(SVG.escape(f.family)), sans-serif\" font-size=\"\(SVG.n(effectiveSize(look)))\""
            if f.synthetic.bold { s += " font-weight=\"bold\"" }
            if f.synthetic.italic { s += " font-style=\"italic\"" }
            s += SVG.paint("fill", look.color)
            if look.tracking != 0 { s += " letter-spacing=\"\(SVG.n(look.tracking * effectiveSize(look)))\"" }
            var shift = look.baselineShift
            if look.superscript == .kSuperscript { shift += look.size * 0.33 }
            if look.superscript == .kSubscript { shift -= look.size * 0.15 }
            if shift != 0 { s += " baseline-shift=\"\(SVG.n(shift))\"" }
            var decoration = [String]()
            if look.underline { decoration.append("underline") }
            if look.strikethrough { decoration.append("line-through") }
            if !decoration.isEmpty { s += " text-decoration=\"\(decoration.joined(separator: " "))\"" }
            s += ">" + SVG.escape(span.text.replacingOccurrences(of: "\t", with: "    ")) + "</tspan>"
        }
        return s + "</text>"
    }

    /// The text an attachment shows: a slide number field shows the slide's number.
    mutating func attachmentText(_ object: UInt64) -> String {
        if type(of: object) == Self.slideNumberAttachmentType { return slideNumber.map(String.init) ?? "" }
        if object != 0 { problems.insert("attachment") }
        return ""
    }

    /// A numbered paragraph's ordinal: one more than the paragraphs before it at its level since
    /// the last paragraph at a shallower level.
    func numberOf(paragraph: Int, level: Int, listID: UInt64, paragraphs: [Range<Int>],
                  levels: [TSWP_ParaDataAttributeTable.ParaDataAttribute], lists: [TSWP_ObjectAttributeTable.ObjectAttribute]) -> Int {
        var n = 1
        var p = paragraph - 1
        while p >= 0 {
            let l = Int(Self.entryAt(levels, paragraphs[p].lowerBound, \.characterIndex)?.first ?? 0)
            if l < level { break }
            if l == level { n += 1 }
            p -= 1
        }
        return n
    }

    static let slideNumberAttachmentType: UInt32 = 22
}
