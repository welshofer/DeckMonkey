import Foundation
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
