import Foundation
import IWASchema
import KeynoteGraph

// R3: a chart drawn from its data grid and styles. The drawable's frame is the plot area (axis
// labels sit outside it, as Keynote draws them); series take their theme styles' fills; the value
// axis runs from zero to a round maximum in four steps.

extension Canvas {
    mutating func drawChart(_ drawable: TSCH_ChartDrawableArchive) {
        let d = drawable.super
        guard d.hasGeometry, drawable.hasTSCH_ChartArchive_unity else { problems.insert("chart"); return }
        let chart = drawable.TSCH_ChartArchive_unity
        let g = d.geometry
        let w = Double(g.size.width), h = Double(g.size.height)
        guard w > 0, h > 0 else { return }

        // Series are the grid's rows unless the chart reads its columns as series.
        let grid = chart.grid
        let byColumn = chart.seriesDirection == .byColumn
        // Values far past any chart's range would overflow the axis arithmetic; they draw as zero.
        let rows = grid.gridRow.prefix(256).map { Array($0.value.prefix(1_024).map { v -> Double in
            let x = Double(v.numericValue); return x.isFinite && abs(x) < 1e100 ? x : 0 } ) }
        var names = grid.rowName.prefix(256).map { $0 }, categories = grid.columnName.prefix(1_024).map { $0 }
        var values = rows
        if byColumn {
            let columns = rows.map(\.count).max() ?? 0
            values = (0..<columns).map { c in rows.map { c < $0.count ? $0[c] : 0 } }
            swap(&names, &categories)
        }
        let seriesCount = values.count, categoryCount = values.map(\.count).max() ?? 0
        guard seriesCount > 0, categoryCount > 0 else { return }
        // Every mark is an element: past the budget the chart keeps its first categories.
        if seriesCount * categoryCount > Self.maximumChartMarks {
            let keep = max(1, Self.maximumChartMarks / seriesCount)
            values = values.map { Array($0.prefix(keep)) }
            categories = Array(categories.prefix(keep))
            problems.insert("chart data truncated")
        }

        // Styles: each series' theme style, then the chart's paragraph styles for labels.
        let seriesStyles = chart.seriesThemeStyles.map { document.decoded(TSCH_ChartSeriesStyleArchive.self, $0.identifier) }
        func series(_ i: Int) -> TSCH_Generated_ChartSeriesStyleArchive? {
            guard !seriesStyles.isEmpty, let s = seriesStyles[i % seriesStyles.count], s.hasTSCH_Generated_ChartSeriesStyleArchive_current else { return nil }
            return s.TSCH_Generated_ChartSeriesStyleArchive_current
        }
        func paragraph(_ index: Int32?) -> CharLook {
            guard let index, index >= 0, Int(index) < chart.paragraphStyles.count else { return CharLook(size: 24) }
            return styles.paraLook(chart.paragraphStyles[Int(index)].identifier).char
        }
        let valueAxis = chart.valueAxisStyles.first.flatMap { document.decoded(TSCH_ChartAxisStyleArchive.self, $0.identifier) }
            .flatMap { $0.hasTSCH_Generated_ChartAxisStyleArchive_current ? $0.TSCH_Generated_ChartAxisStyleArchive_current : nil }
        let categoryAxis = chart.categoryAxisStyles.first.flatMap { document.decoded(TSCH_ChartAxisStyleArchive.self, $0.identifier) }
            .flatMap { $0.hasTSCH_Generated_ChartAxisStyleArchive_current ? $0.TSCH_Generated_ChartAxisStyleArchive_current : nil }
        let chartStyle = document.decoded(TSCH_ChartStyleArchive.self, chart.chartStyle.identifier)
            .flatMap { $0.hasTSCH_Generated_ChartStyleArchive_current ? $0.TSCH_Generated_ChartStyleArchive_current : nil }

        var out = "<g transform=\"\(transform(g))\">"
        let type = chart.chartType
        switch type {
        case .pieChartType2D, .pieChartType3D, .donutChartType2D, .donutChartType3D:
            if type == .pieChartType3D || type == .donutChartType3D { problems.insert("3d chart (drawn flat)") }
            out += pie(values: values.map { $0.first ?? 0 }, w: w, h: h, donut: type == .donutChartType2D || type == .donutChartType3D,
                       fill: { series($0)?.tschchartseriespiefill }, label: paragraph(series(0).map { $0.tschchartseriespielabelparagraphstyleindex }))
        case .columnChartType2D, .barChartType2D, .stackedColumnChartType2D, .stackedBarChartType2D,
             .columnChartType3D, .barChartType3D, .stackedColumnChartType3D, .stackedBarChartType3D,
             .lineChartType2D, .lineChartType3D, .areaChartType2D, .areaChartType3D, .stackedAreaChartType2D, .stackedAreaChartType3D,
             .mixedChartType2D, .twoAxisChartType2D:
            if [.columnChartType3D, .barChartType3D, .stackedColumnChartType3D, .stackedBarChartType3D, .lineChartType3D, .areaChartType3D, .stackedAreaChartType3D].contains(type) {
                problems.insert("3d chart (drawn flat)")
            }
            let horizontal = [.barChartType2D, .stackedBarChartType2D, .barChartType3D, .stackedBarChartType3D].contains(type)
            let stacked = [.stackedColumnChartType2D, .stackedBarChartType2D, .stackedAreaChartType2D, .stackedColumnChartType3D,
                           .stackedBarChartType3D, .stackedAreaChartType3D].contains(type)
            let kind: AxisKind = [.lineChartType2D, .lineChartType3D].contains(type) ? .line
                : [.areaChartType2D, .areaChartType3D, .stackedAreaChartType2D, .stackedAreaChartType3D].contains(type) ? .area : .bars
            if type == .mixedChartType2D || type == .twoAxisChartType2D { problems.insert("mixed chart (drawn as columns)") }
            out += axisChart(values: values, categories: categories, w: w, h: h, horizontal: horizontal, stacked: stacked, kind: kind,
                             series: series, valueAxis: valueAxis, categoryAxis: categoryAxis,
                             interBar: Double(chartStyle?.tschchartinfodefaultinterbargap ?? 10) / 100,
                             interSet: Double(chartStyle?.tschchartinfodefaultintersetgap ?? 40) / 100,
                             valueLabel: paragraph(valueAxis.map { $0.hasTschchartaxisvaluelabelparagraphstyleindex ? $0.tschchartaxisvaluelabelparagraphstyleindex : $0.tschchartaxisdefaultlabelparagraphstyleindex }),
                             categoryLabel: paragraph(categoryAxis.map { $0.hasTschchartaxiscategorylabelparagraphstyleindex ? $0.tschchartaxiscategorylabelparagraphstyleindex : $0.tschchartaxisdefaultlabelparagraphstyleindex }))
        case .scatterChartType2D:
            // Shared X: the first series holds the X values, each later one a series' Y values;
            // separate X: the series come in pairs, X then Y.
            out += scatter(values: values, sharedX: chart.scatterFormat != .separateX, w: w, h: h, series: series, valueAxis: valueAxis,
                           label: paragraph(valueAxis.map { $0.hasTschchartaxisvaluelabelparagraphstyleindex ? $0.tschchartaxisvaluelabelparagraphstyleindex : $0.tschchartaxisdefaultlabelparagraphstyleindex }))
        default:
            problems.insert("chart type \(type.rawValue)")
        }
        body += out + "</g>"
    }

    enum AxisKind { case bars, line, area }

    /// Bars, points or wedges one chart may draw.
    static let maximumChartMarks = 10_000

    /// The value axis: zero to the data's extreme rounded up at its leading digit (9 stays 9,
    /// 24 becomes 30), in four steps, as Keynote's automatic scale draws it.
    static func scale(_ low: Double, _ high: Double) -> (min: Double, max: Double, step: Double) {
        func round(_ x: Double) -> Double {
            guard x > 0, x.isFinite else { return 0 }
            let magnitude = pow(10, floor(log10(x)))
            return ceil(x / magnitude * (1 - 1e-12)) * magnitude
        }
        let hi = round(max(0, high)), lo = -round(-min(0, low))
        guard hi - lo > 0, (hi - lo).isFinite else { return (0, 1, 0.25) }
        return (lo, hi, (hi - lo) / 4)
    }

    static func label(_ v: Double) -> String {
        var s = String(format: "%.6f", v)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s == "-0" ? "0" : s
    }

    mutating func axisChart(values: [[Double]], categories: [String], w: Double, h: Double, horizontal: Bool, stacked: Bool, kind: AxisKind,
                            series: (Int) -> TSCH_Generated_ChartSeriesStyleArchive?, valueAxis: TSCH_Generated_ChartAxisStyleArchive?,
                            categoryAxis: TSCH_Generated_ChartAxisStyleArchive?, interBar: Double, interSet: Double,
                            valueLabel: CharLook, categoryLabel: CharLook) -> String {
        let n = values.count, m = values.map(\.count).max() ?? 0
        func v(_ s: Int, _ c: Int) -> Double { c < values[s].count && values[s][c].isFinite ? values[s][c] : 0 }
        var low = 0.0, high = 0.0
        for c in 0..<m {
            if stacked {
                var pos = 0.0, neg = 0.0
                for s in 0..<n { let x = v(s, c); if x >= 0 { pos += x } else { neg += x } }
                high = max(high, pos); low = min(low, neg)
            } else {
                for s in 0..<n { high = max(high, v(s, c)); low = min(low, v(s, c)) }
            }
        }
        let axis = Self.scale(low, high)
        let valueLength = horizontal ? w : h
        func position(_ x: Double) -> Double { (x - axis.min) / (axis.max - axis.min) * valueLength }
        var out = ""

        // Gridlines and value labels.
        let showGrid = valueAxis.map { $0.hasTschchartaxisvalueshowmajorgridlines ? $0.tschchartaxisvalueshowmajorgridlines : true } ?? true
        let gridStroke = valueAxis.flatMap { $0.hasTschchartaxisvaluemajorgridlinestroke ? $0.tschchartaxisvaluemajorgridlinestroke : nil }
        let ratio = ((axis.max - axis.min) / axis.step).rounded()
        let steps = ratio.isFinite ? Int(min(max(ratio, 0), 100)) : 4
        for i in 0...max(0, min(steps, 100)) {
            let value = axis.min + Double(i) * axis.step
            let p = position(value)
            if showGrid, let gridStroke, visible(gridStroke), value != 0 {
                out += stroked(gridStroke, d: horizontal ? "M\(SVG.n(p)) 0V\(SVG.n(h))" : "M0 \(SVG.n(h - p))H\(SVG.n(w))")
            }
            let text = Self.label(value)
            let size = effectiveSize(valueLabel)
            if horizontal {
                out += textElement([Span(text: text, look: valueLabel, width: 0)], x: p, baseline: h + 10 + vertical(valueLabel).ascent, anchor: "middle", justifyWidth: nil)
            } else {
                out += textElement([Span(text: text, look: valueLabel, width: 0)], x: -10, baseline: h - p + size * 0.35, anchor: "end", justifyWidth: nil)
            }
        }

        // Bars, lines or areas, category by category.
        let band = (horizontal ? h : w) / Double(max(m, 1))
        let perSet = stacked || kind != .bars ? 1 : n
        let barWidth = band / (Double(perSet) + Double(perSet - 1) * interBar + interSet)
        let zero = position(0)
        var stackPos = [Double](repeating: 0, count: m), stackNeg = [Double](repeating: 0, count: m)
        // Areas are drawn last series first, so the first is in front: unstacked ones overlap,
        // and each stacked one runs from zero to its running total, the lower bands over it.
        let order = kind == .area ? Array((0..<n).reversed()) : Array(0..<n)
        var totals = [[Double]](repeating: [Double](repeating: 0, count: m), count: n)
        for c in 0..<m {
            var sum = 0.0
            for s in 0..<n { sum += v(s, c); totals[s][c] = sum }
        }
        for s in order {
            let style = series(s)
            switch kind {
            case .bars:
                let fill = horizontal ? style?.tschchartseriesbarfill : style?.tschchartseriescolumnfill
                let stroke = horizontal ? style?.tschchartseriesbarstroke : nil
                for c in 0..<m {
                    let x = v(s, c)
                    var from = 0.0, to = x
                    if stacked {
                        if x >= 0 { from = stackPos[c]; stackPos[c] += x; to = stackPos[c] } else { from = stackNeg[c]; stackNeg[c] += x; to = stackNeg[c] }
                    }
                    let a = position(from), b = position(to)
                    let slot = stacked ? 0 : s
                    let start = Double(c) * band + (band - (Double(perSet) * barWidth + Double(perSet - 1) * interBar * barWidth)) / 2
                        + Double(slot) * barWidth * (1 + interBar)
                    let rect = horizontal
                        ? (x: min(a, b), y: start, w: abs(b - a), h: barWidth)
                        : (x: start, y: h - max(a, b), w: barWidth, h: abs(b - a))
                    guard rect.w > 0, rect.h > 0 else { continue }
                    if let fill { out += paintedRect(fill, x: rect.x, y: rect.y, w: rect.w, h: rect.h) }
                    if let stroke, visible(stroke) {
                        out += stroked(stroke, d: "M\(SVG.n(rect.x)) \(SVG.n(rect.y))h\(SVG.n(rect.w))v\(SVG.n(rect.h))h\(SVG.n(-rect.w))Z")
                    }
                }
            case .line, .area:
                var points = [(Double, Double)]()
                for c in 0..<m {
                    let x = stacked ? totals[s][c] : v(s, c)
                    // A line or area runs edge to edge: its first category on one side of the plot, its last
                    // on the other.
                    let along = kind != .bars ? (m > 1 ? Double(c) / Double(m - 1) * (horizontal ? h : w) : (horizontal ? h : w) / 2) : (Double(c) + 0.5) * band
                    let p = position(x)
                    points.append(horizontal ? (p, along) : (along, h - p))
                }
                let d = points.enumerated().map { "\($0.offset == 0 ? "M" : "L")\(SVG.n($0.element.0)) \(SVG.n($0.element.1))" }.joined()
                if kind == .area, let fill = style?.tschchartseriesareafill, let first = points.first, let last = points.last {
                    let base = horizontal ? "L\(SVG.n(zero)) \(SVG.n(last.1))L\(SVG.n(zero)) \(SVG.n(first.1))Z" : "L\(SVG.n(last.0)) \(SVG.n(h - zero))L\(SVG.n(first.0)) \(SVG.n(h - zero))Z"
                    out += paintedPath(fill, d: d + base, w: w, h: h)
                }
                if kind == .line { out += stroked(style?.tschchartserieslinestroke, d: d) }
            }
        }

        // The category axis line along zero, and the category labels.
        if categoryAxis.map({ $0.hasTschchartaxiscategoryshowaxis ? $0.tschchartaxiscategoryshowaxis : true }) ?? true {
            let color = gridStroke.map { SVG.RGBA($0.color) } ?? SVG.RGBA(r: 0.6, g: 0.6, b: 0.6, a: 1)
            out += horizontal
                ? "<path d=\"M\(SVG.n(zero)) 0V\(SVG.n(h))\" fill=\"none\"" + SVG.paint("stroke", color) + " stroke-width=\"1\"/>"
                : "<path d=\"M0 \(SVG.n(h - zero))H\(SVG.n(w))\" fill=\"none\"" + SVG.paint("stroke", color) + " stroke-width=\"1\"/>"
        }
        for c in 0..<min(m, categories.count) where !categories[c].isEmpty {
            let along = kind != .bars ? (m > 1 ? Double(c) / Double(m - 1) * (horizontal ? h : w) : (horizontal ? h : w) / 2) : (Double(c) + 0.5) * band
            if horizontal {
                out += textElement([Span(text: categories[c], look: categoryLabel, width: 0)], x: -10, baseline: along + effectiveSize(categoryLabel) * 0.35, anchor: "end", justifyWidth: nil)
            } else {
                out += textElement([Span(text: categories[c], look: categoryLabel, width: 0)], x: along, baseline: h + 18 + vertical(categoryLabel).ascent, anchor: "middle", justifyWidth: nil)
            }
        }
        return out
    }

    mutating func scatter(values: [[Double]], sharedX: Bool, w: Double, h: Double, series: (Int) -> TSCH_Generated_ChartSeriesStyleArchive?,
                          valueAxis: TSCH_Generated_ChartAxisStyleArchive?, label: CharLook) -> String {
        guard values.count >= 2 else { return "" }
        let clean = values.map { $0.map { $0.isFinite ? $0 : 0 } }
        let pairs: [(x: [Double], y: [Double])] = sharedX
            ? clean.dropFirst().map { (clean[0], $0) }
            : stride(from: 0, to: clean.count - 1, by: 2).map { (clean[$0], clean[$0 + 1]) }
        let xs = pairs.flatMap(\.x), ys = pairs.map(\.y)
        let xAxis = Self.scale(xs.min() ?? 0, xs.max() ?? 0)
        let yAxis = Self.scale(ys.flatMap { $0 }.min() ?? 0, ys.flatMap { $0 }.max() ?? 0)
        func px(_ x: Double) -> Double { (x - xAxis.min) / (xAxis.max - xAxis.min) * w }
        func py(_ y: Double) -> Double { h - (y - yAxis.min) / (yAxis.max - yAxis.min) * h }
        var out = ""
        let grid = valueAxis.flatMap { $0.hasTschchartaxisvaluemajorgridlinestroke ? $0.tschchartaxisvaluemajorgridlinestroke : nil }
        for i in 0...4 {
            let y = yAxis.min + Double(i) * yAxis.step, x = xAxis.min + Double(i) * xAxis.step
            if let grid, visible(grid), y != 0 { out += stroked(grid, d: "M0 \(SVG.n(py(y)))H\(SVG.n(w))") }
            out += textElement([Span(text: Self.label(y), look: label, width: 0)], x: -10, baseline: py(y) + effectiveSize(label) * 0.35, anchor: "end", justifyWidth: nil)
            out += textElement([Span(text: Self.label(x), look: label, width: 0)], x: px(x), baseline: h + 18 + vertical(label).ascent, anchor: "middle", justifyWidth: nil)
        }
        let axisColor = grid.map { SVG.RGBA($0.color) } ?? SVG.RGBA(r: 0.6, g: 0.6, b: 0.6, a: 1)
        out += "<path d=\"M0 \(SVG.n(py(0)))H\(SVG.n(w))\" fill=\"none\"" + SVG.paint("stroke", axisColor) + " stroke-width=\"1\"/>"
        for (s, row) in ys.enumerated() {
            let style = series(s)
            let fill = style.flatMap { $0.hasTschchartseriesscattersymbolfill && ($0.tschchartseriesscattersymbolfill.hasColor || $0.tschchartseriesscattersymbolfill.hasGradient) ? $0.tschchartseriesscattersymbolfill : $0.tschchartseriesdefaultfill }
            let color = fill.map { $0.hasColor ? SVG.RGBA($0.color) : $0.gradient.stops.first.map { SVG.RGBA($0.color) } ?? SVG.RGBA(r: 0, g: 0, b: 0, a: 1) } ?? SVG.RGBA(r: 0, g: 0, b: 0, a: 1)
            let rowX = pairs[s].x
            for (c, y) in row.enumerated() where c < rowX.count {
                out += "<circle cx=\"\(SVG.n(px(rowX[c])))\" cy=\"\(SVG.n(py(y)))\" r=\"7\"" + SVG.paint("fill", color) + "/>"
            }
        }
        return out
    }

    /// Wedges clockwise from twelve o'clock, one per series, each labelled with its percentage.
    mutating func pie(values: [Double], w: Double, h: Double, donut: Bool, fill: (Int) -> TSD_FillArchive?, label: CharLook) -> String {
        let parts = values.map { $0.isFinite ? max(0, $0) : 0 }
        let total = parts.reduce(0, +)
        guard total > 0 else { return "" }
        let r = min(w, h) / 2, cx = w / 2, cy = h / 2, inner = donut ? r * 0.5 : 0
        var out = "", angle = -Double.pi / 2
        var labels = ""
        for (i, part) in parts.enumerated() where part > 0 {
            let sweep = part / total * 2 * .pi
            let end = angle + sweep
            func p(_ a: Double, _ radius: Double) -> String { "\(SVG.n(cx + cos(a) * radius)) \(SVG.n(cy + sin(a) * radius))" }
            let large = sweep > .pi ? 1 : 0
            var d: String
            if sweep >= 2 * .pi - 1e-9 {
                d = "M\(p(angle, r))A\(SVG.n(r)) \(SVG.n(r)) 0 1 1 \(p(angle + .pi, r))A\(SVG.n(r)) \(SVG.n(r)) 0 1 1 \(p(angle, r))Z"
                if donut { d += "M\(p(angle, inner))A\(SVG.n(inner)) \(SVG.n(inner)) 0 1 0 \(p(angle + .pi, inner))A\(SVG.n(inner)) \(SVG.n(inner)) 0 1 0 \(p(angle, inner))Z" }
            } else if donut {
                d = "M\(p(angle, r))A\(SVG.n(r)) \(SVG.n(r)) 0 \(large) 1 \(p(end, r))L\(p(end, inner))A\(SVG.n(inner)) \(SVG.n(inner)) 0 \(large) 0 \(p(angle, inner))Z"
            } else {
                d = "M\(SVG.n(cx)) \(SVG.n(cy))L\(p(angle, r))A\(SVG.n(r)) \(SVG.n(r)) 0 \(large) 1 \(p(end, r))Z"
            }
            if let f = fill(i) { out += paintedPath(f, d: d, w: w, h: h) }
            let mid = angle + sweep / 2, at = donut ? (r + inner) / 2 : r * 0.66
            let text = "\(Int((part / total * 100).rounded()))%"
            labels += textElement([Span(text: text, look: label, width: 0)], x: cx + cos(mid) * at,
                                  baseline: cy + sin(mid) * at + effectiveSize(label) * 0.35, anchor: "middle", justifyWidth: nil)
            angle = end
        }
        return out + labels
    }
}
