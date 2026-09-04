package wallpaper

import (
	"encoding/json"
	"fmt"
	"log/slog"
	"os"
	"path/filepath"
	"reflect"
	"strconv"
	"strings"
	"sync"
	"time"

	"vshell/backend/internal/server"
)

const catchUpDelay = 3 * time.Second

type ScheduleConfig struct {
	Enabled     bool   `json:"enabled"`
	Mode        string `json:"mode"`
	IntervalSec int    `json:"intervalSec"`
	Time        string `json:"time"`
}

type Config struct {
	PerMonitor bool                      `json:"perMonitor"`
	Global     ScheduleConfig            `json:"global"`
	Monitors   map[string]ScheduleConfig `json:"monitors"`
}

type State struct {
	Config       Config    `json:"config"`
	NextRotation time.Time `json:"nextRotation"`
	CycleSeq     uint64    `json:"cycleSeq"`
	Target       string    `json:"target"`
}

type Manager struct {
	log *slog.Logger
	srv *server.Server

	mu         sync.RWMutex
	config     Config
	state      State
	lastFires  map[string]time.Time
	lastFiresP string

	stop   chan struct{}
	wake   chan struct{}
	resets chan string
	wg     sync.WaitGroup
}

type setConfigParams struct {
	Config Config `json:"config"`
}

type triggerParams struct {
	Target string `json:"target"`
}

type persistedState struct {
	LastFires map[string]time.Time `json:"lastFires"`
}

type activeSchedule struct {
	cfg      ScheduleConfig
	nextFire time.Time
}

func Register(srv *server.Server, log *slog.Logger) (*Manager, error) {
	if log == nil {
		log = slog.Default()
	}
	m := &Manager{
		log:        log,
		srv:        srv,
		config:     defaultConfig(),
		lastFiresP: stateFilePath(),
		stop:       make(chan struct{}),
		wake:       make(chan struct{}, 1),
		resets:     make(chan string, 8),
	}
	m.lastFires = m.loadLastFires()
	m.state = State{Config: m.config}

	srv.Register("wallpaper", "wallpaper.getState", m.handleGetState)
	srv.Register("wallpaper", "wallpaper.setConfig", m.handleSetConfig)
	srv.Register("wallpaper", "wallpaper.trigger", m.handleTrigger)
	srv.Register("wallpaper", "wallpaper.subscribe", m.handleSubscribe)
	srv.RegisterSnapshot("wallpaper", func() any { return m.GetState() })

	m.wg.Add(1)
	go m.schedulerLoop()

	return m, nil
}

func (m *Manager) Close() {
	select {
	case <-m.stop:
		return
	default:
		close(m.stop)
	}
	m.wg.Wait()
}

func (m *Manager) GetState() State {
	m.mu.RLock()
	defer m.mu.RUnlock()
	return m.state
}

func (m *Manager) handleGetState(json.RawMessage) (any, error) {
	return m.GetState(), nil
}

func (m *Manager) handleSubscribe(json.RawMessage) (any, error) {
	return m.GetState(), nil
}

func (m *Manager) handleSetConfig(params json.RawMessage) (any, error) {
	var p setConfigParams
	if err := json.Unmarshal(params, &p); err != nil {
		return nil, err
	}
	cfg := normalizeConfig(p.Config)

	m.mu.Lock()
	if reflect.DeepEqual(m.config, cfg) {
		m.mu.Unlock()
		return map[string]any{"success": true, "message": "wallpaper schedule unchanged"}, nil
	}
	m.config = cfg
	m.mu.Unlock()
	m.notifyScheduler()

	return map[string]any{"success": true, "message": "wallpaper schedule set"}, nil
}

func (m *Manager) handleTrigger(params json.RawMessage) (any, error) {
	var p triggerParams
	if len(params) > 0 {
		if err := json.Unmarshal(params, &p); err != nil {
			return nil, err
		}
	}
	select {
	case m.resets <- p.Target:
	default:
		// Do not report success for a trigger that was dropped.
		return nil, fmt.Errorf("wallpaper scheduler busy, trigger dropped; retry")
	}
	return map[string]any{"success": true, "message": "wallpaper schedule reset"}, nil
}

func (m *Manager) schedulerLoop() {
	defer m.wg.Done()

	schedules := map[string]*activeSchedule{}
	resets := map[string]bool{}
	var seq uint64
	var timer *time.Timer

	for {
		now := time.Now()
		config := m.getConfig()
		active := activeSchedules(config)

		for key := range schedules {
			if _, ok := active[key]; !ok {
				delete(schedules, key)
			}
		}

		firesDirty := false
		for key, cfg := range active {
			s, ok := schedules[key]
			switch {
			case !ok:
				s = &activeSchedule{cfg: cfg, nextFire: computeNext(now, cfg)}
				schedules[key] = s
				if cfg.Mode == "time" {
					last := m.lastFires[key]
					prev, valid := prevDailyTime(now, cfg.Time)
					switch {
					case last.IsZero():
						m.lastFires[key] = now
						firesDirty = true
					case valid && last.Before(prev):
						s.nextFire = now.Add(catchUpDelay)
					}
				}
			case s.cfg != cfg || resets[key]:
				s.cfg = cfg
				s.nextFire = computeNext(now, cfg)
			}
			delete(resets, key)
		}
		// Resets aimed at schedules that are not active are meaningless; if
		// they lingered they would spuriously reschedule the target the
		// moment it is re-enabled.
		clear(resets)

		var dueKeys []string
		for key, s := range schedules {
			if !s.nextFire.After(now) {
				dueKeys = append(dueKeys, key)
				s.nextFire = computeNext(now, s.cfg)
				if s.cfg.Mode == "time" {
					m.lastFires[key] = now
					firesDirty = true
				}
			}
		}

		if firesDirty {
			// Keep disabled schedules for configured monitors so daily rotation can catch
			// up when re-enabled. Remove only monitors absent from configuration.
			known := map[string]bool{"": true}
			for name := range config.Monitors {
				known[name] = true
			}
			for key := range m.lastFires {
				if !known[key] {
					delete(m.lastFires, key)
				}
			}
			m.saveLastFires()
		}

		next, hasNext := soonest(schedules)
		if len(dueKeys) == 0 {
			m.setState(config, next, seq, "")
		}
		for _, key := range dueKeys {
			seq++
			m.setState(config, next, seq, key)
		}

		wait := 24 * time.Hour
		if hasNext {
			wait = time.Until(next)
			if wait < time.Second {
				wait = time.Second
			}
		}
		if timer != nil {
			timer.Stop()
		}
		timer = time.NewTimer(wait)

		select {
		case <-m.stop:
			timer.Stop()
			return
		case <-m.wake:
			timer.Stop()
		case key := <-m.resets:
			timer.Stop()
			resets[key] = true
		case <-timer.C:
		}
	}
}

func (m *Manager) setState(config Config, next time.Time, seq uint64, target string) {
	nextState := State{Config: config, NextRotation: next, CycleSeq: seq, Target: target}
	m.mu.Lock()
	if statesEqual(m.state, nextState) {
		m.mu.Unlock()
		return
	}
	m.state = nextState
	m.mu.Unlock()
	m.srv.Broadcast("wallpaper", nextState)
}

func (m *Manager) notifyScheduler() {
	select {
	case m.wake <- struct{}{}:
	default:
	}
}

func (m *Manager) getConfig() Config {
	m.mu.RLock()
	defer m.mu.RUnlock()
	return m.config
}

func defaultConfig() Config {
	return Config{
		Global:   ScheduleConfig{Mode: "interval", IntervalSec: 300, Time: "06:00"},
		Monitors: map[string]ScheduleConfig{},
	}
}

func normalizeConfig(cfg Config) Config {
	if cfg.Global.Mode == "" {
		cfg.Global.Mode = "interval"
	}
	if cfg.Global.IntervalSec <= 0 {
		cfg.Global.IntervalSec = 300
	}
	if cfg.Global.Time == "" {
		cfg.Global.Time = "06:00"
	}
	if cfg.Monitors == nil {
		cfg.Monitors = map[string]ScheduleConfig{}
	}
	for name, mon := range cfg.Monitors {
		if mon.Mode == "" {
			mon.Mode = "interval"
		}
		if mon.IntervalSec <= 0 {
			mon.IntervalSec = 300
		}
		if mon.Time == "" {
			mon.Time = "06:00"
		}
		cfg.Monitors[name] = mon
	}
	return cfg
}

func activeSchedules(config Config) map[string]ScheduleConfig {
	out := map[string]ScheduleConfig{}
	if config.PerMonitor {
		for name, cfg := range config.Monitors {
			if cfg.Enabled {
				out[name] = cfg
			}
		}
		return out
	}
	if config.Global.Enabled {
		out[""] = config.Global
	}
	return out
}

func computeNext(now time.Time, cfg ScheduleConfig) time.Time {
	if cfg.Mode == "time" {
		return nextDailyTime(now, cfg.Time)
	}
	sec := cfg.IntervalSec
	if sec < 1 {
		sec = 1
	}
	return now.Add(time.Duration(sec) * time.Second)
}

func nextDailyTime(now time.Time, hhmm string) time.Time {
	hour, minute, ok := parseHHMM(hhmm)
	if !ok {
		return now.Add(24 * time.Hour)
	}
	next := time.Date(now.Year(), now.Month(), now.Day(), hour, minute, 0, 0, now.Location())
	if !next.After(now) {
		next = next.Add(24 * time.Hour)
	}
	return next
}

func prevDailyTime(now time.Time, hhmm string) (time.Time, bool) {
	hour, minute, ok := parseHHMM(hhmm)
	if !ok {
		return time.Time{}, false
	}
	prev := time.Date(now.Year(), now.Month(), now.Day(), hour, minute, 0, 0, now.Location())
	if prev.After(now) {
		prev = prev.Add(-24 * time.Hour)
	}
	return prev, true
}

func parseHHMM(hhmm string) (int, int, bool) {
	parts := strings.Split(hhmm, ":")
	if len(parts) != 2 {
		return 0, 0, false
	}
	hour, err := strconv.Atoi(parts[0])
	if err != nil || hour < 0 || hour > 23 {
		return 0, 0, false
	}
	minute, err := strconv.Atoi(parts[1])
	if err != nil || minute < 0 || minute > 59 {
		return 0, 0, false
	}
	return hour, minute, true
}

func soonest(schedules map[string]*activeSchedule) (time.Time, bool) {
	var best time.Time
	found := false
	for _, s := range schedules {
		if !found || s.nextFire.Before(best) {
			best = s.nextFire
			found = true
		}
	}
	return best, found
}

func statesEqual(a, b State) bool {
	return a.CycleSeq == b.CycleSeq &&
		a.Target == b.Target &&
		a.NextRotation.Equal(b.NextRotation) &&
		reflect.DeepEqual(a.Config, b.Config)
}

func stateFilePath() string {
	base := os.Getenv("XDG_CACHE_HOME")
	if base == "" {
		if home, err := os.UserHomeDir(); err == nil {
			base = filepath.Join(home, ".cache")
		} else {
			base = os.TempDir()
		}
	}
	return filepath.Join(base, "vshell", "wallpaper-schedule.json")
}

func (m *Manager) loadLastFires() map[string]time.Time {
	data, err := os.ReadFile(m.lastFiresP)
	if err != nil {
		return map[string]time.Time{}
	}
	var state persistedState
	if err := json.Unmarshal(data, &state); err != nil || state.LastFires == nil {
		return map[string]time.Time{}
	}
	return state.LastFires
}

func (m *Manager) saveLastFires() {
	if err := os.MkdirAll(filepath.Dir(m.lastFiresP), 0o755); err != nil {
		m.log.Warn("wallpaper: failed to create state dir", "err", err)
		return
	}
	data, err := json.Marshal(persistedState{LastFires: m.lastFires})
	if err != nil {
		m.log.Warn("wallpaper: failed to encode state", "err", err)
		return
	}
	if err := os.WriteFile(m.lastFiresP, data, 0o644); err != nil {
		m.log.Warn("wallpaper: failed to persist schedule state", "err", err)
	}
}

func (m *Manager) String() string {
	return fmt.Sprintf("wallpaper.Manager(%s)", m.lastFiresP)
}
