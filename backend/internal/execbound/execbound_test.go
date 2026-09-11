package execbound

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
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
	// The rows below derive their expectation from the default, so the default
	// itself must be a real bound: os/exec reads zero as no bound and a negative
	// value as a timer that has already fired.
	if DefaultWaitDelay <= 0 {
		t.Fatalf("DefaultWaitDelay = %v, want positive", DefaultWaitDelay)
	}
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
// Without WaitDelay, reads wait for the descendant, and the sleep must outlive
// the test for that wait to be real.
func pipeHolder(t *testing.T, ctx context.Context, delay time.Duration, tail string) *Cmd {
	t.Helper()
	dir := t.TempDir()
	pidPath := filepath.Join(dir, "fixture.pids")
	path := filepath.Join(dir, "pipe-holder")
	body := fmt.Sprintf("#!/bin/sh\necho $$ > '%s'\nsleep 60 &\necho $! >> '%s'\n%s", pidPath, pidPath, tail)
	if err := os.WriteFile(path, []byte(body), 0o755); err != nil {
		t.Fatal(err)
	}
	reapFixture(t, pidPath)
	return CommandWithDelay(ctx, delay, path)
}

// fixturePIDs reads what a fixture script recorded: its own pid first, then each
// descendant. A missing file means the script never ran, so nothing started.
func fixturePIDs(path string) ([]int, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	fields := strings.Fields(string(data))
	pids := make([]int, 0, len(fields))
	for _, field := range fields {
		pid, err := strconv.Atoi(field)
		if err != nil {
			return nil, fmt.Errorf("%s holds %q, not a pid: %w", path, field, err)
		}
		pids = append(pids, pid)
	}
	return pids, nil
}

// reapFixture ends every process the fixture recorded. Register it before the
// command runs: it reads the file at cleanup time, so a case that fails partway
// still ends whatever had started by then.
//
// It ends them by pid and never by process group. The group is the property
// under test, so a cleanup that signalled one would depend on the behaviour its
// own case exercises, and on a case that does not ask for KillGroup the negative
// id names no group at all and reaches nothing.
func reapFixture(t *testing.T, path string) {
	t.Helper()
	t.Cleanup(func() {
		pids, err := fixturePIDs(path)
		if err != nil {
			return
		}
		for _, pid := range pids {
			_ = syscall.Kill(pid, syscall.SIGKILL)
		}
	})
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

// A spawner stands in for a tool that fans out: it starts a grandchild and
// waits. The grandchild ignores SIGTERM, which survives its exec, so under
// KillGroup nothing but the group's SIGKILL can end it, and under the default
// cancel it outlives the child that started it. Both pids are recorded in the
// order reapFixture expects.
const spawnerScript = `#!/bin/sh
echo $$ > "$1"
sh -c 'trap "" TERM; exec sleep 300' &
echo $! >> "$1"
exec sleep 300
`

// The group kill is opt-in. A command that asks for KillGroup loses its whole
// fan-out on a cancel: mise leaves one `npm view` per npm-backed tool running
// otherwise, and those reparent to the user's init and stay until the process
// table is full. A command that does not ask keeps os/exec's child-only cancel,
// so a tool that changes system state is not cut down together with a helper it
// handed work to.
func TestCancelEndsTheDescendantGroupOnlyWhenAsked(t *testing.T) {
	cases := []struct {
		name      string
		killGroup bool
		gone      bool
	}{
		{"KillGroup ends the whole fan-out", true, true},
		{"the default cancel leaves the descendant running", false, false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			dir := t.TempDir()
			pidPath := filepath.Join(dir, "grandchild.pid")
			script := filepath.Join(dir, "spawner")
			if err := os.WriteFile(script, []byte(spawnerScript), 0o755); err != nil {
				t.Fatal(err)
			}
			reapFixture(t, pidPath)

			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			// A short delay bounds the pipe read a surviving grandchild holds open,
			// so the row that expects one reports rather than waits.
			cmd := CommandWithDelay(ctx, 300*time.Millisecond, script, pidPath)
			if tc.killGroup {
				cmd = cmd.KillGroup()
			}
			done := make(chan error, 1)
			go func() {
				_, err := cmd.Output()
				done <- err
			}()

			// The grandchild is the second pid: the spawner records itself first.
			pid := awaitFixturePIDs(t, pidPath, 2)[1]
			cancel()

			select {
			case err := <-done:
				if !errors.Is(err, context.Canceled) {
					t.Fatalf("err = %v, want context.Canceled", err)
				}
			case <-time.After(maxBoundedElapsed):
				t.Fatalf("the run did not return within %v of the cancel", maxBoundedElapsed)
			}

			if tc.gone {
				if err := awaitGone(pid, maxBoundedElapsed); err != nil {
					t.Fatalf("grandchild %d: %v", pid, err)
				}
				return
			}
			running, err := procRunning(pid)
			if err != nil {
				t.Fatal(err)
			}
			if !running {
				t.Fatalf("grandchild %d died without KillGroup, so the option is not what ends it", pid)
			}
		})
	}
}

// awaitFixturePIDs waits until the fixture has recorded want pids, so a case
// acts on a process that is running rather than one still being started.
func awaitFixturePIDs(t *testing.T, path string, want int) []int {
	t.Helper()
	deadline := time.Now().Add(maxBoundedElapsed)
	for {
		pids, err := fixturePIDs(path)
		if err == nil && len(pids) >= want {
			return pids
		}
		if time.Now().After(deadline) {
			t.Fatalf("%s held %d of %d fixture pids within %v: %v", path, len(pids), want, maxBoundedElapsed, err)
		}
		time.Sleep(10 * time.Millisecond)
	}
}

// procRunning reports whether pid is a live process, read from /proc rather than
// signalled so a pid the kernel has recycled cannot pass for the process this
// test started. A killed grandchild reparents to the user's init and is reaped
// there, so it is a zombie for a moment before its entry disappears; a zombie
// holds nothing open and is not running.
func procRunning(pid int) (bool, error) {
	data, err := os.ReadFile(fmt.Sprintf("/proc/%d/stat", pid))
	if err != nil {
		return false, nil
	}
	// The comm field is parenthesised and may itself contain spaces and
	// brackets, so the state character is the one two bytes past the last ')'.
	paren := bytes.LastIndexByte(data, ')')
	if paren < 0 || paren+2 >= len(data) {
		return false, fmt.Errorf("/proc/%d/stat carries no state field: %q", pid, data)
	}
	return data[paren+2] != 'Z', nil
}

func awaitGone(pid int, limit time.Duration) error {
	deadline := time.Now().Add(limit)
	for {
		running, err := procRunning(pid)
		if err != nil {
			return err
		}
		if !running {
			return nil
		}
		if time.Now().After(deadline) {
			return fmt.Errorf("still running %v after the cancel", limit)
		}
		time.Sleep(10 * time.Millisecond)
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
			// Capture every level: a clean run must log nothing at all.
			log := slog.New(slog.NewTextHandler(&buf, &slog.HandlerOptions{Level: slog.LevelDebug}))

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
