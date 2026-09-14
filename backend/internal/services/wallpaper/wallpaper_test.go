package wallpaper

import (
	"io"
	"log/slog"
	"sync"
	"testing"
	"time"
)

// recorder captures the frames the scheduler publishes.
type recorder struct {
	mu     sync.Mutex
	frames []State
}

func (r *recorder) Broadcast(_ string, data any) {
	r.mu.Lock()
	defer r.mu.Unlock()
	state, ok := data.(State)
	if !ok {
		return
	}
	r.frames = append(r.frames, state)
}

func (r *recorder) all() []State {
	r.mu.Lock()
	defer r.mu.Unlock()
	return append([]State(nil), r.frames...)
}

func newRecordingManager() (*Manager, *recorder) {
	rec := &recorder{}
	m := &Manager{
		log:       slog.New(slog.NewTextHandler(io.Discard, nil)),
		srv:       rec,
		config:    defaultConfig(),
		lastFires: map[string]time.Time{},
	}
	return m, rec
}

// The scheduler emits one frame per due monitor, back to back, and each names
// the monitor that rotated. They do not subsume one another, which is why
// "wallpaper" is not declared to CoalesceBroadcasts: a frame replacing an
// unread one loses that monitor's rotation outright.
func TestSetStatePublishesOneFramePerDueMonitor(t *testing.T) {
	m, rec := newRecordingManager()
	next := time.Now().Add(time.Hour)

	for seq, target := range []string{"DP-1", "DP-2", "HDMI-A-1"} {
		m.setState(m.config, next, uint64(seq+1), target)
	}

	frames := rec.all()
	if len(frames) != 3 {
		t.Fatalf("published %d frames, want one per due monitor: %+v", len(frames), frames)
	}
	seen := map[string]uint64{}
	for _, frame := range frames {
		if prior, ok := seen[frame.Target]; ok {
			t.Fatalf("%q was published twice, at cycle %d and %d", frame.Target, prior, frame.CycleSeq)
		}
		seen[frame.Target] = frame.CycleSeq
	}
	for _, target := range []string{"DP-1", "DP-2", "HDMI-A-1"} {
		if seen[target] == 0 {
			t.Fatalf("%q never reached the wire; that monitor's rotation is lost: %+v", target, frames)
		}
	}
}

// A frame identical to the one already published carries no new rotation, so it
// is not republished. Without this the shell would re-run its cycle handler on
// every scheduler pass.
func TestSetStateSkipsAnUnchangedFrame(t *testing.T) {
	m, rec := newRecordingManager()
	next := time.Now().Add(time.Hour)

	m.setState(m.config, next, 1, "DP-1")
	m.setState(m.config, next, 1, "DP-1")

	if frames := rec.all(); len(frames) != 1 {
		t.Fatalf("published %d frames for one unchanged state, want 1: %+v", len(frames), frames)
	}
}
