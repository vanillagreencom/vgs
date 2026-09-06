package execbound

import (
	"bytes"
	"context"
	"errors"
	"log/slog"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"
)

// maxBoundedElapsed is independent of DefaultWaitDelay so increasing the
// production delay cannot also relax the test limit.
const maxBoundedElapsed = 5 * time.Second

// The WaitDelay a command runs with: the default, a given positive delay, and
// the clamp for a zero or negative one, which os/exec would read as no bound
// at all and so reopen the wedge this package prevents.
func TestWaitDelayResolution(t *testing.T) {
	cases := []struct {
		name  string
		given *time.Duration
		want  time.Duration
	}{
		{"Command uses the default", nil, DefaultWaitDelay},
		{"a positive delay is used as given", durationPtr(700 * time.Millisecond), 700 * time.Millisecond},
		{"zero is clamped to the default", durationPtr(0), DefaultWaitDelay},
		{"a negative delay is clamped to the default", durationPtr(-time.Second), DefaultWaitDelay},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			var cmd *Cmd
			if tc.given == nil {
				cmd = Command(context.Background(), "true")
			} else {
				cmd = CommandWithDelay(context.Background(), *tc.given, "true")
			}
			if cmd.Exec().WaitDelay != tc.want {
				t.Fatalf("WaitDelay = %v, want %v", cmd.Exec().WaitDelay, tc.want)
			}
		})
	}
}

func durationPtr(d time.Duration) *time.Duration { return &d }

// pipeHolder starts a descendant that retains stdout after its parent exits.
// Without WaitDelay, reads wait for the descendant. Cleanup kills the process
// group; the sleep must outlive the test to prevent reuse of the group ID before
// cleanup.
func pipeHolder(t *testing.T, ctx context.Context, delay time.Duration, tail string) *Cmd {
	t.Helper()
	dir := t.TempDir()
	path := filepath.Join(dir, "pipe-holder")
	if err := os.WriteFile(path, []byte("#!/bin/sh\nsleep 60 &\n"+tail), 0o755); err != nil {
		t.Fatal(err)
	}
	cmd := CommandWithDelay(ctx, delay, path)
	cmd.Exec().SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	t.Cleanup(func() {
		if proc := cmd.Exec().Process; proc != nil {
			_ = syscall.Kill(-proc.Pid, syscall.SIGKILL)
		}
	})
	return cmd
}

func TestCommandReturnsAfterDeadlineKill(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 200*time.Millisecond)
	defer cancel()
	cmd := pipeHolder(t, ctx, DefaultWaitDelay, "exec sleep 60\n")

	start := time.Now()
	_, err := cmd.Exec().Output()
	elapsed := time.Since(start)

	if err == nil {
		t.Fatal("Output succeeded; want the killed child's error")
	}
	if elapsed > maxBoundedElapsed {
		t.Fatalf("Output took %v, want under %v", elapsed, maxBoundedElapsed)
	}
}

func TestOutputClassifiesTheDeadlineKillAsTimeout(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 200*time.Millisecond)
	defer cancel()
	cmd := pipeHolder(t, ctx, DefaultWaitDelay, "exec sleep 60\n")

	res, err := cmd.Output()

	if !errors.Is(err, ErrTimeout) {
		t.Fatalf("err = %v, want ErrTimeout", err)
	}
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("err = %v, want context.DeadlineExceeded in the chain", err)
	}
	if !Interrupted(err) {
		t.Fatalf("Interrupted(%v) = false, want true", err)
	}
	if res.Salvaged {
		t.Fatal("Salvaged = true for a killed child")
	}
}

// The child exits cleanly and only the descendant holds the pipe, so no
// deadline is involved: WaitDelay alone ends the read, and raw cmd.Output
// surfaces that as exec.ErrWaitDelay with the child's bytes intact.
func TestCommandReturnsAfterCleanExitWithHeldPipe(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
	defer cancel()
	cmd := pipeHolder(t, ctx, 300*time.Millisecond, "echo done\n")

	out, err := cmd.Exec().Output()

	if !errors.Is(err, exec.ErrWaitDelay) {
		t.Fatalf("err = %v, want exec.ErrWaitDelay", err)
	}
	if strings.TrimSpace(string(out)) != "done" {
		t.Fatalf("out = %q, want %q", out, "done")
	}
}

// A child that exits 0 with its output written is salvaged when only a
// descendant holds the pipes: through Output and CombinedOutput, and also when
// the deadline expires during that wait, where the clean exit takes precedence.
func TestOutputSalvagesCleanExitWithHeldPipe(t *testing.T) {
	cases := []struct {
		name    string
		timeout time.Duration
		delay   time.Duration
		tail    string
		run     func(cmd *Cmd) (Result, error)
	}{
		{"Output", time.Minute, 300 * time.Millisecond, "echo done\n", (*Cmd).Output},
		{"CombinedOutput reads stderr too", time.Minute, 300 * time.Millisecond, "echo done >&2\n", (*Cmd).CombinedOutput},
		{"Output inside the deadline straddle", 300 * time.Millisecond, 700 * time.Millisecond, "echo done\n", (*Cmd).Output},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			ctx, cancel := context.WithTimeout(context.Background(), tc.timeout)
			defer cancel()
			cmd := pipeHolder(t, ctx, tc.delay, tc.tail)

			res, err := tc.run(cmd)

			if err != nil {
				t.Fatalf("err = %v, want nil: the child exited 0 and its output was read", err)
			}
			if !res.Salvaged {
				t.Fatal("Salvaged = false; the held pipes must be reportable")
			}
			if strings.TrimSpace(string(res.Out)) != "done" {
				t.Fatalf("out = %q, want %q", res.Out, "done")
			}
		})
	}
}

// Exactly one warning names the tool when a salvage happens, and none when
// nothing was salvaged.
func TestOutputWarnsOnlyWhenItSalvages(t *testing.T) {
	cases := []struct {
		name     string
		cmd      func(ctx context.Context) *Cmd
		warnings int
	}{
		{"salvage warns once", func(ctx context.Context) *Cmd {
			return pipeHolder(t, ctx, 300*time.Millisecond, "echo done\n")
		}, 1},
		{"a plain run does not warn", func(ctx context.Context) *Cmd {
			return Command(ctx, "true")
		}, 0},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
			defer cancel()
			var buf bytes.Buffer
			log := slog.New(slog.NewTextHandler(&buf, &slog.HandlerOptions{Level: slog.LevelWarn}))

			if _, err := tc.cmd(ctx).WithLogger(log).Output(); err != nil {
				t.Fatalf("err = %v, want nil", err)
			}

			line := buf.String()
			if tc.warnings == 0 && buf.Len() != 0 {
				t.Fatalf("logged %q, want nothing", line)
			}
			if got := strings.Count(line, "level=WARN"); got != tc.warnings {
				t.Fatalf("logged %q, want %d warning(s)", line, tc.warnings)
			}
			if tc.warnings > 0 && !strings.Contains(line, "tool=pipe-holder") {
				t.Fatalf("logged %q, want the tool named", line)
			}
		})
	}
}

// A non-zero exit stays an *exec.ExitError with its code, stdout and stderr:
// over a WaitDelay overrun, inside the deadline straddle (where it is not a
// timeout), and on an ordinary failure with no pipe holder at all.
func TestOutputKeepsExitError(t *testing.T) {
	cases := []struct {
		name   string
		cmd    func(ctx context.Context) *Cmd
		code   int
		out    string
		stderr string
	}{
		{"over the WaitDelay overrun", func(ctx context.Context) *Cmd {
			return pipeHolder(t, ctx, 300*time.Millisecond, "echo partial\nexit 2\n")
		}, 2, "partial", ""},
		{"inside the deadline straddle", func(ctx context.Context) *Cmd {
			straddle, cancel := context.WithTimeout(ctx, 300*time.Millisecond)
			t.Cleanup(cancel)
			return pipeHolder(t, straddle, 700*time.Millisecond, "echo partial\nexit 2\n")
		}, 2, "partial", ""},
		{"an ordinary failure", func(ctx context.Context) *Cmd {
			return Command(ctx, "sh", "-c", "echo boom >&2; exit 3")
		}, 3, "", "boom"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
			defer cancel()

			res, err := tc.cmd(ctx).Output()

			var exitErr *exec.ExitError
			if !errors.As(err, &exitErr) {
				t.Fatalf("err = %v, want *exec.ExitError", err)
			}
			if errors.Is(err, exec.ErrWaitDelay) {
				t.Fatalf("err = %v, want the exit error, not the WaitDelay overrun", err)
			}
			if errors.Is(err, ErrTimeout) {
				t.Fatalf("err = %v, want the exit status, not a timeout", err)
			}
			if exitErr.ExitCode() != tc.code {
				t.Fatalf("exit code = %d, want %d", exitErr.ExitCode(), tc.code)
			}
			if res.Salvaged {
				t.Fatal("Salvaged = true for a non-zero exit")
			}
			if strings.TrimSpace(string(res.Out)) != tc.out {
				t.Fatalf("out = %q, want %q", res.Out, tc.out)
			}
			if strings.TrimSpace(string(exitErr.Stderr)) != tc.stderr {
				t.Fatalf("stderr = %q, want %q", exitErr.Stderr, tc.stderr)
			}
		})
	}
}

// classify orders the conditions it can see: a non-zero exit wins over a
// WaitDelay overrun (os/exec discards that error after a non-zero exit, so
// the joined error is synthetic) and over an expired deadline; a signalled
// child under an expired deadline is a timeout; a cancelled context is a
// cancellation and never a timeout.
func TestClassifyOrdersConditions(t *testing.T) {
	expired, cancelExpired := context.WithTimeout(context.Background(), time.Nanosecond)
	defer cancelExpired()
	<-expired.Done()
	canceled, cancel := context.WithCancel(context.Background())
	cancel()

	exit2 := exec.Command("sh", "-c", "exit 2").Run()
	var exit2Err *exec.ExitError
	if !errors.As(exit2, &exit2Err) || exit2Err.ExitCode() != 2 {
		t.Fatalf("fixture err = %v, want an *exec.ExitError with code 2", exit2)
	}
	signalled := exec.Command("sh", "-c", "kill -TERM $$").Run()
	var signalledErr *exec.ExitError
	if !errors.As(signalled, &signalledErr) || signalledErr.ExitCode() != -1 {
		t.Fatalf("fixture err = %v, want a signalled *exec.ExitError", signalled)
	}

	cases := []struct {
		name        string
		ctx         context.Context
		err         error
		exitError   bool
		timeout     bool
		canceled    bool
		interrupted bool
	}{
		{"non-zero exit joined with a WaitDelay overrun", context.Background(), errors.Join(&exec.ExitError{}, exec.ErrWaitDelay), true, false, false, false},
		{"independent non-zero exit under an expired deadline", expired, exit2, true, false, false, false},
		{"signalled child under an expired deadline", expired, signalled, false, true, false, true},
		{"killed child under a cancelled context", canceled, errors.New("signal: killed"), false, false, true, true},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			res, got := classify(tc.ctx, []byte("partial"), tc.err)

			if res.Salvaged {
				t.Fatal("Salvaged = true; none of these is a salvage")
			}
			var exitErr *exec.ExitError
			if errors.As(got, &exitErr) != tc.exitError {
				t.Fatalf("err = %v, want *exec.ExitError preserved = %v", got, tc.exitError)
			}
			if errors.Is(got, ErrTimeout) != tc.timeout {
				t.Fatalf("err = %v, want ErrTimeout = %v", got, tc.timeout)
			}
			if errors.Is(got, context.Canceled) != tc.canceled {
				t.Fatalf("err = %v, want context.Canceled = %v", got, tc.canceled)
			}
			if Interrupted(got) != tc.interrupted {
				t.Fatalf("Interrupted(%v) = %v, want %v", got, !tc.interrupted, tc.interrupted)
			}
		})
	}
}
