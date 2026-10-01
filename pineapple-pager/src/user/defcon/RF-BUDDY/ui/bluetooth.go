package main

import (
	"bufio"
	"context"
	"io"
	"os"
	"os/exec"
	"regexp"
	"strings"
	"sync"
	"time"
)

var leScanAddr = regexp.MustCompile(`^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$`)

// ParseLEScanLine extracts the device address from one `hcitool lescan` line.
func ParseLEScanLine(line string) (string, bool) {
	fields := strings.Fields(line)
	if len(fields) == 0 || !leScanAddr.MatchString(fields[0]) {
		return "", false
	}
	return strings.ToUpper(fields[0]), true
}

// BLECounter counts unique BLE addresses seen inside a rolling window.
type BLECounter struct {
	mu     sync.Mutex
	window time.Duration
	seen   map[string]time.Time
}

func NewBLECounter(window time.Duration) *BLECounter {
	return &BLECounter{window: window, seen: map[string]time.Time{}}
}

func (c *BLECounter) Observe(addr string, at time.Time) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if last, ok := c.seen[addr]; !ok || at.After(last) {
		c.seen[addr] = at
	}
}

func (c *BLECounter) Count(now time.Time) int {
	c.mu.Lock()
	defer c.mu.Unlock()
	for addr, at := range c.seen {
		if now.Sub(at) > c.window {
			delete(c.seen, addr)
		}
	}
	return len(c.seen)
}

// BLEScanner keeps a passive `hcitool lescan` running and feeds the counter.
type BLEScanner struct {
	Iface        string
	Counter      *BLECounter
	Now          func() time.Time
	RestartDelay time.Duration
}

// leScanArgs returns the hcitool arguments for a passive LE scan.
func leScanArgs(iface string) []string {
	return []string{"-i", iface, "lescan", "--passive", "--duplicates"}
}

func (s *BLEScanner) Run(ctx context.Context) {
	for ctx.Err() == nil {
		_ = exec.CommandContext(ctx, "hciconfig", s.Iface, "up").Run()
		cmd := exec.CommandContext(ctx, "hcitool", leScanArgs(s.Iface)...)
		if stdout, err := cmd.StdoutPipe(); err == nil && cmd.Start() == nil {
			s.consume(stdout)
			_ = cmd.Wait()
		}
		timer := time.NewTimer(s.RestartDelay)
		select {
		case <-ctx.Done():
			timer.Stop()
			return
		case <-timer.C:
		}
	}
}

func (s *BLEScanner) consume(r io.Reader) {
	sc := bufio.NewScanner(r)
	for sc.Scan() {
		if addr, ok := ParseLEScanLine(sc.Text()); ok {
			s.Counter.Observe(addr, s.Now())
		}
	}
}

// BluetoothAvailable reports whether hcitool and the adapter both exist.
func BluetoothAvailable(iface string) bool {
	if _, err := exec.LookPath("hcitool"); err != nil {
		return false
	}
	_, err := os.Stat("/sys/class/bluetooth/" + iface)
	return err == nil
}
