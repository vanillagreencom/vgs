package sysupdate

// mise is the user-level tool manager behind coding-agent harnesses and
// language toolchains (docs/architecture/helper.md). It contributes a
// "tools" backend: `mise outdated --json` for the count, and `vshell update
// run tools` for the upgrade.

import (
	"bytes"
	"encoding/json"
	"fmt"
	"sort"
	"strings"
)

// parseMiseOutdated reads `mise outdated --json`: a map of tool name to
// {name, requested, current, latest}. An empty object means up to date.
func parseMiseOutdated(out []byte) ([]Package, error) {
	trimmed := bytes.TrimSpace(out)
	if len(trimmed) == 0 {
		return nil, fmt.Errorf("empty output; up to date is `{}`")
	}
	var raw map[string]struct {
		Name    string `json:"name"`
		Current string `json:"current"`
		Latest  string `json:"latest"`
	}
	if err := json.Unmarshal(trimmed, &raw); err != nil {
		return nil, fmt.Errorf("invalid JSON: %w", err)
	}
	ids := make([]string, 0, len(raw))
	names := make(map[string]string, len(raw))
	for id, info := range raw {
		ids = append(ids, id)
		reported := info.Name
		if reported == "" {
			reported = id
		}
		names[id] = miseToolName(reported)
	}
	// The reader sees tool names, so the list is ordered by them; the mise id
	// breaks a tie, since two backends can publish the same tool name.
	sort.Slice(ids, func(i, j int) bool {
		if names[ids[i]] != names[ids[j]] {
			return names[ids[i]] < names[ids[j]]
		}
		return ids[i] < ids[j]
	})
	var packages []Package
	for _, id := range ids {
		info := raw[id]
		packages = append(packages, Package{Name: names[id], Repo: "tools", Backend: "mise", FromVersion: info.Current, ToVersion: info.Latest})
	}
	return packages, nil
}

// miseToolName is the tool's own name inside a mise id. mise files a package
// under its backend and owner (`npm:@deepseek-ai/dsh`, `aqua:google-antigravity/
// antigravity-cli`) for every backend but the default registry, which files it
// bare (`claude`). Listing both spellings side by side puts a prefix on some
// rows of the update list and not others, for no difference the reader can act
// on.
func miseToolName(id string) string {
	name := id
	if slash := strings.LastIndex(name, "/"); slash >= 0 {
		name = name[slash+1:]
	} else if colon := strings.Index(name, ":"); colon >= 0 {
		name = name[colon+1:]
	}
	// A backend and owner with nothing after them is not a name; the id itself
	// is the only thing left to show.
	if name == "" {
		return id
	}
	return name
}
