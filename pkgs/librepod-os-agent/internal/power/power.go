// Package power does the owner's reboot or power off, once.
package power

import (
	"log"

	"github.com/librepod/os/pkgs/librepod-os-agent/api/v1alpha1"
	"github.com/librepod/os/pkgs/librepod-os-agent/internal/state"
)

// Apply acts on spec once. The id is saved before exec runs, so an agent that
// restarts in between never repeats it: a lost click beats a repeated one.
// publish writes status so the UI sees the id handled before the host goes
// down; its failure is only logged.
func Apply(spec *v1alpha1.PowerSpec, st *state.Store, installing bool, publish func() error, exec func(action string) error) error {
	if spec == nil || !st.S.Fresh("power", spec.ID) {
		return nil
	}
	switch {
	case spec.Action != "reboot" && spec.Action != "poweroff":
		st.S.Reject("power", spec.ID, "the action is not reboot or poweroff")
		return st.Save()
	case installing:
		st.S.Reject("power", spec.ID, "an update is installing")
		return st.Save()
	}
	st.S.Accept("power", spec.ID)
	if err := st.Save(); err != nil {
		return err
	}
	if err := publish(); err != nil {
		log.Printf("publishing status before %s: %v", spec.Action, err)
	}
	return exec(spec.Action)
}
