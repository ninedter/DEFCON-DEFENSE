import gzip
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gen_btdb as g  # noqa: E402

COMPANIES = """# comment
company_identifiers:

  - value: 0x004C
    name: 'Apple, Inc.'

  - value: 0x0075
    name: 'Samsung Electronics Co., Ltd.'

  - value: 0x1234
    name: "O'Brien \\"Labs\\" GmbH"

  - value: 0x0501
    name: 'O''Brien Widgets Inc.'

  - value: 0x0502
    name: 'Shenzhen Wonderful Sound Technology Co., Ltd.'

  - value: 0x0503
    name: 'Shenzhen Technology Co., Ltd.'

  - value: 0x0504
    name: 'Bang & Olufsen A/S'
"""

MEMBERS = """uuids:
 - uuid: 0xFEFF
   name: GN Netcom
 - uuid: 0xFEED
   name: "Tile, Inc."
"""

SERVICES = """uuids:
 - uuid: 0x180D
   name: Heart Rate
   id: org.bluetooth.service.heart_rate
 - uuid: 0x1821
   name: Indoor Positioning Service Extended Name
   id: x
"""

APPEARANCE = """appearance_values:
 - category: 0x000
   name: Unknown
 - category: 0x002
   name: Computer
   subcategory:
    - value: 0x03
      name: Laptop
    - value: 0x04
      name: Handheld PC/PDA (clamshell)
 - category: 0x00F
   name: Human Interface Device
   subcategory:
    - value: 0x01
      name: Keyboard
"""

MANUF = (
    "# comment\n"
    "F8:FF:C2\tApple\tApple, Inc.\n"
    "00:00:0C\tCisco\tCisco Systems, Inc\n"
    "00:01:01\tPrivate\tPrivate\n"
    "00:50:C2:00:10:00/36\tFoo\tFoo Bar Ltd\n"
    "70:B3:D5\tIeeeRegi\tIEEE Registration Authority\n"
    "01:80:C2:00:00:00/48\tBridge\tBridge Filtered\n"
    "AA:BB:CC\tShort\n"
)


class Normalize(unittest.TestCase):
    def brand(self, name):
        return g.normalize_brand(name)[0]

    def test_overrides(self):
        for name, want in [
            ("Apple, Inc.", "APPLE"),
            ("Samsung Electronics Co., Ltd.", "SAMSUNG"),
            ("Texas Instruments Inc.", "TI"),
            ("GN Netcom A/S", "JABRA"),
            ("GN Hearing A/S", "GN HEARING"),
            ("Hewlett-Packard Company", "HP"),
            ("HP Inc.", "HP"),
            ("Bang & Olufsen A/S", "B AND O"),
            ("Beijing Xiaomi Mobile Software Co., Ltd", "XIAOMI"),
            ("LG Electronics", "LG"),
            ("Anhui Huami Information Technology Co., Ltd.", "AMAZFIT"),
        ]:
            self.assertEqual(self.brand(name), want, name)

    def test_override_is_word_boundary(self):
        self.assertNotEqual(self.brand("Intelligent Gadgets Ltd"), "INTEL")
        self.assertNotEqual(self.brand("LGBT Widgets"), "LG")

    def test_generic_two_words_and_trim(self):
        self.assertEqual(self.brand("Foo Bar Baz Corp."), "FOO BAR")
        self.assertEqual(self.brand("Supercalifragilisticexpialidocious Inc"), "SUPERCALIFRAGILI")
        self.assertLessEqual(len(self.brand("Abcdefghij Klmnopqrstu")), 16)

    def test_region_words(self):
        self.assertEqual(self.brand("Shenzhen Wonderful Sound Technology Co., Ltd."), "WONDERFUL SOUND")
        self.assertEqual(self.brand("Shenzhen Technology Co., Ltd."), "SHENZHEN")

    def test_multiword_legal(self):
        self.assertEqual(self.brand("Acme Widgets S.A."), "ACME WIDGETS")
        self.assertEqual(self.brand("Nokia L.L.C."), "NOKIA")
        self.assertEqual(self.brand("Foo B.V."), "FOO")

    def test_leading_the(self):
        self.assertEqual(self.brand("The Kroger Co."), "KROGER")
        self.assertEqual(self.brand("The Linux Foundation"), "LINUX FOUNDATION")
        self.assertEqual(g.normalize_brand("The Kroger Co.")[1], "KROGER")
        self.assertEqual(self.brand("The"), "THE")  # never drop the only word
        self.assertEqual(self.brand("Breathe The Air Inc"), "BREATHE THE")

    def test_ascii_and_empty(self):
        self.assertEqual(self.brand("Café Zeta"), "CAFE ZETA")
        self.assertEqual(g.normalize_brand("中文"), ("", ""))

    def test_full_cells(self):
        _, full = g.normalize_brand("Alpha Beta Gamma Delta Epsilon Zeta Eta")
        self.assertLessEqual(len(full), 26)


class Yaml(unittest.TestCase):
    def test_quotes(self):
        rows = dict(r.split("\t")[:2] for r in g.build_companies(COMPANIES))
        self.assertEqual(rows["004C"], "APPLE")
        self.assertEqual(rows["0501"], "O BRIEN")
        self.assertEqual(g.normalize_brand("O'Brien \"Labs\" GmbH")[1], "O BRIEN LABS")
        self.assertEqual(g.unquote("'O''Brien'"), "O'Brien")
        self.assertEqual(g.unquote('"a \\"b\\""'), 'a "b"')

    def test_sorted_and_hex(self):
        rows = g.build_companies(COMPANIES)
        keys = [r.split("\t")[0] for r in rows]
        self.assertEqual(keys, sorted(keys))
        self.assertTrue(all(len(k) == 4 for k in keys))

    def test_members(self):
        rows = dict(r.split("\t")[:2] for r in g.build_members(MEMBERS))
        self.assertEqual(rows, {"FEFF": "JABRA", "FEED": "TILE"})

    def test_services(self):
        rows = dict(r.split("\t") for r in g.build_services(SERVICES))
        self.assertEqual(rows["180D"], "HEART RATE")
        self.assertLessEqual(len(rows["1821"]), 20)

    def test_appearance(self):
        rows = dict(r.split("\t") for r in g.build_appearance(APPEARANCE))
        self.assertEqual(rows["0000"], "UNKNOWN")
        self.assertEqual(rows["0080"], "COMPUTER")
        self.assertEqual(rows["0083"], "LAPTOP")
        self.assertEqual(rows["03C0"], "HUMAN INTERFACE")
        self.assertEqual(rows["03C1"], "KEYBOARD")
        self.assertTrue(all(len(v) <= 16 for v in rows.values()))
        self.assertEqual(rows["0084"], "HANDHELD PC PDA")


class OUI(unittest.TestCase):
    def test_oui(self):
        rows = dict(r.split("\t") for r in g.build_oui(MANUF))
        self.assertEqual(rows["F8FFC2"], "APPLE")
        self.assertEqual(rows["00000C"], "CISCO")
        self.assertEqual(rows["AABBCC"], "SHORT")
        for bad in ("000101", "70B3D5", "0050C2", "0180C2"):
            self.assertNotIn(bad, rows)


class Output(unittest.TestCase):
    def test_deterministic_gzip(self):
        with tempfile.TemporaryDirectory() as d:
            a, b = os.path.join(d, "a.gz"), os.path.join(d, "b.gz")
            rows = ["0001\tX", "0002\tY"]
            g.write_gz(a, rows)
            g.write_gz(b, rows)
            with open(a, "rb") as fa, open(b, "rb") as fb:
                self.assertEqual(fa.read(), fb.read())
            self.assertEqual(gzip.open(a, "rt").read(), "0001\tX\n0002\tY\n")

    def test_generate(self):
        with tempfile.TemporaryDirectory() as d:
            src, out = os.path.join(d, "s"), os.path.join(d, "o")
            os.mkdir(src)
            for name, text in [("company_identifiers.yaml", COMPANIES), ("member_uuids.yaml", MEMBERS),
                               ("service_uuids.yaml", SERVICES), ("appearance_values.yaml", APPEARANCE),
                               ("manuf", MANUF)]:
                with open(os.path.join(src, name), "w") as f:
                    f.write(text)
            with open(os.devnull, "w") as devnull:
                old, sys.stdout = sys.stdout, devnull
                try:
                    g.main(["--src", src, "--out", out])
                finally:
                    sys.stdout = old
            self.assertEqual(sorted(os.listdir(out)), ["appearance.tsv.gz", "companies.tsv.gz", "members.tsv.gz",
                                                       "oui.tsv.gz", "services.tsv.gz"])


if __name__ == "__main__":
    unittest.main()
