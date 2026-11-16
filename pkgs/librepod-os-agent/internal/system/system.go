// Package system reads the host's slow-changing facts for Device.status.system.
package system

import (
	"bufio"
	"os"
	"strings"
	"syscall"

	"github.com/librepod/os/pkgs/librepod-os-agent/api/v1alpha1"
)

type Paths struct{ OSRelease, Root, Data, MountInfo string }

func Read(p Paths) v1alpha1.SystemStatus {
	s := v1alpha1.SystemStatus{Version: version(p.OSRelease)}
	s.RootDisk.SizeBytes, s.RootDisk.UsedBytes, _ = usage(p.Root)
	if mounted(p.MountInfo, p.Data) {
		s.DataDisk.Present = true
		s.DataDisk.SizeBytes, s.DataDisk.UsedBytes, _ = usage(p.Data)
	}
	return s
}

func version(path string) string {
	f, err := os.Open(path)
	if err != nil {
		return "unknown"
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		if v, ok := strings.CutPrefix(sc.Text(), "IMAGE_VERSION="); ok {
			if v = strings.Trim(v, `"'`); v != "" {
				return v
			}
		}
	}
	return "unknown"
}

func usage(path string) (size, used int64, err error) {
	var st syscall.Statfs_t
	if err = syscall.Statfs(path, &st); err != nil {
		return 0, 0, err
	}
	bs := int64(st.Bsize)
	return int64(st.Blocks) * bs, int64(st.Blocks-st.Bfree) * bs, nil
}

// mounted: path is the mount point (field 5) of a line in mountinfo.
func mounted(mountinfo, path string) bool {
	f, err := os.Open(mountinfo)
	if err != nil {
		return false
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		fs := strings.Fields(sc.Text())
		// shortcut: mountinfo escapes spaces as \040 and this compares as is; unescape if the data path ever has one.
		if len(fs) > 4 && fs[4] == path {
			return true
		}
	}
	return false
}
