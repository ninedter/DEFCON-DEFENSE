# RF-BUDDY Bluetooth View + Track Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task.

**Goal:** Give RF-BUDDY a third tab, BT, that lists nearby BLE devices with per-device details, and a TRACK mode that turns one device's signal strength into a walk-around proximity meter.

**Architecture:** The existing passive `hcitool lescan` keeps the controller scanning. A second child process, `hcidump -i <iface> -w /dev/stdout`, streams btsnoop records unbuffered; Go decodes LE Advertising Reports into `Advert`s and feeds a `BLETracker`. The tracker replaces `BLECounter`, keeps per-device state, and publishes into `Snapshot`. The UI gets a tab model (2.4 / 5 / BT), a BT overview screen and a BT track screen.

**Tech Stack:** Go 1.21, stdlib only (plus already-vendored golang.org/x/image), MIPS softfloat target, busybox device.

## Global Constraints

- Module dir: `pineapple-pager/src/user/defcon/RF-BUDDY/ui` (package `main`). Tests: `go test -mod=vendor -race ./...`; MIPS vet: `CGO_ENABLED=0 GOOS=linux GOARCH=mipsle GOMIPS=softfloat go vet -mod=vendor ./...`; gofmt clean. Full repo suite: `bash pineapple-pager/tests/run_tests.sh`.
- No new Go dependencies. No cgo.
- Screen is 480x222; footer row starts at y=204; font is inconsolata 8x16 (ASCII only). All device-provided text shown on screen must be sanitized to printable ASCII 0x20-0x7E and upper-cased.
- Physical buttons: B = left/red = exit/back, A = right/green = action. Footer layout: left hint B, two middle hints, right hint A (existing `renderFooter`).
- RF-BUDDY must stay independent of DEFCON Defense (no shared ports/files/processes). Never `killall` hcidump/hcitool; only signal our own children.
- BLE advertising channels 37/38/39 = 2402/2426/2480 MHz. A Wi-Fi 2.4 GHz channel n (n=1..13 centre 2407+5n MHz; n=14 centre 2484) is hit when `|centre - f| <= 10` for any of the three frequencies. That yields channels 1, 2, 3, 4, 5, 13, 14, formatted as "1-5, 13-14". Compute it with the formula in code (`HitsWiFi() []int`), and assert the list in tests.
- Devices expire after 30 s without an advert. "Signal lost" in track mode after 5 s without an advert.

---

### Task 1: Advert decoding and BLETracker (pure logic)

**Files:**
- Create: `btsnoop.go`, `btsnoop_test.go` (btsnoop stream reader + HCI LE advert decoding + AD parsing + labels)
- Create: `bletracker.go`, `bletracker_test.go`
- Modify: nothing else (BLECounter stays until Task 2)

**Interfaces produced:**

```go
type Advert struct {
	Addr    string // "AA:BB:CC:DD:EE:FF" upper-case, display order (reverse of wire order)
	Random  bool   // address type != 0
	RSSI    int    // dBm, signed int8 from the report
	Name    string // AD 0x09 complete or 0x08 shortened local name, sanitized; "" if absent
	TxPower int
	HasTx   bool   // AD 0x0A present
	Company int    // AD 0xFF first two bytes little-endian; -1 if absent
	Kind    string // short device-type hint, e.g. "AIRPODS", "" if unknown
}

// ReadBTSnoop reads a btsnoop stream (16-byte header "btsnoop\0" + version + datalink,
// then records: orig len u32, incl len u32, flags u32, drops u32, ts u64, data[incl])
// big-endian, and calls fn for every LE Advertising Report entry found. Datalink 1002
// (H4: first data byte is the packet type, 0x04 = event) and 1001 (no type byte, flags bit 1
// = command/event) must both work. Returns the reader error (io.EOF -> nil).
func ReadBTSnoop(r io.Reader, fn func(Advert)) error

// ParseLEAdvertEvent decodes one HCI event packet (starting at the event code byte, i.e. after
// the H4 type byte): event 0x3E, subevent 0x02 (legacy LE Advertising Report, possibly several
// reports: num_reports, then per report event_type, addr_type, addr[6], data_len, data, rssi) and
// subevent 0x0D (LE Extended Advertising Report: per report event_type u16, addr_type, addr[6],
// primary_phy, secondary_phy, sid, tx_power i8, rssi i8, interval u16, direct_addr_type,
// direct_addr[6], data_len, data). Malformed / truncated input returns nil, never panics.
func ParseLEAdvertEvent(pkt []byte) []Advert

func CompanyName(id int) string // exactly this table: 0x004C APPLE, 0x0006 MICROSOFT, 0x0075 SAMSUNG,
	// 0x00E0 GOOGLE, 0x0087 GARMIN, 0x0157 HUAWEI, 0x038F XIAOMI, 0x0059 NORDIC, 0x000F BROADCOM,
	// 0x02E5 ESPRESSIF, 0x0171 AMAZON, 0x009E BOSE;
	// unknown id -> fmt.Sprintf("ID %04X", id); id < 0 -> ""

type BLEDevice struct {
	Addr      string
	Random    bool
	Label     string  // see labelling rule below
	Maker     string  // CompanyName(Company) or ""
	Kind      string
	Name      string  // sticky: last non-empty name seen
	RSSI      int     // smoothed: mean of adverts in the last 2 s; if none, last value
	Peak      int     // strongest RSSI seen since first seen
	AdvPerSec float64 // adverts in the last 10 s / 10 (or / age if younger, min 1 s)
	TxPower   int
	HasTx     bool
	LastSeen  time.Time
}

type BLETrackView struct {
	BLEDevice
	Lost    bool      // no advert for >= 5 s
	PeakAt  time.Time
	Trend   string    // TrendRising (stronger), TrendFalling (weaker), TrendSteady — reuse engine consts
	History []int     // exactly lockHistoryLen (60) one-second RSSI samples, oldest first; missing seconds = -100
}

type BLETracker struct{ /* mutex-protected */ }
func NewBLETracker(expire time.Duration) *BLETracker
func (t *BLETracker) Observe(a Advert, at time.Time)
func (t *BLETracker) ObserveAddr(addr string, at time.Time) // fallback when only hcitool addresses are available: no RSSI (RSSI stays -100 unless real adverts arrive)
func (t *BLETracker) Count(now time.Time) int               // same semantics as BLECounter.Count (expires stale entries)
func (t *BLETracker) Devices(now time.Time) []BLEDevice     // non-expired, sorted RSSI desc, then Addr asc
func (t *BLETracker) AdvPerSec(now time.Time) float64       // all adverts in the last 10 s / 10
func (t *BLETracker) Track(addr string)                     // start/replace tracking; resets history/peak
func (t *BLETracker) Untrack()
func (t *BLETracker) Tracked(now time.Time) *BLETrackView   // nil when not tracking; device kept while tracked even past expiry (Lost=true)
```

**Labelling rule (Label):** Name if non-empty; else if Kind != "": Maker + " " + Kind (e.g. "APPLE AIRPODS") or Kind alone if no maker; else if Maker != "": Maker + " DEVICE"; else "UNKNOWN " + first 8 chars of Addr (e.g. "UNKNOWN 4B:63:B5").

**Kind hints (keep the table small and tested):** Apple (0x004C) manufacturer data byte[2] (first byte after the company id) type: 0x07 → "AIRPODS", 0x10 → "NEARBY" , 0x12 → "FIND MY", 0x09 → "AIRPLAY", 0x02 → "IBEACON". Microsoft 0x0006 with data byte[2] == 0x03 → "SWIFT PAIR". Service data 16-bit UUID (AD 0x16) 0xFE2C → Kind "FAST PAIR", 0xFD6F → "EXPOSURE NOTIF".

**Trend:** compare mean of the last 5 history seconds to the 5 before: >= +3 dB → TrendRising, <= -3 dB → TrendFalling, else TrendSteady.

**Tests (table-driven, from real captured bytes):** Use these two real legacy reports captured on the Pager (H4 event bytes after the 0x04 type byte):
- `3E 29 02 01 00 00 EE DD CC BB AA 02 1D 02 01 06 19 16 F7 FD 01 36 7C 66 8B B3 8D 50 42 AC 83 3F 2F 32 33 12 E2 00 00 00 00 03 B3` → Addr "02:AA:BB:CC:DD:EE", Random false, RSSI -77 (0xB3), Company -1, no name.
- `3E 2B 02 01 00 00 C5 0F CD BD 4D 74 1F 02 01 06 1B FF B5 B5 13 52 36 30 31 5A 41 42 37 58 46 43 54 30 39 32 38 63 00 01 00 00 3E 99 A6` → Addr "74:4D:BD:CD:0F:C5", Company 0xB5B5, RSSI -90 (0xA6).
Also: a synthetic report with AD 0x09 "Nanoleaf Strip FCE" and 0x0A tx 12; an Apple 0x07 AirPods report; two reports in one event; an extended (0x0D) report; truncated packets at every length (no panic, nil); non-ASCII name sanitized; a btsnoop stream (header + 3 records, datalink 1002) built in the test; tracker expiry, smoothing, peak, sort order, AdvPerSec, Track history with gaps (-100), Lost after 5 s, Trend.

- [ ] Write failing tests, run, implement, run `go test -mod=vendor -race ./...` and the MIPS vet, gofmt, commit `feat(rf-buddy): decode BLE adverts and track devices`.

---

### Task 2: Scanner + engine wiring

**Files:** Modify `bluetooth.go`, `bluetooth_test.go` (if present; else create), `engine.go`, `engine_test.go`, `main.go`, `fakes_test.go` as needed.

- `BLEScanner` gets `Tracker *BLETracker` instead of `Counter *BLECounter`. `Run` keeps the existing hcitool lescan lifecycle exactly (hciconfig up, disable scan, passive lescan with SIGINT cancel + WaitDelay + setChildDeathSignal, disable scan after). In addition, when `hcidump` is on PATH, run `hcidump -i <iface> -w /dev/stdout` as a sibling child for the same lifetime (same SIGINT cancel, WaitDelay 2 s, setChildDeathSignal), and feed its stdout through `ReadBTSnoop` into `Tracker.Observe(a, Now())`. lescan stdout lines still parse with `ParseLEScanLine` and call `Tracker.ObserveAddr` (keeps counts working without hcidump). Start hcidump before lescan; stop both before the restart delay. Make the hcidump argv a small pure function (`hcidumpArgs(iface)`) and test it, like `leScanArgs`.
- Delete `BLECounter` and its tests once nothing uses it (BLETracker.Count covers it); keep `ParseLEScanLine`.
- `Engine`: field `ble *BLETracker`. `Snapshot` gains `BT []BLEDevice`, `BTAdvPerSec float64`, `BTTrack *BLETrackView`, filled in `Snapshot()` from the tracker when `caps.Bluetooth` (BTCount/HasBT unchanged). Add `TrackBT(addr string)` / `UntrackBT()` on Engine (delegating to the tracker, then publish).
- `Controller` interface (ui.go) gains `TrackBT(addr string)` and `UntrackBT()`; update the fake controller in tests.
- `main.go`: build `NewBLETracker(30*time.Second)`, pass to engine and scanner. In the 250 ms ticker case, also redraw once per second while `view.LiveBT()` is true (add `func (u *ui) LiveBT() bool { return false }` here; Task 3 makes it real) so BT screens refresh even when the Wi-Fi engine publishes nothing.
- Tests: engine snapshot contains BT devices/track when caps.Bluetooth, absent otherwise; scanner args; `go test -race`, MIPS vet, gofmt. Commit `feat(rf-buddy): stream hcidump adverts into the BLE tracker`.

---

### Task 3: UI — BT tab, BT overview, BT track

**Files:** Modify `ui.go`, `ui_test.go`, `preview.go` (add BT preview frames if preview renders sample screens), `logger.go`/`logger_test.go` (BT marks), `README.md` of RF-BUDDY (controls table).

- **Tabs:** replace the UP/DOWN band toggle with a tab cycle: UP = next (2.4 → 5 → BT → 2.4), DOWN = previous. Switching to a Wi-Fi tab calls `ctrl.SetBand(band)` as today; switching to BT does not change the Wi-Fi sweep. Header shows three tab labels "2.4 GHZ", "5 GHZ", "BT"; the active one yellow-filled like today. Keep the "BT n" header box on Wi-Fi tabs; move it right if the third tab label needs the space.
- **BT overview (screen when tab = BT):** title "RF-BUDDY", tabs, then right of tabs `"%d DEV  %.0f ADV/S"` in cyan (or "BT N/A" when !s.HasBT — then the body says "BLUETOOTH UNAVAILABLE" dim). Left column x 6..256: header "NEARBY (STRONGEST FIRST)" dim + "DBM" right-aligned; up to 9 rows (16 px, from y 44) of `trimCells(Label, 24)` white and RSSI right-aligned coloured by `signalColor` (show "--" when RSSI <= -100). Selected row prefixed ">" and yellow. If list is longer than fits, scroll so the selected row stays visible. Empty list: "NO DEVICES YET" dim. Vertical divider at x 260 (cyan2) like Wi-Fi. Right panel (`renderBTPanel`) for the selected device: Label (yellow, trimmed), then metric rows using `metricRow`: "ADDR" addr (17 chars do not fit the 16-cell value box: show the addr without colons' first group, i.e. `addr[3:]` + " R" when Random — e.g. "68:EB:EC:8C:6E R"), "MAKER", "SIGNAL" "%d DBM", "PEAK" "%d DBM", "ADV/S" "%.1f", "TX PWR" "%d DBM" or "--", "SEEN" "%d S AGO". Footer: B EXIT, "LEFT/RIGHT DEV", "UP/DN BAND", A TRACK.
- **Selection** is by address (`u.btAddr string`): LEFT/RIGHT move to previous/next device in the current sorted list; if the selected address is no longer present, select index 0. A with a device selected → `ctrl.TrackBT(addr)`, screen = BT track. A with no devices → no-op.
- **BT track screen:** mirrors the Wi-Fi lock screen layout. Title `"TRACKING: " + Label` (yellow, trimmed to fit before the audio label), AUDIO ON/OFF, clock. Left box: big RSSI number (scale 4, e.g. "-41", "--" when lost), proximity label under it: >= -50 "VERY CLOSE" (red), >= -65 "CLOSE" (amber/orange per existing palette), >= -80 "NEAR" (yellow), else "FAR" (green); when Lost: "SIGNAL LOST" dim. Trend line: Rising → "^ CLOSER" red, Falling → "v FARTHER" green, Steady "- STEADY" white. "PEAK %d" and "@15:04" like Wi-Fi. Right: inline "ADV/S", "TX", "MAKER"; "LAST 60 S" RSSI graph mapping -100..-30 dBm onto the same 46 px plot, coloured by signalColor; details rows: ADDR, KIND/NAME; and a line "HITS WI-FI CH " + FormatChannelRuns(HitsWiFi()) → "HITS WI-FI CH 1-5, 13-14". Footer: B BACK, "LEFT/RIGHT DEV", "UP AUDIO", A MARK SPOT. B → `ctrl.UntrackBT()`, back to BT overview. LEFT/RIGHT → move selection and `TrackBT` the new address. UP → toggle audio.
- **Tick:** `TickInterval(s)` also returns a period on the BT track screen when audio on, tracked device present and not Lost: map RSSI linearly -90 dBm → score 20, -35 dBm → score 100 (clamped), then reuse `TickInterval(score)`.
- **Marks on track:** A → `marks.AddMark(Mark{At, BT: true, BTAddr, BTLabel, RSSI})`. Extend `Mark` with `BT bool, BTAddr, BTLabel string, RSSI int`; logger writes BT marks to the same marks.csv as `n,epoch,bt,<ADDR>,<RSSI>,<LABEL>` (band column "bt", channel column the address, score column RSSI, likely column the label with commas stripped). Toast "MARK n @ 15:04 - %d DBM". Wi-Fi marks unchanged.
- **LiveBT()** returns true on BT overview and BT track screens.
- Tests: tab cycle both directions incl. SetBand calls; BT overview selection by address, survives re-sorting, falls back to 0; A → TrackBT + screen; B on track → UntrackBT + back to BT overview; LEFT/RIGHT on track re-tracks; tick mapping (-90→2 s, -35→0.3 s, lost→0, audio off→0); BT mark CSV line; render smoke tests for BT overview (empty, N/A, 12 devices with scroll) and track (normal, lost) without panics; `HitsWiFi()` == [1 2 3 4 5 13 14] and `FormatChannelRuns` → "1-5, 13-14" (put both helpers in btsnoop.go or a new bt_overlap.go in this task). `go test -race`, MIPS vet, gofmt, full suite. Commit `feat(rf-buddy): BT tab with device details and track mode`.
