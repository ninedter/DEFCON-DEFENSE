package main

import (
	"bytes"
	"context"
	"encoding/binary"
	"image"
	"image/color"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"testing"
)

type memoryReadWriteSeeker struct {
	data   []byte
	reader *bytes.Reader
	writes int
}

func newMemoryReadWriteSeeker(data []byte) *memoryReadWriteSeeker {
	copyData := append([]byte(nil), data...)
	return &memoryReadWriteSeeker{data: copyData, reader: bytes.NewReader(copyData)}
}

func (m *memoryReadWriteSeeker) Read(p []byte) (int, error) {
	return m.reader.Read(p)
}

func (m *memoryReadWriteSeeker) Write(p []byte) (int, error) {
	m.writes++
	position, _ := m.reader.Seek(0, io.SeekCurrent)
	end := int(position) + len(p)
	if end > len(m.data) {
		m.data = append(m.data, make([]byte, end-len(m.data))...)
	}
	copy(m.data[int(position):end], p)
	m.reader = bytes.NewReader(m.data)
	_, _ = m.reader.Seek(int64(end), io.SeekStart)
	return len(p), nil
}

func (m *memoryReadWriteSeeker) Seek(offset int64, whence int) (int64, error) {
	return m.reader.Seek(offset, whence)
}

type countingWriteSeeker struct {
	writes int
}

func (w *countingWriteSeeker) Write(p []byte) (int, error) {
	w.writes++
	return len(p), nil
}

func (w *countingWriteSeeker) Seek(int64, int) (int64, error) {
	return 0, nil
}

var _ io.WriteSeeker = (*countingWriteSeeker)(nil)

func TestCanvasToFramebufferRotationAndRGB565(t *testing.T) {
	img := image.NewRGBA(image.Rect(0, 0, screenWidth, screenHeight))
	img.SetRGBA(0, 0, red)
	img.SetRGBA(screenWidth-1, screenHeight-1, green)
	frame := canvasToFramebuffer(img)
	if len(frame) != frameBytes {
		t.Fatalf("frame length = %d, want %d", len(frame), frameBytes)
	}
	redIndex := (0*fbWidth + (fbWidth - 1)) * 2
	if frame[redIndex] == 0 && frame[redIndex+1] == 0 {
		t.Fatal("top-left canvas pixel did not map to rotated framebuffer")
	}
	greenIndex := ((screenWidth-1)*fbWidth + 0) * 2
	if frame[greenIndex] == 0 && frame[greenIndex+1] == 0 {
		t.Fatal("bottom-right canvas pixel did not map to rotated framebuffer")
	}
}

func TestPreviewStateExercisesAllThreeScreens(t *testing.T) {
	s := previewState()
	if len(s.Threats) < 2 {
		t.Fatalf("preview threats = %d, want at least 2", len(s.Threats))
	}
	if len(s.Evidence) < 3 {
		t.Fatalf("preview evidence = %d, want at least 3", len(s.Evidence))
	}
	if got := eventHeadline(s.Threats[0].Event, s.Threats[0].Deauth); got != "DEAUTHENTICATION ATTACK DETECTED" {
		t.Fatalf("headline = %q", got)
	}
}

func TestNormalizeButton(t *testing.T) {
	tests := map[string]string{
		"A\n":        "A",
		"Enter":      "A",
		"Escape":     "B",
		"ESC":        "B",
		"ArrowRight": "RIGHT",
		"arrow_left": "LEFT",
	}
	for input, want := range tests {
		if got := normalizeButton(input); got != want {
			t.Fatalf("normalizeButton(%q) = %q, want %q", input, got, want)
		}
	}
}

func TestPagerLinuxKeyMapping(t *testing.T) {
	tests := map[uint16]string{
		304: "A",
		305: "B",
		103: "UP",
		108: "DOWN",
		105: "LEFT",
		106: "RIGHT",
		116: "",
	}
	for code, want := range tests {
		if got := buttonForLinuxKey(code); got != want {
			t.Fatalf("buttonForLinuxKey(%d) = %q, want %q", code, got, want)
		}
	}
}

func TestDirectPagerInputAndFullNavigationFlow(t *testing.T) {
	inputPath := filepath.Join(t.TempDir(), "event0")
	eventSize, typeOffset := 16, 8
	if strconv.IntSize == 64 {
		eventSize, typeOffset = 24, 16
	}
	event := func(code uint16, value int32) []byte {
		b := make([]byte, eventSize)
		binary.LittleEndian.PutUint16(b[typeOffset:typeOffset+2], 1)
		binary.LittleEndian.PutUint16(b[typeOffset+2:typeOffset+4], code)
		binary.LittleEndian.PutUint32(b[typeOffset+4:typeOffset+8], uint32(value))
		return b
	}
	data := append(event(304, 1), event(304, 0)...)
	data = append(data, event(108, 1)...)
	data = append(data, event(108, 0)...)
	data = append(data, event(305, 1)...)
	if err := os.WriteFile(inputPath, data, 0o600); err != nil {
		t.Fatal(err)
	}
	buttons := make(chan string, 3)
	if err := readButtonDevice(context.Background(), inputPath, buttons); err != io.EOF {
		t.Fatalf("readButtonDevice error = %v, want EOF", err)
	}
	for i, want := range []string{"A", "DOWN", "B"} {
		select {
		case got := <-buttons:
			if got != want {
				t.Fatalf("button %d = %q, want %q", i, got, want)
			}
		default:
			t.Fatalf("button %d missing, want %q", i, want)
		}
	}

	a := &app{screen: screenGeneral}
	state := previewState()
	if a.handleButton("DOWN", state) || a.generalSelected != 1 {
		t.Fatalf("DOWN selected %d, want 1", a.generalSelected)
	}
	if a.handleButton("UP", state) || a.generalSelected != 0 {
		t.Fatalf("UP selected %d, want 0", a.generalSelected)
	}
	if a.handleButton("A", state) || a.screen != screenThreat {
		t.Fatalf("A opened screen %d, want threat", a.screen)
	}
	if a.handleButton("RIGHT", state) || a.screen != screenEvidence {
		t.Fatalf("RIGHT opened screen %d, want evidence", a.screen)
	}
	if a.handleButton("A", state) || a.screen != screenEvidenceDetail {
		t.Fatalf("A opened screen %d, want evidence detail", a.screen)
	}
	if a.handleButton("B", state) || a.screen != screenEvidence {
		t.Fatalf("B returned to screen %d, want evidence", a.screen)
	}
	a.lastButton = ""
	if a.handleButton("B", state) || a.screen != screenGeneral {
		t.Fatalf("B returned to screen %d, want general", a.screen)
	}
	a.lastButton = ""
	if !a.handleButton("B", state) {
		t.Fatal("B on general did not exit")
	}
}

func TestVirtualButtonHandlerQueuesPagerNavigation(t *testing.T) {
	buttons := make(chan string, 1)
	req := httptest.NewRequest(http.MethodPost, "/button?name=ArrowDown", nil)
	res := httptest.NewRecorder()
	virtualButtonHandler(buttons).ServeHTTP(res, req)

	if res.Code != http.StatusNoContent {
		t.Fatalf("button status = %d, want %d", res.Code, http.StatusNoContent)
	}
	select {
	case got := <-buttons:
		if got != "DOWN" {
			t.Fatalf("queued button = %q, want DOWN", got)
		}
	default:
		t.Fatal("virtual button was not queued")
	}
}

func TestUpdateDisplaySkipsIdenticalFrames(t *testing.T) {
	a := &app{renderer: newRenderer("")}
	state := previewState()
	writer := &countingWriteSeeker{}
	var pixels []byte

	if err := a.updateDisplay(writer, state, &pixels); err != nil {
		t.Fatal(err)
	}
	if err := a.updateDisplay(writer, state, &pixels); err != nil {
		t.Fatal(err)
	}
	if writer.writes != 1 {
		t.Fatalf("identical frames wrote %d times, want 1", writer.writes)
	}
	if a.webRevision != 1 {
		t.Fatalf("identical frames published %d revisions, want 1", a.webRevision)
	}

	a.screen = screenThreat
	if err := a.updateDisplay(writer, state, &pixels); err != nil {
		t.Fatal(err)
	}
	if writer.writes != 2 || a.webRevision != 2 {
		t.Fatalf("changed frame writes/revisions = %d/%d, want 2/2", writer.writes, a.webRevision)
	}
}

func TestMaintainDisplayOwnershipOnlyRewritesDisplacedFrame(t *testing.T) {
	expected := bytes.Repeat([]byte{0x5a}, frameBytes)
	framebuffer := newMemoryReadWriteSeeker(expected)
	var scratch []byte

	if err := maintainDisplayOwnership(framebuffer, expected, &scratch); err != nil {
		t.Fatal(err)
	}
	if framebuffer.writes != 0 {
		t.Fatalf("owned frame wrote %d times, want 0", framebuffer.writes)
	}

	framebuffer.data[frameBytes/2] = 0x00
	framebuffer.reader = bytes.NewReader(framebuffer.data)
	if err := maintainDisplayOwnership(framebuffer, expected, &scratch); err != nil {
		t.Fatal(err)
	}
	if framebuffer.writes != 1 {
		t.Fatalf("displaced frame wrote %d times, want 1", framebuffer.writes)
	}
	if !bytes.Equal(framebuffer.data, expected) {
		t.Fatal("displaced framebuffer was not restored exactly")
	}
}

func TestRenderPreviewsCoverEveryTextLayoutState(t *testing.T) {
	dir := t.TempDir()
	a := &app{renderer: newRenderer(""), previewDir: dir}
	if err := a.renderPreviews(); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{
		"01-general.png",
		"02-threat.png",
		"03-evidence.png",
		"04-evidence-detail.png",
		"05-threat-clear.png",
		"06-evidence-empty.png",
		"07-stress-general.png",
		"08-stress-threat.png",
		"09-stress-evidence.png",
		"10-stress-evidence-detail.png",
		"11-stress-toast.png",
	} {
		if _, err := os.Stat(filepath.Join(dir, name)); err != nil {
			t.Errorf("missing preview %s: %v", name, err)
		}
	}
}

func TestClearBadgeAndCaptureIconHaveDedicatedSpace(t *testing.T) {
	a := &app{renderer: newRenderer(""), screen: screenThreat}
	state := previewState()
	state.Threats = nil
	state.Capture = Capture{Status: "IDLE"}
	img := a.render(state)

	for y := 30; y < 87; y++ {
		for x := 87; x < 136; x++ {
			if got := img.RGBAAt(x, y); got != black {
				t.Fatalf("CLEAR badge escaped into title gutter at (%d,%d): %#v", x, y, got)
			}
		}
	}
	labelRight := passiveCaptureLabelX + textPixelWidth(passiveCaptureLabel, 1)
	iconX := labelRight + passiveCaptureIconGap
	if iconX-labelRight < passiveCaptureIconGap {
		t.Fatalf("capture icon gap = %d, want at least %d", iconX-labelRight, passiveCaptureIconGap)
	}
	if iconX+16 > 476 {
		t.Fatalf("capture icon right edge = %d, outside detail panel", iconX+16)
	}
}

func TestPanelTextDoesNotOverwriteBorders(t *testing.T) {
	a := &app{renderer: newRenderer("")}
	state := previewState()
	state.Evidence[0].Status = "VERIFICATION_PENDING"
	state.Evidence[0].Size = 9876543210

	a.screen = screenThreat
	threat := a.render(state)
	for _, x := range []int{4, threatFooterSplitX, 225, 350, 475} {
		assertVerticalColor(t, threat, x, 173, 202, white)
	}

	a.screen = screenEvidence
	evidence := a.render(state)
	for _, x := range []int{4, evidenceFooterSplitX, 163, 241, 323, 402, 475} {
		assertVerticalColor(t, evidence, x, 190, 219, cyan2)
	}
}

func TestFooterHintsMatchPhysicalButtonSides(t *testing.T) {
	a := &app{renderer: newRenderer("")}
	state := previewState()
	for _, tc := range []struct {
		name   string
		screen screenKind
		y1, y2 int
	}{
		{"general", screenGeneral, 190, 222},
		{"threat", screenThreat, 174, 202},
		{"evidence", screenEvidence, 191, 219},
		{"evidence detail", screenEvidenceDetail, 184, 222},
	} {
		a.screen = tc.screen
		img := a.render(state)
		bX, aX := firstColumnWith(img, red, tc.y1, tc.y2), firstColumnWith(img, green, tc.y1, tc.y2)
		if bX < 0 || aX < 0 {
			t.Fatalf("%s footer missing hint keys: B x=%d, A x=%d", tc.name, bX, aX)
		}
		if bX >= aX {
			t.Fatalf("%s footer draws B at x=%d, not left of A at x=%d", tc.name, bX, aX)
		}
	}
}

func firstColumnWith(img *image.RGBA, want color.RGBA, y1, y2 int) int {
	for x := 0; x < screenWidth; x++ {
		for y := y1; y < y2; y++ {
			if img.RGBAAt(x, y) == want {
				return x
			}
		}
	}
	return -1
}

func assertVerticalColor(t *testing.T, img *image.RGBA, x, y1, y2 int, want color.RGBA) {
	t.Helper()
	for y := y1; y < y2; y++ {
		if got := img.RGBAAt(x, y); got != want {
			t.Fatalf("panel border overwritten at (%d,%d): got %#v want %#v", x, y, got, want)
		}
	}
}
