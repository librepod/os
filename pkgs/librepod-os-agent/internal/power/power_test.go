package power

import (
	"errors"
	"os"
	"path/filepath"
	"testing"

	"github.com/librepod/os/pkgs/librepod-os-agent/api/v1alpha1"
	"github.com/librepod/os/pkgs/librepod-os-agent/internal/state"
)

func store(t *testing.T) *state.Store {
	st, err := state.Open(filepath.Join(t.TempDir(), "state.json"))
	if err != nil {
		t.Fatal(err)
	}
	return st
}

func noPublish() error { return nil }

func TestRebootOnce(t *testing.T) {
	st := store(t)
	var calls []string
	exec := func(a string) error { calls = append(calls, a); return nil }
	spec := &v1alpha1.PowerSpec{ID: 1, Action: "reboot"}
	for i := 0; i < 2; i++ {
		if err := Apply(spec, st, false, noPublish, exec); err != nil {
			t.Fatal(err)
		}
	}
	if len(calls) != 1 || calls[0] != "reboot" {
		t.Fatalf("calls %v", calls)
	}
}

func TestPoweroff(t *testing.T) {
	var got string
	err := Apply(&v1alpha1.PowerSpec{ID: 2, Action: "poweroff"}, store(t), false, noPublish,
		func(a string) error { got = a; return nil })
	if err != nil || got != "poweroff" {
		t.Fatalf("%v %q", err, got)
	}
}

func TestRefusedWhileInstalling(t *testing.T) {
	st := store(t)
	called := false
	err := Apply(&v1alpha1.PowerSpec{ID: 3, Action: "reboot"}, st, true, noPublish,
		func(string) error { called = true; return nil })
	if err != nil || called {
		t.Fatalf("err %v called %v", err, called)
	}
	if st.S.Rejected["power"] != "power id 3: an update is installing" || st.S.Handled.Power != 3 {
		t.Fatalf("%+v", st.S)
	}
}

func TestHandledPersistedBeforeExec(t *testing.T) {
	st := store(t)
	published := false
	err := Apply(&v1alpha1.PowerSpec{ID: 5, Action: "reboot"}, st, false,
		func() error { published = true; return nil },
		func(string) error {
			disk, err := state.Open(st.Path)
			if err != nil {
				t.Fatal(err)
			}
			if disk.S.Handled.Power != 5 {
				t.Fatalf("on disk at exec: %+v", disk.S.Handled)
			}
			if !published {
				t.Fatal("status not published before exec")
			}
			return nil
		})
	if err != nil {
		t.Fatal(err)
	}
}

func TestPublishFailureStillExecs(t *testing.T) {
	called := false
	err := Apply(&v1alpha1.PowerSpec{ID: 6, Action: "reboot"}, store(t), false,
		func() error { return errors.New("api down") },
		func(string) error { called = true; return nil })
	if err != nil || !called {
		t.Fatalf("err %v called %v", err, called)
	}
}

func TestSaveFailureNoExec(t *testing.T) {
	dir := t.TempDir()
	st, _ := state.Open(filepath.Join(dir, "sub", "state.json"))
	if err := os.WriteFile(filepath.Join(dir, "sub"), nil, 0o600); err != nil { // a file where the directory must be
		t.Fatal(err)
	}
	called := false
	err := Apply(&v1alpha1.PowerSpec{ID: 7, Action: "reboot"}, st, false, noPublish,
		func(string) error { called = true; return nil })
	if err == nil || called {
		t.Fatalf("err %v called %v", err, called)
	}
}
