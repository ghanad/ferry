package imagebuild

import (
	"archive/tar"
	"compress/gzip"
	"context"
	"crypto/md5"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"os"
	"strings"
	"time"

	v1 "github.com/google/go-containerregistry/pkg/v1"
	"github.com/google/go-containerregistry/pkg/v1/tarball"

	"ferry/internal/safename"
	"ferry/internal/securefile"
)

var fixedModTime = time.Date(2020, 1, 1, 0, 0, 0, 0, time.UTC)

// InputFile is one file to pack into the image.
type InputFile struct {
	Name       string
	Path       string
	Size       int64
	SHA256     string
	MD5        string
	Compress   bool
	Encrypt    bool
	Passphrase string
	Mode       int64
}

// preparedFile describes the bytes as they will be stored in the image after
// optional gzip compression and passphrase encryption.
type preparedFile struct {
	InputFile
	StoredName   string
	StoredSize   int64
	StoredSHA256 string
	StoredMD5    string
	PlainSize    int64
	Compress     bool
	Encrypt      bool
	Salt         []byte
	ctx          context.Context
}

func prepareFile(ctx context.Context, f InputFile) (preparedFile, error) {
	if err := ctx.Err(); err != nil {
		return preparedFile{}, err
	}
	name := safename.Sanitize(f.Name)
	if name == "" || name != f.Name || strings.ContainsAny(name, "/\\") {
		return preparedFile{}, fmt.Errorf("unsafe filename %q", f.Name)
	}
	if f.Size < 0 {
		return preparedFile{}, fmt.Errorf("invalid size for %q", f.Name)
	}
	if safename.Reserved(name) {
		return preparedFile{}, fmt.Errorf("filename %q is reserved by Ferry; rename the file", f.Name)
	}
	p := preparedFile{InputFile: f, PlainSize: f.Size, Encrypt: f.Encrypt, ctx: ctx}
	if p.Encrypt && f.Passphrase == "" {
		return preparedFile{}, fmt.Errorf("file %q needs a passphrase but none was provided", name)
	}

	if f.Compress {
		gzSize, err := gzippedSize(ctx, f.Path)
		if err != nil {
			return preparedFile{}, fmt.Errorf("measure compressed size of %q: %w", name, err)
		}
		// Only keep the compressed form when it is actually smaller.
		if gzSize < f.Size {
			p.Compress = true
			p.PlainSize = gzSize
		}
	}

	if p.Encrypt {
		salt, err := securefile.NewSalt()
		if err != nil {
			return preparedFile{}, err
		}
		p.Salt = salt
		p.StoredSize = securefile.EncryptedSize(p.PlainSize)
	} else {
		p.StoredSize = p.PlainSize
	}

	p.StoredName = name
	if p.Compress {
		p.StoredName += ".gz"
	}
	if p.Encrypt {
		p.StoredName += securefile.Suffix
	}

	if err := ctx.Err(); err != nil {
		return preparedFile{}, err
	}
	switch {
	case p.Encrypt || p.Compress:
		sum, md5sum, err := hashStored(p)
		if err != nil {
			return preparedFile{}, fmt.Errorf("hash stored form of %q: %w", name, err)
		}
		p.StoredSHA256 = sum
		p.StoredMD5 = md5sum
	case f.SHA256 != "" && f.MD5 != "":
		p.StoredSHA256 = f.SHA256
		p.StoredMD5 = f.MD5
	default:
		sum, md5sum, err := hashFile(f.Path)
		if err != nil {
			return preparedFile{}, fmt.Errorf("hash %q: %w", name, err)
		}
		p.StoredSHA256 = sum
		p.StoredMD5 = md5sum
	}
	return p, nil
}

// openStored returns the exact bytes that will be placed in the image. The
// gzip and encryption stages run in goroutines connected by pipes, so a
// multi-gigabyte file is never held in memory or copied to a second file.
func openStored(p preparedFile) (io.ReadCloser, error) {
	ctx := p.ctx
	if ctx == nil {
		ctx = context.Background()
	}
	if !p.Compress && !p.Encrypt {
		f, err := os.Open(p.Path)
		if err != nil {
			return nil, err
		}
		return &contextReadCloser{ctx: ctx, file: f}, nil
	}
	file, err := os.Open(p.Path)
	if err != nil {
		return nil, err
	}
	var src io.Reader = file
	var pipes []*io.PipeReader

	if p.Compress {
		pr, pw := io.Pipe()
		pipes = append(pipes, pr)
		go func() {
			zw, err := gzip.NewWriterLevel(pw, gzip.DefaultCompression)
			if err != nil {
				_ = file.Close()
				_ = pw.CloseWithError(err)
				return
			}
			zw.ModTime = fixedModTime
			zw.OS = 255
			_, copyErr := io.Copy(zw, file)
			closeErr := zw.Close()
			_ = file.Close()
			if copyErr != nil {
				_ = pw.CloseWithError(copyErr)
				return
			}
			_ = pw.CloseWithError(closeErr)
		}()
		src = pr
	}

	if p.Encrypt {
		pr, pw := io.Pipe()
		pipes = append(pipes, pr)
		inner := src
		go func() {
			err := securefile.Encrypt(pw, inner, p.Passphrase, p.Salt, p.PlainSize)
			if c, ok := inner.(io.Closer); ok {
				_ = c.Close()
			}
			_ = pw.CloseWithError(err)
		}()
		src = pr
	}

	return &pipelineReader{
		Reader: &contextReader{ctx: ctx, reader: src},
		pipes:  pipes,
		file:   file,
	}, nil
}

// contextReader aborts a long preparation or layer read when the job is
// cancelled or the server shuts down.
type contextReader struct {
	ctx    context.Context
	reader io.Reader
}

func (c *contextReader) Read(b []byte) (int, error) {
	if err := c.ctx.Err(); err != nil {
		return 0, err
	}
	return c.reader.Read(b)
}

type contextReadCloser struct {
	ctx  context.Context
	file *os.File
}

func (c *contextReadCloser) Read(b []byte) (int, error) {
	if err := c.ctx.Err(); err != nil {
		return 0, err
	}
	return c.file.Read(b)
}

func (c *contextReadCloser) Close() error { return c.file.Close() }

type pipelineReader struct {
	io.Reader
	pipes []*io.PipeReader
	file  *os.File
}

func (p *pipelineReader) Close() error {
	for _, pr := range p.pipes {
		_ = pr.Close()
	}
	if p.file != nil {
		_ = p.file.Close()
	}
	return nil
}

func fileLayer(p preparedFile) (v1.Layer, error) {
	mode := p.Mode
	if mode == 0 {
		mode = 0o644
	}
	path := p.Path
	name := p.StoredName
	size := p.StoredSize
	return tarball.LayerFromOpener(
		func() (io.ReadCloser, error) {
			rc, err := openStored(p)
			if err != nil {
				return nil, fmt.Errorf("open %q for image layer: %w", path, err)
			}
			pr, pw := io.Pipe()
			go func() {
				defer rc.Close()
				err := writeStreamTar(pw, name, mode, size, rc)
				_ = pw.CloseWithError(err)
			}()
			return pr, nil
		},
		tarball.WithCompressionLevel(gzip.BestSpeed),
	)
}

func writeStreamTar(w io.Writer, name string, mode int64, size int64, body io.Reader) error {
	tw := tar.NewWriter(w)
	if err := writeDataDir(tw); err != nil {
		return err
	}
	hdr := &tar.Header{
		Name:     "data/" + name,
		Typeflag: tar.TypeReg,
		Mode:     mode,
		Uid:      0,
		Gid:      0,
		Size:     size,
		ModTime:  fixedModTime,
		Format:   tar.FormatPAX,
	}
	if err := tw.WriteHeader(hdr); err != nil {
		return fmt.Errorf("write tar header for %q: %w", name, err)
	}
	written, err := io.Copy(tw, body)
	if err != nil {
		return fmt.Errorf("copy %q into layer: %w", name, err)
	}
	if written != size {
		return fmt.Errorf("file %q changed size while building (expected %d, read %d)", name, size, written)
	}
	if err := tw.Close(); err != nil {
		return fmt.Errorf("close tar for %q: %w", name, err)
	}
	return nil
}

func writeDataDir(tw *tar.Writer) error {
	return tw.WriteHeader(&tar.Header{
		Name:     "data/",
		Typeflag: tar.TypeDir,
		Mode:     0o755,
		Uid:      0,
		Gid:      0,
		ModTime:  fixedModTime,
		Format:   tar.FormatPAX,
	})
}

// sumsLayer writes SHA256SUMS and MD5SUMS for the stored bytes. The hashes were
// computed while preparing each file, so no extra full read is needed here.
func sumsLayer(files []preparedFile) (v1.Layer, error) {
	var shaBuilder, md5Builder strings.Builder
	for _, f := range files {
		if f.StoredSHA256 == "" || f.StoredMD5 == "" {
			return nil, fmt.Errorf("missing checksum for %q", f.StoredName)
		}
		shaBuilder.WriteString(f.StoredSHA256)
		shaBuilder.WriteString("  ")
		shaBuilder.WriteString(f.StoredName)
		shaBuilder.WriteByte('\n')
		md5Builder.WriteString(f.StoredMD5)
		md5Builder.WriteString("  ")
		md5Builder.WriteString(f.StoredName)
		md5Builder.WriteByte('\n')
	}
	entries := []tarEntry{
		{name: "SHA256SUMS", contents: []byte(shaBuilder.String()), mode: 0o644},
		{name: "MD5SUMS", contents: []byte(md5Builder.String()), mode: 0o644},
	}
	return textLayer(entries)
}

type tarEntry struct {
	name     string
	contents []byte
	mode     int64
}

func textLayer(entries []tarEntry) (v1.Layer, error) {
	return tarball.LayerFromOpener(
		func() (io.ReadCloser, error) {
			pr, pw := io.Pipe()
			go func() {
				_ = pw.CloseWithError(writeEntriesTar(pw, entries))
			}()
			return pr, nil
		},
		tarball.WithCompressionLevel(gzip.BestSpeed),
	)
}

func binaryLayer(ctx context.Context, path, name string, mode int64) (v1.Layer, error) {
	st, err := os.Stat(path)
	if err != nil {
		return nil, fmt.Errorf("read %s: %w", path, err)
	}
	if !st.Mode().IsRegular() {
		return nil, fmt.Errorf("%s is not a regular file", path)
	}
	size := st.Size()
	return tarball.LayerFromOpener(
		func() (io.ReadCloser, error) {
			f, err := os.Open(path)
			if err != nil {
				return nil, err
			}
			pr, pw := io.Pipe()
			go func() {
				defer f.Close()
				_ = pw.CloseWithError(writeStreamTar(pw, name, mode, size, &contextReader{ctx: ctx, reader: f}))
			}()
			return pr, nil
		},
		tarball.WithCompressionLevel(gzip.BestSpeed),
	)
}

func writeEntriesTar(w io.Writer, entries []tarEntry) error {
	tw := tar.NewWriter(w)
	if err := writeDataDir(tw); err != nil {
		return err
	}
	for _, entry := range entries {
		mode := entry.mode
		if mode == 0 {
			mode = 0o644
		}
		if err := tw.WriteHeader(&tar.Header{
			Name:     "data/" + entry.name,
			Typeflag: tar.TypeReg,
			Mode:     mode,
			Uid:      0,
			Gid:      0,
			Size:     int64(len(entry.contents)),
			ModTime:  fixedModTime,
			Format:   tar.FormatPAX,
		}); err != nil {
			return err
		}
		if _, err := tw.Write(entry.contents); err != nil {
			return err
		}
	}
	return tw.Close()
}

func hashStored(p preparedFile) (string, string, error) {
	rc, err := openStored(p)
	if err != nil {
		return "", "", err
	}
	defer rc.Close()
	sha := sha256.New()
	md := md5.New()
	if _, err := io.Copy(io.MultiWriter(sha, md), rc); err != nil {
		return "", "", err
	}
	return hex.EncodeToString(sha.Sum(nil)), hex.EncodeToString(md.Sum(nil)), nil
}

func hashFile(path string) (string, string, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", "", err
	}
	defer f.Close()
	sha := sha256.New()
	md := md5.New()
	if _, err := io.Copy(io.MultiWriter(sha, md), f); err != nil {
		return "", "", err
	}
	return hex.EncodeToString(sha.Sum(nil)), hex.EncodeToString(md.Sum(nil)), nil
}

type countWriter struct{ n int64 }

func (c *countWriter) Write(b []byte) (int, error) {
	c.n += int64(len(b))
	return len(b), nil
}

func gzippedSize(ctx context.Context, path string) (int64, error) {
	f, err := os.Open(path)
	if err != nil {
		return 0, err
	}
	defer f.Close()
	cw := &countWriter{}
	zw, err := gzip.NewWriterLevel(cw, gzip.DefaultCompression)
	if err != nil {
		return 0, err
	}
	zw.ModTime = fixedModTime
	zw.OS = 255
	if _, err := io.Copy(zw, &contextReader{ctx: ctx, reader: f}); err != nil {
		return 0, err
	}
	if err := zw.Close(); err != nil {
		return 0, err
	}
	return cw.n, nil
}

// reservedStoredNames are written by Ferry itself and must not be used by a
// user file, even if the file was uploaded before these names were reserved.
var reservedStoredNames = map[string]bool{
	"ferry": true, "SHA256SUMS": true, "MD5SUMS": true,
	"FERRY-MANIFEST.json": true, "README-FERRY.txt": true,
}

// ensureUniqueStoredNames prevents two inputs from mapping to the same path in
// the image (for example "a" compressed to "a.gz" and a plain file "a.gz").
func ensureUniqueStoredNames(files []preparedFile) {
	used := make(map[string]bool, len(reservedStoredNames)+len(files))
	for name := range reservedStoredNames {
		used[name] = true
	}
	for i := range files {
		name := files[i].StoredName
		if !used[name] {
			used[name] = true
			continue
		}
		files[i].StoredName = uniqueStoredName(name, used)
	}
}

func uniqueStoredName(name string, used map[string]bool) string {
	base := name
	ext := ""
	if strings.HasSuffix(base, securefile.Suffix) {
		base = strings.TrimSuffix(base, securefile.Suffix)
		ext = securefile.Suffix + ext
	}
	if strings.HasSuffix(base, ".gz") {
		base = strings.TrimSuffix(base, ".gz")
		ext = ".gz" + ext
	}
	for i := 1; ; i++ {
		candidate := fmt.Sprintf("%s-%d%s", base, i, ext)
		if !used[candidate] {
			used[candidate] = true
			return candidate
		}
	}
}
