// pdftext.swift — the text of each page of a PDF, as a JSON array of strings (PDFKit).
// usage: swift Scripts/pdftext.swift <file.pdf>
import Foundation
import PDFKit

guard CommandLine.arguments.count == 2, let doc = PDFDocument(url: URL(fileURLWithPath: CommandLine.arguments[1])) else {
    FileHandle.standardError.write("usage: pdftext.swift <file.pdf>\n".data(using: .utf8)!)
    exit(2)
}
let pages = (0..<doc.pageCount).map { doc.page(at: $0)?.string ?? "" }
let data = try JSONSerialization.data(withJSONObject: pages)
print(String(decoding: data, as: UTF8.self))
