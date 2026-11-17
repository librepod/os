// Package controller reconciles the node's Device: it applies the owner's
// answers once each and mirrors the host's truth into status.
package controller

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"time"

	"github.com/librepod/os/pkgs/librepod-os-agent/api/v1alpha1"
	"github.com/librepod/os/pkgs/librepod-os-agent/internal/power"
	"github.com/librepod/os/pkgs/librepod-os-agent/internal/sshkeys"
	"github.com/librepod/os/pkgs/librepod-os-agent/internal/state"
	"github.com/librepod/os/pkgs/librepod-os-agent/internal/system"
	"github.com/librepod/os/pkgs/librepod-os-agent/internal/updates"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
)

// usageOnlyWait is how old status.updated gets before a change in nothing but
// the used-bytes numbers is written (the heartbeat is every 5 minutes at most).
const usageOnlyWait = 4 * time.Minute

type Paths struct {
	StatusJSON, TZDir, AuthorizedKeys, Heartbeat string
	System                                       system.Paths
}

type Reconciler struct {
	Client client.Client
	// Reader reads the live Device, past the cache: a cache keeps answering
	// after the API server is gone, and the host must then stay untouched.
	// Nil means Client.
	Reader client.Reader
	Node   string
	Store  *state.Store
	Paths  Paths
	// Run calls the updater's CLI; Exec reboots or powers off.
	Run  func(args ...string) error
	Exec func(action string) error
	// SetupCodeHash is the bcrypt hash of the sticker's code, "" without one.
	SetupCodeHash string
	// BootID is the kernel's ID of this boot.
	BootID string
	Now    func() time.Time
}

func (r *Reconciler) now() time.Time {
	if r.Now != nil {
		return r.Now()
	}
	return time.Now()
}

func (r *Reconciler) Reconcile(ctx context.Context, _ ctrl.Request) (ctrl.Result, error) {
	// 1. The Device. Any error but NotFound leaves the host untouched.
	var dev v1alpha1.Device
	var reader client.Reader = r.Client
	if r.Reader != nil {
		reader = r.Reader
	}
	err := reader.Get(ctx, client.ObjectKey{Name: r.Node}, &dev)
	if apierrors.IsNotFound(err) {
		d := &v1alpha1.Device{ObjectMeta: metav1.ObjectMeta{Name: r.Node}}
		if err := r.Client.Create(ctx, d); err != nil && !apierrors.IsAlreadyExists(err) {
			return ctrl.Result{}, err
		}
		return ctrl.Result{Requeue: true}, nil
	}
	if err != nil {
		return ctrl.Result{}, err
	}
	if err := r.dropAfterBoot(dev.Spec); err != nil {
		return ctrl.Result{}, err
	}

	// 2. Adopt the installer's SSH keys once; from then on the UI owns the list.
	if r.Store.S.SSHKeys == nil {
		if keys, err := sshkeys.Adopt(r.Paths.AuthorizedKeys); err != nil {
			ctrl.LoggerFrom(ctx).Error(err, "adopting SSH keys")
		} else {
			r.Store.S.SSHKeys = keys
			if err := r.Store.Save(); err != nil {
				return ctrl.Result{}, err
			}
		}
	}

	// 3. The owner's update answers. A failure is retried by the next run
	// (nothing was recorded); status still goes out.
	if err := updates.Apply(dev.Spec, r.Store, r.Run, r.Paths.TZDir); err != nil {
		ctrl.LoggerFrom(ctx).Error(err, "applying update answers")
	}

	// The owner's SSH key list, then the file sshd reads. Not before the keys
	// are adopted: rendering nothing would delete the installer's.
	if err := sshkeys.Apply(dev.Spec.SSHKeys, r.Store); err != nil {
		ctrl.LoggerFrom(ctx).Error(err, "applying SSH keys")
	}
	if r.Store.S.SSHKeys != nil {
		if err := sshkeys.Render(r.Paths.AuthorizedKeys, r.Store.S.SSHKeys); err != nil {
			ctrl.LoggerFrom(ctx).Error(err, "rendering SSH keys")
		}
	}

	// 4. Status.
	if err := r.writeStatus(ctx, &dev); err != nil {
		return ctrl.Result{}, err
	}

	// 5. Power, last: the host may go down right after. publish writes status
	// first; the second writeStatus covers a refusal (no-op otherwise).
	publish := func() error { return r.writeStatus(ctx, &dev) }
	if err := power.Apply(dev.Spec.Power, r.Store, updates.Installing(r.Paths.StatusJSON), publish, r.Exec); err != nil {
		ctrl.LoggerFrom(ctx).Error(err, "applying power answer")
	}
	if err := publish(); err != nil {
		return ctrl.Result{}, err
	}
	return ctrl.Result{RequeueAfter: 30 * time.Second}, nil
}

// dropAfterBoot rejects the power and install answers still waiting at the
// first run after a boot: an answer that outlived a boot is no longer the
// owner's click. The new boot ID is saved with the rejections, so a crash
// before that write drops them again.
func (r *Reconciler) dropAfterBoot(spec v1alpha1.DeviceSpec) error {
	if r.Store.S.BootID == r.BootID {
		return nil
	}
	const why = "the device restarted before it could act"
	if p := spec.Power; p != nil && r.Store.S.Fresh("power", p.ID) {
		r.Store.S.Reject("power", p.ID, why)
	}
	if i := spec.Install; i != nil && r.Store.S.Fresh("install", i.ID) {
		r.Store.S.Reject("install", i.ID, why)
	}
	r.Store.S.BootID = r.BootID
	return r.Store.Save()
}

func (r *Reconciler) desired() v1alpha1.DeviceStatus {
	sys := system.Read(r.Paths.System)
	s := v1alpha1.DeviceStatus{
		Handled:       r.Store.S.Handled,
		System:        &sys,
		SSHKeys:       append([]string{}, r.Store.S.SSHKeys...),
		Update:        updates.ReadStatus(r.Paths.StatusJSON),
		SetupCodeHash: r.SetupCodeHash,
	}
	if len(r.Store.S.Rejected) > 0 {
		s.Rejected = r.Store.S.Rejected
	}
	return s
}

// canon is status as JSON without what must not trigger a write on its own:
// the time stamp and the used-bytes numbers. Marshalling through a map
// settles key order and nil-versus-empty differences of a round trip.
func canon(s v1alpha1.DeviceStatus) string {
	s.Updated = nil
	if s.System != nil {
		sys := *s.System
		sys.RootDisk.UsedBytes, sys.DataDisk.UsedBytes = 0, 0
		s.System = &sys
	}
	if s.SSHKeys == nil {
		s.SSHKeys = []string{}
	}
	b, _ := json.Marshal(s)
	var m any
	_ = json.Unmarshal(b, &m)
	b, _ = json.Marshal(m)
	return string(b)
}

func (r *Reconciler) writeStatus(ctx context.Context, dev *v1alpha1.Device) error {
	want := r.desired()
	now := r.now()
	// An updated in the future means the clock went back: waiting for it would stop the writes.
	stale := dev.Status.Updated == nil || now.Sub(dev.Status.Updated.Time) >= usageOnlyWait ||
		now.Before(dev.Status.Updated.Time)
	if !stale && canon(want) == canon(dev.Status) {
		return nil
	}
	t := metav1.NewTime(now)
	want.Updated = &t
	dev.Status = want
	// Replace the whole status, never merge-patch it: a merge patch against a
	// base that holds zeros omits `handled` (the API server then refuses the
	// status for its required counters) and deletes the nulls inside
	// status.update. A conflict returns as an error; the next run retries.
	if err := r.Client.Status().Update(ctx, dev); err != nil {
		return err
	}
	return touch(r.Paths.Heartbeat)
}

func touch(path string) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	f, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY, 0o600)
	if err != nil {
		return err
	}
	if err := f.Close(); err != nil {
		return err
	}
	n := time.Now()
	return os.Chtimes(path, n, n)
}

func (r *Reconciler) SetupWithManager(mgr ctrl.Manager) error {
	return ctrl.NewControllerManagedBy(mgr).For(&v1alpha1.Device{}).Complete(r)
}
