// librepod-os-agent serves the Device API on an image device: it creates the
// node's Device, applies the owner's answers once each and mirrors the host's
// truth into status. It listens on no port.
package main

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"strings"

	"github.com/librepod/os/pkgs/librepod-os-agent/api/v1alpha1"
	"github.com/librepod/os/pkgs/librepod-os-agent/internal/controller"
	"github.com/librepod/os/pkgs/librepod-os-agent/internal/setupcode"
	"github.com/librepod/os/pkgs/librepod-os-agent/internal/state"
	"github.com/librepod/os/pkgs/librepod-os-agent/internal/system"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/fields"
	"k8s.io/apimachinery/pkg/runtime"
	clientgoscheme "k8s.io/client-go/kubernetes/scheme"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/cache"
	"sigs.k8s.io/controller-runtime/pkg/client"
	metricsserver "sigs.k8s.io/controller-runtime/pkg/metrics/server"
)

const stateDir = "/var/lib/librepod/agent"

func main() {
	if err := run(); err != nil {
		// systemd restarts us every 10 s: that is also how we wait for the CRD.
		fmt.Fprintln(os.Stderr, "librepod-os-agent:", err)
		os.Exit(1)
	}
}

func run() error {
	host, err := os.ReadFile("/proc/sys/kernel/hostname")
	if err != nil {
		return err
	}
	node := strings.TrimSpace(string(host))
	boot, err := os.ReadFile("/proc/sys/kernel/random/boot_id")
	if err != nil {
		return err
	}

	scheme := runtime.NewScheme()
	if err := clientgoscheme.AddToScheme(scheme); err != nil {
		return err
	}
	if err := v1alpha1.AddToScheme(scheme); err != nil {
		return err
	}
	cfg, err := ctrl.GetConfig()
	if err != nil {
		return err
	}

	// Get or create our Device before the manager starts, so a CRD that isn't
	// established yet fails here, not inside the cache.
	direct, err := client.New(cfg, client.Options{Scheme: scheme})
	if err != nil {
		return err
	}
	ctx := ctrl.SetupSignalHandler()
	if err := ensureDevice(ctx, direct, node); err != nil {
		return err
	}

	mgr, err := ctrl.NewManager(cfg, ctrl.Options{
		Scheme:                 scheme,
		Metrics:                metricsserver.Options{BindAddress: "0"},
		HealthProbeBindAddress: "0",
		LeaderElection:         false,
		Cache: cache.Options{ByObject: map[client.Object]cache.ByObject{
			&v1alpha1.Device{}: {Field: fields.OneTermEqualSelector("metadata.name", node)},
		}},
	})
	if err != nil {
		return err
	}
	store, err := state.Open(stateDir + "/state.json")
	if err != nil {
		return err
	}
	tz := os.Getenv("TZDIR")
	if tz == "" {
		tz = "/etc/zoneinfo"
	}
	// Once, at start: bcrypt at cost 12 is slow on purpose, and the file never changes.
	hash, err := setupcode.Hash("/var/lib/librepod/setup-code")
	if err != nil {
		return err
	}
	r := &controller.Reconciler{
		Client: mgr.GetClient(), Reader: mgr.GetAPIReader(), Node: node, Store: store, SetupCodeHash: hash,
		BootID: strings.TrimSpace(string(boot)),
		Paths: controller.Paths{
			StatusJSON:     "/var/lib/librepod/updates/status.json",
			TZDir:          tz,
			AuthorizedKeys: "/etc/ssh/authorized_keys.d/librepod",
			Heartbeat:      stateDir + "/status-written",
			System: system.Paths{
				OSRelease: "/etc/os-release", Root: "/", Data: "/mnt/k3s", MountInfo: "/proc/self/mountinfo",
			},
		},
		Run:  runUpdater,
		Exec: func(action string) error { return exec.Command("systemctl", action).Run() },
	}
	if err := r.SetupWithManager(mgr); err != nil {
		return err
	}
	return mgr.Start(ctx)
}

// runUpdater calls the updater's CLI; its output goes to the journal.
func runUpdater(args ...string) error {
	out, err := exec.Command("librepod-update", args...).CombinedOutput()
	if len(out) > 0 {
		fmt.Fprintf(os.Stderr, "librepod-update %s: %s", strings.Join(args, " "), out)
	}
	return err
}

func ensureDevice(ctx context.Context, c client.Client, node string) error {
	var d v1alpha1.Device
	err := c.Get(ctx, client.ObjectKey{Name: node}, &d)
	if apierrors.IsNotFound(err) {
		err = c.Create(ctx, &v1alpha1.Device{ObjectMeta: metav1.ObjectMeta{Name: node}})
		if apierrors.IsAlreadyExists(err) {
			return nil
		}
	}
	return err
}
