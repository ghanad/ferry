package jobs

import (
	"context"
	"errors"
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"testing"

	"ferry/internal/config"
	"ferry/internal/db"
	"ferry/internal/safename"
)

func newTestManager(t *testing.T) (*Manager, *db.Store) {
	t.Helper()
	dir := t.TempDir()
	store, err := db.Open(filepath.Join(dir, "ferry.db"), dir)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = store.Close() })
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	return New(&config.Config{DataDir: dir}, store, nil, nil, nil, logger), store
}

func TestDiscardQueuedJob(t *testing.T) {
	m, store := newTestManager(t)
	ctx := context.Background()
	id := "20000000000000000000000000000001"
	if _, err := store.CreateJob(ctx, id); err != nil {
		t.Fatal(err)
	}
	if _, err := store.Transition(ctx, id, db.StateDraft, db.StateQueued, ""); err != nil {
		t.Fatal(err)
	}
	dir, err := safename.JobDir(m.cfg.DataDir, id)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(dir, 0o750); err != nil {
		t.Fatal(err)
	}
	m.setProgress(id, Progress{Text: "Queued"})

	if err := m.Discard(ctx, id); err != nil {
		t.Fatal(err)
	}
	if _, err := store.GetJob(ctx, id); !errors.Is(err, db.ErrNotFound) {
		t.Fatalf("GetJob after discard = %v, want ErrNotFound", err)
	}
	if _, err := os.Stat(dir); !os.IsNotExist(err) {
		t.Fatalf("job directory still exists: %v", err)
	}
	if p := m.Progress(id); p.Text != "" {
		t.Fatalf("progress was not cleared: %+v", p)
	}
}

func TestDiscardRunningJobWaitsForCancel(t *testing.T) {
	m, store := newTestManager(t)
	ctx := context.Background()
	id := "20000000000000000000000000000002"
	if _, err := store.CreateJob(ctx, id); err != nil {
		t.Fatal(err)
	}
	if _, err := store.Transition(ctx, id, db.StateDraft, db.StateQueued, ""); err != nil {
		t.Fatal(err)
	}
	if _, err := store.Transition(ctx, id, db.StateQueued, db.StateDownloading, ""); err != nil {
		t.Fatal(err)
	}
	m.registerCancel(id, func() {
		if err := store.Fail(context.Background(), id, "cancelled by user"); err != nil {
			t.Errorf("mark job failed: %v", err)
		}
	})

	if err := m.Discard(ctx, id); err != nil {
		t.Fatal(err)
	}
	if _, err := store.GetJob(ctx, id); !errors.Is(err, db.ErrNotFound) {
		t.Fatalf("GetJob after discard = %v, want ErrNotFound", err)
	}
}

func TestDiscardTerminalAndMissingJob(t *testing.T) {
	m, store := newTestManager(t)
	ctx := context.Background()
	id := "20000000000000000000000000000003"
	if _, err := store.CreateJob(ctx, id); err != nil {
		t.Fatal(err)
	}
	if _, err := store.Transition(ctx, id, db.StateDraft, db.StateFailed, "boom"); err != nil {
		t.Fatal(err)
	}
	if err := m.Discard(ctx, id); err != nil {
		t.Fatal(err)
	}
	if _, err := store.GetJob(ctx, id); !errors.Is(err, db.ErrNotFound) {
		t.Fatalf("GetJob after discard = %v, want ErrNotFound", err)
	}
	if err := m.Discard(ctx, "20000000000000000000000000000004"); err != nil {
		t.Fatalf("discard missing job = %v, want nil", err)
	}
}
