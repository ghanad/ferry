package jobs

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"time"

	"ferry/internal/db"
	"ferry/internal/dockerhub"
	"ferry/internal/safename"
)

const (
	staleDraftAge = 24 * time.Hour
	cleanupPeriod = time.Hour
)

func (m *Manager) cleanupLoop(ctx context.Context) {
	timer := time.NewTimer(2 * time.Minute)
	defer timer.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-timer.C:
			m.runCleanup(ctx)
			timer.Reset(cleanupPeriod)
		}
	}
}

func (m *Manager) runCleanup(ctx context.Context) {
	if ctx.Err() != nil {
		return
	}
	m.deleteStaleDrafts(ctx)
	m.cleanupOrphans(ctx)
	m.cleanupRetention(ctx)
}

func (m *Manager) deleteStaleDrafts(ctx context.Context) {
	cutoff := time.Now().Add(-staleDraftAge)
	drafts, err := m.store.ListStaleDrafts(ctx, cutoff)
	if err != nil {
		m.logger.Error("list stale drafts", "error", err)
		return
	}
	for _, job := range drafts {
		ok, err := m.store.DeleteStaleDraft(ctx, job.ID, cutoff)
		if err != nil {
			m.logger.Error("delete stale draft", "id", job.ID, "error", err)
			continue
		}
		if !ok {
			continue
		}
		m.removeJobDir(job.ID)
		m.logger.Info("deleted stale draft", "id", job.ID)
	}
}

// cleanupOrphans removes job directories whose database row is gone or whose
// job is finished. Draft and queued jobs keep their files.
func (m *Manager) cleanupOrphans(ctx context.Context) {
	base := filepath.Join(m.cfg.DataDir, "jobs")
	entries, err := os.ReadDir(base)
	if err != nil {
		if !os.IsNotExist(err) {
			m.logger.Error("read jobs directory", "error", err)
		}
		return
	}
	for _, entry := range entries {
		if !entry.IsDir() {
			continue
		}
		id := entry.Name()
		dir, err := safename.JobDir(m.cfg.DataDir, id)
		if err != nil {
			m.logger.Warn("skipping unrecognized entry in jobs directory", "name", id)
			continue
		}
		job, err := m.store.GetJob(ctx, id)
		if errors.Is(err, db.ErrNotFound) {
			if err := os.RemoveAll(dir); err != nil {
				m.logger.Error("remove orphan job directory", "id", id, "error", err)
			}
			continue
		}
		if err != nil {
			m.logger.Error("look up job directory", "id", id, "error", err)
			continue
		}
		if db.IsTerminal(job.State) {
			if err := os.RemoveAll(dir); err != nil {
				m.logger.Error("remove finished job directory", "id", id, "error", err)
			}
		}
	}
}

func (m *Manager) cleanupRetention(ctx context.Context) {
	if m.cfg.RetentionDays <= 0 {
		return
	}
	cutoff := time.Now().AddDate(0, 0, -m.cfg.RetentionDays)
	jobs, err := m.store.ListDoneBefore(ctx, cutoff)
	if err != nil {
		m.logger.Error("list images for retention", "error", err)
		return
	}
	for _, job := range jobs {
		repo, tag, err := dockerhub.SplitImage(job.Image)
		if err == nil {
			err = m.hub.DeleteTag(ctx, repo, tag)
		}
		if err != nil {
			m.logger.Error("retention image delete failed", "id", job.ID, "image", job.Image, "error", err)
			continue
		}
		if err := m.store.SetImageDeleted(ctx, job.ID); err != nil {
			m.logger.Error("mark retention image deleted", "id", job.ID, "error", err)
			continue
		}
		m.appendLog(ctx, job.ID, "Docker Hub image tag deleted by retention policy.")
	}
}
