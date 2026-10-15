import Foundation
import IWAArchive
import IWASchema
import SwiftProtobuf

/// A problem the validator found. Errors block `save`; warnings are reported.
public struct ValidationIssue: Equatable, Sendable, CustomStringConvertible {
    public enum Severity: String, Sendable {
        case error
        case warning
    }

    public enum Kind: Equatable, Sendable {
        case duplicateIdentifier(UInt64, components: [String])
        case danglingObjectReference(from: UInt64, to: UInt64)
        case unknownType(UInt32, identifier: UInt64)
        case missingDataFile(String)
        /// A TSWP.StorageArchive offset table out of order or past its text (invariant 8).
        case textOffset(identifier: UInt64, TextOffsets.Problem)
        /// A header data reference with no DataInfo in PackageMetadata (invariant 8).
        case danglingDataReference(from: UInt64, to: UInt64)
    }

    public let severity: Severity
    public let kind: Kind

    public var description: String {
        switch kind {
        case .duplicateIdentifier(let id, let components):
            return "\(severity.rawValue): duplicate identifier \(id) in \(components.joined(separator: ", "))"
        case .danglingObjectReference(let from, let to):
            return "\(severity.rawValue): object \(from) references missing object \(to)"
        case .unknownType(let type, let id):
            return "\(severity.rawValue): object \(id) has type \(type) not in the pinned registry"
        case .missingDataFile(let name):
            return "\(severity.rawValue): Data/ entry \(name) is missing"
        case .textOffset(let id, let problem):
            return "\(severity.rawValue): text storage \(id): \(problem)"
        case .danglingDataReference(let from, let to):
            return "\(severity.rawValue): object \(from) references data \(to), which has no DataInfo"
        }
    }
}

/// The pre-write checks of invariant 8: duplicate identifiers, dangling strong (listed) references,
/// unknown types, text offset tables, and data references → DataInfo → file in Data/.
public enum Validator {
    public static func validate(_ document: KeynoteDocument) -> [ValidationIssue] {
        var issues = [ValidationIssue]()
        for issue in document.store.issues {
            switch issue {
            case .duplicateIdentifier(let id, let components):
                issues.append(ValidationIssue(severity: .error, kind: .duplicateIdentifier(id, components: components)))
            }
        }
        // An error, not a warning: 28 Keynote-authored decks (6.5 through 15.4, macOS, iOS and iCloud
        // saves) carry zero header-level dangling references, so one in our output means we broke
        // the graph (invariant 8). AT-06 extends the same check to payload-level TSP.Reference.
        for dangling in document.store.danglingObjectReferences {
            issues.append(ValidationIssue(severity: .error, kind: .danglingObjectReference(from: dangling.from, to: dangling.to)))
        }
        // Invariant 8: an unknown type is an error. Two things in a Keynote file are not typed
        // messages and are skipped: a merge archive's diff descriptor (`MessageInfo [1]`, type 0,
        // carrying base_message_index; spec §4 row 3a), and a type this Keynote declares deprecated
        // (it knows it and has no schema; 6219 in decks last saved by 6.5). Corpus: 0 unknown.
        if let registry = document.registry, !registry.isEmpty {
            for identifier in document.store.identifiers {
                guard let record = document.store.record(for: identifier) else { continue }
                for info in record.info.messageInfos where info.baseMessageIndex == nil && !registry.resolves(info.type) {
                    issues.append(ValidationIssue(severity: .error, kind: .unknownType(info.type, identifier: identifier)))
                }
            }
        }
        // Invariant 8 for text: offset tables strictly increasing and within the UTF-16 text length
        // (0 violations in 23,248 Keynote-authored storages; an index may equal the length).
        for component in document.store.components {
            for record in component.records {
                for (i, info) in record.info.messageInfos.enumerated() where info.type == storageArchiveType && info.baseMessageIndex == nil {
                    guard i < record.payloads.count,
                          let storage = try? TSWP_StorageArchive(serializedBytes: record.payloads[i], extensions: Schema.extensions, partial: true)
                    else { continue }
                    for problem in TextOffsets.problems(in: storage) {
                        issues.append(ValidationIssue(severity: .error, kind: .textOffset(identifier: record.identifier, problem)))
                    }
                }
            }
        }
        // Invariant 8 for data: every data reference resolves to a DataInfo, and every DataInfo that
        // names a file has it in Data/ (no or an empty file name: an app resource).
        if let metadata = document.packageMetadata {
            let known = Set(metadata.datas.map(\.identifier))
            for component in document.store.components {
                for record in component.records {
                    for info in record.info.messageInfos {
                        for id in info.dataReferences where !known.contains(id) {
                            issues.append(ValidationIssue(severity: .error, kind: .danglingDataReference(from: record.identifier, to: id)))
                        }
                    }
                }
            }
            for d in metadata.datas {
                if let name = d.storedFileName, document.package.data("Data/" + name) == nil {
                    issues.append(ValidationIssue(severity: .error, kind: .missingDataFile("Data/" + name)))
                }
            }
        }
        return issues
    }

    static let storageArchiveType: UInt32 = 2001
}
