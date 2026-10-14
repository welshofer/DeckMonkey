#!/usr/bin/env swift
// pdfdiff.swift — rasterize two PDFs at 72 dpi and count mismatched pixels (docs/spec.md §10 step 5).
//
// usage: swift Scripts/pdfdiff.swift golden.pdf candidate.pdf [--dump dir]
// Prints {"mismatch": <pixels>, "bounds": [page, minX, minY, maxX, maxY] | null, "pages": [a, b]}.
// A page-count difference counts every pixel of the extra pages as mismatched.
// macOS only (CoreGraphics). Exit 0 when the JSON was produced, whatever the mismatch.

import CoreGraphics
import Foundation

func raster(_ page: CGPDFPage, scale: CGFloat = 1.0) -> (width: Int, height: Int, bytes: [UInt8])? {
    let box = page.getBoxRect(.mediaBox)
    let width = Int((box.width * scale).rounded(.up))
    let height = Int((box.height * scale).rounded(.up))
    guard width > 0, height > 0 else { return nil }
    let space = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    ctx.scaleBy(x: scale, y: scale)
    ctx.translateBy(x: -box.minX, y: -box.minY)
    ctx.drawPDFPage(page)
    guard let data = ctx.data else { return nil }
    let bytes = [UInt8](UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: width * height * 4))
    return (width, height, bytes)
}

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write(Data("usage: pdfdiff.swift golden.pdf candidate.pdf\n".utf8))
    exit(2)
}
guard let a = CGPDFDocument(URL(fileURLWithPath: args[1]) as CFURL),
      let b = CGPDFDocument(URL(fileURLWithPath: args[2]) as CFURL) else {
    print("{\"mismatch\": -1, \"bounds\": null, \"pages\": [0, 0], \"error\": \"could not open a PDF\"}")
    exit(0)
}

var mismatch = 0
var bounds: [Int]? = nil
let pages = max(a.numberOfPages, b.numberOfPages)
for index in 1...max(pages, 1) where pages > 0 {
    guard let pa = a.page(at: index), let pb = b.page(at: index),
          let ra = raster(pa), let rb = raster(pb) else {
        if let p = a.page(at: index) ?? b.page(at: index), let r = raster(p) {
            mismatch += r.width * r.height
            if bounds == nil { bounds = [index, 0, 0, r.width, r.height] }
        }
        continue
    }
    if ra.width != rb.width || ra.height != rb.height {
        mismatch += max(ra.width * ra.height, rb.width * rb.height)
        if bounds == nil { bounds = [index, 0, 0, max(ra.width, rb.width), max(ra.height, rb.height)] }
        continue
    }
    var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
    var pageMismatch = 0
    for y in 0..<ra.height {
        for x in 0..<ra.width {
            let i = (y * ra.width + x) * 4
            if ra.bytes[i] != rb.bytes[i] || ra.bytes[i + 1] != rb.bytes[i + 1] || ra.bytes[i + 2] != rb.bytes[i + 2] {
                pageMismatch += 1
                minX = min(minX, x); minY = min(minY, y); maxX = max(maxX, x); maxY = max(maxY, y)
            }
        }
    }
    mismatch += pageMismatch
    if pageMismatch > 0, bounds == nil {
        bounds = [index, minX, minY, maxX + 1, maxY + 1]
    }
}

let boundsJSON = bounds.map { "[\($0.map(String.init).joined(separator: ", "))]" } ?? "null"
print("{\"mismatch\": \(mismatch), \"bounds\": \(boundsJSON), \"pages\": [\(a.numberOfPages), \(b.numberOfPages)]}")
