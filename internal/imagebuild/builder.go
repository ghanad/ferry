// Package imagebuild creates an image layer-by-layer and pushes it to Docker Hub.
package imagebuild

import (
	"context"
	"crypto/rand"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/url"
	"os"
	"runtime"
	"strings"
	"syscall"
	"time"

	"github.com/google/go-containerregistry/pkg/authn"
	"github.com/google/go-containerregistry/pkg/name"
	v1 "github.com/google/go-containerregistry/pkg/v1"
	"github.com/google/go-containerregistry/pkg/v1/mutate"
	"github.com/google/go-containerregistry/pkg/v1/remote"
)

const (
	baseImage       = "busybox:stable"
	maxPushAttempts = 3
	pushBackoff     = 5 * time.Second
)

// Options controls optional compression and passphrase encryption for a job.
type Options struct {
	Compress   bool
	Passphrase string
	// OnTag is called with the final image name just before the push starts.
	// The caller can persist it so a crash mid-push still leaves a record for
	// Docker Hub cleanup.
	OnTag func(string)
}

// Builder packs files onto busybox and pushes the result.
type Builder struct {
	platform v1.Platform
	username string
	token    string
	repo     string
}

// New validates the target platform and Docker Hub settings.
func New(username, token, repo, platform string) (*Builder, error) {
	p, err := v1.ParsePlatform(platform)
	if err != nil {
		return nil, fmt.Errorf("invalid FERRY_PLATFORM %q: %w", platform, err)
	}
	if p.OS == "" || p.Architecture == "" {
		return nil, fmt.Errorf("invalid FERRY_PLATFORM %q", platform)
	}
	if username == "" || token == "" || repo == "" {
		return nil, errors.New("Docker Hub username, token and repository are required")
	}
	return &Builder{
		platform: *p,
		username: username,
		token:    token,
		repo:     repo,
	}, nil
}

// BuildAndPush creates the image and pushes it. phase is called with
// "pushing" immediately before bytes start going to the registry. logf must
// never receive the Docker Hub token.
func (b *Builder) BuildAndPush(
	ctx context.Context,
	files []InputFile,
	opts Options,
	logf func(string),
	phase func(string),
	progress func(v1.Update),
) (string, error) {
	if len(files) == 0 {
		return "", errors.New("no files to pack")
	}
	if (opts.Compress || opts.Passphrase != "") &&
		(runtime.GOOS != "linux" || b.platform.OS != "linux" || b.platform.Architecture != runtime.GOARCH) {
		return "", fmt.Errorf("compression and passphrase encryption require Ferry to run on Linux with FERRY_PLATFORM matching its architecture: FERRY_PLATFORM is %s/%s but this Ferry binary runs on %s/%s. On the Linux server set FERRY_PLATFORM=linux/%s, or disable compression/encryption",
			b.platform.OS, b.platform.Architecture, runtime.GOOS, runtime.GOARCH, runtime.GOARCH)
	}
	if logf == nil {
		logf = func(string) {}
	}
	if phase == nil {
		phase = func(string) {}
	}

	tag, err := newTag(time.Now())
	if err != nil {
		return "", err
	}
	displayName := fmt.Sprintf("%s/%s:%s", strings.ToLower(b.username), b.repo, tag)
	ref, err := name.ParseReference(displayName)
	if err != nil {
		return "", fmt.Errorf("build image reference: %w", err)
	}
	auth := &authn.Basic{Username: b.username, Password: b.token}
	remoteCtx := remote.WithContext(ctx)
	remoteAuth := remote.WithAuth(auth)

	logf(fmt.Sprintf("Pulling base image %s for %s/%s", baseImage, b.platform.OS, b.platform.Architecture))
	baseRef, err := name.ParseReference(baseImage)
	if err != nil {
		return "", fmt.Errorf("parse base image: %w", err)
	}
	base, err := remote.Image(baseRef,
		remoteCtx,
		remoteAuth,
		remote.WithPlatform(b.platform),
		remote.WithUserAgent("ferry/1.0"),
	)
	if err != nil {
		return "", redact(fmt.Errorf("pull %s: %w", baseImage, err), b.token)
	}

	prepared := make([]preparedFile, 0, len(files))
	for _, f := range files {
		if err := ctx.Err(); err != nil {
			return "", errors.New("cancelled")
		}
		p, err := prepareFile(ctx, f)
		if err != nil {
			return "", err
		}
		prepared = append(prepared, p)
		if p.Compress || p.Encrypt {
			extras := make([]string, 0, 2)
			if p.Compress {
				extras = append(extras, "compressed")
			}
			if p.Encrypt {
				extras = append(extras, "encrypted")
			}
			logf(fmt.Sprintf("Prepared %s as %s (%s)", p.Name, p.StoredName, strings.Join(extras, ", ")))
		}
	}

	ensureUniqueStoredNames(prepared)
	layers := make([]v1.Layer, 0, len(prepared)+4)
	for _, f := range prepared {
		if err := ctx.Err(); err != nil {
			return "", errors.New("cancelled")
		}
		layer, err := fileLayer(f)
		if err != nil {
			return "", err
		}
		layers = append(layers, layer)
	}
	logf(fmt.Sprintf("Creating SHA256SUMS and MD5SUMS for %d files", len(prepared)))
	sumLayer, err := sumsLayer(prepared)
	if err != nil {
		return "", err
	}
	layers = append(layers, sumLayer)

	manifest, err := manifestLayer(prepared)
	if err != nil {
		return "", err
	}
	layers = append(layers, manifest)

	if opts.Compress || opts.Passphrase != "" {
		// The destination needs a tool that can decrypt and decompress. Ferry
		// itself is a static binary, so ship a copy plus short instructions.
		exe, err := os.Executable()
		if err != nil {
			return "", fmt.Errorf("locate the ferry binary for the image: %w", err)
		}
		logf("Adding the ferry unpack tool and README to the image")
		toolLayer, err := binaryLayer(ctx, exe, "ferry", 0o755)
		if err != nil {
			return "", err
		}
		layers = append(layers, toolLayer)
		readmeLayer, err := textLayer([]tarEntry{
			{name: "README-FERRY.txt", contents: []byte(unpackReadme(opts)), mode: 0o644},
		})
		if err != nil {
			return "", err
		}
		layers = append(layers, readmeLayer)
	}

	img, err := mutate.AppendLayers(base, layers...)
	if err != nil {
		return "", fmt.Errorf("append layers: %w", err)
	}
	img, err = mutate.Config(img, v1.Config{
		WorkingDir: "/data",
		Cmd:        []string{"sh"},
	})
	if err != nil {
		return "", fmt.Errorf("set image config: %w", err)
	}
	img, err = mutate.CreatedAt(img, v1.Time{Time: time.Now().UTC()})
	if err != nil {
		return "", fmt.Errorf("set image creation time: %w", err)
	}

	if opts.OnTag != nil {
		opts.OnTag(displayName)
	}
	phase("pushing")
	var lastErr error
	for attempt := 1; attempt <= maxPushAttempts; attempt++ {
		if err := ctx.Err(); err != nil {
			return displayName, errors.New("push cancelled")
		}
		logf(fmt.Sprintf("Pushing %s (attempt %d of %d)", displayName, attempt, maxPushAttempts))
		// remote.Write closes the progress channel, so every attempt gets a
		// fresh channel and a drain goroutine that runs until that close.
		updates := make(chan v1.Update, 128)
		progressDone := make(chan struct{})
		go func() {
			defer close(progressDone)
			for u := range updates {
				if progress != nil {
					progress(u)
				}
			}
		}()
		err = remote.Write(ref, img,
			remoteCtx,
			remoteAuth,
			remote.WithJobs(2),
			remote.WithProgress(updates),
			remote.WithUserAgent("ferry/1.0"),
		)
		<-progressDone
		if err == nil {
			lastErr = nil
			break
		}
		lastErr = redact(err, b.token)
		if !isRetryablePushError(err) || attempt == maxPushAttempts {
			break
		}
		logf(fmt.Sprintf("Push attempt %d failed (%v); retrying in %s", attempt, lastErr, pushBackoff))
		timer := time.NewTimer(pushBackoff)
		select {
		case <-ctx.Done():
			timer.Stop()
			return displayName, errors.New("push cancelled")
		case <-timer.C:
		}
	}
	if lastErr != nil {
		return displayName, fmt.Errorf("push image: %w", lastErr)
	}

	logf("Verifying that the pushed tag is visible in Docker Hub")
	digest, err := img.Digest()
	if err != nil {
		return displayName, fmt.Errorf("compute image digest: %w", err)
	}
	var desc *v1.Descriptor
	for attempt := 1; attempt <= 3; attempt++ {
		desc, err = remote.Head(ref, remoteCtx, remoteAuth, remote.WithUserAgent("ferry/1.0"))
		if err == nil {
			break
		}
		if attempt < 3 {
			timer := time.NewTimer(2 * time.Second)
			select {
			case <-ctx.Done():
				timer.Stop()
				return displayName, errors.New("push cancelled")
			case <-timer.C:
			}
		}
	}
	if err != nil {
		return displayName, redact(fmt.Errorf("verify pushed tag: %w", err), b.token)
	}
	if desc == nil {
		return displayName, errors.New("verify pushed tag: Docker Hub returned no descriptor")
	}
	if desc.Digest != digest {
		return displayName, fmt.Errorf("verify pushed tag: Docker Hub digest %s does not match built image %s", desc.Digest, digest)
	}
	logf("Push verified: Docker Hub reports the expected manifest digest")
	return displayName, nil
}

type manifestEntry struct {
	Stored     string `json:"stored"`
	Original   string `json:"original"`
	Compressed bool   `json:"compressed"`
	Encrypted  bool   `json:"encrypted"`
}

// manifestLayer records the original name and transforms of every stored file.
// Without it, a plain file whose name ends in .gz or .ferry would be mistaken
// for a packed file during unpacking.
func manifestLayer(files []preparedFile) (v1.Layer, error) {
	entries := make([]manifestEntry, 0, len(files))
	for _, f := range files {
		entries = append(entries, manifestEntry{
			Stored:     f.StoredName,
			Original:   f.Name,
			Compressed: f.Compress,
			Encrypted:  f.Encrypt,
		})
	}
	contents, err := json.MarshalIndent(entries, "", "  ")
	if err != nil {
		return nil, fmt.Errorf("build image manifest: %w", err)
	}
	contents = append(contents, '\n')
	return textLayer([]tarEntry{
		{name: "FERRY-MANIFEST.json", contents: contents, mode: 0o644},
	})
}

func unpackReadme(opts Options) string {
	var b strings.Builder
	b.WriteString("Ferry image\n")
	b.WriteString("===========\n\n")
	b.WriteString("Some files in this image are stored in a packed form:\n")
	if opts.Compress {
		b.WriteString("  *.gz      gzip-compressed files\n")
	}
	if opts.Passphrase != "" {
		b.WriteString("  *.ferry   files encrypted with the job passphrase\n")
	}
	b.WriteString("\nFERRY-MANIFEST.json records the original name and the transforms\n")
	b.WriteString("for every stored file. Keep it next to the files.\n")
	b.WriteString("\nVerify the stored files:\n")
	b.WriteString("  sha256sum -c SHA256SUMS\n")
	b.WriteString("  md5sum -c MD5SUMS\n")
	b.WriteString("\nUnpack everything inside the image (asks for the passphrase when needed):\n")
	b.WriteString("  ./ferry unpack\n")
	b.WriteString("\nFrom the host, run the tool inside the image so the architecture matches:\n")
	b.WriteString("  docker run --rm -it -v \"$PWD:/work\" --entrypoint /data/ferry <image> unpack --dir /work\n")
	b.WriteString("\nNon-interactive unpack:\n")
	b.WriteString("  ./ferry unpack --passphrase 'your passphrase'\n")
	b.WriteString("\nThe unpack command verifies the checksums, decrypts .ferry files,\n")
	b.WriteString("decompresses .gz files, and writes the original filenames here.\n")
	b.WriteString("Use --verify-only to check the checksums without unpacking.\n")
	return b.String()
}

func newTag(now time.Time) (string, error) {
	b := make([]byte, 2)
	if _, err := rand.Read(b); err != nil {
		return "", fmt.Errorf("generate tag: %w", err)
	}
	return fmt.Sprintf("job-%s-%x", now.UTC().Format("20060102-150405"), b), nil
}

func isRetryablePushError(err error) bool {
	if err == nil {
		return false
	}
	if errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) {
		return false
	}
	var netErr net.Error
	if errors.As(err, &netErr) {
		return true
	}
	var urlErr *url.Error
	if errors.As(err, &urlErr) {
		return true
	}
	var opErr *net.OpError
	if errors.As(err, &opErr) {
		return true
	}
	if errors.Is(err, io.EOF) || errors.Is(err, io.ErrUnexpectedEOF) ||
		errors.Is(err, syscall.ECONNRESET) || errors.Is(err, syscall.ECONNREFUSED) ||
		errors.Is(err, syscall.ETIMEDOUT) {
		return true
	}
	msg := strings.ToLower(err.Error())
	for _, marker := range []string{
		"connection reset", "connection refused", "broken pipe", "timeout",
		"tls handshake", "unexpected eof", "temporary failure", "http 502", "http 503", "http 504",
	} {
		if strings.Contains(msg, marker) {
			return true
		}
	}
	return false
}

func redact(err error, secret string) error {
	if err == nil {
		return nil
	}
	msg := err.Error()
	if secret != "" {
		msg = strings.ReplaceAll(msg, secret, "[redacted]")
	}
	return errors.New(msg)
}
