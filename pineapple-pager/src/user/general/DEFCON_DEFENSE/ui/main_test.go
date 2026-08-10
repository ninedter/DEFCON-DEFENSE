package main

import (
	"image"
	"io"
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
