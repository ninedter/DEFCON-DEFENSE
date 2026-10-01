package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func fakeBuzzerDir(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	for name, v := range map[string]string{"brightness": "0\n", "max_brightness": "255\n", "frequency": "523\n", "volume": "0\n"} {
		if err := os.WriteFile(filepath.Join(dir, name), []byte(v), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	return dir
}

func readTrim(t *testing.T, dir, name string) string {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(dir, name))
	if err != nil {
		t.Fatal(err)
	}
	return strings.TrimSpace(string(b))
}

func TestBuzzerBeepAndRestore(t *testing.T) {
	dir := fakeBuzzerDir(t)
	b, err := OpenBuzzer(dir, 2000, 60)
	if err != nil {
		t.Fatal(err)
	}
	b.Beep(time.Millisecond)
	if got := readTrim(t, dir, "brightness"); got != "0" {
		t.Fatalf("brightness after beep = %q", got)
	}
	if readTrim(t, dir, "frequency") != "2000" || readTrim(t, dir, "volume") != "60" {
		t.Fatal("beep must set frequency and volume")
	}
	raw, _ := os.ReadFile(filepath.Join(dir, "frequency"))
	if string(raw) != "2000\n" {
		t.Fatalf("frequency raw = %q, want decimal with newline", raw)
	}
	b.Close()
	if readTrim(t, dir, "frequency") != "523" || readTrim(t, dir, "volume") != "0" || readTrim(t, dir, "brightness") != "0" {
		t.Fatal("close must restore frequency/volume and leave brightness 0")
	}
}

func TestOpenBuzzerMissing(t *testing.T) {
	if _, err := OpenBuzzer(filepath.Join(t.TempDir(), "nope"), 2000, 128); err == nil {
		t.Fatal("missing dir must error")
	}
	dir := fakeBuzzerDir(t)
	os.Remove(filepath.Join(dir, "brightness"))
	if _, err := OpenBuzzer(dir, 2000, 60); err == nil {
		t.Fatal("missing brightness must error")
	}
	dir = fakeBuzzerDir(t)
	os.Remove(filepath.Join(dir, "max_brightness"))
	if _, err := OpenBuzzer(dir, 2000, 60); err == nil {
		t.Fatal("missing max_brightness must error")
	}
}

func TestBuzzerNilSafe(t *testing.T) {
	var b *Buzzer
	b.Beep(time.Millisecond)
	b.Close()
}

func TestBuzzerVolumeClamped(t *testing.T) {
	for in, want := range map[int]string{150: "100", -5: "0", 60: "60"} {
		dir := fakeBuzzerDir(t)
		b, err := OpenBuzzer(dir, 2000, in)
		if err != nil {
			t.Fatal(err)
		}
		b.Beep(time.Millisecond)
		if got := readTrim(t, dir, "volume"); got != want {
			t.Fatalf("volume %d wrote %q, want %q", in, got, want)
		}
		b.Close()
	}
}
