package sysupdate

// mise is the user-level tool manager behind coding-agent harnesses and
// language toolchains (docs/architecture/dev-tools.md). It contributes a
// "tools" backend: `mise outdated --json` for the count, and `vshell update
// run tools` for the upgrade.

import (
	"bytes"
	"encoding/json"
	"fmt"
	"sort"
)

// parseMiseOutdated reads `mise outdated --json`: a map of tool name to
// {name, requested, current, latest}. An empty object means up to date.
func parseMiseOutdated(out []byte) ([]Package, error) {
	trimmed := bytes.TrimSpace(out)
	if len(trimmed) == 0 {
		return nil, nil
	}
	var raw map[string]struct {
		Name    string `json:"name"`
		Current string `json:"current"`
		Latest  string `json:"latest"`
	}
	if err := json.Unmarshal(trimmed, &raw); err != nil {
		return nil, fmt.Errorf("invalid JSON: %w", err)
	}
	names := make([]string, 0, len(raw))
	for name := range raw {
		names = append(names, name)
	}
	sort.Strings(names)
	var packages []Package
	for _, name := range names {
		info := raw[name]
		display := info.Name
		if display == "" {
			display = name
		}
		packages = append(packages, Package{Name: display, Repo: "tools", Backend: "mise", FromVersion: info.Current, ToVersion: info.Latest})
	}
	return packages, nil
}
