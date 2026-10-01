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
