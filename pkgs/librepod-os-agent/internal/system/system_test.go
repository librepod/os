package system

import (
	"fmt"
	"os"
	"path/filepath"
	"testing"
)

func write(t *testing.T, name, s string) string {
	p := filepath.Join(t.TempDir(), name)
	if err := os.WriteFile(p, []byte(s), 0o644); err != nil {
		t.Fatal(err)
	}
	return p
}

func TestReadVersion(t *testing.T) {
	p := Paths{OSRelease: write(t, "os-release", "NAME=x\nIMAGE_VERSION=\"0.6.0\"\n"), Root: "/", Data: "/nonexistent", MountInfo: write(t, "mi", "")}
	if v := Read(p).Version; v != "0.6.0" {
		t.Fatal(v)
	}
	p.OSRelease = filepath.Join(t.TempDir(), "missing")
	if v := Read(p).Version; v != "unknown" {
		t.Fatal(v)
	}
}

func TestDataDiskAbsent(t *testing.T) {
	mi := write(t, "mi", "36 1 8:1 / / rw - ext4 /dev/sda1 rw\n")
	s := Read(Paths{OSRelease: "/nonexistent", Root: "/", Data: t.TempDir(), MountInfo: mi})
	if s.DataDisk.Present {
		t.Fatalf("%+v", s.DataDisk)
	}
}

func TestDataDiskPresent(t *testing.T) {
	d := t.TempDir()
	mi := write(t, "mi", fmt.Sprintf("36 1 8:1 / / rw - ext4 /dev/sda1 rw\n40 36 8:2 / %s rw - ext4 /dev/sdb1 rw\n", d))
	s := Read(Paths{OSRelease: "/nonexistent", Root: "/", Data: d, MountInfo: mi})
	if !s.DataDisk.Present || s.DataDisk.SizeBytes <= 0 {
		t.Fatalf("%+v", s.DataDisk)
	}
}
