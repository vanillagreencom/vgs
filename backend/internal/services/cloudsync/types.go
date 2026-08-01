// Package cloudsync provides consumer-style cloud file sync on top of rclone.
//
// The service supervises a single `rclone rcd` process and drives it over the
// rclone remote control API. It owns every long-lived concern — the daemon
// lifecycle, configured accounts, sync-folder definitions, schedules, the
// inotify watcher, FUSE mounts, job history and conflict state — so QML stays
// presentation only.
package cloudsync

// Mode is how one synced folder is kept in step with the cloud. There is
// deliberately no default: the add-folder flow makes the user choose, because
// the modes have very different failure characteristics.
type Mode string

const (
	// ModeTwoWay mirrors both directions with rclone bisync. Closest to the
	// Google Drive desktop experience, and the only mode that can produce
	// conflicts.
	ModeTwoWay Mode = "twoway"
	// ModeBackup is one-way local -> cloud.
	ModeBackup Mode = "backup"
	// ModeRestore is one-way cloud -> local.
	ModeRestore Mode = "restore"
	// ModeStream exposes the remote as an on-demand FUSE mount; nothing is
	// stored locally except the VFS cache.
	ModeStream Mode = "stream"
)

// Valid reports whether m is a mode the service knows how to run.
func (m Mode) Valid() bool {
	switch m {
	case ModeTwoWay, ModeBackup, ModeRestore, ModeStream:
		return true
	}
	return false
}

// NeedsResync reports whether the mode requires an explicit first-run baseline
// before it may run unattended.
func (m Mode) NeedsResync() bool { return m == ModeTwoWay }

// Folder states reported to the UI.
const (
	StateIdle        = "idle"
	StateSyncing     = "syncing"
	StatePaused      = "paused"
	StateError       = "error"
	StateNeedsResync = "needsResync"
	StateMounted     = "mounted"
	StateMounting    = "mounting"
	StateUnmounted   = "unmounted"
)

// Folder is a user-configured sync pair. Persisted verbatim in the config file.
type Folder struct {
	ID         string `json:"id"`
	Name       string `json:"name"`
	Remote     string `json:"remote"`
	RemotePath string `json:"remotePath"`
	LocalPath  string `json:"localPath"`
	Mode       Mode   `json:"mode"`

	// IntervalSeconds is the scheduled sync period. 0 means manual only.
	IntervalSeconds int `json:"intervalSeconds"`
	// RealTime enables the inotify watcher for this folder. Off by default:
	// large trees can exhaust the kernel watch limit, and continuous sync has
	// real battery/network cost.
	RealTime bool     `json:"realTime"`
	Paused   bool     `json:"paused"`
	Excludes []string `json:"excludes"`

	// ConflictResolve maps to rclone's --conflict-resolve. Empty or "none"
	// keeps both sides and surfaces the pair in the Conflicts view.
	ConflictResolve string `json:"conflictResolve"`
	// MaxDelete caps deletions for one-way modes (rclone --max-delete, a file
	// count). -1 disables the cap.
	MaxDelete int `json:"maxDelete"`

	// ResyncDone records that a two-way folder has an established baseline.
	// Until it is set the folder reports StateNeedsResync and refuses to run.
	ResyncDone bool `json:"resyncDone"`

	CreatedUnix int64 `json:"createdUnix"`
}

// Transfer is one file currently moving, mapped from rclone core/stats.
type Transfer struct {
	Name       string  `json:"name"`
	FolderID   string  `json:"folderId"`
	FolderName string  `json:"folderName"`
	Direction  string  `json:"direction"`
	Size       int64   `json:"size"`
	Bytes      int64   `json:"bytes"`
	Percentage int     `json:"percentage"`
	Speed      float64 `json:"speed"`
	SpeedAvg   float64 `json:"speedAvg"`
	ETASeconds float64 `json:"etaSeconds"`
}

// RecentFile is a completed transfer, mapped from rclone core/transferred.
type RecentFile struct {
	Name          string `json:"name"`
	FolderID      string `json:"folderId"`
	FolderName    string `json:"folderName"`
	Direction     string `json:"direction"`
	Size          int64  `json:"size"`
	Error         string `json:"error"`
	CompletedUnix int64  `json:"completedUnix"`
}

// FolderStatus is the live runtime state of one folder. Never persisted.
type FolderStatus struct {
	ID              string     `json:"id"`
	State           string     `json:"state"`
	LastSyncUnix    int64      `json:"lastSyncUnix"`
	LastSuccessUnix int64      `json:"lastSuccessUnix"`
	NextSyncUnix    int64      `json:"nextSyncUnix"`
	LastError       string     `json:"lastError"`
	Bytes           int64      `json:"bytes"`
	TotalBytes      int64      `json:"totalBytes"`
	Speed           float64    `json:"speed"`
	ETASeconds      float64    `json:"etaSeconds"`
	Transfers       int64      `json:"transfers"`
	Checks          int64      `json:"checks"`
	Errors          int64      `json:"errors"`
	Transferring    []Transfer `json:"transferring"`
	ConflictCount   int        `json:"conflictCount"`
	Watching        bool       `json:"watching"`
	WatchDegraded   string     `json:"watchDegraded"`
	Mounted         bool       `json:"mounted"`
	MountPoint      string     `json:"mountPoint"`
}

// Quota is remote storage usage from rclone operations/about. Fields are
// pointers because most backends report only a subset.
type Quota struct {
	Total   *int64 `json:"total"`
	Used    *int64 `json:"used"`
	Free    *int64 `json:"free"`
	Trashed *int64 `json:"trashed"`
}

// Account health, reported per account so the UI can show a passive status
// instead of making the user press a "test" button to find out.
const (
	// HealthUnknown means no check has completed yet — the account is new, or
	// the daemon has not finished its first pass.
	HealthUnknown  = "unknown"
	HealthChecking = "checking"
	HealthOK       = "ok"
	// HealthError means the last check failed. Usually an expired token, which
	// Reconnect fixes without losing the folders that point at this account.
	HealthError = "error"
)

// Account is a configured rclone remote presented as a cloud account.
//
// Name is rclone's remote name and is immutable: every Folder references it,
// so renaming it would orphan the user's sync pairs. Label is the display name
// and is ours, stored alongside the folders rather than in rclone's config.
type Account struct {
	Name string `json:"name"`
	Type string `json:"type"`
	// Provider is the human-readable backend name ("Google Drive"), resolved
	// from rclone's provider list. Falls back to Type when unknown.
	Provider string `json:"provider"`
	Label    string `json:"label"`
	User     string `json:"user"`
	// OAuth reports that this account was created by a browser sign-in, which
	// is what makes Reconnect possible.
	OAuth bool `json:"oauth"`
	// ClientID is the user's own API credential when they supplied one. Not a
	// secret (the paired secret is never exposed), but Reconnect needs it to
	// re-run the same sign-in.
	ClientID string `json:"clientId"`

	Quota       *Quota `json:"quota"`
	Health      string `json:"health"`
	CheckedUnix int64  `json:"checkedUnix"`
	Error       string `json:"error"`
	Folders     int    `json:"folders"`
}

// DisplayName is the label if the user set one, else the provider name, else
// the raw remote name. Never empty.
func (a Account) DisplayName() string {
	return firstNonEmpty(a.Label, a.Provider, a.Name)
}

// Provider is one connectable backend, derived from rclone config/providers
// and trimmed to what a setup form needs.
type Provider struct {
	Type        string `json:"type"`
	Name        string `json:"name"`
	Description string `json:"description"`
	OAuth       bool   `json:"oauth"`
	Featured    bool   `json:"featured"`
	// DocsURL points at rclone's own setup page for this backend, for the
	// people who do want to supply their own API credentials.
	DocsURL string           `json:"docsUrl"`
	Options []ProviderOption `json:"options"`
}

// ProviderOption is a single field in a provider's setup form.
type ProviderOption struct {
	Name string `json:"name"`
	// Label is Name made presentable ("client_id" -> "Client ID"); rclone's
	// raw config keys are not consumer-facing copy.
	Label      string   `json:"label"`
	Help       string   `json:"help"`
	Type       string   `json:"type"`
	Default    string   `json:"default"`
	Required   bool     `json:"required"`
	IsPassword bool     `json:"isPassword"`
	Advanced   bool     `json:"advanced"`
	Examples   []string `json:"examples"`
}

// Conflict is a two-way sync collision: bisync kept both versions and the user
// has to pick.
type Conflict struct {
	ID          string `json:"id"`
	FolderID    string `json:"folderId"`
	FolderName  string `json:"folderName"`
	RelPath     string `json:"relPath"`
	LocalPath   string `json:"localPath"`
	CloudPath   string `json:"cloudPath"`
	LocalSize   int64  `json:"localSize"`
	CloudSize   int64  `json:"cloudSize"`
	LocalMtime  int64  `json:"localMtime"`
	CloudMtime  int64  `json:"cloudMtime"`
	DetectedRun int64  `json:"detectedUnix"`
}

// HistoryEntry is one completed sync run.
type HistoryEntry struct {
	ID           string `json:"id"`
	FolderID     string `json:"folderId"`
	FolderName   string `json:"folderName"`
	Mode         Mode   `json:"mode"`
	Trigger      string `json:"trigger"`
	StartedUnix  int64  `json:"startedUnix"`
	FinishedUnix int64  `json:"finishedUnix"`
	Success      bool   `json:"success"`
	Error        string `json:"error"`
	Bytes        int64  `json:"bytes"`
	Transfers    int64  `json:"transfers"`
	Checks       int64  `json:"checks"`
	Errors       int64  `json:"errors"`
}

// Settings holds global preferences. Persisted alongside the folders.
type Settings struct {
	BandwidthUp        string `json:"bandwidthUp"`
	BandwidthDown      string `json:"bandwidthDown"`
	Transfers          int    `json:"transfers"`
	Checkers           int    `json:"checkers"`
	MountRoot          string `json:"mountRoot"`
	TrashRetentionDays int    `json:"trashRetentionDays"`
	NotifyErrors       bool   `json:"notifyErrors"`
	NotifyCompletions  bool   `json:"notifyCompletions"`
	Paused             bool   `json:"paused"`
}

// GlobalStats aggregates every running job for the bar widget.
type GlobalStats struct {
	Speed        float64 `json:"speed"`
	Bytes        int64   `json:"bytes"`
	TotalBytes   int64   `json:"totalBytes"`
	Transfers    int64   `json:"transfers"`
	Errors       int64   `json:"errors"`
	ETASeconds   float64 `json:"etaSeconds"`
	ActiveFolder string  `json:"activeFolder"`
}

// OAuthState reports an in-flight browser authorization.
type OAuthState struct {
	Active  bool   `json:"active"`
	Type    string `json:"type"`
	Name    string `json:"name"`
	AuthURL string `json:"authUrl"`
	Error   string `json:"error"`
	// Reconnect marks a sign-in that repairs an existing account rather than
	// creating one, so the UI can say so instead of implying a new account.
	Reconnect bool `json:"reconnect"`
}

// State is the full snapshot broadcast on the "cloudsync" subscription.
type State struct {
	Available     bool           `json:"available"`
	DaemonRunning bool           `json:"daemonRunning"`
	DaemonError   string         `json:"daemonError"`
	RcloneVersion string         `json:"rcloneVersion"`
	CanMount      bool           `json:"canMount"`
	Paused        bool           `json:"paused"`
	Accounts      []Account      `json:"accounts"`
	Folders       []Folder       `json:"folders"`
	Statuses      []FolderStatus `json:"statuses"`
	Transferring  []Transfer     `json:"transferring"`
	Recent        []RecentFile   `json:"recent"`
	Conflicts     []Conflict     `json:"conflicts"`
	History       []HistoryEntry `json:"history"`
	Warnings      []string       `json:"warnings"`
	Global        GlobalStats    `json:"global"`
	Settings      Settings       `json:"settings"`
	OAuth         OAuthState     `json:"oauth"`
}

// defaultSettings are applied on first run and used to fill zero values from an
// older config file.
func defaultSettings() Settings {
	return Settings{
		Transfers:          4,
		Checkers:           8,
		TrashRetentionDays: 30,
		NotifyErrors:       true,
		NotifyCompletions:  false,
	}
}
