package controller

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/librepod/os/pkgs/librepod-os-agent/api/v1alpha1"
	"github.com/librepod/os/pkgs/librepod-os-agent/internal/state"
	"github.com/librepod/os/pkgs/librepod-os-agent/internal/system"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
	"sigs.k8s.io/controller-runtime/pkg/client/interceptor"
)

const node = "pod-image"

type env struct {
	r   *Reconciler
	c   client.Client
	now time.Time
	dir string
}

func newEnv(t *testing.T, funcs interceptor.Funcs, objs ...client.Object) *env {
	t.Helper()
	sch := runtime.NewScheme()
	if err := v1alpha1.AddToScheme(sch); err != nil {
		t.Fatal(err)
	}
	c := fake.NewClientBuilder().WithScheme(sch).WithStatusSubresource(&v1alpha1.Device{}).
		WithObjects(objs...).WithInterceptorFuncs(funcs).Build()
	dir := t.TempDir()
	osr := filepath.Join(dir, "os-release")
	_ = os.WriteFile(osr, []byte("IMAGE_VERSION=\"0.6.0\"\n"), 0o644)
	mi := filepath.Join(dir, "mountinfo")
	_ = os.WriteFile(mi, nil, 0o644)
	st, err := state.Open(filepath.Join(dir, "state.json"))
	if err != nil {
		t.Fatal(err)
	}
	e := &env{c: c, dir: dir, now: time.Date(2026, 11, 16, 12, 0, 0, 0, time.UTC)}
	e.r = &Reconciler{
		Client: c, Node: node, Store: st,
		Paths: Paths{
			StatusJSON: filepath.Join(dir, "status.json"), TZDir: dir,
			AuthorizedKeys: filepath.Join(dir, "authorized_keys"), Heartbeat: filepath.Join(dir, "status-written"),
			System: system.Paths{OSRelease: osr, Root: dir, Data: filepath.Join(dir, "data"), MountInfo: mi},
		},
		Run:  func(...string) error { return nil },
		Exec: func(string) error { return nil },
		Now:  func() time.Time { return e.now },
	}
	return e
}

func (e *env) reconcile(t *testing.T) {
	t.Helper()
	if _, err := e.r.Reconcile(context.Background(), ctrl.Request{NamespacedName: types.NamespacedName{Name: node}}); err != nil {
		t.Fatal(err)
	}
}

func (e *env) device(t *testing.T) *v1alpha1.Device {
	t.Helper()
	var d v1alpha1.Device
	if err := e.c.Get(context.Background(), client.ObjectKey{Name: node}, &d); err != nil {
		t.Fatal(err)
	}
	return &d
}

func TestCreatesDeviceWhenMissing(t *testing.T) {
	e := newEnv(t, interceptor.Funcs{})
	e.reconcile(t)
	d := e.device(t)
	if d.Spec != (v1alpha1.DeviceSpec{}) {
		t.Fatalf("spec not empty: %+v", d.Spec)
	}
}

func TestRecreatesDeletedDeviceKeepsHandled(t *testing.T) {
	e := newEnv(t, interceptor.Funcs{})
	e.r.Store.S.Handled.Install = 7
	e.reconcile(t)
	e.reconcile(t)
	if got := e.device(t).Status.Handled.Install; got != 7 {
		t.Fatalf("handled.install = %d", got)
	}
}

func TestStatusWrittenAndHeartbeatTouched(t *testing.T) {
	start := time.Now().Add(-2 * time.Second)
	e := newEnv(t, interceptor.Funcs{}, &v1alpha1.Device{ObjectMeta: metav1.ObjectMeta{Name: node}})
	e.reconcile(t)
	d := e.device(t)
	if d.Status.Updated == nil || d.Status.System == nil || d.Status.System.Version != "0.6.0" {
		t.Fatalf("status: %+v", d.Status)
	}
	fi, err := os.Stat(e.r.Paths.Heartbeat)
	if err != nil || fi.ModTime().Before(start) {
		t.Fatalf("heartbeat: %v %v", fi, err)
	}
}

func TestUsageOnlyChangeWaitsFourMinutes(t *testing.T) {
	e := newEnv(t, interceptor.Funcs{}, &v1alpha1.Device{ObjectMeta: metav1.ObjectMeta{Name: node}})
	e.reconcile(t)
	d := e.device(t)
	d.Status.System.RootDisk.UsedBytes += 12345
	if err := e.c.Status().Update(context.Background(), d); err != nil {
		t.Fatal(err)
	}
	rv := e.device(t).ResourceVersion

	e.now = e.now.Add(time.Minute)
	e.reconcile(t)
	if got := e.device(t).ResourceVersion; got != rv {
		t.Fatalf("written after 1 min: %s -> %s", rv, got)
	}
	e.now = e.now.Add(3*time.Minute + time.Second)
	e.reconcile(t)
	if got := e.device(t).ResourceVersion; got == rv {
		t.Fatal("not written after 4 min 1 s")
	}
}

func TestClockBackStillWrites(t *testing.T) {
	e := newEnv(t, interceptor.Funcs{}, &v1alpha1.Device{ObjectMeta: metav1.ObjectMeta{Name: node}})
	e.reconcile(t)
	rv := e.device(t).ResourceVersion
	e.now = e.now.Add(-time.Hour) // status.updated is now an hour ahead
	e.reconcile(t)
	if got := e.device(t).ResourceVersion; got == rv {
		t.Fatal("not written after the clock went back")
	}
}

func TestNeverWritesSpec(t *testing.T) {
	spec := v1alpha1.DeviceSpec{Power: &v1alpha1.PowerSpec{ID: 5, Action: "reboot"}}
	e := newEnv(t, interceptor.Funcs{}, &v1alpha1.Device{ObjectMeta: metav1.ObjectMeta{Name: node}, Spec: spec})
	e.reconcile(t)
	e.reconcile(t)
	got := e.device(t).Spec
	if got.Power == nil || *got.Power != *spec.Power || got.Updates != nil || got.Install != nil || got.SSHKeys != nil {
		t.Fatalf("spec changed: %+v", got)
	}
}

func TestGetErrorTouchesNothing(t *testing.T) {
	boom := errors.New("apiserver down")
	e := newEnv(t, interceptor.Funcs{Get: func(context.Context, client.WithWatch, client.ObjectKey, client.Object, ...client.GetOption) error {
		return boom
	}})
	keyFile := e.r.Paths.AuthorizedKeys
	_ = os.WriteFile(keyFile, []byte("hand edit\n"), 0o644)
	old := time.Now().Add(-time.Hour).Truncate(time.Second)
	_ = os.Chtimes(keyFile, old, old)
	_, err := e.r.Reconcile(context.Background(), ctrl.Request{NamespacedName: types.NamespacedName{Name: node}})
	if fi, _ := os.Stat(keyFile); fi == nil || !fi.ModTime().Equal(old) {
		t.Fatalf("key file touched: %v", fi)
	}
	if b, _ := os.ReadFile(keyFile); string(b) != "hand edit\n" {
		t.Fatalf("key file changed: %q", b)
	}
	if !errors.Is(err, boom) {
		t.Fatalf("err = %v", err)
	}
	if _, err := os.Stat(e.r.Paths.Heartbeat); !os.IsNotExist(err) {
		t.Fatalf("heartbeat exists: %v", err)
	}
}

func TestStatusUpdateMirrorsStatusJSON(t *testing.T) {
	e := newEnv(t, interceptor.Funcs{}, &v1alpha1.Device{ObjectMeta: metav1.ObjectMeta{Name: node}})
	_ = os.WriteFile(e.r.Paths.StatusJSON, []byte(`{"state":"idle","settings":{"channel":"beta"}}`), 0o644)
	e.reconcile(t)
	u := e.device(t).Status.Update
	if u == nil {
		t.Fatal("no status.update")
	}
	var got map[string]any
	if err := json.Unmarshal(u.Raw, &got); err != nil || got["state"] != "idle" || got["settings"].(map[string]any)["channel"] != "beta" {
		t.Fatalf("%s %v", u.Raw, err)
	}
}

func TestRestoredSpecBelowHandledChangesNothing(t *testing.T) {
	spec := v1alpha1.DeviceSpec{Updates: &v1alpha1.UpdatesSpec{Rev: 1, Channel: "stable", Auto: true, Timezone: "UTC"}}
	e := newEnv(t, interceptor.Funcs{}, &v1alpha1.Device{ObjectMeta: metav1.ObjectMeta{Name: node}, Spec: spec})
	e.r.Store.S.Handled.Updates = 2
	var calls [][]string
	e.r.Run = func(a ...string) error { calls = append(calls, a); return nil }
	e.reconcile(t)
	if len(calls) != 0 || e.device(t).Status.Handled.Updates != 2 {
		t.Fatalf("calls %v handled %d", calls, e.device(t).Status.Handled.Updates)
	}
}

func TestPowerThroughReconcile(t *testing.T) {
	spec := v1alpha1.DeviceSpec{Power: &v1alpha1.PowerSpec{ID: 1, Action: "reboot"}}
	e := newEnv(t, interceptor.Funcs{}, &v1alpha1.Device{ObjectMeta: metav1.ObjectMeta{Name: node}, Spec: spec})
	var acts []string
	e.r.Exec = func(a string) error { acts = append(acts, a); return nil }
	e.reconcile(t)
	e.reconcile(t)
	if len(acts) != 1 || e.device(t).Status.Handled.Power != 1 {
		t.Fatalf("acts %v handled %d", acts, e.device(t).Status.Handled.Power)
	}
}

func TestPowerRefusedShowsRejectedAtOnce(t *testing.T) {
	spec := v1alpha1.DeviceSpec{Power: &v1alpha1.PowerSpec{ID: 3, Action: "reboot"}}
	e := newEnv(t, interceptor.Funcs{}, &v1alpha1.Device{ObjectMeta: metav1.ObjectMeta{Name: node}, Spec: spec})
	_ = os.WriteFile(e.r.Paths.StatusJSON, []byte(`{"state":"installing"}`), 0o644)
	e.reconcile(t)
	if got := e.device(t).Status.Rejected["power"]; got != "power id 3: an update is installing" {
		t.Fatalf("%q", got)
	}
}

func TestBootDropsWaitingPowerAndInstall(t *testing.T) {
	spec := v1alpha1.DeviceSpec{
		Power:   &v1alpha1.PowerSpec{ID: 5, Action: "poweroff"},
		Install: &v1alpha1.InstallSpec{ID: 4, When: "now"},
	}
	e := newEnv(t, interceptor.Funcs{}, &v1alpha1.Device{ObjectMeta: metav1.ObjectMeta{Name: node}, Spec: spec})
	e.r.Store.S.BootID, e.r.BootID = "boot-1", "boot-2"
	var acts []string
	e.r.Exec = func(a string) error { acts = append(acts, a); return nil }
	var calls [][]string
	e.r.Run = func(a ...string) error { calls = append(calls, a); return nil }
	e.reconcile(t)
	e.reconcile(t)
	d := e.device(t)
	if len(acts) != 0 || len(calls) != 0 {
		t.Fatalf("acted: %v %v", acts, calls)
	}
	if d.Status.Handled.Power != 5 || d.Status.Handled.Install != 4 {
		t.Fatalf("handled %+v", d.Status.Handled)
	}
	if got := d.Status.Rejected["power"]; got != "power id 5: the device restarted before it could act" {
		t.Fatalf("rejected.power %q", got)
	}
	if got := d.Status.Rejected["install"]; got != "install id 4: the device restarted before it could act" {
		t.Fatalf("rejected.install %q", got)
	}
	if st, err := state.Open(e.r.Store.Path); err != nil || st.S.BootID != "boot-2" {
		t.Fatalf("saved boot ID %q %v", st.S.BootID, err)
	}

	// The owner clicks again in the same boot: that one is carried out.
	d.Spec.Power = &v1alpha1.PowerSpec{ID: 6, Action: "reboot"}
	if err := e.c.Update(context.Background(), d); err != nil {
		t.Fatal(err)
	}
	e.reconcile(t)
	if len(acts) != 1 || acts[0] != "reboot" {
		t.Fatalf("acts %v", acts)
	}
	if got := e.device(t).Status.Rejected["power"]; got != "" {
		t.Fatalf("rejected.power %q", got)
	}
}

func TestSameBootStillActsOnWaitingPower(t *testing.T) {
	spec := v1alpha1.DeviceSpec{Power: &v1alpha1.PowerSpec{ID: 5, Action: "reboot"}}
	e := newEnv(t, interceptor.Funcs{}, &v1alpha1.Device{ObjectMeta: metav1.ObjectMeta{Name: node}, Spec: spec})
	e.r.Store.S.BootID = "boot-1"
	if err := e.r.Store.Save(); err != nil {
		t.Fatal(err)
	}
	st, err := state.Open(e.r.Store.Path) // the agent restarts
	if err != nil {
		t.Fatal(err)
	}
	e.r.Store, e.r.BootID = st, "boot-1"
	var acts []string
	e.r.Exec = func(a string) error { acts = append(acts, a); return nil }
	e.reconcile(t)
	if len(acts) != 1 || acts[0] != "reboot" {
		t.Fatalf("acts %v", acts)
	}
	if got := e.device(t).Status.Rejected["power"]; got != "" {
		t.Fatalf("rejected.power %q", got)
	}
}

func TestBootDropSaveFailureActsOnNothing(t *testing.T) {
	spec := v1alpha1.DeviceSpec{Power: &v1alpha1.PowerSpec{ID: 5, Action: "reboot"}}
	e := newEnv(t, interceptor.Funcs{}, &v1alpha1.Device{ObjectMeta: metav1.ObjectMeta{Name: node}, Spec: spec})
	e.r.BootID = "boot-2"                                             // stored one is "": the first run of this agent version
	e.r.Store.Path = filepath.Join(e.dir, "os-release", "state.json") // a file in the way
	e.r.Store.S.SSHKeys = []string{}                                  // adopted, so that save isn't the one failing
	var acts []string
	e.r.Exec = func(a string) error { acts = append(acts, a); return nil }
	if _, err := e.r.Reconcile(context.Background(), ctrl.Request{NamespacedName: types.NamespacedName{Name: node}}); err == nil {
		t.Fatal("no error")
	}
	if len(acts) != 0 {
		t.Fatalf("acts %v", acts)
	}
}

func TestBootChangeKeepsHandledAnswers(t *testing.T) {
	spec := v1alpha1.DeviceSpec{Power: &v1alpha1.PowerSpec{ID: 5, Action: "reboot"}}
	e := newEnv(t, interceptor.Funcs{}, &v1alpha1.Device{ObjectMeta: metav1.ObjectMeta{Name: node}, Spec: spec})
	e.r.Store.S.Handled.Power = 5
	e.r.Store.S.Rejected = map[string]string{"power": "power id 5: an update is installing"}
	e.r.BootID = "boot-2"
	var acts []string
	e.r.Exec = func(a string) error { acts = append(acts, a); return nil }
	e.reconcile(t)
	if len(acts) != 0 {
		t.Fatalf("acts %v", acts)
	}
	if got := e.device(t).Status.Rejected["power"]; got != "power id 5: an update is installing" {
		t.Fatalf("rejected.power %q", got)
	}
	if e.r.Store.S.BootID != "boot-2" {
		t.Fatalf("boot ID %q", e.r.Store.S.BootID)
	}
}

func TestAdoptsInstallersKeysOnceThenOwnsList(t *testing.T) {
	e := newEnv(t, interceptor.Funcs{}, &v1alpha1.Device{ObjectMeta: metav1.ObjectMeta{Name: node}})
	const k = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl me"
	_ = os.WriteFile(e.r.Paths.AuthorizedKeys, []byte(k+"\n"), 0o644)
	e.reconcile(t)
	if got := e.device(t).Status.SSHKeys; len(got) != 1 || got[0] != k {
		t.Fatalf("status.sshKeys %v", got)
	}
	_ = os.WriteFile(e.r.Paths.AuthorizedKeys, []byte("junk\n"), 0o644) // a hand edit is put back
	e.reconcile(t)
	if b, _ := os.ReadFile(e.r.Paths.AuthorizedKeys); string(b) != k+"\n" {
		t.Fatalf("%q", b)
	}
}

func TestSSHKeysAnswerReplacesList(t *testing.T) {
	const k = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl"
	spec := v1alpha1.DeviceSpec{SSHKeys: &v1alpha1.SSHKeysSpec{Rev: 1, Keys: []string{k}}}
	e := newEnv(t, interceptor.Funcs{}, &v1alpha1.Device{ObjectMeta: metav1.ObjectMeta{Name: node}, Spec: spec})
	e.reconcile(t)
	if b, _ := os.ReadFile(e.r.Paths.AuthorizedKeys); string(b) != k+"\n" {
		t.Fatalf("%q", b)
	}
	if d := e.device(t); len(d.Status.SSHKeys) != 1 || d.Status.Handled.SSHKeys != 1 {
		t.Fatalf("%+v", d.Status)
	}
}

func TestSetupCodeHashPublished(t *testing.T) {
	e := newEnv(t, interceptor.Funcs{}, &v1alpha1.Device{ObjectMeta: metav1.ObjectMeta{Name: node}})
	e.r.SetupCodeHash = "$2a$12$abc"
	e.reconcile(t)
	if got := e.device(t).Status.SetupCodeHash; got != "$2a$12$abc" {
		t.Fatalf("%q", got)
	}
}

// A real API server drops `handled` from a merge patch whose base already
// holds zeros, and then refuses the status for its missing required counters;
// and a merge patch deletes the nulls inside status.update. So status is
// replaced whole.
func TestStatusIsReplacedNotMergePatched(t *testing.T) {
	patched := false
	e := newEnv(t, interceptor.Funcs{SubResourcePatch: func(ctx context.Context, c client.Client, sub string, obj client.Object, p client.Patch, o ...client.SubResourcePatchOption) error {
		patched = true
		return c.SubResource(sub).Patch(ctx, obj, p, o...)
	}}, &v1alpha1.Device{ObjectMeta: metav1.ObjectMeta{Name: node}})
	_ = os.WriteFile(e.r.Paths.StatusJSON, []byte(`{"state":"idle","available":null,"lastCheck":null}`), 0o644)
	e.reconcile(t)
	if patched {
		t.Fatal("status was merge-patched")
	}
	u := e.device(t).Status.Update
	if u == nil || !strings.Contains(string(u.Raw), `"available":null`) {
		t.Fatalf("nulls lost: %v", u)
	}
}

func TestLiveReadErrorTouchesNothing(t *testing.T) {
	e := newEnv(t, interceptor.Funcs{}, &v1alpha1.Device{ObjectMeta: metav1.ObjectMeta{Name: node}})
	e.r.Reader = failingReader{}
	e.r.BootID = "boot-2"
	_ = os.WriteFile(e.r.Paths.AuthorizedKeys, []byte("console edit\n"), 0o644)
	if _, err := e.r.Reconcile(context.Background(), ctrl.Request{NamespacedName: types.NamespacedName{Name: node}}); err == nil {
		t.Fatal("no error")
	}
	if e.r.Store.S.BootID != "" {
		t.Fatalf("boot ID recorded without the Device: %q", e.r.Store.S.BootID)
	}
	if b, _ := os.ReadFile(e.r.Paths.AuthorizedKeys); string(b) != "console edit\n" {
		t.Fatalf("key file changed: %q", b)
	}
	if _, err := os.Stat(e.r.Paths.Heartbeat); !os.IsNotExist(err) {
		t.Fatal("heartbeat touched")
	}
}

type failingReader struct{}

func (failingReader) Get(context.Context, client.ObjectKey, client.Object, ...client.GetOption) error {
	return errors.New("apiserver down")
}
func (failingReader) List(context.Context, client.ObjectList, ...client.ListOption) error {
	return errors.New("apiserver down")
}
