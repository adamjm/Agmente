package push

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/x509"
	"encoding/pem"
	"errors"
	"fmt"
	"os"
)

// LoadKey reads an APNs auth key (.p8, PKCS#8 PEM, ECDSA P-256; PLAN 3.11). It refuses a file that
// group or others can read, and a file it cannot parse. Its errors name the file and the problem,
// never the key bytes (NFR-14).
func LoadKey(path string) (*ecdsa.PrivateKey, error) {
	fi, err := os.Stat(path)
	if err != nil {
		return nil, fmt.Errorf("push key file %s cannot be read", path)
	}
	if !fi.Mode().IsRegular() {
		return nil, fmt.Errorf("push key file %s is not a regular file", path)
	}
	if perm := fi.Mode().Perm(); perm&0o077 != 0 {
		return nil, fmt.Errorf("push key file %s is readable by group or others (mode %04o); make it owner-only, for example chmod 600", path, perm)
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("push key file %s cannot be read", path)
	}
	block, _ := pem.Decode(data)
	if block == nil || block.Type != "PRIVATE KEY" {
		return nil, fmt.Errorf("push key file %s is not a PKCS#8 PEM private key (.p8)", path)
	}
	raw, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		return nil, fmt.Errorf("push key file %s cannot be parsed", path)
	}
	key, ok := raw.(*ecdsa.PrivateKey)
	if !ok || key.Curve != elliptic.P256() {
		return nil, errors.New("push key must be an ECDSA P-256 key (an APNs .p8)")
	}
	return key, nil
}
