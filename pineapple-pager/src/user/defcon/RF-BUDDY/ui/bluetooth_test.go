package main

import (
	"strings"
	"testing"
	"time"
)

func TestParseLEScanLine(t *testing.T) {
	if addr, ok := ParseLEScanLine("aa:bb:cc:dd:ee:01 (unknown)"); !ok || addr != "AA:BB:CC:DD:EE:01" {
		t.Fatalf("parse = %q %v", addr, ok)
	}
	for _, bad := range []string{"LE Scan ...", "", "garbage line", "AA:BB:CC:DD:EE (unknown)"} {
		if _, ok := ParseLEScanLine(bad); ok {
			t.Fatalf("parsed %q", bad)
		}
	}
}

func TestBLECounterRollingWindow(t *testing.T) {
	t0 := time.Date(2026, 10, 1, 12, 0, 0, 0, time.UTC)
	c := NewBLECounter(30 * time.Second)
	c.Observe("A", t0)
	c.Observe("B", t0.Add(20*time.Second))
	c.Observe("A", t0.Add(25*time.Second))
	if got := c.Count(t0.Add(29 * time.Second)); got != 2 {
		t.Fatalf("count = %d, want 2", got)
	}
	if got := c.Count(t0.Add(51 * time.Second)); got != 1 {
		t.Fatalf("count after B expires = %d, want 1", got)
	}
	if got := c.Count(t0.Add(56 * time.Second)); got != 0 {
		t.Fatalf("count after window = %d, want 0", got)
	}
}

func TestBLEScannerConsumesHcitoolOutput(t *testing.T) {
	now := time.Date(2026, 10, 1, 12, 0, 0, 0, time.UTC)
	s := &BLEScanner{Counter: NewBLECounter(30 * time.Second), Now: func() time.Time { return now }}
	s.consume(strings.NewReader("LE Scan ...\nAA:BB:CC:DD:EE:01 (unknown)\naa:bb:cc:dd:ee:01 Phone\nAA:BB:CC:DD:EE:02 (unknown)\nnoise\n"))
	if got := s.Counter.Count(now); got != 2 {
		t.Fatalf("unique devices = %d, want 2", got)
	}
}

func TestLEScanIsPassive(t *testing.T) {
	if got := strings.Join(leScanArgs("hci0"), " "); got != "-i hci0 lescan --passive --duplicates" {
		t.Fatalf("leScanArgs = %q", got)
	}
}

func TestScanDisableArgs(t *testing.T) {
	if got := strings.Join(scanDisableArgs("hci0"), " "); got != "-i hci0 cmd 0x08 0x000c 00 00" {
		t.Fatalf("scanDisableArgs = %q", got)
	}
}
