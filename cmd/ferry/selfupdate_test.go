package main

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"ferry/internal/update"
)

type tarEntry struct {
	name     string
	content  string
	mode     int64
	typeflag byte
}

func writeArchive(t *testing.T, entries []tarEntry) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "release.tar.gz")
	file, err := os.Create(path)
	if err != nil {
		t.Fatal(err)
	}
	gz := gzip.NewWriter(file)
	archive := tar.NewWriter(gz)
	for _, entry := range entries {
		mode := entry.mode
		if mode == 0 {
			mode = 0o755
		}
		typeflag := entry.typeflag
		if typeflag == 0 {
			typeflag = tar.TypeReg
		}
		header := &tar.Header{Name: entry.name, Mode: mode, Size: int64(len(entry.content)), Typeflag: typeflag}
		if err := archive.WriteHeader(header); err != nil {
			t.Fatal(err)
		}
		if _, err := archive.Write([]byte(entry.content)); err != nil {
			t.Fatal(err)
		}
	}
	if err := archive.Close(); err != nil {
		t.Fatal(err)
	}
	if err := gz.Close(); err != nil {
		t.Fatal(err)
	}
	if err := file.Close(); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestExtractFerryBinary(t *testing.T) {
	archive := writeArchive(t, []tarEntry{
		{name: "./README.md", content: "readme"},
		{name: "./ferry", content: "binary-data"},
		{name: "./deploy/install.sh", content: "script"},
	})
	dest := filepath.Join(t.TempDir(), "ferry")
	if err := extractFerryBinary(archive, dest); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(dest)
	if err != nil {
		t.Fatal(err)
	}
	if string(data) != "binary-data" {
		t.Errorf("binary = %q", data)
	}
	info, err := os.Stat(dest)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0o755 {
		t.Errorf("mode = %o, want 0755", info.Mode().Perm())
	}
}

func TestExtractFerryBinaryMissing(t *testing.T) {
	archive := writeArchive(t, []tarEntry{{name: "./README.md", content: "readme"}})
	if err := extractFerryBinary(archive, filepath.Join(t.TempDir(), "ferry")); err == nil {
		t.Fatal("expected an error when the archive has no ferry binary")
	}
}

func TestExtractFerryBinaryRejectsNonRegular(t *testing.T) {
	archive := writeArchive(t, []tarEntry{{name: "./ferry", typeflag: tar.TypeSymlink}})
	if err := extractFerryBinary(archive, filepath.Join(t.TempDir(), "ferry")); err == nil {
		t.Fatal("expected an error for a non-regular ferry entry")
	}
}

func TestReadChecksum(t *testing.T) {
	sum := strings.Repeat("a", 64)
	tests := []struct {
		name    string
		content string
		asset   string
		want    string
		wantErr bool
	}{
		{name: "standard", content: sum + "  ferry.tar.gz\n", asset: "ferry.tar.gz", want: sum},
		{name: "uppercase and binary marker", content: strings.ToUpper(sum) + " *ferry.tar.gz\n", asset: "ferry.tar.gz", want: sum},
		{name: "hash only", content: sum + "\n", asset: "ferry.tar.gz", want: sum},
		{name: "wrong file", content: sum + "  other.tar.gz\n", asset: "ferry.tar.gz", wantErr: true},
		{name: "empty", content: "", asset: "ferry.tar.gz", wantErr: true},
		{name: "too short", content: "abc  ferry.tar.gz\n", asset: "ferry.tar.gz", wantErr: true},
		{name: "not hex", content: strings.Repeat("z", 64) + "  ferry.tar.gz\n", asset: "ferry.tar.gz", wantErr: true},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			path := filepath.Join(t.TempDir(), "checksum")
			if err := os.WriteFile(path, []byte(test.content), 0o600); err != nil {
				t.Fatal(err)
			}
			got, err := readChecksum(path, test.asset)
			if test.wantErr {
				if err == nil {
					t.Fatalf("expected an error, got %q", got)
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			if got != test.want {
				t.Errorf("checksum = %q, want %q", got, test.want)
			}
		})
	}
}

func TestReplaceBinary(t *testing.T) {
	dir := t.TempDir()
	dest := filepath.Join(dir, "ferry")
	if err := os.WriteFile(dest, []byte("old"), 0o755); err != nil {
		t.Fatal(err)
	}
	src := filepath.Join(t.TempDir(), "new")
	if err := os.WriteFile(src, []byte("new"), 0o755); err != nil {
		t.Fatal(err)
	}

	if err := replaceBinary(src, dest); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(dest)
	if err != nil {
		t.Fatal(err)
	}
	if string(data) != "new" {
		t.Errorf("binary = %q, want %q", data, "new")
	}
	info, err := os.Stat(dest)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0o755 {
		t.Errorf("mode = %o, want 0755", info.Mode().Perm())
	}
	leftovers, err := filepath.Glob(filepath.Join(dir, ".ferry-update-*"))
	if err != nil {
		t.Fatal(err)
	}
	if len(leftovers) != 0 {
		t.Errorf("temporary files left behind: %v", leftovers)
	}
}

func newReleaseChecker(t *testing.T, tag string) *update.Checker {
	t.Helper()
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`{"tag_name":"` + tag + `","html_url":"https://example.test/release"}`))
	}))
	t.Cleanup(server.Close)
	checker := update.New("")
	checker.APIBase = server.URL
	return checker
}

func TestRunSelfUpdateAlreadyCurrent(t *testing.T) {
	var out bytes.Buffer
	err := runSelfUpdate(context.Background(), &out, "v1.0.0", newReleaseChecker(t, "v1.0.0"), false, false)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(out.String(), "already up to date") {
		t.Errorf("output = %q", out.String())
	}
}

func TestRunSelfUpdateNewerBuild(t *testing.T) {
	var out bytes.Buffer
	err := runSelfUpdate(context.Background(), &out, "v2.0.0", newReleaseChecker(t, "v1.0.0"), false, false)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(out.String(), "newer than the latest release") {
		t.Errorf("output = %q", out.String())
	}
}

func TestRunSelfUpdateMissingAsset(t *testing.T) {
	var out bytes.Buffer
	err := runSelfUpdate(context.Background(), &out, "v0.9.0", newReleaseChecker(t, "v1.0.0"), false, false)
	if err == nil || !strings.Contains(err.Error(), "no asset named") {
		t.Fatalf("error = %v, want a missing-asset error", err)
	}
}
