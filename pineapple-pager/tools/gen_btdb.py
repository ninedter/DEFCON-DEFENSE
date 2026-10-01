#!/usr/bin/env python3
"""Generate the RF-BUDDY Bluetooth identification tables (gzip'd TSV).

Inputs (in --src DIR): company_identifiers.yaml, member_uuids.yaml,
service_uuids.yaml, appearance_values.yaml (Bluetooth SIG assigned numbers)
and manuf (Wireshark's IEEE OUI registry).  Stdlib only; output is
deterministic (sorted rows, gzip mtime=0).

  python3 tools/gen_btdb.py --download --src /tmp/btsrc \
      --out src/user/defcon/RF-BUDDY/ui/btdb
"""
import argparse
import gzip
import os
import re
import sys
import unicodedata
import urllib.request

SIG = "https://bitbucket.org/bluetooth-SIG/public/raw/main/assigned_numbers/"
SOURCES = {
    "company_identifiers.yaml": SIG + "company_identifiers/company_identifiers.yaml",
    "member_uuids.yaml": SIG + "uuids/member_uuids.yaml",
    "service_uuids.yaml": SIG + "uuids/service_uuids.yaml",
    "appearance_values.yaml": SIG + "core/appearance_values.yaml",
    "manuf": "https://www.wireshark.org/download/automated/data/manuf",
}

BRAND_CELLS = 16
FULL_CELLS = 26
SERVICE_CELLS = 20
APPEARANCE_CELLS = 16

LEGAL_WORDS = set("""INC INCORPORATED LLC LTD LIMITED CO COMPANY CORP CORPORATION
GMBH AG SA AB AS BV NV PLC PTY SRL SPA KK OY OYJ SAS SARL ASA APS SE LTDA GROUP
HOLDINGS INTERNATIONAL TECHNOLOGY TECHNOLOGIES ELECTRONICS ELECTRONIC ELECTRIC
INDUSTRIAL INDUSTRIES SEMICONDUCTOR SYSTEMS COMMUNICATIONS MOBILE""".split())
# Multi-word legal suffixes (the punctuation split leaves single letters).
LEGAL_SEQS = [["L", "L", "C"], ["S", "A"], ["A", "S"], ["B", "V"], ["S", "P", "A"]]
REGION_WORDS = set("""SHENZHEN GUANGDONG DONGGUAN HANGZHOU SHANGHAI BEIJING ZHUHAI
XIAMEN SUZHOU""".split())

# (normalized prefix, brand); first match wins, matched on word boundaries.
OVERRIDES = [
    ("APPLE", "APPLE"), ("SAMSUNG", "SAMSUNG"), ("GOOGLE", "GOOGLE"),
    ("MICROSOFT", "MICROSOFT"), ("SONY", "SONY"), ("BOSE", "BOSE"),
    ("HARMAN", "HARMAN JBL"), ("LOGITECH", "LOGITECH"), ("GARMIN", "GARMIN"),
    ("FITBIT", "FITBIT"), ("HUAWEI", "HUAWEI"), ("XIAOMI", "XIAOMI"),
    ("BEIJING XIAOMI", "XIAOMI"), ("ANHUI HUAMI", "AMAZFIT"), ("AMAZON", "AMAZON"), ("LG", "LG"),
    ("LENOVO", "LENOVO"), ("DELL", "DELL"), ("HEWLETT PACKARD", "HP"),
    ("HP", "HP"), ("INTEL", "INTEL"), ("QUALCOMM", "QUALCOMM"),
    ("BROADCOM", "BROADCOM"), ("REALTEK", "REALTEK"), ("MEDIATEK", "MEDIATEK"),
    ("NORDIC", "NORDIC"), ("ESPRESSIF", "ESPRESSIF"),
    ("TEXAS INSTRUMENTS", "TI"), ("PHILIPS", "PHILIPS"), ("SIGNIFY", "PHILIPS"),
    ("TILE", "TILE"), ("BEATS", "BEATS"), ("JABRA", "JABRA"),
    ("GN NETCOM", "JABRA"), ("GN AUDIO", "JABRA"), ("GN HEARING", "GN HEARING"),
    ("SENNHEISER", "SENNHEISER"), ("SONOS", "SONOS"), ("ONEPLUS", "ONEPLUS"),
    ("OPPO", "OPPO"), ("VIVO", "VIVO"), ("MOTOROLA", "MOTOROLA"),
    ("NINTENDO", "NINTENDO"), ("TESLA", "TESLA"), ("POLAR", "POLAR"),
    ("SUUNTO", "SUUNTO"), ("WHOOP", "WHOOP"), ("OURA", "OURA"),
    ("ANKER", "ANKER"), ("CHIPOLO", "CHIPOLO"), ("NANOLEAF", "NANOLEAF"),
    ("ROKU", "ROKU"), ("META", "META"), ("FACEBOOK", "META"), ("NIKE", "NIKE"),
    ("PELOTON", "PELOTON"), ("BANG AND OLUFSEN", "B AND O"),
    ("SKULLCANDY", "SKULLCANDY"), ("PLANTRONICS", "POLY"), ("POLY", "POLY"),
]


def ascii_fold(s):
    s = unicodedata.normalize("NFKD", s)
    return s.encode("ascii", "ignore").decode("ascii")


def base_words(name):
    """Brand normalization step 1: upper-case ASCII words."""
    s = ascii_fold(name).upper().replace("&", " AND ")
    s = re.sub(r"[^A-Z0-9 ]", " ", s)
    return s.split()


def drop_legal(words):
    """Step 2: remove legal / boilerplate words (never everything)."""
    out = []
    i = 0
    while i < len(words):
        hit = 0
        for seq in LEGAL_SEQS:
            n = len(seq)
            if words[i:i + n] == seq and (len(words) > n or out):
                hit = n
                break
        if hit:
            i += hit
            continue
        if words[i] in LEGAL_WORDS:
            i += 1
            continue
        out.append(words[i])
        i += 1
    if not out:
        return list(words)
    kept = [w for w in out if w not in REGION_WORDS]
    return kept if kept else out


def trim_words(words, cells):
    """Join words, trimmed to `cells` at a word boundary (hard-trim one word)."""
    out = ""
    for w in words:
        cand = w if not out else out + " " + w
        if len(cand) > cells:
            break
        out = cand
    if not out and words:
        out = words[0][:cells]
    return out


def has_prefix(words, prefix):
    p = prefix.split()
    return words[:len(p)] == p


def normalize_brand(name):
    """Return (brand, full) or ("", "") when nothing printable remains."""
    words = drop_legal(base_words(name))
    if len(words) > 1 and words[0] == "THE":
        words = words[1:]  # "The Kroger" -> "KROGER"
    if not words:
        return "", ""
    full = trim_words(words, FULL_CELLS)
    for prefix, brand in OVERRIDES:
        if has_prefix(words, prefix):
            return brand, full
    return trim_words(words[:2], BRAND_CELLS), full


def short_name(name, cells):
    """Upper-case ASCII label for services / appearance values."""
    words = base_words(name)
    return trim_words(words, cells)


def unquote(v):
    v = v.strip()
    if len(v) >= 2 and v[0] == "'" and v[-1] == "'":
        return v[1:-1].replace("''", "'")
    if len(v) >= 2 and v[0] == '"' and v[-1] == '"':
        return re.sub(r"\\(.)", r"\1", v[1:-1])
    return v


KV = re.compile(r"^\s*(?:-\s+)?([A-Za-z_]+):\s*(.*?)\s*$")


def yaml_items(text):
    """Yield dicts for simple `- key: v` list items. A new item starts at a
    line beginning with `- `; sub-lists (subcategory) are returned separately
    through the special key '_sub' as a list of dicts."""
    items = []
    cur = None
    sub = None
    for line in text.splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        m = KV.match(line)
        if not m:
            continue
        indent = len(line) - len(line.lstrip())
        key, val = m.group(1), m.group(2)
        is_item = line.lstrip().startswith("- ")
        if key == "subcategory" and cur is not None:
            sub = cur.setdefault("_sub", [])
            continue
        if is_item and sub is not None and cur is not None and indent > cur["_indent"]:
            sub.append({key: unquote(val)})
            continue
        if is_item:
            cur = {"_indent": indent, key: unquote(val)}
            sub = None
            items.append(cur)
            continue
        if sub is not None and cur is not None and indent > cur["_indent"] + 2 and sub:
            sub[-1][key] = unquote(val)
        elif cur is not None:
            cur[key] = unquote(val)
    return items


def parse_int(s):
    try:
        return int(s, 0)
    except (TypeError, ValueError):
        return None


def build_companies(text, key="value", width=4):
    rows = {}
    for it in yaml_items(text):
        v = parse_int(it.get(key))
        name = it.get("name", "")
        if v is None or v < 0 or v > 0xFFFF:
            continue
        brand, full = normalize_brand(name)
        if not brand:
            continue
        rows.setdefault("%0*X" % (width, v), (brand, full))
    return ["%s\t%s\t%s" % (k, b, f) for k, (b, f) in sorted(rows.items())]


def build_members(text):
    return build_companies(text, key="uuid")


def build_services(text):
    rows = {}
    for it in yaml_items(text):
        v = parse_int(it.get("uuid"))
        name = short_name(it.get("name", ""), SERVICE_CELLS)
        if v is None or v < 0 or v > 0xFFFF or not name:
            continue
        rows.setdefault("%04X" % v, name)
    return ["%s\t%s" % kv for kv in sorted(rows.items())]


def build_appearance(text):
    rows = {}
    for it in yaml_items(text):
        cat = parse_int(it.get("category"))
        if cat is None or cat < 0 or cat > 0x3FF:
            continue
        name = short_name(it.get("name", ""), APPEARANCE_CELLS)
        if name:
            rows.setdefault(cat << 6, name)
        for s in it.get("_sub", []):
            sv = parse_int(s.get("value"))
            sn = short_name(s.get("name", ""), APPEARANCE_CELLS)
            if sv is not None and 0 <= sv < 64 and sn:
                rows.setdefault((cat << 6) | sv, sn)
    return ["%04X\t%s" % kv for kv in sorted(rows.items())]


PREFIX24 = re.compile(r"^([0-9A-Fa-f]{2}):([0-9A-Fa-f]{2}):([0-9A-Fa-f]{2})$")


def build_oui(text):
    rows = {}
    for line in text.splitlines():
        if not line or line.startswith("#"):
            continue
        f = line.split("\t")
        if len(f) < 2:
            continue
        m = PREFIX24.match(f[0].strip())
        if not m:
            continue
        name = f[2].strip() if len(f) > 2 and f[2].strip() else f[1].strip()
        words = base_words(name)
        if not words or words[0] in ("PRIVATE", "IEEE"):
            continue
        brand, _ = normalize_brand(name)
        if not brand:
            continue
        rows.setdefault("".join(m.groups()).upper(), brand)
    return ["%s\t%s" % kv for kv in sorted(rows.items())]


def write_gz(path, rows):
    data = ("\n".join(rows) + "\n").encode("ascii")
    with open(path, "wb") as raw:
        with gzip.GzipFile(filename="", mode="wb", fileobj=raw,
                           compresslevel=9, mtime=0) as gz:
            gz.write(data)


def read(src, name):
    with open(os.path.join(src, name), "r", encoding="utf-8", errors="replace") as f:
        return f.read()


def download(src):
    os.makedirs(src, exist_ok=True)
    for name, url in SOURCES.items():
        req = urllib.request.Request(url, headers={"User-Agent": "gen_btdb/1.0 (RF-BUDDY)"})
        with urllib.request.urlopen(req, timeout=60) as r:
            data = r.read()
        with open(os.path.join(src, name), "wb") as f:
            f.write(data)
        print("downloaded %s (%d bytes)" % (name, len(data)))


def generate(src, out):
    os.makedirs(out, exist_ok=True)
    tables = [
        ("companies.tsv.gz", build_companies(read(src, "company_identifiers.yaml"))),
        ("members.tsv.gz", build_members(read(src, "member_uuids.yaml"))),
        ("services.tsv.gz", build_services(read(src, "service_uuids.yaml"))),
        ("appearance.tsv.gz", build_appearance(read(src, "appearance_values.yaml"))),
        ("oui.tsv.gz", build_oui(read(src, "manuf"))),
    ]
    for name, rows in tables:
        write_gz(os.path.join(out, name), rows)
        print("%-18s %6d rows %8d bytes" % (name, len(rows), os.path.getsize(os.path.join(out, name))))


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--src", required=True, help="directory holding the source files")
    ap.add_argument("--out", required=True, help="output directory (ui/btdb)")
    ap.add_argument("--download", action="store_true", help="fetch the sources into --src first")
    a = ap.parse_args(argv)
    if a.download:
        download(a.src)
    generate(a.src, a.out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
