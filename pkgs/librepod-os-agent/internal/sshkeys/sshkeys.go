// Package sshkeys keeps the one file sshd reads keys from for the librepod
// user, with the Marketplace owning the whole list.
package sshkeys

import (
	"bytes"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/librepod/os/pkgs/librepod-os-agent/api/v1alpha1"
	"github.com/librepod/os/pkgs/librepod-os-agent/internal/state"
	"golang.org/x/crypto/ssh"
)

// valid: `<type> <base64 starting AAAA> [comment]` on one line, no options.
func valid(k string) bool {
	if strings.ContainsAny(k, "\r\n") {
		return false
	}
	f := strings.Fields(k)
	if len(f) < 2 || !strings.HasPrefix(f[1], "AAAA") {
		return false
	}
	_, _, opts, rest, err := ssh.ParseAuthorizedKey([]byte(k))
	return err == nil && len(opts) == 0 && len(bytes.TrimSpace(rest)) == 0
}

// Validate names the first bad key, counting from 1.
func Validate(keys []string) error {
	for i, k := range keys {
		if !valid(k) {
			return fmt.Errorf("key %d is not a public key (key type first, no options)", i+1)
		}
	}
	return nil
}

// Adopt reads the installer's file: its good lines, none when it is missing.
func Adopt(path string) ([]string, error) {
	b, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return []string{}, nil
	}
	if err != nil {
		return nil, err
	}
	keys := []string{}
	for _, l := range strings.Split(string(b), "\n") {
		if l = strings.TrimSpace(l); l != "" && !strings.HasPrefix(l, "#") && valid(l) {
			keys = append(keys, l)
		}
	}
	return keys, nil
}

// Apply takes the owner's list once. A bad key rejects the whole answer.
func Apply(spec *v1alpha1.SSHKeysSpec, st *state.Store) error {
	if spec == nil || !st.S.Fresh("sshKeys", spec.Rev) {
		return nil
	}
	if err := Validate(spec.Keys); err != nil {
		st.S.Reject("sshKeys", spec.Rev, err.Error())
	} else {
		st.S.Accept("sshKeys", spec.Rev)
		st.S.SSHKeys = append([]string{}, spec.Keys...)
	}
	return st.Save()
}

// Render makes the file hold exactly keys, one per line, root's and 0644 in a
// 0755 directory (sshd's StrictModes). It writes only when something differs,
// as a new file renamed over the path: a symlink there is replaced, and its
// target left alone.
func Render(path string, keys []string) error {
	var want string
	for _, k := range keys {
		want += k + "\n"
	}
	if fi, err := os.Lstat(path); err == nil && fi.Mode().IsRegular() && fi.Mode().Perm() == 0o644 {
		if b, err := os.ReadFile(path); err == nil && string(b) == want {
			return nil
		}
	}
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	if err := os.Chmod(dir, 0o755); err != nil { // MkdirAll obeys the umask
		return err
	}
	f, err := os.CreateTemp(dir, ".keys-*")
	if err != nil {
		return err
	}
	defer os.Remove(f.Name()) // no-op after the rename
	if _, err := f.WriteString(want); err != nil {
		f.Close()
		return err
	}
	if err := f.Chmod(0o644); err != nil {
		f.Close()
		return err
	}
	if err := f.Close(); err != nil {
		return err
	}
	return os.Rename(f.Name(), path)
}
