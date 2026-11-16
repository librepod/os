// Package updates carries the owner's update answers (spec.updates,
// spec.install) to the updater's CLI, once each, and reads its status back.
package updates

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"regexp"

	"github.com/librepod/os/pkgs/librepod-os-agent/api/v1alpha1"
	"github.com/librepod/os/pkgs/librepod-os-agent/internal/state"
	apiextensionsv1 "k8s.io/apiextensions-apiserver/pkg/apis/apiextensions/v1"
)

// The zone becomes part of a path, so the shape is checked before the file.
var zoneShape = regexp.MustCompile(`^[A-Za-z][A-Za-z0-9_+-]*(/[A-Za-z0-9_+-]+)*$`)

func validZone(tzdir, zone string) bool {
	if !zoneShape.MatchString(zone) {
		return false
	}
	fi, err := os.Stat(filepath.Join(tzdir, zone))
	return err == nil && fi.Mode().IsRegular()
}

// Apply handles spec.updates, then spec.install. A section is saved as
// handled right after its decision, so a failure of the next one can't undo
// it. If the CLI fails the section's number is not recorded: the next run
// retries it.
func Apply(spec v1alpha1.DeviceSpec, st *state.Store, run func(args ...string) error, tzdir string) error {
	if u := spec.Updates; u != nil && st.S.Fresh("updates", u.Rev) {
		var why string
		switch {
		case u.Channel != "stable" && u.Channel != "beta":
			why = "the channel is not stable or beta"
		case !validZone(tzdir, u.Timezone):
			why = "the time zone is unknown"
		}
		if why == "" {
			auto := "off"
			if u.Auto {
				auto = "on"
			}
			for _, args := range [][]string{{"channel", u.Channel}, {"auto", auto}, {"timezone", u.Timezone}} {
				if err := run(args...); err != nil {
					return err
				}
			}
			st.S.Accept("updates", u.Rev)
		} else {
			st.S.Reject("updates", u.Rev, why)
		}
		if err := st.Save(); err != nil {
			return err
		}
	}
	if i := spec.Install; i != nil && st.S.Fresh("install", i.ID) {
		if i.When == "now" || i.When == "tonight" {
			if err := run("install", i.When); err != nil {
				return err
			}
			st.S.Accept("install", i.ID)
		} else {
			st.S.Reject("install", i.ID, "when is not now or tonight")
		}
		if err := st.Save(); err != nil {
			return err
		}
	}
	return nil
}

func readStatus(path string) (raw []byte, m map[string]any) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, nil
	}
	b = bytes.TrimSpace(b)
	if json.Unmarshal(b, &m) != nil || m == nil {
		return nil, nil
	}
	return b, m
}

// ReadStatus is the updater's status.json as it is; nil when it is missing or
// not a JSON object.
func ReadStatus(path string) *apiextensionsv1.JSON {
	raw, m := readStatus(path)
	if m == nil {
		return nil
	}
	return &apiextensionsv1.JSON{Raw: raw}
}

// Installing: an update is being installed right now.
func Installing(path string) bool {
	_, m := readStatus(path)
	return m["state"] == "installing"
}
