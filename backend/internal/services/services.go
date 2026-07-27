package services

import (
	"log/slog"
	"os"
	"strings"

	"vshell/backend/internal/server"
	"vshell/backend/internal/services/bluez"
	"vshell/backend/internal/services/brightnessbridge"
	"vshell/backend/internal/services/clipboard"
	"vshell/backend/internal/services/cups"
	"vshell/backend/internal/services/dbusbridge"
	"vshell/backend/internal/services/evdev"
	"vshell/backend/internal/services/freedesktop"
	"vshell/backend/internal/services/gamma"
	"vshell/backend/internal/services/location"
	"vshell/backend/internal/services/loginctl"
	"vshell/backend/internal/services/mimeapps"
	"vshell/backend/internal/services/networkmanager"
	"vshell/backend/internal/services/sysupdate"
	"vshell/backend/internal/services/tailscale"
	"vshell/backend/internal/services/wallpaper"
	"vshell/backend/internal/services/wlroutput"
)

type closer interface {
	Close()
}

// RegisterAll wires optional system-integration services. A service that cannot
// initialize leaves its capability absent; shell startup must still proceed.
// VGS_BACKEND_DISABLE (comma-separated capability names, e.g. "network,cups")
// skips services without a rebuild.
func RegisterAll(srv *server.Server, log *slog.Logger) func() {
	disabled := parseDisabled(os.Getenv("VGS_BACKEND_DISABLE"))
	var closers []closer

	// register runs one service's constructor unless it is disabled, tracks
	// its closer, and reports failures without blocking the rest.
	register := func(name string, init func() (closer, error)) bool {
		if disabled[name] {
			log.Info("service disabled via VGS_BACKEND_DISABLE", "service", name)
			return false
		}
		c, err := init()
		if err != nil {
			log.Warn(name+" service unavailable", "err", err)
			return false
		}
		closers = append(closers, c)
		return true
	}

	// loginctl and freedesktop are wired to each other, so their managers are
	// kept in scope instead of going through the generic helper's closure.
	var login *loginctl.Manager
	if disabled["loginctl"] {
		log.Info("service disabled via VGS_BACKEND_DISABLE", "service", "loginctl")
	} else if m, err := loginctl.Register(srv, log); err != nil {
		log.Warn("loginctl service unavailable", "err", err)
	} else {
		login = m
		closers = append(closers, m)
	}

	register("dbus", func() (closer, error) { return dbusbridge.Register(srv, log) })

	if disabled["freedesktop"] {
		log.Info("service disabled via VGS_BACKEND_DISABLE", "service", "freedesktop")
	} else if free, err := freedesktop.Register(srv, log); err != nil {
		log.Warn("freedesktop screensaver service unavailable", "err", err)
	} else {
		closers = append(closers, free)
		if login != nil {
			login.AddStateListener(func(state loginctl.State) {
				free.SetScreenLockActive(state.Locked)
			})
			// Apps calling org.freedesktop.ScreenSaver.Lock get a real
			// session lock through the shell's single lock path (logind).
			free.SetLockRequestHandler(func() {
				if err := login.Lock(); err != nil {
					log.Warn("screensaver lock request failed", "err", err)
				}
			})
		}
	}

	register("mime", func() (closer, error) { return mimeapps.Register(srv, log) })
	register("network", func() (closer, error) { return networkmanager.Register(srv, log) })
	register("bluetooth", func() (closer, error) { return bluez.Register(srv, log) })
	register("clipboard", func() (closer, error) { return clipboard.Register(srv, log) })
	register("gamma", func() (closer, error) { return gamma.Register(srv, log) })
	register("location", func() (closer, error) { return location.Register(srv, log) })
	register("wallpaper", func() (closer, error) { return wallpaper.Register(srv, log) })
	register("brightness", func() (closer, error) { return brightnessbridge.Register(srv, log) })
	register("wlroutput", func() (closer, error) { return wlroutput.Register(srv, log) })
	register("cups", func() (closer, error) { return cups.Register(srv, log) })
	register("tailscale", func() (closer, error) { return tailscale.Register(srv, log) })
	register("sysupdate", func() (closer, error) { return sysupdate.Register(srv, log) })
	register("evdev", func() (closer, error) { return evdev.Register(srv, log) })

	return func() {
		for i := len(closers) - 1; i >= 0; i-- {
			closers[i].Close()
		}
	}
}

// parseDisabled splits VGS_BACKEND_DISABLE into a capability-name set.
func parseDisabled(raw string) map[string]bool {
	out := map[string]bool{}
	for _, name := range strings.Split(raw, ",") {
		name = strings.ToLower(strings.TrimSpace(name))
		if name != "" {
			out[name] = true
		}
	}
	return out
}
