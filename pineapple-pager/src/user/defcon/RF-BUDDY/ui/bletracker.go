package main

import (
	"math"
	"sort"
	"strconv"
	"sync"
	"time"
)

const (
	bleLost      = 5 * time.Second
	bleSmooth    = 2 * time.Second
	bleRateWin   = 10 * time.Second
	bleNoSignal  = -100
	bleTrendStep = 3.0
)

// BLEDevice is the display state of one tracked BLE address.
type BLEDevice struct {
	Addr      string
	Random    bool
	Label     string
	Maker     string
	Kind      string
	Name      string
	RSSI      int
	Peak      int
	AdvPerSec float64
	TxPower   int
	HasTx     bool
	LastSeen  time.Time
}

// BLETrackView is the walk-around view of the one device being tracked.
type BLETrackView struct {
	BLEDevice
	Lost    bool
	PeakAt  time.Time
	Trend   string
	History []int
}

type bleSample struct {
	at   time.Time
	rssi int
}

type bleEntry struct {
	addr     string
	random   bool
	company  int
	kind     string
	name     string
	lastRSSI int
	peak     int
	tx       int
	hasTx    bool
	first    time.Time
	last     time.Time
	recent   []bleSample // adverts in the last bleRateWin
}

// BLETracker keeps per-device state from decoded adverts.
type BLETracker struct {
	mu      sync.Mutex
	expire  time.Duration
	devs    map[string]*bleEntry
	all     []time.Time // every advert in the last bleRateWin
	tracked string
	hist    []bleSample // tracked device adverts, last lockHistoryLen s
	tPeak   int
	tPeakAt time.Time
}

func NewBLETracker(expire time.Duration) *BLETracker {
	return &BLETracker{expire: expire, devs: map[string]*bleEntry{}, tPeak: bleNoSignal}
}

func (t *BLETracker) entry(addr string, at time.Time) *bleEntry {
	e := t.devs[addr]
	if e == nil {
		e = &bleEntry{addr: addr, company: -1, lastRSSI: bleNoSignal, peak: bleNoSignal, first: at}
		t.devs[addr] = e
	}
	if at.After(e.last) {
		e.last = at
	}
	return e
}

func (t *BLETracker) Observe(a Advert, at time.Time) {
	t.mu.Lock()
	defer t.mu.Unlock()
	e := t.entry(a.Addr, at)
	e.random = a.Random
	if a.Name != "" {
		e.name = a.Name
	}
	if a.Company >= 0 {
		e.company = a.Company
	}
	if a.Kind != "" {
		e.kind = a.Kind
	}
	if a.HasTx {
		e.tx, e.hasTx = a.TxPower, true
	}
	e.lastRSSI = a.RSSI
	if a.RSSI > e.peak {
		e.peak = a.RSSI
	}
	e.recent = append(pruneSamples(e.recent, at.Add(-bleRateWin)), bleSample{at, a.RSSI})
	t.all = append(pruneTimes(t.all, at.Add(-bleRateWin)), at)
	if a.Addr == t.tracked {
		t.hist = append(pruneSamples(t.hist, at.Add(-lockHistoryLen*time.Second)), bleSample{at, a.RSSI})
		if a.RSSI > t.tPeak {
			t.tPeak, t.tPeakAt = a.RSSI, at
		}
	}
}

// ObserveAddr records presence only (no RSSI) for hcitool-only fallback.
func (t *BLETracker) ObserveAddr(addr string, at time.Time) {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.entry(addr, at)
}

// pruneSamples/pruneTimes reslice instead of copying; the following append
// reallocates only when the backing array is exhausted (amortized O(1)).
func pruneSamples(s []bleSample, cutoff time.Time) []bleSample {
	i := 0
	for i < len(s) && s[i].at.Before(cutoff) {
		i++
	}
	return s[i:]
}

func pruneTimes(s []time.Time, cutoff time.Time) []time.Time {
	i := 0
	for i < len(s) && s[i].Before(cutoff) {
		i++
	}
	return s[i:]
}

func (t *BLETracker) expireLocked(now time.Time) {
	for addr, e := range t.devs {
		if addr != t.tracked && now.Sub(e.last) > t.expire {
			delete(t.devs, addr)
		}
	}
}

func (t *BLETracker) Count(now time.Time) int {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.expireLocked(now)
	return len(t.devs)
}

func (t *BLETracker) Devices(now time.Time) []BLEDevice {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.expireLocked(now)
	out := make([]BLEDevice, 0, len(t.devs))
	for _, e := range t.devs {
		out = append(out, e.device(now))
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].RSSI != out[j].RSSI {
			return out[i].RSSI > out[j].RSSI
		}
		return out[i].Addr < out[j].Addr
	})
	return out
}

func (e *bleEntry) device(now time.Time) BLEDevice {
	sum, n, cnt := 0, 0, 0
	for _, s := range e.recent {
		if now.Sub(s.at) <= bleSmooth {
			sum += s.rssi
			n++
		}
		if now.Sub(s.at) <= bleRateWin {
			cnt++
		}
	}
	rssi := e.lastRSSI
	if n > 0 {
		rssi = int(math.Round(float64(sum) / float64(n)))
	}
	span := now.Sub(e.first).Seconds()
	if span > bleRateWin.Seconds() {
		span = bleRateWin.Seconds()
	}
	if span < 1 {
		span = 1
	}
	d := BLEDevice{
		Addr: e.addr, Random: e.random, Maker: CompanyName(e.company), Kind: e.kind,
		Name: e.name, RSSI: rssi, Peak: e.peak, AdvPerSec: float64(cnt) / span,
		TxPower: e.tx, HasTx: e.hasTx, LastSeen: e.last,
	}
	d.Label = bleLabel(d)
	return d
}

func bleLabel(d BLEDevice) string {
	switch {
	case d.Name != "":
		return d.Name
	case d.Kind != "" && d.Maker != "":
		return d.Maker + " " + d.Kind
	case d.Kind != "":
		return d.Kind
	case d.Maker != "":
		return d.Maker + " DEVICE"
	}
	a := d.Addr
	if len(a) > 8 {
		a = a[:8]
	}
	return "UNKNOWN " + a
}

// AdvPerSec is the all-device advert rate over the last 10 s.
func (t *BLETracker) AdvPerSec(now time.Time) float64 {
	t.mu.Lock()
	defer t.mu.Unlock()
	n := 0
	for _, at := range t.all {
		if now.Sub(at) <= bleRateWin {
			n++
		}
	}
	return float64(n) / bleRateWin.Seconds()
}

// Track starts (or replaces) tracking of addr and resets history and peak.
func (t *BLETracker) Track(addr string) {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.tracked, t.hist, t.tPeak, t.tPeakAt = addr, nil, bleNoSignal, time.Time{}
}

func (t *BLETracker) Untrack() {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.tracked, t.hist, t.tPeak, t.tPeakAt = "", nil, bleNoSignal, time.Time{}
}

// Tracked returns the tracked device view, or nil when not tracking.
func (t *BLETracker) Tracked(now time.Time) *BLETrackView {
	t.mu.Lock()
	defer t.mu.Unlock()
	if t.tracked == "" {
		return nil
	}
	t.expireLocked(now)
	e := t.devs[t.tracked]
	if e == nil {
		e = &bleEntry{addr: t.tracked, company: -1, lastRSSI: bleNoSignal, peak: bleNoSignal}
	}
	v := &BLETrackView{BLEDevice: e.device(now), PeakAt: t.tPeakAt}
	v.Peak = t.tPeak
	v.Lost = e.last.IsZero() || now.Sub(e.last) >= bleLost
	v.History = t.history(now)
	v.Trend = bleTrend(v.History)
	return v
}

// history buckets tracked adverts into lockHistoryLen one-second means.
func (t *BLETracker) history(now time.Time) []int {
	sum := make([]int, lockHistoryLen)
	cnt := make([]int, lockHistoryLen)
	for _, s := range t.hist {
		age := int(now.Sub(s.at) / time.Second)
		if age < 0 {
			age = 0
		}
		if age >= lockHistoryLen {
			continue
		}
		sum[age] += s.rssi
		cnt[age]++
	}
	h := make([]int, lockHistoryLen)
	for age := 0; age < lockHistoryLen; age++ {
		v := bleNoSignal
		if cnt[age] > 0 {
			v = int(math.Round(float64(sum[age]) / float64(cnt[age])))
		}
		h[lockHistoryLen-1-age] = v
	}
	return h
}

// bleTrend compares the last 5 seconds with the 5 before; missing seconds are ignored.
func bleTrend(h []int) string {
	mean := func(s []int) (float64, bool) {
		sum, n := 0, 0
		for _, v := range s {
			if v != bleNoSignal {
				sum += v
				n++
			}
		}
		if n == 0 {
			return 0, false
		}
		return float64(sum) / float64(n), true
	}
	if len(h) < 10 {
		return TrendSteady
	}
	cur, ok1 := mean(h[len(h)-5:])
	prev, ok2 := mean(h[len(h)-10 : len(h)-5])
	if !ok1 || !ok2 {
		return TrendSteady
	}
	switch d := cur - prev; {
	case d >= bleTrendStep:
		return TrendRising
	case d <= -bleTrendStep:
		return TrendFalling
	}
	return TrendSteady
}

// HitsWiFi lists 2.4 GHz Wi-Fi channels overlapped by BLE advertising channels 37/38/39.
func HitsWiFi() []int {
	var out []int
	for ch := 1; ch <= 14; ch++ {
		c := 2407 + 5*ch
		if ch == 14 {
			c = 2484
		}
		for _, f := range []int{2402, 2426, 2480} {
			if d := c - f; d >= -10 && d <= 10 {
				out = append(out, ch)
				break
			}
		}
	}
	return out
}

// FormatChannelRuns renders e.g. [1 2 3 4 5 13 14] as "1-5, 13-14".
func FormatChannelRuns(chs []int) string {
	s := ""
	for i := 0; i < len(chs); {
		j := i
		for j+1 < len(chs) && chs[j+1] == chs[j]+1 {
			j++
		}
		if s != "" {
			s += ", "
		}
		if j == i {
			s += strconv.Itoa(chs[i])
		} else {
			s += strconv.Itoa(chs[i]) + "-" + strconv.Itoa(chs[j])
		}
		i = j + 1
	}
	return s
}
