package clipboard

import (
	"bufio"
	"bytes"
	"context"
	"fmt"
	"log/slog"
	"os/exec"
	"strings"
	"syscall"
	"time"
)

const (
	listTypesTimeout = 3 * time.Second
	readTextTimeout  = 3 * time.Second
	readImageTimeout = 10 * time.Second
	// copyStartupGrace is how long wl-copy gets to fail fast (bad args, no
	// display). Past it the process is assumed to be serving the clipboard.
	copyStartupGrace = 600 * time.Millisecond
	// maxImageBytes refuses absurd clipboard blobs rather than writing
	// unbounded files; anything a screenshot tool produces fits comfortably.
	maxImageBytes = 64 << 20
)

// selection reads the current clipboard offer: text when a text type is
// offered, otherwise the first image type. Empty ok means an empty or
// unreadable clipboard, which is not an error.
type selection struct {
	text  string
	mime  string
	image []byte
}

func readSelection(log *slog.Logger) (sel selection, ok bool, err error) {
	types, err := listTypes(log)
	if err != nil || len(types) == 0 {
		return selection{}, false, err
	}
	if hasTextType(types) {
		text, err := readText(log)
		if err != nil {
			return selection{}, false, err
		}
		if text != "" {
			return selection{text: text, mime: "text/plain"}, true, nil
		}
		// An empty text offer can still carry an image (e.g. some browsers
		// offer both); fall through.
	}
	mime := firstImageType(types)
	if mime == "" {
		return selection{}, false, nil
	}
	blob, err := readImage(log, mime)
	if err != nil {
		return selection{}, false, err
	}
	if len(blob) == 0 {
		return selection{}, false, nil
	}
	return selection{mime: mime, image: blob}, true, nil
}

// logPasteFailure distinguishes a real read failure from the routine
// empty-clipboard exit: wl-paste says nothing on an empty selection, so any
// stderr content is a failure worth a trace even though the caller degrades
// to "empty".
func logPasteFailure(log *slog.Logger, op string, err error) {
	ee, ok := err.(*exec.ExitError)
	if !ok {
		log.Warn("wl-paste failed", "op", op, "err", err)
		return
	}
	if msg := strings.TrimSpace(string(ee.Stderr)); msg != "" && !strings.Contains(msg, "No selection") {
		log.Warn("wl-paste failed", "op", op, "err", msg)
	}
}

func listTypes(log *slog.Logger) ([]string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), listTypesTimeout)
	defer cancel()
	out, err := exec.CommandContext(ctx, "wl-paste", "--list-types").Output()
	if err != nil {
		// wl-paste exits non-zero for an empty clipboard; that is a normal
		// state, but anything with stderr is a real failure worth logging.
		logPasteFailure(log, "list-types", err)
		return nil, nil
	}
	var types []string
	for _, line := range strings.Split(string(out), "\n") {
		if line = strings.TrimSpace(line); line != "" {
			types = append(types, line)
		}
	}
	return types, nil
}

func hasTextType(types []string) bool {
	for _, t := range types {
		if t == "text/plain" || strings.HasPrefix(t, "text/plain;") || t == "UTF8_STRING" || t == "TEXT" || t == "STRING" {
			return true
		}
	}
	return false
}

func firstImageType(types []string) string {
	for _, t := range types {
		if strings.HasPrefix(t, "image/") {
			return t
		}
	}
	return ""
}

func readText(log *slog.Logger) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), readTextTimeout)
	defer cancel()
	out, err := exec.CommandContext(ctx, "wl-paste", "--no-newline", "--type", "text").Output()
	if ctx.Err() != nil {
		return "", ctx.Err()
	}
	if err != nil {
		logPasteFailure(log, "read-text", err)
		return "", nil
	}
	return string(out), nil
}

func readImage(log *slog.Logger, mime string) ([]byte, error) {
	ctx, cancel := context.WithTimeout(context.Background(), readImageTimeout)
	defer cancel()
	out, err := exec.CommandContext(ctx, "wl-paste", "--type", mime).Output()
	if ctx.Err() != nil {
		return nil, ctx.Err()
	}
	if err != nil {
		logPasteFailure(log, "read-image", err)
		return nil, nil
	}
	if len(out) > maxImageBytes {
		return nil, fmt.Errorf("clipboard image exceeds %d bytes", maxImageBytes)
	}
	return out, nil
}

// wlCopy hands blob to wl-copy. wl-copy stays alive in the background to
// serve the Wayland clipboard, so success is "did not fail immediately". It
// runs in its own session so a backend restart does not drop the clipboard;
// the reaper goroutine collects it when it exits and logs a late failure —
// by then the RPC has already returned success, so the log line is the only
// trace that the clipboard was never actually set.
func wlCopy(log *slog.Logger, blob []byte, mime string) error {
	args := []string{}
	if mime != "" {
		args = append(args, "--type", mime)
	}
	cmd := exec.Command("wl-copy", args...)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	cmd.Stdin = bytes.NewReader(blob)
	var stderr bytes.Buffer
	cmd.Stderr = &stderr

	if err := cmd.Start(); err != nil {
		return err
	}
	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()
	select {
	case err := <-done:
		if err != nil {
			if msg := strings.TrimSpace(stderr.String()); msg != "" {
				return fmt.Errorf("wl-copy: %s", msg)
			}
			return fmt.Errorf("wl-copy: %w", err)
		}
		return nil
	case <-time.After(copyStartupGrace):
		// Still serving the clipboard: success as far as the caller knows.
		go func() {
			if err := <-done; err != nil {
				log.Warn("wl-copy failed after startup grace", "err", err, "stderr", strings.TrimSpace(stderr.String()))
			}
		}()
		return nil
	}
}

// watch runs one wl-paste --watch process, invoking onEvent for every
// clipboard change, until the context is cancelled or the process dies.
// The watched command is a bare `echo`: each change prints one line, which is
// the only signal needed — content is read separately by the poller.
func watch(ctx context.Context, onEvent func()) error {
	cmd := exec.CommandContext(ctx, "wl-paste", "--watch", "echo")
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return err
	}
	var stderr bytes.Buffer
	cmd.Stderr = &boundedWriter{buf: &stderr, max: 4096}
	if err := cmd.Start(); err != nil {
		return err
	}
	sc := bufio.NewScanner(stdout)
	for sc.Scan() {
		onEvent()
	}
	err = cmd.Wait()
	if ctx.Err() != nil {
		return ctx.Err()
	}
	msg := strings.TrimSpace(stderr.String())
	if err != nil {
		if msg != "" {
			return fmt.Errorf("%w: %s", err, msg)
		}
		return err
	}
	if msg != "" {
		return fmt.Errorf("wl-paste --watch exited: %s", msg)
	}
	return fmt.Errorf("wl-paste --watch exited")
}

// boundedWriter keeps the first max bytes and drops the rest, so a chatty
// child cannot grow the buffer unboundedly over a long watch.
type boundedWriter struct {
	buf *bytes.Buffer
	max int
}

func (w *boundedWriter) Write(p []byte) (int, error) {
	if room := w.max - w.buf.Len(); room > 0 {
		if len(p) > room {
			w.buf.Write(p[:room])
		} else {
			w.buf.Write(p)
		}
	}
	return len(p), nil
}
