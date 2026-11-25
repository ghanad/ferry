package web

import (
	"context"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"

	"ferry/internal/auth"
	"ferry/internal/config"
	"ferry/internal/db"
	"ferry/internal/jobs"
)

func newTestServer(t *testing.T) (*Server, *db.Store, *jobs.Manager) {
	t.Helper()
	dir := t.TempDir()
	store, err := db.Open(filepath.Join(dir, "ferry.db"), dir)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = store.Close() })
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	cfg := &config.Config{DataDir: dir, MaxTotalBytes: 1 << 30}
	manager := jobs.New(cfg, store, nil, nil, nil, logger)
	server, err := New(cfg, store, nil, nil, manager, logger, "test")
	if err != nil {
		t.Fatal(err)
	}
	return server, store, manager
}

func TestIndexShowsQueuedJob(t *testing.T) {
	server, store, _ := newTestServer(t)
	ctx := context.Background()
	id := "30000000000000000000000000000001"
	if _, err := store.CreateJob(ctx, id); err != nil {
		t.Fatal(err)
	}
	if _, err := store.Transition(ctx, id, db.StateDraft, db.StateQueued, ""); err != nil {
		t.Fatal(err)
	}

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/", nil)
	server.handleIndex(rec, req, &auth.Session{Username: "dev", CSRF: "token"})

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want %d", rec.Code, http.StatusOK)
	}
	body := rec.Body.String()
	if !strings.Contains(body, "Working now") {
		t.Fatal("home page does not show the current-transfer card")
	}
	if !strings.Contains(body, id) {
		t.Fatal("home page does not show the queued job id")
	}
	if !strings.Contains(body, "Cancel &amp; clean up") {
		t.Fatal("home page does not offer cleanup for the queued job")
	}
}

func TestDiscardHandlerRemovesQueuedJob(t *testing.T) {
	server, store, _ := newTestServer(t)
	ctx := context.Background()
	id := "30000000000000000000000000000002"
	if _, err := store.CreateJob(ctx, id); err != nil {
		t.Fatal(err)
	}
	if _, err := store.Transition(ctx, id, db.StateDraft, db.StateQueued, ""); err != nil {
		t.Fatal(err)
	}

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/api/jobs/"+id+"/discard", nil)
	req.SetPathValue("jobID", id)
	server.handleDiscardJob(rec, req, &auth.Session{Username: "dev", CSRF: "token"})

	if rec.Code != http.StatusNoContent {
		t.Fatalf("status = %d, want %d", rec.Code, http.StatusNoContent)
	}
	if _, err := store.GetJob(ctx, id); !errors.Is(err, db.ErrNotFound) {
		t.Fatalf("GetJob after discard = %v, want ErrNotFound", err)
	}
}
