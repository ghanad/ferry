// Package secretbox encrypts small secrets (the optional job passphrase) at
// rest with a key derived from FERRY_SECRET_KEY.
package secretbox

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"fmt"
	"strings"
)

const keyContext = "ferry-job-passphrase-v1:"

// Seal encrypts plaintext and returns a base64 string safe for SQLite.
func Seal(secret, plaintext string) (string, error) {
	if secret == "" {
		return "", errors.New("secret key is empty")
	}
	key := sha256.Sum256([]byte(keyContext + secret))
	block, err := aes.NewCipher(key[:])
	if err != nil {
		return "", err
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return "", err
	}
	nonce := make([]byte, gcm.NonceSize())
	if _, err := rand.Read(nonce); err != nil {
		return "", fmt.Errorf("generate nonce: %w", err)
	}
	sealed := gcm.Seal(nonce, nonce, []byte(plaintext), nil)
	return base64.RawURLEncoding.EncodeToString(sealed), nil
}

// Open decrypts a value produced by Seal.
func Open(secret, encoded string) (string, error) {
	if encoded == "" {
		return "", nil
	}
	if secret == "" {
		return "", errors.New("secret key is empty")
	}
	raw, err := base64.RawURLEncoding.DecodeString(strings.TrimSpace(encoded))
	if err != nil {
		return "", errors.New("stored passphrase is corrupted")
	}
	key := sha256.Sum256([]byte(keyContext + secret))
	block, err := aes.NewCipher(key[:])
	if err != nil {
		return "", err
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return "", err
	}
	if len(raw) < gcm.NonceSize() {
		return "", errors.New("stored passphrase is corrupted")
	}
	nonce, ciphertext := raw[:gcm.NonceSize()], raw[gcm.NonceSize():]
	plaintext, err := gcm.Open(nil, nonce, ciphertext, nil)
	if err != nil {
		return "", errors.New("stored passphrase could not be decrypted; FERRY_SECRET_KEY may have changed")
	}
	return string(plaintext), nil
}
