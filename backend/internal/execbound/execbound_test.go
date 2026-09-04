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

func TestCommandSetsDefaultWaitDelay(t *testing.T) {
	cmd := Command(context.Background(), "true")
	if cmd.Exec().WaitDelay != DefaultWaitDelay {
		t.Fatalf("WaitDelay = %v, want %v", cmd.Exec().WaitDelay, DefaultWaitDelay)
	}
}

// Zero disables the pipe-read bound. The upper limit is independent of the
// production constant.
func TestDefaultWaitDelayStaysInASaneBand(t *testing.T) {
	if DefaultWaitDelay <= 0 || DefaultWaitDelay > 3*time.Second {
		t.Fatalf("DefaultWaitDelay = %v, want a bound in (0, 3s]", DefaultWaitDelay)
	}
}

func TestCommandWithDelayUsesTheGivenDelay(t *testing.T) {
	cmd := CommandWithDelay(context.Background(), 700*time.Millisecond, "true")
	if cmd.Exec().WaitDelay != 700*time.Millisecond {
		t.Fatalf("WaitDelay = %v, want 700ms", cmd.Exec().WaitDelay)
	}
}

// os/exec reads WaitDelay == 0 as no bound at all, so a caller passing a zero
// or negative delay would silently get the wedge this package prevents.
func TestCommandWithDelayClampsNonPositiveDelay(t *testing.T) {
	for _, delay := range []time.Duration{0, -time.Second} {
		cmd := CommandWithDelay(context.Background(), delay, "true")
		if cmd.Exec().WaitDelay != DefaultWaitDelay {
			t.Fatalf("WaitDelay for %v = %v, want %v", delay, cmd.Exec().WaitDelay, DefaultWaitDelay)
		}
	}
}

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

func TestOutputSalvagesCleanExitWithHeldPipe(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
	defer cancel()
	cmd := pipeHolder(t, ctx, 300*time.Millisecond, "echo done\n")

	res, err := cmd.Output()

	if err != nil {
		t.Fatalf("err = %v, want nil: the child exited 0 and its output was read", err)
	}
	if !res.Salvaged {
		t.Fatal("Salvaged = false; the held pipes must be reportable")
	}
	if strings.TrimSpace(string(res.Out)) != "done" {
		t.Fatalf("out = %q, want %q", res.Out, "done")
	}
}

func TestOutputWarnsOnceWhenItSalvages(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
	defer cancel()
	var buf bytes.Buffer
	log := slog.New(slog.NewTextHandler(&buf, &slog.HandlerOptions{Level: slog.LevelWarn}))
	cmd := pipeHolder(t, ctx, 300*time.Millisecond, "echo done\n")

	if _, err := cmd.WithLogger(log).Output(); err != nil {
		t.Fatalf("err = %v, want nil", err)
	}

	line := buf.String()
	if strings.Count(line, "level=WARN") != 1 {
		t.Fatalf("logged %q, want exactly one warning", line)
	}
	if !strings.Contains(line, "tool=pipe-holder") {
		t.Fatalf("logged %q, want the tool named", line)
	}
}

func TestOutputDoesNotWarnWithoutSalvage(t *testing.T) {
	var buf bytes.Buffer
	log := slog.New(slog.NewTextHandler(&buf, &slog.HandlerOptions{Level: slog.LevelWarn}))

	if _, err := Command(context.Background(), "true").WithLogger(log).Output(); err != nil {
		t.Fatalf("err = %v, want nil", err)
	}

	if buf.Len() != 0 {
		t.Fatalf("logged %q, want nothing", buf.String())
	}
}

func TestCombinedOutputSalvagesCleanExitWithHeldPipe(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
	defer cancel()
	cmd := pipeHolder(t, ctx, 300*time.Millisecond, "echo done >&2\n")

	res, err := cmd.CombinedOutput()

	if err != nil {
		t.Fatalf("err = %v, want nil", err)
	}
	if !res.Salvaged {
		t.Fatal("Salvaged = false; the held pipes must be reportable")
	}
	if strings.TrimSpace(string(res.Out)) != "done" {
		t.Fatalf("out = %q, want %q", res.Out, "done")
	}
}

// A clean child exit takes precedence when the deadline expires while a
// descendant still holds the pipes.
func TestOutputSalvagesInsideTheDeadlineStraddle(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 300*time.Millisecond)
	defer cancel()
	cmd := pipeHolder(t, ctx, 700*time.Millisecond, "echo done\n")

	res, err := cmd.Output()

	if err != nil {
		t.Fatalf("err = %v, want nil: the child finished inside the straddle window", err)
	}
	if !res.Salvaged {
		t.Fatal("Salvaged = false")
	}
	if strings.TrimSpace(string(res.Out)) != "done" {
		t.Fatalf("out = %q, want %q", res.Out, "done")
	}
}

// A non-zero exit must remain an *exec.ExitError so callers can inspect exit
// codes and stderr.
func TestOutputKeepsExitErrorOverWaitDelay(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
	defer cancel()
	cmd := pipeHolder(t, ctx, 300*time.Millisecond, "echo partial\nexit 2\n")

	res, err := cmd.Output()

	var exitErr *exec.ExitError
	if !errors.As(err, &exitErr) {
		t.Fatalf("err = %v, want *exec.ExitError", err)
	}
	if errors.Is(err, exec.ErrWaitDelay) {
		t.Fatalf("err = %v, want the exit error, not the WaitDelay overrun", err)
	}
	if exitErr.ExitCode() != 2 {
		t.Fatalf("exit code = %d, want 2", exitErr.ExitCode())
	}
	if res.Salvaged {
		t.Fatal("Salvaged = true for a non-zero exit")
	}
	if strings.TrimSpace(string(res.Out)) != "partial" {
		t.Fatalf("out = %q, want %q", res.Out, "partial")
	}
}

// os/exec discards WaitDelay errors after non-zero exits. A synthetic combined
// error is needed to test ExitError precedence over ErrWaitDelay.
func TestClassifyKeepsExitErrorWhenBothConditionsHold(t *testing.T) {
	err := errors.Join(&exec.ExitError{}, exec.ErrWaitDelay)

	res, got := classify(context.Background(), []byte("partial"), err)

	if res.Salvaged {
		t.Fatal("Salvaged = true; a non-zero exit is not a salvage")
	}
	var exitErr *exec.ExitError
	if !errors.As(got, &exitErr) {
		t.Fatalf("err = %v, want the *exec.ExitError preserved", got)
	}
}

// A child can exit non-zero before descendants hold its pipes past the deadline.
// Its exit code and stderr must remain available to callers.
func TestOutputKeepsExitErrorInsideTheDeadlineStraddle(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 300*time.Millisecond)
	defer cancel()
	cmd := pipeHolder(t, ctx, 700*time.Millisecond, "echo partial\nexit 2\n")

	res, err := cmd.Output()

	if errors.Is(err, ErrTimeout) {
		t.Fatalf("err = %v, want the exit status, not a timeout", err)
	}
	var exitErr *exec.ExitError
	if !errors.As(err, &exitErr) {
		t.Fatalf("err = %v, want *exec.ExitError", err)
	}
	if exitErr.ExitCode() != 2 {
		t.Fatalf("exit code = %d, want 2", exitErr.ExitCode())
	}
	if res.Salvaged {
		t.Fatal("Salvaged = true for a non-zero exit")
	}
	if strings.TrimSpace(string(res.Out)) != "partial" {
		t.Fatalf("out = %q, want %q", res.Out, "partial")
	}
}

// A child killed by the deadline has no exit code and must remain ErrTimeout.
func TestClassifyOrdersExitStatusAgainstAnExpiredDeadline(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), time.Nanosecond)
	defer cancel()
	<-ctx.Done()

	independent := exec.Command("sh", "-c", "exit 2").Run()
	var independentExit *exec.ExitError
	if !errors.As(independent, &independentExit) || independentExit.ExitCode() != 2 {
		t.Fatalf("fixture err = %v, want an *exec.ExitError with code 2", independent)
	}
	if _, got := classify(ctx, nil, independent); !errors.As(got, &independentExit) {
		t.Fatalf("err = %v, want the independent exit status preserved", got)
	} else if errors.Is(got, ErrTimeout) {
		t.Fatalf("err = %v, want no ErrTimeout for an independent exit", got)
	}

	killed := exec.Command("sh", "-c", "kill -TERM $$").Run()
	var killedExit *exec.ExitError
	if !errors.As(killed, &killedExit) || killedExit.ExitCode() != -1 {
		t.Fatalf("fixture err = %v, want a signalled *exec.ExitError", killed)
	}
	if _, got := classify(ctx, nil, killed); !errors.Is(got, ErrTimeout) {
		t.Fatalf("err = %v, want ErrTimeout for a signalled child", got)
	}
}

func TestClassifyReportsCancellationAsCanceled(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()

	_, err := classify(ctx, nil, errors.New("signal: killed"))

	if !errors.Is(err, context.Canceled) {
		t.Fatalf("err = %v, want context.Canceled", err)
	}
	if errors.Is(err, ErrTimeout) {
		t.Fatalf("err = %v, want no ErrTimeout for a cancellation", err)
	}
	if !Interrupted(err) {
		t.Fatalf("Interrupted(%v) = false, want true", err)
	}
}

func TestOutputPassesThroughOrdinaryExitError(t *testing.T) {
	res, err := Command(context.Background(), "sh", "-c", "echo boom >&2; exit 3").Output()

	var exitErr *exec.ExitError
	if !errors.As(err, &exitErr) {
		t.Fatalf("err = %v, want *exec.ExitError", err)
	}
	if exitErr.ExitCode() != 3 {
		t.Fatalf("exit code = %d, want 3", exitErr.ExitCode())
	}
	if strings.TrimSpace(string(exitErr.Stderr)) != "boom" {
		t.Fatalf("stderr = %q, want %q", exitErr.Stderr, "boom")
	}
	if res.Salvaged {
		t.Fatal("Salvaged = true for an ordinary failure")
	}
}
