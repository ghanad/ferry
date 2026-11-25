package main

import (
	"archive/tar"
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"

	"github.com/google/go-containerregistry/pkg/authn"
	"github.com/google/go-containerregistry/pkg/name"
	v1 "github.com/google/go-containerregistry/pkg/v1"
	"github.com/google/go-containerregistry/pkg/v1/remote"
)

// downloadCommand pulls a Ferry image straight from a registry and extracts its
// /data directory into a local folder. It needs no Docker daemon, CLI, or
// socket: layers are streamed with go-containerregistry and only data/ entries
// are written to disk.
func downloadCommand(args []string) error {
	fs := flag.NewFlagSet("download", flag.ContinueOnError)
	fs.SetOutput(os.Stderr)
	var (
		dir        = fs.String("dir", "", "output directory (default: the image tag)")
		passphrase = fs.String("passphrase", "", "job passphrase (prompted when needed)")
		force      = fs.Bool("force", false, "replace an existing output directory")
		verifyOnly = fs.Bool("verify-only", false, "only verify checksums, do not unpack")
		platform   = fs.String("platform", "linux/amd64", "platform to select from a multi-platform image")
		username   = fs.String("username", "", "registry username (default: DOCKERHUB_USERNAME, then the Docker config)")
		password   = fs.String("password", "", "registry password or token (default: DOCKERHUB_TOKEN, then the Docker config)")
		insecure   = fs.Bool("insecure", false, "allow a plain-HTTP registry (local testing only)")
	)
	if err := fs.Parse(args); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			return nil
		}
		return err
	}
	if fs.NArg() != 1 {
		return errors.New("usage: ferry download [flags] <image>")
	}

	var refOpts []name.Option
	if *insecure {
		refOpts = append(refOpts, name.Insecure)
	}
	ref, err := name.ParseReference(fs.Arg(0), refOpts...)
	if err != nil {
		return fmt.Errorf("invalid image reference %q: %w", fs.Arg(0), err)
	}
	plat, err := v1.ParsePlatform(*platform)
	if err != nil {
		return fmt.Errorf("invalid --platform %q: %w", *platform, err)
	}

	outDir := *dir
	if outDir == "" {
		outDir = defaultOutputDir(ref)
	}
	absOut, err := filepath.Abs(filepath.Clean(outDir))
	if err != nil {
		return fmt.Errorf("resolve %q: %w", outDir, err)
	}
	cwd, err := os.Getwd()
	if err != nil {
		return err
	}
	// A replacement must never remove the working directory or one of its
	// parents (for example --dir . or --dir .. with --force).
	if filepath.Dir(absOut) == absOut || absOut == cwd ||
		strings.HasPrefix(cwd, absOut+string(filepath.Separator)) {
		return fmt.Errorf("refusing to use %q as the output directory", outDir)
	}
	if _, err := os.Stat(outDir); err == nil {
		if !*force {
			return fmt.Errorf("output directory %q already exists; use --force to replace it", outDir)
		}
	} else if !os.IsNotExist(err) {
		return err
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	remoteOpts := []remote.Option{
		remote.WithContext(ctx),
		remote.WithPlatform(*plat),
		remote.WithUserAgent("ferry/" + version),
	}
	user, pass := *username, *password
	if user == "" {
		user = os.Getenv("DOCKERHUB_USERNAME")
	}
	if pass == "" {
		pass = os.Getenv("DOCKERHUB_TOKEN")
	}
	switch {
	case user != "" || pass != "":
		if user == "" || pass == "" {
			return errors.New("both --username and --password (or DOCKERHUB_USERNAME and DOCKERHUB_TOKEN) are required")
		}
		remoteOpts = append(remoteOpts, remote.WithAuth(&authn.Basic{Username: user, Password: pass}))
	default:
		remoteOpts = append(remoteOpts, remote.WithAuthFromKeychain(authn.DefaultKeychain))
	}

	fmt.Printf("Pulling %s (%s)...\n", ref.Name(), plat.String())
	img, err := remote.Image(ref, remoteOpts...)
	if err != nil {
		return fmt.Errorf("pull %s: %w%s", ref.Name(), err, authHint(err))
	}
	if digest, err := img.Digest(); err == nil {
		fmt.Printf("Image digest: %s\n", digest)
	}

	parent := filepath.Dir(outDir)
	if err := os.MkdirAll(parent, 0o755); err != nil {
		return fmt.Errorf("create %s: %w", parent, err)
	}
	tmpDir, err := os.MkdirTemp(parent, ".ferry-download-*")
	if err != nil {
		return fmt.Errorf("create temporary directory: %w", err)
	}
	// After a successful rename this removes nothing.
	defer os.RemoveAll(tmpDir)

	extracted, err := extractImageData(ctx, img, tmpDir)
	if err != nil {
		return err
	}
	if extracted == 0 {
		return fmt.Errorf("image %s contains no Ferry files under /data", ref.Name())
	}
	fmt.Printf("Extracted %d file(s).\n", extracted)

	if err := runUnpack(unpackOptions{
		Dir:        tmpDir,
		Passphrase: *passphrase,
		VerifyOnly: *verifyOnly,
	}); err != nil {
		return err
	}

	// MkdirTemp creates 0700; the delivered folder should be readable like a
	// normal extraction directory.
	if err := os.Chmod(tmpDir, 0o755); err != nil {
		return fmt.Errorf("set mode of %s: %w", outDir, err)
	}
	if *force {
		if err := os.RemoveAll(outDir); err != nil {
			return fmt.Errorf("replace %s: %w", outDir, err)
		}
	}
	if err := os.Rename(tmpDir, outDir); err != nil {
		return fmt.Errorf("move files to %s: %w", outDir, err)
	}
	fmt.Printf("Files are in %s\n", outDir)
	return nil
}

// defaultOutputDir names the destination after the image tag (or digest), so
// two jobs never overwrite each other by accident.
func defaultOutputDir(ref name.Reference) string {
	return strings.ReplaceAll(ref.Identifier(), ":", "-")
}

// authHint turns a registry authorization failure into an actionable message
// without ever printing the credentials.
func authHint(err error) string {
	msg := err.Error()
	if strings.Contains(msg, "401") || strings.Contains(msg, "403") ||
		strings.Contains(msg, "UNAUTHORIZED") || strings.Contains(msg, "DENIED") {
		return " (private image? pass --username and --password, set DOCKERHUB_USERNAME and DOCKERHUB_TOKEN, or run docker login first)"
	}
	return ""
}

// extractImageData streams every layer and writes its data/ entries into dest.
// Only regular files directly under data/ are accepted; anything else is
// ignored (base-image files) or rejected (unsafe paths, links).
func extractImageData(ctx context.Context, img v1.Image, dest string) (int, error) {
	layers, err := img.Layers()
	if err != nil {
		return 0, fmt.Errorf("read image layers: %w", err)
	}
	fmt.Printf("Extracting %d layer(s)...\n", len(layers))
	total := 0
	for i, layer := range layers {
		if err := ctx.Err(); err != nil {
			return total, err
		}
		rc, err := layer.Uncompressed()
		if err != nil {
			return total, fmt.Errorf("open layer %d: %w", i+1, err)
		}
		n, extractErr := extractDataTar(ctx, rc, dest)
		closeErr := rc.Close()
		if extractErr != nil {
			return total, fmt.Errorf("layer %d: %w", i+1, extractErr)
		}
		if closeErr != nil {
			return total, fmt.Errorf("layer %d: %w", i+1, closeErr)
		}
		total += n
	}
	return total, nil
}

func extractDataTar(ctx context.Context, r io.Reader, dest string) (int, error) {
	tr := tar.NewReader(r)
	written := 0
	for {
		if err := ctx.Err(); err != nil {
			return written, err
		}
		hdr, err := tr.Next()
		if errors.Is(err, io.EOF) {
			return written, nil
		}
		if err != nil {
			return written, err
		}
		name := strings.TrimSuffix(hdr.Name, "/")
		// Base-image files are irrelevant; only validate paths that claim to
		// live under data/.
		if name != "data" && !strings.HasPrefix(name, "data/") {
			continue
		}
		if !safeTarPath(hdr.Name) {
			return written, fmt.Errorf("refusing unsafe image path %q", hdr.Name)
		}
		if name == "data" {
			continue
		}
		if hdr.Typeflag == tar.TypeDir {
			continue
		}
		if hdr.Typeflag != tar.TypeReg {
			return written, fmt.Errorf("unsupported image entry %q (type %q)", hdr.Name, hdr.Typeflag)
		}
		rel := strings.TrimPrefix(name, "data/")
		if rel == "" || strings.Contains(rel, "/") {
			return written, fmt.Errorf("unexpected nested image path %q", hdr.Name)
		}
		if err := writeExtractedFile(dest, rel, hdr, ctxReader{ctx: ctx, r: tr}); err != nil {
			return written, err
		}
		written++
	}
}

// safeTarPath accepts only relative, forward-slash paths with no empty or
// parent components. It runs before any path is joined with the destination.
func safeTarPath(name string) bool {
	if name == "" || strings.Contains(name, "\\") || strings.HasPrefix(name, "/") {
		return false
	}
	for _, part := range strings.Split(strings.TrimSuffix(name, "/"), "/") {
		if part == "" || part == "." || part == ".." {
			return false
		}
	}
	return true
}

// ctxReader aborts a long extraction when the user presses Ctrl-C.
type ctxReader struct {
	ctx context.Context
	r   io.Reader
}

func (c ctxReader) Read(p []byte) (int, error) {
	if err := c.ctx.Err(); err != nil {
		return 0, err
	}
	return c.r.Read(p)
}

func writeExtractedFile(dest, name string, hdr *tar.Header, r io.Reader) error {
	perm := os.FileMode(hdr.Mode).Perm()
	if perm&0o111 != 0 {
		perm = 0o755
	} else {
		perm = 0o644
	}
	finalPath := filepath.Join(dest, name)
	f, err := os.OpenFile(finalPath, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, perm)
	if err != nil {
		return fmt.Errorf("create %s: %w", name, err)
	}
	if _, err := io.Copy(f, r); err != nil {
		_ = f.Close()
		return fmt.Errorf("write %s: %w", name, err)
	}
	if err := f.Close(); err != nil {
		return fmt.Errorf("write %s: %w", name, err)
	}
	if err := os.Chmod(finalPath, perm); err != nil {
		return fmt.Errorf("set mode of %s: %w", name, err)
	}
	return nil
}
