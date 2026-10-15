import Foundation
import IWASchema
import SwiftProtobuf
import Testing
@testable import KeynoteGraph

@Test func xProbe() throws {
    let d = try KeynoteDocument.open(CorpusTests.repoRoot.appendingPathComponent("Corpus/features/charts.key"))
    for (i, e) in try d.slideList().enumerated() where i < 3 {
        for id in d.slideDrawables(e.slide) where d.store.record(for: id)?.info.messageInfos[0].type == 5021 {
            let c = d.decoded(TSCH_ChartDrawableArchive.self, id)!
            var u = c.TSCH_ChartArchive_unity
            let g = u.grid
            u.grid = TSCH_ChartGridArchive()
            print("XP slide \(i) chart \(id) geometry \(c.super.geometry.position.x),\(c.super.geometry.position.y) \(c.super.geometry.size.width)x\(c.super.geometry.size.height) flags \(c.super.geometry.flags)")
            print("XP   grid rows \(g.rowName) cols \(g.columnName) values \(g.gridRow.map { $0.value.map(\.numericValue) }) idMap rows \(g.idMap.rowIDMap.map { "\($0.uniqueID):\($0.index)" }) cols \(g.idMap.columnIDMap.map { "\($0.uniqueID):\($0.index)" })")
            print("XP   rest \(u.textFormatString().replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "  ", with: "").prefix(900))")
        }
    }
}
