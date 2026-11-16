package state

import (
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

func TestOpenMissingIsZero(t *testing.T) {
	s, err := Open(filepath.Join(t.TempDir(), "state.json"))
	if err != nil {
		t.Fatal(err)
	}
	if s.S.Handled.Power != 0 || s.S.Rejected != nil || s.S.SSHKeys != nil {
		t.Fatalf("not zero: %+v", s.S)
	}
}

func TestSaveOpenRoundTrip(t *testing.T) {
	p := filepath.Join(t.TempDir(), "state.json")
	s, _ := Open(p)
	s.S.Accept("install", 7)
	s.S.Reject("power", 3, "an update is installing")
	s.S.SSHKeys = []string{}
	if err := s.Save(); err != nil {
		t.Fatal(err)
	}
	got, err := Open(p)
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(got.S, s.S) {
		t.Fatalf("got %+v want %+v", got.S, s.S)
	}
	if got.S.SSHKeys == nil {
		t.Fatal("adopted-empty key list must stay non-nil")
	}
}

func TestSaveLeavesNoTempFilesAndMode0600(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "state.json")
	s, _ := Open(p)
	s.S.Accept("updates", 1)
	if err := s.Save(); err != nil {
		t.Fatal(err)
	}
	ents, _ := os.ReadDir(dir)
	if len(ents) != 1 || ents[0].Name() != "state.json" {
		t.Fatalf("dir: %v", ents)
	}
	fi, _ := os.Stat(p)
	if fi.Mode().Perm() != 0o600 {
		t.Fatalf("mode %v", fi.Mode())
	}
}

func TestAcceptClearsRejected(t *testing.T) {
	var s State
	s.Reject("updates", 4, "x")
	s.Accept("updates", 5)
	if s.Last("updates") != 5 || len(s.Rejected) != 0 {
		t.Fatalf("%+v", s)
	}
}

func TestRejectFormats(t *testing.T) {
	var s State
	s.Reject("updates", 4, "the time zone is unknown")
	s.Reject("power", 3, "an update is installing")
	if s.Rejected["updates"] != "updates rev 4: the time zone is unknown" {
		t.Fatal(s.Rejected["updates"])
	}
	if s.Rejected["power"] != "power id 3: an update is installing" {
		t.Fatal(s.Rejected["power"])
	}
	if s.Last("updates") != 4 || s.Last("power") != 3 {
		t.Fatalf("%+v", s.Handled)
	}
}
