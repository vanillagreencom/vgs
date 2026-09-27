// Package recovery keeps a panic in one unit of backend work from ending the
// daemon. A service goroutine runs each unit through Run, so a fault degrades
// that unit and is logged with its stack.
package recovery

import (
	"log/slog"
	"runtime/debug"
	"time"
)

// Run calls fn and logs a panic from it instead of letting it unwind the
// goroutine. where names the unit in the log. A long-lived loop passes one
// iteration as fn, not the whole loop, so the loop keeps serving after a fault.
// Deferred calls inside fn still run during the unwind; a lock fn took without
// a deferred unlock stays held. A nil log uses slog's default logger.
func Run(log *slog.Logger, where string, fn func()) {
	defer func() {
		if r := recover(); r != nil {
			if log == nil {
				log = slog.Default()
			}
			log.Error("recovered panic", "where", where, "panic", r, "stack", string(debug.Stack()))
		}
	}()
	fn()
}

// AfterFunc waits for d and then calls fn through Run on its own goroutine, as
// time.AfterFunc does.
func AfterFunc(d time.Duration, log *slog.Logger, where string, fn func()) *time.Timer {
	return time.AfterFunc(d, func() { Run(log, where, fn) })
}
