package main

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"io"
	"log"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/google/go-containerregistry/pkg/authn"
	"github.com/google/go-containerregistry/pkg/name"
	"github.com/google/go-containerregistry/pkg/registry"
	v1 "github.com/google/go-containerregistry/pkg/v1"
	"github.com/google/go-containerregistry/pkg/v1/empty"
	"github.com/google/go-containerregistry/pkg/v1/mutate"
	"github.com/google/go-containerregistry/pkg/v1/remote"
	"github.com/google/go-containerregistry/pkg/v1/tarball"

	"ferry/internal/securefile"
)

type imageFile struct {
	name string
	data []byte
	mode int64
}

// tarLayer builds a gzip-compressed layer with data/ entries, matching the
// layout Ferry pushes.
func tarLayer(t *testing.T, files []imageFile) v1.Layer {
	t.Helper()
	var buf bytes.Buffer
	tw := tar.NewWriter(&buf)
	if err := tw.WriteHeader(&tar.Header{Name: "data/", Typeflag: tar.TypeDir, Mode: 0o755}); err != nil {
		t.Fatal(err)
	}
	for _, f := range files {
		mode := f.mode
		if mode == 0 {
			mode = 0o644
		}
		if err := tw.WriteHeader(&tar.Header{
			Name: "data/" + f.name, Typeflag: tar.TypeReg,
			Mode: mode, Size: int64(len(f.data)),
		}); err != nil {
			t.Fatal(err)
		}
		if _, err := tw.Write(f.data); err != nil {
			t.Fatal(err)
		}
	}
	if err := tw.Close(); err != nil {
		t.Fatal(err)
	}
	layer, err := tarball.LayerFromReader(bytes.NewReader(buf.Bytes()))
	if err != nil {
		t.Fatal(err)
	}
	return layer
}

// rawLayer lets a test place arbitrary tar entries in the image.
func rawLayer(t *testing.T, entries []tar.Header, bodies [][]byte) v1.Layer {
	t.Helper()
	var buf bytes.Buffer
	tw := tar.NewWriter(&buf)
	for i, hdr := range entries {
		hdr.Size = int64(len(bodies[i]))
		if err := tw.WriteHeader(&hdr); err != nil {
			t.Fatal(err)
		}
		if _, err := tw.Write(bodies[i]); err != nil {
			t.Fatal(err)
		}
	}
	if err := tw.Close(); err != nil {
		t.Fatal(err)
	}
	layer, err := tarball.LayerFromReader(bytes.NewReader(buf.Bytes()))
	if err != nil {
		t.Fatal(err)
	}
	return layer
}

// pushImage serves an in-memory registry and pushes one image to it, so the
// test never needs a network or a Docker daemon.
func pushImage(t *testing.T, layers ...v1.Layer) name.Reference {
	t.Helper()
	srv := httptest.NewServer(registry.New(registry.Logger(log.New(io.Discard, "", 0))))
	t.Cleanup(srv.Close)
	host := strings.TrimPrefix(srv.URL, "http://")
	ref, err := name.ParseReference(host+"/ferry/test:job-test", name.Insecure)
	if err != nil {
		t.Fatal(err)
	}
	img, err := mutate.AppendLayers(empty.Image, layers...)
	if err != nil {
		t.Fatal(err)
	}
	if err := remote.Write(ref, img, remote.WithAuth(authn.Anonymous)); err != nil {
		t.Fatal(err)
	}
	return ref
}

func shaLine(data []byte, name string) string {
	sum := sha256.Sum256(data)
	return hex.EncodeToString(sum[:]) + "  " + name + "\n"
}

func gzipBytes(t *testing.T, data []byte) []byte {
	t.Helper()
	var buf bytes.Buffer
	zw := gzip.NewWriter(&buf)
	if _, err := zw.Write(data); err != nil {
		t.Fatal(err)
	}
	if err := zw.Close(); err != nil {
		t.Fatal(err)
	}
	return buf.Bytes()
}

func TestDownloadPullsVerifiesAndUnpacks(t *testing.T) {
	plain := []byte("plain notes\n")
	gz := gzipBytes(t, plain)
	salt, err := securefile.NewSalt()
	if err != nil {
		t.Fatal(err)
	}
	var enc bytes.Buffer
	if err := securefile.Encrypt(&enc, bytes.NewReader(plain), "job passphrase", salt, int64(len(plain))); err != nil {
		t.Fatal(err)
	}

	files := []imageFile{
		{name: "notes.txt", data: plain},
		{name: "compressed.txt.gz", data: gz},
		{name: "secret.txt.ferry", data: enc.Bytes()},
		{name: "ferry", data: []byte("not a real binary"), mode: 0o755},
	}
	manifest, err := json.Marshal([]map[string]any{
		{"stored": "notes.txt", "original": "notes.txt", "compressed": false, "encrypted": false},
		{"stored": "compressed.txt.gz", "original": "compressed.txt", "compressed": true, "encrypted": false},
		{"stored": "secret.txt.ferry", "original": "secret.txt", "compressed": false, "encrypted": true},
		{"stored": "ferry", "original": "ferry", "compressed": false, "encrypted": false},
	})
	if err != nil {
		t.Fatal(err)
	}
	sums := shaLine(plain, "notes.txt") + shaLine(gz, "compressed.txt.gz") +
		shaLine(enc.Bytes(), "secret.txt.ferry") + shaLine([]byte("not a real binary"), "ferry")
	files = append(files,
		imageFile{name: "SHA256SUMS", data: []byte(sums)},
		imageFile{name: "FERRY-MANIFEST.json", data: manifest},
	)
	ref := pushImage(t, tarLayer(t, files))

	out := filepath.Join(t.TempDir(), "out")
	if err := downloadCommand([]string{
		"--insecure", "--dir", out, "--passphrase", "job passphrase", ref.Name(),
	}); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"notes.txt", "compressed.txt", "secret.txt"} {
		got, err := os.ReadFile(filepath.Join(out, name))
		if err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		if !bytes.Equal(got, plain) {
			t.Fatalf("%s = %q, want %q", name, got, plain)
		}
	}
	st, err := os.Stat(filepath.Join(out, "ferry"))
	if err != nil {
		t.Fatal(err)
	}
	if st.Mode().Perm()&0o111 == 0 {
		t.Fatalf("ferry mode = %v, want executable", st.Mode().Perm())
	}
}

func TestDownloadRejectsUnsafeImagePath(t *testing.T) {
	layer := rawLayer(t,
		[]tar.Header{{Name: "data/../../evil.txt", Typeflag: tar.TypeReg, Mode: 0o644}},
		[][]byte{[]byte("escaped")},
	)
	ref := pushImage(t, layer)

	parent := t.TempDir()
	out := filepath.Join(parent, "out")
	err := downloadCommand([]string{"--insecure", "--dir", out, ref.Name()})
	if err == nil {
		t.Fatal("expected an unsafe path error")
	}
	if !strings.Contains(err.Error(), "unsafe image path") {
		t.Fatalf("error = %v", err)
	}
	if _, statErr := os.Stat(filepath.Join(parent, "evil.txt")); !os.IsNotExist(statErr) {
		t.Fatalf("file escaped the destination: %v", statErr)
	}
	if _, statErr := os.Stat(out); !os.IsNotExist(statErr) {
		t.Fatalf("output directory should not exist after a failed download: %v", statErr)
	}
}

func TestDownloadRefusesExistingDirectory(t *testing.T) {
	out := t.TempDir()
	err := downloadCommand([]string{"--dir", out, "example.com/ferry/test:job-test"})
	if err == nil || !strings.Contains(err.Error(), "already exists") {
		t.Fatalf("error = %v", err)
	}
}

func TestDownloadRefusesDotDirectory(t *testing.T) {
	for _, dir := range []string{".", "/", ".."} {
		err := downloadCommand([]string{"--dir", dir, "example.com/ferry/test:job-test"})
		if err == nil || !strings.Contains(err.Error(), "refusing") {
			t.Fatalf("--dir %q: error = %v", dir, err)
		}
	}
}

func TestDownloadRejectsBadChecksum(t *testing.T) {
	files := []imageFile{
		{name: "notes.txt", data: []byte("real contents")},
		{name: "SHA256SUMS", data: []byte("deadbeef  notes.txt\n")},
	}
	ref := pushImage(t, tarLayer(t, files))
	err := downloadCommand([]string{"--insecure", "--dir", filepath.Join(t.TempDir(), "out"), ref.Name()})
	if err == nil || !strings.Contains(err.Error(), "checksum mismatch") {
		t.Fatalf("error = %v", err)
	}
}

func TestSafeTarPath(t *testing.T) {
	tests := []struct {
		name string
		want bool
	}{
		{"data/notes.txt", true},
		{"data/", true},
		{"data", true},
		{"data/sub/file.txt", true},
		{"../evil", false},
		{"data/../../evil", false},
		{"/etc/passwd", false},
		{"data\\..\\evil", false},
		{"data//double", false},
		{"", false},
		{"data/./file", false},
	}
	for _, tc := range tests {
		if got := safeTarPath(tc.name); got != tc.want {
			t.Errorf("safeTarPath(%q) = %v, want %v", tc.name, got, tc.want)
		}
	}
}

func TestDefaultOutputDir(t *testing.T) {
	tagRef, err := name.ParseReference("user/ferry:job-20261124-153012-a1b2")
	if err != nil {
		t.Fatal(err)
	}
	if got := defaultOutputDir(tagRef); got != "job-20261124-153012-a1b2" {
		t.Fatalf("tag dir = %q", got)
	}
	digestRef, err := name.ParseReference("user/ferry@sha256:" + strings.Repeat("a", 64))
	if err != nil {
		t.Fatal(err)
	}
	if got := defaultOutputDir(digestRef); got != "sha256-"+strings.Repeat("a", 64) {
		t.Fatalf("digest dir = %q", got)
	}
}
