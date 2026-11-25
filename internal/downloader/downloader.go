package downloader

import (
	"context"
	"crypto/md5"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"math"
	"mime"
	"net"
	"net/http"
	"net/url"
	"os"
	"path"
	"strings"
	"sync/atomic"
	"syscall"
	"time"

	"ferry/internal/safename"
)

const (
	dialTimeout           = 15 * time.Second
	tlsHandshakeTimeout   = 15 * time.Second
	responseHeaderTimeout = 30 * time.Second
	stallTimeout          = 60 * time.Second
	maxRedirects          = 5
	maxHeaderBytes        = 1 << 20
)

// ErrTooLarge means the download exceeded the remaining job quota.
var ErrTooLarge = errors.New("download exceeds the remaining job size limit")

// ErrStalled means no bytes arrived for 60 seconds.
var ErrStalled = errors.New("download stalled: no data received for 60 seconds")

// Result describes a completed download.
type Result struct {
	Filename string
	Size     int64
	SHA256   string
	MD5      string
}

// Client is an SSRF-safe streaming HTTP downloader.
type Client struct {
	http *http.Client
}

// New creates a downloader that does not use environment proxies and checks
// the actual connected IP on every request and redirect.
func New() *Client {
	dialer := &net.Dialer{
		Timeout:   dialTimeout,
		KeepAlive: 30 * time.Second,
		Control: func(network, address string, _ syscall.RawConn) error {
			host, _, err := net.SplitHostPort(address)
			if err != nil {
				return fmt.Errorf("blocked address: cannot parse %q", address)
			}
			ip := net.ParseIP(host)
			if ip == nil {
				return fmt.Errorf("blocked address: cannot parse IP %q", host)
			}
			if IsBlockedIP(ip) {
				return fmt.Errorf("%w (connected address %s)", ErrBlockedAddress, ip.String())
			}
			return nil
		},
	}
	transport := &http.Transport{
		Proxy:                  nil, // never honor HTTP_PROXY / HTTPS_PROXY
		DialContext:            dialer.DialContext,
		TLSHandshakeTimeout:    tlsHandshakeTimeout,
		ResponseHeaderTimeout:  responseHeaderTimeout,
		MaxResponseHeaderBytes: maxHeaderBytes,
		ForceAttemptHTTP2:      true,
		MaxIdleConns:           10,
		IdleConnTimeout:        90 * time.Second,
	}
	client := &http.Client{
		Transport: transport,
		CheckRedirect: func(req *http.Request, via []*http.Request) error {
			if len(via) > maxRedirects {
				return fmt.Errorf("too many redirects (maximum %d)", maxRedirects)
			}
			if req.URL.Scheme != "http" && req.URL.Scheme != "https" {
				return errors.New("redirect to a non-http(s) URL is not allowed")
			}
			if req.URL.User != nil {
				return errors.New("redirect to a URL with credentials is not allowed")
			}
			// The transport dialer validates the resolved IP for this hop.
			return nil
		},
	}
	return &Client{http: client}
}

// Download streams rawURL into destPath. destPath must not exist. The caller
// must remove the destination on error. maxBytes is the remaining total quota.
func (c *Client) Download(ctx context.Context, rawURL, destPath string, maxBytes int64,
	progress func(done, total int64)) (Result, error) {

	u, err := ValidateURL(rawURL)
	if err != nil {
		return Result{}, err
	}
	if maxBytes < 0 {
		return Result{}, ErrTooLarge
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u.String(), nil)
	if err != nil {
		return Result{}, fmt.Errorf("create request: %w", err)
	}
	req.Header.Set("User-Agent", "Ferry/1.0 (self-hosted transfer agent)")
	req.Header.Set("Accept", "*/*")

	resp, err := c.http.Do(req)
	if err != nil {
		return Result{}, friendlyHTTPError(err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return Result{}, fmt.Errorf("server returned HTTP %d %s (only a plain 200 response is accepted)",
			resp.StatusCode, http.StatusText(resp.StatusCode))
	}
	if resp.ContentLength > maxBytes {
		return Result{}, fmt.Errorf("%w: server reports %d bytes but only %d bytes remain",
			ErrTooLarge, resp.ContentLength, maxBytes)
	}
	filename := suggestedFilename(resp, u)

	f, err := os.OpenFile(destPath, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
	if err != nil {
		return Result{}, fmt.Errorf("create download file: %w", err)
	}
	ok := false
	defer func() {
		_ = f.Close()
		if !ok {
			_ = os.Remove(destPath)
		}
	}()

	stall := newStallBody(resp.Body, stallTimeout)
	defer stall.Close()
	hasher := sha256.New()
	md5Hasher := md5.New()
	writer := io.MultiWriter(f, hasher, md5Hasher)
	if progress != nil {
		writer = io.MultiWriter(f, hasher, md5Hasher, &progressWriter{
			onWrite: progress,
			total:   resp.ContentLength,
		})
	}
	limit := maxBytes
	if limit < math.MaxInt64 {
		limit++ // one extra byte lets us detect a too-large body
	}
	copied, err := io.CopyBuffer(writer, io.LimitReader(stall, limit), make([]byte, 256*1024))
	if err != nil {
		if stall.TimedOut() {
			return Result{}, ErrStalled
		}
		return Result{}, friendlyHTTPError(err)
	}
	// Stop the stall timer before fsync; a slow disk must not look like a
	// stalled network connection.
	stall.Stop()
	if copied > maxBytes {
		return Result{}, fmt.Errorf("%w: limit is %d bytes", ErrTooLarge, maxBytes)
	}
	if resp.ContentLength >= 0 && copied != resp.ContentLength {
		return Result{}, fmt.Errorf("download ended early: received %d of %d bytes", copied, resp.ContentLength)
	}
	if err := f.Sync(); err != nil {
		return Result{}, fmt.Errorf("flush download: %w", err)
	}
	if err := f.Close(); err != nil {
		return Result{}, fmt.Errorf("close download: %w", err)
	}
	ok = true
	return Result{
		Filename: filename,
		Size:     copied,
		SHA256:   hex.EncodeToString(hasher.Sum(nil)),
		MD5:      hex.EncodeToString(md5Hasher.Sum(nil)),
	}, nil
}

func friendlyHTTPError(err error) error {
	if errors.Is(err, ErrBlockedAddress) {
		return fmt.Errorf("%w: Ferry refuses loopback, private, link-local, CGNAT and reserved addresses", ErrBlockedAddress)
	}
	if errors.Is(err, context.Canceled) {
		return errors.New("download cancelled")
	}
	if errors.Is(err, context.DeadlineExceeded) {
		return errors.New("download timed out while connecting")
	}
	var netErr net.Error
	if errors.As(err, &netErr) && netErr.Timeout() {
		return fmt.Errorf("network timeout: %w", err)
	}
	return err
}

func suggestedFilename(resp *http.Response, u *url.URL) string {
	candidate := ""
	if cd := resp.Header.Get("Content-Disposition"); cd != "" {
		if _, params, err := mime.ParseMediaType(cd); err == nil {
			candidate = params["filename"]
		}
	}
	if candidate == "" {
		candidate = path.Base(strings.TrimSuffix(u.Path, "/"))
	}
	name := safename.Sanitize(candidate)
	if name == "" {
		name = "download"
	}
	return name
}

type progressWriter struct {
	onWrite func(done, total int64)
	total   int64
	done    int64
}

func (p *progressWriter) Write(b []byte) (int, error) {
	n, err := len(b), error(nil)
	p.done += int64(n)
	p.onWrite(p.done, p.total)
	return n, err
}

type stallBody struct {
	body     io.ReadCloser
	timer    *time.Timer
	timedOut atomic.Bool
}

func newStallBody(body io.ReadCloser, timeout time.Duration) *stallBody {
	s := &stallBody{body: body}
	s.timer = time.AfterFunc(timeout, func() {
		s.timedOut.Store(true)
		_ = s.body.Close()
	})
	return s
}

func (s *stallBody) Read(p []byte) (int, error) {
	n, err := s.body.Read(p)
	if n > 0 {
		s.timer.Reset(stallTimeout)
	}
	if s.timedOut.Load() {
		return n, ErrStalled
	}
	return n, err
}

func (s *stallBody) Close() error {
	s.timer.Stop()
	return s.body.Close()
}

func (s *stallBody) Stop() { s.timer.Stop() }

func (s *stallBody) TimedOut() bool { return s.timedOut.Load() }
