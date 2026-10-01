package main

import (
	"fmt"
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
		brand, typ, name string
		rssi             int
		adv              float64
		tx               int
	}
	// a realistic office mix: lots of Apple, a Nanoleaf strip, Microsoft, randoms
	devs := []dev{
		{"APPLE", "AIRPODS", "", -42, 9.8, 0},
		{"APPLE", "FIND MY", "", -48, 2.1, 0},
		{"NANOLEAF", "OTHER", "NANOLEAF STRIP FCE", -55, 4.2, 12},
		{"APPLE", "NEARBY", "", -57, 3.0, 0},
		{"APPLE", "FIND MY", "", -59, 1.8, 0},
		{"MICROSOFT", "SWIFT PAIR", "", -63, 2.1, 0},
		{"APPLE", "AIRPLAY", "", -64, 1.4, 0},
		{"APPLE", "FIND MY", "", -66, 1.6, 0},
		{"UNKNOWN", "OTHER", "", -67, 1.5, 0},
		{"APPLE", "HANDOFF", "", -68, 1.1, 0},
		{"APPLE", "FIND MY", "", -70, 1.2, 0},
		{"APPLE", "NEARBY", "", -71, 0.9, 0},
		{"SAMSUNG", "WATCH", "GALAXY WATCH5 PRO (LIVING ROOM)", -72, 3.3, 8},
		{"APPLE", "FIND MY", "", -73, 1.0, 0},
		{"GOOGLE", "FAST PAIR", "", -75, 1.1, 0},
		{"APPLE", "FIND MY", "", -76, 0.9, 0},
		{"APPLE", "NEARBY", "", -77, 0.8, 0},
		{"MICROSOFT", "WINDOWS", "", -78, 0.7, 0},
		{"APPLE", "FIND MY", "", -79, 0.8, 0},
		{"UNKNOWN", "EDDYSTONE", "", -80, 0.6, 0},
		{"APPLE", "FIND MY", "", -81, 0.7, 0},
		{"APPLE", "NEARBY", "", -82, 0.6, 0},
		{"TILE", "TRACKER", "", -83, 0.5, 0},
		{"APPLE", "FIND MY", "", -84, 0.6, 0},
		{"GARMIN", "OTHER", "", -85, 0.7, 0},
		{"APPLE", "NEARBY", "", -86, 0.5, 0},
		{"MICROSOFT", "SWIFT PAIR", "", -87, 0.5, 0},
		{"APPLE", "FIND MY", "", -88, 0.5, 0},
		{"UNKNOWN", "OTHER", "", -89, 0.4, 0},
		{"XIAOMI", "OTHER", "", -90, 0.6, 0},
		{"APPLE", "NEARBY", "", -91, 0.4, 0},
		{"MICROSOFT", "WINDOWS", "", -92, 0.4, 0},
		{"UNKNOWN", "OTHER", "", -93, 0.3, 0},
		{"APPLE", "AIRPLAY", "", -94, 0.3, 0},
		{"ESPRESSIF", "OTHER", "", -95, 0.2, 0},
		{"APPLE", "FIND MY", "", -100, 0.2, 0},
		{"UNKNOWN", "OTHER", "", -100, 0.2, 0},
	}
	for i, d := range devs {
		b := BLEDevice{
			Addr:   fmt.Sprintf("%02X:%02X:%02X:%02X:%02X:%02X", 0x40+i, 0x63^i, 0xB5-i, 0x11*(i%9), 0x20+3*i, 0xA0+i),
			Random: d.brand == "APPLE" || d.brand == "UNKNOWN",
			Brand:  d.brand, Type: d.typ, Name: d.name, Maker: d.brand, Kind: d.typ,
			RSSI: d.rssi, Peak: min(-30, d.rssi+6+i%5), AdvPerSec: d.adv, TxPower: d.tx, HasTx: d.tx != 0,
			LastSeen:  now.Add(-time.Duration(i%4) * time.Second),
			FirstSeen: now.Add(-time.Duration(60+i*47) * time.Second),
		}
		if d.rssi <= -100 {
			b.Peak = -100
		}
		if d.brand == "UNKNOWN" {
			b.Maker = ""
		}
		b.Label = bleLabel(b)
		s.BT = append(s.BT, b)
	}
	s.BTCount, s.HasBT, s.BTAdvPerSec = len(devs), true, 90
	return s
}

func previewBTTrack(now time.Time, lost bool) Snapshot {
	s := previewBTSnapshot(now)
	t := BLETrackView{BLEDevice: s.BT[2], Trend: TrendRising, PeakAt: now.Add(-45 * time.Second)}
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
	btEmpty.BT, btEmpty.BTCount, btEmpty.BTAdvPerSec = nil, 0, 0
	btNA := previewBTSnapshot(now)
	btNA.BT, btNA.BTCount, btNA.HasBT = nil, 0, false
	mkBT := func(level int, brand, typ, addr string, audio bool) func() *ui {
		return func() *ui {
			u := newUI(nil, nil, clock)
			u.caps, u.probed, u.audio = okCaps, true, audio
			u.btBrand, u.btType, u.btAddr = brand, typ, addr
			u.setBTLevel(level)
			return u
		}
	}
	trackAddr := btSnap.BT[2].Addr
	findMy := DevicesOf(btSnap.BT, "APPLE", "FIND MY")
	findMyLast := findMy[len(findMy)-2].Addr
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
		{"10-bt-brands.png", btSnap, mkBT(btLevelBrands, "UNKNOWN", "", "", true)},
		{"11-bt-types-apple.png", btSnap, mkBT(btLevelTypes, "APPLE", "FIND MY", "", true)},
		{"12-bt-devices-find-my.png", btSnap, mkBT(btLevelDevices, "APPLE", "FIND MY", findMyLast, true)},
		{"13-bt-device-long-name.png", btSnap, mkBT(btLevelDevices, "SAMSUNG", "WATCH", "", true)},
		{"14-bt-types-empty.png", btSnap, mkBT(btLevelTypes, "GONE BRAND", "", "", true)},
		{"15-bt-brands-empty.png", btEmpty, mkBT(btLevelBrands, "", "", "", true)},
		{"16-bt-na.png", btNA, mkBT(btLevelBrands, "", "", "", true)},
		{"17-bt-track.png", previewBTTrack(now, false), mkBT(btLevelTrack, "NANOLEAF", "OTHER", trackAddr, true)},
		{"18-bt-track-lost.png", previewBTTrack(now, true), mkBT(btLevelTrack, "NANOLEAF", "OTHER", trackAddr, false)},
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
