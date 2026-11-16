package updates

import (
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"github.com/librepod/os/pkgs/librepod-os-agent/api/v1alpha1"
	"github.com/librepod/os/pkgs/librepod-os-agent/internal/state"
)

type rig struct {
	t     *testing.T
	st    *state.Store
	tz    string
	calls [][]string
	fail  string // a CLI verb that fails
}

func newRig(t *testing.T) *rig {
	tz := t.TempDir()
	if err := os.MkdirAll(filepath.Join(tz, "Europe"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(tz, "Europe", "Minsk"), []byte("tz"), 0o644); err != nil {
		t.Fatal(err)
	}
	st, err := state.Open(filepath.Join(t.TempDir(), "state.json"))
	if err != nil {
		t.Fatal(err)
	}
	return &rig{t: t, st: st, tz: tz}
}

func (r *rig) run(args ...string) error {
	r.calls = append(r.calls, args)
	if len(args) > 0 && args[0] == r.fail {
		return errors.New("updater failed")
	}
	return nil
}

func (r *rig) apply(spec v1alpha1.DeviceSpec) error { return Apply(spec, r.st, r.run, r.tz) }

func upd(rev int64, ch string, auto bool, tz string) v1alpha1.DeviceSpec {
	return v1alpha1.DeviceSpec{Updates: &v1alpha1.UpdatesSpec{Rev: rev, Channel: ch, Auto: auto, Timezone: tz}}
}

func TestSettingsOncePerRev(t *testing.T) {
	r := newRig(t)
	if err := r.apply(upd(3, "beta", true, "Europe/Minsk")); err != nil {
		t.Fatal(err)
	}
	want := [][]string{{"channel", "beta"}, {"auto", "on"}, {"timezone", "Europe/Minsk"}}
	if !reflect.DeepEqual(r.calls, want) || r.st.S.Handled.Updates != 3 {
		t.Fatalf("calls %v handled %d", r.calls, r.st.S.Handled.Updates)
	}
	r.calls = nil
	_ = r.apply(upd(3, "beta", true, "Europe/Minsk"))
	_ = r.apply(upd(2, "stable", false, "Europe/Minsk"))
	if len(r.calls) != 0 || r.st.S.Handled.Updates != 3 {
		t.Fatalf("calls %v handled %d", r.calls, r.st.S.Handled.Updates)
	}
}

func TestInstallOncePerID(t *testing.T) {
	r := newRig(t)
	spec := v1alpha1.DeviceSpec{Install: &v1alpha1.InstallSpec{ID: 7, When: "now"}}
	_ = r.apply(spec)
	if !reflect.DeepEqual(r.calls, [][]string{{"install", "now"}}) {
		t.Fatal(r.calls)
	}
	r.calls = nil
	_ = r.apply(spec)
	if len(r.calls) != 0 {
		t.Fatal(r.calls)
	}
}

func TestUnknownZoneRejected(t *testing.T) {
	for _, z := range []string{"../../etc/shadow", "Europe/Minsk; reboot", "Mars/Olympus"} {
		r := newRig(t)
		if err := r.apply(upd(4, "stable", true, z)); err != nil {
			t.Fatal(err)
		}
		if len(r.calls) != 0 || r.st.S.Handled.Updates != 4 ||
			r.st.S.Rejected["updates"] != "updates rev 4: the time zone is unknown" {
			t.Fatalf("%q: calls %v state %+v", z, r.calls, r.st.S)
		}
	}
}

func TestCLIFailureNotRecorded(t *testing.T) {
	r := newRig(t)
	r.fail = "channel"
	if err := r.apply(upd(2, "beta", true, "Europe/Minsk")); err == nil {
		t.Fatal("no error")
	}
	if r.st.S.Handled.Updates != 0 {
		t.Fatal("recorded")
	}
	r.fail = ""
	if err := r.apply(upd(2, "beta", true, "Europe/Minsk")); err != nil || r.st.S.Handled.Updates != 2 {
		t.Fatalf("%v %d", err, r.st.S.Handled.Updates)
	}
}

func TestSettingsKeptWhenInstallFails(t *testing.T) {
	r := newRig(t)
	r.st.S.Handled.Install = 8
	r.fail = "install"
	spec := upd(31, "stable", true, "Europe/Minsk")
	spec.Install = &v1alpha1.InstallSpec{ID: 9, When: "tonight"}
	if err := r.apply(spec); err == nil {
		t.Fatal("no error")
	}
	disk, err := state.Open(r.st.Path)
	if err != nil {
		t.Fatal(err)
	}
	if disk.S.Handled.Updates != 31 || disk.S.Handled.Install != 8 {
		t.Fatalf("on disk: %+v", disk.S.Handled)
	}
}

func TestAppliedAnswerClearsRejection(t *testing.T) {
	r := newRig(t)
	_ = r.apply(upd(1, "stable", true, "Mars/Olympus"))
	if r.st.S.Rejected["updates"] == "" {
		t.Fatal("not rejected")
	}
	_ = r.apply(upd(2, "stable", true, "Europe/Minsk"))
	if _, ok := r.st.S.Rejected["updates"]; ok {
		t.Fatal("rejection kept")
	}
}

func TestReadStatusMissingOrGarbage(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "status.json")
	if ReadStatus(p) != nil {
		t.Fatal("missing")
	}
	for _, c := range []string{"garbage", "[1]"} {
		_ = os.WriteFile(p, []byte(c), 0o644)
		if ReadStatus(p) != nil {
			t.Fatalf("%q", c)
		}
	}
	_ = os.WriteFile(p, []byte(`{"state":"idle"}`+"\n"), 0o644)
	if got := ReadStatus(p); got == nil || strings.TrimSpace(string(got.Raw)) != `{"state":"idle"}` {
		t.Fatalf("%v", got)
	}
}

func TestInstalling(t *testing.T) {
	p := filepath.Join(t.TempDir(), "status.json")
	if Installing(p) {
		t.Fatal("missing file")
	}
	_ = os.WriteFile(p, []byte(`{"state":"installing"}`), 0o644)
	if !Installing(p) {
		t.Fatal("installing")
	}
	_ = os.WriteFile(p, []byte(`{"state":"idle"}`), 0o644)
	if Installing(p) {
		t.Fatal("idle")
	}
}
