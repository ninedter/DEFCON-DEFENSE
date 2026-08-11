package main

import (
	"image"
	"image/color"
	"io"
	"os"
	"path/filepath"
	"testing"
)

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
	for _, x := range []int{4, 136, 225, 350, 475} {
		assertVerticalColor(t, threat, x, 173, 202, white)
	}

	a.screen = screenEvidence
	evidence := a.render(state)
	for _, x := range []int{4, 86, 163, 241, 323, 402, 475} {
		assertVerticalColor(t, evidence, x, 190, 219, cyan2)
	}
}

func assertVerticalColor(t *testing.T, img *image.RGBA, x, y1, y2 int, want color.RGBA) {
	t.Helper()
	for y := y1; y < y2; y++ {
		if got := img.RGBAAt(x, y); got != want {
			t.Fatalf("panel border overwritten at (%d,%d): got %#v want %#v", x, y, got, want)
		}
	}
}
