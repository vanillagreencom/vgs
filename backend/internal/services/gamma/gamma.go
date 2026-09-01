package gamma

import (
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"math"
	"net/http"
	"os/exec"
	"strconv"
	"sync"
	"time"

	"vshell/backend/internal/compositor"
	"vshell/backend/internal/server"
)

type Config struct {
	LowTemp       int      `json:"LowTemp"`
	HighTemp      int      `json:"HighTemp"`
	Latitude      *float64 `json:"Latitude,omitempty"`
	Longitude     *float64 `json:"Longitude,omitempty"`
	UseIPLocation bool     `json:"UseIPLocation"`
	ManualSunrise *string  `json:"ManualSunrise,omitempty"`
	ManualSunset  *string  `json:"ManualSunset,omitempty"`
	Gamma         float64  `json:"Gamma"`
	Enabled       bool     `json:"Enabled"`
}

type State struct {
	Config         Config    `json:"config"`
	CurrentTemp    int       `json:"currentTemp"`
	NextTransition time.Time `json:"nextTransition"`
	SunriseTime    time.Time `json:"sunriseTime"`
	SunsetTime     time.Time `json:"sunsetTime"`
	DawnTime       time.Time `json:"dawnTime"`
	NightTime      time.Time `json:"nightTime"`
	IsDay          bool      `json:"isDay"`
	SunPosition    float64   `json:"sunPosition"`
	// Running distinguishes "enabled in config" from "hyprsunset actually
	// alive", so a crashed hyprsunset is not shown as night-light on.
	Running bool `json:"running"`
}

type Manager struct {
	log     *slog.Logger
	srv     *server.Server
	binary  string
	hyprctl string
	backend string
	client  *http.Client

	mu    sync.RWMutex
	state State
	cmd   *exec.Cmd
	// Last effective wlsunset inputs. Config-only changes such as manual
	// sunrise/sunset must not flash the display by replacing an identical
	// process several times in one settings reapply.
	appliedTemp  int
	appliedGamma float64
	// transitionTimer re-applies the config at NextTransition so the managed
	// hyprsunset actually switches between day and night temperatures.
	transitionTimer *time.Timer
	closed          bool
}

type tempParams struct {
	Temp *float64 `json:"temp"`
	Low  *float64 `json:"low"`
	High *float64 `json:"high"`
}

type locationParams struct {
	Latitude  float64 `json:"latitude"`
	Longitude float64 `json:"longitude"`
}

type manualTimesParams struct {
	Sunrise *string `json:"sunrise"`
	Sunset  *string `json:"sunset"`
}

type useIPParams struct {
	Use bool `json:"use"`
}

type gammaParams struct {
	Gamma float64 `json:"gamma"`
}

type enabledParams struct {
	Enabled bool `json:"enabled"`
}

type ipAPIResponse struct {
	Status  string  `json:"status"`
	Message string  `json:"message"`
	Lat     float64 `json:"lat"`
	Lon     float64 `json:"lon"`
}

func Register(srv *server.Server, log *slog.Logger) (*Manager, error) {
	if log == nil {
		log = slog.Default()
	}
	bin, hyprctlBin, backend, err := gammaCommand()
	if err != nil {
		return nil, err
	}
	m := &Manager{
		log:     log,
		srv:     srv,
		binary:  bin,
		hyprctl: hyprctlBin,
		backend: backend,
		client:  &http.Client{Timeout: 10 * time.Second},
	}
	m.state = m.recalculate(defaultConfig(), time.Now())

	srv.Register("gamma", "wayland.gamma.getState", m.handleGetState)
	srv.Register("gamma", "wayland.gamma.setTemperature", m.handleSetTemperature)
	srv.Register("gamma", "wayland.gamma.setLocation", m.handleSetLocation)
	srv.Register("gamma", "wayland.gamma.setManualTimes", m.handleSetManualTimes)
	srv.Register("gamma", "wayland.gamma.setUseIPLocation", m.handleSetUseIPLocation)
	srv.Register("gamma", "wayland.gamma.setGamma", m.handleSetGamma)
	srv.Register("gamma", "wayland.gamma.setEnabled", m.handleSetEnabled)
	srv.Register("gamma", "wayland.gamma.subscribe", m.handleGetState)
	srv.RegisterSnapshot("gamma", func() any { return m.GetState() })
	return m, nil
}

func (m *Manager) Close() {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.closed = true
	if m.transitionTimer != nil {
		m.transitionTimer.Stop()
		m.transitionTimer = nil
	}
	m.stopLocked()
}

func (m *Manager) GetState() State {
	m.mu.RLock()
	defer m.mu.RUnlock()
	return m.state
}

func (m *Manager) handleGetState(json.RawMessage) (any, error) {
	// SunPosition is time-derived and drifts between transitions; recompute
	// it so a getState is never stale (temperature changes are owned by the
	// transition timer).
	m.mu.Lock()
	m.state.SunPosition = sunPosition(m.state.SunriseTime, m.state.SunsetTime, time.Now())
	state := m.state
	m.mu.Unlock()
	return state, nil
}

func (m *Manager) handleSetTemperature(params json.RawMessage) (any, error) {
	var p tempParams
	if err := json.Unmarshal(params, &p); err != nil {
		return nil, err
	}
	m.mu.Lock()
	cfg := m.state.Config
	switch {
	case p.Temp != nil:
		cfg.LowTemp = int(*p.Temp)
		cfg.HighTemp = int(*p.Temp)
	case p.Low != nil && p.High != nil:
		cfg.LowTemp = int(*p.Low)
		cfg.HighTemp = int(*p.High)
	default:
		m.mu.Unlock()
		return nil, fmt.Errorf("missing temperature parameters")
	}
	if err := validateConfig(cfg); err != nil {
		m.mu.Unlock()
		return nil, err
	}
	next, err := m.applyConfigLocked(cfg)
	m.mu.Unlock()
	if err != nil {
		return nil, err
	}
	m.srv.Broadcast("gamma", next)
	return success("temperature set"), nil
}

func (m *Manager) handleSetLocation(params json.RawMessage) (any, error) {
	var p locationParams
	if err := json.Unmarshal(params, &p); err != nil {
		return nil, err
	}
	if math.Abs(p.Latitude) > 90 || math.Abs(p.Longitude) > 180 {
		return nil, fmt.Errorf("invalid location")
	}
	m.mu.Lock()
	cfg := m.state.Config
	cfg.Latitude = &p.Latitude
	cfg.Longitude = &p.Longitude
	cfg.UseIPLocation = false
	next, err := m.applyConfigLocked(cfg)
	m.mu.Unlock()
	if err != nil {
		return nil, err
	}
	m.srv.Broadcast("gamma", next)
	return success("location set"), nil
}

func (m *Manager) handleSetManualTimes(params json.RawMessage) (any, error) {
	var p manualTimesParams
	if len(params) > 0 {
		if err := json.Unmarshal(params, &p); err != nil {
			return nil, err
		}
	}
	m.mu.Lock()
	cfg := m.state.Config
	if p.Sunrise == nil || p.Sunset == nil || *p.Sunrise == "" || *p.Sunset == "" {
		cfg.ManualSunrise = nil
		cfg.ManualSunset = nil
		next, err := m.applyConfigLocked(cfg)
		m.mu.Unlock()
		if err != nil {
			return nil, err
		}
		m.srv.Broadcast("gamma", next)
		return success("manual times cleared"), nil
	}
	if _, ok := parseHHMM(*p.Sunrise, time.Now()); !ok {
		m.mu.Unlock()
		return nil, fmt.Errorf("invalid sunrise format")
	}
	if _, ok := parseHHMM(*p.Sunset, time.Now()); !ok {
		m.mu.Unlock()
		return nil, fmt.Errorf("invalid sunset format")
	}
	cfg.ManualSunrise = p.Sunrise
	cfg.ManualSunset = p.Sunset
	next, err := m.applyConfigLocked(cfg)
	m.mu.Unlock()
	if err != nil {
		return nil, err
	}
	m.srv.Broadcast("gamma", next)
	return success("manual times set"), nil
}

func (m *Manager) handleSetUseIPLocation(params json.RawMessage) (any, error) {
	var p useIPParams
	if err := json.Unmarshal(params, &p); err != nil {
		return nil, err
	}
	var ipLat, ipLon float64
	var haveIP bool
	if p.Use {
		lat, lon, err := m.fetchIPLocation()
		if err != nil {
			return nil, err
		}
		ipLat, ipLon, haveIP = lat, lon, true
	}
	m.mu.Lock()
	cfg := m.state.Config
	cfg.UseIPLocation = p.Use
	if p.Use && (cfg.Latitude == nil || cfg.Longitude == nil) {
		cfg.Latitude = &ipLat
		cfg.Longitude = &ipLon
	} else if p.Use && haveIP {
		cfg.Latitude = &ipLat
		cfg.Longitude = &ipLon
	}
	next, err := m.applyConfigLocked(cfg)
	m.mu.Unlock()
	if err != nil {
		return nil, err
	}
	m.srv.Broadcast("gamma", next)
	return success("IP location preference set"), nil
}

func (m *Manager) handleSetGamma(params json.RawMessage) (any, error) {
	var p gammaParams
	if err := json.Unmarshal(params, &p); err != nil {
		return nil, err
	}
	m.mu.Lock()
	cfg := m.state.Config
	cfg.Gamma = p.Gamma
	if err := validateConfig(cfg); err != nil {
		m.mu.Unlock()
		return nil, err
	}
	next, err := m.applyConfigLocked(cfg)
	m.mu.Unlock()
	if err != nil {
		return nil, err
	}
	m.srv.Broadcast("gamma", next)
	return success("gamma set"), nil
}

func (m *Manager) handleSetEnabled(params json.RawMessage) (any, error) {
	var p enabledParams
	if err := json.Unmarshal(params, &p); err != nil {
		return nil, err
	}
	m.mu.Lock()
	cfg := m.state.Config
	cfg.Enabled = p.Enabled
	next, err := m.applyConfigLocked(cfg)
	m.mu.Unlock()
	if err != nil {
		return nil, err
	}
	m.srv.Broadcast("gamma", next)
	return success("enabled state set"), nil
}

// applyConfigLocked validates and applies cfg and returns the new state. The
// caller broadcasts it after releasing m.mu — a stalled subscriber write (up
// to the 5s conn deadline) must not block every gamma handler and Close.
func (m *Manager) applyConfigLocked(cfg Config) (State, error) {
	if err := validateConfig(cfg); err != nil {
		return State{}, err
	}
	next := m.recalculate(cfg, time.Now())
	m.state = next
	if err := m.applyGammaLocked(next); err != nil {
		m.state.Running = false
		return State{}, err
	}
	m.state.Running = cfg.Enabled && m.cmd != nil
	m.scheduleTransitionLocked(next)
	return m.state, nil
}

// scheduleTransitionLocked (re)arms the day/night switch: at NextTransition the
// config is re-applied, which recomputes CurrentTemp for the new period,
// restarts hyprsunset at that temperature, and schedules the following
// transition.
func (m *Manager) scheduleTransitionLocked(state State) {
	if m.transitionTimer != nil {
		m.transitionTimer.Stop()
		m.transitionTimer = nil
	}
	if m.closed || !state.Config.Enabled || state.NextTransition.IsZero() {
		return
	}
	delay := time.Until(state.NextTransition)
	if delay < time.Second {
		delay = time.Second // never busy-loop on a boundary
	}
	m.transitionTimer = time.AfterFunc(delay, func() {
		m.mu.Lock()
		if m.closed || !m.state.Config.Enabled {
			m.mu.Unlock()
			return
		}
		next, err := m.applyConfigLocked(m.state.Config)
		m.mu.Unlock()
		if err != nil {
			m.log.Warn("gamma transition re-apply failed", "err", err)
			return
		}
		m.srv.Broadcast("gamma", next)
	})
}

// applyGammaLocked makes the compositor-appropriate gamma process match state.
// The adapter only runs while night mode is enabled, so nothing consumes
// resources when it is off:
//   - off  -> stop the process (release the display back to native).
//   - on, not yet running -> start it once at the target temperature.
//   - Hyprland, already running -> adjust live over the hyprsunset IPC socket.
//   - Niri, already running -> restart wlsunset with its new fixed target.
//
// Hyprland retains its no-flash IPC path unchanged. wlsunset has no live control
// socket, so Niri changes require a short process replacement.
func (m *Manager) applyGammaLocked(state State) error {
	if !state.Config.Enabled {
		m.stopLocked()
		return nil
	}

	if m.backend == "wlsunset" {
		if m.cmd != nil && m.appliedTemp == state.CurrentTemp && m.appliedGamma == state.Config.Gamma {
			return nil
		}
		m.stopLocked()
		// wlsunset rejects equal day/night temperatures. Keep its two targets
		// one kelvin apart so its internal transition is visually fixed at the
		// VGS-computed temperature without delegating our schedule to it.
		lowTemp, highTemp := state.CurrentTemp, state.CurrentTemp+1
		if highTemp > 10000 {
			lowTemp, highTemp = 9999, 10000
		}
		cmd := exec.Command(m.binary,
			"-t", strconv.Itoa(lowTemp),
			"-T", strconv.Itoa(highTemp),
			"-g", strconv.FormatFloat(state.Config.Gamma, 'f', 3, 64),
		)
		if err := cmd.Start(); err != nil {
			return fmt.Errorf("start wlsunset: %w", err)
		}
		m.cmd = cmd
		m.appliedTemp = state.CurrentTemp
		m.appliedGamma = state.Config.Gamma
		go m.watchLocked(cmd)
		return nil
	}

	gammaPercent := int(math.Round(state.Config.Gamma * 100))
	if gammaPercent <= 0 {
		gammaPercent = 100
	}
	if m.cmd == nil {
		cmd := exec.Command(m.binary,
			"--temperature", strconv.Itoa(state.CurrentTemp),
			"--gamma", strconv.Itoa(gammaPercent),
		)
		if err := cmd.Start(); err != nil {
			return fmt.Errorf("start hyprsunset: %w", err)
		}
		m.cmd = cmd
		go m.watchLocked(cmd)
		return nil
	}

	if err := m.hyprsunsetIPC("gamma", strconv.Itoa(gammaPercent)); err != nil {
		return fmt.Errorf("set hyprsunset gamma: %w", err)
	}
	return m.hyprsunsetIPC("temperature", strconv.Itoa(state.CurrentTemp))
}

// watchLocked reports an unexpected gamma-adapter exit so a crashed process is
// not shown as night-light-on. A later apply restarts it.
func (m *Manager) watchLocked(cmd *exec.Cmd) {
	err := cmd.Wait()
	m.mu.Lock()
	// Still the active instance means nobody stopped or replaced it: the process
	// died on its own and gamma is silently no longer applied.
	crashed := m.cmd == cmd
	if crashed {
		m.cmd = nil
		m.state.Running = false
	}
	state := m.state
	m.mu.Unlock()
	if crashed {
		m.log.Warn("gamma adapter exited unexpectedly; gamma no longer applied", "backend", m.backend, "err", err)
		m.srv.Broadcast("gamma", state)
	}
}

func gammaCommand() (binary, hyprctl, backend string, err error) {
	return gammaCommandFor(compositor.Current())
}

func gammaCommandFor(current string) (binary, hyprctl, backend string, err error) {
	if current == "niri" {
		command, lookupErr := exec.LookPath("wlsunset")
		if lookupErr != nil {
			return "", "", "", fmt.Errorf("wlsunset not found")
		}
		return command, "", "wlsunset", nil
	}
	command, lookupErr := exec.LookPath("hyprsunset")
	if lookupErr != nil {
		return "", "", "", fmt.Errorf("hyprsunset not found")
	}
	hyprctlCommand, lookupErr := exec.LookPath("hyprctl")
	if lookupErr != nil {
		return "", "", "", fmt.Errorf("hyprctl not found")
	}
	return command, hyprctlCommand, "hyprsunset", nil
}

func (m *Manager) fetchIPLocation() (float64, float64, error) {
	resp, err := m.client.Get("http://ip-api.com/json/")
	if err != nil {
		return 0, 0, fmt.Errorf("fetch IP location: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return 0, 0, fmt.Errorf("ip-api.com returned status %d", resp.StatusCode)
	}
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return 0, 0, fmt.Errorf("read IP location response: %w", err)
	}
	var data ipAPIResponse
	if err := json.Unmarshal(body, &data); err != nil {
		return 0, 0, fmt.Errorf("decode IP location response: %w", err)
	}
	if data.Status == "fail" || (data.Lat == 0 && data.Lon == 0) {
		if data.Message != "" {
			return 0, 0, fmt.Errorf("IP location unavailable: %s", data.Message)
		}
		return 0, 0, fmt.Errorf("IP location unavailable")
	}
	return data.Lat, data.Lon, nil
}

func (m *Manager) stopLocked() {
	if m.cmd == nil || m.cmd.Process == nil {
		m.cmd = nil
		return
	}
	_ = m.cmd.Process.Kill()
	m.cmd = nil
}

func (m *Manager) recalculate(cfg Config, now time.Time) State {
	sunrise, sunset := scheduleTimes(cfg, now)
	isDay := now.Equal(sunrise) || (now.After(sunrise) && now.Before(sunset))
	temp := cfg.LowTemp
	if isDay {
		temp = cfg.HighTemp
	}
	next := sunset
	if !isDay {
		next = sunrise
		if !next.After(now) {
			next = next.Add(24 * time.Hour)
		}
	}
	if isDay && !next.After(now) {
		next = next.Add(24 * time.Hour)
	}
	return State{
		Config:         cfg,
		CurrentTemp:    temp,
		NextTransition: next,
		SunriseTime:    sunrise,
		SunsetTime:     sunset,
		DawnTime:       sunrise.Add(-30 * time.Minute),
		NightTime:      sunset.Add(30 * time.Minute),
		IsDay:          isDay,
		SunPosition:    sunPosition(sunrise, sunset, now),
	}
}

func scheduleTimes(cfg Config, now time.Time) (time.Time, time.Time) {
	if cfg.ManualSunrise != nil && cfg.ManualSunset != nil {
		sunrise, ok1 := parseHHMM(*cfg.ManualSunrise, now)
		sunset, ok2 := parseHHMM(*cfg.ManualSunset, now)
		if ok1 && ok2 {
			return sunrise, sunset
		}
	}
	if cfg.Latitude != nil && cfg.Longitude != nil {
		return calculateSunTimes(*cfg.Latitude, *cfg.Longitude, now)
	}
	sunrise, _ := parseHHMM("06:00", now)
	sunset, _ := parseHHMM("18:00", now)
	return sunrise, sunset
}

func parseHHMM(hhmm string, now time.Time) (time.Time, bool) {
	t, err := time.Parse("15:04", hhmm)
	if err != nil {
		return time.Time{}, false
	}
	return time.Date(now.Year(), now.Month(), now.Day(), t.Hour(), t.Minute(), 0, 0, now.Location()), true
}

func calculateSunTimes(lat, lon float64, date time.Time) (time.Time, time.Time) {
	zenith := 90.833
	sunrise := calculateSunEvent(lat, lon, date, zenith, true)
	sunset := calculateSunEvent(lat, lon, date, zenith, false)
	if sunrise.IsZero() || sunset.IsZero() {
		fallbackRise, _ := parseHHMM("06:00", date)
		fallbackSet, _ := parseHHMM("18:00", date)
		return fallbackRise, fallbackSet
	}
	return sunrise, sunset
}

func calculateSunEvent(lat, lon float64, date time.Time, zenith float64, rising bool) time.Time {
	n := float64(date.YearDay())
	lngHour := lon / 15.0
	t := n + ((6 - lngHour) / 24)
	if !rising {
		t = n + ((18 - lngHour) / 24)
	}
	mean := (0.9856 * t) - 3.289
	trueLong := mean + (1.916 * math.Sin(deg(mean))) + (0.020 * math.Sin(deg(2*mean))) + 282.634
	trueLong = normalizeDegrees(trueLong)
	rightAsc := rad(math.Atan(0.91764 * math.Tan(deg(trueLong))))
	rightAsc = normalizeDegrees(rightAsc)
	lQuadrant := math.Floor(trueLong/90) * 90
	raQuadrant := math.Floor(rightAsc/90) * 90
	rightAsc = (rightAsc + (lQuadrant - raQuadrant)) / 15
	sinDec := 0.39782 * math.Sin(deg(trueLong))
	cosDec := math.Cos(math.Asin(sinDec))
	cosH := (math.Cos(deg(zenith)) - (sinDec * math.Sin(deg(lat)))) / (cosDec * math.Cos(deg(lat)))
	if cosH > 1 || cosH < -1 {
		return time.Time{}
	}
	var h float64
	if rising {
		h = 360 - rad(math.Acos(cosH))
	} else {
		h = rad(math.Acos(cosH))
	}
	h /= 15
	localMean := h + rightAsc - (0.06571 * t) - 6.622
	utcHours := math.Mod(localMean-lngHour+24, 24)
	hour := int(utcHours)
	minute := int((utcHours - float64(hour)) * 60)
	second := int((((utcHours - float64(hour)) * 60) - float64(minute)) * 60)
	return time.Date(date.Year(), date.Month(), date.Day(), hour, minute, second, 0, time.UTC).In(date.Location())
}

func deg(v float64) float64 {
	return v * math.Pi / 180
}

func rad(v float64) float64 {
	return v * 180 / math.Pi
}

func normalizeDegrees(v float64) float64 {
	for v < 0 {
		v += 360
	}
	for v >= 360 {
		v -= 360
	}
	return v
}

func sunPosition(sunrise, sunset, now time.Time) float64 {
	if !sunset.After(sunrise) {
		return 0
	}
	return math.Max(0, math.Min(1, float64(now.Sub(sunrise))/float64(sunset.Sub(sunrise))))
}

func defaultConfig() Config {
	return Config{
		LowTemp:  4000,
		HighTemp: 6500,
		Gamma:    1.0,
	}
}

func validateConfig(cfg Config) error {
	if cfg.LowTemp < 1000 || cfg.LowTemp > 10000 || cfg.HighTemp < 1000 || cfg.HighTemp > 10000 || cfg.LowTemp > cfg.HighTemp {
		return fmt.Errorf("invalid temperature")
	}
	if cfg.Gamma <= 0 || cfg.Gamma > 2 {
		return fmt.Errorf("invalid gamma")
	}
	if cfg.Latitude != nil && math.Abs(*cfg.Latitude) > 90 {
		return fmt.Errorf("invalid location")
	}
	if cfg.Longitude != nil && math.Abs(*cfg.Longitude) > 180 {
		return fmt.Errorf("invalid location")
	}
	return nil
}

func success(message string) map[string]any {
	return map[string]any{"success": true, "message": message}
}
