#!/usr/bin/env python3
"""registry-dump.py — docs/spec.md §7 step 4, statically.

usage: registry-dump.py <Keynote.app> <descriptors.pb> --out registry-<version>.json

Keynote fills its TSPRegistry (type number -> message) at launch, from one
`<Prefix>RegisterPersistentClasses` function per framework plus TSPRegistry's own
`registerPersistenceMessages`. Every registration compiles to the same arm64 shape:

    bl   <X::default_instance()>                    ; x3: the prototype (symbol often stripped)
    bl   AssignDescriptors(&descriptor_table_F, 0)
    ldr  x8, [xT, #0x58]                             ; xT = &descriptor_table_F: its metadata array
    ldr  x4, [x8, #16*i]                             ; x4: the descriptor of F's i-th message
    mov  w2, #<type>
    bl   <objc stub: -[TSPRegistry setMessageType:messagePrototype:descriptor:unarchiveClassname:]>

The dynamic route (Frida, lldb) is closed on a stock Mac: Keynote is hardened-runtime with
library validation and no get-task-allow, and SIP is on. So this reads the calls out of the
arm64 disassembly. The message is identified the way Keynote identifies it: by descriptor, i.e.
the descriptor table's symbol (`_descriptor_table_TSKArchives_2eproto` -> TSKArchives.proto)
and the index into its metadata, which protobuf lays out as every message of the file in
post-order (nested before parent), 16 bytes apiece. Where the prototype's `default_instance` symbol survives it must name
the same message. Objc stubs resolve to selectors through __objc_stubs -> __objc_selrefs
(chained-fixup target) -> __objc_methname.

Nothing is guessed: a registration whose type or descriptor cannot be read is an error, as is a
symbol that disagrees with the descriptor, or one type registered to two messages by the same
kind of call. AT-05 (every corpus type resolves) is the completeness check.

Needs Xcode's otool and nm. Standard library only.
"""
import bisect, json, os, plistlib, re, struct, subprocess, sys

REGISTER_SELECTORS = {
    "setMessageType:messagePrototype:descriptor:unarchiveClassname:": "register",
    "setOverrideMessageType:messagePrototype:descriptor:": "override",
    "setOverrideMessageType:messagePrototype:descriptor:unarchiveClassname:": "override",
    "setUpgradeMessageType:messagePrototype:unarchiveClassname:": "upgrade",
    "setUpgradeMessageType:messagePrototype:unarchiveClass:unarchiveClassname:": "upgrade",
    "setMessageType:forUnarchiveClassname:": "classname",
    "setDeprecatedMessageType:": "deprecated",
}
WITH_DESCRIPTOR = {"register", "override"}
METADATA_OFFSET = 0x58  # DescriptorTable -> file_level_metadata
METADATA_STRIDE = 16    # Metadata { const Descriptor*, const Reflection* }


def fail(message):
    sys.stderr.write(f"registry-dump: {message}\n")
    sys.exit(1)


def run(*args):
    return subprocess.run(list(args), check=True, capture_output=True, text=True).stdout


def otool(*args):
    return run("otool", "-arch", "arm64", *args)


# --- descriptors ---------------------------------------------------------------------------------

def varint(b, p):
    r = s = 0
    while True:
        c = b[p]; p += 1
        r |= (c & 0x7F) << s; s += 7
        if c < 0x80: return r, p


def fields(b):
    p = 0
    while p < len(b):
        tag, p = varint(b, p)
        n, wt = tag >> 3, tag & 7
        if wt == 0: v, p = varint(b, p)
        elif wt == 2:
            ln, p = varint(b, p); v = b[p:p + ln]; p += ln
        elif wt == 1: v = b[p:p + 8]; p += 8
        elif wt == 5: v = b[p:p + 4]; p += 4
        else: raise ValueError(f"wire type {wt}")
        yield n, v


def files_in(descriptor_set):
    """file name -> its messages' full names in protobuf's file_level_metadata order: post-order,
    every nested message before its parent (protoc's C++ FlattenMessagesInFile)."""
    out = {}

    def walk(msg, prefix, into):
        name = next(bytes(v).decode() for n, v in fields(msg) if n == 1)
        full = f"{prefix}.{name}" if prefix else name
        for n, v in fields(msg):
            if n == 3: walk(v, full, into)
        into.append(full)

    for n, file in fields(descriptor_set):
        if n != 1: continue
        name, package, messages = "", "", []
        for fn, v in fields(file):
            if fn == 1: name = bytes(v).decode()
            if fn == 2: package = bytes(v).decode()
        for fn, v in fields(file):
            if fn == 4: walk(v, package, messages)
        out[name] = messages
    return out


def table_file(symbol):
    """`_descriptor_table_TSCHArchives_2eGEN_2eproto` -> `TSCHArchives.GEN.proto`."""
    m = re.fullmatch(r"_descriptor_table_(.+)", symbol)
    return re.sub(r"_([0-9a-f]{2})", lambda h: chr(int(h.group(1), 16)), m.group(1)) if m else None


def demangle_default_instance(symbol):
    """`__ZN4TSCH9Generated12ChartArchive16default_instanceEv` -> `TSCH::Generated::ChartArchive`."""
    m = re.fullmatch(r"__ZN((?:\d+\w+?)+)16default_instanceEv", symbol)
    if not m: return None
    parts, s = [], m.group(1)
    while s:
        d = re.match(r"\d+", s).group(0)
        ln = int(d); parts.append(s[len(d):len(d) + ln]); s = s[len(d) + ln:]
    return "::".join(parts)


# --- one binary ----------------------------------------------------------------------------------

class MachO:
    """The arm64 slice of a (possibly fat) Mach-O: read pointers and C strings at a vmaddr."""

    def __init__(self, path):
        f = open(path, "rb").read()
        base = 0
        if struct.unpack(">I", f[:4])[0] in (0xCAFEBABE, 0xCAFEBABF):
            for i in range(struct.unpack(">I", f[4:8])[0]):
                cpu, _, off, _, _ = struct.unpack(">iiIII", f[8 + 20 * i:28 + 20 * i])
                if cpu == 0x0100000C: base = off
        self.m = memoryview(f)[base:]
        self.segments = []
        ncmds, p = struct.unpack("<I", self.m[16:20])[0], 32
        for _ in range(ncmds):
            cmd, size = struct.unpack("<II", self.m[p:p + 8])
            if cmd == 0x19:  # LC_SEGMENT_64
                vm, vs, fo, fs = struct.unpack("<QQQQ", self.m[p + 24:p + 56])
                self.segments.append((vm, fo, fs))
            p += size

    def offset(self, va):
        for vm, fo, fs in self.segments:
            if vm <= va < vm + fs: return fo + va - vm
        return None

    def pointer(self, va):
        """A rebase in a chained-fixup chain: the target vmaddr is the low 36 bits."""
        o = self.offset(va)
        if o is None: return None
        v = struct.unpack("<Q", self.m[o:o + 8])[0]
        return None if v >> 63 else v & 0xFFFFFFFFF

    def u32(self, va):
        o = self.offset(va)
        return None if o is None else struct.unpack("<I", self.m[o:o + 4])[0]

    def cstring(self, va):
        o = self.offset(va)
        if o is None: return None
        end = bytes(self.m[o:o + 512]).find(b"\0")
        return bytes(self.m[o:o + end]).decode("utf-8", "replace") if end >= 0 else None


TABLE_FILENAME = 0x10   # DescriptorTable -> const char* filename
TABLE_COUNT = 0x38      # DescriptorTable -> int num_messages (compiled; may be < the descriptor's)
TABLE_DEFAULTS = 0x48   # DescriptorTable -> const Message* const* default_instances, metadata order


def all_symbols(binary):
    out = {}
    for line in run("nm", "-arch", "arm64", binary).splitlines():
        parts = line.split(maxsplit=2)  # ObjC method names contain a space
        if len(parts) == 3: out[int(parts[0], 16)] = parts[2]
    return out


def default_instance_symbol(message, package):
    """The mangled `_<Message>_default_instance_` global protobuf's C++ generator emits:
    TSCH.Generated.A.B -> __ZN4TSCH9Generated17_A_B_default_instance_E."""
    leaf = message[len(package) + 1:] if package else message
    parts = (package.split(".") if package else []) + [f"_{leaf.replace('.', '_')}_default_instance_"]
    return "__ZN" + "".join(f"{len(x)}{x}" for x in parts) + "E"


def selector_stubs(binary):
    methnames = {}
    for line in otool("-v", "-s", "__TEXT", "__objc_methname", binary).splitlines():
        m = re.match(r"^([0-9a-f]{16})\s+(.*)$", line)
        if m: methnames[int(m.group(1), 16)] = m.group(2)
    selrefs = {}
    for segment in ("__DATA_CONST", "__DATA"):
        for line in otool("-v", "-s", segment, "__objc_selrefs", binary).splitlines():
            m = re.match(r"^([0-9a-f]{16})\s+(?:0x([0-9a-f]+)|__TEXT:__objc_methname:(.*))", line)
            if not m: continue
            address = int(m.group(1), 16)
            if m.group(3) is not None:
                selrefs[address] = m.group(3)
            else:
                target = int(m.group(2), 16) & 0xFFFFFFFFF  # chained fixup: low 36 bits
                if target in methnames: selrefs[address] = methnames[target]
    stubs = {}
    lines = otool("-V", "-s", "__TEXT", "__objc_stubs", binary).splitlines()
    for i, line in enumerate(lines):
        m = re.match(r"^([0-9a-f]{16})\s+adrp\s+x1, \d+ ; 0x([0-9a-f]+)", line)
        if not m or i + 1 >= len(lines): continue
        n = re.match(r"^[0-9a-f]{16}\s+ldr\s+x1, \[x1, #0x([0-9a-f]+)\]", lines[i + 1])
        if not n: continue
        selref = int(m.group(2), 16) + int(n.group(1), 16)
        if selref in selrefs: stubs[int(m.group(1), 16)] = selrefs[selref]
    return stubs


def registrations(binary, files, package_of, stats):
    stubs = selector_stubs(binary)
    if not any(sel in REGISTER_SELECTORS for sel in stubs.values()):
        return [], []
    image = MachO(binary)
    syms = all_symbols(binary)
    tables = {}   # table address -> file name, read from the table itself
    found, problems = [], []
    name = os.path.basename(binary)

    def table_at(address):
        """Names a descriptor table by the filename it carries, then proves the index mapping for
        the whole table: the compiled default_instances array, in metadata order, must match the
        post-order flattening wherever a `_default_instance_` symbol survives. A table may compile
        fewer messages than its descriptor declares (TSK: 47 of 49), only ever at the end."""
        if address in tables: return tables[address]
        target = image.pointer(address + TABLE_FILENAME)
        file = image.cstring(target) if target is not None else None
        if file not in files:
            tables[address] = None
            return None
        symbol = syms.get(address)
        if symbol and symbol.startswith("_descriptor_table_") and table_file(symbol) != file:
            problems.append(f"{name}: table at {address:#x} names {file}, its symbol says {table_file(symbol)}")
        flat = files[file]
        count = image.u32(address + TABLE_COUNT)
        defaults = image.pointer(address + TABLE_DEFAULTS)
        if count is None or count > len(flat) or defaults is None:
            problems.append(f"{name}: {file} table at {address:#x}: {count} compiled messages, descriptor has {len(flat)}")
        else:
            for i in range(count):
                sym = syms.get(image.pointer(defaults + 8 * i))
                if sym is None or not sym.endswith("_default_instance_E"): continue
                stats["checked"] += 1
                if sym != default_instance_symbol(flat[i], package_of[flat[i]]):
                    problems.append(f"{name}: {file}[{i}] is {sym}, flattening says {flat[i]}")
        tables[address] = file
        return file

    # Every table defined here is proven up front, whether or not a local registration uses it:
    # other frameworks reach it through their GOT.
    for address, symbol in syms.items():
        if symbol.startswith("_descriptor_table_") and image.offset(address) is not None:
            table_at(address)

    # Function attribution from nm, not otool's labels. TSPRegistry's own methods forward to each
    # other (setUpgradeMessageType:… calls the 4-argument form); those calls are not registrations.
    functions = sorted((a, n) for a, n in syms.items() if n.startswith(("_", "-[", "+[")))
    starts = [a for a, _ in functions]

    def function_at(address):
        i = bisect.bisect_right(starts, address) - 1
        return functions[i][1] if i >= 0 else None

    def key(reg):
        """x3 and w3 are one register; xzr/wzr/sp are not tracked."""
        r = re.fullmatch(r"[xw](\d+)", reg)
        return r.group(1) if r else None

    regs = {}   # "n" -> ("addr", va) | ("imm", value) | ("table", file) | ("meta", file) | ("desc", (file, index))
    prototype = classname = None
    previous_function = None

    for line in otool("-tV", binary).splitlines():
        m = re.match(r"^([0-9a-f]{16})\s+(\S+)\s*(.*)$", line)
        if not m: continue
        address, mnemonic, operands = int(m.group(1), 16), m.group(2), m.group(3)
        function = function_at(address)
        if function != previous_function:
            regs.clear(); prototype = classname = None
            previous_function = function
        ops = [o.strip() for o in operands.split(";", 1)[0].split(",")]
        comment = operands.split(";", 1)[1].strip() if ";" in operands else ""
        dst = key(ops[0]) if ops and ops[0] else None

        if mnemonic == "bl":
            target = ops[0]
            callee = comment[len("symbol stub for: "):] if comment.startswith("symbol stub for: ") else target
            if callee.endswith("16default_instanceEv"):
                prototype = callee
            sel = stubs.get(int(target, 16)) if target.startswith("0x") else None
            kind = REGISTER_SELECTORS.get(sel)
            internal = (function or "").startswith("-[TSPRegistry ") and function != "-[TSPRegistry registerPersistenceMessages]"
            if kind is not None and not internal:
                where = f"{name} {function} @{address:#x}"
                t = regs.get("2")
                entry = {"kind": kind, "binary": name, "function": function}
                if classname: entry["unarchiveClassname"] = classname
                if not t or t[0] != "imm":
                    problems.append(f"{where}: {sel}: type in w2 not traced")
                else:
                    entry["type"] = t[1]
                    if kind in WITH_DESCRIPTOR:
                        desc = regs.get("4")
                        if not desc or desc[0] != "desc":
                            problems.append(f"{where}: type {t[1]}: descriptor in x4 not traced")
                        else:
                            file, index = desc[1]
                            messages = files.get(file)
                            if messages is None or index >= len(messages):
                                problems.append(f"{where}: type {t[1]}: {file} has no message {index}")
                            else:
                                entry["message"] = messages[index]
                                if prototype: entry["prototypeSymbol"] = demangle_default_instance(prototype)
                    found.append(entry)
                prototype = classname = None
            # A call clobbers the caller-saved registers (x0-x18, x30).
            for r in [r for r in regs if int(r) <= 18 or r == "30"]: regs.pop(r)
            continue

        if mnemonic == "adrp" and dst:
            a = re.match(r"0x([0-9a-f]+)", comment)
            regs[dst] = ("addr", int(a.group(1), 16)) if a else None
            if regs[dst] is None: regs.pop(dst)
            continue
        if mnemonic == "add" and dst and len(ops) == 3 and ops[2].startswith("#"):
            src = regs.get(key(ops[1]) or "")
            if src and src[0] == "addr":
                regs[dst] = ("addr", src[1] + int(ops[2][1:], 0))
            else:
                regs.pop(dst, None)
            if dst in ("4", "5") and 'literal pool for: "' in comment:
                classname = comment.split('literal pool for: "', 1)[1].rsplit('"', 1)[0]
            continue
        if mnemonic in ("mov", "movz", "orr") and dst:
            last = ops[-1]
            if last.startswith("#") and mnemonic != "orr" or (mnemonic == "orr" and ops[1] in ("wzr", "xzr")):
                v = int(last[1:], 0) if not last.startswith("#-") else None
                if v is None: regs.pop(dst, None)
                else: regs[dst] = ("imm", v)
            elif mnemonic == "mov" and key(last) is not None:
                if key(last) in regs: regs[dst] = regs[key(last)]
                else: regs.pop(dst, None)
            else:
                regs.pop(dst, None)
            continue
        if mnemonic == "movk" and dst:
            mk = re.match(r"#(0x[0-9a-f]+|\d+)(?:, lsl #(\d+))?", ", ".join(ops[1:]))
            src = regs.get(dst)
            if mk and src and src[0] == "imm":
                regs[dst] = ("imm", src[1] | int(mk.group(1), 0) << int(mk.group(2) or 0))
            else:
                regs.pop(dst, None)
            continue
        if mnemonic == "ldr" and dst:
            mm = re.match(r"\[(\w+)(?:, #(-?0x[0-9a-f]+|-?\d+))?\]$", ", ".join(ops[1:]))
            base = regs.get(key(mm.group(1)) or "") if mm else None
            off = int(mm.group(2), 0) if mm and mm.group(2) else 0
            if comment.startswith("literal pool symbol address: _descriptor_table_"):
                regs[dst] = ("table", table_file(comment.split(": ", 1)[1]))
            elif base and off == METADATA_OFFSET and base[0] == "table" and base[1] in files:
                regs[dst] = ("meta", base[1])
            elif base and off == METADATA_OFFSET and base[0] == "addr" and table_at(base[1]):
                regs[dst] = ("meta", table_at(base[1]))
            elif base and base[0] == "meta" and off % METADATA_STRIDE == 0:
                regs[dst] = ("desc", (base[1], off // METADATA_STRIDE))
            elif base and base[0] == "addr" and ops[0].startswith("w") and image.u32(base[1] + off) is not None:
                regs[dst] = ("imm", image.u32(base[1] + off))   # a uint32 constant, e.g. a type number
            else:
                regs.pop(dst, None)
            continue
        if dst and not mnemonic.startswith(("st", "cmp", "cmn", "tst", "b", "cb", "tb", "ret", "nop", "prfm")):
            regs.pop(dst, None)
    return found, problems


def check_symbol(entry, package_of):
    """A surviving `default_instance` symbol must name the descriptor's message:
    proto `TSCH.Generated.A.B` is C++ `TSCH::Generated::A_B`."""
    sym = entry.get("prototypeSymbol")
    if not sym: return None
    message = entry["message"]
    package = package_of[message]
    rest = message[len(package) + 1:] if package else message
    expected = "::".join(package.split(".") + [rest.replace(".", "_")]) if package else rest.replace(".", "_")
    return None if sym == expected else f"type {entry['type']}: descriptor says {message}, prototype symbol says {sym}"


def binaries(app):
    out = []
    macos = os.path.join(app, "Contents/MacOS")
    out += [os.path.join(macos, n) for n in sorted(os.listdir(macos))]
    fw = os.path.join(app, "Contents/Frameworks")
    for name in sorted(os.listdir(fw)):
        if not name.endswith(".framework"): continue
        base = name[:-len(".framework")]
        for candidate in (f"{name}/{base}", f"{name}/Versions/A/{base}"):
            path = os.path.join(fw, candidate)
            if os.path.isfile(path):
                out.append(os.path.realpath(path)); break
    return out


def main():
    args = sys.argv[1:]
    if len(args) != 4 or args[2] != "--out":
        sys.stderr.write(__doc__.split("\n\n")[1] + "\n"); sys.exit(2)
    app, descriptors, out = args[0], args[1], args[3]
    data = open(descriptors, "rb").read()
    files = files_in(data)
    package_of = {}
    for n, file in fields(data):
        if n != 1: continue
        fname = next(bytes(v).decode() for fn, v in fields(file) if fn == 1)
        pkg = next((bytes(v).decode() for fn, v in fields(file) if fn == 2), "")
        for msg in files[fname]: package_of[msg] = pkg
    info = plistlib.load(open(os.path.join(app, "Contents/Info.plist"), "rb"))

    entries, problems = [], []
    stats = {"checked": 0}
    for binary in binaries(app):
        f, p = registrations(binary, files, package_of, stats)
        entries += f; problems += p
    problems += [p for p in (check_symbol(e, package_of) for e in entries if "message" in e) if p]
    if problems:
        fail(f"{len(problems)} unreadable registration(s):\n  " + "\n  ".join(problems))
    if not entries:
        fail("no registrations found")

    # Resolve: an override replaces a plain registration of the same type. Two different messages
    # for one type under the same kind of call is an error, never a silent pick.
    by_kind = {}
    for e in entries:
        if e["kind"] not in WITH_DESCRIPTOR: continue
        key = (e["type"], e["kind"])
        if key in by_kind and by_kind[key]["message"] != e["message"]:
            fail(f"type {e['type']} has two {e['kind']} registrations: {by_kind[key]['message']} and {e['message']}")
        by_kind[key] = e
    types = {}
    for (t, kind), e in by_kind.items():
        if kind == "override" or (t, "override") not in by_kind:
            types[t] = e["message"]

    registry = {
        "keynoteVersion": info["CFBundleShortVersionString"],
        "keynoteBuild": info["CFBundleVersion"],
        "source": "Scripts/schema/registry-dump.py (static: arm64 TSPRegistry registration calls)",
        "types": {str(t): types[t] for t in sorted(types)},
        "deprecatedTypes": sorted({e["type"] for e in entries if e["kind"] == "deprecated"}),
        "registrations": sorted(
            ({k: e[k] for k in ("type", "kind", "message", "unarchiveClassname", "binary") if e.get(k) is not None}
             for e in entries),
            key=lambda e: (e["type"], e["kind"], e.get("message", ""))),
    }
    with open(out, "w") as fh:
        json.dump(registry, fh, indent=1)
        fh.write("\n")
    kinds = {}
    for e in entries: kinds[e["kind"]] = kinds.get(e["kind"], 0) + 1
    checked = sum(1 for e in entries if e.get("prototypeSymbol"))
    print(f"registry-dump: {len(types)} types ({', '.join(f'{v} {k}' for k, v in sorted(kinds.items()))}); "
          f"{checked} call sites and {stats['checked']} table slots cross-checked against surviving symbols -> {out}")


if __name__ == "__main__":
    main()
