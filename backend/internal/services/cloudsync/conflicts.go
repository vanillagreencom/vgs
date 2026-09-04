package cloudsync

import (
	"crypto/sha1"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"syscall"
)

// conflictSuffix is rclone's --conflict-suffix. With --conflict-resolve none,
// bisync keeps both versions as "<name>.conflict1" (path1 = this computer) and
// "<name>.conflict2" (path2 = the cloud) rather than picking a winner.
const conflictSuffix = "conflict"

const (
	suffixLocal = "." + conflictSuffix + "1"
	suffixCloud = "." + conflictSuffix + "2"
)

const (
	resolveKeepLocal = "keepLocal"
	resolveKeepCloud = "keepCloud"
	resolveKeepBoth  = "keepBoth"
)

// Conflict files persist across runs, so rescanConflicts reads the local tree
// rather than relying on transient log messages.
func (m *Manager) rescanConflicts(folder Folder) error {
	if folder.Mode != ModeTwoWay {
		m.replaceConflicts(folder.ID, nil)
		return nil
	}

	var found []Conflict
	var scanProblems []string
	walkErr := filepath.Walk(folder.LocalPath, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			scanProblems = append(scanProblems, fmt.Sprintf("%s: %s", path, firstLine(err.Error())))
			if info != nil && info.IsDir() {
				return filepath.SkipDir
			}
			return nil
		}
		if info.IsDir() {
			if isIgnoredPath(path) {
				return filepath.SkipDir
			}
			return nil
		}
		if !strings.HasSuffix(path, suffixLocal) {
			return nil
		}
		base := strings.TrimSuffix(path, suffixLocal)
		cloudPath := base + suffixCloud
		cloudInfo, statErr := os.Stat(cloudPath)
		if statErr != nil {
			// Only one half is present; the other side has not landed yet, so
			// this is not something the user can resolve.
			if !os.IsNotExist(statErr) {
				scanProblems = append(scanProblems, fmt.Sprintf("%s: %s", cloudPath, firstLine(statErr.Error())))
			}
			return nil
		}
		rel, relErr := filepath.Rel(folder.LocalPath, base)
		if relErr != nil {
			rel = filepath.Base(base)
		}
		found = append(found, Conflict{
			ID:          conflictID(folder.ID, rel),
			FolderID:    folder.ID,
			FolderName:  folder.displayName(),
			RelPath:     rel,
			LocalPath:   path,
			CloudPath:   cloudPath,
			LocalSize:   info.Size(),
			CloudSize:   cloudInfo.Size(),
			LocalMtime:  info.ModTime().Unix(),
			CloudMtime:  cloudInfo.ModTime().Unix(),
			DetectedRun: nowUnix(),
		})
		return nil
	})
	if walkErr != nil {
		scanProblems = append(scanProblems, firstLine(walkErr.Error()))
	}
	if len(scanProblems) > 0 {
		err := fmt.Errorf("conflict scan failed: %s", strings.Join(scanProblems, "; "))
		m.markFolderError(folder.ID, err)
		m.log.Warn("cloudsync conflict scan failed", "folder", folder.ID, "err", err)
		return err
	}

	m.replaceConflicts(folder.ID, found)
	return nil
}

func (m *Manager) replaceConflicts(folderID string, found []Conflict) {
	m.mu.Lock()
	kept := make([]Conflict, 0, len(m.conflicts)+len(found))
	for _, c := range m.conflicts {
		if c.FolderID != folderID {
			kept = append(kept, c)
		}
	}
	kept = append(kept, found...)
	m.conflicts = kept
	m.statusLocked(folderID).ConflictCount = len(found)
	m.mu.Unlock()
}

// resolveConflict applies the user's choice on the local side and re-syncs, so
// the decision propagates to the cloud on the next run.
func (m *Manager) resolveConflict(id, action string) error {
	m.mu.Lock()
	var target *Conflict
	for i := range m.conflicts {
		if m.conflicts[i].ID == id {
			target = &m.conflicts[i]
			break
		}
	}
	var conflict Conflict
	if target != nil {
		conflict = *target
	}
	m.mu.Unlock()

	if target == nil {
		return fmt.Errorf("that conflict is no longer present")
	}
	folder, ok := m.store.folder(conflict.FolderID)
	if !ok {
		return fmt.Errorf("no such folder")
	}

	// Move the winner before trashing the rejected copy. A failed move must leave
	// the conflict pair available for retry.
	original := strings.TrimSuffix(conflict.LocalPath, suffixLocal)
	switch action {
	case resolveKeepLocal:
		// The winner is at conflict.LocalPath and must land on `original`,
		// which the loser currently does not occupy — so the move is safe
		// before the loser is trashed.
		if err := os.Rename(conflict.LocalPath, original); err != nil {
			return fmt.Errorf("keep this computer's copy: %w", err)
		}
		if err := m.trashLocal(folder, conflict.CloudPath); err != nil {
			return fmt.Errorf("kept this computer's copy, but the other copy could not be moved to the recycle bin: %w", err)
		}
	case resolveKeepCloud:
		if err := os.Rename(conflict.CloudPath, original); err != nil {
			return fmt.Errorf("keep the cloud copy: %w", err)
		}
		if err := m.trashLocal(folder, conflict.LocalPath); err != nil {
			return fmt.Errorf("kept the cloud copy, but the other copy could not be moved to the recycle bin: %w", err)
		}
	case resolveKeepBoth:
		ext := filepath.Ext(original)
		stem := strings.TrimSuffix(original, ext)
		localDest := stem + " (this computer)" + ext
		if err := os.Rename(conflict.LocalPath, localDest); err != nil {
			return fmt.Errorf("keep both copies: %w", err)
		}
		if err := os.Rename(conflict.CloudPath, stem+" (cloud)"+ext); err != nil {
			// Undo the first rename so the pair stays intact and the conflict
			// remains visible, rather than leaving an orphan behind a conflict
			// that has silently disappeared from the view.
			if undo := os.Rename(localDest, conflict.LocalPath); undo != nil {
				return fmt.Errorf("keep both copies: renamed this computer's copy to %q, but the cloud copy could not be renamed: %w", filepath.Base(localDest), err)
			}
			return fmt.Errorf("keep both copies: %w", err)
		}
	default:
		return fmt.Errorf("unknown resolution %q", action)
	}

	m.rescanConflicts(folder)
	// Force: the resolution itself is a deletion the user just approved, and on
	// a small folder it would otherwise trip bisync's max-delete guard.
	if err := m.startSync(folder.ID, syncOptions{Trigger: triggerManual, Force: true}); err != nil {
		m.noteStartFailure(folder.ID, triggerManual, err)
	}
	m.broadcastNow()
	return nil
}

// trashLocal moves the rejected version into the folder recycle bin for recovery
// within its retention period.
func (m *Manager) trashLocal(folder Folder, path string) error {
	rel, err := filepath.Rel(folder.LocalPath, path)
	if err != nil {
		rel = filepath.Base(path)
	}
	dest := filepath.Join(m.store.localTrash(folder.ID), rel)
	if err := os.MkdirAll(filepath.Dir(dest), 0o700); err != nil {
		return fmt.Errorf("prepare recycle bin: %w", err)
	}
	// Use a unique trash destination so an existing same-name file cannot block
	// conflict resolution.
	if _, statErr := os.Stat(dest); statErr == nil {
		dest = fmt.Sprintf("%s.%d", dest, nowUnix())
	}
	if err := moveFile(path, dest); err != nil {
		return fmt.Errorf("move to recycle bin: %w", err)
	}
	return nil
}

// moveFile relocates a file, falling back to copy-then-delete when the source
// and destination are on different filesystems. A synced folder frequently
// lives on a different device from ~/.local/state (external drive, separate
// /home), where a plain rename fails with EXDEV.
func moveFile(src, dst string) error {
	if err := os.Rename(src, dst); err == nil {
		return nil
	} else if !errors.Is(err, syscall.EXDEV) {
		return err
	}

	info, err := os.Stat(src)
	if err != nil {
		return err
	}
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()

	out, err := os.OpenFile(dst, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, info.Mode().Perm())
	if err != nil {
		return err
	}
	if _, err := io.Copy(out, in); err != nil {
		out.Close()
		os.Remove(dst)
		return err
	}
	// Sync the destination file before unlinking the source to reduce data loss if
	// the process stops during the move.
	if err := out.Sync(); err != nil {
		out.Close()
		os.Remove(dst)
		return err
	}
	if err := out.Close(); err != nil {
		os.Remove(dst)
		return err
	}
	return os.Remove(src)
}

// rescanAllConflicts scans configured two-way folders at startup so persisted
// conflicts can appear before another sync.
func (m *Manager) rescanAllConflicts() error {
	var problems []string
	for _, folder := range m.store.snapshotFolders() {
		if folder.Mode == ModeTwoWay {
			if err := m.rescanConflicts(folder); err != nil {
				problems = append(problems, err.Error())
			}
		}
	}
	if len(problems) > 0 {
		return errors.New(strings.Join(problems, "; "))
	}
	return nil
}

func conflictID(folderID, rel string) string {
	sum := sha1.Sum([]byte(folderID + "\x00" + rel))
	return hex.EncodeToString(sum[:10])
}
