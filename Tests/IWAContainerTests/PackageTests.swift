import Foundation
import Rostrum
import Testing
@testable import IWAContainer

enum SynthPackage {
    static let properties = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>fileFormatVersion</key><string>15.4</string>
            <key>documentUUID</key><string>ABCDEF</string>
            <key>revision</key><integer>3</integer>
        </dict>
        </plist>
        """

    static let history = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <array>
            <string>M14.2-6900-1</string>
            <string>M15.4-7051-1</string>
        </array>
        </plist>
        """

    static func entries(iwa: Data) -> [String: Data] {
        [
            "Index/Document.iwa": iwa,
            "Index/Slide-1.iwa": iwa,
            "Metadata/Properties.plist": Data(properties.utf8),
            "Metadata/BuildVersionHistory.plist": Data(history.utf8),
            "Metadata/DocumentIdentifier": Data("1234-5678\n".utf8),
            "Data/image-1.jpg": Data([0xFF, 0xD8, 0xFF]),
            "preview.jpg": Data([0xFF, 0xD8]),
        ]
    }

    static func zip(_ entries: [String: Data]) throws -> Data {
        var writer = ZipWriter()
        for name in entries.keys.sorted() {
            writer.addFile(name: name, data: entries[name]!, compress: true)
        }
        return try writer.finalize()
    }
}

@Suite("IWA package container")
struct PackageTests {
    @Test("a zip-form package opens, exposes entries and metadata")
    func openZip() throws {
        let iwa = Data([0, 1, 0, 0, 0])   // one chunk, bogus body; the container does not decode it
        let package = try IWAPackage.openZip(try SynthPackage.zip(SynthPackage.entries(iwa: iwa)))
        #expect(package.form == .zip)
        #expect(package.nestedIndex == false)
        #expect(package.iwaNames == ["Index/Document.iwa", "Index/Slide-1.iwa"])
        #expect(package.dataNames == ["Data/image-1.jpg"])
        #expect(package.buildVersionHistory == ["M14.2-6900-1", "M15.4-7051-1"])
        #expect(package.fileFormatVersion == "15.4")
        #expect(package.properties["documentUUID"] == "ABCDEF")
        #expect(package.properties["revision"] == "3")
        #expect(package.documentIdentifier == "1234-5678")
    }

    @Test("an older package with a nested Index.zip is flattened and written back nested")
    func nestedIndex() throws {
        let iwa = Data([0, 1, 0, 0, 0])
        var entries = SynthPackage.entries(iwa: iwa)
        var inner = ZipWriter()
        inner.addFile(name: "Document.iwa", data: iwa, compress: false)
        entries["Index/Document.iwa"] = nil
        entries["Index/Slide-1.iwa"] = nil
        entries["Index.zip"] = try inner.finalize()
        let package = try IWAPackage.openZip(try SynthPackage.zip(entries))
        #expect(package.nestedIndex == true)
        #expect(package.iwaNames == ["Index/Document.iwa"])
        let rewritten = try IWAPackage.openZip(try package.zipData())
        #expect(rewritten.nestedIndex == true)
        #expect(rewritten.entries == package.entries)
    }

    @Test("write→open identity in zip and directory form")
    func writeIdentity() throws {
        let iwa = Data([0, 1, 0, 0, 0])
        let package = try IWAPackage.openZip(try SynthPackage.zip(SynthPackage.entries(iwa: iwa)))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("deckmonkey-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let zipURL = dir.appendingPathComponent("a.key")
        try package.write(to: zipURL)
        let fromZip = try IWAPackage.open(zipURL)
        #expect(fromZip.entries == package.entries)
        #expect(fromZip.form == .zip)

        let dirURL = dir.appendingPathComponent("b.key")
        try package.write(to: dirURL, as: .directory)
        let fromDir = try IWAPackage.open(dirURL)
        #expect(fromDir.entries == package.entries)
        #expect(fromDir.form == .directory)
    }

    @Test("legacy APXL packages and non-iWork zips are refused with typed errors")
    func refusals() throws {
        var legacy = SynthPackage.entries(iwa: Data([0]))
        legacy["index.apxl"] = Data("<presentation/>".utf8)
        #expect(throws: IWAPackageError.unsupportedLegacyFormat("<memory>")) {
            try IWAPackage.openZip(try SynthPackage.zip(legacy))
        }
        #expect(throws: IWAPackageError.notAnIWorkPackage("<memory>")) {
            try IWAPackage.openZip(try SynthPackage.zip(["README.txt": Data("hi".utf8)]))
        }
        #expect(throws: IWAPackageError.notFound("/nonexistent/x.key")) {
            try IWAPackage.open(URL(fileURLWithPath: "/nonexistent/x.key"))
        }
    }

    @Test("an entry name that could escape the package is refused on open and on write")
    func unsafeEntryNames() throws {
        for bad in ["Data/../../escape.png", "/etc/x", "Index/./Document.iwa", "Data//x", "Data\\x", "Data/x\u{0}y", "", "a/../\u{301}b", "Index/\u{301}../../x"] {
            #expect(!IWAPackage.isSafeEntryName(bad), "\(bad)")
        }
        for good in ["Index/Document.iwa", "Data/photo-2652582.jpg", "Index/Tables/Tile-2654602.iwa", "Data/a b..c.png"] {
            #expect(IWAPackage.isSafeEntryName(good), "\(good)")
        }
        var hostile = SynthPackage.entries(iwa: Data([0]))
        hostile["Data/../../escape.png"] = Data([1])
        #expect(throws: IWAPackageError.unsafeEntryName("Data/../../escape.png")) {
            try IWAPackage.openZip(try SynthPackage.zip(hostile))
        }
        var package = try IWAPackage.openZip(try SynthPackage.zip(SynthPackage.entries(iwa: Data([0]))))
        package.set("Index/../../escape.iwa", Data([1]))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("deckmonkey-unsafe-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(throws: IWAPackageError.unsafeEntryName("Index/../../escape.iwa")) { try package.write(to: dir.appendingPathComponent("x.key"), as: .directory) }
        #expect(throws: IWAPackageError.unsafeEntryName("Index/../../escape.iwa")) { try package.zipData() }
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("escape.iwa").path))

        // A package directory with a symbolic link inside is refused, not followed.
        let linked = dir.appendingPathComponent("linked.key")
        try IWAPackage.openZip(try SynthPackage.zip(SynthPackage.entries(iwa: Data([0])))).write(to: linked, as: .directory)
        try FileManager.default.createDirectory(at: linked.appendingPathComponent("Data"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: linked.appendingPathComponent("Data/secret").path, withDestinationPath: "/etc/hosts")
        #expect(throws: IWAPackageError.unsafeEntryName("Data/secret")) { try IWAPackage.open(linked) }
    }
}
