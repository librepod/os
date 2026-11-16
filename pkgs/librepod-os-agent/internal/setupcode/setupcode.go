// Package setupcode turns the sticker's code into the bcrypt hash the Device
// publishes: the Marketplace checks what the owner types against it, and the
// code itself never leaves the host.
package setupcode

import (
	"errors"
	"os"
	"strings"

	"golang.org/x/crypto/bcrypt"
)

// Normalize: uppercase, without dashes, spaces and newlines.
func Normalize(s string) string {
	return strings.ToUpper(strings.NewReplacer("-", "", " ", "", "\n", "", "\r", "", "\t", "").Replace(s))
}

// Hash is bcrypt (cost 12) of the code in path, "" when there is no file.
func Hash(path string) (string, error) {
	b, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return "", nil
	}
	if err != nil {
		return "", err
	}
	h, err := bcrypt.GenerateFromPassword([]byte(Normalize(string(b))), 12)
	return string(h), err
}
