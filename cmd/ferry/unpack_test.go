package main

import (
	"bytes"
	"compress/gzip"
	"crypto/sha256"
	"encoding/hex"
	"os"
	"path/filepath"
	"testing"

	"ferry/internal/securefile"
)

func writeStored(t *testing.T, dir, name string, data []byte) string {
	t.Helper()
	path := filepath.Join(dir, name)
	if err := os.WriteFile(path, data, 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}

func checksumLine(t *testing.T, path, name string) string {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	sum := sha256.Sum256(data)
	return hex.EncodeToString(sum[:]) + "  " + name + "\n"
}

func TestUnpackDecryptsAndDecompresses(t *testing.T) {
	dir := t.TempDir()
	plain := []byte("hello from the ferry image\n")

	// Compressed file.
	var gz bytes.Buffer
	zw := gzip.NewWriter(&gz)
	if _, err := zw.Write(plain); err != nil {
		t.Fatal(err)
	}
	if err := zw.Close(); err != nil {
		t.Fatal(err)
	}
	gzPath := writeStored(t, dir, "notes.txt.gz", gz.Bytes())

	// Encrypted file.
	salt, err := securefile.NewSalt()
	if err != nil {
		t.Fatal(err)
	}
	var enc bytes.Buffer
	if err := securefile.Encrypt(&enc, bytes.NewReader(plain), "correct horse battery staple", salt, int64(len(plain))); err != nil {
		t.Fatal(err)
	}
	encPath := writeStored(t, dir, "secret.txt.ferry", enc.Bytes())

	// Encrypted + compressed file.
	var gz2 bytes.Buffer
	zw2 := gzip.NewWriter(&gz2)
	if _, err := zw2.Write(plain); err != nil {
		t.Fatal(err)
	}
	if err := zw2.Close(); err != nil {
		t.Fatal(err)
	}
	salt2, _ := securefile.NewSalt()
	var enc2 bytes.Buffer
	if err := securefile.Encrypt(&enc2, bytes.NewReader(gz2.Bytes()), "correct horse battery staple", salt2, int64(gz2.Len())); err != nil {
		t.Fatal(err)
	}
	bothPath := writeStored(t, dir, "both.txt.gz.ferry", enc2.Bytes())

	sums := checksumLine(t, gzPath, "notes.txt.gz") +
		checksumLine(t, encPath, "secret.txt.ferry") +
		checksumLine(t, bothPath, "both.txt.gz.ferry")
	writeStored(t, dir, "SHA256SUMS", []byte(sums))

	if err := unpackCommand([]string{"--dir", dir, "--passphrase", "correct horse battery staple"}); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"notes.txt", "secret.txt", "both.txt"} {
		got, err := os.ReadFile(filepath.Join(dir, name))
		if err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		if !bytes.Equal(got, plain) {
			t.Fatalf("%s = %q", name, got)
		}
	}
}

func TestUnpackRejectsBadChecksum(t *testing.T) {
	dir := t.TempDir()
	path := writeStored(t, dir, "file.txt.gz", []byte("not really gzip"))
	writeStored(t, dir, "SHA256SUMS", []byte("deadbeef  file.txt.gz\n"))
	err := unpackCommand([]string{"--dir", dir, "--verify-only"})
	if err == nil {
		t.Fatal("expected a checksum mismatch error")
	}
	_ = path
}

func TestUnpackWrongPassphrase(t *testing.T) {
	dir := t.TempDir()
	salt, _ := securefile.NewSalt()
	var enc bytes.Buffer
	if err := securefile.Encrypt(&enc, bytes.NewReader([]byte("data")), "right passphrase", salt, 4); err != nil {
		t.Fatal(err)
	}
	path := writeStored(t, dir, "data.bin.ferry", enc.Bytes())
	writeStored(t, dir, "SHA256SUMS", []byte(checksumLine(t, path, "data.bin.ferry")))
	if err := unpackCommand([]string{"--dir", dir, "--passphrase", "wrong passphrase"}); err == nil {
		t.Fatal("expected an error with the wrong passphrase")
	}
}

func TestUnpackUsesManifestAndSkipsPlainLookalike(t *testing.T) {
	dir := t.TempDir()
	// A plain file whose name ends in .gz must not be treated as compressed.
	plainLookalike := []byte("this is not gzip data")
	writeStored(t, dir, "notes.gz", plainLookalike)

	// A genuinely compressed file described by the manifest.
	original := []byte("real contents")
	var gz bytes.Buffer
	zw := gzip.NewWriter(&gz)
	if _, err := zw.Write(original); err != nil {
		t.Fatal(err)
	}
	if err := zw.Close(); err != nil {
		t.Fatal(err)
	}
	gzPath := writeStored(t, dir, "stored.bin", gz.Bytes())

	manifest := `[
  {"stored":"notes.gz","original":"notes.gz","compressed":false,"encrypted":false},
  {"stored":"stored.bin","original":"real.txt","compressed":true,"encrypted":false}
]`
	writeStored(t, dir, "FERRY-MANIFEST.json", []byte(manifest))
	writeStored(t, dir, "SHA256SUMS", []byte(checksumLine(t, gzPath, "stored.bin")))

	if err := unpackCommand([]string{"--dir", dir}); err != nil {
		t.Fatal(err)
	}
	got, err := os.ReadFile(filepath.Join(dir, "real.txt"))
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(got, original) {
		t.Fatalf("real.txt = %q", got)
	}
	// The plain lookalike must be untouched.
	got, err = os.ReadFile(filepath.Join(dir, "notes.gz"))
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(got, plainLookalike) {
		t.Fatalf("notes.gz was modified: %q", got)
	}
}

func TestUnpackRenamedPlainFile(t *testing.T) {
	dir := t.TempDir()
	contents := []byte("plain but renamed")
	storedPath := writeStored(t, dir, "renamed-1.bin", contents)
	manifest := `[
  {"stored":"renamed-1.bin","original":"renamed.bin","compressed":false,"encrypted":false}
]`
	writeStored(t, dir, "FERRY-MANIFEST.json", []byte(manifest))
	writeStored(t, dir, "SHA256SUMS", []byte(checksumLine(t, storedPath, "renamed-1.bin")))
	if err := unpackCommand([]string{"--dir", dir}); err != nil {
		t.Fatal(err)
	}
	got, err := os.ReadFile(filepath.Join(dir, "renamed.bin"))
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(got, contents) {
		t.Fatalf("renamed.bin = %q", got)
	}
}
