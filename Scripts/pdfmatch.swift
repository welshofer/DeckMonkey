#!/usr/bin/env swift
// pdfmatch.swift — which pages of a reference PDF each page of a candidate PDF equals, pixel for
// pixel (72 dpi). Gate 3 uses it: after a move or delete, every page must be an unchanged page of
// the original, in the new order.
//
// usage: swift Scripts/pdfmatch.swift reference.pdf candidate.pdf
// Prints {"pages": [r, c], "matches": [[ref pages equal to candidate page 1], ...]} (1-based).
// macOS only (CoreGraphics).

import CoreGraphics
import Foundation

func raster(_ page: CGPDFPage) -> (Int, Int, [UInt8])? {
    let box = page.getBoxRect(.mediaBox)
    let w = Int(box.width.rounded(.up)), h = Int(box.height.rounded(.up))
    guard w > 0, h > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    ctx.translateBy(x: -box.minX, y: -box.minY)
    ctx.drawPDFPage(page)
    guard let data = ctx.data else { return nil }
    return (w, h, [UInt8](UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: w * h * 4)))
}

let args = CommandLine.arguments
guard args.count >= 3, let a = CGPDFDocument(URL(fileURLWithPath: args[1]) as CFURL),
      let b = CGPDFDocument(URL(fileURLWithPath: args[2]) as CFURL) else {
    FileHandle.standardError.write(Data("usage: pdfmatch.swift reference.pdf candidate.pdf\n".utf8))
    exit(2)
}
let reference = (0..<a.numberOfPages).map { a.page(at: $0 + 1).flatMap(raster) }
var matches = [[Int]]()
for j in 1...max(b.numberOfPages, 1) where b.numberOfPages > 0 {
    guard let page = b.page(at: j), let r = raster(page) else { matches.append([]); continue }
    var equal = [Int]()
    for (i, ref) in reference.enumerated() {
        if let ref, ref.0 == r.0, ref.1 == r.1, ref.2 == r.2 { equal.append(i + 1) }
    }
    matches.append(equal)
}
let list = matches.map { "[" + $0.map(String.init).joined(separator: ", ") + "]" }.joined(separator: ", ")
print("{\"pages\": [\(a.numberOfPages), \(b.numberOfPages)], \"matches\": [\(list)]}")
