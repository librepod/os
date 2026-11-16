package sshkeys

import (
	"crypto/ecdsa"
	"crypto/ed25519"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/rsa"
	"encoding/base64"
	"encoding/binary"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"github.com/librepod/os/pkgs/librepod-os-agent/api/v1alpha1"
	"github.com/librepod/os/pkgs/librepod-os-agent/internal/state"
	"golang.org/x/crypto/ssh"
)

func line(t *testing.T, pub any, comment string) string {
	t.Helper()
	k, err := ssh.NewPublicKey(pub)
	if err != nil {
		t.Fatal(err)
	}
	s := strings.TrimSpace(string(ssh.MarshalAuthorizedKey(k)))
	if comment != "" {
		s += " " + comment
	}
	return s
}

func ed(t *testing.T, comment string) string {
	pub, _, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	return line(t, pub, comment)
}

// skEd25519 builds a FIDO security key's public key by its wire format.
func skEd25519(t *testing.T) string {
	pub, _, _ := ed25519.GenerateKey(rand.Reader)
	var b []byte
	for _, f := range [][]byte{[]byte("sk-ssh-ed25519@openssh.com"), pub, []byte("ssh:")} {
		b = binary.BigEndian.AppendUint32(b, uint32(len(f)))
		b = append(b, f...)
	}
	return "sk-ssh-ed25519@openssh.com " + base64.StdEncoding.EncodeToString(b) + " yubikey"
}

func TestValidate(t *testing.T) {
	ec, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	rk, _ := rsa.GenerateKey(rand.Reader, 2048)
	good := ed(t, "me@laptop")
	for _, k := range []string{
		ed(t, ""), good, line(t, &ec.PublicKey, "ec"), line(t, &rk.PublicKey, "rsa with words"), skEd25519(t),
	} {
		if err := Validate([]string{k}); err != nil {
			t.Errorf("rejected %q: %v", k, err)
		}
	}
	for _, k := range []string{
		`command="x" ` + good,
		`from="1.2.3.4" ` + good,
		"host " + good,
		"junk",
		good + "\r",
		good + "\nssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIA",
	} {
		if err := Validate([]string{k}); err == nil {
			t.Errorf("accepted %q", k)
		}
	}
}

func TestValidateNumbersTheBadKey(t *testing.T) {
	err := Validate([]string{ed(t, ""), "junk", ed(t, "")})
	if err == nil || err.Error() != "key 2 is not a public key (key type first, no options)" {
		t.Fatal(err)
	}
}

func TestAdoptSkipsCommentsAndBlank(t *testing.T) {
	a, b := ed(t, "a"), ed(t, "b")
	p := filepath.Join(t.TempDir(), "k")
	_ = os.WriteFile(p, []byte("# the installer's\n\n"+a+"\r\nnot a key\n"+b+"\n"), 0o644)
	got, err := Adopt(p)
	if err != nil || !reflect.DeepEqual(got, []string{a, b}) {
		t.Fatalf("%v %v", got, err)
	}
}

func TestAdoptMissingFileIsEmpty(t *testing.T) {
	got, err := Adopt(filepath.Join(t.TempDir(), "missing"))
	if err != nil || got == nil || len(got) != 0 {
		t.Fatalf("%#v %v", got, err)
	}
}

func store(t *testing.T) *state.Store {
	st, err := state.Open(filepath.Join(t.TempDir(), "state.json"))
	if err != nil {
		t.Fatal(err)
	}
	return st
}

func TestApplyReplacesList(t *testing.T) {
	st := store(t)
	st.S.SSHKeys = []string{ed(t, "old")}
	keys := []string{ed(t, "a"), ed(t, "b")}
	if err := Apply(&v1alpha1.SSHKeysSpec{Rev: 2, Keys: keys}, st); err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(st.S.SSHKeys, keys) || st.S.Handled.SSHKeys != 2 {
		t.Fatalf("%+v", st.S)
	}
	// once: the same rev again, with other keys, changes nothing
	_ = Apply(&v1alpha1.SSHKeysSpec{Rev: 2, Keys: []string{ed(t, "c")}}, st)
	if !reflect.DeepEqual(st.S.SSHKeys, keys) {
		t.Fatal("applied twice")
	}
}

func TestApplyRejectsWholeAnswer(t *testing.T) {
	st := store(t)
	old := []string{ed(t, "old")}
	st.S.SSHKeys = old
	_ = Apply(&v1alpha1.SSHKeysSpec{Rev: 5, Keys: []string{ed(t, ""), "junk", ed(t, "")}}, st)
	if !reflect.DeepEqual(st.S.SSHKeys, old) {
		t.Fatalf("list changed: %v", st.S.SSHKeys)
	}
	want := "sshKeys rev 5: key 2 is not a public key (key type first, no options)"
	if st.S.Rejected["sshKeys"] != want || st.S.Handled.SSHKeys != 5 {
		t.Fatalf("%+v", st.S)
	}
}

func TestApplyEmptyListRemovesAll(t *testing.T) {
	st := store(t)
	st.S.SSHKeys = []string{ed(t, "old")}
	_ = Apply(&v1alpha1.SSHKeysSpec{Rev: 1, Keys: nil}, st)
	if st.S.SSHKeys == nil || len(st.S.SSHKeys) != 0 {
		t.Fatalf("%#v", st.S.SSHKeys)
	}
}

func TestRenderRewritesHandEdit(t *testing.T) {
	p := filepath.Join(t.TempDir(), "d", "librepod")
	keys := []string{ed(t, "a"), ed(t, "b")}
	if err := Render(p, keys); err != nil {
		t.Fatal(err)
	}
	want := keys[0] + "\n" + keys[1] + "\n"
	if b, _ := os.ReadFile(p); string(b) != want {
		t.Fatalf("%q", b)
	}
	_ = os.WriteFile(p, []byte("junk\n"), 0o644)
	_ = Render(p, keys)
	if b, _ := os.ReadFile(p); string(b) != want {
		t.Fatalf("not put back: %q", b)
	}
}

func TestRenderMode0644(t *testing.T) {
	old := umaskSet(0o077)
	defer umaskSet(old)
	p := filepath.Join(t.TempDir(), "d", "librepod")
	if err := Render(p, []string{ed(t, "")}); err != nil {
		t.Fatal(err)
	}
	fi, _ := os.Stat(p)
	di, _ := os.Stat(filepath.Dir(p))
	if fi.Mode().Perm() != 0o644 || di.Mode().Perm() != 0o755 {
		t.Fatalf("file %v dir %v", fi.Mode().Perm(), di.Mode().Perm())
	}
}

func TestRenderReplacesSymlink(t *testing.T) {
	dir := t.TempDir()
	target := filepath.Join(dir, "target")
	_ = os.WriteFile(target, []byte("precious\n"), 0o644)
	p := filepath.Join(dir, "librepod")
	if err := os.Symlink(target, p); err != nil {
		t.Fatal(err)
	}
	k := ed(t, "")
	if err := Render(p, []string{k}); err != nil {
		t.Fatal(err)
	}
	fi, _ := os.Lstat(p)
	if !fi.Mode().IsRegular() {
		t.Fatalf("mode %v", fi.Mode())
	}
	if b, _ := os.ReadFile(target); string(b) != "precious\n" {
		t.Fatalf("target changed: %q", b)
	}
	if b, _ := os.ReadFile(p); string(b) != k+"\n" {
		t.Fatalf("%q", b)
	}
}
