package main

import (
	"image/png"
	"os"
	"path/filepath"
	"time"
)

type previewCase struct {
	name string
	snap Snapshot
	ui   func() *ui
}

func previewSnapshot(now time.Time, stress bool) Snapshot {
	t := DefaultThresholds()
	bt := 23
	if stress {
		bt = 999
	}
	view := func(ch Channel, airtime, retry float64, aps, overlap int, hasBT bool) ChannelView {
		m := Metrics{AirtimePct: airtime, HasAirtime: true, RetryPct: retry, HasRetry: true, FramesPerSec: airtime * 4,
			CoChannelAPs: aps, OverlapAPs: overlap, BTCount: bt, HasBT: hasBT}
		score := Score(m)
		return ChannelView{Channel: ch, Metrics: m, Raw: score, Score: score, Likely: Likely(m, ch.Band, t), Measured: true, Updated: now}
	}
	var s Snapshot
	airtime24 := []float64{58, 20, 12, 18, 41, 22, 47, 24, 21, 35, 52}
	retry24 := []float64{12, 6, 4, 5, 9, 38, 11, 7, 6, 8, 14}
	for i := range airtime24 {
		s.Channels24 = append(s.Channels24, view(Channel{Band24, i + 1}, airtime24[i], retry24[i], 3+i%4, i%3, true))
	}
	nums5 := []int{36, 40, 44, 48, 149, 153, 157, 161}
	if stress {
		nums5 = []int{36, 40, 44, 48, 52, 56, 60, 64, 100, 104, 108, 112, 116, 120, 124, 128, 132, 136, 140, 144, 149, 153, 157, 161, 165}
	}
	for i, n := range nums5 {
		s.Channels5 = append(s.Channels5, view(Channel{Band5, n}, float64(5+(i*13)%60), 4, 1+i%3, 0, true))
	}
	if stress {
		s.Channels24[2].Skipped = true
		s.Channels5[3].Skipped = true
	}
	lock := LockView{ChannelView: s.Channels24[5], Peak: 94, PeakAt: now.Add(-time.Minute), Trend: TrendRising}
	for i := 0; i < lockHistoryLen; i++ {
		lock.History = append(lock.History, 40+i*50/lockHistoryLen)
	}
	lock.Top = []Transmitter{{Addr: "70:A7:41:6C:00:2E", SSID: "NINEDTER", SignalDBm: -67}, {Addr: "02:68:EB:EC:0C:6E", SSID: "DIRECT-6E-HP M479fdw Color LJ", SignalDBm: -48}}
	if stress {
		lock.Score, lock.Raw, lock.Peak = 100, 100, 100
		lock.Top = []Transmitter{{Addr: "AA:BB:CC:00:00:09", SSID: "THIS-IS-A-VERY-LONG-GUEST-NETWORK-NAME-FOR-CONTAINMENT", SignalDBm: -100}, {Addr: "AA:BB:CC:00:00:0A", SignalDBm: -99}}
	}
	s.Lock = &lock
	s.BTCount, s.HasBT, s.LogPaused = bt, true, stress
	if stress {
		s.RadioError = "FRAME CAPTURE FAILED ON WLAN1MON - RETRYING EVERY SECOND"
	}
	return s
}

func noBluetoothSnapshot(now time.Time) Snapshot {
	s := previewSnapshot(now, false)
	for _, list := range [][]ChannelView{s.Channels24, s.Channels5} {
		for i := range list {
			list[i].Metrics.HasBT = false
			list[i].Likely = Likely(list[i].Metrics, list[i].Channel.Band, DefaultThresholds())
		}
	}
	s.HasBT = false
	return s
}

func previewBTSnapshot(now time.Time) Snapshot {
	s := previewSnapshot(now, false)
	type dev struct {
		addr, label, maker, kind string
		rssi, peak               int
		adv                      float64
		tx                       int
		hasTx, random            bool
	}
	devs := []dev{
		{"68:EB:EC:8C:6E:01", "APPLE AIRPODS", "APPLE", "AIRPODS", -42, -38, 9.8, 0, false, true},
		{"74:4D:BD:CD:0F:C5", "NANOLEAF STRIP FCE", "", "", -55, -49, 4.2, 12, true, false},
		{"02:68:EB:EC:8C:6E", "MICROSOFT SWIFT PAIR", "MICROSOFT", "SWIFT PAIR", -63, -58, 2.1, 0, false, true},
		{"4B:63:B5:11:22:33", "UNKNOWN 4B:63:B5", "", "", -67, -60, 1.5, 0, false, true},
		{"11:22:33:44:55:66", "GALAXY WATCH5 (LONG NAME HERE)", "SAMSUNG", "", -72, -66, 3.3, 8, true, false},
		{"22:33:44:55:66:77", "GOOGLE FAST PAIR", "GOOGLE", "FAST PAIR", -75, -70, 1.1, 0, false, true},
		{"33:44:55:66:77:88", "APPLE NEARBY", "APPLE", "NEARBY", -78, -61, 0.9, 0, false, true},
		{"44:55:66:77:88:99", "GARMIN DEVICE", "GARMIN", "", -83, -80, 0.7, 0, false, false},
		{"55:66:77:88:99:AA", "XIAOMI DEVICE", "XIAOMI", "", -86, -82, 0.6, 0, false, false},
		{"66:77:88:99:AA:BB", "UNKNOWN 66:77:88", "", "", -91, -88, 0.4, 0, false, true},
		{"77:88:99:AA:BB:CC", "APPLE FIND MY", "APPLE", "FIND MY", -95, -90, 0.3, 0, false, true},
		{"88:99:AA:BB:CC:DD", "ESPRESSIF DEVICE", "ESPRESSIF", "", -100, -97, 0.2, 0, false, false},
	}
	for i, d := range devs {
		s.BT = append(s.BT, BLEDevice{Addr: d.addr, Random: d.random, Label: d.label, Maker: d.maker, Kind: d.kind,
			RSSI: d.rssi, Peak: d.peak, AdvPerSec: d.adv, TxPower: d.tx, HasTx: d.hasTx, LastSeen: now.Add(-time.Duration(i%4) * time.Second)})
	}
	s.BTCount, s.HasBT, s.BTAdvPerSec = len(devs), true, 31
	return s
}

func previewBTTrack(now time.Time, lost bool) Snapshot {
	s := previewBTSnapshot(now)
	t := BLETrackView{BLEDevice: s.BT[1], Trend: TrendRising, PeakAt: now.Add(-45 * time.Second)}
	t.Name = "NANOLEAF STRIP FCE"
	t.RSSI, t.Peak = -41, -38
	for i := 0; i < lockHistoryLen; i++ {
		v := -90 + i*50/lockHistoryLen
		if i%17 == 5 {
			v = -100
		}
		t.History = append(t.History, v)
	}
	if lost {
		t.Lost, t.Trend = true, TrendSteady
		t.LastSeen = now.Add(-9 * time.Second)
		for i := 50; i < lockHistoryLen; i++ {
			t.History[i] = -100
		}
	}
	s.BTTrack = &t
	return s
}

func previewCases(now time.Time) []previewCase {
	clock := func() time.Time { return now }
	okCaps := Capabilities{Tune: true, Capture: true, Bluetooth: true}
	noBT := Capabilities{Tune: true, Capture: true}
	fatal := Capabilities{FatalReason: "SOMETHING ELSE IS MOVING WLAN1MON OFF THE LOCKED CHANNEL. CLOSE OTHER RECON PAYLOADS, THEN RELAUNCH RF-BUDDY."}
	normal, stress := previewSnapshot(now, false), previewSnapshot(now, true)
	mk := func(caps Capabilities, probed bool, scr screen, band Band, toast string) func() *ui {
		return func() *ui {
			u := newUI(nil, nil, clock)
			u.caps, u.probed, u.screen, u.band, u.toast = caps, probed, scr, band, toast
			return u
		}
	}
	btSnap, btEmpty := previewBTSnapshot(now), previewBTSnapshot(now)
	btEmpty.BT, btEmpty.BTCount = nil, 0
	btNA := previewBTSnapshot(now)
	btNA.BT, btNA.BTCount, btNA.HasBT = nil, 0, false
	mkBT := func(scr screen, addr string, audio bool) func() *ui {
		return func() *ui {
			u := newUI(nil, nil, clock)
			u.caps, u.probed, u.screen, u.btAddr, u.audio = okCaps, true, scr, addr, audio
			return u
		}
	}
	return []previewCase{
		{"01-probe-checking.png", normal, mk(okCaps, false, screenProbe, Band24, "")},
		{"02-probe-result.png", normal, mk(noBT, true, screenProbe, Band24, "")},
		{"03-overview-24.png", normal, mk(okCaps, true, screenOverview, Band24, "")},
		{"04-overview-5.png", normal, mk(okCaps, true, screenOverview, Band5, "")},
		{"05-lock.png", normal, mk(okCaps, true, screenLock, Band24, "")},
		{"06-no-bluetooth-overview.png", noBluetoothSnapshot(now), mk(noBT, true, screenOverview, Band24, "")},
		{"07-fatal.png", normal, mk(fatal, true, screenFatal, Band24, "")},
		{"08-stress-overview.png", stress, mk(okCaps, true, screenOverview, Band5, "")},
		{"09-stress-lock.png", stress, mk(okCaps, true, screenLock, Band24, "MARK 12 @ 12:42 - SCORE 100 WITH A VERY LONG OPERATOR NOTE")},
		{"10-bt-overview.png", btSnap, mkBT(screenBT, "77:88:99:AA:BB:CC", true)},
		{"11-bt-overview-empty.png", btEmpty, mkBT(screenBT, "", true)},
		{"12-bt-overview-na.png", btNA, mkBT(screenBT, "", true)},
		{"13-bt-track.png", previewBTTrack(now, false), mkBT(screenBTTrack, "74:4D:BD:CD:0F:C5", true)},
		{"14-bt-track-lost.png", previewBTTrack(now, true), mkBT(screenBTTrack, "74:4D:BD:CD:0F:C5", false)},
	}
}

// renderPreviews writes deterministic PNGs of every screen state for review.
func renderPreviews(dir string) error {
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	now := time.Date(2026, 10, 1, 12, 42, 0, 0, time.Local)
	for _, c := range previewCases(now) {
		f, err := os.Create(filepath.Join(dir, c.name))
		if err != nil {
			return err
		}
		err = png.Encode(f, c.ui().Render(c.snap, now))
		if closeErr := f.Close(); err == nil {
			err = closeErr
		}
		if err != nil {
			return err
		}
	}
	return nil
}
