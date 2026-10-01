// RF-BUDDY full-screen Pager application.
//
// Locks Recon to one channel at a time, passively measures Wi-Fi airtime,
// retries, AP crowding, and nearby Bluetooth, renders the 480x222 UI to the
// Pager framebuffer and Virtual Pager, and logs a survey session.
package main

import (
	"bytes"
	"context"
	"errors"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"time"
)

type options struct {
	framebuffer, inputDevice, readyFile, virtualListen, previewDir string
	iface, btIface, lootDir, tickFile, officeSSID                  string
	dwellMS, logMaxMB, minFreeMB                                   int
	thresholds                                                     Thresholds
}

func parseOptions(args []string) (options, error) {
	fs := flag.NewFlagSet("rf-buddy-ui", flag.ContinueOnError)
	o := options{thresholds: DefaultThresholds()}
	fs.StringVar(&o.framebuffer, "framebuffer", "/dev/fb0", "Pager framebuffer")
	fs.StringVar(&o.inputDevice, "input-device", "/dev/input/event0", "Pager evdev button device")
	fs.StringVar(&o.readyFile, "ready-file", "", "written after the first frame is on screen")
	fs.StringVar(&o.virtualListen, "virtual-listen", ":1472", "Virtual Pager bridge listen address")
	fs.StringVar(&o.previewDir, "preview-dir", "", "render preview PNGs and exit")
	fs.StringVar(&o.iface, "iface", "wlan1mon", "monitor interface")
	fs.StringVar(&o.btIface, "bt-iface", "hci0", "Bluetooth adapter")
	fs.StringVar(&o.lootDir, "loot-dir", "/root/loot/rf_buddy", "session log root")
	fs.StringVar(&o.tickFile, "tick-file", "", "lock-on tick interval file read by payload.sh")
	fs.StringVar(&o.officeSSID, "office-ssid", "", "office SSID for WEAK COVERAGE")
	fs.IntVar(&o.dwellMS, "dwell-ms", 250, "overview dwell per channel")
	fs.IntVar(&o.logMaxMB, "log-max-mb", 20, "per-session log cap")
	fs.IntVar(&o.minFreeMB, "min-free-mb", 64, "pause logging below this free space")
	fs.Float64Var(&o.thresholds.RetryHighPct, "retry-high-pct", o.thresholds.RetryHighPct, "retry % for INTERFERENCE")
	fs.Float64Var(&o.thresholds.AirtimeHighPct, "airtime-high-pct", o.thresholds.AirtimeHighPct, "airtime % for CONGESTION")
	fs.IntVar(&o.thresholds.OverlapMinDBm, "overlap-min-dbm", o.thresholds.OverlapMinDBm, "neighbour AP signal for CHANNEL OVERLAP")
	fs.IntVar(&o.thresholds.BTDenseCount, "bt-dense-count", o.thresholds.BTDenseCount, "BLE devices for BT DENSE")
	fs.IntVar(&o.thresholds.WeakSignalDBm, "weak-signal-dbm", o.thresholds.WeakSignalDBm, "office AP below this is WEAK COVERAGE")
	if err := fs.Parse(args); err != nil {
		return o, err
	}
	if o.dwellMS < 50 {
		return o, errors.New("dwell-ms must be at least 50")
	}
	return o, nil
}

func main() {
	o, err := parseOptions(os.Args[1:])
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
	if o.previewDir != "" {
		if err := renderPreviews(o.previewDir); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		return
	}
	if err := run(o); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

// tickWriter publishes the lock-on tick interval (ms, 0 = off) for the
// payload.sh tick loop, rewriting the file only when the value changes.
type tickWriter struct {
	path    string
	last    time.Duration
	written bool
}

func (w *tickWriter) Set(d time.Duration) error {
	if w.path == "" || (w.written && d == w.last) {
		return nil
	}
	tmp := w.path + ".tmp"
	if err := os.WriteFile(tmp, []byte(strconv.FormatInt(d.Milliseconds(), 10)+"\n"), 0o644); err != nil {
		return err
	}
	if err := os.Rename(tmp, w.path); err != nil {
		return err
	}
	w.last, w.written = d, true
	return nil
}

func sessionText(o options, c Capabilities, started time.Time) string {
	t := o.thresholds
	lines := []string{
		"started: " + started.Format(time.RFC3339),
		"iface: " + o.iface,
		"office_ssid: " + o.officeSSID,
		fmt.Sprintf("dwell_ms: %d", o.dwellMS),
		fmt.Sprintf("retry_high_pct: %.0f", t.RetryHighPct),
		fmt.Sprintf("airtime_high_pct: %.0f", t.AirtimeHighPct),
		fmt.Sprintf("overlap_min_dbm: %d", t.OverlapMinDBm),
		fmt.Sprintf("bt_dense_count: %d", t.BTDenseCount),
		fmt.Sprintf("weak_signal_dbm: %d", t.WeakSignalDBm),
		fmt.Sprintf("capture: %t", c.Capture),
		fmt.Sprintf("channel_lock: %t", c.Tune),
		fmt.Sprintf("bluetooth: %t", c.Bluetooth),
		"unavailable: " + strings.Join(c.Unavailable(), ", "),
		"fatal: " + c.FatalReason,
	}
	return strings.Join(lines, "\n") + "\n"
}

func run(o options) error {
	fb, err := os.OpenFile(o.framebuffer, os.O_RDWR, 0)
	if err != nil {
		return fmt.Errorf("open framebuffer: %w", err)
	}
	defer fb.Close()

	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM, syscall.SIGHUP)
	defer cancel()

	started := time.Now()
	logger, err := OpenLogger(o.lootDir, started, int64(o.logMaxMB)<<20, uint64(o.minFreeMB)<<20, freeBytes, time.Now)
	if err != nil {
		return fmt.Errorf("open survey log: %w", err)
	}
	defer logger.Close()

	capturer, err := OpenCapturer(o.iface)
	if err != nil {
		capturer = nil
	}
	if capturer != nil {
		defer capturer.Close()
	}
	radio := NewPagerRadio(o.iface, execRunner, capturer, 30*time.Millisecond)
	// Always hand the channel back to Recon, even after a fatal probe.
	defer func() { _ = radio.Release(context.Background()) }()

	cfg := DefaultEngineConfig()
	cfg.Dwell = time.Duration(o.dwellMS) * time.Millisecond
	cfg.Thresholds = o.thresholds
	cfg.OfficeSSID = o.officeSSID
	ble := NewBLECounter(30 * time.Second)
	engine := NewEngine(cfg, radio, NewInventory(nil), ble, logger, time.Now)
	view := newUI(engine, logger, time.Now)
	tick := &tickWriter{path: o.tickFile}
	defer func() { _ = tick.Set(0) }()

	mir := newMirror()
	// Keep only one unhandled press so double clicks cannot skip a screen.
	buttons := make(chan string, 1)
	if o.virtualListen != "" {
		go mir.serve(ctx, o.virtualListen, buttons)
	}
	go func() {
		// Let the A press that confirmed the payload launch finish first.
		timer := time.NewTimer(inputStartupDelay)
		defer timer.Stop()
		select {
		case <-timer.C:
			readButtons(ctx, o.inputDevice, buttons)
		case <-ctx.Done():
		}
	}()

	var displayedPixels, displayedFrame, scratch []byte
	redraw := func() error {
		canvas := view.Render(engine.Snapshot(), time.Now())
		if bytes.Equal(displayedPixels, canvas.Pix) {
			return nil
		}
		displayedPixels = append(displayedPixels[:0], canvas.Pix...)
		frame := canvasToFramebuffer(canvas)
		if err := writeFramebuffer(fb, frame); err != nil {
			return err
		}
		displayedFrame = append(displayedFrame[:0], frame...)
		mir.publish(canvas)
		return nil
	}
	if err := redraw(); err != nil {
		return err
	}
	if o.readyFile != "" {
		if err := os.WriteFile(o.readyFile, []byte("ready\n"), 0o600); err != nil {
			return fmt.Errorf("write ready file: %w", err)
		}
		defer os.Remove(o.readyFile)
	}

	probeDone := make(chan Capabilities, 1)
	go func() {
		probeDone <- Probe(ctx, ProbeDeps{
			Radio: radio, Bluetooth: func() bool { return BluetoothAvailable(o.btIface) },
			Settle: 500 * time.Millisecond, CaptureWindow: 300 * time.Millisecond,
		})
	}()

	ticker := time.NewTicker(250 * time.Millisecond)
	defer ticker.Stop()
	owner := time.NewTicker(ownershipPollInterval)
	defer owner.Stop()
	minute := time.Now().Minute()
	for {
		select {
		case <-ctx.Done():
			return nil
		case caps := <-probeDone:
			view.SetProbe(caps)
			_ = logger.WriteSession(sessionText(o, caps, started))
			if !caps.Fatal() {
				engine.SetCapabilities(caps)
				if caps.Bluetooth {
					scanner := &BLEScanner{Iface: o.btIface, Counter: ble, Now: time.Now, RestartDelay: 2 * time.Second}
					go scanner.Run(ctx)
				}
				go engine.Run(ctx)
			}
			if err := redraw(); err != nil {
				return err
			}
		case b := <-buttons:
			if view.HandleButton(b, engine.Snapshot()) {
				return nil
			}
			if err := redraw(); err != nil {
				return err
			}
		case <-engine.Updates():
			_ = tick.Set(view.TickInterval(engine.Snapshot()))
			if err := redraw(); err != nil {
				return err
			}
		case now := <-ticker.C:
			changed := view.Advance(now)
			_ = tick.Set(view.TickInterval(engine.Snapshot()))
			if changed || now.Minute() != minute {
				minute = now.Minute()
				if err := redraw(); err != nil {
					return err
				}
			}
		case <-owner.C:
			// The native payload runner can repaint after launch; reclaim the
			// display only when our frame has been displaced.
			if err := maintainDisplayOwnership(fb, displayedFrame, &scratch); err != nil {
				return err
			}
		}
	}
}
