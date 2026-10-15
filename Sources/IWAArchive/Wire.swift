import Foundation
import IWASnappy

/// Errors from the protobuf wire-format reader.
public enum WireError: Error, Equatable, Sendable {
    case truncated(at: Int)
    case badTag(at: Int)
    /// Wire types 3 and 4 (groups) and anything above 5 are not used by IWA.
    case unsupportedWireType(Int, at: Int)
}

/// One field as it sits on the wire, with no schema applied.
///
/// `IWAArchive` reads `TSP.ArchiveInfo` and `TSP.MessageInfo` this way instead of through generated
/// code so the raw layer can round-trip a file from any Keynote version with no schema at all
/// (invariants 1 and 2). Fields are kept in wire order and re-emitted verbatim.
public struct WireField: Equatable, Sendable {
    public enum Value: Equatable, Sendable {
        case varint(UInt64)
        case fixed64(UInt64)
        case lengthDelimited(Data)
        case fixed32(UInt32)
    }

    public var number: Int
    public var value: Value

    public init(number: Int, value: Value) {
        self.number = number
        self.value = value
    }

    public var wireType: Int {
        switch value {
        case .varint: return 0
        case .fixed64: return 1
        case .lengthDelimited: return 2
        case .fixed32: return 5
        }
    }
}

public enum Wire {
    /// Parses a message body into its fields, in order.
    public static func fields(_ bytes: [UInt8]) throws -> [WireField] {
        var fields = [WireField]()
        var pos = 0
        while pos < bytes.count {
            let tagStart = pos
            let tag = try Varint.read(bytes, at: pos)
            pos += tag.length
            let number = Int(tag.value >> 3)
            let wireType = Int(tag.value & 0x07)
            guard number > 0 else { throw WireError.badTag(at: tagStart) }
            switch wireType {
            case 0:
                let v = try Varint.read(bytes, at: pos)
                pos += v.length
                fields.append(WireField(number: number, value: .varint(v.value)))
            case 1:
                guard pos + 8 <= bytes.count else { throw WireError.truncated(at: pos) }
                var v: UInt64 = 0
                for k in 0..<8 {
                    v |= UInt64(bytes[pos + k]) << (8 * UInt64(k))
                }
                pos += 8
                fields.append(WireField(number: number, value: .fixed64(v)))
            case 2:
                let len = try Varint.read(bytes, at: pos)
                pos += len.length
                guard len.value <= UInt64(bytes.count - pos) else {
                    throw WireError.truncated(at: pos)
                }
                let n = Int(len.value)
                fields.append(WireField(number: number, value: .lengthDelimited(Data(bytes[pos..<(pos + n)]))))
                pos += n
            case 5:
                guard pos + 4 <= bytes.count else { throw WireError.truncated(at: pos) }
                var v: UInt32 = 0
                for k in 0..<4 {
                    v |= UInt32(bytes[pos + k]) << (8 * UInt32(k))
                }
                pos += 4
                fields.append(WireField(number: number, value: .fixed32(v)))
            default:
                throw WireError.unsupportedWireType(wireType, at: tagStart)
            }
        }
        return fields
    }

    /// Serializes fields in the order given, with minimal varints.
    public static func encode(_ fields: [WireField]) -> [UInt8] {
        var out = [UInt8]()
        for field in fields {
            Varint.write(UInt64(field.number) << 3 | UInt64(field.wireType), into: &out)
            switch field.value {
            case .varint(let v):
                Varint.write(v, into: &out)
            case .fixed64(let v):
                for k in 0..<8 {
                    out.append(UInt8((v >> (8 * UInt64(k))) & 0xFF))
                }
            case .lengthDelimited(let data):
                Varint.write(UInt64(data.count), into: &out)
                out.append(contentsOf: data)
            case .fixed32(let v):
                for k in 0..<4 {
                    out.append(UInt8((v >> (8 * UInt32(k))) & 0xFF))
                }
            }
        }
        return out
    }

    /// Reads a packed or unpacked repeated varint field value.
    public static func repeatedVarints(_ value: WireField.Value) throws -> [UInt64] {
        switch value {
        case .varint(let v):
            return [v]
        case .lengthDelimited(let data):
            let bytes = [UInt8](data)
            var out = [UInt64]()
            var pos = 0
            while pos < bytes.count {
                let v = try Varint.read(bytes, at: pos)
                out.append(v.value)
                pos += v.length
            }
            return out
        case .fixed64(let v):
            return [v]
        case .fixed32(let v):
            return [UInt64(v)]
        }
    }

    /// Encodes `values` as one packed length-delimited field value.
    public static func packed(_ values: [UInt64]) -> WireField.Value {
        var out = [UInt8]()
        for v in values {
            Varint.write(v, into: &out)
        }
        return .lengthDelimited(Data(out))
    }
}
