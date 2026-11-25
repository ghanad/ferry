package securefile

import (
	"bytes"
	"crypto/rand"
	"errors"
	"io"
	"os"
	"path/filepath"
	"testing"
)

func TestRoundTrip(t *testing.T) {
	for _, size := range []int{0, 1, 1024, chunkSize - 1, chunkSize, chunkSize + 1, 3*chunkSize + 7} {
		data := make([]byte, size)
		if _, err := rand.Read(data); err != nil {
			t.Fatal(err)
		}
		salt, err := NewSalt()
		if err != nil {
			t.Fatal(err)
		}
		var encrypted bytes.Buffer
		if err := Encrypt(&encrypted, bytes.NewReader(data), "correct horse battery staple", salt, int64(size)); err != nil {
			t.Fatalf("size %d: encrypt: %v", size, err)
		}
		if got, want := int64(encrypted.Len()), EncryptedSize(int64(size)); got != want {
			t.Fatalf("size %d: encrypted length = %d, want %d", size, got, want)
		}
		var decrypted bytes.Buffer
		n, err := Decrypt(&decrypted, bytes.NewReader(encrypted.Bytes()), "correct horse battery staple")
		if err != nil {
			t.Fatalf("size %d: decrypt: %v", size, err)
		}
		if n != int64(size) || !bytes.Equal(decrypted.Bytes(), data) {
			t.Fatalf("size %d: round trip mismatch (n=%d)", size, n)
		}
	}
}

func TestWrongPassphrase(t *testing.T) {
	salt, _ := NewSalt()
	var encrypted bytes.Buffer
	if err := Encrypt(&encrypted, bytes.NewReader([]byte("secret data")), "right", salt, 11); err != nil {
		t.Fatal(err)
	}
	var out bytes.Buffer
	_, err := Decrypt(&out, bytes.NewReader(encrypted.Bytes()), "wrong")
	if !errors.Is(err, ErrWrongPassphrase) {
		t.Fatalf("error = %v, want ErrWrongPassphrase", err)
	}
}

func TestTruncatedFile(t *testing.T) {
	salt, _ := NewSalt()
	data := bytes.Repeat([]byte("x"), 2*chunkSize)
	var encrypted bytes.Buffer
	if err := Encrypt(&encrypted, bytes.NewReader(data), "pass", salt, int64(len(data))); err != nil {
		t.Fatal(err)
	}
	truncated := encrypted.Bytes()[:encrypted.Len()-10]
	var out bytes.Buffer
	if _, err := Decrypt(&out, bytes.NewReader(truncated), "pass"); err == nil {
		t.Fatal("truncated file decrypted without an error")
	}
}

func TestDeterministicWithSameSalt(t *testing.T) {
	salt, _ := NewSalt()
	data := []byte("same input")
	var a, b bytes.Buffer
	if err := Encrypt(&a, bytes.NewReader(data), "pass", salt, int64(len(data))); err != nil {
		t.Fatal(err)
	}
	if err := Encrypt(&b, bytes.NewReader(data), "pass", salt, int64(len(data))); err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(a.Bytes(), b.Bytes()) {
		t.Fatal("same salt and input produced different ciphertext")
	}
}

func TestIsEncryptedFile(t *testing.T) {
	dir := t.TempDir()
	plain := filepath.Join(dir, "plain.txt")
	if err := os.WriteFile(plain, []byte("hello"), 0o600); err != nil {
		t.Fatal(err)
	}
	ok, err := IsEncryptedFile(plain)
	if err != nil || ok {
		t.Fatalf("plain file: ok=%v err=%v", ok, err)
	}
	salt, _ := NewSalt()
	enc := filepath.Join(dir, "secret.txt.ferry")
	f, err := os.Create(enc)
	if err != nil {
		t.Fatal(err)
	}
	if err := Encrypt(f, bytes.NewReader([]byte("hello")), "pass", salt, 5); err != nil {
		t.Fatal(err)
	}
	if err := f.Close(); err != nil {
		t.Fatal(err)
	}
	ok, err = IsEncryptedFile(enc)
	if err != nil || !ok {
		t.Fatalf("encrypted file: ok=%v err=%v", ok, err)
	}
}

func TestDecryptNotEncrypted(t *testing.T) {
	_, err := Decrypt(io.Discard, bytes.NewReader([]byte("plain text, not encrypted")), "pass")
	if !errors.Is(err, ErrNotEncrypted) {
		t.Fatalf("error = %v, want ErrNotEncrypted", err)
	}
}
