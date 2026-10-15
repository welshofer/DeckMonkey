import Foundation
import IWAArchive

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
        }
    }
}

/// The pre-write checks of invariant 8. Phase 0 covers what the raw store can see: identifiers,
/// header-declared references, merge records. Payload-level checks (offset tables, `DataReference`
/// → `DataInfo` → file) arrive with the typed layer.
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
        if let registry = document.registry, !registry.isEmpty {
            for identifier in document.store.identifiers {
                guard let record = document.store.record(for: identifier) else { continue }
                for info in record.info.messageInfos where registry.name(for: info.type) == nil {
                    issues.append(ValidationIssue(severity: .warning, kind: .unknownType(info.type, identifier: identifier)))
                }
            }
        }
        return issues
    }
}
