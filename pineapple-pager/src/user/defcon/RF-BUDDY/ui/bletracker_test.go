package main

import (
	"reflect"
	"testing"
	"time"
)

var t0 = time.Date(2026, 1, 1, 12, 0, 0, 0, time.UTC)

func adv(addr string, rssi int) Advert { return Advert{Addr: addr, RSSI: rssi, Company: -1} }

func TestHitsWiFi(t *testing.T) {
	got := HitsWiFi()
	if want := []int{1, 2, 3, 4, 5, 13, 14}; !reflect.DeepEqual(got, want) {
		t.Fatalf("got %v", got)
	}
	for in, want := range map[string]string{FormatChannelRuns(got): "1-5, 13-14", FormatChannelRuns(nil): "",
		FormatChannelRuns([]int{3}): "3", FormatChannelRuns([]int{1, 3, 4}): "1, 3-4"} {
		if in != want {
			t.Errorf("got %q want %q", in, want)
		}
	}
}

func TestBLELabel(t *testing.T) {
	tests := []struct {
		d    BLEDevice
		want string
	}{
		{BLEDevice{Name: "TAG", Maker: "APPLE", Kind: "X"}, "TAG"},
		{BLEDevice{Maker: "APPLE", Kind: "AIRPODS"}, "APPLE AIRPODS"},
		{BLEDevice{Kind: "FAST PAIR"}, "FAST PAIR"},
		{BLEDevice{Maker: "BOSE"}, "BOSE DEVICE"},
		{BLEDevice{Addr: "4B:63:B5:11:22:33"}, "UNKNOWN 4B:63:B5"},
	}
	for _, tc := range tests {
		if got := bleLabel(tc.d); got != tc.want {
			t.Errorf("got %q want %q", got, tc.want)
		}
	}
}

func TestTrackerDevices(t *testing.T) {
	tr := NewBLETracker(30 * time.Second)
	a := Advert{Addr: "AA", Random: true, RSSI: -80, Company: 0x4C, Kind: "AIRPODS", Name: "BUDS", HasTx: true, TxPower: 4}
	tr.Observe(a, t0)
	a.Name, a.RSSI = "", -60 // sticky name
	tr.Observe(a, t0.Add(time.Second))
	tr.Observe(adv("BB", -60), t0.Add(time.Second))
	tr.Observe(adv("A0", -60), t0.Add(time.Second))
	tr.ObserveAddr("CC", t0.Add(time.Second))

	now := t0.Add(1500 * time.Millisecond)
	ds := tr.Devices(now)
	var order []string
	for _, d := range ds {
		order = append(order, d.Addr)
	}
	// -70 smoothed AA? mean(-80,-60) = -70; A0/BB -60; CC -100
	if want := []string{"A0", "BB", "AA", "CC"}; !reflect.DeepEqual(order, want) {
		t.Fatalf("order %v", order)
	}
	aa := ds[2]
	if aa.RSSI != -70 || aa.Peak != -60 || aa.Name != "BUDS" || aa.Label != "BUDS" || aa.Maker != "APPLE" ||
		!aa.Random || !aa.HasTx || aa.TxPower != 4 || aa.AdvPerSec != 2/1.5 {
		t.Errorf("AA %+v", aa)
	}
	if ds[3].RSSI != -100 {
		t.Errorf("addr-only %+v", ds[3])
	}

	// outside the 2 s window the smoothed value falls back to the last advert
	later := t0.Add(20 * time.Second)
	for _, d := range tr.Devices(later) {
		if d.Addr == "AA" && d.RSSI != -60 {
			t.Errorf("fallback %+v", d)
		}
	}
	if got := tr.Count(later); got != 4 {
		t.Errorf("count %d", got)
	}
	if got := tr.Count(t0.Add(32 * time.Second)); got != 0 {
		t.Errorf("count after expiry %d", got)
	}
}

func TestTrackerAdvPerSec(t *testing.T) {
	tr := NewBLETracker(time.Minute)
	for i := 0; i < 50; i++ {
		tr.Observe(adv("AA", -70), t0.Add(time.Duration(i)*100*time.Millisecond))
	}
	if got := tr.AdvPerSec(t0.Add(5 * time.Second)); got != 5 {
		t.Errorf("got %v", got)
	}
	if got := tr.AdvPerSec(t0.Add(30 * time.Second)); got != 0 {
		t.Errorf("stale %v", got)
	}
}

func TestTrackHistoryLostTrend(t *testing.T) {
	tr := NewBLETracker(10 * time.Second)
	if tr.Tracked(t0) != nil {
		t.Fatal("nil when not tracking")
	}
	tr.Observe(adv("AA", -90), t0.Add(-time.Hour)) // pre-track data not in history
	tr.Track("AA")
	// seconds 0-4: -80 ; 5-9: -70 (rising); gap at second 10; sample at 11
	for s := 0; s < 10; s++ {
		r := -80
		if s >= 5 {
			r = -70
		}
		tr.Observe(adv("AA", r), t0.Add(time.Duration(s)*time.Second))
		tr.Observe(adv("AA", r-2), t0.Add(time.Duration(s)*time.Second+500*time.Millisecond))
	}
	now := t0.Add(9*time.Second + 900*time.Millisecond)
	v := tr.Tracked(now)
	if len(v.History) != lockHistoryLen {
		t.Fatalf("len %d", len(v.History))
	}
	if v.History[lockHistoryLen-1] != -71 || v.History[lockHistoryLen-10] != -81 || v.History[0] != -100 {
		t.Errorf("history %v", v.History)
	}
	if v.Trend != TrendRising || v.Lost || v.Peak != -70 || !v.PeakAt.Equal(t0.Add(5*time.Second)) {
		t.Errorf("view %+v", v)
	}

	// signal lost after 5 s, survives expiry, gaps are -100
	late := t0.Add(9*time.Second + 500*time.Millisecond + 20*time.Second)
	v = tr.Tracked(late)
	if v == nil || !v.Lost || v.Addr != "AA" {
		t.Fatalf("lost view %+v", v)
	}
	if tr.Count(late) != 1 {
		t.Error("tracked device must not expire")
	}
	if v.History[lockHistoryLen-1] != -100 {
		t.Error("gap should be -100")
	}
	tr.Untrack()
	if tr.Tracked(late) != nil || tr.Count(late) != 0 {
		t.Error("untrack")
	}
}

func TestTrackUnseenAndTrends(t *testing.T) {
	tr := NewBLETracker(time.Second)
	tr.Track("ZZ")
	if v := tr.Tracked(t0); v == nil || !v.Lost || v.RSSI != -100 || v.Label != "UNKNOWN ZZ" {
		t.Errorf("unseen %+v", v)
	}
	mk := func(prev, cur int) []int {
		h := make([]int, lockHistoryLen)
		for i := range h {
			h[i] = bleNoSignal
		}
		for i := 0; i < 5; i++ {
			h[lockHistoryLen-10+i], h[lockHistoryLen-5+i] = prev, cur
		}
		return h
	}
	for _, tc := range []struct {
		h    []int
		want string
	}{
		{mk(-80, -77), TrendRising}, {mk(-70, -73), TrendFalling}, {mk(-70, -72), TrendSteady},
		{mk(bleNoSignal, -50), TrendSteady},
	} {
		if got := bleTrend(tc.h); got != tc.want {
			t.Errorf("got %s want %s", got, tc.want)
		}
	}
}
