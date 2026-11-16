package setupcode

import (
	"os"
	"path/filepath"
	"testing"

	"golang.org/x/crypto/bcrypt"
)

func hashOf(t *testing.T, content string) []byte {
	t.Helper()
	p := filepath.Join(t.TempDir(), "setup-code")
	if err := os.WriteFile(p, []byte(content), 0o600); err != nil {
		t.Fatal(err)
	}
	h, err := Hash(p)
	if err != nil {
		t.Fatal(err)
	}
	return []byte(h)
}

func TestHashVerifies(t *testing.T) {
	h := hashOf(t, "7KQMX3RT9VHC\n")
	if err := bcrypt.CompareHashAndPassword(h, []byte("7KQMX3RT9VHC")); err != nil {
		t.Fatal(err)
	}
	if c, _ := bcrypt.Cost(h); c != 12 {
		t.Fatalf("cost %d", c)
	}
}

func TestHashNormalizes(t *testing.T) {
	h := hashOf(t, "7kqm-x3rt-9vhc")
	if err := bcrypt.CompareHashAndPassword(h, []byte("7KQMX3RT9VHC")); err != nil {
		t.Fatal(err)
	}
}

func TestHashRejectsOther(t *testing.T) {
	h := hashOf(t, "7KQMX3RT9VHC")
	if bcrypt.CompareHashAndPassword(h, []byte("AAAAAAAAAAAA")) == nil {
		t.Fatal("matched another code")
	}
}

func TestHashMissingFileEmpty(t *testing.T) {
	h, err := Hash(filepath.Join(t.TempDir(), "missing"))
	if err != nil || h != "" {
		t.Fatalf("%q %v", h, err)
	}
}
