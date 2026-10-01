# RF-BUDDY BT Category Browser Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task.

**Goal:** Replace the flat BT device list with a drill-down browser — BRANDS → TYPES → DEVICES → TRACK — with richer device classification and a fuller details panel. A goes down a level, B goes back up.

**Architecture:** Task 1 enriches decoding (`btsnoop.go`) and the tracker's device record (`bletracker.go`) with Brand / Type / Appearance / AddrType / FirstSeen, and adds pure grouping helpers. Task 2 rewrites the BT screens in `ui_bt.go` as a level-based browser on top of those helpers. The track screen (existing `renderBTTrack`) is kept as level 4.

**Tech Stack:** Go 1.21, stdlib + vendored golang.org/x/image only; MIPS softfloat target.

## Global Constraints

- Module dir: `pineapple-pager/src/user/defcon/RF-BUDDY/ui` (package `main`). Must pass: `go test -mod=vendor -race ./...`; `CGO_ENABLED=0 GOOS=linux GOARCH=mipsle GOMIPS=softfloat go vet -mod=vendor ./...`; `gofmt -l .` prints nothing; `bash pineapple-pager/tests/run_tests.sh` → ALL TESTS PASSED.
- No new Go dependencies, no cgo. Decoders never panic on malformed input.
- Screen 480x222, footer row at y=204, font inconsolata 8x16 ASCII only; all device text sanitized to printable ASCII and upper-cased. Text must never overlap or clip; verify by rendering previews (`--preview-dir`) and looking at the PNGs.
- Physical buttons: B = left/red, A = right/green. Footer: left hint B, two middle hints, right hint A.
- Wi-Fi tabs (2.4 / 5) behaviour is unchanged.

---

### Task 1: Richer classification + grouping helpers

**Files:** Modify `btsnoop.go`, `btsnoop_test.go`, `bletracker.go`, `bletracker_test.go`. Create `bt_groups.go`, `bt_groups_test.go`.

**Decoding additions (`parseAD` / `mfrKind`):**
- AD 0x19 Appearance (u16 LE) → `Advert.Appearance int` (-1 if absent). `AppearanceType(v int) string`: category = v >> 6. Exact table: 1 "PHONE", 2 "COMPUTER", 3 "WATCH", 4 "CLOCK", 5 "DISPLAY", 6 "REMOTE", 7 "GLASSES", 8 "TAG", 9 "KEYRING", 10 "MEDIA PLAYER", 11 "BARCODE SCANNER", 12 "THERMOMETER", 13 "HEART RATE", 14 "BLOOD PRESSURE", 15 "HID" (sub-values: 0x03C1 "KEYBOARD", 0x03C2 "MOUSE", 0x03C3 "JOYSTICK", 0x03C4 "GAMEPAD", 0x03C5 "TABLET"), 16 "GLUCOSE METER", 17 "RUNNING SENSOR", 18 "CYCLING SENSOR"; exact values 0x0940 "AUDIO", 0x0941 "EARBUD", 0x0942 "HEADSET", 0x0943 "HEADPHONES", 0x0944 "NECKBAND"; anything else → "".
- Apple (0x004C) manufacturer data is a sequence of TLVs `[type][len][data...]`. Walk all TLVs (bounds-checked) and pick the most specific kind by this priority (highest first): 0x07 "AIRPODS", 0x0B "WATCH", 0x12 "FIND MY", 0x02 "IBEACON", 0x05 "AIRDROP", 0x0C "HANDOFF", 0x0D "HOTSPOT", 0x0E "HOTSPOT", 0x06 "HOMEKIT", 0x08 "HEY SIRI", 0x09 "AIRPLAY", 0x0A "AIRPLAY", 0x0F "NEARBY ACTION", 0x10 "NEARBY". Keep existing tests passing (single-TLV cases).
- Microsoft (0x0006): d[0]==0x01 "WINDOWS", d[0]==0x03 "SWIFT PAIR".
- Service data 16-bit UUID (AD 0x16) and 16-bit service UUID lists (AD 0x02/0x03): 0xFEED or 0xFEEC → brand hint "TILE", kind "TRACKER"; 0xFD5A → brand hint "SAMSUNG", kind "SMARTTAG"; 0xFEAA → kind "EDDYSTONE"; 0xFE2C → kind "FAST PAIR" (brand hint "GOOGLE" only if no company id); 0xFD6F → "EXPOSURE NOTIF"; 0xFE9F → brand hint "GOOGLE". Add `Advert.BrandHint string`.
- Kind precedence (fixes earlier order-dependence): manufacturer-data kind > service kind > appearance type. Compute once after the AD walk.

**Tracker additions (`BLEDevice`):** `Brand string`, `Type string`, `Appearance string`, `FirstSeen time.Time`. Keep `Maker`, `Kind`, `Label`.
- Brand: `Maker` (CompanyName, but if it is an "ID xxxx" unknown id use "ID xxxx") → else BrandHint → else first word of Name if Name has ≥1 letter (e.g. "NANOLEAF STRIP FCE" → "NANOLEAF"; strip non-letters/digits at the ends) → else "UNKNOWN".
- Type: Kind → else Appearance → else "OTHER".
- Appearance sticky like Name; Kind/BrandHint sticky (last non-empty).
- Label rule unchanged except when Name is empty use `Brand + " " + Type` (Type "OTHER" → `Brand + " DEVICE"`; Brand "UNKNOWN" → "UNKNOWN " + first 8 addr chars).

**Grouping helpers (`bt_groups.go`), pure functions over `[]BLEDevice` (input already sorted strongest first):**
```go
type BTGroup struct {
	Name      string  // brand or type name
	Count     int
	Strongest int     // max RSSI in the group (-100 if none known)
	AdvPerSec float64 // sum
	Top       string  // Label of the strongest device
}
func GroupByBrand(devs []BLEDevice) []BTGroup            // sorted: Count desc, then Strongest desc, then Name asc; "UNKNOWN" always last
func GroupByType(devs []BLEDevice, brand string) []BTGroup // devices of that brand grouped by Type; same ordering, "OTHER" last
func DevicesOf(devs []BLEDevice, brand, typ string) []BLEDevice // filter, keeps input order
func TypeBreakdown(devs []BLEDevice, brand string, max int) string // e.g. "FIND MY 8, NEARBY 5, +3" — for the brand panel
```
Tests: real captured packets still decode; Apple multi-TLV (0x10 then 0x0C → "HANDOFF"; 0x12 alone → "FIND MY"; truncated TLV no panic); appearance table incl. keyboard/earbud/unknown; Tile/SmartTag/Eddystone via service data and via UUID list; brand derivation each branch; type fallback; grouping order incl. UNKNOWN/OTHER last; DevicesOf; TypeBreakdown with "+n". Commit `feat(rf-buddy): classify BLE devices by brand and type`.

---

### Task 2: Drill-down BT browser UI

**Files:** Modify `ui_bt.go`, `ui.go` (only where BT state/dispatch lives), `ui_test.go` (or `ui_bt_test.go`), `preview.go`, `tests/test_rf_buddy_go.sh` (preview count), `src/user/defcon/RF-BUDDY/README.md`.

**State:** `btLevel` (0 brands, 1 types, 2 devices, 3 track), `btBrand`, `btType`, `btAddr` (selection by name/addr so it survives re-sorting; fall back to index 0 when gone), plus per-level selected name for levels 0/1.

**Buttons:**
- Level 0 BRANDS: LEFT/RIGHT move selection; UP/DOWN switch tabs (as today); A → level 1 for the selected brand; B → exit payload.
- Level 1 TYPES: UP/LEFT previous, DOWN/RIGHT next; A → level 2; B → level 0 (selection restored to that brand).
- Level 2 DEVICES: UP/LEFT previous, DOWN/RIGHT next; A → `ctrl.TrackBT(addr)` → level 3; B → level 1.
- Level 3 TRACK: unchanged behaviour (B → `UntrackBT`, back to level 2; LEFT/RIGHT next/prev device within the same brand+type and re-track; UP audio; A mark spot).
- If the selected brand/type has no devices any more (all expired), show the empty-state text in that level; B still goes up.

**Layout (all levels share the tab header row: title, tabs "2.4 GHZ" "5 GHZ" "BT", the "n DEV m ADV/S" box, clock):**
- Row y=24: breadcrumb in dim/cyan: level 0 "BRANDS", level 1 "BRANDS > APPLE", level 2 "APPLE > FIND MY" (trim to fit the left column, keep the deepest part visible).
- Left column x 6..256, list rows 16 px from y 44, up to 9 rows, scroll to keep selection visible, selected row ">" + yellow. Level 0/1 rows: `NAME` left, `COUNT` right-aligned (e.g. "APPLE ........ 24"); level 2 rows: Label left, RSSI right coloured by signalColor ("--" when unknown).
- Divider x 260 cyan2. Right panel x 266..476:
  - Level 0 (brand panel): brand name (yellow), "DEVICES n", "STRONGEST -51 DBM", "ADV/S 37.2", "TOP" + label of strongest device (wrapped/trimmed), "TYPES" + TypeBreakdown (up to 2 lines).
  - Level 1 (type panel): "<BRAND> <TYPE>" (yellow), "DEVICES n", "STRONGEST", "ADV/S", "TOP" label, and if the type is a known kind a one-line plain-English hint from this table: AIRPODS "APPLE EARBUDS CASE/PODS", FIND MY "OFFLINE FINDING BEACON", NEARBY "IPHONE/IPAD/MAC NEARBY", HANDOFF "APPLE HANDOFF ACTIVITY", WATCH "APPLE WATCH", HOTSPOT "PERSONAL HOTSPOT", AIRDROP "AIRDROP SENDER", AIRPLAY "AIRPLAY SPEAKER/TV", HOMEKIT "HOMEKIT ACCESSORY", WINDOWS "WINDOWS PC NEARBY", SWIFT PAIR "PAIRING-MODE ACCESSORY", FAST PAIR "ANDROID FAST PAIR", TRACKER "ITEM TRACKER", SMARTTAG "SAMSUNG TRACKER", EDDYSTONE "BEACON", IBEACON "BEACON"; otherwise no hint line.
  - Level 2 (device details): Label (yellow) then metric rows (label x 266, value x 346, 16-cell value box): ADDR (short form as today), TYPE ("RANDOM"/"PUBLIC" addr type), MAKER (Brand), KIND (Type), NAME (or "--"), SIGNAL "%d DBM", PEAK "%d DBM", ADV/S "%.1f", TX PWR, SEEN "n S AGO", FIRST "15:04:05". If 11 rows do not fit between y 44 and 198, drop the label row and/or merge SIGNAL/PEAK into one row "SIGNAL -55 (PK -51)"; nothing may clip.
- Footers: level 0 `B EXIT | LEFT/RIGHT SEL | UP/DN BAND | A OPEN`; level 1 `B BACK | ARROWS SELECT | (blank) | A OPEN`; level 2 `B BACK | ARROWS SELECT | (blank) | A TRACK`; level 3 unchanged.
- `LiveBT()` true on all BT levels.

**Previews:** replace the BT overview preview cases with: brands (≥8 brands incl. UNKNOWN, scroll), types for APPLE, devices for APPLE/FIND MY (≥10, scroll), device details with a long name, empty type level; keep N/A, track, track-lost. Update the preview count assertion. Look at every BT PNG; fix overlaps before committing.

**Tests:** every button transition above incl. B chain 3→2→1→0→exit, selection survives re-sort at each level, fallback when the selected brand/type/addr disappears, LEFT/RIGHT on track stays within brand+type, Wi-Fi tab behaviour unchanged, render smoke tests for each level (empty and full). Commit `feat(rf-buddy): browse BT devices by brand and type`.
