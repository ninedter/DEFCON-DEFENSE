package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestParseOptionsDefaults(t *testing.T) {
	o, err := parseOptions(nil)
	if err != nil {
		t.Fatal(err)
	}
	if o.iface != "wlan1mon" || o.btIface != "hci0" || o.lootDir != "/root/loot/rf_buddy" || o.dwellMS != 250 ||
		o.logMaxMB != 20 || o.minFreeMB != 64 || o.virtualListen != ":1472" || o.thresholds != DefaultThresholds() {
		t.Fatalf("defaults = %+v", o)
	}
}

func TestParseOptionsOverrides(t *testing.T) {
	o, err := parseOptions([]string{"--office-ssid", "OfficeNet", "--dwell-ms", "400", "--bt-dense-count", "12", "--retry-high-pct", "30", "--airtime-high-pct", "60"})
	if err != nil {
		t.Fatal(err)
	}
	if o.officeSSID != "OfficeNet" || o.dwellMS != 400 || o.thresholds.BTDenseCount != 12 || o.thresholds.RetryHighPct != 30 || o.thresholds.AirtimeHighPct != 60 {
		t.Fatalf("overrides = %+v", o)
	}
	if _, err := parseOptions([]string{"--dwell-ms", "10"}); err == nil {
		t.Fatal("dwell below 50 ms must be rejected")
	}
}

func TestTickWriterWritesOnlyOnChange(t *testing.T) {
	path := filepath.Join(t.TempDir(), "tick_ms")
	w := &tickWriter{path: path}
	if err := w.Set(1150 * time.Millisecond); err != nil {
		t.Fatal(err)
	}
	if b, _ := os.ReadFile(path); string(b) != "1150\n" {
		t.Fatalf("tick file = %q", b)
	}
	if err := os.WriteFile(path, []byte("sentinel"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := w.Set(1150 * time.Millisecond); err != nil {
		t.Fatal(err)
	}
	if b, _ := os.ReadFile(path); string(b) != "sentinel" {
		t.Fatal("unchanged interval must not rewrite the tick file")
	}
	if err := w.Set(0); err != nil {
		t.Fatal(err)
	}
	if b, _ := os.ReadFile(path); string(b) != "0\n" {
		t.Fatalf("tick off = %q", b)
	}
	if err := (&tickWriter{}).Set(time.Second); err != nil {
		t.Fatal("empty path must be a no-op")
	}
}

func TestSessionTextListsConfigAndCapabilities(t *testing.T) {
	o, _ := parseOptions([]string{"--office-ssid", "OfficeNet"})
	text := sessionText(o, Capabilities{Tune: true, Capture: true}, time.Date(2026, 10, 1, 12, 0, 0, 0, time.UTC))
	for _, want := range []string{"started: 2026-10-01T12:00:00Z", "office_ssid: OfficeNet", "capture: true", "bluetooth: false", "unavailable: BT", "retry_high_pct: 25", "airtime_high_pct: 50"} {
		if !strings.Contains(text, want) {
			t.Errorf("session text missing %q:\n%s", want, text)
		}
	}
}
