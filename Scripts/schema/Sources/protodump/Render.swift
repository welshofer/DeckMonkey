import SwiftProtobuf

/// Step 2 of the schema pipeline: render a descriptor back to `.proto` source, for people and for
/// `make schema-diff`. Generation does not read this text; it reads the descriptors directly, so a
/// rendering slip can never change generated code.
///
/// Deterministic: declaration order is the descriptor's. Fix-up per docs/spec.md §7: `-` in an
/// identifier becomes `_`. `required` is kept.
enum Render {
    typealias Field = Google_Protobuf_FieldDescriptorProto
    typealias Message = Google_Protobuf_DescriptorProto
    typealias Enum = Google_Protobuf_EnumDescriptorProto

    static func file(_ d: Google_Protobuf_FileDescriptorProto, source: String) -> String {
        var out = "// \(d.name): extracted from \(source) by Scripts/schema/protodump. Do not edit.\n"
        out += "syntax = \"\(d.hasSyntax && !d.syntax.isEmpty ? d.syntax : "proto2")\";\n"
        if d.hasPackage { out += "\npackage \(d.package);\n" }
        if !d.dependency.isEmpty {
            out += "\n"
            for (i, dep) in d.dependency.enumerated() {
                out += d.publicDependency.contains(Int32(i)) ? "import public \"\(dep)\";\n" : "import \"\(dep)\";\n"
            }
        }
        for e in d.enumType { out += "\n" + enumeration(e, indent: "") }
        for m in d.messageType { out += "\n" + message(m, indent: "") }
        out += extensions(d.extension, indent: "")
        return out
    }

    static func message(_ m: Message, indent: String) -> String {
        let inner = indent + "  "
        var out = "\(indent)message \(ident(m.name)) {\n"
        for e in m.enumType { out += enumeration(e, indent: inner) }
        for n in m.nestedType where !(n.options.hasMapEntry && n.options.mapEntry) {
            out += message(n, indent: inner)
        }
        var openOneof: Int32?
        for f in m.field {
            let oneof = f.hasOneofIndex && !f.proto3Optional ? f.oneofIndex : nil
            if oneof != openOneof {
                if openOneof != nil { out += "\(inner)}\n" }
                if let oneof { out += "\(inner)oneof \(ident(m.oneofDecl[Int(oneof)].name)) {\n" }
                openOneof = oneof
            }
            out += (oneof == nil ? inner : inner + "  ") + field(f, inOneof: oneof != nil) + "\n"
        }
        if openOneof != nil { out += "\(inner)}\n" }
        for r in m.extensionRange {
            out += "\(inner)extensions \(r.start) to \(r.end - 1 >= 536_870_911 ? "max" : String(r.end - 1));\n"
        }
        for r in m.reservedRange {
            out += "\(inner)reserved \(r.start == r.end - 1 ? "\(r.start)" : "\(r.start) to \(r.end - 1)");\n"
        }
        if !m.reservedName.isEmpty {
            out += "\(inner)reserved \(m.reservedName.map { "\"\($0)\"" }.joined(separator: ", "));\n"
        }
        out += extensions(m.extension, indent: inner)
        out += "\(indent)}\n"
        return out
    }

    static func field(_ f: Field, inOneof: Bool) -> String {
        let label: String
        switch f.label {
        case .required: label = "required "
        case .repeated: label = "repeated "
        default: label = inOneof ? "" : "optional "
        }
        var options = [String]()
        if f.hasDefaultValue {
            let quoted = f.type == .string || f.type == .bytes
            options.append("default = \(quoted ? "\"\(escape(f.defaultValue))\"" : f.defaultValue)")
        }
        if f.options.hasPacked { options.append("packed = \(f.options.packed)") }
        if f.options.hasDeprecated && f.options.deprecated { options.append("deprecated = true") }
        if f.options.hasLazy && f.options.lazy { options.append("lazy = true") }
        let suffix = options.isEmpty ? "" : " [\(options.joined(separator: ", "))]"
        return "\(label)\(typeName(f)) \(ident(f.name)) = \(f.number)\(suffix);"
    }

    static func extensions(_ fields: [Field], indent: String) -> String {
        var out = ""
        var current: String?
        for f in fields {
            if f.extendee != current {
                if current != nil { out += "\(indent)}\n" }
                out += "\(indent)extend \(f.extendee) {\n"
                current = f.extendee
            }
            out += "\(indent)  \(field(f, inOneof: false))\n"
        }
        if current != nil { out += "\(indent)}\n" }
        return out
    }

    static func enumeration(_ e: Enum, indent: String) -> String {
        var out = "\(indent)enum \(ident(e.name)) {\n"
        if e.options.hasAllowAlias && e.options.allowAlias { out += "\(indent)  option allow_alias = true;\n" }
        for v in e.value {
            let deprecated = v.options.hasDeprecated && v.options.deprecated ? " [deprecated = true]" : ""
            out += "\(indent)  \(ident(v.name)) = \(v.number)\(deprecated);\n"
        }
        out += "\(indent)}\n"
        return out
    }

    static func typeName(_ f: Field) -> String {
        if f.hasTypeName && !f.typeName.isEmpty { return f.typeName }
        switch f.type {
        case .double: return "double"
        case .float: return "float"
        case .int64: return "int64"
        case .uint64: return "uint64"
        case .int32: return "int32"
        case .fixed64: return "fixed64"
        case .fixed32: return "fixed32"
        case .bool: return "bool"
        case .string: return "string"
        case .bytes: return "bytes"
        case .uint32: return "uint32"
        case .sfixed32: return "sfixed32"
        case .sfixed64: return "sfixed64"
        case .sint32: return "sint32"
        case .sint64: return "sint64"
        default: return "UNKNOWN_TYPE_\(f.type.rawValue)"
        }
    }

    static func ident(_ s: String) -> String { s.replacingOccurrences(of: "-", with: "_") }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}
