import Foundation
import IWAArchive
import IWASchema
import SwiftProtobuf

/// Phase 4: fill a Keynote-made table with text without writing a cell buffer. The table comes
/// from a parts deck (`tables-parts.key`) where Keynote put the text "r<row>c<column>" (1-based; letters, so Keynote keeps it text) in every
/// cell, so every cell is a text cell with its own entry in the table's string list. Filling the
/// table replaces those strings; the cells, their styles and the table's geometry stay as Keynote
/// made them.
extension KeynoteDocument {
    public enum TableCellsFailure: Error, Equatable, Sendable, CustomStringConvertible {
        case notATable(UInt64)
        case size(rows: Int, columns: Int, cells: (rows: Int, columns: Int))
        case missingMarker(String)

        public static func == (a: Self, b: Self) -> Bool { "\(a)" == "\(b)" }

        public var description: String {
            switch self {
            case .notATable(let id): return "object \(id) is not a table model"
            case .size(let r, let c, let cells): return "the table is \(r) × \(c); the cells given are \(cells.rows) × \(cells.columns)"
            case .missingMarker(let m): return "the table has no cell holding “\(m)”: it is not a parts table"
            }
        }
    }

    static let tableInfoType: UInt32 = 6000

    /// The table models of the tables on `slide`, in drawable order.
    public func slideTables(_ slide: UInt64) -> [UInt64] {
        slideDrawables(slide).compactMap { id -> UInt64? in
            guard store.record(for: id)?.info.messageInfos.first?.type == Self.tableInfoType,
                  let info = decoded(TST_TableInfoArchive.self, id) else { return nil }
            return info.tableModel.identifier
        }
    }

    /// The table drawables (TST.TableInfoArchive) on `slide`, in drawable order.
    public func slideTableInfos(_ slide: UInt64) -> [UInt64] {
        slideDrawables(slide).filter { store.record(for: $0)?.info.messageInfos.first?.type == Self.tableInfoType }
    }

    /// The frame (points) of drawable `drawable`: a shape, table or chart.
    public func drawableFrame(_ drawable: UInt64) -> Frame? {
        guard let type = store.record(for: drawable)?.info.messageInfos.first?.type else { return nil }
        let g: TSD_GeometryArchive
        switch type {
        case Self.tableInfoType: guard let t = decoded(TST_TableInfoArchive.self, drawable) else { return nil }; g = t.super.geometry
        case Self.chartDrawableType: guard let c = decoded(TSCH_ChartDrawableArchive.self, drawable) else { return nil }; g = c.super.geometry
        case Self.shapeInfoType: guard let s = decoded(TSWP_ShapeInfoArchive.self, drawable) else { return nil }; g = s.super.super.geometry
        default: return nil
        }
        return Frame(x: Double(g.position.x), y: Double(g.position.y), width: Double(g.size.width), height: Double(g.size.height), angle: Double(g.angle))
    }

    /// Places table drawable `info` at `frame` the way Keynote does when a table's width, height
    /// and position are set: every column `width / columns` wide, every row `height / rows` tall
    /// (the header buckets' sizes), the position as given.
    public mutating func setTableFrame(_ info: UInt64, _ frame: Frame) throws {
        guard var table = decoded(TST_TableInfoArchive.self, info), let model = decoded(TST_TableModelArchive.self, table.tableModel.identifier) else {
            throw TableCellsFailure.notATable(info)
        }
        let rows = Int(model.numberOfRows), columns = Int(model.numberOfColumns)
        guard rows > 0, columns > 0 else { throw TableCellsFailure.notATable(info) }
        func resize(_ bucket: UInt64, to size: Float) throws {
            guard var b = decoded(TST_HeaderStorageBucket.self, bucket) else { return }
            for i in b.headers.indices { b.headers[i].size = size }
            try replacePayload(of: bucket, with: try b.serializedData(partial: true))
        }
        for bucket in model.baseDataStore.rowHeaders.buckets { try resize(bucket.identifier, to: Float(frame.height / Double(rows))) }
        try resize(model.baseDataStore.columnHeaders.identifier, to: Float(frame.width / Double(columns)))
        table.super.geometry.position = .with { $0.x = Float(frame.x); $0.y = Float(frame.y) }
        table.super.geometry.size = .with { $0.width = Float(frame.width); $0.height = Float(frame.height) }
        try replacePayload(of: info, with: try table.serializedData(partial: true))
    }

    static let headerNameManagerType: UInt32 = 6366, headerNameTileType: UInt32 = 6365

    /// Registers table `model`'s header names with this deck's header-name manager, as Keynote does
    /// for a table it makes (learned from Keynote's own builds): a per-table entry (the table's UID,
    /// the next free precedent, the header row's and column's UIDs) and, in the name-fragment
    /// tile, each lowercased word of the header cells (the header row left to right, then the
    /// header column top to bottom) with the next precedent and a use naming its cell by column
    /// and row UID. A word already in the tile gains a use and keeps its precedent. A deck with no
    /// tile gets a copy of `tileSource`'s record (a Keynote-made tile), refilled.
    public mutating func registerHeaderNames(_ model: UInt64, cells: [[String]], tileSource: (KeynoteDocument, UInt64)?) throws {
        guard let m = decoded(TST_TableModelArchive.self, model), let base = Self.uuidValue(m.tableID),
              let managerID = store.identifiers.first(where: { store.record(for: $0)?.info.messageInfos.first?.type == Self.headerNameManagerType }),
              var manager = decoded(TST_HeaderNameMgrArchive.self, managerID),
              let map = decoded(TST_ColumnRowUIDMapArchive.self, m.baseColumnRowUids.identifier) else { throw TableCellsFailure.notATable(model) }
        func columnUID(_ i: Int) -> TSP_UUID? { i < map.columnUidForIndex.count ? map.sortedColumnUids[Int(map.columnUidForIndex[i])] : nil }
        func rowUID(_ i: Int) -> TSP_UUID? { i < map.rowUidForIndex.count ? map.sortedRowUids[Int(map.rowUidForIndex[i])] : nil }
        guard let headerRow = rowUID(0), let headerColumn = columnUID(0) else { throw TableCellsFailure.notATable(model) }
        let tableUID = TSP_UUID.with { $0.lower = base.lower; $0.upper = base.upper }

        // The tile: this deck's, or a copy of the source's record, emptied.
        var tileID = manager.nameFragTiles.first?.identifier
        var tile = tileID.flatMap { decoded(TST_HeaderNameMgrTileArchive.self, $0) } ?? TST_HeaderNameMgrTileArchive()
        if tileID == nil {
            guard let (deck, sourceTile) = tileSource, let record = deck.store.record(for: sourceTile),
                  let home = store.entry(for: managerID)?.component, var metadata = packageMetadata else { return }
            var allocator = IDAllocator(seed: max(store.highestIdentifier, metadata.lastObjectIdentifier) + 1)
            let id = allocator.allocate()
            var info = record.info
            info.setIdentifier(id)
            store.append(ArchiveRecord(info: info, payloads: record.payloads, isDirty: true), to: home)
            metadata.lastObjectIdentifier = max(metadata.lastObjectIdentifier, allocator.highWaterMark)
            try replacePayload(of: 2, with: try metadata.serializedData(partial: true))
            tileID = id
            tile = TST_HeaderNameMgrTileArchive()
            manager.nameFragTiles.append(TSP_Reference.with { $0.identifier = id })
        }
        guard let tileID else { return }

        // Precedents: columns in row 1 of the manager's own coordinate space, the next free ones.
        var next = UInt32(([1] + manager.perTables.map { Int($0.perTablePrecedent.column) } + tile.nameFragEntries.map { Int($0.namePrecedent.column) }).max()! + (manager.perTables.isEmpty && tile.nameFragEntries.isEmpty ? 0 : 1))
        manager.perTables.append(.with {
            $0.tableUid = tableUID
            $0.perTablePrecedent = .with { $0.column = next; $0.row = 1 }
            $0.headerRowUids = [headerRow]
            $0.headerColumnUids = [headerColumn]
        })
        next += 1
        // The header cells, in Keynote's order: the header row left to right, then the header
        // column top to bottom.
        func cellText(_ r: Int, _ c: Int) -> String { r < cells.count && c < cells[r].count ? cells[r][c] : "" }
        var order = [(Int, Int)]()
        for c in 0..<Int(m.numberOfColumns) { order.append((0, c)) }
        for r in 1..<max(1, Int(m.numberOfRows)) { order.append((r, 0)) }
        for (r, c) in order {
            guard let col = columnUID(c), let row = rowUID(r) else { continue }
            let use = TSCE_UidCellRefSetArchive.OwnerEntry.with {
                $0.ownerUid = tableUID
                $0.coordSet = .with { $0.columnEntries = [.with { $0.column = col; $0.rowSet = [row] }] }
            }
            for word in cellText(r, c).lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init) {
                if let i = tile.nameFragEntries.firstIndex(where: { $0.nameFragment == word }) {
                    tile.nameFragEntries[i].usesOfNameFragment.ownerEntries.append(use)
                } else {
                    tile.nameFragEntries.append(.with {
                        $0.nameFragment = word
                        $0.namePrecedent = .with { $0.column = next; $0.row = 1 }
                        $0.usesOfNameFragment = .with { $0.ownerEntries = [use] }
                    })
                    next += 1
                }
            }
        }
        tile.nameFragEntries.sort { $0.nameFragment < $1.nameFragment }
        tile.firstFragment = tile.nameFragEntries.first?.nameFragment ?? ""
        tile.lastFragment = tile.nameFragEntries.last?.nameFragment ?? ""
        try replacePayload(of: tileID, with: try tile.serializedData(partial: true))
        try replacePayload(of: managerID, with: try manager.serializedData(partial: true))
    }

    /// The size of table model `model`, header rows and columns included.
    public func tableSize(_ model: UInt64) -> (rows: Int, columns: Int)? {
        guard store.record(for: model)?.info.messageInfos.first?.type == Self.tableModelType,
              let m = decoded(TST_TableModelArchive.self, model) else { return nil }
        return (Int(m.numberOfRows), Int(m.numberOfColumns))
    }

    /// Replaces the parts table's "r<row>c<column>" strings with `cells[row][column]` (0-based).
    public mutating func setTableCells(_ model: UInt64, _ cells: [[String]]) throws {
        guard let size = tableSize(model), let m = decoded(TST_TableModelArchive.self, model) else { throw TableCellsFailure.notATable(model) }
        let width = cells.map(\.count).max() ?? 0
        guard cells.count == size.rows, width == size.columns else {
            throw TableCellsFailure.size(rows: size.rows, columns: size.columns, cells: (cells.count, width))
        }
        let listID = m.baseDataStore.stringTable.identifier
        guard var list = decoded(TST_TableDataList.self, listID) else { throw TableCellsFailure.notATable(model) }
        for (r, row) in cells.enumerated() {
            for c in 0..<size.columns {
                let marker = "r\(r + 1)c\(c + 1)"
                guard let e = list.entries.firstIndex(where: { $0.string == marker }) else { throw TableCellsFailure.missingMarker(marker) }
                list.entries[e].string = c < row.count ? row[c] : ""
            }
        }
        try replacePayload(of: listID, with: try list.serializedData(partial: true))
    }
}
