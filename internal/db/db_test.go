package db

import (
	"context"
	"path/filepath"
	"testing"
	"time"
)

func TestStoreLifecycle(t *testing.T) {
	dir := t.TempDir()
	store, err := Open(filepath.Join(dir, "ferry.db"), dir)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	ctx := context.Background()

	jobID := "0123456789abcdef0123456789abcdef"
	job, err := store.CreateJob(ctx, jobID)
	if err != nil {
		t.Fatal(err)
	}
	if job.State != StateDraft {
		t.Fatalf("state = %q", job.State)
	}

	upload := &Upload{ID: "aaaabbbbccccddddeeeeffff00001111", JobID: jobID, Filename: "file.bin", DeclaredSize: 5}
	if err := store.CreateUpload(ctx, upload); err != nil {
		t.Fatal(err)
	}
	total, err := store.DeclaredTotal(ctx, jobID)
	if err != nil {
		t.Fatal(err)
	}
	if total != 5 {
		t.Fatalf("declared total = %d, want 5", total)
	}
	if err := store.SetUploadReceived(ctx, jobID, upload.ID, 5); err != nil {
		t.Fatal(err)
	}
	file := &File{Name: "file.bin", Size: 5, SHA256: "abc", Source: "upload", Status: "done"}
	if err := store.CompleteUpload(ctx, jobID, upload.ID, file); err != nil {
		t.Fatal(err)
	}
	total, err = store.DeclaredTotal(ctx, jobID)
	if err != nil {
		t.Fatal(err)
	}
	if total != 5 {
		t.Fatalf("declared total after completion = %d, want 5", total)
	}
	used, err := store.UsedNames(ctx, jobID)
	if err != nil {
		t.Fatal(err)
	}
	if !used["file.bin"] || !used["SHA256SUMS"] {
		t.Fatalf("reserved names missing: %#v", used)
	}
	files, err := store.ListDoneFiles(ctx, jobID)
	if err != nil {
		t.Fatal(err)
	}
	if len(files) != 1 || files[0].Name != "file.bin" {
		t.Fatalf("finished files = %#v", files)
	}

	urlFile, err := store.AddURLFile(ctx, jobID, "https://example.com/file")
	if err != nil {
		t.Fatal(err)
	}
	pending, err := store.ListPendingURLs(ctx, jobID)
	if err != nil {
		t.Fatal(err)
	}
	if len(pending) != 1 {
		t.Fatalf("pending URLs = %d", len(pending))
	}
	if err := store.MarkURLDone(ctx, jobID, urlFile.ID, "file", 4, "def", "abc123"); err != nil {
		t.Fatal(err)
	}
	total, count, err := store.RecalcTotals(ctx, jobID)
	if err != nil {
		t.Fatal(err)
	}
	if total != 9 || count != 2 {
		t.Fatalf("totals = %d/%d, want 9/2", total, count)
	}
	if err := store.Complete(ctx, jobID, "user/ferry:job-1", total, count); err != nil {
		t.Fatal(err)
	}
	old, err := store.ListDoneBefore(ctx, time.Now().Add(time.Hour))
	if err != nil {
		t.Fatal(err)
	}
	if len(old) != 1 {
		t.Fatalf("done-before list = %d", len(old))
	}
	if err := store.SetImageDeleted(ctx, jobID); err != nil {
		t.Fatal(err)
	}
}

func TestDeleteStaleDraft(t *testing.T) {
	dir := t.TempDir()
	store, err := Open(filepath.Join(dir, "ferry.db"), dir)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	ctx := context.Background()
	id := "fedcba9876543210fedcba9876543210"
	if _, err := store.CreateJob(ctx, id); err != nil {
		t.Fatal(err)
	}
	ok, err := store.DeleteStaleDraft(ctx, id, time.Now().Add(time.Minute))
	if err != nil {
		t.Fatal(err)
	}
	if !ok {
		t.Fatal("stale draft was not deleted")
	}
	if _, err := store.GetJob(ctx, id); err != ErrNotFound {
		t.Fatalf("GetJob error = %v, want ErrNotFound", err)
	}
}

func TestJobOptionsAndPassphraseClearing(t *testing.T) {
	dir := t.TempDir()
	store, err := Open(filepath.Join(dir, "ferry.db"), dir)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	ctx := context.Background()
	id := "00112233445566778899aabbccddeeff"
	if _, err := store.CreateJob(ctx, id); err != nil {
		t.Fatal(err)
	}
	if err := store.SetJobOptions(ctx, id, "sealed-value", true); err != nil {
		t.Fatal(err)
	}
	job, err := store.GetJob(ctx, id)
	if err != nil {
		t.Fatal(err)
	}
	if !job.Compress || !job.Encrypted || !job.HasPassphrase || job.PassphraseEnc != "sealed-value" {
		t.Fatalf("job options = %+v", job)
	}
	if _, err := store.Transition(ctx, id, StateDraft, StateQueued, ""); err != nil {
		t.Fatal(err)
	}
	if err := store.SetJobOptions(ctx, id, "other", true); err != ErrNotDraft {
		t.Fatalf("SetJobOptions on queued job = %v, want ErrNotDraft", err)
	}
	if _, err := store.Transition(ctx, id, StateQueued, StateFailed, "cancelled"); err != nil {
		t.Fatal(err)
	}
	job, err = store.GetJob(ctx, id)
	if err != nil {
		t.Fatal(err)
	}
	if job.HasPassphrase || job.PassphraseEnc != "" {
		t.Fatalf("passphrase was not cleared: %+v", job)
	}
	if !job.Encrypted || !job.Compress {
		t.Fatalf("encryption/compression flags were lost: %+v", job)
	}
}
