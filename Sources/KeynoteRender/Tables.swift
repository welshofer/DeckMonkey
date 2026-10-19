import Foundation
import IWASchema
import KeynoteGraph

// R3: a table drawn as Keynote shows it in a PDF: row and column sizes from the header buckets,
// cell fills from the region and cell styles, cell values from the packed cell storage, borders
// from the table style with the stroke sidecar's custom strokes on top.

/// One cell's stored value and style references, decoded from a tile row's packed storage.
struct StoredCell: Equatable {
    enum Kind: UInt8 { case empty = 0, number = 2, text = 3, date = 5, bool = 6, duration = 7, error = 8, richText = 9, currency = 10 }
    var kind: Kind = .empty
    var decimal: Double?
    var double: Double?
    var seconds: Double?
    var stringID: UInt32?
    var richTextID: UInt32?
    var cellStyleID: UInt32?
    var textStyleID: UInt32?
    var formats: [UInt32: UInt32] = [:]  // flag bit → format id
    var formatHint: UInt16 = 0
    /// A conditional style set (a key in the conditional style list) and the rule of it that
    /// matched, when one did.
    var conditionalStyleID: UInt32?
    var appliedRule: UInt32?

    var number: Double? { decimal ?? double }

    init() {}

    /// Field flags in storage order, with each field's size in bytes. Learned from Keynote 15.4
    /// tables (version 5 storage): a 12-byte header (version, kind, two bytes, a 16-bit format hint
    /// at 6, the 32-bit flags at 8), then the flagged fields in bit order.
    static let fields: [(flag: UInt32, size: Int)] = [
        (0x1, 16), (0x2, 8), (0x4, 8), (0x8, 4), (0x10, 4), (0x20, 4), (0x40, 4), (0x80, 4), (0x100, 4), (0x200, 4),
        (0x400, 4), (0x800, 4), (0x1000, 4), (0x2000, 4), (0x4000, 4), (0x8000, 4), (0x10000, 4), (0x20000, 4),
        (0x40000, 4), (0x80000, 4), (0x100000, 4),
    ]
    static let numberFormat: UInt32 = 0x2000, currencyFormat: UInt32 = 0x4000, dateFormat: UInt32 = 0x8000
    static let durationFormat: UInt32 = 0x10000, textFormat: UInt32 = 0x20000, boolFormat: UInt32 = 0x40000

    /// Decodes the cell at `offset` in `buffer`, or nil when it is not version 5 or runs past the end.
    init?(_ buffer: [UInt8], at offset: Int) {
        func u32(_ o: Int) -> UInt32? {
            guard o >= 0, o + 4 <= buffer.count else { return nil }
            return UInt32(buffer[o]) | UInt32(buffer[o + 1]) << 8 | UInt32(buffer[o + 2]) << 16 | UInt32(buffer[o + 3]) << 24
        }
        guard offset >= 0, offset + 12 <= buffer.count else { return nil }
        if buffer[offset] == 4 {
            guard let v4 = Self.version4(buffer, at: offset) else { return nil }
            self = v4
            return
        }
        guard buffer[offset] == 5, let flags = u32(offset + 8) else { return nil }
        kind = Kind(rawValue: buffer[offset + 1]) ?? .empty
        formatHint = UInt16(buffer[offset + 6]) | UInt16(buffer[offset + 7]) << 8
        var o = offset + 12
        for (flag, size) in Self.fields where flags & flag != 0 {
            guard o + size <= buffer.count else { return nil }
            switch flag {
            case 0x1: decimal = Self.decimal128(Array(buffer[o..<(o + 16)]))
            case 0x2: double = Double(bitPattern: UInt64(u32(o)!) | UInt64(u32(o + 4)!) << 32)
            case 0x4: seconds = Double(bitPattern: UInt64(u32(o)!) | UInt64(u32(o + 4)!) << 32)
            case 0x8: stringID = u32(o)
            case 0x10: richTextID = u32(o)
            case 0x20: cellStyleID = u32(o)
            case 0x40: textStyleID = u32(o)
            case Self.numberFormat, Self.currencyFormat, Self.dateFormat, Self.durationFormat, Self.textFormat, Self.boolFormat:
                formats[flag] = u32(o)
            default: break
            }
            o += size
        }
    }

    /// Version 4 ("pre-BNC", Keynote 6 and 7) storage, learned from a Keynote 7.2 table: a
    /// 12-byte header (version, kind, two bytes, the 32-bit flags at 4, a second flag word at
    /// 8), then the 4-byte fields in the order 0x400 (conditional style set), 0x800 (the rule
    /// that matched; 15 for none), 0x4 and 0x8 (style indexes), 0x10 (the string), and the 8-byte
    /// double (0x20) after them. A cell with any other flag is not decoded rather than misread.
    static func version4(_ buffer: [UInt8], at offset: Int) -> StoredCell? {
        func u32(_ o: Int) -> UInt32? {
            guard o >= 0, o + 4 <= buffer.count else { return nil }
            return UInt32(buffer[o]) | UInt32(buffer[o + 1]) << 8 | UInt32(buffer[o + 2]) << 16 | UInt32(buffer[o + 3]) << 24
        }
        guard let flags = u32(offset + 4), flags & ~UInt32(0x4 | 0x8 | 0x10 | 0x20 | 0x400 | 0x800) == 0 else { return nil }
        var cell = StoredCell()
        cell.kind = Kind(rawValue: buffer[offset + 1]) ?? .empty
        var o = offset + 12
        for flag: UInt32 in [0x400, 0x800, 0x4, 0x8, 0x10] where flags & flag != 0 {
            guard let v = u32(o) else { return nil }
            switch flag {
            case 0x10: cell.stringID = v
            case 0x400: cell.conditionalStyleID = v
            case 0x800: cell.appliedRule = v
            default: break
            }
            o += 4
        }
        if flags & 0x20 != 0 {
            guard let lo = u32(o), let hi = u32(o + 4) else { return nil }
            cell.double = Double(bitPattern: UInt64(lo) | UInt64(hi) << 32)
        }
        return cell
    }

    /// An IEEE 754-2008 decimal128 in Apple's binary-integer encoding: a 113-bit little-endian
    /// coefficient, then a 14-bit exponent biased by 6176 and the sign in the top bit.
    static func decimal128(_ b: [UInt8]) -> Double {
        var coefficient = 0.0
        for i in stride(from: 13, through: 0, by: -1) { coefficient = coefficient * 256 + Double(b[i]) }
        coefficient += Double(b[14] & 1) * pow(2, 112)
        let exponent = (Int(b[15] & 0x7F) << 7 | Int(b[14]) >> 1) - 6176
        let value = coefficient * pow(10, Double(exponent))
        return b[15] & 0x80 != 0 ? -value : value
    }
}

extension Canvas {
    mutating func drawTable(_ info: TST_TableInfoArchive) {
        let d = info.super
        guard d.hasGeometry, info.hasTableModel, let model = document.decoded(TST_TableModelArchive.self, info.tableModel.identifier) else {
            problems.insert("table"); return
        }
        let rows = min(Int(model.numberOfRows), 2_000), columns = min(Int(model.numberOfColumns), 500)
        guard rows > 0, columns > 0 else { return }
        if model.numberOfRows > 2_000 || model.numberOfColumns > 500 { problems.insert("table truncated") }
        let store = model.baseDataStore

        // Row heights and column widths: the header buckets' sizes, the defaults otherwise; a
        // hidden row or column takes no space.
        func sizes(_ buckets: [UInt64], count: Int, fallback: Double) -> [Double] {
            var out = [Double](repeating: fallback, count: count)
            for b in buckets {
                for h in document.decoded(TST_HeaderStorageBucket.self, b)?.headers ?? [] where Int(h.index) < count {
                    if h.hasSize, h.size > 0 { out[Int(h.index)] = Double(h.size) }
                    if h.hasHidingState, h.hidingState != 0 { out[Int(h.index)] = 0 }
                }
            }
            return out
        }
        let heights = sizes(store.rowHeaders.buckets.map(\.identifier), count: rows, fallback: model.defaultRowHeight > 0 ? model.defaultRowHeight : 30)
        let widths = sizes(store.hasColumnHeaders ? [store.columnHeaders.identifier] : [], count: columns, fallback: model.defaultColumnWidth > 0 ? model.defaultColumnWidth : 100)
        var ys = [0.0], xs = [0.0]
        for h in heights { ys.append(ys.last! + h) }
        for w in widths { xs.append(xs.last! + w) }

        // The data lists.
        func list(_ ref: TSP_Reference, _ has: Bool) -> [UInt32: TST_TableDataList.ListEntry] {
            guard has, let l = document.decoded(TST_TableDataList.self, ref.identifier) else { return [:] }
            return Dictionary(l.entries.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        }
        let strings = list(store.stringTable, store.hasStringTable)
        let styleList = list(store.styleTable, store.hasStyleTable)
        let formatList = list(store.formatTable, store.hasFormatTable)
        let conditionalList = list(store.conditionalstyletable, store.hasConditionalstyletable)
        var conditionalSets = [UInt32: TST_ConditionalStyleSetArchive]()
        /// The cell and text styles of the conditional rule that matched a cell (0 for none).
        func conditionalRule(_ cell: StoredCell) -> (cell: UInt64, text: UInt64)? {
            guard let key = cell.conditionalStyleID, let index = cell.appliedRule, index < 15,
                  let entry = conditionalList[key], entry.hasReference else { return nil }
            if conditionalSets[key] == nil { conditionalSets[key] = document.decoded(TST_ConditionalStyleSetArchive.self, entry.reference.identifier) }
            guard let set = conditionalSets[key] else { return nil }
            let i = Int(index)
            if i < set.rulesPrepivot.count {
                let rule = set.rulesPrepivot[i]
                return (rule.hasCellStyle ? rule.cellStyle.identifier : 0, rule.hasTextStyle ? rule.textStyle.identifier : 0)
            }
            if i < set.rules.rule.count {
                let rule = set.rules.rule[i]
                return (rule.hasCellStyle ? rule.cellStyle.identifier : 0, rule.hasTextStyle ? rule.textStyle.identifier : 0)
            }
            return nil
        }
        let richText = list(store.richTextTable, store.hasRichTextTable)

        // Cells: each tile holds rows; the row tile tree gives a tile's first row.
        var cells = [Int: [Int: StoredCell]]()
        let tileStart = Dictionary(store.rowTileTree.nodes.map { (Int($0.value), Int($0.key)) }, uniquingKeysWith: { a, _ in a })
        for t in store.tiles.tiles {
            guard let tile = document.decoded(TST_Tile.self, t.tile.identifier) else { continue }
            let first = tileStart[Int(t.tileid)] ?? 0
            for row in tile.rowInfos {
                let r = first + Int(row.tileRowIndex)
                // Version 5 keeps its buffer in `cell_storage_buffer` (offsets in words when rows
                // are wide); version 4 in the pre-BNC fields, offsets in bytes.
                let preBNC = row.storageVersion == 4
                guard r < rows, row.storageVersion == 5 || preBNC else { continue }
                let buffer = [UInt8](preBNC ? row.cellStorageBufferPreBnc : row.cellStorageBuffer)
                let offsets = [UInt8](preBNC ? row.cellOffsetsPreBnc : row.cellOffsets)
                let wide = !preBNC && (tile.shouldUseWideRows || store.tiles.shouldUseWideRows)
                for c in 0..<min(columns, offsets.count / 2) {
                    let o = Int(offsets[2 * c]) | Int(offsets[2 * c + 1]) << 8
                    guard o != 0xFFFF, let cell = StoredCell(buffer, at: wide ? o * 4 : o) else { continue }
                    cells[r, default: [:]][c] = cell
                }
            }
        }

        // Merged ranges, kept by the merge owner as range formulas (a colon tract of absolute
        // columns and rows): the origin cell spans the range; the others are not drawn.
        var span = [Int: (rows: Int, columns: Int)](), covered = Set<Int>(), mergeOf = [Int: Int]()
        // Every cell belongs to at most one merge, so the work is bounded by the table's cells,
        // however many or however large the ranges a file declares.
        var mergeBudget = rows * columns
        merges: for pair in model.mergeOwner.formulaStore.formulas.prefix(10_000) {
            for node in pair.formula.astNodeArray.astNode where node.hasAstColonTract {
                let tract = node.astColonTract
                guard let cr = tract.absoluteColumn.first, let rr = tract.absoluteRow.first else { continue }
                let c0 = Int(cr.rangeBegin), c1 = cr.hasRangeEnd ? Int(cr.rangeEnd) : c0
                let r0 = Int(rr.rangeBegin), r1 = rr.hasRangeEnd ? Int(rr.rangeEnd) : r0
                guard r0 >= 0, c0 >= 0, r0 < rows, c0 < columns, r1 >= r0, c1 >= c0, mergeOf[r0 * columns + c0] == nil else { continue }
                let nr = min(r1, rows - 1) - r0 + 1, nc = min(c1, columns - 1) - c0 + 1
                mergeBudget -= nr * nc
                guard mergeBudget >= 0 else { problems.insert("table merges over budget"); break merges }
                span[r0 * columns + c0] = (nr, nc)
                for r in r0..<(r0 + nr) {
                    for c in c0..<(c0 + nc) {
                        mergeOf[r * columns + c] = r0 * columns + c0
                        if r != r0 || c != c0 { covered.insert(r * columns + c) }
                    }
                }
            }
        }

        let headerRows = Int(model.numberOfHeaderRows), headerColumns = Int(model.numberOfHeaderColumns)
        let footerRows = Int(model.numberOfFooterRows)
        func region(_ r: Int, _ c: Int) -> (cell: TSP_Reference?, text: TSP_Reference?) {
            if r < headerRows { return (model.hasHeaderRowStyle ? model.headerRowStyle : nil, model.hasHeaderRowTextStyle ? model.headerRowTextStyle : nil) }
            if r >= rows - footerRows { return (model.hasFooterRowStyle ? model.footerRowStyle : nil, model.hasFooterRowTextStyle ? model.footerRowTextStyle : nil) }
            if c < headerColumns { return (model.hasHeaderColumnStyle ? model.headerColumnStyle : nil, model.hasHeaderColumnTextStyle ? model.headerColumnTextStyle : nil) }
            return (model.hasBodyCellStyle ? model.bodyCellStyle : nil, model.hasBodyTextStyle ? model.bodyTextStyle : nil)
        }
        let tableProps = model.hasTableStyle ? styles.chain(TST_TableStyleArchive.self, from: model.tableStyle.identifier) { $0.super }.map(\.tableProperties) : []

        let g = d.geometry
        var out = "<g transform=\"\(transform(g))\">"
        var text = ""
        var cellBudget = Self.maximumTableCells
        for r in 0..<rows where heights[r] > 0 {
            for c in 0..<columns where widths[c] > 0 && !covered.contains(r * columns + c) {
                cellBudget -= 1
                guard cellBudget >= 0 else { problems.insert("table cells over budget"); break }
                let s = span[r * columns + c] ?? (1, 1)
                let x = xs[c], y = ys[r], w = xs[c + s.columns] - x, h = ys[r + s.rows] - y
                let cell = cells[r]?[c]
                let base = region(r, c)
                var cellStyles = [TST_CellStylePropertiesArchive]()
                // A conditional rule that matched styles the cell over its own styles.
                var ruleText: UInt64?
                if let rule = cell.flatMap(conditionalRule) {
                    if rule.cell != 0 { cellStyles += styles.chain(TST_CellStyleArchive.self, from: rule.cell) { $0.super }.map(\.cellProperties) }
                    if rule.text != 0 { ruleText = rule.text }
                }
                if let id = cell?.cellStyleID, let ref = styleList[id], ref.hasReference {
                    cellStyles += styles.chain(TST_CellStyleArchive.self, from: ref.reference.identifier) { $0.super }.map(\.cellProperties)
                }
                if let ref = base.cell { cellStyles += styles.chain(TST_CellStyleArchive.self, from: ref.identifier) { $0.super }.map(\.cellProperties) }
                var fill = StyleResolver.first(cellStyles, \.hasCellFill, \.cellFill)
                if fill.map({ !$0.hasColor && !$0.hasGradient && !$0.hasImage }) ?? true,
                   r >= headerRows, r < rows - footerRows, c >= headerColumns,
                   StyleResolver.first(tableProps, \.hasBandedRows, \.bandedRows) == true, (r - headerRows) % 2 == 1 {
                    fill = StyleResolver.first(tableProps, \.hasBandedFill, \.bandedFill)
                }
                if let fill { out += paintedRect(fill, x: x, y: y, w: w, h: h) }

                guard let cell, cell.kind != .empty else { continue }
                var look = StyleResolver.ShapeLook()
                if let pad = StyleResolver.first(cellStyles, \.hasPadding, \.padding) {
                    look.padding = (Double(pad.left), Double(pad.top), Double(pad.right), Double(pad.bottom))
                }
                switch StyleResolver.first(cellStyles, \.hasVerticalAlignment, \.verticalAlignment) ?? 0 {
                case 1: look.verticalAlignment = .kFrameAlignMiddle
                case 2: look.verticalAlignment = .kFrameAlignBottom
                default: look.verticalAlignment = .kFrameAlignTop
                }
                var textStyle = base.text?.identifier
                if let id = cell.textStyleID, let ref = styleList[id], ref.hasReference { textStyle = ref.reference.identifier }
                if let ruleText { textStyle = ruleText }
                look.paragraphStyle = textStyle
                let numeric = [.number, .currency, .date, .duration].contains(cell.kind)
                look.naturalAlignment = numeric ? .tatvalue1 : .tatvalue0
                // Only text wraps in a cell; a number or date runs past the cell and is clipped.
                look.wraps = !numeric

                var markup = ""
                if cell.kind == .richText, let id = cell.richTextID, let entry = richText[id], entry.hasRichTextPayload,
                   let payload = document.decoded(TST_RichTextPayloadArchive.self, entry.richTextPayload.identifier), payload.hasStorage,
                   let storage = document.decoded(TSWP_StorageArchive.self, payload.storage.identifier) {
                    markup = textMarkup(archive: storage, width: w, height: h, look: look)
                } else {
                    let value = display(cell, strings: strings, formats: formatList)
                    guard !value.isEmpty else { continue }
                    var storage = TSWP_StorageArchive()
                    storage.text = [value]
                    markup = textMarkup(archive: storage, width: w, height: h, look: look)
                }
                if !markup.isEmpty {
                    let clip = defs.add { "<clipPath id=\"\($0)\"><rect x=\"\(SVG.n(x))\" y=\"\(SVG.n(y))\" width=\"\(SVG.n(w))\" height=\"\(SVG.n(h))\"/></clipPath>" }
                    text += "<g clip-path=\"url(#\(clip))\"><g transform=\"translate(\(SVG.n(x)) \(SVG.n(y)))\">" + markup + "</g></g>"
                }
            }
        }
        out += text
        out += tableStrokes(model, tableProps: tableProps, xs: xs, ys: ys, rows: rows, columns: columns,
                            headerRows: headerRows, headerColumns: headerColumns, footerRows: footerRows, mergeOf: mergeOf)
        body += out + "</g>"
    }

    /// The cells one table may lay out: past it the rest is left blank and reported.
    static let maximumTableCells = 20_000

    /// A cell's value as Keynote shows it, through the cell's format.
    func display(_ cell: StoredCell, strings: [UInt32: TST_TableDataList.ListEntry], formats: [UInt32: TST_TableDataList.ListEntry]) -> String {
        func format(_ flag: UInt32) -> TSK_FormatStructArchive? {
            cell.formats[flag].flatMap { formats[$0] }.flatMap { $0.hasFormat ? $0.format : nil }
        }
        switch cell.kind {
        case .text:
            return cell.stringID.flatMap { strings[$0]?.string } ?? ""
        case .number, .currency:
            guard let v = cell.number else { return "" }
            // A number shows in its number format; the currency format a cell keeps from an
            // earlier formatting is not the one in force (Keynote shows 12.5, not $12.50).
            let f = (cell.kind == .currency ? format(StoredCell.currencyFormat) : nil) ?? format(StoredCell.numberFormat)
            return Self.formatNumber(v, f)
        case .date:
            guard let s = cell.seconds else { return "" }
            return Self.formatDate(s, format(StoredCell.dateFormat))
        case .bool:
            let v = (cell.number ?? 0) != 0
            return v ? "TRUE" : "FALSE"
        case .duration:
            guard let v = cell.number ?? cell.double, v.isFinite, abs(v) < 1e15 else { return "" }
            let total = Int(v.rounded())
            return String(format: "%d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60)
        case .error:
            return "#ERROR"
        case .empty, .richText:
            return ""
        }
    }

    static func grouped(_ integer: String) -> String {
        var out = "", count = 0
        for ch in integer.reversed() {
            if count > 0, count % 3 == 0 { out.append(",") }
            out.append(ch); count += 1
        }
        return String(out.reversed())
    }

    static func formatNumber(_ value: Double, _ f: TSK_FormatStructArchive?) -> String {
        let type = f?.formatType ?? 256
        let auto = f.map { !$0.hasDecimalPlaces || $0.decimalPlaces == 253 } ?? true
        var v = value
        var suffix = "", prefix = ""
        switch type {
        case 258: v *= 100; suffix = "%"
        case 257:
            let code = f?.currencyCode ?? "USD"
            prefix = ["USD": "$", "EUR": "€", "GBP": "£", "JPY": "¥", "CNY": "¥", "INR": "₹", "KRW": "₩", "AUD": "$", "CAD": "$"][code] ?? code + " "
        case 259:
            let places = auto ? 2 : min(Int(f!.decimalPlaces), 20)
            return String(format: "%.\(places)E", v)
        default: break
        }
        var digits: String
        if auto {
            // Shortest form, up to ten significant digits, as Keynote's automatic places show.
            digits = String(format: "%.10g", abs(v))
            if digits.contains("e") { digits = String(format: "%.10f", abs(v)) }
            if digits.contains(".") { while digits.hasSuffix("0") { digits.removeLast() }; if digits.hasSuffix(".") { digits.removeLast() } }
        } else {
            digits = String(format: "%.\(min(Int(f!.decimalPlaces), 20))f", abs(v))
        }
        if f?.showThousandsSeparator == true || type == 257 {
            let parts = digits.split(separator: ".", omittingEmptySubsequences: false)
            digits = grouped(String(parts[0])) + (parts.count > 1 ? "." + parts[1] : "")
        }
        let negative = v < 0 && Double(digits.replacingOccurrences(of: ",", with: "")) != 0
        return (negative ? "-" : "") + prefix + digits + suffix
    }

    static func formatDate(_ seconds: Double, _ f: TSK_FormatStructArchive?) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        guard seconds.isFinite, abs(seconds) < 1e12 else { return "" }
        formatter.dateFormat = f.flatMap { $0.hasDateTimeFormat && !$0.dateTimeFormat.isEmpty ? $0.dateTimeFormat : nil } ?? "M/d/yy"
        return formatter.string(from: Date(timeIntervalSinceReferenceDate: seconds))
    }

    /// The table's grid lines: the table style's strokes for each region boundary, then the stroke
    /// sidecar's custom strokes over them.
    mutating func tableStrokes(_ model: TST_TableModelArchive, tableProps p: [TST_TableStylePropertiesArchive], xs: [Double], ys: [Double],
                               rows: Int, columns: Int, headerRows: Int, headerColumns: Int, footerRows: Int, mergeOf: [Int: Int]) -> String {
        // An edge between two cells of one merged range is not drawn.
        func inside(_ a: Int, _ b: Int) -> Bool { mergeOf[a].map { $0 == mergeOf[b] } ?? false }
        func stroke(_ has: (TST_TableStylePropertiesArchive) -> Bool, _ get: (TST_TableStylePropertiesArchive) -> TSD_StrokeArchive) -> TSD_StrokeArchive? {
            StyleResolver.first(p, has, get)
        }
        func flag(_ has: (TST_TableStylePropertiesArchive) -> Bool, _ get: (TST_TableStylePropertiesArchive) -> Bool) -> Bool {
            StyleResolver.first(p, has, get) ?? true
        }
        var out = ""
        var lineBudget = 2 * Self.maximumTableCells, overBudget = false
        func line(_ s: TSD_StrokeArchive?, _ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) {
            guard let s, visible(s) else { return }
            lineBudget -= 1
            guard lineBudget >= 0 else { overBudget = true; return }
            out += stroked(s, d: "M\(SVG.n(x1)) \(SVG.n(y1))L\(SVG.n(x2)) \(SVG.n(y2))")
        }
        let hVisible = flag(\.hasHStrokesVisible, \.hStrokesVisible), vVisible = flag(\.hasVStrokesVisible, \.vStrokesVisible)
        let border = flag(\.hasTableBorderVisible, \.tableBorderVisible)
        let bodyH = stroke(\.hasTableBodyHorizontalStroke, \.tableBodyHorizontalStroke), bodyV = stroke(\.hasTableBodyVerticalStroke, \.tableBodyVerticalStroke)
        let headerH = stroke(\.hasHeaderRowHorizontalStroke, \.headerRowHorizontalStroke), headerV = stroke(\.hasHeaderRowVerticalStroke, \.headerRowVerticalStroke)
        let columnH = stroke(\.hasHeaderColumnHorizontalStroke, \.headerColumnHorizontalStroke), columnV = stroke(\.hasHeaderColumnVerticalStroke, \.headerColumnVerticalStroke)
        let footerH = stroke(\.hasFooterRowHorizontalStroke, \.footerRowHorizontalStroke), footerV = stroke(\.hasFooterRowVerticalStroke, \.footerRowVerticalStroke)

        // Horizontal lines inside each band of rows, segment by column, skipping merged interiors.
        for r in 1..<rows {
            if r == headerRows || r == rows - footerRows { continue }
            let s = r < headerRows ? headerH : r >= rows - footerRows ? footerH : nil
            for c in 0..<columns where !inside(r * columns + c, (r - 1) * columns + c) {
                let body = c < headerColumns ? columnH : bodyH
                if hVisible || r < headerRows { line(s ?? body, xs[c], ys[r], xs[c + 1], ys[r]) }
            }
        }
        for c in 1..<columns {
            if c == headerColumns { continue }
            for r in 0..<rows where !inside(r * columns + c, r * columns + c - 1) {
                let s = r < headerRows ? headerV : r >= rows - footerRows ? footerV : c < headerColumns ? columnV : bodyV
                if vVisible || r < headerRows { line(s, xs[c], ys[r], xs[c], ys[r + 1]) }
            }
        }
        // Separators between the header and footer regions and the body.
        if headerRows > 0, headerRows < rows, flag(\.hasHrSeparatorVisible, \.hrSeparatorVisible) {
            line(stroke(\.hasHeaderRowSeparatorStroke, \.headerRowSeparatorStroke), 0, ys[headerRows], xs[columns], ys[headerRows])
        }
        if headerColumns > 0, headerColumns < columns {
            // In the header rows the header row's own vertical stroke divides the columns.
            if headerRows > 0 { line(headerV, xs[headerColumns], 0, xs[headerColumns], ys[min(headerRows, rows)]) }
            if flag(\.hasHcSeparatorVisible, \.hcSeparatorVisible) {
                line(stroke(\.hasHeaderColumnSeparatorStroke, \.headerColumnSeparatorStroke), xs[headerColumns], ys[min(headerRows, rows)], xs[headerColumns], ys[rows])
            }
        }
        if footerRows > 0, footerRows < rows, flag(\.hasFooterSeparatorVisible, \.footerSeparatorVisible) {
            line(stroke(\.hasFooterRowSeparatorStroke, \.footerRowSeparatorStroke), 0, ys[rows - footerRows], xs[columns], ys[rows - footerRows])
        }
        if border {
            let h = stroke(\.hasTableBodyHorizontalBorderStroke, \.tableBodyHorizontalBorderStroke)
            let v = stroke(\.hasTableBodyVerticalBorderStroke, \.tableBodyVerticalBorderStroke)
            line(headerRows > 0 ? stroke(\.hasHeaderRowBorderStroke, \.headerRowBorderStroke) ?? h : h, 0, 0, xs[columns], 0)
            line(footerRows > 0 ? stroke(\.hasFooterRowBorderStroke, \.footerRowBorderStroke) ?? h : h, 0, ys[rows], xs[columns], ys[rows])
            line(headerColumns > 0 ? stroke(\.hasHeaderColumnBorderStroke, \.headerColumnBorderStroke) ?? v : v, 0, 0, 0, ys[rows])
            line(v, xs[columns], 0, xs[columns], ys[rows])
        }

        // The sidecar: strokes set on particular cells, as runs along a row or column edge.
        if model.hasStrokeSidecar, let sidecar = document.decoded(TST_StrokeSidecarArchive.self, model.strokeSidecar.identifier) {
            func runs(_ layers: [TSP_Reference], horizontal: Bool, after: Bool) {
                for ref in layers.prefix(2_000) {
                    guard let layer = document.decoded(TST_StrokeLayerArchive.self, ref.identifier) else { continue }
                    let index = Int(layer.rowColumnIndex) + (after ? 1 : 0)
                    for run in layer.strokeRuns.prefix(2_000) {
                        let a = max(0, Int(run.origin)), b = a + Int(run.length)
                        if horizontal {
                            guard index < ys.count, a < xs.count else { continue }
                            line(run.stroke, xs[a], ys[index], xs[min(b, columns)], ys[index])
                        } else {
                            guard index < xs.count, a < ys.count else { continue }
                            line(run.stroke, xs[index], ys[a], xs[index], ys[min(b, rows)])
                        }
                    }
                }
            }
            runs(sidecar.topRowStrokeLayers, horizontal: true, after: false)
            runs(sidecar.bottomRowStrokeLayers, horizontal: true, after: true)
            runs(sidecar.leftColumnStrokeLayers, horizontal: false, after: false)
            runs(sidecar.rightColumnStrokeLayers, horizontal: false, after: true)
        }
        if overBudget { problems.insert("table strokes over budget") }
        return out
    }
}
