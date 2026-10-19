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

        // Styles: each series' theme style with the series' own variation over it (what the
        // Format sidebar set for that series), then the chart's paragraph styles for labels.
        let seriesStyles = chart.seriesThemeStyles.map { document.decoded(TSCH_ChartSeriesStyleArchive.self, $0.identifier) }
        var privateStyles = [Int: TSCH_Generated_ChartSeriesStyleArchive]()
        for entry in chart.seriesPrivateStyles.entries.prefix(Self.maximumChartMarks) where entry.hasReference {
            if let s = document.decoded(TSCH_ChartSeriesStyleArchive.self, entry.reference.identifier), s.hasTSCH_Generated_ChartSeriesStyleArchive_current {
                privateStyles[Int(entry.index)] = s.TSCH_Generated_ChartSeriesStyleArchive_current
            }
        }
        // Each series' settings that are not style (whether its value labels show).
        var nonStyles = [Int: TSCH_Generated_ChartSeriesNonStyleArchive]()
        for entry in chart.seriesNonStyles.entries.prefix(Self.maximumChartMarks) where entry.hasReference {
            if let s = document.decoded(TSCH_ChartSeriesNonStyleArchive.self, entry.reference.identifier), s.hasTSCH_Generated_ChartSeriesNonStyleArchive_current {
                nonStyles[Int(entry.index)] = s.TSCH_Generated_ChartSeriesNonStyleArchive_current
            }
        }
        func nonStyle(_ i: Int) -> TSCH_Generated_ChartSeriesNonStyleArchive? { nonStyles[i] }
        var resolved = [Int: TSCH_Generated_ChartSeriesStyleArchive?]()
        func series(_ i: Int) -> TSCH_Generated_ChartSeriesStyleArchive? {
            if let known = resolved[i] { return known }
            var theme: TSCH_Generated_ChartSeriesStyleArchive?
            if !seriesStyles.isEmpty, let s = seriesStyles[i % seriesStyles.count], s.hasTSCH_Generated_ChartSeriesStyleArchive_current {
                theme = s.TSCH_Generated_ChartSeriesStyleArchive_current
            }
            var out = theme
            if let own = privateStyles[i] {
                var merged = theme ?? TSCH_Generated_ChartSeriesStyleArchive()
                if let bytes = try? own.serializedData(partial: true) { try? merged.merge(serializedBytes: bytes, partial: true) }
                Self.overlayFills(own, on: &merged)
                out = merged
            }
            resolved[i] = out
            return out
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

        let valueAxisNonStyle = chart.valueAxisNonstyles.first.flatMap { document.decoded(TSCH_ChartAxisNonStyleArchive.self, $0.identifier) }
            .flatMap { $0.hasTSCH_Generated_ChartAxisNonStyleArchive_current ? $0.TSCH_Generated_ChartAxisNonStyleArchive_current : nil }
        var valueAxisSettings = AxisSettings()
        if let a = valueAxisNonStyle {
            if a.hasTschchartaxisdefaultusermin, a.tschchartaxisdefaultusermin.hasNumberArchive { valueAxisSettings.userMin = a.tschchartaxisdefaultusermin.numberArchive }
            if a.hasTschchartaxisdefaultusermax, a.tschchartaxisdefaultusermax.hasNumberArchive { valueAxisSettings.userMax = a.tschchartaxisdefaultusermax.numberArchive }
            if a.hasTschchartaxisvaluenumberofmajorgridlines, a.tschchartaxisvaluenumberofmajorgridlines > 0 {
                valueAxisSettings.intervals = Int(a.tschchartaxisvaluenumberofmajorgridlines)
            }
            // A decimal format with fixed places (253 is "automatic").
            let format = a.tschchartaxisdefaultnumberformat
            if a.hasTschchartaxisdefaultnumberformat, format.formatType == 256, format.decimalPlaces < 253 {
                valueAxisSettings.decimals = Int(format.decimalPlaces)
            }
        }

        var out = "<g transform=\"\(transform(g))\">"
        let type = chart.chartType
        switch type {
        case .pieChartType2D, .pieChartType3D, .donutChartType2D, .donutChartType3D:
            if type == .pieChartType3D || type == .donutChartType3D { problems.insert("3d chart (drawn flat)") }
            let info = document.decoded(TSCH_ChartNonStyleArchive.self, chart.chartNonStyle.identifier)
                .flatMap { $0.hasTSCH_Generated_ChartNonStyleArchive_current ? $0.TSCH_Generated_ChartNonStyleArchive_current : nil }
            let donut = type == .donutChartType2D || type == .donutChartType3D
            var layout = PieLayout()
            layout.startAngle = Double(info?.tschchartinfodefaultpiestartangle ?? 0)
            if let info, info.hasTschchartinfodefaultinnerradius, info.tschchartinfodefaultinnerradius > 0, info.tschchartinfodefaultinnerradius < 1 {
                layout.innerFraction = Double(info.tschchartinfodefaultinnerradius)
            }
            if donut, let info, info.tschchartinfodefaultshowtitle, info.tschchartinfodefaultdonutplacetitleatcenter, !info.tschchartinfodefaulttitle.isEmpty {
                let index = chartStyle?.tschchartinfodefaulttitleparagraphstyleindex ?? -1
                if index >= 0, Int(index) < chart.paragraphStyles.count {
                    layout.title = (info.tschchartinfodefaulttitle, chart.paragraphStyles[Int(index)].identifier)
                }
            }
            // Series labels (the wedges' names) sit at the label distance: past the wedge they move
            // out to a column on their side with a callout line back to the wedge.
            layout.name = { i in
                guard let n = nonStyle(i), n.tschchartseriespieshowserieslabels, i < names.count, !names[i].isEmpty else { return nil }
                return names[i]
            }
            layout.labelDistance = { i in Double(nonStyle(i)?.tschchartseriespielabelexplosion ?? 0) / 100 }
            // A donut has label styles of its own, inside and outside the ring.
            layout.outsideLabel = paragraph(series(0).map { donut ? $0.tschchartseriesdonutoutsidelabelparagraphstyleindex : $0.tschchartseriespieoutsidelabelparagraphstyleindex })
            layout.callout = { i in
                guard (info?.tschchartinfopiecalloutlinetype ?? 0) != 0, let s = series(i) else { return nil }
                return s.hasTschchartseriesdefaultcalloutlinestrokestyle ? s.tschchartseriesdefaultcalloutlinestrokestyle : nil
            }
            out += pie(values: values.map { $0.first ?? 0 }, w: w, h: h, donut: donut,
                       fill: { series($0)?.tschchartseriespiefill }, label: paragraph(series(0).map { donut ? $0.tschchartseriesdonutlabelparagraphstyleindex : $0.tschchartseriespielabelparagraphstyleindex }),
                       showsValue: { nonStyle($0).map { !$0.hasTschchartseriespieshowvaluelabels || $0.tschchartseriespieshowvaluelabels } ?? true },
                       layout: layout)
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
                             categoryLabel: paragraph(categoryAxis.map { $0.hasTschchartaxiscategorylabelparagraphstyleindex ? $0.tschchartaxiscategorylabelparagraphstyleindex : $0.tschchartaxisdefaultlabelparagraphstyleindex }),
                             settings: valueAxisSettings)
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
    /// A fill is one paint: a series variation's fill replaces its theme style's rather than
    /// merging into it.
    static func overlayFills(_ own: TSCH_Generated_ChartSeriesStyleArchive, on merged: inout TSCH_Generated_ChartSeriesStyleArchive) {
        if own.hasTschchartseriesareafill { merged.tschchartseriesareafill = own.tschchartseriesareafill }
        if own.hasTschchartseriesareasymbolfill { merged.tschchartseriesareasymbolfill = own.tschchartseriesareasymbolfill }
        if own.hasTschchartseriesbarfill { merged.tschchartseriesbarfill = own.tschchartseriesbarfill }
        if own.hasTschchartseriesbubblesymbolfill { merged.tschchartseriesbubblesymbolfill = own.tschchartseriesbubblesymbolfill }
        if own.hasTschchartseriescolumnfill { merged.tschchartseriescolumnfill = own.tschchartseriescolumnfill }
        if own.hasTschchartseriesdefaultfill { merged.tschchartseriesdefaultfill = own.tschchartseriesdefaultfill }
        if own.hasTschchartserieslinesymbolfill { merged.tschchartserieslinesymbolfill = own.tschchartserieslinesymbolfill }
        if own.hasTschchartseriesmixedareafill { merged.tschchartseriesmixedareafill = own.tschchartseriesmixedareafill }
        if own.hasTschchartseriesmixedareasymbolfill { merged.tschchartseriesmixedareasymbolfill = own.tschchartseriesmixedareasymbolfill }
        if own.hasTschchartseriesmixedcolumnfill { merged.tschchartseriesmixedcolumnfill = own.tschchartseriesmixedcolumnfill }
        if own.hasTschchartseriesmixedlinesymbolfill { merged.tschchartseriesmixedlinesymbolfill = own.tschchartseriesmixedlinesymbolfill }
        if own.hasTschchartseriespiefill { merged.tschchartseriespiefill = own.tschchartseriespiefill }
        if own.hasTschchartseriesradarareafill { merged.tschchartseriesradarareafill = own.tschchartseriesradarareafill }
        if own.hasTschchartseriesradarareasymbolfill { merged.tschchartseriesradarareasymbolfill = own.tschchartseriesradarareasymbolfill }
        if own.hasTschchartseriesscattersymbolfill { merged.tschchartseriesscattersymbolfill = own.tschchartseriesscattersymbolfill }
    }

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

    /// What a value axis's non-style decides: a range the user set, how many intervals the
    /// gridlines make, and the labels' decimal places.
    struct AxisSettings {
        var userMin: Double?, userMax: Double?
        var intervals = 4
        var decimals: Int?
    }

    /// A value axis's range. Data that includes zero, or spreads over more than a sixth of its
    /// largest value, runs from zero to a round maximum (`scale`). Data bunched far from zero
    /// starts below its minimum by half its spread, rounded down at the spread's leading digit,
    /// as Keynote's automatic axis does (24.46…24.72 runs 24.3…24.8). A user range wins.
    static func axisRange(dataMin: Double, dataMax: Double, settings: AxisSettings) -> (min: Double, max: Double, step: Double) {
        let intervals = Double(min(max(settings.intervals, 1), 100))
        var range: (min: Double, max: Double)
        if dataMin > 0, dataMax > 0, (dataMax - dataMin) / dataMax < 1.0 / 6 {
            let start = dataMin - (dataMax - dataMin) / 2
            let magnitude = pow(10, floor(log10(max(dataMax - start, 1e-300))))
            range = (floor(start / magnitude) * magnitude, ceil(dataMax / magnitude * (1 - 1e-12)) * magnitude)
        } else if dataMax < 0, dataMin < 0, (dataMax - dataMin) / -dataMin < 1.0 / 6 {
            let mirrored = axisRange(dataMin: -dataMax, dataMax: -dataMin, settings: AxisSettings(intervals: settings.intervals))
            range = (-mirrored.max, -mirrored.min)
        } else {
            let s = scale(min(0, dataMin), max(0, dataMax))
            range = (s.min, s.max)
        }
        if let lo = settings.userMin, lo.isFinite { range.min = lo }
        if let hi = settings.userMax, hi.isFinite { range.max = hi }
        guard range.max > range.min, (range.max - range.min).isFinite else { return (0, 1, 1 / intervals) }
        return (range.min, range.max, (range.max - range.min) / intervals)
    }

    static func label(_ v: Double, decimals: Int?) -> String {
        guard let decimals, (0...10).contains(decimals) else { return label(v) }
        let s = String(format: "%.\(decimals)f", v)
        return s.hasPrefix("-") && Double(s) == 0 ? String(s.dropFirst()) : s
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
                            valueLabel: CharLook, categoryLabel: CharLook, settings: AxisSettings = AxisSettings()) -> String {
        let n = values.count, m = values.map(\.count).max() ?? 0
        func v(_ s: Int, _ c: Int) -> Double { c < values[s].count && values[s][c].isFinite ? values[s][c] : 0 }
        var low = Double.infinity, high = -Double.infinity
        for c in 0..<m {
            if stacked {
                var pos = 0.0, neg = 0.0
                for s in 0..<n { let x = v(s, c); if x >= 0 { pos += x } else { neg += x } }
                high = max(high, pos); low = min(low, neg == 0 ? pos : neg)
            } else {
                for s in 0..<n { high = max(high, v(s, c)); low = min(low, v(s, c)) }
            }
        }
        if !low.isFinite || !high.isFinite { low = 0; high = 0 }
        let axis = Self.axisRange(dataMin: low, dataMax: high, settings: settings)
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
            let text = Self.label(value, decimals: settings.decimals)
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
        // Lines and areas meet the axis at zero, or at its edge when zero is off it.
        let zero = position(min(max(0, axis.min), axis.max))
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
                    // A bar shows only the part of it on the axis (one that starts at zero below
                    // an axis beginning at 24.3 grows from the axis's edge).
                    func clamped(_ v: Double) -> Double { min(max(v, axis.min), axis.max) }
                    let a = position(clamped(from)), b = position(clamped(to))
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
    /// What a pie or donut takes from the chart beyond its data.
    struct PieLayout {
        /// Where the first wedge starts, in degrees counter-clockwise from twelve o'clock; the
        /// wedges follow clockwise.
        var startAngle = 0.0
        /// A donut's hole as a fraction of its radius.
        var innerFraction = 0.5
        /// The chart's title and its paragraph style, drawn in a donut's hole.
        var title: (text: String, style: UInt64)?
        var name: (Int) -> String? = { _ in nil }
        /// A label's distance past the wedge, as a fraction of the ring's width.
        var labelDistance: (Int) -> Double = { _ in 0 }
        var outsideLabel = CharLook()
        var callout: (Int) -> TSD_StrokeArchive? = { _ in nil }
    }

    mutating func pie(values: [Double], w: Double, h: Double, donut: Bool, fill: (Int) -> TSD_FillArchive?, label: CharLook,
                      showsValue: (Int) -> Bool = { _ in true }, layout: PieLayout = PieLayout()) -> String {
        let parts = values.map { $0.isFinite ? max(0, $0) : 0 }
        let total = parts.reduce(0, +)
        guard total > 0 else { return "" }
        let frameRadius = min(w, h) / 2, cx = w / 2, cy = h / 2
        // Names outside the wedges take room from the pie: fitted to Keynote's export of a donut
        // whose labels sit 53% of the ring's width out (the ring shrinks by a tenth).
        let outside = parts.indices.contains { parts[$0] > 0 && layout.name($0) != nil && layout.labelDistance($0) > 0 }
        let r = outside ? frameRadius / (1 + 0.2 * (layout.labelDistance(parts.indices.first { layout.name($0) != nil } ?? 0))) : frameRadius
        let inner = donut ? r * layout.innerFraction : 0
        var out = "", angle = -Double.pi / 2 - layout.startAngle * .pi / 180
        var labels = ""
        for (i, part) in parts.enumerated() where part > 0 {
            let sweep = part / total * 2 * .pi
            let end = angle + sweep
            // A wedge's picture fills the wedge's own bounds, so its path is drawn from there.
            var ox = 0.0, oy = 0.0, bw = w, bh = h
            let f = fill(i)
            if let f, f.hasImage, sweep < 2 * .pi - 1e-9 {
                var xs = [cx + cos(angle) * r, cx + cos(end) * r], ys = [cy + sin(angle) * r, cy + sin(end) * r]
                if donut {
                    xs += [cx + cos(angle) * inner, cx + cos(end) * inner]; ys += [cy + sin(angle) * inner, cy + sin(end) * inner]
                } else {
                    xs.append(cx); ys.append(cy)
                }
                var k = (angle / (.pi / 2)).rounded(.up)
                while k * .pi / 2 < end { xs.append(cx + cos(k * .pi / 2) * r); ys.append(cy + sin(k * .pi / 2) * r); k += 1 }
                if let x0 = xs.min(), let x1 = xs.max(), let y0 = ys.min(), let y1 = ys.max(), x1 - x0 > 0.5, y1 - y0 > 0.5 {
                    ox = x0; oy = y0; bw = x1 - x0; bh = y1 - y0
                }
            }
            func p(_ a: Double, _ radius: Double) -> String { "\(SVG.n(cx - ox + cos(a) * radius)) \(SVG.n(cy - oy + sin(a) * radius))" }
            let large = sweep > .pi ? 1 : 0
            var d: String
            if sweep >= 2 * .pi - 1e-9 {
                d = "M\(p(angle, r))A\(SVG.n(r)) \(SVG.n(r)) 0 1 1 \(p(angle + .pi, r))A\(SVG.n(r)) \(SVG.n(r)) 0 1 1 \(p(angle, r))Z"
                if donut { d += "M\(p(angle, inner))A\(SVG.n(inner)) \(SVG.n(inner)) 0 1 0 \(p(angle + .pi, inner))A\(SVG.n(inner)) \(SVG.n(inner)) 0 1 0 \(p(angle, inner))Z" }
            } else if donut {
                d = "M\(p(angle, r))A\(SVG.n(r)) \(SVG.n(r)) 0 \(large) 1 \(p(end, r))L\(p(end, inner))A\(SVG.n(inner)) \(SVG.n(inner)) 0 \(large) 0 \(p(angle, inner))Z"
            } else {
                d = "M\(SVG.n(cx - ox)) \(SVG.n(cy - oy))L\(p(angle, r))A\(SVG.n(r)) \(SVG.n(r)) 0 \(large) 1 \(p(end, r))Z"
            }
            if let f {
                let painted = paintedPath(f, d: d, w: bw, h: bh)
                out += ox == 0 && oy == 0 ? painted : "<g transform=\"translate(\(SVG.n(ox)) \(SVG.n(oy)))\">" + painted + "</g>"
            }
            let mid = angle + sweep / 2, at = donut ? (r + inner) / 2 : r * 0.66
            let text = "\(Int((part / total * 100).rounded()))%"
            if showsValue(i) {
                labels += textElement([Span(text: text, look: label, width: 0)], x: cx + cos(mid) * at,
                                      baseline: cy + sin(mid) * at + effectiveSize(label) * 0.35, anchor: "middle", justifyWidth: nil)
            }
            if let name = layout.name(i) {
                let distance = r + layout.labelDistance(i) * (r - inner)
                let ax = cx + cos(mid) * distance, ay = cy + sin(mid) * distance
                if distance <= r {
                    labels += textElement([Span(text: name, look: label, width: 0)], x: ax, baseline: ay + effectiveSize(label) * 0.35, anchor: "middle", justifyWidth: nil)
                } else {
                    // A column each side of the frame's centre (a wedge within a few degrees of
                    // straight down still labels on the right); the callout runs level from the
                    // label's point to just short of it.
                    let right = cos(mid) > -0.1
                    let column = cx + (right ? 1 : -1) * frameRadius * 1.13
                    let gap = 12.0, lineEnd = column + (right ? -gap : gap)
                    if let stroke = layout.callout(i), (right ? lineEnd > ax : lineEnd < ax) {
                        labels += stroked(stroke, d: "M\(SVG.n(ax)) \(SVG.n(ay))L\(SVG.n(lineEnd)) \(SVG.n(ay))")
                    }
                    labels += textElement([Span(text: name, look: layout.outsideLabel, width: 0)], x: column,
                                          baseline: ay + effectiveSize(layout.outsideLabel) * 0.35, anchor: right ? nil : "end", justifyWidth: nil)
                }
            }
            angle = end
        }
        if let title = layout.title, inner > 0 {
            var storage = TSWP_StorageArchive()
            storage.text = [title.text]
            var look = StyleResolver.ShapeLook()
            look.paragraphStyle = title.style
            look.verticalAlignment = .kFrameAlignMiddle
            look.naturalAlignment = .tatvalue2
            let side = inner * 2
            labels += "<g transform=\"translate(\(SVG.n(cx - side / 2)) \(SVG.n(cy - side / 2)))\">"
                + textMarkup(archive: storage, width: side, height: side, look: look) + "</g>"
        }
        return out + labels
    }
}
