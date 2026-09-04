package cloudsync

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"regexp"
	"sort"
	"strings"
	"sync"
	"syscall"
	"time"
)

// oauthTimeout gives the user time to complete a browser consent flow before we
// give up and release the local callback port.
const oauthTimeout = 5 * time.Minute

// aboutTimeout allows for a token exchange during the quota request.
const aboutTimeout = 60 * time.Second

// featuredProviders appear first in the picker. Other supported providers remain
// available in the full list.
var featuredProviders = map[string]bool{
	"drive":       true,
	"dropbox":     true,
	"onedrive":    true,
	"box":         true,
	"pcloud":      true,
	"mega":        true,
	"iclouddrive": true,
	"protondrive": true,
	"jottacloud":  true,
	"koofr":       true,
	"webdav":      true,
	"s3":          true,
	"b2":          true,
	"sftp":        true,
}

// hiddenProviders are wrappers and pseudo-backends that are meaningless as a
// "cloud account": they compose or transform other remotes rather than being
// somewhere your files live.
var hiddenProviders = map[string]bool{
	"local":    true,
	"memory":   true,
	"alias":    true,
	"union":    true,
	"chunker":  true,
	"crypt":    true,
	"cache":    true,
	"combine":  true,
	"compress": true,
	"http":     true,
}

var (
	remoteNamePattern = regexp.MustCompile(`^[A-Za-z0-9_.\-]{1,40}$`)
	authURLPattern    = regexp.MustCompile(`https?://[^\s"']+`)
)

func (m *Manager) listProviders() ([]Provider, error) {
	var raw rcProviders
	if err := m.client.callTimeout("config/providers", nil, &raw, 15*time.Second); err != nil {
		return nil, err
	}

	out := make([]Provider, 0, len(raw.Providers))
	for _, p := range raw.Providers {
		if hiddenProviders[p.Name] {
			continue
		}
		provider := Provider{
			Type:        p.Name,
			Name:        shortProviderName(p.Name, p.Description),
			Description: p.Description,
			Featured:    featuredProviders[p.Name],
			DocsURL:     "https://rclone.org/" + p.Name + "/",
			Options:     make([]ProviderOption, 0, len(p.Options)),
		}
		for _, opt := range p.Options {
			if opt.Name == "token" {
				// The presence of an OAuth token field is what distinguishes a
				// "sign in with your browser" backend from a credentials form.
				provider.OAuth = true
			}
			if opt.Hide != 0 || isInternalOption(opt.Name) {
				continue
			}
			examples := make([]string, 0, len(opt.Examples))
			for _, ex := range opt.Examples {
				examples = append(examples, ex.Value)
			}
			provider.Options = append(provider.Options, ProviderOption{
				Name:       opt.Name,
				Label:      humanizeOptionName(opt.Name),
				Help:       firstLine(opt.Help),
				Type:       opt.Type,
				Default:    stringifyDefault(opt.Default),
				Required:   opt.Required,
				IsPassword: opt.IsPassword,
				Advanced:   opt.Advanced,
				Examples:   examples,
			})
		}
		out = append(out, provider)
	}

	sort.Slice(out, func(i, j int) bool {
		if out[i].Featured != out[j].Featured {
			return out[i].Featured
		}
		return strings.ToLower(out[i].Name) < strings.ToLower(out[j].Name)
	})
	return out, nil
}

// shortProviderName removes vendor enumerations so provider descriptions fit the
// picker.
func shortProviderName(name, description string) string {
	label := strings.TrimSpace(description)
	if label == "" {
		return name
	}
	for _, sep := range []string{" including ", " (this is not ", ", including "} {
		if idx := strings.Index(label, sep); idx > 0 {
			label = label[:idx]
		}
	}
	label = strings.TrimRight(strings.TrimSpace(label), ",")
	if len(label) > 48 {
		label = strings.TrimSpace(label[:47]) + "…"
	}
	if label == "" {
		return name
	}
	return label
}

var optionAcronyms = map[string]string{
	"id": "ID", "url": "URL", "api": "API", "oauth": "OAuth", "aws": "AWS",
	"sso": "SSO", "acl": "ACL", "iam": "IAM", "sse": "SSE", "kms": "KMS",
	"tls": "TLS", "ssl": "SSL", "ip": "IP", "dns": "DNS", "uid": "UID",
	"gid": "GID", "sha1": "SHA1", "md5": "MD5", "http": "HTTP", "ftp": "FTP",
	"cdn": "CDN", "vfs": "VFS", "os": "OS", "jwt": "JWT",
}

// humanizeOptionName turns an rclone config key into a form label:
// "client_id" -> "Client ID". rclone's keys are CLI identifiers, not copy.
func humanizeOptionName(name string) string {
	parts := strings.Split(strings.TrimSpace(name), "_")
	out := make([]string, 0, len(parts))
	for _, part := range parts {
		if part == "" {
			continue
		}
		if acronym, ok := optionAcronyms[strings.ToLower(part)]; ok {
			out = append(out, acronym)
			continue
		}
		out = append(out, strings.ToUpper(part[:1])+part[1:])
	}
	if len(out) == 0 {
		return name
	}
	return strings.Join(out, " ")
}

// isInternalOption filters fields the user should never have to fill in: OAuth
// plumbing we manage ourselves.
func isInternalOption(name string) bool {
	switch name {
	case "token", "auth_url", "token_url":
		return true
	}
	return false
}

func stringifyDefault(value any) string {
	switch v := value.(type) {
	case nil:
		return ""
	case string:
		return v
	case bool:
		if v {
			return "true"
		}
		return "false"
	case float64:
		if v == float64(int64(v)) {
			return fmt.Sprintf("%d", int64(v))
		}
		return fmt.Sprintf("%g", v)
	default:
		return fmt.Sprintf("%v", v)
	}
}

// providerDetails caches provider names and sign-in metadata. The provider table
// is fetched once per daemon instance.
type providerDetails struct {
	name  string
	oauth bool
}

// providerDetailsFor returns the provider label and browser-sign-in support.
// Unknown providers use their raw type as a label.
func (m *Manager) providerDetailsFor(providerType string) providerDetails {
	if providerType == "" {
		return providerDetails{}
	}
	m.mu.Lock()
	cached, ok := m.providers[providerType]
	loaded := m.providersLoaded
	m.mu.Unlock()
	if ok {
		return cached
	}
	if loaded {
		return providerDetails{name: providerType}
	}

	// Serialize provider-table loading so concurrent account lookups share the same
	// control call.
	m.providersOnce.Lock()
	defer m.providersOnce.Unlock()

	m.mu.Lock()
	cached, ok = m.providers[providerType]
	loaded = m.providersLoaded
	m.mu.Unlock()
	if ok {
		return cached
	}
	if loaded {
		return providerDetails{name: providerType}
	}

	list, err := m.listProviders()
	if err != nil {
		// Deliberately not marking the table loaded: caching a failure would
		// leave every account without a provider name until the next restart.
		m.log.Debug("cloudsync could not list providers", "err", err)
		return providerDetails{name: providerType}
	}
	table := make(map[string]providerDetails, len(list))
	for _, p := range list {
		table[p.Type] = providerDetails{name: p.Name, oauth: p.OAuth}
	}
	m.mu.Lock()
	m.providers = table
	m.providersLoaded = true
	m.mu.Unlock()

	if details, ok := table[providerType]; ok {
		return details
	}
	return providerDetails{name: providerType}
}

// refreshAccounts rebuilds the account list from rclone's config. Identity is
// resolved synchronously (it is only config reads); reachability and quota are
// filled in afterwards so the list appears immediately.
func (m *Manager) refreshAccounts() {
	if !m.client.ready() {
		return
	}
	var remotes rcListRemotes
	if err := m.client.callTimeout("config/listremotes", nil, &remotes, 10*time.Second); err != nil {
		// Retain cached accounts on a failed refresh and report the error to the
		// caller.
		m.log.Warn("cloudsync could not list remotes; the account list may be stale", "err", err)
		return
	}
	sort.Strings(remotes.Remotes)

	folderCounts := map[string]int{}
	for _, folder := range m.store.snapshotFolders() {
		folderCounts[folder.Remote]++
	}

	accounts := make([]Account, 0, len(remotes.Remotes))
	// Accounts whose config could not be read this pass: their identity is
	// restored from the previous list rather than published as blank.
	unresolved := map[string]bool{}
	live := map[string]bool{}
	for _, name := range remotes.Remotes {
		name = strings.TrimSuffix(name, ":")
		live[name] = true
		account := Account{
			Name:    name,
			Folders: folderCounts[name],
			Health:  HealthUnknown,
			Label:   strings.TrimSpace(m.store.accountMeta(name).Label),
		}

		var cfg map[string]string
		if err := m.client.callTimeout("config/get", map[string]any{"name": name}, &cfg, 10*time.Second); err == nil {
			account.Type = cfg["type"]
			account.User = firstNonEmpty(cfg["user"], cfg["username"], cfg["account"], cfg["email"])
			account.ClientID = cfg["client_id"]
			// A stored token is the durable marker of a browser sign-in: it is
			// what Reconnect replaces.
			if strings.TrimSpace(cfg["token"]) != "" {
				account.OAuth = true
			}
		} else {
			// Identity is kept rather than blanked. A timed-out config/get
			// would otherwise leave a nameless, icon-less account that
			// Reconnect refuses ("provider is unknown") — with no repair path
			// visible — until some later refresh happens to succeed.
			m.log.Warn("cloudsync could not read account config", "account", name, "err", err)
			unresolved[name] = true
		}
		if hiddenProviders[account.Type] {
			continue
		}
		details := m.providerDetailsFor(account.Type)
		account.Provider = firstNonEmpty(details.name, account.Type)
		account.OAuth = account.OAuth || details.oauth

		accounts = append(accounts, account)
	}

	// Health and quota already known are carried over so a refresh does not
	// blank the status chips and storage bars mid-session. The carry-over is
	// read in the same critical section as the swap: reading it before the
	// config round trips above would discard any check that completed while
	// they were in flight.
	m.mu.Lock()
	previous := make(map[string]Account, len(m.accounts))
	for _, account := range m.accounts {
		previous[account.Name] = account
	}
	carryOverAccounts(accounts, previous, unresolved)
	m.accounts = accounts
	m.mu.Unlock()

	// Labels are keyed by remote name, and remotes can be deleted with the
	// rclone CLI — a supported path, since accounts live in rclone's own
	// config. Without pruning, a later account reusing that name would
	// silently inherit a stranger's label.
	if err := m.store.pruneAccountMeta(live); err != nil {
		m.log.Warn("cloudsync could not prune account labels", "err", err)
	}
	m.broadcastNow()

	// Reachability and quota are network calls that can be slow (a cold Drive
	// token exchange plus an about call), and plenty of backends do not
	// implement about at all. They are refreshed after the accounts are
	// already visible, in parallel; a quota failure only means "no storage
	// bar" and never marks the account unhealthy.
	go m.refreshAccountDetails(m.accountNames())
}

// carryOverAccounts retains health, quota, and unreadable account identities
// from the outgoing list. It does not retain transient checking state or state
// from a different provider type.
func carryOverAccounts(fresh []Account, previous map[string]Account, unresolved map[string]bool) {
	for i := range fresh {
		prior, ok := previous[fresh[i].Name]
		if !ok {
			continue
		}
		if unresolved[fresh[i].Name] {
			fresh[i].Type = prior.Type
			fresh[i].Provider = prior.Provider
			fresh[i].User = prior.User
			fresh[i].ClientID = prior.ClientID
			fresh[i].OAuth = prior.OAuth
		}
		// A type change means the remote was replaced under the same name, so
		// nothing recorded about the old one still describes it.
		if prior.Type != fresh[i].Type {
			continue
		}
		fresh[i].Quota = prior.Quota
		fresh[i].CheckedUnix = prior.CheckedUnix
		fresh[i].Error = prior.Error
		// "checking" belongs to a check that has since finished or been
		// abandoned; carrying it forward pins the chip on a spinner that never
		// resolves.
		if prior.Health != HealthChecking {
			fresh[i].Health = prior.Health
		}
	}
}

// refreshAccountDetails checks every named account's reachability and storage
// usage without blocking the account list.
//
// It takes names rather than accounts deliberately: an []Account handed over
// here shares its backing array with m.accounts, which setAccountHealth writes
// into under the lock — so iterating it off-lock is a data race.
func (m *Manager) refreshAccountDetails(names []string) {
	// Check closed and add the task under the same lock that Close uses. Adding
	// after shutdown starts waiting can violate WaitGroup ordering.
	m.mu.Lock()
	if m.closed {
		m.mu.Unlock()
		return
	}
	m.tasks.Add(1)
	m.mu.Unlock()
	defer m.tasks.Done()

	var wg sync.WaitGroup
	for _, name := range names {
		wg.Add(1)
		go func(name string) {
			defer wg.Done()
			m.checkAccount(name)
		}(name)
	}
	wg.Wait()
	m.broadcastNow()
}

func (m *Manager) accountNames() []string {
	m.mu.Lock()
	defer m.mu.Unlock()
	names := make([]string, 0, len(m.accounts))
	for _, account := range m.accounts {
		names = append(names, account.Name)
	}
	return names
}

// checkAccount refreshes account health and quota. It probes operations/about
// first because listing a large root can exceed the timeout. Providers without
// about support use a root listing.
func (m *Manager) checkAccount(name string) error {
	if err := validateRemoteName(name); err != nil {
		return err
	}
	m.setAccountHealth(name, HealthChecking, "", false)
	m.broadcastNow()

	var about rcAbout
	err := m.client.callTimeoutCtx(m.shutdown, "operations/about", map[string]any{"fs": name + ":"}, &about, aboutTimeout)
	if err == nil {
		quota := &Quota{Total: about.Total, Used: about.Used, Free: about.Free, Trashed: about.Trashed}
		m.mu.Lock()
		for i := range m.accounts {
			if m.accounts[i].Name == name {
				m.accounts[i].Quota = quota
			}
		}
		m.mu.Unlock()
		m.setAccountHealth(name, HealthOK, "", true)
		m.broadcastNow()
		return nil
	}
	m.log.Debug("cloudsync quota unavailable", "account", name, "err", err)

	if listErr := m.testRemoteCtx(m.shutdown, name); listErr != nil {
		m.setAccountHealth(name, HealthError, firstLine(listErr.Error()), true)
		m.broadcastNow()
		return listErr
	}
	m.setAccountHealth(name, HealthOK, "", true)
	m.broadcastNow()
	return nil
}

// setAccountHealth updates one account's status. stamp is false for the
// transient "checking" state, which must not move the last-checked time.
func (m *Manager) setAccountHealth(name, health, message string, stamp bool) {
	m.mu.Lock()
	defer m.mu.Unlock()
	for i := range m.accounts {
		if m.accounts[i].Name != name {
			continue
		}
		m.accounts[i].Health = health
		m.accounts[i].Error = message
		if stamp {
			m.accounts[i].CheckedUnix = time.Now().Unix()
		}
		return
	}
}

// scheduleAccountCheck refreshes health and quota because tokens and storage use
// can change without a user request.
func (m *Manager) scheduleAccountCheck() {
	m.mu.Lock()
	if m.closed {
		m.mu.Unlock()
		return
	}
	if m.accountTimer != nil {
		m.accountTimer.Stop()
	}
	m.accountTimer = time.AfterFunc(accountCheckInterval, func() {
		if m.client.ready() {
			m.refreshAccountDetails(m.accountNames())
		}
		m.scheduleAccountCheck()
	})
	m.mu.Unlock()
}

// setAccountLabel renames an account for display only. The rclone remote name
// is left alone because every folder references it.
func (m *Manager) setAccountLabel(name, label string) error {
	if err := validateRemoteName(name); err != nil {
		return err
	}
	if !m.accountExists(name) {
		return fmt.Errorf("no such account")
	}
	// Control characters are stripped, not just trimmed: the label is persisted
	// and broadcast, and an escape sequence in it would be interpreted by any
	// consumer that prints state to a terminal (`vshell-backend request`).
	label = strings.Map(func(r rune) rune {
		if r == '\t' || r == '\n' || r == '\r' {
			return ' '
		}
		if r < 0x20 || r == 0x7f {
			return -1
		}
		return r
	}, label)
	label = strings.TrimSpace(label)
	if len([]rune(label)) > 60 {
		return fmt.Errorf("that name is too long")
	}
	if err := m.store.putAccountMeta(name, AccountMeta{Label: label}); err != nil {
		return err
	}
	m.mu.Lock()
	for i := range m.accounts {
		if m.accounts[i].Name == name {
			m.accounts[i].Label = label
		}
	}
	m.mu.Unlock()
	m.broadcastNow()
	return nil
}

func (m *Manager) accountExists(name string) bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	for _, account := range m.accounts {
		if account.Name == name {
			return true
		}
	}
	return false
}

func (m *Manager) addRemote(name, providerType string, parameters map[string]string) error {
	if err := validateRemoteName(name); err != nil {
		return err
	}
	if strings.TrimSpace(providerType) == "" {
		return fmt.Errorf("choose a provider")
	}
	if err := m.ensureRemoteFree(name); err != nil {
		return err
	}

	params := map[string]any{}
	for k, v := range parameters {
		params[k] = v
	}
	// obscure lets the user type a plain password: rclone encodes it before it
	// reaches the config file.
	body := map[string]any{
		"name":       name,
		"type":       providerType,
		"parameters": params,
		"opt":        map[string]any{"obscure": true, "nonInteractive": true},
	}
	if err := m.client.callTimeout("config/create", body, nil, 60*time.Second); err != nil {
		return err
	}
	m.refreshAccounts()
	m.broadcastNow()
	return nil
}

// removeRemote requires explicit acknowledgement when folders depend on the
// account. It deletes the remote first, then tears down those folders without
// deleting their local files.
func (m *Manager) removeRemote(name string, removeFolders bool) error {
	if err := validateRemoteName(name); err != nil {
		return err
	}
	affected := m.store.foldersForRemote(name)
	if len(affected) > 0 && !removeFolders {
		return fmt.Errorf("%d synced folder(s) still use this account", len(affected))
	}
	// Delete the remote before tearing down folders. A failed remote deletion must
	// preserve sync configuration and two-way baselines. Folder teardown failures
	// are reported separately.
	if err := m.client.callTimeout("config/delete", map[string]any{"name": name}, nil, 20*time.Second); err != nil {
		return err
	}
	var failed []string
	for _, folder := range affected {
		if err := m.removeFolderByID(folder.ID); err != nil {
			m.log.Warn("cloudsync could not remove folder for disconnected account", "folder", folder.ID, "err", err)
			failed = append(failed, folder.displayName())
		}
	}
	if err := m.store.deleteAccountMeta(name); err != nil {
		m.log.Warn("cloudsync could not clear account label", "account", name, "err", err)
	}
	m.refreshAccounts()
	m.broadcastNow()
	// The account is gone either way, so this is reported rather than returned
	// as a plain failure: a folder left behind would fail every run forever
	// with nothing having told the user.
	if len(failed) > 0 {
		return fmt.Errorf("account disconnected, but these folders could not be removed: %s", strings.Join(failed, ", "))
	}
	return nil
}

// reconnectRemote replaces an account token through browser sign-in while
// preserving the remote name used by configured folders.
func (m *Manager) reconnectRemote(name string, parameters map[string]string) error {
	if err := validateRemoteName(name); err != nil {
		return err
	}
	// Copied, not pointed at: refreshAccounts replaces the whole slice, so a
	// pointer into it read after the unlock is both a race and potentially a
	// read of a superseded account.
	var account Account
	found := false
	m.mu.Lock()
	for _, candidate := range m.accounts {
		if candidate.Name == name {
			account, found = candidate, true
			break
		}
	}
	m.mu.Unlock()

	if !found {
		return fmt.Errorf("no such account")
	}
	if account.Type == "" {
		return fmt.Errorf("this account's provider is unknown")
	}
	if !account.OAuth && !m.providerDetailsFor(account.Type).oauth {
		return fmt.Errorf("this account does not sign in through a browser")
	}
	// Restrict reconnect updates to credential fields so a supplied type cannot
	// redirect dependent folders. Keep client ID and secret together because rclone
	// authorize uses them as a pair.
	allowed := map[string]string{}
	if id, secret := strings.TrimSpace(parameters["client_id"]), strings.TrimSpace(parameters["client_secret"]); id != "" && secret != "" {
		allowed["client_id"] = id
		allowed["client_secret"] = secret
	}
	return m.beginOAuth(name, account.Type, allowed, true)
}

// testRemote lists the remote root as a fallback when operations/about is
// unavailable. Large roots can exceed the probe timeout.
func (m *Manager) testRemote(name string) error {
	return m.testRemoteCtx(context.Background(), name)
}

func (m *Manager) testRemoteCtx(ctx context.Context, name string) error {
	if err := validateRemoteName(name); err != nil {
		return err
	}
	var list rcList
	return m.client.callTimeoutCtx(ctx, "operations/list",
		map[string]any{"fs": name + ":", "remote": "", "opt": map[string]any{"dirsOnly": true}},
		&list, aboutTimeout)
}

func (m *Manager) browse(remote, path string) ([]rcListEntry, error) {
	if err := validateRemoteName(remote); err != nil {
		return nil, err
	}
	// Reject parent traversal before browsing. rclone remotes can refer to local
	// storage, where traversal can escape the selected root.
	for _, segment := range strings.Split(strings.Trim(strings.TrimSpace(path), "/"), "/") {
		if segment == ".." {
			return nil, fmt.Errorf("that path is not valid")
		}
	}
	var list rcList
	err := m.client.callTimeout("operations/list",
		map[string]any{
			"fs":     remote + ":",
			"remote": strings.Trim(strings.TrimSpace(path), "/"),
			"opt":    map[string]any{"dirsOnly": true},
		},
		&list, 45*time.Second)
	if err != nil {
		return nil, err
	}
	sort.Slice(list.List, func(i, j int) bool {
		return strings.ToLower(list.List[i].Name) < strings.ToLower(list.List[j].Name)
	})
	return list.List, nil
}

func (m *Manager) ensureRemoteFree(name string) error {
	var remotes rcListRemotes
	if err := m.client.callTimeout("config/listremotes", nil, &remotes, 10*time.Second); err != nil {
		return err
	}
	for _, existing := range remotes.Remotes {
		if strings.EqualFold(strings.TrimSuffix(existing, ":"), name) {
			return fmt.Errorf("an account named %q already exists", name)
		}
	}
	return nil
}

func validateRemoteName(name string) error {
	if !remoteNamePattern.MatchString(name) {
		return fmt.Errorf("account names may only contain letters, numbers, dots, dashes and underscores")
	}
	return nil
}

type oauthSession struct {
	cmd    *exec.Cmd
	timer  *time.Timer
	once   sync.Once
	name   string
	kind   string
	params map[string]string
	// reconnect distinguishes repairing an existing account from creating one.
	// It decides whether the finished token is written with config/update
	// (preserving every other setting) or config/create.
	reconnect bool
	// scanners waits for stdout and stderr readers before the child is reaped.
	scanners sync.WaitGroup
}

func (m *Manager) startOAuth(name, providerType string, parameters map[string]string) error {
	if err := validateRemoteName(name); err != nil {
		return err
	}
	if strings.TrimSpace(providerType) == "" {
		return fmt.Errorf("choose a provider")
	}
	if err := m.ensureRemoteFree(name); err != nil {
		return err
	}
	return m.beginOAuth(name, providerType, parameters, false)
}

// beginOAuth runs the browser sign-in. rclone's `authorize` subcommand runs the
// whole OAuth dance against a loopback callback and prints the resulting token,
// which we then write into the config. The consent URL is published in state so
// the shell can open it (and show it for copy/paste if the browser does not).
func (m *Manager) beginOAuth(name, providerType string, parameters map[string]string, reconnect bool) error {
	m.mu.Lock()
	if m.oauth.Active {
		m.mu.Unlock()
		return fmt.Errorf("another sign-in is already in progress")
	}
	m.oauth = OAuthState{Active: true, Type: providerType, Name: name, Reconnect: reconnect}
	m.mu.Unlock()
	m.broadcastNow()

	// Pass API credentials through the environment because command arguments can be
	// visible to other local users. Use backend-specific option names for rclone
	// authorize.
	cmd := exec.Command(m.binary, "authorize", providerType, "--auth-no-open-browser")
	cmd.Env = os.Environ()
	clientID := strings.TrimSpace(parameters["client_id"])
	clientSecret := strings.TrimSpace(parameters["client_secret"])
	if clientID != "" && clientSecret != "" {
		prefix := backendEnvPrefix(providerType)
		cmd.Env = append(cmd.Env,
			prefix+"CLIENT_ID="+clientID,
			prefix+"CLIENT_SECRET="+clientSecret,
		)
	}
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		m.failOAuth(err.Error())
		return err
	}
	stderr, err := cmd.StderrPipe()
	if err != nil {
		m.failOAuth(err.Error())
		return err
	}
	if err := cmd.Start(); err != nil {
		m.failOAuth(fmt.Sprintf("could not start sign-in: %v", err))
		return err
	}

	session := &oauthSession{cmd: cmd, name: name, kind: providerType, params: parameters, reconnect: reconnect}
	// A timeout must publish an error. User cancellation clears the sign-in state
	// without one.
	session.timer = time.AfterFunc(oauthTimeout, func() {
		m.abortOAuth(session, "sign-in timed out after 5 minutes; try again")
	})
	m.mu.Lock()
	m.oauthSession = session
	m.mu.Unlock()

	tokens := make(chan string, 1)
	session.scanners.Add(2)
	go m.scanAuthorizeOutput(session, stdout, tokens)
	go m.scanAuthorizeOutput(session, stderr, tokens)
	go m.awaitOAuth(session, tokens)
	return nil
}

// scanAuthorizeOutput watches one of the child's streams for the consent URL
// and for the token blob. rclone splits these across stdout and stderr
// depending on version, so both streams are scanned the same way.
func (m *Manager) scanAuthorizeOutput(session *oauthSession, r io.Reader, tokens chan<- string) {
	defer session.scanners.Done()
	scanner := bufio.NewScanner(r)
	scanner.Buffer(make([]byte, 0, 64*1024), 1<<20)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" {
			continue
		}
		if strings.HasPrefix(line, "{") && strings.Contains(line, "access_token") {
			select {
			case tokens <- line:
			default:
			}
			continue
		}
		if url := authURLPattern.FindString(line); url != "" && strings.Contains(url, "127.0.0.1") {
			// Guarded on session identity, not on oauth.Active: a killed
			// session's buffered output can flush after a new sign-in has
			// started, and would otherwise publish the dead consent URL over
			// the live one.
			m.mu.Lock()
			if m.oauthSession == session {
				m.oauth.AuthURL = url
			}
			current := m.oauthSession == session
			m.mu.Unlock()
			if current {
				m.broadcastNow()
			}
		}
	}
}

// awaitOAuth collects the token and writes the account only while this sign-in
// session is current.
func (m *Manager) awaitOAuth(session *oauthSession, tokens <-chan string) {
	// Drain both streams before Wait closes their read ends. rclone authorize can
	// print the token immediately before exit; waiting first can discard it.
	session.scanners.Wait()
	waitErr := session.cmd.Wait()

	var token string
	select {
	case token = <-tokens:
	default:
	}

	session.timer.Stop()

	// Every terminal write below is guarded on session identity: a cancelled
	// or timed-out session whose child is still exiting must never overwrite
	// the state of the sign-in that replaced it.
	m.mu.Lock()
	current := m.oauthSession == session
	m.mu.Unlock()
	if !current {
		return
	}

	if token == "" {
		msg := "sign-in did not complete"
		if waitErr != nil {
			msg = "sign-in did not complete: " + firstLine(waitErr.Error())
		}
		m.abortOAuth(session, msg)
		return
	}

	params := map[string]any{"token": token}
	for k, v := range session.params {
		if strings.TrimSpace(v) == "" {
			continue
		}
		params[k] = v
	}
	body := map[string]any{
		"name":       session.name,
		"parameters": params,
		"opt":        map[string]any{"nonInteractive": true, "obscure": true},
	}
	// config/update merges into the existing section; config/create would
	// replace it and lose settings the account was set up with.
	method := "config/create"
	if session.reconnect {
		method = "config/update"
	} else {
		body["type"] = session.kind
	}
	if err := m.client.callTimeout(method, body, nil, 60*time.Second); err != nil {
		m.abortOAuth(session, firstLine(err.Error()))
		return
	}

	if !m.finishOAuth(session, OAuthState{}) {
		return
	}
	m.refreshAccounts()
	m.broadcastNow()
}

// finishOAuth publishes a terminal state for one session, and only while that
// session is still the current one. Reports whether the write happened.
func (m *Manager) finishOAuth(session *oauthSession, state OAuthState) bool {
	m.mu.Lock()
	if m.oauthSession != session {
		m.mu.Unlock()
		return false
	}
	m.oauthSession = nil
	m.oauth = state
	m.mu.Unlock()
	m.broadcastNow()
	return true
}

func (m *Manager) abortOAuth(session *oauthSession, message string) {
	if !m.finishOAuth(session, OAuthState{Error: firstLine(message)}) {
		return
	}
	session.kill()
}

// cancelOAuth aborts an in-flight sign-in and releases rclone's callback port.
func (m *Manager) cancelOAuth() {
	m.mu.Lock()
	session := m.oauthSession
	m.oauthSession = nil
	m.oauth = OAuthState{}
	m.mu.Unlock()

	if session != nil {
		session.kill()
	}
	m.broadcastNow()
}

// kill stops the sign-in child and its process group. rclone spawns with
// Setpgid, so killing only the PID can leave the group holding the loopback
// callback port — which then blocks the next sign-in.
func (s *oauthSession) kill() {
	if s == nil {
		return
	}
	if s.timer != nil {
		s.timer.Stop()
	}
	s.once.Do(func() {
		if s.cmd.Process == nil {
			return
		}
		if pgid, err := syscall.Getpgid(s.cmd.Process.Pid); err == nil {
			_ = syscall.Kill(-pgid, syscall.SIGKILL)
			return
		}
		_ = s.cmd.Process.Kill()
	})
}

func (m *Manager) failOAuth(message string) {
	m.mu.Lock()
	m.oauth = OAuthState{Error: firstLine(message)}
	m.oauthSession = nil
	m.mu.Unlock()
	m.broadcastNow()
}

// backendEnvPrefix selects rclone authorize credential options such as
// RCLONE_DRIVE_CLIENT_ID. The generic RCLONE_CLIENT_ID does not select the same
// credentials, which can leave the token mismatched with the saved account.
func backendEnvPrefix(providerType string) string {
	var b strings.Builder
	b.WriteString("RCLONE_")
	for _, r := range strings.ToUpper(strings.TrimSpace(providerType)) {
		if (r >= 'A' && r <= 'Z') || (r >= '0' && r <= '9') {
			b.WriteRune(r)
			continue
		}
		b.WriteRune('_')
	}
	b.WriteString("_")
	return b.String()
}

func firstNonEmpty(values ...string) string {
	for _, v := range values {
		if strings.TrimSpace(v) != "" {
			return v
		}
	}
	return ""
}

func decodeStringMap(raw json.RawMessage) map[string]string {
	out := map[string]string{}
	if len(raw) == 0 {
		return out
	}
	var generic map[string]any
	if err := json.Unmarshal(raw, &generic); err != nil {
		return out
	}
	for k, v := range generic {
		switch value := v.(type) {
		case string:
			out[k] = value
		case bool:
			if value {
				out[k] = "true"
			} else {
				out[k] = "false"
			}
		case float64:
			out[k] = stringifyDefault(value)
		}
	}
	return out
}
