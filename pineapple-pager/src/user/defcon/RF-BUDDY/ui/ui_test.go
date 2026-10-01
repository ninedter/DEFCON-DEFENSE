package main

import (
	"image"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

type recordingController struct {
	bands    []Band
	locks    []Channel
	unlocks  int
	tracked  []string
	untracks int
}

func (c *recordingController) SetBand(b Band)      { c.bands = append(c.bands, b) }
func (c *recordingController) Lock(ch Channel)     { c.locks = append(c.locks, ch) }
func (c *recordingController) Unlock()             { c.unlocks++ }
func (c *recordingController) TrackBT(addr string) { c.tracked = append(c.tracked, addr) }
func (c *recordingController) UntrackBT()          { c.untracks++ }

type recordingMarks struct {
	marks []Mark
	err   error
}

func (m *recordingMarks) AddMark(x Mark) (int, error) {
	if m.err != nil {
		return 0, m.err
	}
	m.marks = append(m.marks, x)
	return len(m.marks) + 2, nil
}

func uiSnapshot() Snapshot {
	var s Snapshot
	for _, ch := range Channels24() {
		s.Channels24 = append(s.Channels24, ChannelView{Channel: ch, Measured: true, Score: 30, Likely: CauseClean})
	}
	for _, ch := range Channels5(nil) {
		s.Channels5 = append(s.Channels5, ChannelView{Channel: ch, Measured: true, Score: 20, Likely: CauseClean})
	}
	return s
}

func overviewUI(t *testing.T) (*ui, *recordingController, *recordingMarks, *fakeClock) {
	t.Helper()
	clock := newFakeClock()
	ctrl, marks := &recordingController{}, &recordingMarks{}
	u := newUI(ctrl, marks, clock.Now)
	u.SetProbe(Capabilities{Tune: true, Capture: true, Bluetooth: true})
	if u.Advance(clock.Now()) {
		t.Fatal("probe results must hold before switching to the overview")
	}
	clock.Advance(probeResultHold)
	if !u.Advance(clock.Now()) || u.screen != screenOverview {
		t.Fatal("probe results did not advance to the overview")
	}
	return u, ctrl, marks, clock
}

func lockedSnapshot(score int) Snapshot {
	s := uiSnapshot()
	s.Lock = &LockView{ChannelView: ChannelView{Channel: Channel{Band24, 6}, Measured: true, Score: score, Raw: score + 3, Likely: CauseInterference}}
	return s
}

func TestOverviewALocksSelectedChannel(t *testing.T) {
	u, ctrl, _, _ := overviewUI(t)
	s := uiSnapshot()
	u.HandleButton("RIGHT", s)
	if u.HandleButton("A", s) {
		t.Fatal("A must not exit")
	}
	if len(ctrl.locks) != 1 || ctrl.locks[0] != (Channel{Band24, 7}) || u.screen != screenLock {
		t.Fatalf("locks = %+v screen = %d (default selection is channel 6)", ctrl.locks, u.screen)
	}
}

func TestOverviewSelectionSkipsSkippedAndClamps(t *testing.T) {
	u, ctrl, _, _ := overviewUI(t)
	s := uiSnapshot()
	s.Channels24[6].Skipped = true
	u.HandleButton("RIGHT", s)
	u.HandleButton("A", s)
	if ctrl.locks[0].Number != 8 {
		t.Fatalf("locked %d, want 8", ctrl.locks[0].Number)
	}
	u.HandleButton("B", s)
	for i := 0; i < 20; i++ {
		u.HandleButton("RIGHT", s)
	}
	u.HandleButton("A", s)
	if ctrl.locks[1].Number != 11 {
		t.Fatalf("selection must clamp at the last channel, got %d", ctrl.locks[1].Number)
	}
}

func TestOverviewUpDownToggleBandAndBExits(t *testing.T) {
	u, ctrl, _, _ := overviewUI(t)
	s := uiSnapshot()
	u.HandleButton("UP", s)
	u.HandleButton("DOWN", s)
	if len(ctrl.bands) != 2 || ctrl.bands[0] != Band5 || ctrl.bands[1] != Band24 {
		t.Fatalf("bands = %+v", ctrl.bands)
	}
	if !u.HandleButton("B", s) {
		t.Fatal("B on the overview must exit")
	}
}

func TestLockButtons(t *testing.T) {
	u, ctrl, marks, _ := overviewUI(t)
	u.HandleButton("A", uiSnapshot())
	s := lockedSnapshot(91)
	u.HandleButton("UP", s)
	if u.audio {
		t.Fatal("UP must toggle audio off")
	}
	u.HandleButton("A", s)
	if len(marks.marks) != 1 || marks.marks[0].Score != 91 || u.toast != "MARK 3 @ 12:00 - SCORE 91" {
		t.Fatalf("marks = %+v toast = %q", marks.marks, u.toast)
	}
	u.HandleButton("LEFT", s)
	if got := ctrl.locks[len(ctrl.locks)-1]; got != (Channel{Band24, 5}) {
		t.Fatalf("LEFT relocked %+v, want channel 5", got)
	}
	if exit := u.HandleButton("B", s); exit || ctrl.unlocks != 1 || u.screen != screenOverview {
		t.Fatalf("B in lock: exit=%v unlocks=%d screen=%d", exit, ctrl.unlocks, u.screen)
	}
}

func TestLockMarkFailureShowsPausedToastThenExpires(t *testing.T) {
	u, _, marks, clock := overviewUI(t)
	marks.err = errLogPaused
	u.HandleButton("A", uiSnapshot())
	u.HandleButton("A", lockedSnapshot(50))
	if !strings.Contains(u.toast, "NOT SAVED") {
		t.Fatalf("toast = %q", u.toast)
	}
	clock.Advance(toastHold)
	if !u.Advance(clock.Now()) || u.toast != "" {
		t.Fatal("toast must clear after toastHold")
	}
}

func TestFatalScreenOnlyExitsOnB(t *testing.T) {
	u := newUI(&recordingController{}, nil, newFakeClock().Now)
	u.SetProbe(Capabilities{FatalReason: "CANNOT CAPTURE FRAMES ON WLAN1MON"})
	s := uiSnapshot()
	for _, b := range []string{"A", "UP", "LEFT"} {
		if u.HandleButton(b, s) {
			t.Fatalf("%s exited the fatal screen", b)
		}
	}
	if !u.HandleButton("B", s) {
		t.Fatal("B must exit the fatal screen")
	}
}

func TestTickInterval(t *testing.T) {
	cases := map[int]time.Duration{0: 0, 19: 0, 20: 2000 * time.Millisecond, 60: 1150 * time.Millisecond, 100: 300 * time.Millisecond, 140: 300 * time.Millisecond}
	for score, want := range cases {
		if got := TickInterval(score); got != want {
			t.Errorf("TickInterval(%d) = %v, want %v", score, got, want)
		}
	}
}

func TestTickOnlyInLockWithAudio(t *testing.T) {
	u, _, _, _ := overviewUI(t)
	s := lockedSnapshot(100)
	if u.TickInterval(s) != 0 {
		t.Fatal("no tick on the overview")
	}
	u.HandleButton("A", s)
	if u.TickInterval(s) != 300*time.Millisecond {
		t.Fatal("tick expected in lock-on")
	}
	u.HandleButton("UP", s)
	if u.TickInterval(s) != 0 {
		t.Fatal("audio off must silence the tick")
	}
}

func assertMarginsBlack(t *testing.T, name string, img *image.RGBA) {
	t.Helper()
	for y := 0; y < screenHeight; y++ {
		for x := 477; x < screenWidth; x++ {
			if img.RGBAAt(x, y) != black {
				t.Fatalf("%s: pixel (%d,%d) outside the right margin", name, x, y)
			}
		}
	}
	for x := 0; x < screenWidth; x++ {
		if img.RGBAAt(x, screenHeight-1) != black {
			t.Fatalf("%s: pixel (%d,%d) on the bottom edge", name, x, screenHeight-1)
		}
	}
}

func TestRenderEveryStateStaysInsideMargins(t *testing.T) {
	now := time.Date(2026, 10, 1, 12, 42, 0, 0, time.UTC)
	for _, c := range previewCases(now) {
		assertMarginsBlack(t, c.name, c.ui().Render(c.snap, now))
	}
}

func TestRenderPreviewsWritesEveryState(t *testing.T) {
	dir := t.TempDir()
	if err := renderPreviews(dir); err != nil {
		t.Fatal(err)
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 14 {
		t.Fatalf("previews = %d, want 14", len(entries))
	}
	if _, err := os.Stat(filepath.Join(dir, "05-lock.png")); err != nil {
		t.Fatal(err)
	}
}

func TestRadioErrorStripShowsUnlessToastIsUp(t *testing.T) {
	u, _, _, clock := overviewUI(t)
	s := uiSnapshot()
	s.RadioError = "FRAME CAPTURE FAILED"
	if got := u.Render(s, clock.Now()).RGBAAt(6, 184); got != red {
		t.Fatalf("error strip border = %v, want red", got)
	}
	u.toast, u.toastUntil = "MARK 1 @ 12:00 - SCORE 10", clock.Now().Add(toastHold)
	if got := u.Render(s, clock.Now()).RGBAAt(6, 184); got != yellow {
		t.Fatalf("toast border = %v, want yellow (toast has priority)", got)
	}
	s.RadioError = ""
	u.toast = ""
	if got := u.Render(s, clock.Now()).RGBAAt(6, 184); got == red {
		t.Fatal("no strip when the radio is healthy")
	}
}

func btSnap(addrs ...string) Snapshot {
	s := uiSnapshot()
	s.HasBT = true
	for i, a := range addrs {
		s.BT = append(s.BT, BLEDevice{Addr: a, Label: "DEV " + a, RSSI: -50 - i*5, Peak: -45, LastSeen: time.Unix(0, 0)})
	}
	return s
}

func TestTabCycle(t *testing.T) {
	u, ctrl, _, _ := overviewUI(t)
	s := btSnap()
	u.HandleButton("UP", s)
	if u.screen != screenOverview || u.band != Band5 {
		t.Fatalf("UP #1: screen=%d band=%d", u.screen, u.band)
	}
	u.HandleButton("UP", s)
	if u.screen != screenBT || len(ctrl.bands) != 1 {
		t.Fatalf("UP #2: screen=%d bands=%v (BT must not retune)", u.screen, ctrl.bands)
	}
	u.HandleButton("UP", s)
	if u.screen != screenOverview || u.band != Band24 || len(ctrl.bands) != 2 || ctrl.bands[1] != Band24 {
		t.Fatalf("UP #3: screen=%d band=%d bands=%v", u.screen, u.band, ctrl.bands)
	}
	u.HandleButton("DOWN", s)
	if u.screen != screenBT {
		t.Fatalf("DOWN from 2.4 must reach BT, screen=%d", u.screen)
	}
	u.HandleButton("DOWN", s)
	if u.screen != screenOverview || u.band != Band5 || ctrl.bands[len(ctrl.bands)-1] != Band5 {
		t.Fatalf("DOWN from BT: screen=%d band=%d bands=%v", u.screen, u.band, ctrl.bands)
	}
	if u.LiveBT() {
		t.Fatal("LiveBT must be false on Wi-Fi tabs")
	}
}

func TestBTSelectionByAddress(t *testing.T) {
	u, ctrl, _, _ := overviewUI(t)
	s := btSnap("A", "B", "C")
	u.HandleButton("UP", s)
	u.HandleButton("UP", s)
	if !u.LiveBT() {
		t.Fatal("LiveBT must be true on the BT overview")
	}
	u.HandleButton("RIGHT", s)
	u.HandleButton("RIGHT", s)
	u.HandleButton("RIGHT", s) // clamps
	if u.btAddr != "C" {
		t.Fatalf("btAddr = %q, want C", u.btAddr)
	}
	// re-sorted list: selection follows the address
	re := btSnap("C", "A", "B")
	u.HandleButton("LEFT", re)
	if u.btAddr != "C" { // C is index 0; LEFT clamps
		t.Fatalf("after re-sort LEFT btAddr = %q", u.btAddr)
	}
	u.HandleButton("RIGHT", re)
	if u.btAddr != "A" {
		t.Fatalf("after re-sort RIGHT btAddr = %q, want A", u.btAddr)
	}
	// selected address vanished: fall back to index 0
	gone := btSnap("X", "Y")
	if d, _ := u.btSelected(gone.BT); d.Addr != "X" {
		t.Fatalf("fallback selection = %q", d.Addr)
	}
	u.HandleButton("A", gone)
	if len(ctrl.tracked) != 1 || ctrl.tracked[0] != "X" || u.screen != screenBTTrack {
		t.Fatalf("tracked=%v screen=%d", ctrl.tracked, u.screen)
	}
}

func TestBTTrackAWithNoDevicesIsNoop(t *testing.T) {
	u, ctrl, _, _ := overviewUI(t)
	u.screen = screenBT
	u.HandleButton("A", btSnap())
	if u.screen != screenBT || len(ctrl.tracked) != 0 {
		t.Fatalf("screen=%d tracked=%v", u.screen, ctrl.tracked)
	}
}

func TestBTTrackButtons(t *testing.T) {
	u, ctrl, marks, clock := overviewUI(t)
	s := btSnap("A", "B", "C")
	u.screen, u.btAddr = screenBT, "A"
	u.HandleButton("A", s)
	u.HandleButton("RIGHT", s)
	u.HandleButton("LEFT", s)
	u.HandleButton("LEFT", s) // clamped, no extra TrackBT
	if got := strings.Join(ctrl.tracked, ","); got != "A,B,A" {
		t.Fatalf("tracked = %s", got)
	}
	u.HandleButton("UP", s)
	if u.audio {
		t.Fatal("UP must toggle audio")
	}
	s.BTTrack = &BLETrackView{BLEDevice: BLEDevice{Addr: "A", Label: "DEV A", RSSI: -61}}
	u.HandleButton("A", s)
	if len(marks.marks) != 1 || !marks.marks[0].BT || marks.marks[0].BTAddr != "A" || marks.marks[0].RSSI != -61 || marks.marks[0].BTLabel != "DEV A" {
		t.Fatalf("marks = %+v", marks.marks)
	}
	want := "MARK 3 @ " + clock.Now().Format("15:04") + " - -61 DBM"
	if u.toast != want {
		t.Fatalf("toast = %q, want %q", u.toast, want)
	}
	if exit := u.HandleButton("B", s); exit || ctrl.untracks != 1 || u.screen != screenBT {
		t.Fatalf("B: exit=%v untracks=%d screen=%d", exit, ctrl.untracks, u.screen)
	}
}

func TestBTTickInterval(t *testing.T) {
	u, _, _, _ := overviewUI(t)
	u.screen = screenBTTrack
	at := func(rssi int, lost bool) Snapshot {
		return Snapshot{BTTrack: &BLETrackView{BLEDevice: BLEDevice{RSSI: rssi}, Lost: lost}}
	}
	if got := u.TickInterval(at(-90, false)); got != 2*time.Second {
		t.Fatalf("-90 dBm = %v", got)
	}
	if got := u.TickInterval(at(-35, false)); got != 300*time.Millisecond {
		t.Fatalf("-35 dBm = %v", got)
	}
	if got := u.TickInterval(at(-20, false)); got != 300*time.Millisecond {
		t.Fatalf("-20 dBm must clamp, got %v", got)
	}
	if got := u.TickInterval(at(-50, true)); got != 0 {
		t.Fatalf("lost = %v", got)
	}
	if got := u.TickInterval(Snapshot{}); got != 0 {
		t.Fatalf("no track = %v", got)
	}
	u.audio = false
	if got := u.TickInterval(at(-50, false)); got != 0 {
		t.Fatalf("audio off = %v", got)
	}
}

func TestBTRenderSmoke(t *testing.T) {
	now := time.Date(2026, 10, 1, 12, 42, 0, 0, time.Local)
	for _, c := range previewCases(now) {
		if img := c.ui().Render(c.snap, now); img == nil || img.Bounds().Dx() != screenWidth {
			t.Fatalf("%s did not render", c.name)
		}
	}
	// selected row beyond the visible window, and a track with no snapshot data
	u := newUI(nil, nil, func() time.Time { return now })
	u.screen, u.btAddr = screenBT, "88:99:AA:BB:CC:DD"
	u.Render(previewBTSnapshot(now), now)
	u.screen = screenBTTrack
	u.Render(Snapshot{HasBT: true}, now)
}
