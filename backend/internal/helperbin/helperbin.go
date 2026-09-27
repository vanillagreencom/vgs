// Package helperbin locates the vshell-helper executable the backend and the
// runner invoke.
package helperbin

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
)

// Path resolves vshell-helper from $VSHELL_ROOT/bin, then relative to the
// running executable, then PATH.
func Path() (string, error) {
	if root := os.Getenv("VSHELL_ROOT"); root != "" {
		path := filepath.Join(root, "bin", "vshell-helper")
		if st, err := os.Stat(path); err == nil && !st.IsDir() {
			return path, nil
		}
	}
	exe, err := os.Executable()
	if err == nil {
		path := filepath.Join(filepath.Dir(filepath.Dir(filepath.Dir(exe))), "bin", "vshell-helper")
		if st, err := os.Stat(path); err == nil && !st.IsDir() {
			return path, nil
		}
	}
	if path, err := exec.LookPath("vshell-helper"); err == nil {
		return path, nil
	}
	return "", fmt.Errorf("vshell-helper not found")
}
