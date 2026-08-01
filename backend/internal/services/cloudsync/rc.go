package cloudsync

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"
)

// rcClient talks to a running `rclone rcd` over its JSON HTTP control API.
// Every call is a POST with a JSON body; auth is HTTP Basic with per-start
// random credentials (rc access is equivalent to shell access as the user).
type rcClient struct {
	mu      sync.RWMutex
	baseURL string
	user    string
	pass    string
	http    *http.Client
}

func newRCClient() *rcClient {
	return &rcClient{
		http: &http.Client{Timeout: 0}, // per-call deadlines come from ctx
	}
}

func (c *rcClient) setEndpoint(baseURL, user, pass string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.baseURL, c.user, c.pass = baseURL, user, pass
}

func (c *rcClient) clearEndpoint() { c.setEndpoint("", "", "") }

func (c *rcClient) ready() bool {
	c.mu.RLock()
	defer c.mu.RUnlock()
	return c.baseURL != ""
}

// rcError is a structured error from the rc API. The daemon returns a JSON body
// with an "error" field on failure; surfacing it verbatim gives the UI rclone's
// own wording, which is usually the most actionable thing available.
type rcError struct {
	Method string
	Status int
	Msg    string
}

func (e *rcError) Error() string {
	if e.Msg == "" {
		return fmt.Sprintf("rclone %s failed (status %d)", e.Method, e.Status)
	}
	return e.Msg
}

// call POSTs in to the rc endpoint and decodes the response into out (which may
// be nil when the caller only cares about success).
func (c *rcClient) call(ctx context.Context, method string, in any, out any) error {
	c.mu.RLock()
	base, user, pass := c.baseURL, c.user, c.pass
	c.mu.RUnlock()
	if base == "" {
		return fmt.Errorf("rclone control daemon is not running")
	}

	var body []byte
	if in != nil {
		encoded, err := json.Marshal(in)
		if err != nil {
			return fmt.Errorf("encode %s params: %w", method, err)
		}
		body = encoded
	} else {
		body = []byte("{}")
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, base+"/"+method, bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	req.SetBasicAuth(user, pass)

	resp, err := c.http.Do(req)
	if err != nil {
		// *url.Error embeds the loopback control URL and port. That is internal
		// plumbing; it must never reach a user-facing error string.
		if errors.Is(err, context.DeadlineExceeded) {
			return fmt.Errorf("rclone %s timed out", method)
		}
		var urlErr *url.Error
		if errors.As(err, &urlErr) {
			return fmt.Errorf("rclone %s failed: %v", method, urlErr.Err)
		}
		return fmt.Errorf("rclone %s failed: %v", method, err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		var payload struct {
			Error string `json:"error"`
		}
		_ = json.NewDecoder(resp.Body).Decode(&payload)
		return &rcError{Method: method, Status: resp.StatusCode, Msg: strings.TrimSpace(payload.Error)}
	}
	if out == nil {
		return nil
	}
	if err := json.NewDecoder(resp.Body).Decode(out); err != nil {
		return fmt.Errorf("decode %s response: %w", method, err)
	}
	return nil
}

// callTimeout wraps call with a deadline for the many short control calls.
func (c *rcClient) callTimeout(method string, in any, out any, d time.Duration) error {
	return c.callTimeoutCtx(context.Background(), method, in, out, d)
}

// callTimeoutCtx is callTimeout under a caller-supplied parent, so a long probe
// can be abandoned when the service shuts down instead of outliving it.
func (c *rcClient) callTimeoutCtx(parent context.Context, method string, in any, out any, d time.Duration) error {
	if parent == nil {
		parent = context.Background()
	}
	ctx, cancel := context.WithTimeout(parent, d)
	defer cancel()
	return c.call(ctx, method, in, out)
}

// --- Typed response shapes -------------------------------------------------

type rcVersion struct {
	Version string `json:"version"`
	Os      string `json:"os"`
	Arch    string `json:"arch"`
}

type rcTransferring struct {
	Name       string  `json:"name"`
	Size       int64   `json:"size"`
	Bytes      int64   `json:"bytes"`
	Percentage int     `json:"percentage"`
	Speed      float64 `json:"speed"`
	SpeedAvg   float64 `json:"speedAvg"`
	ETA        float64 `json:"eta"`
	Group      string  `json:"group"`
	SrcFs      string  `json:"srcFs"`
	DstFs      string  `json:"dstFs"`
}

type rcStats struct {
	Bytes        int64            `json:"bytes"`
	TotalBytes   int64            `json:"totalBytes"`
	Speed        float64          `json:"speed"`
	ETA          float64          `json:"eta"`
	Errors       int64            `json:"errors"`
	Transfers    int64            `json:"transfers"`
	Checks       int64            `json:"checks"`
	Deletes      int64            `json:"deletes"`
	LastError    string           `json:"lastError"`
	Transferring []rcTransferring `json:"transferring"`
}

type rcTransferred struct {
	Name        string `json:"name"`
	Size        int64  `json:"size"`
	Bytes       int64  `json:"bytes"`
	Checked     bool   `json:"checked"`
	Error       string `json:"error"`
	Group       string `json:"group"`
	SrcFs       string `json:"srcFs"`
	DstFs       string `json:"dstFs"`
	CompletedAt string `json:"completedAt"`
	StartedAt   string `json:"startedAt"`
}

type rcTransferredList struct {
	Transferred []rcTransferred `json:"transferred"`
}

type rcAsyncJob struct {
	JobID int64 `json:"jobid"`
}

type rcJobStatus struct {
	ID       int64   `json:"id"`
	Finished bool    `json:"finished"`
	Success  bool    `json:"success"`
	Error    string  `json:"error"`
	Duration float64 `json:"duration"`
	Group    string  `json:"group"`
}

type rcListRemotes struct {
	Remotes []string `json:"remotes"`
}

type rcAbout struct {
	Total   *int64 `json:"total"`
	Used    *int64 `json:"used"`
	Free    *int64 `json:"free"`
	Trashed *int64 `json:"trashed"`
}

type rcListEntry struct {
	Path     string `json:"Path"`
	Name     string `json:"Name"`
	Size     int64  `json:"Size"`
	MimeType string `json:"MimeType"`
	ModTime  string `json:"ModTime"`
	IsDir    bool   `json:"IsDir"`
}

type rcList struct {
	List []rcListEntry `json:"list"`
}

type rcMountPoint struct {
	Fs         string `json:"Fs"`
	MountPoint string `json:"MountPoint"`
}

type rcMounts struct {
	MountPoints []rcMountPoint `json:"mountPoints"`
}

// rcProviderOption mirrors the option metadata rclone exposes per backend. Only
// the fields a setup form needs are decoded.
type rcProviderOption struct {
	Name       string `json:"Name"`
	Help       string `json:"Help"`
	Default    any    `json:"Default"`
	Required   bool   `json:"Required"`
	IsPassword bool   `json:"IsPassword"`
	Advanced   bool   `json:"Advanced"`
	Hide       int    `json:"Hide"`
	Type       string `json:"Type"`
	Examples   []struct {
		Value string `json:"Value"`
		Help  string `json:"Help"`
	} `json:"Examples"`
}

type rcProvider struct {
	Name        string             `json:"Name"`
	Description string             `json:"Description"`
	Prefix      string             `json:"Prefix"`
	Options     []rcProviderOption `json:"Options"`
}

type rcProviders struct {
	Providers []rcProvider `json:"providers"`
}
