package update

import (
	"bytes"
	"context"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestParseVersion(t *testing.T) {
	tests := []struct {
		in   string
		want Version
		ok   bool
	}{
		{"v1.2.3", Version{1, 2, 3, ""}, true},
		{"1.2.3", Version{1, 2, 3, ""}, true},
		{"V2.0", Version{2, 0, 0, ""}, true},
		{"1", Version{1, 0, 0, ""}, true},
		{"1.2.3-rc.1", Version{1, 2, 3, "rc.1"}, true},
		{"v1.2.3+build.7", Version{1, 2, 3, ""}, true},
		{"dev", Version{}, false},
		{"0b4784c", Version{}, false},
		{"1.2.3.4", Version{}, false},
		{"1..2", Version{}, false},
		{"", Version{}, false},
	}
	for _, test := range tests {
		got, ok := ParseVersion(test.in)
		if ok != test.ok || got != test.want {
			t.Errorf("ParseVersion(%q) = %+v, %v; want %+v, %v", test.in, got, ok, test.want, test.ok)
		}
	}
}

func TestCompare(t *testing.T) {
	tests := []struct {
		a, b string
		want int
	}{
		{"1.0.0", "1.0.0", 0},
		{"1.0.0", "1.0.1", -1},
		{"1.1.0", "1.0.9", 1},
		{"2.0.0", "10.0.0", -1},
		{"1.0.0-rc.1", "1.0.0", -1},
		{"1.0.0", "1.0.0-rc.1", 1},
		{"1.0.0-rc.9", "1.0.0-rc.10", -1},
		{"1.0.0-alpha", "1.0.0-beta", -1},
		{"1.0.0-1", "1.0.0-alpha", -1},
	}
	for _, test := range tests {
		a, ok := ParseVersion(test.a)
		if !ok {
			t.Fatalf("ParseVersion(%q) failed", test.a)
		}
		b, ok := ParseVersion(test.b)
		if !ok {
			t.Fatalf("ParseVersion(%q) failed", test.b)
		}
		if got := Compare(a, b); got != test.want {
			t.Errorf("Compare(%q, %q) = %d; want %d", test.a, test.b, got, test.want)
		}
	}
}

func newTestChecker(t *testing.T, handler http.HandlerFunc) *Checker {
	t.Helper()
	server := httptest.NewServer(handler)
	t.Cleanup(server.Close)
	checker := New("")
	checker.APIBase = server.URL
	return checker
}

func TestLatest(t *testing.T) {
	var gotPath, gotAuth, gotAccept string
	checker := newTestChecker(t, func(w http.ResponseWriter, r *http.Request) {
		gotPath = r.URL.Path
		gotAuth = r.Header.Get("Authorization")
		gotAccept = r.Header.Get("Accept")
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"tag_name":"v1.4.0","html_url":"https://github.com/ghanad/ferry/releases/tag/v1.4.0","published_at":"2026-11-20T10:00:00Z"}`))
	})
	checker.Token = "secret-token"

	release, err := checker.Latest(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if gotPath != "/repos/ghanad/ferry/releases/latest" {
		t.Errorf("path = %q", gotPath)
	}
	if gotAuth != "Bearer secret-token" {
		t.Errorf("Authorization = %q", gotAuth)
	}
	if gotAccept != "application/vnd.github+json" {
		t.Errorf("Accept = %q", gotAccept)
	}
	if release.Tag != "v1.4.0" || release.Version != (Version{1, 4, 0, ""}) {
		t.Errorf("release = %+v", release)
	}
	if release.URL != "https://github.com/ghanad/ferry/releases/tag/v1.4.0" {
		t.Errorf("URL = %q", release.URL)
	}
	if release.PublishedAt.IsZero() {
		t.Error("PublishedAt was not parsed")
	}
}

func TestLatestWithoutTokenSendsNoAuthorization(t *testing.T) {
	var gotAuth string
	checker := newTestChecker(t, func(w http.ResponseWriter, r *http.Request) {
		gotAuth = r.Header.Get("Authorization")
		_, _ = w.Write([]byte(`{"tag_name":"v1.0.0"}`))
	})
	if _, err := checker.Latest(context.Background()); err != nil {
		t.Fatal(err)
	}
	if gotAuth != "" {
		t.Errorf("Authorization = %q, want empty", gotAuth)
	}
}

func TestLatestErrors(t *testing.T) {
	tests := []struct {
		name    string
		status  int
		headers map[string]string
		want    string
		is      error
	}{
		{name: "not found", status: http.StatusNotFound, want: "GITHUB_TOKEN", is: ErrNotFound},
		{name: "unauthorized", status: http.StatusUnauthorized, want: "401"},
		{name: "forbidden", status: http.StatusForbidden, want: "403"},
		{name: "rate limited", status: http.StatusForbidden, headers: map[string]string{"X-RateLimit-Remaining": "0"}, want: "rate limit"},
		{name: "server error", status: http.StatusBadGateway, want: "502"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			checker := newTestChecker(t, func(w http.ResponseWriter, r *http.Request) {
				for key, value := range test.headers {
					w.Header().Set(key, value)
				}
				w.WriteHeader(test.status)
			})
			_, err := checker.Latest(context.Background())
			if err == nil {
				t.Fatal("expected an error")
			}
			if !strings.Contains(err.Error(), test.want) {
				t.Errorf("error = %q, want it to contain %q", err, test.want)
			}
			if test.is != nil && !errors.Is(err, test.is) {
				t.Errorf("error = %v, want errors.Is(err, %v)", err, test.is)
			}
		})
	}
}

func TestLatestRejectsUnrecognizedTag(t *testing.T) {
	checker := newTestChecker(t, func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`{"tag_name":"nightly"}`))
	})
	if _, err := checker.Latest(context.Background()); err == nil {
		t.Fatal("expected an error for an unrecognized tag")
	}
}

func TestWatcherRefresh(t *testing.T) {
	tests := []struct {
		name       string
		current    string
		tag        string
		available  bool
		wantLatest string
	}{
		{name: "newer release", current: "v1.0.0", tag: "v1.1.0", available: true, wantLatest: "v1.1.0"},
		{name: "same release", current: "v1.1.0", tag: "v1.1.0", available: false, wantLatest: "v1.1.0"},
		{name: "older release", current: "v2.0.0", tag: "v1.1.0", available: false, wantLatest: "v1.1.0"},
		{name: "development build", current: "dev", tag: "v1.1.0", available: false, wantLatest: "v1.1.0"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			checker := newTestChecker(t, func(w http.ResponseWriter, r *http.Request) {
				_, _ = w.Write([]byte(`{"tag_name":"` + test.tag + `","html_url":"https://example.test/release"}`))
			})
			watcher := NewWatcher(checker, test.current)
			watcher.Refresh(context.Background())

			status := watcher.Status()
			if status.Err != nil {
				t.Fatalf("unexpected error: %v", status.Err)
			}
			if status.Latest != test.wantLatest {
				t.Errorf("Latest = %q, want %q", status.Latest, test.wantLatest)
			}
			if status.UpdateAvailable != test.available {
				t.Errorf("UpdateAvailable = %v, want %v", status.UpdateAvailable, test.available)
			}
			if status.URL != "https://example.test/release" {
				t.Errorf("URL = %q", status.URL)
			}
			if status.CheckedAt.IsZero() {
				t.Error("CheckedAt was not set")
			}
		})
	}
}

func TestWatcherRecordsErrors(t *testing.T) {
	checker := newTestChecker(t, func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusNotFound)
	})
	watcher := NewWatcher(checker, "v1.0.0")
	watcher.Refresh(context.Background())

	status := watcher.Status()
	if status.Err == nil {
		t.Fatal("expected the check error to be cached")
	}
	if status.UpdateAvailable {
		t.Error("UpdateAvailable must stay false when the check fails")
	}
}

func TestLatestParsesAssets(t *testing.T) {
	checker := newTestChecker(t, func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`{"tag_name":"v1.2.0","assets":[{"name":"ferry-v1.2.0-linux-amd64.tar.gz","url":"https://api.example/assets/1","browser_download_url":"https://example.test/1","size":1234}]}`))
	})
	release, err := checker.Latest(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	asset, ok := release.AssetByName("ferry-v1.2.0-linux-amd64.tar.gz")
	if !ok {
		t.Fatal("asset was not parsed")
	}
	if asset.APIURL != "https://api.example/assets/1" || asset.BrowserURL != "https://example.test/1" || asset.Size != 1234 {
		t.Errorf("asset = %+v", asset)
	}
	if _, ok := release.AssetByName("missing"); ok {
		t.Error("AssetByName found an asset that does not exist")
	}
}

func TestDownloadAsset(t *testing.T) {
	var gotAccept, gotAuth string
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotAccept = r.Header.Get("Accept")
		gotAuth = r.Header.Get("Authorization")
		_, _ = w.Write([]byte("archive-bytes"))
	}))
	t.Cleanup(server.Close)

	checker := New("secret-token")
	checker.DownloadClient = server.Client()
	var buf bytes.Buffer
	err := checker.DownloadAsset(context.Background(), Asset{Name: "a.tar.gz", APIURL: server.URL + "/asset"}, &buf)
	if err != nil {
		t.Fatal(err)
	}
	if buf.String() != "archive-bytes" {
		t.Errorf("body = %q", buf.String())
	}
	if gotAccept != "application/octet-stream" {
		t.Errorf("Accept = %q", gotAccept)
	}
	if gotAuth != "Bearer secret-token" {
		t.Errorf("Authorization = %q", gotAuth)
	}
}

func TestDownloadAssetFallsBackToBrowserURL(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte("ok"))
	}))
	t.Cleanup(server.Close)

	checker := New("")
	checker.DownloadClient = server.Client()
	var buf bytes.Buffer
	if err := checker.DownloadAsset(context.Background(), Asset{Name: "a", BrowserURL: server.URL}, &buf); err != nil {
		t.Fatal(err)
	}
	if buf.String() != "ok" {
		t.Errorf("body = %q", buf.String())
	}
}

func TestDownloadAssetErrorStatus(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusNotFound)
	}))
	t.Cleanup(server.Close)

	checker := New("")
	checker.DownloadClient = server.Client()
	err := checker.DownloadAsset(context.Background(), Asset{Name: "a", APIURL: server.URL}, io.Discard)
	if err == nil || !strings.Contains(err.Error(), "404") {
		t.Fatalf("error = %v, want a 404 error", err)
	}
}

func TestDownloadAssetWithoutURL(t *testing.T) {
	checker := New("")
	if err := checker.DownloadAsset(context.Background(), Asset{Name: "a"}, io.Discard); err == nil {
		t.Fatal("expected an error for an asset without a download URL")
	}
}
