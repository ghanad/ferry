package main

import (
	"bytes"
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"ferry/internal/update"
)

func testUpdateChecker(t *testing.T, tag string) *update.Checker {
	t.Helper()
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`{"tag_name":"` + tag + `","html_url":"https://example.test/release"}`))
	}))
	t.Cleanup(server.Close)
	checker := update.New("")
	checker.APIBase = server.URL
	return checker
}

func TestReportUpdate(t *testing.T) {
	tests := []struct {
		name     string
		current  string
		tag      string
		wantCode int
		wantOut  string
	}{
		{name: "newer release", current: "v1.0.0", tag: "v1.1.0", wantCode: 1, wantOut: "A newer Ferry release is available: v1.1.0"},
		{name: "up to date", current: "v1.1.0", tag: "v1.1.0", wantCode: 0, wantOut: "is up to date"},
		{name: "running a newer build", current: "v2.0.0", tag: "v1.1.0", wantCode: 0, wantOut: "is up to date"},
		{name: "development build", current: "dev", tag: "v1.1.0", wantCode: 0, wantOut: "development build (dev)"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			var stdout, stderr bytes.Buffer
			code := reportUpdate(context.Background(), &stdout, &stderr, test.current, testUpdateChecker(t, test.tag))
			if code != test.wantCode {
				t.Errorf("exit code = %d, want %d (stderr: %s)", code, test.wantCode, stderr.String())
			}
			if !strings.Contains(stdout.String(), test.wantOut) {
				t.Errorf("stdout = %q, want it to contain %q", stdout.String(), test.wantOut)
			}
			if stderr.Len() != 0 {
				t.Errorf("stderr = %q, want empty", stderr.String())
			}
		})
	}
}

func TestReportUpdateFailure(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusNotFound)
	}))
	t.Cleanup(server.Close)
	checker := update.New("")
	checker.APIBase = server.URL

	var stdout, stderr bytes.Buffer
	code := reportUpdate(context.Background(), &stdout, &stderr, "v1.0.0", checker)
	if code != 2 {
		t.Errorf("exit code = %d, want 2", code)
	}
	if !strings.Contains(stderr.String(), "Could not check for updates") {
		t.Errorf("stderr = %q, want an actionable error", stderr.String())
	}
	if !strings.Contains(stderr.String(), "GITHUB_TOKEN") {
		t.Errorf("stderr = %q, want it to mention GITHUB_TOKEN", stderr.String())
	}
}
