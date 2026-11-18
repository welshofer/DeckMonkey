#!/usr/bin/env python3
"""Portable CLI acceptance, using only Python's standard library and synthetic data.

Run after swift build --product deckmonkey. --work preserves the example decks,
previews and raw command results locally; no Keynote app or cloud service is used.
"""
import argparse
import json
from pathlib import Path
import struct
import subprocess
import tempfile
import unittest
import xml.etree.ElementTree as ET
import zipfile
import zlib


class InterchangeCLI(unittest.TestCase):
    executable = None
    work = None

    def setUp(self):
        self.directory = self.work / self._testMethodName
        self.directory.mkdir()
        self.input = self.directory / "input.keyx"
        self.main = b"""{
 "slides": [{"identifier":"one","note":{"string":"Before"},
 "contents":[{"object":{"textbox":{"geometry":{"position":{"x":20,"y":20},
 "size":{"width":500,"height":120}},"text":{"text_runs":[
 {"string":"Styled ","style":{"bold":true,"vendor_style":7}},{"string":"words"}]}}}}],
 "vendor":{"huge":9007199254740993123456789,"precise":1.23000000000000000000000001e+7}}],
 "unknown":{"enabled":true}
}"""
        self.entries = {
            "main.json": self.main,
            "manifest.json": b'{ "package_version":"1.0", "vendor":true }\n',
            "presets.json": b" [ ] \n",
            "Data/opaque.bin": bytes([0, 1, 255]),
            "vendor/metadata": b"keep extension bytes\n",
        }
        self.write_archive(self.input, self.entries)

    @staticmethod
    def write_archive(path, entries):
        with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
            for name, data in entries.items():
                archive.writestr(name, data)

    @staticmethod
    def read_archive(path):
        with zipfile.ZipFile(path) as archive:
            return {name: archive.read(name) for name in archive.namelist()}

    def run_cli(self, *args, expected=0, json_result=True):
        command = [str(self.executable), *map(str, args)]
        result = subprocess.run(command, capture_output=True, text=True, timeout=60, check=False)
        with (self.work / "commands.jsonl").open("a", encoding="utf-8") as log:
            log.write(json.dumps({"command": command, "exitCode": result.returncode,
                                  "stdout": result.stdout, "stderr": result.stderr}) + "\n")
        self.assertEqual(result.returncode, expected, result.stderr + result.stdout)
        if not json_result:
            return result
        report = json.loads(result.stdout)
        self.assertEqual(report["format"], "keyx")
        return report

    def test_roundtrip_and_surgical_notes(self):
        output = self.directory / "roundtrip.keyx"
        report = self.run_cli("keyx", "roundtrip", self.input, "-o", output)
        self.assertEqual(report["status"], "CLEAN")
        self.assertEqual(self.read_archive(output), self.entries)
        edited = self.directory / "edited.keyx"
        self.run_cli("keyx", "notes", self.input, "--slide", 0, "--text", 'After\n"quoted" \U0001f600', "-o", edited)
        after = self.read_archive(edited)
        for name in self.entries.keys() - {"main.json"}:
            self.assertEqual(after[name], self.entries[name])
        before_json = json.loads(self.main)
        after_json = json.loads(after["main.json"])
        expected = json.loads(self.main)
        expected["slides"][0]["note"] = {
            "type_identifier": "com.apple.apps.content-language.text",
            "string": 'After\n"quoted" \U0001f600',
        }
        self.assertEqual(after_json, expected)
        self.assertIn(b"1.23000000000000000000000001e+7", after["main.json"])
        self.assertIn(b"9007199254740993123456789", after["main.json"])
        inspected = self.run_cli("keyx", "inspect", edited)
        self.assertIn("Styled words", inspected["slides"][0]["texts"])
        self.assertEqual(inspected["slides"][0]["notes"], 'After\n"quoted" \U0001f600')
        removed = self.directory / "removed.keyx"
        self.run_cli("keyx", "notes", edited, "--slide", 0, "--remove", "-o", removed)
        removed_slide = json.loads(self.read_archive(removed)["main.json"])["slides"][0]
        self.assertNotIn("note", removed_slide)
        self.assertEqual(removed_slide["contents"], before_json["slides"][0]["contents"])

    def test_missing_optional_entries(self):
        self.write_archive(self.input, {"main.json": self.main})
        output = self.directory / "defaults.keyx"
        report = self.run_cli("keyx", "roundtrip", self.input, "-o", output)
        self.assertEqual(report["status"], "PRESERVED")
        self.assertEqual(report["added"], ["manifest.json", "presets.json"])
        self.assertEqual(self.read_archive(output)["main.json"], self.main)

    def test_author_inspect_preview_and_template(self):
        ir = {
            "irVersion": "lectern.deck/1",
            "meta": {"title": "DeckMonkey interchange"},
            "slides": [
                {"id": "intro", "layout": "bullets", "title": "Direct Keynote Interchange",
                 "body": {"bullets": [{"text": "Editable text, no intermediate deck"},
                                      {"text": "Native .key remains a separate backend"}]},
                 "notes": "Synthetic DeckMonkey CLI acceptance example."},
                {"id": "table", "layout": "table", "title": "Editable table",
                 "body": {"table": {"headers": ["Stage", "Count"], "rows": [["Read", "2"], ["Write", "5"]]}}},
                {"id": "chart", "layout": "chart", "title": "Numeric chart",
                 "body": {"chart": {"kind": "line", "categories": ["Q1", "Q2"],
                                    "series": [{"name": "Count", "values": [2, 5]}]}}},
                {"id": "image", "layout": "imageLeft", "title": "Local image resource",
                 "body": {"bullets": [{"text": "Generated test pixels; no Apple artwork"}]}},
            ],
        }
        source = self.directory / "deck.json"
        source.write_text(json.dumps(ir), encoding="utf-8")
        image = self.directory / "pixels.png"

        def chunk(name, data):
            return struct.pack(">I", len(data)) + name + data + struct.pack(">I", zlib.crc32(name + data) & 0xFFFFFFFF)

        image.write_bytes(b"\x89PNG\r\n\x1a\n"
                          + chunk(b"IHDR", struct.pack(">IIBBBBB", 2, 2, 8, 2, 0, 0, 0))
                          + chunk(b"IDAT", zlib.compress(b"\0\x27\x6d\x89\xff\xff\xff\0\xff\xff\xff\x27\x6d\x89"))
                          + chunk(b"IEND", b""))
        output = self.directory / "authored.keyx"
        authored = self.run_cli("keyx", "from-ir", source, "--image", f"image={image}", "-o", output)
        self.assertEqual(authored["slideCount"], 4)
        self.assertTrue(authored["warnings"])
        self.assertEqual(set(authored["slideGroups"]), {"intro", "table", "chart", "image"})
        entries = self.read_archive(output)
        self.assertTrue({"main.json", "manifest.json", "presets.json"} <= entries.keys())
        self.assertFalse(any(name.startswith(("ppt/", "Index/")) for name in entries))
        inspection = self.run_cli("keyx", "inspect", output)
        slides = inspection["slides"]
        self.assertIn("Editable text, no intermediate deck", "\n".join(slides[0]["texts"]))
        self.assertEqual(slides[0]["notes"], ir["slides"][0]["notes"])
        self.assertEqual(slides[1]["tables"], [[["Stage", "Count"], ["Read", "2"], ["Write", "5"]]])
        self.assertEqual(slides[2]["charts"][0]["values"], [[2, 5]])
        self.assertEqual(slides[2]["charts"][0]["categories"], ["Q1", "Q2"])
        self.assertEqual(slides[3]["resources"][0]["bytes"], len(image.read_bytes()))
        self.assertTrue(self.run_cli("keyx", "verify", output)["valid"])
        preview = self.directory / "preview"
        report = self.run_cli("keyx", "render", output, "-o", preview)
        self.assertTrue(report["approximate"])
        self.assertEqual(len(report["slides"]), 4)
        self.assertEqual(json.loads((preview / "render.json").read_text()), report)
        for slide in report["slides"]:
            self.assertTrue(slide["warnings"])
            self.assertEqual(ET.parse(preview / slide["file"]).getroot().tag, "{http://www.w3.org/2000/svg}svg")
        self.assertIn("data:image/png;base64,", (preview / "page-4.svg").read_text())
        selected = self.run_cli("keyx", "inspect", output, "--slide", 2)
        self.assertEqual([slide["index"] for slide in selected["slides"]], [2])
        from_template = self.directory / "from-template.keyx"
        self.run_cli("keyx", "from-ir", source, "--template", output, "-o", from_template)
        self.assertEqual(json.loads(self.read_archive(from_template)["main.json"])["theme"],
                         json.loads(entries["main.json"])["theme"])
        self.assertTrue(self.run_cli("keyx", "verify", from_template)["valid"])

    def test_refusals_and_strict_options(self):
        output = self.directory / "should-not-exist.keyx"
        native = self.directory / "not-interchange.key"
        for args, code in [
            (["keyx", "notes", self.input, "--slide", 0, "--text", "No", "-o", native], 3),
            (["keyx", "inspect", native], 3),
            (["inspect", self.input], 3),
            (["roundtrip", self.input, "-o", native], 3),
            (["from-ir", "not-read.json", "-o", output], 3),
            (["keyx", "convert", self.input, "-o", native], 3),
            (["keyx", "render", self.input, "--stages", "-o", self.directory / "no-preview"], 3),
            (["keyx", "inspect", self.input, "--slide", -1], 1),
            (["keyx", "inspect", self.input, "--slide", 99], 1),
            (["keyx", "inspect", self.input, "--slide", "bad"], 2),
            (["keyx", "inspect", self.input, "--slide"], 2),
            (["keyx", "inspect", self.input, "--slide", 0, "--slide", 0], 2),
            (["keyx", "inspect", self.input, "--unknown"], 2),
            (["keyx", "notes", self.input, "--slide", 0, "--text", "No", "--remove", "-o", output], 2),
        ]:
            with self.subTest(args=args):
                result = self.run_cli(*args, expected=code, json_result=False)
                self.assertTrue(result.stderr)
                self.assertFalse(output.exists())
                self.assertFalse(native.exists())
        self.assertFalse((self.directory / "no-preview").exists())
        source = self.directory / "unsupported.json"
        source.write_text(json.dumps({"meta": {"title": "Refuse"}, "slides": [
            {"id": "bad", "layout": "unsupported-layout", "title": "Do not silently approximate"}
        ]}), encoding="utf-8")
        result = self.run_cli("keyx", "from-ir", source, "-o", output, expected=3, json_result=False)
        self.assertIn("Unsupported authoring layout", result.stderr)
        self.assertFalse(output.exists())

    def test_invalid_document_does_not_replace_output(self):
        invalid = json.loads(self.main)
        invalid["slides"].append(invalid["slides"][0])
        self.entries["main.json"] = json.dumps(invalid).encode()
        self.write_archive(self.input, self.entries)
        report = self.run_cli("keyx", "verify", self.input, expected=1)
        self.assertFalse(report["valid"])
        self.assertTrue(any("Duplicate identifier" in issue["message"] for issue in report["diagnostics"]))
        output = self.directory / "protected.keyx"
        output.write_bytes(b"do not replace")
        self.run_cli("keyx", "notes", self.input, "--slide", 0, "--text", "No", "-o", output,
                     expected=1, json_result=False)
        self.assertEqual(output.read_bytes(), b"do not replace")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--deckmonkey", default=".build/debug/deckmonkey")
    parser.add_argument("--work", type=Path, help="new directory for retained local acceptance artifacts")
    args = parser.parse_args()
    InterchangeCLI.executable = Path(args.deckmonkey).resolve()
    if not InterchangeCLI.executable.is_file():
        parser.error("build deckmonkey before running this check")
    with tempfile.TemporaryDirectory(prefix="deckmonkey-keyx-check-") as temporary:
        if args.work:
            args.work.mkdir(parents=True, exist_ok=False)
        InterchangeCLI.work = args.work.resolve() if args.work else Path(temporary)
        suite = unittest.defaultTestLoader.loadTestsFromTestCase(InterchangeCLI)
        result = unittest.TextTestRunner(verbosity=2).run(suite)
        return 0 if result.wasSuccessful() else 1


if __name__ == "__main__":
    raise SystemExit(main())
