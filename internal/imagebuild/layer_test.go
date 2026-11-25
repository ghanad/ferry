package imagebuild

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"context"
	"crypto/md5"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"ferry/internal/securefile"
)

func writeTestFile(t *testing.T, dir, name, contents string) (string, string, int64) {
	t.Helper()
	path := filepath.Join(dir, name)
	if err := os.WriteFile(path, []byte(contents), 0o600); err != nil {
		t.Fatal(err)
	}
	sum := sha256.Sum256([]byte(contents))
	return path, hex.EncodeToString(sum[:]), int64(len(contents))
}

func TestFileLayerContents(t *testing.T) {
	dir := t.TempDir()
	path, sum, size := writeTestFile(t, dir, "hello.txt", "hello layer\n")
	prepared, err := prepareFile(context.Background(), InputFile{Name: "hello.txt", Path: path, Size: size, SHA256: sum})
	if err != nil {
		t.Fatal(err)
	}
	layer, err := fileLayer(prepared)
	if err != nil {
		t.Fatal(err)
	}
	rc, err := layer.Uncompressed()
	if err != nil {
		t.Fatal(err)
	}
	defer rc.Close()
	tr := tar.NewReader(rc)

	dirHeader, err := tr.Next()
	if err != nil {
		t.Fatal(err)
	}
	if dirHeader.Name != "data/" || dirHeader.Typeflag != tar.TypeDir || dirHeader.Mode != 0o755 {
		t.Fatalf("bad directory header: %+v", dirHeader)
	}
	if dirHeader.Uid != 0 || dirHeader.Gid != 0 {
		t.Fatalf("directory owner = %d:%d, want 0:0", dirHeader.Uid, dirHeader.Gid)
	}
	if !dirHeader.ModTime.Equal(fixedModTime) {
		t.Fatalf("directory mtime = %v, want %v", dirHeader.ModTime, fixedModTime)
	}

	fileHeader, err := tr.Next()
	if err != nil {
		t.Fatal(err)
	}
	if fileHeader.Name != "data/hello.txt" || fileHeader.Typeflag != tar.TypeReg || fileHeader.Mode != 0o644 {
		t.Fatalf("bad file header: %+v", fileHeader)
	}
	if fileHeader.Uid != 0 || fileHeader.Gid != 0 {
		t.Fatalf("file owner = %d:%d, want 0:0", fileHeader.Uid, fileHeader.Gid)
	}
	if !fileHeader.ModTime.Equal(fixedModTime) {
		t.Fatalf("file mtime = %v, want %v", fileHeader.ModTime, fixedModTime)
	}
	body, err := io.ReadAll(tr)
	if err != nil {
		t.Fatal(err)
	}
	if string(body) != "hello layer\n" {
		t.Fatalf("body = %q", body)
	}
	if _, err := tr.Next(); err != io.EOF {
		t.Fatalf("expected EOF, got %v", err)
	}
}

func TestSumsLayer(t *testing.T) {
	dir := t.TempDir()
	pathA, sumA, sizeA := writeTestFile(t, dir, "a.txt", "alpha")
	pathB, sumB, sizeB := writeTestFile(t, dir, "b.txt", "beta")
	preparedA, err := prepareFile(context.Background(), InputFile{Name: "a.txt", Path: pathA, Size: sizeA, SHA256: sumA})
	if err != nil {
		t.Fatal(err)
	}
	preparedB, err := prepareFile(context.Background(), InputFile{Name: "b.txt", Path: pathB, Size: sizeB, SHA256: sumB})
	if err != nil {
		t.Fatal(err)
	}
	layer, err := sumsLayer([]preparedFile{preparedA, preparedB})
	if err != nil {
		t.Fatal(err)
	}
	rc, err := layer.Uncompressed()
	if err != nil {
		t.Fatal(err)
	}
	defer rc.Close()
	tr := tar.NewReader(rc)
	if _, err := tr.Next(); err != nil { // data/
		t.Fatal(err)
	}
	hdr, err := tr.Next()
	if err != nil {
		t.Fatal(err)
	}
	if hdr.Name != "data/SHA256SUMS" || hdr.Mode != 0o644 {
		t.Fatalf("bad sums header: %+v", hdr)
	}
	body, err := io.ReadAll(tr)
	if err != nil {
		t.Fatal(err)
	}
	want := sumA + "  a.txt\n" + sumB + "  b.txt\n"
	if string(body) != want {
		t.Fatalf("SHA256SUMS = %q, want %q", body, want)
	}

	md5Header, err := tr.Next()
	if err != nil {
		t.Fatal(err)
	}
	if md5Header.Name != "data/MD5SUMS" || md5Header.Mode != 0o644 {
		t.Fatalf("bad MD5SUMS header: %+v", md5Header)
	}
	md5Body, err := io.ReadAll(tr)
	if err != nil {
		t.Fatal(err)
	}
	alpha := md5.Sum([]byte("alpha"))
	beta := md5.Sum([]byte("beta"))
	wantMD5 := hex.EncodeToString(alpha[:]) + "  a.txt\n" + hex.EncodeToString(beta[:]) + "  b.txt\n"
	if string(md5Body) != wantMD5 {
		t.Fatalf("MD5SUMS = %q, want %q", md5Body, wantMD5)
	}
	if _, err := tr.Next(); err != io.EOF {
		t.Fatalf("expected EOF after MD5SUMS, got %v", err)
	}
}

func TestNewTagFormat(t *testing.T) {
	now := time.Date(2026, 11, 24, 15, 30, 12, 0, time.UTC)
	tag, err := newTag(now)
	if err != nil {
		t.Fatal(err)
	}
	if len(tag) != len("job-20261124-153012-")+4 {
		t.Fatalf("tag %q has unexpected length", tag)
	}
	if !strings.HasPrefix(tag, "job-20261124-153012-") {
		t.Fatalf("tag %q does not start with the timestamp", tag)
	}
	if _, err := hex.DecodeString(tag[len("job-20261124-153012-"):]); err != nil {
		t.Fatalf("tag random suffix is not hex: %q", tag)
	}
}

func TestPrepareCompressedFile(t *testing.T) {
	dir := t.TempDir()
	contents := strings.Repeat("compressible data ", 5000)
	path, sum, size := writeTestFile(t, dir, "big.txt", contents)
	p, err := prepareFile(context.Background(), InputFile{Name: "big.txt", Path: path, Size: size, SHA256: sum, Compress: true})
	if err != nil {
		t.Fatal(err)
	}
	if !p.Compress || p.StoredName != "big.txt.gz" {
		t.Fatalf("prepared = %+v", p)
	}
	if p.StoredSize >= size {
		t.Fatalf("compressed size %d is not smaller than %d", p.StoredSize, size)
	}
	rc, err := openStored(p)
	if err != nil {
		t.Fatal(err)
	}
	defer rc.Close()
	gz, err := gzip.NewReader(rc)
	if err != nil {
		t.Fatal(err)
	}
	got, err := io.ReadAll(gz)
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != contents {
		t.Fatal("decompressed contents do not match")
	}
}

func TestPrepareIncompressibleFileStaysPlain(t *testing.T) {
	dir := t.TempDir()
	data := make([]byte, 4096)
	if _, err := rand.Read(data); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(dir, "random.bin")
	if err := os.WriteFile(path, data, 0o600); err != nil {
		t.Fatal(err)
	}
	p, err := prepareFile(context.Background(), InputFile{Name: "random.bin", Path: path, Size: int64(len(data)), Compress: true})
	if err != nil {
		t.Fatal(err)
	}
	if p.Compress || p.StoredName != "random.bin" {
		t.Fatalf("prepared = %+v", p)
	}
}

func TestPrepareEncryptedFile(t *testing.T) {
	dir := t.TempDir()
	path, sum, size := writeTestFile(t, dir, "secret.txt", "top secret contents")
	p, err := prepareFile(context.Background(), InputFile{
		Name: "secret.txt", Path: path, Size: size, SHA256: sum,
		Encrypt: true, Passphrase: "correct horse battery staple",
	})
	if err != nil {
		t.Fatal(err)
	}
	if !p.Encrypt || p.StoredName != "secret.txt.ferry" {
		t.Fatalf("prepared = %+v", p)
	}
	if p.StoredSize != securefile.EncryptedSize(size) {
		t.Fatalf("stored size = %d", p.StoredSize)
	}
	rc, err := openStored(p)
	if err != nil {
		t.Fatal(err)
	}
	defer rc.Close()
	var out bytes.Buffer
	if _, err := securefile.Decrypt(&out, rc, "correct horse battery staple"); err != nil {
		t.Fatal(err)
	}
	if out.String() != "top secret contents" {
		t.Fatalf("decrypted = %q", out.String())
	}
	if p.StoredSHA256 == "" || p.StoredMD5 == "" {
		t.Fatal("stored hashes were not computed")
	}
}

func TestPrepareEncryptedAndCompressed(t *testing.T) {
	dir := t.TempDir()
	contents := strings.Repeat("abc", 10000)
	path, sum, size := writeTestFile(t, dir, "both.txt", contents)
	p, err := prepareFile(context.Background(), InputFile{
		Name: "both.txt", Path: path, Size: size, SHA256: sum,
		Compress: true, Encrypt: true, Passphrase: "long enough passphrase",
	})
	if err != nil {
		t.Fatal(err)
	}
	if !p.Compress || !p.Encrypt || p.StoredName != "both.txt.gz.ferry" {
		t.Fatalf("prepared = %+v", p)
	}
}

func TestStoredNameCollision(t *testing.T) {
	dir := t.TempDir()
	compressible := strings.Repeat("abc", 2000)
	pathA, sumA, sizeA := writeTestFile(t, dir, "a", compressible)
	random := make([]byte, 4096)
	if _, err := rand.Read(random); err != nil {
		t.Fatal(err)
	}
	pathB := filepath.Join(dir, "a.gz")
	if err := os.WriteFile(pathB, random, 0o600); err != nil {
		t.Fatal(err)
	}
	sumB := sha256.Sum256(random)
	sizeB := int64(len(random))
	prepared := make([]preparedFile, 0, 2)
	for _, input := range []InputFile{
		{Name: "a", Path: pathA, Size: sizeA, SHA256: sumA, Compress: true},
		{Name: "a.gz", Path: pathB, Size: sizeB, SHA256: hex.EncodeToString(sumB[:]), Compress: true},
	} {
		p, err := prepareFile(context.Background(), input)
		if err != nil {
			t.Fatal(err)
		}
		prepared = append(prepared, p)
	}
	ensureUniqueStoredNames(prepared)
	if prepared[0].StoredName == prepared[1].StoredName {
		t.Fatalf("stored names collide: %q", prepared[0].StoredName)
	}
	if prepared[0].StoredName != "a.gz" || prepared[1].StoredName != "a-1.gz" {
		t.Fatalf("unexpected stored names: %q, %q", prepared[0].StoredName, prepared[1].StoredName)
	}
}
