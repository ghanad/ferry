// Package update checks GitHub releases for a newer Ferry version.
package update

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"
)

// Repo is the GitHub repository that publishes Ferry releases.
const Repo = "ghanad/ferry"

const (
	apiBase        = "https://api.github.com"
	defaultTimeout = 15 * time.Second
	maxBodyBytes   = 1 << 20
)

// ErrNotFound reports that GitHub has no published release for the repository.
var ErrNotFound = errors.New("no published release found")

// Release describes the newest published Ferry release.
type Release struct {
	Version     Version
	Tag         string
	URL         string
	PublishedAt time.Time
}

// Version is a parsed semantic version. Pre holds the pre-release suffix
// without the leading dash, for example "rc.1".
type Version struct {
	Major int
	Minor int
	Patch int
	Pre   string
}

// ParseVersion parses versions such as "v1.2.3", "1.2" or "1.2.3-rc.1".
// Build metadata after "+" is ignored.
func ParseVersion(raw string) (Version, bool) {
	s := strings.TrimSpace(raw)
	if strings.HasPrefix(s, "v") || strings.HasPrefix(s, "V") {
		s = s[1:]
	}
	if s == "" {
		return Version{}, false
	}
	if i := strings.IndexByte(s, '+'); i >= 0 {
		s = s[:i]
	}
	pre := ""
	if i := strings.IndexByte(s, '-'); i >= 0 {
		pre = s[i+1:]
		s = s[:i]
	}
	parts := strings.Split(s, ".")
	if len(parts) > 3 {
		return Version{}, false
	}
	var nums [3]int
	for i, part := range parts {
		if part == "" {
			return Version{}, false
		}
		n, err := strconv.Atoi(part)
		if err != nil || n < 0 {
			return Version{}, false
		}
		nums[i] = n
	}
	return Version{Major: nums[0], Minor: nums[1], Patch: nums[2], Pre: pre}, true
}

// Compare returns -1, 0 or 1 when a is older than, equal to, or newer than b.
// It follows the semantic-versioning rules for pre-release identifiers.
func Compare(a, b Version) int {
	if c := compareInt(a.Major, b.Major); c != 0 {
		return c
	}
	if c := compareInt(a.Minor, b.Minor); c != 0 {
		return c
	}
	if c := compareInt(a.Patch, b.Patch); c != 0 {
		return c
	}
	return comparePre(a.Pre, b.Pre)
}

func compareInt(a, b int) int {
	switch {
	case a < b:
		return -1
	case a > b:
		return 1
	default:
		return 0
	}
}

func comparePre(a, b string) int {
	if a == b {
		return 0
	}
	// A release without a pre-release suffix is newer than any pre-release.
	if a == "" {
		return 1
	}
	if b == "" {
		return -1
	}
	aParts := strings.Split(a, ".")
	bParts := strings.Split(b, ".")
	for i := 0; i < len(aParts) && i < len(bParts); i++ {
		if c := compareIdentifier(aParts[i], bParts[i]); c != 0 {
			return c
		}
	}
	return compareInt(len(aParts), len(bParts))
}

func compareIdentifier(a, b string) int {
	aNum, aErr := strconv.Atoi(a)
	bNum, bErr := strconv.Atoi(b)
	switch {
	case aErr == nil && bErr == nil:
		return compareInt(aNum, bNum)
	case aErr == nil:
		return -1 // numeric identifiers sort before alphanumeric ones
	case bErr == nil:
		return 1
	default:
		return strings.Compare(a, b)
	}
}

// Checker queries the GitHub releases API.
type Checker struct {
	// Repo is the "owner/name" repository to query.
	Repo string
	// Token authenticates the request. It may be empty for a public repository.
	Token string
	// Client performs the HTTP request. A sensible default is used when nil.
	Client *http.Client
	// APIBase overrides the GitHub API root; tests use it with httptest.
	APIBase string
}

// New returns a Checker for the Ferry repository. token may be empty; the
// repository is private, so GitHub then answers with 404.
func New(token string) *Checker {
	return &Checker{
		Repo:    Repo,
		Token:   strings.TrimSpace(token),
		Client:  &http.Client{Timeout: defaultTimeout},
		APIBase: apiBase,
	}
}

// Latest returns the newest published release.
func (c *Checker) Latest(ctx context.Context) (Release, error) {
	base := strings.TrimRight(c.APIBase, "/")
	if base == "" {
		base = apiBase
	}
	url := base + "/repos/" + c.Repo + "/releases/latest"
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return Release{}, fmt.Errorf("build GitHub request: %w", err)
	}
	req.Header.Set("Accept", "application/vnd.github+json")
	req.Header.Set("X-GitHub-Api-Version", "2022-11-28")
	req.Header.Set("User-Agent", "ferry-update-check")
	if c.Token != "" {
		req.Header.Set("Authorization", "Bearer "+c.Token)
	}

	client := c.Client
	if client == nil {
		client = &http.Client{Timeout: defaultTimeout}
	}
	resp, err := client.Do(req)
	if err != nil {
		return Release{}, fmt.Errorf("contact GitHub: %w", err)
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(io.LimitReader(resp.Body, maxBodyBytes))
	if err != nil {
		return Release{}, fmt.Errorf("read GitHub response: %w", err)
	}
	switch resp.StatusCode {
	case http.StatusOK:
	case http.StatusNotFound:
		return Release{}, fmt.Errorf("%w for %s. If the repository is private, set GITHUB_TOKEN to a token that can read it", ErrNotFound, c.Repo)
	case http.StatusUnauthorized:
		return Release{}, errors.New("GitHub rejected GITHUB_TOKEN (401 Unauthorized). Check that the token is valid and has not expired")
	case http.StatusForbidden:
		if resp.Header.Get("X-RateLimit-Remaining") == "0" {
			return Release{}, errors.New("GitHub API rate limit reached; try again later")
		}
		return Release{}, errors.New("GitHub refused the request (403 Forbidden)")
	default:
		return Release{}, fmt.Errorf("GitHub returned %s", resp.Status)
	}

	var payload struct {
		TagName     string    `json:"tag_name"`
		HTMLURL     string    `json:"html_url"`
		PublishedAt time.Time `json:"published_at"`
	}
	if err := json.Unmarshal(body, &payload); err != nil {
		return Release{}, fmt.Errorf("decode GitHub response: %w", err)
	}
	parsed, ok := ParseVersion(payload.TagName)
	if !ok {
		return Release{}, fmt.Errorf("GitHub returned an unrecognized release tag %q", payload.TagName)
	}
	return Release{
		Version:     parsed,
		Tag:         payload.TagName,
		URL:         payload.HTMLURL,
		PublishedAt: payload.PublishedAt,
	}, nil
}

// Status is the cached result of the most recent update check.
type Status struct {
	CheckedAt       time.Time
	Current         string
	Latest          string
	UpdateAvailable bool
	URL             string
	Err             error
}

// Watcher checks for a newer release in the background and caches the result
// so HTTP handlers never block on the network.
type Watcher struct {
	checker  *Checker
	current  string
	interval time.Duration

	mu     sync.RWMutex
	status Status
}

// NewWatcher returns a Watcher for the given build version. Call Start to
// begin checking.
func NewWatcher(checker *Checker, current string) *Watcher {
	return &Watcher{checker: checker, current: current, interval: 6 * time.Hour}
}

// Start checks once and then every interval until ctx is cancelled. It returns
// immediately; the check runs in a background goroutine.
func (w *Watcher) Start(ctx context.Context) {
	go func() {
		w.Refresh(ctx)
		ticker := time.NewTicker(w.interval)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				w.Refresh(ctx)
			}
		}
	}()
}

// Status returns a copy of the cached result.
func (w *Watcher) Status() Status {
	w.mu.RLock()
	defer w.mu.RUnlock()
	return w.status
}

// Refresh checks once and replaces the cached status. It is safe to call
// concurrently; Start calls it in the background.
func (w *Watcher) Refresh(ctx context.Context) {
	checkCtx, cancel := context.WithTimeout(ctx, defaultTimeout+5*time.Second)
	defer cancel()

	release, err := w.checker.Latest(checkCtx)
	status := Status{CheckedAt: time.Now(), Current: w.current, Err: err}
	if err == nil {
		status.Latest = release.Tag
		status.URL = release.URL
		if current, ok := ParseVersion(w.current); ok {
			status.UpdateAvailable = Compare(current, release.Version) < 0
		}
	}

	w.mu.Lock()
	w.status = status
	w.mu.Unlock()
}
