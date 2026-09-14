package gamma

import (
	"errors"
	"fmt"
	"log/slog"
	"os"
	"strconv"
	"strings"
	"syscall"
	"time"

	"golang.org/x/sys/unix"
)

// commLen is the longest command name the kernel records for a process.
const commLen = 15

type strayProcess struct {
	pid int
	fd  int
}

// terminateStrays ends every process of this user, other than this one, whose
// command name is name. Two instances of a gamma adapter fight over the
// display's gamma ramp, so an instance this backend did not start, such as one
// left by an earlier backend or started by hand, is ended before a launch. Each
// process gets SIGTERM, then SIGKILL after grace. Signals go through a pidfd, so
// a pid reused after the scan is never signalled.
func terminateStrays(log *slog.Logger, name string, grace time.Duration) error {
	if len(name) > commLen {
		name = name[:commLen]
	}
	entries, err := os.ReadDir("/proc")
	if err != nil {
		return fmt.Errorf("scan for running %s: %w", name, err)
	}
	uid := os.Getuid()
	self := os.Getpid()
	var strays []strayProcess
	defer func() {
		for _, s := range strays {
			unix.Close(s.fd)
		}
	}()
	for _, entry := range entries {
		pid, err := strconv.Atoi(entry.Name())
		if err != nil || pid == self || !isStray(pid, name, uid) {
			continue
		}
		fd, err := unix.PidfdOpen(pid, 0)
		if errors.Is(err, unix.ESRCH) {
			continue
		}
		if err != nil {
			return fmt.Errorf("open running %s pid %d: %w", name, pid, err)
		}
		// The pid may have been reused between the scan and the open; the pidfd
		// holds whichever process has it now, so check that one.
		if !isStray(pid, name, uid) {
			unix.Close(fd)
			continue
		}
		strays = append(strays, strayProcess{pid: pid, fd: fd})
	}
	if len(strays) == 0 {
		return nil
	}

	for _, s := range strays {
		if log != nil {
			log.Warn("ending a running gamma adapter this backend did not start", "program", name, "pid", s.pid)
		}
	}
	if err := signalStrays(strays, unix.SIGTERM); err != nil {
		return fmt.Errorf("terminate running %s: %w", name, err)
	}
	alive, err := awaitStrays(strays, grace)
	if err != nil {
		return fmt.Errorf("wait for running %s to exit: %w", name, err)
	}
	if len(alive) == 0 {
		return nil
	}
	if err := signalStrays(alive, unix.SIGKILL); err != nil {
		return fmt.Errorf("kill running %s: %w", name, err)
	}
	alive, err = awaitStrays(alive, grace)
	if err != nil {
		return fmt.Errorf("wait for running %s to exit: %w", name, err)
	}
	if len(alive) > 0 {
		return fmt.Errorf("running %s pid %d did not exit after SIGKILL", name, alive[0].pid)
	}
	return nil
}

// isStray reports a process owned by uid whose command name is name. A process
// that exits while it is read is not a stray.
func isStray(pid int, name string, uid int) bool {
	dir := "/proc/" + strconv.Itoa(pid)
	comm, err := os.ReadFile(dir + "/comm")
	if err != nil || strings.TrimSuffix(string(comm), "\n") != name {
		return false
	}
	info, err := os.Stat(dir)
	if err != nil {
		return false
	}
	st, ok := info.Sys().(*syscall.Stat_t)
	return ok && int(st.Uid) == uid
}

func signalStrays(strays []strayProcess, sig unix.Signal) error {
	for _, s := range strays {
		if err := unix.PidfdSendSignal(s.fd, sig, nil, 0); err != nil && !errors.Is(err, unix.ESRCH) {
			return fmt.Errorf("pid %d: %w", s.pid, err)
		}
	}
	return nil
}

// awaitStrays waits up to grace for the processes to exit and returns the ones
// still running. A pidfd becomes readable when its process exits.
func awaitStrays(strays []strayProcess, grace time.Duration) ([]strayProcess, error) {
	deadline := time.Now().Add(grace)
	alive := append([]strayProcess(nil), strays...)
	for len(alive) > 0 {
		left := time.Until(deadline)
		if left <= 0 {
			break
		}
		fds := make([]unix.PollFd, len(alive))
		for i, s := range alive {
			fds[i] = unix.PollFd{Fd: int32(s.fd), Events: unix.POLLIN}
		}
		if _, err := unix.Poll(fds, int(left.Milliseconds())+1); err != nil {
			if errors.Is(err, unix.EINTR) {
				continue
			}
			return nil, err
		}
		kept := alive[:0]
		for i, s := range alive {
			if fds[i].Revents == 0 {
				kept = append(kept, s)
			}
		}
		alive = kept
	}
	return alive, nil
}
