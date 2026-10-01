package main

import (
	"context"
	"math"
	"sync"
	"time"
)

type EngineConfig struct {
	Dwell           time.Duration
	LockInterval    time.Duration
	SmoothTau       time.Duration
	ReconRefresh    time.Duration
	DefaultRateKbps int
	Thresholds      Thresholds
	OfficeSSID      string
}

func DefaultEngineConfig() EngineConfig {
	return EngineConfig{
		Dwell: 250 * time.Millisecond, LockInterval: time.Second, SmoothTau: 3 * time.Second,
		ReconRefresh: 30 * time.Second, DefaultRateKbps: defaultRateKbps, Thresholds: DefaultThresholds(),
	}
}

type ChannelView struct {
	Channel  Channel
	Metrics  Metrics
	Raw      int
	Score    int
	Likely   string
	Skipped  bool
	Measured bool
	Updated  time.Time
	Top      []Transmitter
}

const (
	TrendRising    = "RISING"
	TrendFalling   = "FALLING"
	TrendSteady    = "STEADY"
	lockHistoryLen = 60
	trendWindow    = 10
)

type LockView struct {
	ChannelView
	Peak    int
	PeakAt  time.Time
	Trend   string
	History []int
}

type Snapshot struct {
	Revision   uint64
	Band       Band
	Channels24 []ChannelView
	Channels5  []ChannelView
	Lock       *LockView
	BTCount    int
	HasBT      bool
	LogPaused  bool
}

func (s Snapshot) Channels(b Band) []ChannelView {
	if b == Band5 {
		return s.Channels5
	}
	return s.Channels24
}

// Engine drives wlan1mon: it sweeps channels in overview mode or stays on one
// channel in lock-on mode, and publishes snapshots for the UI.
type Engine struct {
	cfg   EngineConfig
	radio Radio
	inv   *Inventory
	ble   *BLECounter
	sink  SampleSink
	now   func() time.Time

	mu         sync.Mutex
	caps       Capabilities
	band       Band
	lockTarget *Channel
	views      map[Channel]ChannelView
	smooth     map[Channel]float64
	smoothAt   map[Channel]time.Time
	skipped    map[Channel]bool
	lock       *LockView
	lockRaw    []int
	channels5  []Channel
	reconAt    time.Time
	queue      []Channel
	cycle      int
	revision   uint64
	updates    chan struct{}
}

func NewEngine(cfg EngineConfig, radio Radio, inv *Inventory, ble *BLECounter, sink SampleSink, now func() time.Time) *Engine {
	return &Engine{
		cfg: cfg, radio: radio, inv: inv, ble: ble, sink: sink, now: now,
		views: map[Channel]ChannelView{}, smooth: map[Channel]float64{}, smoothAt: map[Channel]time.Time{},
		skipped: map[Channel]bool{}, updates: make(chan struct{}, 1),
	}
}

func (e *Engine) SetCapabilities(c Capabilities) {
	e.mu.Lock()
	e.caps = c
	e.mu.Unlock()
}

func (e *Engine) Updates() <-chan struct{} { return e.updates }

func (e *Engine) SetBand(b Band) {
	e.mu.Lock()
	defer e.mu.Unlock()
	if e.band != b {
		e.band = b
		e.queue = nil
	}
	e.publishLocked()
}

func (e *Engine) Lock(ch Channel) {
	e.mu.Lock()
	defer e.mu.Unlock()
	target := ch
	e.lockTarget = &target
	e.lock = &LockView{ChannelView: e.viewLocked(ch), Trend: TrendSteady}
	e.lockRaw = nil
	e.publishLocked()
}

func (e *Engine) Unlock() {
	e.mu.Lock()
	defer e.mu.Unlock()
	e.lockTarget, e.lock, e.lockRaw, e.queue = nil, nil, nil, nil
	e.publishLocked()
}

func (e *Engine) Run(ctx context.Context) {
	for ctx.Err() == nil {
		e.Step(ctx)
	}
}

// refreshRecon merges the live Recon AP list into the inventory every
// ReconRefresh; Recon keeps running while RF-BUDDY locks channels.
func (e *Engine) refreshRecon(ctx context.Context) {
	e.mu.Lock()
	due := e.reconAt.IsZero() || e.now().Sub(e.reconAt) >= e.cfg.ReconRefresh
	if due {
		e.reconAt = e.now()
	}
	e.mu.Unlock()
	if !due {
		return
	}
	aps, err := e.radio.ReconAPs(ctx)
	if err != nil {
		return
	}
	for _, ap := range aps {
		e.inv.Observe(ap)
	}
	e.mu.Lock()
	e.channels5 = Channels5(e.inv.All())
	e.mu.Unlock()
}

// Step performs one measurement: the locked channel, or the next sweep channel.
func (e *Engine) Step(ctx context.Context) {
	e.refreshRecon(ctx)
	e.mu.Lock()
	mode, d := ModeOverview, e.cfg.Dwell
	var ch Channel
	if e.lockTarget != nil {
		ch, mode, d = *e.lockTarget, ModeLock, e.cfg.LockInterval
	} else {
		if len(e.queue) == 0 {
			e.queue = e.sweepPlanLocked()
		}
		if len(e.queue) == 0 {
			e.mu.Unlock()
			sleepCtx(ctx, e.cfg.Dwell)
			return
		}
		ch, e.queue = e.queue[0], e.queue[1:]
	}
	e.mu.Unlock()
	e.measure(ctx, ch, d, mode)
}

func (e *Engine) sweepPlanLocked() []Channel {
	e.cycle++
	plan := e.bandChannelsLocked(e.band)
	if e.cycle%3 == 0 {
		plan = append(plan, e.bandChannelsLocked(e.band.Other())...)
	}
	out := make([]Channel, 0, len(plan))
	for _, ch := range plan {
		if !e.skipped[ch] {
			out = append(out, ch)
		}
	}
	return out
}

func (e *Engine) bandChannelsLocked(b Band) []Channel {
	if b == Band24 {
		return Channels24()
	}
	if e.channels5 == nil {
		e.channels5 = Channels5(e.inv.All())
	}
	return append([]Channel(nil), e.channels5...)
}

func (e *Engine) measure(ctx context.Context, ch Channel, d time.Duration, mode Mode) {
	if err := e.radio.Tune(ctx, ch); err != nil {
		if ctx.Err() != nil {
			return
		}
		e.mu.Lock()
		e.skipped[ch] = true
		e.publishLocked()
		e.mu.Unlock()
		return
	}
	stats := NewDwellStats(e.cfg.DefaultRateKbps)
	if err := e.radio.Capture(ctx, d, stats.Add); err != nil || ctx.Err() != nil {
		return
	}
	res := stats.Result(d)
	m := Metrics{
		AirtimePct: res.AirtimePct, HasAirtime: true, FramesPerSec: res.FramesPerSec,
		RetryPct: res.RetryPct, HasRetry: res.HasRetry,
	}
	for _, b := range res.Beacons {
		apCh := ch
		if b.BeaconChannel > 0 {
			if c, ok := ChannelForNumber(b.BeaconChannel); ok {
				apCh = c
			}
		}
		signal := -100
		if b.HasSignal {
			signal = b.SignalDBm
		}
		e.inv.Observe(AP{BSSID: b.TA, SSID: b.SSID, Channel: apCh, SignalDBm: signal})
	}
	m.CoChannelAPs = e.inv.CoChannel(ch)
	m.OverlapAPs, m.StrongOverlapAPs = e.inv.Overlap(ch, e.cfg.Thresholds.OverlapMinDBm)
	now := e.now()
	e.mu.Lock()
	caps := e.caps
	e.mu.Unlock()
	if caps.Bluetooth && e.ble != nil {
		m.BTCount, m.HasBT = e.ble.Count(now), true
	}
	if e.cfg.OfficeSSID != "" {
		m.OfficeConfigured = true
		m.OfficeSignalDBm, m.OfficeHeard = e.inv.OfficeBest(ch.Band, e.cfg.OfficeSSID)
	}
	top := res.Top
	for i := range top {
		if top[i].SSID == "" {
			top[i].SSID = e.inv.SSIDFor(top[i].Addr)
		}
	}
	raw := Score(m)
	likely := Likely(m, ch.Band, e.cfg.Thresholds)

	e.mu.Lock()
	v := ChannelView{Channel: ch, Metrics: m, Raw: raw, Score: e.smoothLocked(ch, raw, now), Likely: likely, Measured: true, Updated: now, Top: top}
	e.views[ch] = v
	if mode == ModeLock && e.lock != nil && e.lock.Channel == ch {
		e.updateLockLocked(v, now)
	}
	e.publishLocked()
	e.mu.Unlock()

	if e.sink != nil {
		// The log keeps the raw score so short spikes are not smoothed away.
		e.sink.WriteSample(Sample{At: now, Mode: mode, Channel: ch, Metrics: m, Score: raw, Likely: likely})
	}
}

// smoothLocked applies an exponential moving average with time constant
// SmoothTau so the displayed score does not flicker.
func (e *Engine) smoothLocked(ch Channel, raw int, now time.Time) int {
	value := float64(raw)
	if prev, ok := e.smooth[ch]; ok && e.cfg.SmoothTau > 0 {
		dt := now.Sub(e.smoothAt[ch]).Seconds()
		if dt <= 0 {
			value = prev
		} else {
			alpha := 1 - math.Exp(-dt/e.cfg.SmoothTau.Seconds())
			value = prev + alpha*(float64(raw)-prev)
		}
	}
	e.smooth[ch], e.smoothAt[ch] = value, now
	return int(math.Round(value))
}

func (e *Engine) updateLockLocked(v ChannelView, now time.Time) {
	l := e.lock
	l.ChannelView = v
	if l.PeakAt.IsZero() || v.Raw > l.Peak {
		l.Peak, l.PeakAt = v.Raw, now
	}
	l.History = append(l.History, v.Score)
	if len(l.History) > lockHistoryLen {
		l.History = append([]int(nil), l.History[len(l.History)-lockHistoryLen:]...)
	}
	e.lockRaw = append(e.lockRaw, v.Raw)
	if len(e.lockRaw) > trendWindow {
		e.lockRaw = append([]int(nil), e.lockRaw[len(e.lockRaw)-trendWindow:]...)
	}
	l.Trend = trendOf(e.lockRaw)
}

// trendOf compares the newer half of the last ~10 s of raw scores with the
// older half.
func trendOf(raw []int) string {
	if len(raw) < 4 {
		return TrendSteady
	}
	half := len(raw) / 2
	mean := func(xs []int) float64 {
		sum := 0
		for _, x := range xs {
			sum += x
		}
		return float64(sum) / float64(len(xs))
	}
	switch d := mean(raw[half:]) - mean(raw[:half]); {
	case d > 5:
		return TrendRising
	case d < -5:
		return TrendFalling
	default:
		return TrendSteady
	}
}

func (e *Engine) publishLocked() {
	e.revision++
	select {
	case e.updates <- struct{}{}:
	default:
	}
}

func (e *Engine) viewLocked(ch Channel) ChannelView {
	v, ok := e.views[ch]
	if !ok {
		v = ChannelView{Channel: ch}
	}
	v.Skipped = v.Skipped || e.skipped[ch]
	v.Top = append([]Transmitter(nil), v.Top...)
	return v
}

func (e *Engine) Snapshot() Snapshot {
	e.mu.Lock()
	defer e.mu.Unlock()
	s := Snapshot{Revision: e.revision, Band: e.band}
	for _, ch := range Channels24() {
		s.Channels24 = append(s.Channels24, e.viewLocked(ch))
	}
	chans5 := e.channels5
	if chans5 == nil {
		chans5 = Channels5(e.inv.All())
	}
	for _, ch := range chans5 {
		s.Channels5 = append(s.Channels5, e.viewLocked(ch))
	}
	if e.lock != nil {
		l := *e.lock
		l.History = append([]int(nil), e.lock.History...)
		l.Top = append([]Transmitter(nil), e.lock.Top...)
		s.Lock = &l
	}
	if e.caps.Bluetooth && e.ble != nil {
		s.BTCount, s.HasBT = e.ble.Count(e.now()), true
	}
	if e.sink != nil {
		s.LogPaused = e.sink.Paused()
	}
	return s
}
