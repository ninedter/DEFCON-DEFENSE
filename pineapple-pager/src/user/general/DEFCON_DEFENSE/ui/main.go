// DEFCON Defense custom full-screen UI for the WiFi Pineapple Pager.
//
// The Pager exposes a 222x480 RGB565 framebuffer rotated counter-clockwise
// onto its 480x222 landscape LCD. This application renders a 480x222 canvas,
// maps it into the device framebuffer, and receives both physical and Virtual
// Pager buttons through the firmware WAIT_FOR_INPUT command.
package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/csv"
	"errors"
	"flag"
	"fmt"
	"image"
	"image/color"
	"image/draw"
	"image/png"
	"io"
	"net/http"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"golang.org/x/image/font"
	"golang.org/x/image/font/inconsolata"
	"golang.org/x/image/font/opentype"
	"golang.org/x/image/math/fixed"
)

const (
	screenWidth   = 480
	screenHeight  = 222
	fbWidth       = 222
	fbHeight      = 480
	frameBytes    = fbWidth * fbHeight * 2
	textCellWidth = 8

	passiveCaptureLabel   = "PASSIVE CAPTURE:"
	passiveCaptureLabelX  = 244
	passiveCaptureIconGap = 8
)

var (
	black  = color.RGBA{0x00, 0x00, 0x00, 0xff}
	white  = color.RGBA{0xf4, 0xf4, 0xee, 0xff}
	cyan   = color.RGBA{0x69, 0xd5, 0xf1, 0xff}
	cyan2  = color.RGBA{0x2d, 0xa8, 0xc4, 0xff}
	yellow = color.RGBA{0xff, 0xd5, 0x1f, 0xff}
	green  = color.RGBA{0x5d, 0xe1, 0x42, 0xff}
	red    = color.RGBA{0xff, 0x3f, 0x2f, 0xff}
	dim    = color.RGBA{0x75, 0x82, 0x87, 0xff}
)

type screenKind int

const (
	screenGeneral screenKind = iota
	screenThreat
	screenEvidence
	screenEvidenceDetail
)

type AP struct {
	BSSID, SSID, Channel, Frequency, Signal, Seen, Packets, Band string
}

type Threat struct {
	BSSID, SSID, Channel, Band, Signal, Packets, Event, Deauth, Level string
}

type Evidence struct {
	Epoch, ID, Event, Severity, SSID, BSSID, Band, Channel, Signal string
	Duration, Size                                                 int64
	Hash, Status, Trigger, Path                                    string
}

type Capture struct {
	Status, ID, Epoch, Path, Event, Severity, SSID, BSSID string
	Band, Channel, Signal, Duration, Trigger              string
}

type liveState struct {
	Now          time.Time
	Battery      int
	Monitoring   string
	UpdatedEpoch int64
	APs          []AP
	Threats      []Threat
	Evidence     []Evidence
	Capture      Capture
	Watched      int
	UsedBytes    int64
	StorageMax   int64
}

type renderer struct {
	material map[int]font.Face
}

type app struct {
	dataDir, pcapDir, actionFile, muteFile string
	framebuffer, previewDir                string
	virtualListen                          string
	preview                                bool
	renderer                               *renderer
	webMu                                  sync.RWMutex
	webPNG                                 []byte
	webETag                                string
	webRevision                            uint64
	webUpdated                             chan struct{}

	mu               sync.Mutex
	screen           screenKind
	generalSelected  int
	threatSelected   int
	evidenceSelected int
	evidencePage     int
	muted            bool
	toast            string
	toastUntil       time.Time
	lastButton       string
	lastButtonAt     time.Time
}

func main() {
	var materialPath string
	a := &app{webUpdated: make(chan struct{})}
	flag.StringVar(&a.dataDir, "data-dir", "/root/loot/defcon_defense", "DEFCON Defense state directory")
	flag.StringVar(&a.pcapDir, "pcap-dir", "/root/loot/pcap", "managed PCAP directory")
	flag.StringVar(&a.actionFile, "action-file", "", "action queue file")
	flag.StringVar(&a.muteFile, "mute-file", "", "alert mute state file")
	flag.StringVar(&a.framebuffer, "framebuffer", "/dev/fb0", "Pager framebuffer")
	flag.StringVar(&a.previewDir, "preview-dir", "", "render the three reference states as PNG files")
	flag.StringVar(&a.virtualListen, "virtual-listen", ":1472", "Virtual Pager bridge listen address")
	flag.StringVar(&materialPath, "material-font", "/pineapple/ui/MaterialIcons-Regular.ttf", "Material Icons font path")
	flag.BoolVar(&a.preview, "preview", false, "use deterministic reference data")
	flag.Parse()

	if a.actionFile == "" {
		a.actionFile = filepath.Join(a.dataDir, "ui_action.psv")
	}
	if a.muteFile == "" {
		a.muteFile = filepath.Join(a.dataDir, "ui_muted")
	}
	a.renderer = newRenderer(materialPath)

	if a.previewDir != "" {
		if err := a.renderPreviews(); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		return
	}
	if err := a.run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func newRenderer(materialPath string) *renderer {
	r := &renderer{material: map[int]font.Face{}}
	b, err := os.ReadFile(materialPath)
	if err != nil {
		return r
	}
	f, err := opentype.Parse(b)
	if err != nil {
		return r
	}
	for _, size := range []int{12, 14, 16, 18, 20, 24, 28} {
		face, faceErr := opentype.NewFace(f, &opentype.FaceOptions{Size: float64(size), DPI: 72, Hinting: font.HintingFull})
		if faceErr == nil {
			r.material[size] = face
		}
	}
	return r
}

func (a *app) renderPreviews() error {
	if err := os.MkdirAll(a.previewDir, 0o755); err != nil {
		return err
	}
	a.preview = true
	state := a.loadState()
	clearState := state
	clearState.Threats = nil
	clearState.Capture = Capture{Status: "IDLE"}
	emptyEvidenceState := clearState
	emptyEvidenceState.Evidence = nil
	emptyEvidenceState.UsedBytes = 0

	stressState := previewState()
	stressState.Monitoring = "RECONNECTING TO MONITOR SERVICE"
	stressState.Threats = append([]Threat(nil), stressState.Threats...)
	stressState.Threats[0].SSID = "DEFCON-CONFERENCE-GUEST-NETWORK-WITH-A-LONG-NAME"
	stressState.Threats[0].Event = "UNRECOGNIZED_SECURITY_EVENT_WITH_A_VERY_LONG_NAME"
	stressState.Evidence = append([]Evidence(nil), stressState.Evidence...)
	stressState.Evidence[0].SSID = "DEFCON-CONFERENCE-GUEST-NETWORK-WITH-A-LONG-NAME"
	stressState.Evidence[0].Event = "UNRECOGNIZED_SECURITY_EVENT_WITH_A_VERY_LONG_NAME"
	stressState.Evidence[0].Status = "VERIFICATION_PENDING"
	stressState.Evidence[0].Size = 9876543210
	views := []struct {
		name   string
		screen screenKind
		state  liveState
		toast  string
	}{
		{"01-general.png", screenGeneral, state, ""},
		{"02-threat.png", screenThreat, state, ""},
		{"03-evidence.png", screenEvidence, state, ""},
		{"04-evidence-detail.png", screenEvidenceDetail, state, ""},
		{"05-threat-clear.png", screenThreat, clearState, ""},
		{"06-evidence-empty.png", screenEvidence, emptyEvidenceState, ""},
		{"07-stress-general.png", screenGeneral, stressState, ""},
		{"08-stress-threat.png", screenThreat, stressState, ""},
		{"09-stress-evidence.png", screenEvidence, stressState, ""},
		{"10-stress-evidence-detail.png", screenEvidenceDetail, stressState, ""},
		{"11-stress-toast.png", screenGeneral, stressState, "A VERY LONG OPERATOR MESSAGE THAT MUST REMAIN INSIDE THE TOAST PANEL WITHOUT OVERLAP"},
	}
	for _, view := range views {
		a.screen = view.screen
		a.toast = view.toast
		if view.toast != "" {
			a.toastUntil = time.Now().Add(time.Minute)
		} else {
			a.toastUntil = time.Time{}
		}
		img := a.render(view.state)
		f, err := os.Create(filepath.Join(a.previewDir, view.name))
		if err != nil {
			return err
		}
		err = png.Encode(f, img)
		closeErr := f.Close()
		if err != nil {
			return err
		}
		if closeErr != nil {
			return closeErr
		}
	}
	return nil
}

func (a *app) run() error {
	fb, err := os.OpenFile(a.framebuffer, os.O_WRONLY, 0)
	if err != nil {
		return fmt.Errorf("open framebuffer: %w", err)
	}
	defer fb.Close()

	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM, syscall.SIGHUP)
	defer cancel()
	if a.virtualListen != "" {
		go a.serveVirtualPager(ctx)
	}
	buttons := make(chan string, 4)
	go readButtons(ctx, buttons)

	stateTicker := time.NewTicker(time.Second)
	defer stateTicker.Stop()

	state := a.loadState()
	stateFingerprint := a.stateFingerprint()
	displayedMinute := state.Now.Format("15:04")
	var displayedPixels []byte
	if err := a.updateDisplay(fb, state, &displayedPixels); err != nil {
		return err
	}
	for {
		select {
		case <-ctx.Done():
			return nil
		case button := <-buttons:
			if a.handleButton(button, state) {
				return nil
			}
			if err := a.updateDisplay(fb, state, &displayedPixels); err != nil {
				return err
			}
		case <-stateTicker.C:
			now := time.Now()
			nextFingerprint := a.stateFingerprint()
			minuteChanged := now.Format("15:04") != displayedMinute
			stateChanged := nextFingerprint != stateFingerprint
			if stateChanged || minuteChanged {
				state = a.loadState()
				stateFingerprint = nextFingerprint
			} else {
				state.Now = now
			}
			if stateChanged || minuteChanged || a.timedRefreshNeeded(state, now) {
				if err := a.updateDisplay(fb, state, &displayedPixels); err != nil {
					return err
				}
				displayedMinute = state.Now.Format("15:04")
			}
		}
	}
}

func (a *app) stateFingerprint() string {
	paths := []string{
		filepath.Join(a.dataDir, "ui_state.psv"),
		filepath.Join(a.dataDir, "latest_snapshot.tsv"),
		filepath.Join(a.dataDir, "latest_threats.tsv"),
		filepath.Join(a.dataDir, "pcap_index.tsv"),
		filepath.Join(a.dataDir, "pcap_capture.psv"),
		filepath.Join(a.dataDir, "watched_aps.tsv"),
		a.muteFile,
	}
	var fingerprint strings.Builder
	for _, path := range paths {
		info, err := os.Stat(path)
		if err != nil {
			fingerprint.WriteString("missing|")
			continue
		}
		fingerprint.WriteString(strconv.FormatInt(info.Size(), 10))
		fingerprint.WriteByte(':')
		fingerprint.WriteString(strconv.FormatInt(info.ModTime().UnixNano(), 10))
		fingerprint.WriteByte('|')
	}
	return fingerprint.String()
}

func (a *app) timedRefreshNeeded(state liveState, now time.Time) bool {
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.toast != "" {
		if !now.Before(a.toastUntil) {
			a.toast = ""
		}
		return true
	}
	return state.Capture.Status == "CAPTURING"
}

func (a *app) updateDisplay(fb io.WriteSeeker, state liveState, displayedPixels *[]byte) error {
	canvas := a.render(state)
	if bytes.Equal(*displayedPixels, canvas.Pix) {
		return nil
	}
	*displayedPixels = append((*displayedPixels)[:0], canvas.Pix...)
	a.publishPNG(canvas)
	frame := canvasToFramebuffer(canvas)
	if _, err := fb.Seek(0, io.SeekStart); err != nil {
		return fmt.Errorf("seek framebuffer: %w", err)
	}
	if _, err := fb.Write(frame); err != nil {
		return fmt.Errorf("write framebuffer: %w", err)
	}
	return nil
}

func (a *app) publishPNG(img image.Image) {
	var b bytes.Buffer
	encoder := png.Encoder{CompressionLevel: png.BestSpeed}
	if encoder.Encode(&b, img) != nil {
		return
	}
	a.webMu.Lock()
	a.webPNG = append(a.webPNG[:0], b.Bytes()...)
	a.webRevision++
	a.webETag = fmt.Sprintf("\"defcon-%x\"", a.webRevision)
	if a.webUpdated != nil {
		close(a.webUpdated)
	}
	a.webUpdated = make(chan struct{})
	a.webMu.Unlock()
}

func (a *app) serveVirtualPager(ctx context.Context) {
	mux := http.NewServeMux()
	mux.HandleFunc("/health", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Access-Control-Allow-Origin", "*")
		w.Header().Set("Cache-Control", "no-store")
		w.WriteHeader(http.StatusOK)
		_, _ = io.WriteString(w, "DEFCON Defense UI active\n")
	})
	mux.HandleFunc("/screen.png", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Access-Control-Allow-Origin", "*")
		w.Header().Set("Access-Control-Expose-Headers", "ETag")
		w.Header().Set("Cache-Control", "no-cache")
		w.Header().Set("Content-Type", "image/png")
		clientETag := r.Header.Get("If-None-Match")
		if clientETag == "" {
			clientETag = r.URL.Query().Get("rev")
		}
		for {
			a.webMu.RLock()
			etag := a.webETag
			updated := a.webUpdated
			if etag == "" || clientETag != etag {
				b := append([]byte(nil), a.webPNG...)
				a.webMu.RUnlock()
				if len(b) == 0 {
					http.Error(w, "screen not ready", http.StatusServiceUnavailable)
					return
				}
				w.Header().Set("ETag", etag)
				_, _ = w.Write(b)
				return
			}
			a.webMu.RUnlock()
			if r.URL.Query().Get("wait") == "1" && updated != nil {
				timer := time.NewTimer(5 * time.Second)
				select {
				case <-updated:
					timer.Stop()
					continue
				case <-timer.C:
				case <-r.Context().Done():
					timer.Stop()
					return
				}
			}
			w.Header().Set("ETag", etag)
			w.WriteHeader(http.StatusNotModified)
			return
		}
	})
	server := &http.Server{Addr: a.virtualListen, Handler: mux, ReadHeaderTimeout: 2 * time.Second}
	go func() {
		<-ctx.Done()
		shutdownCtx, cancel := context.WithTimeout(context.Background(), time.Second)
		defer cancel()
		_ = server.Shutdown(shutdownCtx)
	}()
	_ = server.ListenAndServe()
}

func readButtons(ctx context.Context, out chan<- string) {
	for ctx.Err() == nil {
		cmd := exec.CommandContext(ctx, "WAIT_FOR_INPUT")
		b, err := cmd.Output()
		if ctx.Err() != nil {
			return
		}
		if err != nil {
			time.Sleep(150 * time.Millisecond)
			continue
		}
		button := normalizeButton(string(b))
		switch button {
		case "A", "B", "UP", "DOWN", "LEFT", "RIGHT":
			select {
			case out <- button:
			case <-ctx.Done():
				return
			}
		}
	}
}

func normalizeButton(raw string) string {
	button := strings.ToUpper(strings.TrimSpace(raw))
	button = strings.NewReplacer(" ", "", "_", "", "-", "").Replace(button)
	switch button {
	case "ENTER", "RETURN":
		return "A"
	case "ESC", "ESCAPE", "BACK":
		return "B"
	case "ARROWUP":
		return "UP"
	case "ARROWDOWN":
		return "DOWN"
	case "ARROWLEFT":
		return "LEFT"
	case "ARROWRIGHT":
		return "RIGHT"
	default:
		return button
	}
}

func (a *app) handleButton(button string, s liveState) (exit bool) {
	a.mu.Lock()
	defer a.mu.Unlock()
	now := time.Now()
	if button == a.lastButton && now.Sub(a.lastButtonAt) < 170*time.Millisecond {
		return false
	}
	a.lastButton, a.lastButtonAt = button, now

	switch a.screen {
	case screenGeneral:
		switch button {
		case "UP":
			a.generalSelected = (a.generalSelected + 2) % 3
		case "DOWN":
			a.generalSelected = (a.generalSelected + 1) % 3
		case "LEFT", "RIGHT":
			a.screen = screenEvidence
		case "A":
			switch a.generalSelected {
			case 0:
				a.screen = screenThreat
			case 1:
				a.toast = fmt.Sprintf("LIVE RF: %d NETWORKS SCANNING", len(s.APs))
				a.toastUntil = now.Add(2 * time.Second)
			case 2:
				a.toast = fmt.Sprintf("%d MONITORED NETWORKS", s.Watched)
				a.toastUntil = now.Add(2 * time.Second)
			}
		case "B":
			return true
		}
	case screenThreat:
		n := len(s.Threats)
		if n < 1 {
			n = 1
		}
		switch button {
		case "UP":
			a.threatSelected = (a.threatSelected + n - 1) % n
		case "DOWN":
			a.threatSelected = (a.threatSelected + 1) % n
		case "LEFT":
			a.screen = screenGeneral
		case "RIGHT":
			a.screen = screenEvidence
		case "A":
			if len(s.Threats) > 0 {
				t := s.Threats[a.threatSelected%len(s.Threats)]
				a.queueCapture(t)
				a.toast = "PASSIVE PCAP CAPTURE REQUESTED"
				a.toastUntil = now.Add(2 * time.Second)
			} else {
				a.toast = "NO ACTIVE THREAT TO CAPTURE"
				a.toastUntil = now.Add(2 * time.Second)
			}
		case "B":
			a.muted = !a.muted
			if a.muted {
				_ = os.WriteFile(a.muteFile, []byte("1\n"), 0o600)
				a.toast = "THREAT AUDIO MUTED"
			} else {
				_ = os.Remove(a.muteFile)
				a.toast = "THREAT AUDIO ACTIVE"
			}
			a.toastUntil = now.Add(2 * time.Second)
		}
	case screenEvidence:
		n := len(s.Evidence)
		if n < 1 {
			n = 1
		}
		switch button {
		case "UP":
			a.evidenceSelected = (a.evidenceSelected + n - 1) % n
		case "DOWN":
			a.evidenceSelected = (a.evidenceSelected + 1) % n
		case "LEFT":
			if len(s.Evidence) <= 3 || a.evidencePage == 0 {
				a.screen = screenGeneral
			} else {
				a.evidencePage--
				a.evidenceSelected = a.evidencePage * 3
			}
		case "RIGHT":
			pages := (len(s.Evidence) + 2) / 3
			if pages > 1 {
				a.evidencePage = (a.evidencePage + 1) % pages
				a.evidenceSelected = a.evidencePage * 3
			} else {
				a.screen = screenGeneral
			}
		case "A":
			if len(s.Evidence) > 0 {
				a.screen = screenEvidenceDetail
			}
		case "B":
			a.screen = screenGeneral
		}
	case screenEvidenceDetail:
		switch button {
		case "A":
			if len(s.Evidence) > 0 {
				e := s.Evidence[a.evidenceSelected%len(s.Evidence)]
				a.queueAction("VERIFY", e.ID)
				a.toast = "SHA-256 VERIFICATION REQUESTED"
				a.toastUntil = now.Add(2 * time.Second)
			}
		case "B", "LEFT":
			a.screen = screenEvidence
		case "RIGHT":
			a.screen = screenGeneral
		}
	}
	return false
}

func (a *app) queueCapture(t Threat) {
	a.queueAction("CAPTURE", t.Event, t.SSID, t.BSSID, t.Band, t.Channel, t.Signal)
}

func (a *app) queueAction(fields ...string) {
	for i := range fields {
		fields[i] = cleanField(fields[i])
	}
	tmp := a.actionFile + ".tmp"
	_ = os.MkdirAll(filepath.Dir(a.actionFile), 0o755)
	if os.WriteFile(tmp, []byte(strings.Join(fields, "|")+"\n"), 0o600) == nil {
		_ = os.Rename(tmp, a.actionFile)
	}
}

func cleanField(s string) string {
	s = strings.Map(func(r rune) rune {
		switch r {
		case '|', '\t', '\r', '\n':
			return ' '
		}
		return r
	}, s)
	if len(s) > 128 {
		s = s[:128]
	}
	return s
}

func (a *app) loadState() liveState {
	if a.preview {
		return previewState()
	}
	s := liveState{Now: time.Now(), Battery: 0, Monitoring: "ACTIVE", StorageMax: 256 * 1024 * 1024}
	s.Battery = readIntFile("/sys/class/power_supply/bq27546-0/capacity")
	if s.Battery < 0 || s.Battery > 100 {
		s.Battery = 0
	}
	ui := readKeyValues(filepath.Join(a.dataDir, "ui_state.psv"))
	if ui["monitoring"] != "" {
		s.Monitoring = strings.ToUpper(ui["monitoring"])
	}
	s.UpdatedEpoch, _ = strconv.ParseInt(ui["updated_epoch"], 10, 64)
	s.APs = loadAPs(filepath.Join(a.dataDir, "latest_snapshot.tsv"))
	s.Threats = loadThreats(filepath.Join(a.dataDir, "latest_threats.tsv"))
	s.Evidence = loadEvidence(filepath.Join(a.dataDir, "pcap_index.tsv"))
	s.Capture = loadCapture(filepath.Join(a.dataDir, "pcap_capture.psv"))
	s.Watched = countRows(filepath.Join(a.dataDir, "watched_aps.tsv"))
	for _, e := range s.Evidence {
		s.UsedBytes += e.Size
	}
	a.muted = fileExists(a.muteFile)
	return s
}

func previewState() liveState {
	now := time.Date(2026, 8, 10, 14, 32, 23, 0, time.Local)
	return liveState{
		Now: now, Battery: 83, Monitoring: "ACTIVE", Watched: 3,
		StorageMax: 512 * 1024 * 1024, UsedBytes: 48 * 1024 * 1024,
		APs: []AP{
			{"AA:BB:CC:DD:EE:FF", "DEFCON-GUEST", "6", "2437", "-41", "", "1522", "2.4GHz"},
			{"10:20:30:40:50:60", "HOTEL-WIFI", "44", "5220", "-58", "", "812", "5GHz"},
			{"DE:AD:BE:EF:00:01", "CONFERENCE", "11", "2462", "-65", "", "390", "2.4GHz"},
		},
		Threats: []Threat{
			{"AA:BB:CC:DD:EE:FF", "DEFCON-GUEST", "6", "2.4GHz", "-41", "1522", "DEAUTH_ACTIVITY", "4", "red"},
			{"10:20:30:40:50:60", "HOTEL-WIFI", "44", "5GHz", "-58", "812", "TRUSTED_SSID_NEW_BSSID", "0", "red"},
		},
		Capture: Capture{"CAPTURING", "preview", strconv.FormatInt(now.Unix(), 10), "/root/loot/pcap/preview.pcap", "DEAUTH_ACTIVITY", "HIGH", "DEFCON-GUEST", "AA:BB:CC:DD:EE:FF", "2.4GHz", "6", "-41", "30", "automatic"},
		Evidence: []Evidence{
			{strconv.FormatInt(now.Unix(), 10), "1", "DEAUTH_ACTIVITY", "HIGH", "DEFCON-GUEST", "AA:BB:CC:DD:EE:FF", "2.4GHz", "6", "-41", 23, 18 * 1024 * 1024, "pending", "SAVED", "automatic", "/root/loot/pcap/deauth.pcap"},
			{strconv.FormatInt(now.Add(-84*time.Minute).Unix(), 10), "2", "TRUSTED_SSID_NEW_BSSID", "HIGH", "HOTEL-WIFI", "10:20:30:40:50:60", "5GHz", "44", "-58", 30, 22 * 1024 * 1024, "pending", "SAVED", "automatic", "/root/loot/pcap/twin.pcap"},
			{strconv.FormatInt(now.Add(-165*time.Minute).Unix(), 10), "3", "NEW_BSSID", "REVIEW", "CONFERENCE", "DE:AD:BE:EF:00:01", "2.4GHz", "11", "-65", 30, 8 * 1024 * 1024, "pending", "SAVED", "manual", "/root/loot/pcap/probe.pcap"},
		},
	}
}

func loadAPs(path string) []AP {
	rows := readTSV(path)
	out := make([]AP, 0, len(rows))
	for _, row := range rows {
		if len(row) < 8 {
			continue
		}
		out = append(out, AP{row[0], row[1], row[2], row[3], row[4], row[5], row[6], row[7]})
	}
	return out
}

func loadThreats(path string) []Threat {
	rows := readTSV(path)
	out := make([]Threat, 0, len(rows))
	for _, row := range rows {
		if len(row) < 9 || row[0] == "" {
			continue
		}
		out = append(out, Threat{row[0], row[1], row[2], row[3], row[4], row[5], row[6], row[7], row[8]})
	}
	sort.SliceStable(out, func(i, j int) bool {
		return out[i].Level == "red" && out[j].Level != "red"
	})
	return out
}

func loadEvidence(path string) []Evidence {
	rows := readTSV(path)
	out := make([]Evidence, 0, len(rows))
	for _, row := range rows {
		if len(row) < 15 || row[0] == "epoch" || row[12] != "SAVED" {
			continue
		}
		duration, _ := strconv.ParseInt(row[9], 10, 64)
		size, _ := strconv.ParseInt(row[10], 10, 64)
		out = append(out, Evidence{row[0], row[1], row[2], row[3], row[4], row[5], row[6], row[7], row[8], duration, size, row[11], row[12], row[13], row[14]})
	}
	sort.SliceStable(out, func(i, j int) bool {
		a, _ := strconv.ParseInt(out[i].Epoch, 10, 64)
		b, _ := strconv.ParseInt(out[j].Epoch, 10, 64)
		return a > b
	})
	return out
}

func loadCapture(path string) Capture {
	b, err := os.ReadFile(path)
	if err != nil {
		return Capture{Status: "IDLE"}
	}
	f := strings.Split(strings.TrimSpace(string(b)), "|")
	for len(f) < 13 {
		f = append(f, "")
	}
	return Capture{f[0], f[1], f[2], f[3], f[4], f[5], f[6], f[7], f[8], f[9], f[10], f[11], f[12]}
}

func readTSV(path string) [][]string {
	f, err := os.Open(path)
	if err != nil {
		return nil
	}
	defer f.Close()
	r := csv.NewReader(f)
	r.Comma = '\t'
	r.FieldsPerRecord = -1
	r.LazyQuotes = true
	rows, err := r.ReadAll()
	if err != nil {
		return nil
	}
	return rows
}

func readKeyValues(path string) map[string]string {
	out := map[string]string{}
	f, err := os.Open(path)
	if err != nil {
		return out
	}
	defer f.Close()
	s := bufio.NewScanner(f)
	for s.Scan() {
		key, value, ok := strings.Cut(s.Text(), "=")
		if ok {
			out[strings.TrimSpace(key)] = strings.TrimSpace(value)
		}
	}
	return out
}

func readIntFile(path string) int {
	b, err := os.ReadFile(path)
	if err != nil {
		return -1
	}
	n, err := strconv.Atoi(strings.TrimSpace(string(b)))
	if err != nil {
		return -1
	}
	return n
}

func countRows(path string) int {
	f, err := os.Open(path)
	if err != nil {
		return 0
	}
	defer f.Close()
	n := 0
	s := bufio.NewScanner(f)
	for s.Scan() {
		line := strings.TrimSpace(s.Text())
		if line != "" && !strings.HasPrefix(line, "#") {
			n++
		}
	}
	return n
}

func fileExists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}

func (a *app) render(s liveState) *image.RGBA {
	img := image.NewRGBA(image.Rect(0, 0, screenWidth, screenHeight))
	draw.Draw(img, img.Bounds(), image.NewUniform(black), image.Point{}, draw.Src)
	a.mu.Lock()
	defer a.mu.Unlock()
	switch a.screen {
	case screenThreat:
		a.renderThreat(img, s)
	case screenEvidence:
		a.renderEvidence(img, s)
	case screenEvidenceDetail:
		a.renderEvidenceDetail(img, s)
	default:
		a.renderGeneral(img, s)
	}
	if a.toast != "" && time.Now().Before(a.toastUntil) {
		r := image.Rect(0, 92, screenWidth, 123)
		fill(img, r, black)
		stroke(img, r, 1, green)
		drawCentered(img, 99, trimCells(a.toast, 56), green, true)
	}
	return img
}

func (a *app) renderGeneral(img *image.RGBA, s liveState) {
	drawTextWide(img, 10, 8, "DEFCON DEFENSE", yellow, true)
	a.drawStatus(img, s, 296)
	hLine(img, 9, 471, 33, cyan2)

	redCount := 0
	for _, t := range s.Threats {
		if t.Level == "red" {
			redCount++
		}
	}
	state, stateColor := "CLEAR", green
	if redCount > 0 {
		state, stateColor = "HIGH THREAT", red
	} else if len(s.Threats) > 0 {
		state, stateColor = "REVIEW", yellow
	}
	drawText(img, 12, 44, "THREAT STATE:", cyan, false, 1)
	drawText(img, 145, 44, state, stateColor, true, 1)
	drawText(img, 292, 44, "MONITORING:", cyan, false, 1)
	drawTextBox(img, image.Rect(405, 40, 471, 62), 405, 44, trimCells(s.Monitoring, 8), green, true, 1)
	drawText(img, 12, 67, "BANDS:", cyan, false, 1)
	drawText(img, 80, 67, "2.4 GHZ + 5 GHZ", green, true, 1)
	hLine(img, 9, 471, 90, cyan2)

	rows := []struct{ left, right string }{
		{"1. Threats", fmt.Sprintf("%d active", len(s.Threats))},
		{"2. Live RF", "Scanning"},
		{"3. Monitored Networks", fmt.Sprintf("%d watched", s.Watched)},
	}
	y := []int{95, 124, 151}
	for i, row := range rows {
		fg := cyan
		if i == a.generalSelected {
			fill(img, image.Rect(9, y[i]-1, 471, y[i]+25), yellow)
			fg = black
			drawText(img, 15, y[i]+3, ">", black, true, 1)
		}
		drawText(img, 38, y[i]+3, row.left, fg, i == a.generalSelected, 1)
		drawTextRightBox(img, image.Rect(320, y[i], 453, y[i]+22), y[i]+3, row.right, fg, i == a.generalSelected)
	}
	hLine(img, 9, 471, 188, cyan2)
	drawText(img, 14, 199, "A", green, true, 1)
	drawText(img, 35, 199, "OPEN", white, true, 1)
	drawText(img, 145, 199, "B", red, true, 1)
	drawText(img, 165, 199, "EXIT", white, true, 1)
	drawText(img, 263, 199, "LEFT/RIGHT", yellow, true, 1)
	drawText(img, 386, 199, "PAGE", white, true, 1)
}

func (a *app) renderThreat(img *image.RGBA, s liveState) {
	drawText(img, 7, 4, "DEFCON DEFENSE", yellow, true, 1)
	a.drawStatus(img, s, 210)
	hLine(img, 5, 475, 22, white)

	var t Threat
	hasThreat := len(s.Threats) > 0
	if hasThreat {
		if a.threatSelected >= len(s.Threats) {
			a.threatSelected = 0
		}
		t = s.Threats[a.threatSelected]
	}
	fillColor := red
	cardTitle, cardSub := "HIGH", "THREAT"
	mainTitle, affected := "NO ACTIVE THREAT DETECTED", "ALL MONITORED NETWORKS"
	if hasThreat {
		mainTitle = eventHeadline(t.Event, t.Deauth)
		affected = displaySSID(t.SSID)
	} else {
		fillColor, cardTitle, cardSub = green, "CLEAR", "STATE"
	}
	stroke(img, image.Rect(7, 30, 87, 87), 2, fillColor)
	drawTextFitted(img, image.Rect(9, 31, 85, 65), 14, 37, cardTitle, fillColor, true, 2)
	drawTextBox(img, image.Rect(9, 64, 85, 85), 14, 65, cardSub, fillColor, true, 1)
	if hasThreat {
		a.renderer.drawIcon(img, 99, 32, "\ue002", 28, red)
	}
	drawText(img, 136, 32, trimCells(mainTitle, 41), fillColor, true, 1)
	drawText(img, 136, 57, "AFFECTED NETWORK:", white, true, 1)
	drawText(img, 136, 72, trimCells(affected, 36), fillColor, true, 1)
	hLine(img, 5, 475, 94, white)
	vLine(img, 232, 96, 171, white)

	bssid, channel, signal, auth := "--", "--", "--", "0/0"
	if hasThreat {
		bssid, channel, signal = t.BSSID, t.Channel+" ("+strings.TrimSuffix(t.Band, "GHz")+"GHz)", t.Signal+"dBm"
		auth = fmt.Sprintf("1/%d", max(1, countSSID(s.APs, t.SSID)))
	}
	drawMetric(img, 9, 104, "BSSID:", bssid, cyan)
	drawMetric(img, 9, 122, "CHANNEL:", channel, cyan)
	drawMetric(img, 9, 140, "SIGNAL:", signal, green)
	drawMetric(img, 9, 158, "AUTH APS:", auth, yellow)

	eventTime := s.Now.Format("15:04")
	duration := "ACTIVE"
	evidenceStatus := captureLabel(s.Capture, t.BSSID, s.Evidence)
	if s.Capture.Status == "CAPTURING" {
		if epoch, err := strconv.ParseInt(s.Capture.Epoch, 10, 64); err == nil {
			elapsed := int64(s.Now.Sub(time.Unix(epoch, 0)).Seconds())
			if elapsed < 0 {
				elapsed = 0
			}
			duration = fmt.Sprintf("00:%02d", elapsed)
		}
	}
	drawMetricAt(img, 244, 356, 104, "EVENT TIME:", eventTime, cyan)
	drawMetricAt(img, 244, 356, 122, "DURATION:", duration, cyan)
	drawMetricAt(img, 244, 356, 140, "EVIDENCE:", trimCells(evidenceStatus, 14), red)
	drawTextBox(img, image.Rect(244, 156, 374, 173), passiveCaptureLabelX, 158, passiveCaptureLabel, white, true, 1)
	passiveIconX := passiveCaptureLabelX + textPixelWidth(passiveCaptureLabel, 1) + passiveCaptureIconGap
	a.renderer.drawIcon(img, passiveIconX, 156, "\ue1da", 16, green)

	stroke(img, image.Rect(4, 173, 476, 202), 1, white)
	for _, x := range []int{136, 225, 350} {
		vLine(img, x, 173, 202, white)
	}
	drawButtonHint(img, 12, 180, "A", "INVESTIGATE", cyan)
	drawButtonHint(img, 145, 180, "B", "MUTE", cyan)
	a.renderer.drawIcon(img, 239, 178, "\ue5c4", 20, cyan)
	drawText(img, 263, 181, "GENERAL", cyan, true, 1)
	a.renderer.drawIcon(img, 360, 178, "\ue5c8", 20, cyan)
	drawText(img, 385, 181, "EVIDENCE", cyan, true, 1)
	hLine(img, 7, 140, 212, green)
	hLine(img, 343, 475, 212, green)
	drawCentered(img, 205, "UP/DOWN: NEXT/PREV ALERT", green, true)
}

func (a *app) renderEvidence(img *image.RGBA, s liveState) {
	drawText(img, 10, 7, "EVIDENCE", yellow, true, 1)
	total := fmt.Sprintf("%d PCAPS · %s / %s", len(s.Evidence), humanBytes(s.UsedBytes), humanBytes(s.StorageMax))
	drawTextRightBox(img, image.Rect(158, 4, 471, 25), 9, trimCells(total, 38), cyan, true)
	hLine(img, 4, 476, 27, cyan2)
	columns := []struct {
		x int
		t string
	}{{25, "TIME"}, {101, "THREAT"}, {199, "SSID"}, {343, "SIZE"}, {410, "STATUS"}}
	for _, c := range columns {
		drawText(img, c.x, 35, c.t, cyan, true, 1)
	}
	hLine(img, 4, 476, 50, cyan2)

	if len(s.Evidence) == 0 {
		drawCentered(img, 87, "NO SAVED PCAP EVIDENCE", white, true)
		drawCentered(img, 108, "HIGH-CONFIDENCE THREATS CAPTURE AUTOMATICALLY", cyan, false)
	} else {
		if a.evidenceSelected >= len(s.Evidence) {
			a.evidenceSelected = 0
		}
		a.evidencePage = a.evidenceSelected / 3
		start := a.evidencePage * 3
		for row := 0; row < 3 && start+row < len(s.Evidence); row++ {
			i := start + row
			e := s.Evidence[i]
			y := 55 + row*27
			fg := white
			if i == a.evidenceSelected {
				fill(img, image.Rect(4, y-2, 476, y+21), yellow)
				fg = black
				drawText(img, 9, y+1, ">", black, true, 1)
			}
			drawText(img, 26, y+1, evidenceTime(e.Epoch), fg, true, 1)
			drawText(img, 101, y+1, trimCells(eventShort(e.Event), 12), fg, true, 1)
			drawText(img, 199, y+1, trimCells(displaySSID(e.SSID), 17), fg, true, 1)
			drawTextBox(img, image.Rect(343, y-1, 409, y+20), 343, y+1, trimCells(humanBytes(e.Size), 8), fg, true, 1)
			statusColor := green
			if i == a.evidenceSelected {
				statusColor = black
			}
			drawTextBox(img, image.Rect(410, y-1, 475, y+20), 410, y+1, trimCells(e.Status, 8), statusColor, true, 1)
		}
	}
	hLine(img, 4, 476, 164, cyan2)
	drawText(img, 11, 174, "DOWNLOAD VIA VIRTUAL PAGER", green, true, 1)
	stroke(img, image.Rect(4, 190, 476, 219), 1, cyan2)
	for _, x := range []int{86, 163, 241, 323, 402} {
		vLine(img, x, 190, 219, cyan2)
	}
	drawTextBox(img, image.Rect(5, 191, 85, 218), 9, 197, "A", green, true, 1)
	drawTextBox(img, image.Rect(5, 191, 85, 218), 26, 197, "DETAILS", white, true, 1)
	drawButtonHint(img, 94, 197, "B", "BACK", white)
	a.renderer.drawIcon(img, 171, 195, "\ue5c4", 18, cyan)
	drawText(img, 194, 198, "PAGE", white, true, 1)
	a.renderer.drawIcon(img, 248, 195, "\ue5c8", 18, cyan)
	drawText(img, 271, 198, "PAGE", white, true, 1)
	a.renderer.drawIcon(img, 330, 195, "\ue5d8", 18, green)
	drawText(img, 352, 198, "SELECT", white, true, 1)
	a.renderer.drawIcon(img, 405, 195, "\ue5db", 18, green)
	drawTextBox(img, image.Rect(403, 191, 475, 218), 427, 198, "SELECT", white, true, 1)
}

func (a *app) renderEvidenceDetail(img *image.RGBA, s liveState) {
	drawText(img, 10, 5, "EVIDENCE DETAIL", yellow, true, 1)
	drawTextRight(img, 470, 5, "SAVED PCAP", green, true)
	hLine(img, 4, 476, 27, cyan2)
	if len(s.Evidence) == 0 {
		drawCentered(img, 94, "NO EVIDENCE SELECTED", white, true)
		return
	}
	e := s.Evidence[a.evidenceSelected%len(s.Evidence)]
	drawMetricWide(img, 12, 42, "THREAT:", eventShort(e.Event), red)
	drawMetricWide(img, 12, 61, "NETWORK:", displaySSID(e.SSID), cyan)
	drawMetricWide(img, 12, 80, "BSSID:", e.BSSID, cyan)
	drawMetricWide(img, 12, 99, "BAND / CHANNEL:", e.Band+" / "+e.Channel, cyan)
	drawMetricWide(img, 12, 118, "TIME:", evidenceDateTime(e.Epoch), cyan)
	drawMetricWide(img, 12, 137, "DURATION / SIZE:", fmt.Sprintf("%ds / %s", e.Duration, humanBytes(e.Size)), white)
	hash := e.Hash
	if hash == "" {
		hash = "pending"
	}
	drawMetricWide(img, 12, 156, "SHA-256:", trimCells(hash, 34), yellow)
	hLine(img, 4, 476, 183, cyan2)
	drawText(img, 11, 194, "A", green, true, 1)
	drawText(img, 30, 194, "VERIFY SHA-256", white, true, 1)
	drawText(img, 201, 194, "B", red, true, 1)
	drawText(img, 220, 194, "BACK", white, true, 1)
	drawText(img, 289, 194, "DOWNLOAD: VIRTUAL PAGER", cyan, true, 1)
}

func (a *app) drawStatus(img *image.RGBA, s liveState, startX int) {
	a.renderer.drawIcon(img, startX, 3, "\ue63e", 20, cyan)
	a.renderer.drawIcon(img, startX+43, 3, "\ue050", 20, cyan)
	stroke(img, image.Rect(startX+78, 5, startX+117, 22), 1, cyan)
	drawTextBox(img, image.Rect(startX+79, 5, startX+116, 22), startX+84, 6, trimCells(fmt.Sprintf("%d%%", s.Battery), 4), green, true, 1)
	drawTextRight(img, 469, 5, s.Now.Format("15:04"), cyan, true)
}

func (r *renderer) drawIcon(img *image.RGBA, x, y int, glyph string, size int, c color.RGBA) {
	face := r.material[size]
	if face == nil {
		return
	}
	d := font.Drawer{Dst: img, Src: image.NewUniform(c), Face: face, Dot: fixed.P(x, y+size)}
	d.DrawString(glyph)
}

func drawText(img *image.RGBA, x, y int, text string, c color.RGBA, bold bool, scale int) {
	face := font.Face(inconsolata.Regular8x16)
	if bold {
		face = inconsolata.Bold8x16
	}
	if scale <= 1 {
		d := font.Drawer{Dst: img, Src: image.NewUniform(c), Face: face, Dot: fixed.P(x, y+13)}
		d.DrawString(text)
		return
	}
	w := max(1, len([]rune(text))*8)
	tmp := image.NewRGBA(image.Rect(0, 0, w, 16))
	d := font.Drawer{Dst: tmp, Src: image.NewUniform(c), Face: face, Dot: fixed.P(0, 13)}
	d.DrawString(text)
	for sy := 0; sy < tmp.Bounds().Dy(); sy++ {
		for sx := 0; sx < tmp.Bounds().Dx(); sx++ {
			px := tmp.RGBAAt(sx, sy)
			if px.A == 0 || (px.R == 0 && px.G == 0 && px.B == 0) {
				continue
			}
			fill(img, image.Rect(x+sx*scale, y+sy*scale, x+(sx+1)*scale, y+(sy+1)*scale), c)
		}
	}
}

func textPixelWidth(text string, scale int) int {
	return len([]rune(text)) * textCellWidth * max(1, scale)
}

func drawTextBox(img *image.RGBA, box image.Rectangle, x, y int, text string, c color.RGBA, bold bool, scale int) {
	box = box.Intersect(img.Bounds())
	if box.Empty() {
		return
	}
	clipped, ok := img.SubImage(box).(*image.RGBA)
	if !ok {
		return
	}
	drawText(clipped, x, y, text, c, bold, scale)
}

func drawTextFitted(img *image.RGBA, box image.Rectangle, x, y int, text string, c color.RGBA, bold bool, scale int) {
	box = box.Intersect(img.Bounds())
	if box.Empty() || x >= box.Max.X || y >= box.Max.Y {
		return
	}
	face := font.Face(inconsolata.Regular8x16)
	if bold {
		face = inconsolata.Bold8x16
	}
	sourceWidth := max(1, len([]rune(text))*textCellWidth)
	tmp := image.NewRGBA(image.Rect(0, 0, sourceWidth, 16))
	d := font.Drawer{Dst: tmp, Src: image.NewUniform(c), Face: face, Dot: fixed.P(0, 13)}
	d.DrawString(text)
	destWidth := min(sourceWidth*max(1, scale), box.Max.X-x)
	destHeight := 16 * max(1, scale)
	for dy := 0; dy < destHeight && y+dy < box.Max.Y; dy++ {
		for dx := 0; dx < destWidth && x+dx < box.Max.X; dx++ {
			sx := dx * sourceWidth / destWidth
			sy := dy / max(1, scale)
			p := tmp.RGBAAt(sx, sy)
			if p.A == 0 || (p.R == 0 && p.G == 0 && p.B == 0) {
				continue
			}
			img.SetRGBA(x+dx, y+dy, c)
		}
	}
}

func drawTextWide(img *image.RGBA, x, y int, text string, c color.RGBA, bold bool) {
	face := font.Face(inconsolata.Regular8x16)
	if bold {
		face = inconsolata.Bold8x16
	}
	sourceWidth := max(1, len([]rune(text))*8)
	tmp := image.NewRGBA(image.Rect(0, 0, sourceWidth, 16))
	d := font.Drawer{Dst: tmp, Src: image.NewUniform(c), Face: face, Dot: fixed.P(0, 13)}
	d.DrawString(text)
	destWidth := (sourceWidth*5 + 3) / 4
	for dy := 0; dy < 16; dy++ {
		for dx := 0; dx < destWidth; dx++ {
			sx := dx * 4 / 5
			p := tmp.RGBAAt(sx, dy)
			if p.A == 0 || (p.R == 0 && p.G == 0 && p.B == 0) {
				continue
			}
			if x+dx < screenWidth {
				img.SetRGBA(x+dx, y+dy, c)
			}
		}
	}
}

func drawTextRight(img *image.RGBA, right, y int, text string, c color.RGBA, bold bool) {
	drawText(img, right-textPixelWidth(text, 1), y, text, c, bold, 1)
}

func drawTextRightBox(img *image.RGBA, box image.Rectangle, y int, text string, c color.RGBA, bold bool) {
	text = trimCells(text, box.Dx()/textCellWidth)
	drawTextBox(img, box, box.Max.X-textPixelWidth(text, 1), y, text, c, bold, 1)
}

func drawCentered(img *image.RGBA, y int, text string, c color.RGBA, bold bool) {
	drawText(img, (screenWidth-textPixelWidth(text, 1))/2, y, text, c, bold, 1)
}

func drawMetric(img *image.RGBA, x, y int, label, value string, valueColor color.RGBA) {
	drawText(img, x, y, label, white, true, 1)
	drawText(img, x+78, y, trimCells(value, 17), valueColor, true, 1)
}

func drawMetricAt(img *image.RGBA, labelX, valueX, y int, label, value string, valueColor color.RGBA) {
	drawText(img, labelX, y, label, white, true, 1)
	drawTextBox(img, image.Rect(valueX, y-1, 472, y+16), valueX, y, trimCells(value, (472-valueX)/textCellWidth), valueColor, true, 1)
}

func drawMetricWide(img *image.RGBA, x, y int, label, value string, valueColor color.RGBA) {
	drawText(img, x, y, label, white, true, 1)
	drawText(img, x+145, y, trimCells(value, 39), valueColor, true, 1)
}

func drawButtonHint(img *image.RGBA, x, y int, key, label string, labelColor color.RGBA) {
	keyColor := green
	if key == "B" {
		keyColor = red
	}
	drawText(img, x, y, key, keyColor, true, 1)
	drawText(img, x+23, y, label, labelColor, true, 1)
}

func fill(img *image.RGBA, rect image.Rectangle, c color.RGBA) {
	draw.Draw(img, rect.Intersect(img.Bounds()), image.NewUniform(c), image.Point{}, draw.Src)
}

func stroke(img *image.RGBA, rect image.Rectangle, width int, c color.RGBA) {
	fill(img, image.Rect(rect.Min.X, rect.Min.Y, rect.Max.X, rect.Min.Y+width), c)
	fill(img, image.Rect(rect.Min.X, rect.Max.Y-width, rect.Max.X, rect.Max.Y), c)
	fill(img, image.Rect(rect.Min.X, rect.Min.Y, rect.Min.X+width, rect.Max.Y), c)
	fill(img, image.Rect(rect.Max.X-width, rect.Min.Y, rect.Max.X, rect.Max.Y), c)
}

func hLine(img *image.RGBA, x1, x2, y int, c color.RGBA) { fill(img, image.Rect(x1, y, x2, y+1), c) }
func vLine(img *image.RGBA, x, y1, y2 int, c color.RGBA) { fill(img, image.Rect(x, y1, x+1, y2), c) }

func canvasToFramebuffer(img *image.RGBA) []byte {
	out := make([]byte, frameBytes)
	for y := 0; y < screenHeight; y++ {
		for x := 0; x < screenWidth; x++ {
			p := img.RGBAAt(x, y)
			v := uint16(p.R>>3)<<11 | uint16(p.G>>2)<<5 | uint16(p.B>>3)
			// The physical landscape canvas is the device framebuffer rotated
			// counter-clockwise: fb(x=221-y, y=x) == canvas(x,y).
			i := (x*fbWidth + (fbWidth - 1 - y)) * 2
			out[i] = byte(v)
			out[i+1] = byte(v >> 8)
		}
	}
	return out
}

func eventHeadline(event, deauth string) string {
	if n, _ := strconv.Atoi(deauth); n > 0 || event == "DEAUTH_ACTIVITY" {
		return "DEAUTHENTICATION ATTACK DETECTED"
	}
	switch event {
	case "TRUSTED_SSID_NEW_BSSID", "WATCHED_SSID_NEW_BSSID":
		return "POSSIBLE EVIL TWIN DETECTED"
	case "TRUSTED_BSSID_SSID_CHANGE", "WATCHED_BSSID_SSID_CHANGE":
		return "KNOWN ACCESS POINT IDENTITY CHANGED"
	case "TRUSTED_AP_CHANNEL_CHANGE", "WATCHED_AP_CHANNEL_CHANGE":
		return "KNOWN ACCESS POINT CHANNEL CHANGED"
	case "NEW_BSSID":
		return "PERSISTENT NEW ACCESS POINT DETECTED"
	default:
		if event == "" {
			return "NO ACTIVE THREAT DETECTED"
		}
		return strings.ReplaceAll(event, "_", " ")
	}
}

func eventShort(event string) string {
	switch event {
	case "DEAUTH_ACTIVITY":
		return "DEAUTH"
	case "TRUSTED_SSID_NEW_BSSID", "WATCHED_SSID_NEW_BSSID":
		return "EVIL TWIN"
	case "TRUSTED_BSSID_SSID_CHANGE", "WATCHED_BSSID_SSID_CHANGE":
		return "SSID CHANGE"
	case "TRUSTED_AP_CHANNEL_CHANGE", "WATCHED_AP_CHANNEL_CHANGE":
		return "CHANNEL"
	case "NEW_BSSID":
		return "PROBE FLOOD"
	case "MANUAL_FOCUS", "MANUAL_INVESTIGATE":
		return "MANUAL"
	case "LEGACY_CAPTURE":
		return "LEGACY"
	default:
		return strings.ReplaceAll(event, "_", " ")
	}
}

func captureLabel(c Capture, bssid string, evidence []Evidence) string {
	if c.Status == "CAPTURING" && (bssid == "" || strings.EqualFold(c.BSSID, bssid)) {
		return "PCAP CAPTURING"
	}
	for _, e := range evidence {
		if bssid != "" && strings.EqualFold(e.BSSID, bssid) {
			return "PCAP SAVED"
		}
	}
	if c.Status != "" && c.Status != "IDLE" {
		return "PCAP " + c.Status
	}
	return "READY"
}

func displaySSID(s string) string {
	s = strings.TrimSpace(s)
	if s == "" || s == "<hidden>" || s == "<unknown>" {
		return "<HIDDEN NETWORK>"
	}
	return s
}

func evidenceTime(epoch string) string {
	v, err := strconv.ParseInt(epoch, 10, 64)
	if err != nil {
		return "--:--"
	}
	return time.Unix(v, 0).Format("15:04")
}

func evidenceDateTime(epoch string) string {
	v, err := strconv.ParseInt(epoch, 10, 64)
	if err != nil {
		return epoch
	}
	return time.Unix(v, 0).Format("2006-01-02 15:04:05")
}

func humanBytes(n int64) string {
	switch {
	case n >= 1024*1024*1024:
		return fmt.Sprintf("%.1f GB", float64(n)/(1024*1024*1024))
	case n >= 1024*1024:
		return fmt.Sprintf("%.0f MB", float64(n)/(1024*1024))
	case n >= 1024:
		return fmt.Sprintf("%.0f KB", float64(n)/1024)
	default:
		return fmt.Sprintf("%d B", n)
	}
}

func trimCells(s string, maxCells int) string {
	r := []rune(strings.TrimSpace(s))
	if len(r) <= maxCells {
		return string(r)
	}
	if maxCells <= 1 {
		return string(r[:maxCells])
	}
	return string(r[:maxCells-1]) + "…"
}

func countSSID(aps []AP, ssid string) int {
	n := 0
	for _, ap := range aps {
		if ssid != "" && ap.SSID == ssid {
			n++
		}
	}
	return n
}

func max(a, b int) int {
	if a > b {
		return a
	}
	return b
}

// Compile-time checks that keep otherwise easy-to-drop standard packages
// referenced when this file is built with older OpenWrt-oriented Go releases.
var _ = bytes.Compare
var _ = errors.Is
