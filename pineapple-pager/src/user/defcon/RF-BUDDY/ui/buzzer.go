package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// Buzzer pulses the Pager's LED-class buzzer with plain sysfs file writes.
// The pre-existing frequency and volume are saved on open and restored on
// Close so other payloads see the buzzer unchanged.
type Buzzer struct {
	dir                 string
	freq, vol           int
	maxBrightness       string
	savedFreq, savedVol string
}

func OpenBuzzer(dir string, freqHz, volume int) (*Buzzer, error) {
	read := func(name string) (string, error) {
		b, err := os.ReadFile(filepath.Join(dir, name))
		if err != nil {
			return "", err
		}
		return strings.TrimSpace(string(b)), nil
	}
	b := &Buzzer{dir: dir, freq: freqHz, vol: volume}
	var err error
	if _, err = read("brightness"); err != nil {
		return nil, fmt.Errorf("buzzer: %w", err)
	}
	if b.maxBrightness, err = read("max_brightness"); err != nil {
		return nil, fmt.Errorf("buzzer: %w", err)
	}
	// frequency and volume are optional on some firmware; restore only if present.
	b.savedFreq, _ = read("frequency")
	b.savedVol, _ = read("volume")
	return b, nil
}

func (b *Buzzer) write(name, value string) {
	_ = os.WriteFile(filepath.Join(b.dir, name), []byte(value+"\n"), 0o644)
}

// Beep sounds the buzzer for d, then silences it.
func (b *Buzzer) Beep(d time.Duration) {
	if b == nil {
		return
	}
	b.write("frequency", strconv.Itoa(b.freq))
	b.write("volume", strconv.Itoa(b.vol))
	b.write("brightness", b.maxBrightness)
	time.Sleep(d)
	b.write("brightness", "0")
}

// Close silences the buzzer and restores the saved frequency and volume.
func (b *Buzzer) Close() {
	if b == nil {
		return
	}
	b.write("brightness", "0")
	if b.savedFreq != "" {
		b.write("frequency", b.savedFreq)
	}
	if b.savedVol != "" {
		b.write("volume", b.savedVol)
	}
}
