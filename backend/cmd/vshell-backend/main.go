// Command vshell-backend is the VGS backend binary. It is invoked by bin/vshell:
//
//	vshell-backend run              -> runner: socket + Quickshell child (from `vshell run`)
//	vshell-backend serve            -> daemon only, no Quickshell (debugging)
//	vshell-backend request M [json] -> send one method call to the running socket
//	vshell-backend doctor           -> connect + getServerInfo health check
//	vshell-backend methods [--json] -> print the advertised method/capability set
package main

import (
	"encoding/json"
	"fmt"
	"log/slog"
	"net"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"syscall"

	"vshell/backend/internal/client"
	"vshell/backend/internal/registry"
	"vshell/backend/internal/runner"
	"vshell/backend/internal/server"
	"vshell/backend/internal/services"
)

func main() {
	args := os.Args[1:]
	if len(args) == 0 {
		usage()
		os.Exit(2)
	}
	cmd, rest := args[0], args[1:]

	switch cmd {
	case "run":
		code, err := runner.Run(runner.Options{QSArgs: rest, Log: newLogger()})
		if err != nil {
			fmt.Fprintln(os.Stderr, "vshell-backend run:", err)
		}
		os.Exit(code)
	case "serve":
		os.Exit(serve())
	case "request":
		os.Exit(doRequest(rest))
	case "doctor":
		os.Exit(doctor())
	case "methods":
		os.Exit(methods(rest))
	case "-h", "--help", "help":
		usage()
	default:
		fmt.Fprintln(os.Stderr, "unknown subcommand:", cmd)
		usage()
		os.Exit(2)
	}
}

func newLogger() *slog.Logger {
	level := slog.LevelInfo
	switch strings.ToLower(os.Getenv("VGS_BACKEND_LOG_LEVEL")) {
	case "debug":
		level = slog.LevelDebug
	case "warn":
		level = slog.LevelWarn
	case "error":
		level = slog.LevelError
	}
	return slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: level}))
}

// serve runs the daemon (no Quickshell). Under the runner it accepts on the
// listener FD inherited via VGS_BACKEND_LISTEN_FD, so the runner keeps socket
// ownership across backend restarts; standalone (debugging/tests) it binds
// VGS_BACKEND_SOCKET itself.
func serve() int {
	var ln net.Listener
	var cleanup func()

	if fdStr := os.Getenv("VGS_BACKEND_LISTEN_FD"); fdStr != "" {
		fd, err := strconv.Atoi(fdStr)
		if err != nil {
			fmt.Fprintln(os.Stderr, "serve: bad VGS_BACKEND_LISTEN_FD:", fdStr)
			return 2
		}
		f := os.NewFile(uintptr(fd), "vgs-backend-listener")
		inherited, err := net.FileListener(f)
		f.Close() // FileListener dups the fd
		if err != nil {
			fmt.Fprintln(os.Stderr, "serve: inherited listener:", err)
			return 1
		}
		ln = inherited
		cleanup = func() { ln.Close() } // never unlink: the runner owns the path
	} else {
		path := os.Getenv("VGS_BACKEND_SOCKET")
		if path == "" {
			fmt.Fprintln(os.Stderr, "serve: set VGS_BACKEND_SOCKET to a socket path")
			return 2
		}
		_ = os.Remove(path)
		// Bind at 0600 from creation (same umask guard as the runner) so there is
		// no world-accessible window even for the debug socket.
		old := syscall.Umask(0o177)
		bound, err := net.Listen("unix", path)
		syscall.Umask(old)
		if err != nil {
			fmt.Fprintln(os.Stderr, "serve:", err)
			return 1
		}
		if err := os.Chmod(path, 0o600); err != nil {
			bound.Close()
			_ = os.Remove(path)
			fmt.Fprintln(os.Stderr, "serve:", err)
			return 1
		}
		ln = bound
		cleanup = func() { ln.Close(); os.Remove(path) }
	}
	defer cleanup()

	log := newLogger()
	srv := server.New(uint32(os.Getuid()), log)
	closeServices := services.RegisterAll(srv, log)
	defer closeServices()
	go func() {
		if err := srv.Serve(ln); err != nil {
			log.Error("serve stopped", "err", err)
		}
	}()

	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
	<-sigCh
	return 0
}

func doRequest(rest []string) int {
	if len(rest) == 0 {
		fmt.Fprintln(os.Stderr, "request: usage: request <method> [json-params]")
		return 2
	}
	var params json.RawMessage
	if len(rest) > 1 {
		params = json.RawMessage(rest[1])
	}
	resp, err := client.Request(rest[0], params)
	if err != nil {
		fmt.Fprintln(os.Stderr, "request:", err)
		return 1
	}
	out, _ := json.Marshal(resp)
	fmt.Println(string(out))
	if resp.Error != "" {
		return 1
	}
	return 0
}

func doctor() int {
	path, err := client.SocketPath()
	if err != nil {
		fmt.Fprintln(os.Stderr, "doctor: FAIL:", err)
		return 1
	}
	resp, err := client.Request("getServerInfo", nil)
	if err != nil {
		fmt.Fprintf(os.Stderr, "doctor: FAIL: %s (socket %s)\n", err, path)
		return 1
	}
	if resp.Error != "" {
		fmt.Fprintln(os.Stderr, "doctor: FAIL:", resp.Error)
		return 1
	}
	out, _ := json.MarshalIndent(resp.Result, "", "  ")
	fmt.Printf("doctor: OK (socket %s)\n%s\n", path, out)
	return 0
}

// methods prints the advertised inventory, preferring the running daemon's
// getServerInfo. It must never call services.RegisterAll: registering live
// services has side effects (it would steal BlueZ default-agent status from
// the running backend's pairing agent). Without a running daemon it reports
// the static core set so tooling works offline.
func methods(rest []string) int {
	asJSON := false
	for _, a := range rest {
		if a == "--json" {
			asJSON = true
		}
	}
	srv := server.New(uint32(os.Getuid()), newLogger())
	info := registry.Info(srv.Capabilities(), srv.Methods())
	if resp, err := client.Request("getServerInfo", nil); err == nil && resp.Error == "" {
		if raw, merr := json.Marshal(resp.Result); merr == nil {
			var live registry.ServerInfo
			if json.Unmarshal(raw, &live) == nil && len(live.Methods) > 0 {
				info = live
			}
		}
	} else {
		fmt.Fprintln(os.Stderr, "methods: no running backend, reporting the static core set")
	}
	if asJSON {
		out, _ := json.MarshalIndent(info, "", "  ")
		fmt.Println(string(out))
		return 0
	}
	fmt.Printf("apiVersion=%d vgsApiVersion=%d cliVersion=%s\n", info.APIVersion, info.VGSAPIVersion, info.CLIVersion)
	fmt.Println("capabilities:", strings.Join(info.Capabilities, ", "))
	fmt.Println("methods:", strings.Join(info.Methods, ", "))
	return 0
}

func usage() {
	fmt.Fprintln(os.Stderr, strings.TrimSpace(`
vshell-backend <command>
  run [qs args...]        runner: backend socket + Quickshell child
  serve                   daemon only (needs VGS_BACKEND_SOCKET)
  request <method> [json] send one method call to the running socket
  doctor                  connect + getServerInfo health check
  methods [--json]        print advertised methods/capabilities`))
}
