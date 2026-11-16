// Package state is what the agent keeps on disk: the numbers it has acted on
// and the SSH key list it owns. It survives restarts, reboots and a deleted
// Device.
package state

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"

	"github.com/librepod/os/pkgs/librepod-os-agent/api/v1alpha1"
)

type State struct {
	Handled  v1alpha1.Handled  `json:"handled"`
	Rejected map[string]string `json:"rejected,omitempty"`
	// SSHKeys is nil until the installer's keys are adopted.
	SSHKeys []string `json:"sshKeys"`
}

type Store struct {
	Path string
	S    State
}

// Open reads path; a missing file is the zero State.
func Open(path string) (*Store, error) {
	s := &Store{Path: path}
	b, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return s, nil
	}
	if err != nil {
		return nil, err
	}
	if err := json.Unmarshal(b, &s.S); err != nil {
		return nil, fmt.Errorf("%s: %w", path, err)
	}
	return s, nil
}

// Save writes the file so that a crash leaves the old or the new one, never half.
func (s *Store) Save() error {
	b, err := json.Marshal(s.S)
	if err != nil {
		return err
	}
	dir := filepath.Dir(s.Path)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	f, err := os.CreateTemp(dir, ".state-*") // 0600
	if err != nil {
		return err
	}
	defer os.Remove(f.Name()) // no-op after the rename
	if _, err := f.Write(b); err != nil {
		f.Close()
		return err
	}
	if err := f.Sync(); err != nil {
		f.Close()
		return err
	}
	if err := f.Close(); err != nil {
		return err
	}
	if err := os.Rename(f.Name(), s.Path); err != nil {
		return err
	}
	d, err := os.Open(dir)
	if err != nil {
		return err
	}
	defer d.Close()
	return d.Sync()
}

func (s *State) slot(section string) *int64 {
	switch section {
	case "updates":
		return &s.Handled.Updates
	case "install":
		return &s.Handled.Install
	case "power":
		return &s.Handled.Power
	case "sshKeys":
		return &s.Handled.SSHKeys
	}
	panic("state: unknown section " + section)
}

// Last is the last number acted on for section.
func (s *State) Last(section string) int64 { return *s.slot(section) }

// maxNumber: above it, a JSON number stops being an exact integer.
const maxNumber = 999999999999999

// Fresh: n is a usable rev or id, above the last one acted on for section.
func (s *State) Fresh(section string, n int64) bool {
	return n >= 1 && n <= maxNumber && n > s.Last(section)
}

// Accept records n as handled and clears the section's rejection.
func (s *State) Accept(section string, n int64) {
	*s.slot(section) = n
	delete(s.Rejected, section)
}

// Reject records n as handled too, with the reason.
func (s *State) Reject(section string, n int64, why string) {
	*s.slot(section) = n
	if s.Rejected == nil {
		s.Rejected = map[string]string{}
	}
	kind := "id"
	if section == "updates" || section == "sshKeys" {
		kind = "rev"
	}
	s.Rejected[section] = fmt.Sprintf("%s %s %d: %s", section, kind, n, why)
}
