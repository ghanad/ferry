package jobs

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"path/filepath"
	"runtime/debug"
	"strings"
	"sync"
	"time"

	v1 "github.com/google/go-containerregistry/pkg/v1"

	"ferry/internal/config"
	"ferry/internal/db"
	"ferry/internal/dockerhub"
	"ferry/internal/downloader"
	"ferry/internal/imagebuild"
	"ferry/internal/safename"
	"ferry/internal/secretbox"
)

const (
	discardPollInterval = 100 * time.Millisecond
	discardTimeout      = 30 * time.Second
)

// Progress is the live, non-persisted progress shown by the job page.
type Progress struct {
	Text  string
	Done  int64
	Total int64
}

// Manager owns the single job queue and its worker.
type Manager struct {
	cfg     *config.Config
	store   *db.Store
	dl      *downloader.Client
	builder *imagebuild.Builder
	hub     *dockerhub.Client
	logger  *slog.Logger

	ctx    context.Context
	cancel context.CancelFunc
	queue  chan string
	wg     sync.WaitGroup

	mu       sync.Mutex
	progress map[string]Progress
	current  string
	closing  bool

	cancelMu      sync.Mutex
	jobCancels    map[string]context.CancelFunc
	userCancelled map[string]bool
}

// New creates a job manager. Call Start and Recover before serving requests.
func New(cfg *config.Config, store *db.Store, dl *downloader.Client,
	builder *imagebuild.Builder, hub *dockerhub.Client, logger *slog.Logger) *Manager {
	ctx, cancel := context.WithCancel(context.Background())
	return &Manager{
		cfg:           cfg,
		store:         store,
		dl:            dl,
		builder:       builder,
		hub:           hub,
		logger:        logger,
		ctx:           ctx,
		cancel:        cancel,
		queue:         make(chan string, 256),
		progress:      make(map[string]Progress),
		jobCancels:    make(map[string]context.CancelFunc),
		userCancelled: make(map[string]bool),
	}
}

// Start launches the worker and the hourly cleanup loop.
func (m *Manager) Start() {
	m.wg.Add(2)
	go func() {
		defer m.wg.Done()
		m.worker()
	}()
	go func() {
		defer m.wg.Done()
		m.cleanupLoop(m.ctx)
	}()
}

// Recover repairs state left by a previous process, removes orphan
// directories, and re-queues jobs that were queued when the process stopped.
func (m *Manager) Recover(ctx context.Context) error {
	var errs []error
	for _, state := range []string{db.StateDownloading, db.StateBuilding, db.StatePushing} {
		list, err := m.store.ListByState(ctx, state)
		if err != nil {
			errs = append(errs, err)
			continue
		}
		for _, job := range list {
			bg, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			_ = m.store.Fail(bg, job.ID, "interrupted by restart")
			_ = m.store.AppendLog(bg, job.ID, "Interrupted by a Ferry restart; partial files were removed.")
			cancel()
			m.removeJobDir(job.ID)
			m.setProgress(job.ID, Progress{Text: "Failed: interrupted by restart"})
			// A push may have completed before the restart. Delete the tag so it
			// cannot stay in Docker Hub forever without a history record.
			if job.Image != "" {
				m.deleteOrphanTag(job.ID, job.Image)
			}
		}
	}
	queued, err := m.store.ListByState(ctx, db.StateQueued)
	if err != nil {
		errs = append(errs, err)
	} else {
		for _, job := range queued {
			select {
			case m.queue <- job.ID:
			case <-m.ctx.Done():
				return errors.Join(errs...)
			}
		}
	}
	m.cleanupOrphans(ctx)
	return errors.Join(errs...)
}

// SetOptions saves the optional compression flag and passphrase for a draft.
// An empty passphrase keeps the one already saved, so pressing Start twice
// cannot silently remove encryption.
func (m *Manager) SetOptions(ctx context.Context, jobID, passphrase string, compress, clearPassphrase bool) error {
	job, err := m.store.GetJob(ctx, jobID)
	if err != nil {
		return err
	}
	if job.State != db.StateDraft {
		return errors.New("options can only be changed while the job is a draft")
	}
	enc := job.PassphraseEnc
	if clearPassphrase {
		enc = ""
	} else if passphrase != "" {
		if len(passphrase) < 8 {
			return errors.New("the passphrase must be at least 8 characters")
		}
		if len(passphrase) > 1024 {
			return errors.New("the passphrase is too long (maximum 1024 characters)")
		}
		enc, err = secretbox.Seal(m.cfg.SecretKey, passphrase)
		if err != nil {
			return fmt.Errorf("save passphrase: %w", err)
		}
	}
	if err := m.store.SetJobOptions(ctx, jobID, enc, compress); err != nil {
		if errors.Is(err, db.ErrNotDraft) {
			return errors.New("the job started before the options were saved; refresh the page")
		}
		return err
	}
	return nil
}

// StartJob validates a draft and moves it to the queue.
func (m *Manager) StartJob(ctx context.Context, jobID string) error {
	job, err := m.store.GetJob(ctx, jobID)
	if err != nil {
		return err
	}
	if job.State != db.StateDraft {
		return errors.New("this job has already been started")
	}
	pending, err := m.store.CountPendingUploads(ctx, jobID)
	if err != nil {
		return err
	}
	if pending > 0 {
		return fmt.Errorf("%d file upload(s) are still in progress; wait for them to finish before starting", pending)
	}
	entryCount, err := m.store.CountFiles(ctx, jobID)
	if err != nil {
		return err
	}
	if entryCount == 0 {
		return errors.New("add at least one file or download URL before starting")
	}
	total, _, err := m.store.RecalcTotals(ctx, jobID)
	if err != nil {
		return err
	}
	if total > m.cfg.MaxTotalBytes {
		return fmt.Errorf("job size %s exceeds the limit of %s", formatBytes(total), formatBytes(m.cfg.MaxTotalBytes))
	}
	if err := CheckDiskSpace(m.cfg.DataDir, total); err != nil {
		return err
	}
	ok, err := m.store.Transition(ctx, jobID, db.StateDraft, db.StateQueued, "")
	if err != nil {
		return err
	}
	if !ok {
		return errors.New("this job is no longer a draft")
	}
	// Re-check after the atomic transition. A concurrent upload creation either
	// happened before this check (and is caught here) or will fail its own
	// draft-state check in the database.
	if pending, err := m.store.CountPendingUploads(ctx, jobID); err != nil {
		return err
	} else if pending > 0 {
		_, _ = m.store.Transition(ctx, jobID, db.StateQueued, db.StateDraft, "")
		return errors.New("an upload is still in progress; wait for it to finish, then start again")
	}
	m.appendLog(ctx, jobID, "Queued. Waiting for the worker.")
	m.setProgress(jobID, Progress{Text: "Queued", Done: 0, Total: total})
	select {
	case m.queue <- jobID:
		return nil
	case <-m.ctx.Done():
		return errors.New("the server is shutting down; the job is queued and will start after the next restart")
	}
}

// Progress returns a copy of the live progress for a job.
func (m *Manager) Progress(jobID string) Progress {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.progress[jobID]
}

// Current returns the job the worker is processing right now, if any.
func (m *Manager) Current() (string, Progress) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.current == "" {
		return "", Progress{}
	}
	return m.current, m.progress[m.current]
}

// Cancel stops a queued or running transfer. Queued jobs are marked failed
// immediately; running jobs are cancelled through their context and the worker
// cleans up the files.
func (m *Manager) Cancel(ctx context.Context, jobID string) error {
	job, err := m.store.GetJob(ctx, jobID)
	if err != nil {
		return err
	}
	switch job.State {
	case db.StateQueued:
		ok, err := m.store.Transition(ctx, jobID, db.StateQueued, db.StateFailed, "cancelled by user")
		if err != nil {
			return err
		}
		if !ok {
			return errors.New("the transfer already started; try cancelling again")
		}
		m.appendLog(ctx, jobID, "Cancelled before it started.")
		m.setProgress(jobID, Progress{Text: "Cancelled by user"})
		return nil
	case db.StateDownloading, db.StateBuilding, db.StatePushing:
		m.cancelMu.Lock()
		cancel := m.jobCancels[jobID]
		if cancel != nil {
			m.userCancelled[jobID] = true
		}
		m.cancelMu.Unlock()
		if cancel == nil {
			return errors.New("the transfer is starting; try cancelling again in a moment")
		}
		m.appendLog(ctx, jobID, "Cancellation requested. Stopping the current step...")
		m.setProgress(jobID, Progress{Text: "Cancelling..."})
		cancel()
		return nil
	default:
		return errors.New("only queued or running transfers can be cancelled")
	}
}

// Discard cancels a queued or running job (if needed), waits for the worker to
// release it, and then deletes its database record and files. Waiting avoids a
// race where the worker recreates a directory after the cleanup.
func (m *Manager) Discard(ctx context.Context, jobID string) error {
	deadline := time.Now().Add(discardTimeout)
	cancelledState := ""
	for {
		job, err := m.store.GetJob(ctx, jobID)
		if errors.Is(err, db.ErrNotFound) {
			m.removeJobDir(jobID)
			m.forget(jobID)
			return nil
		}
		if err != nil {
			return err
		}
		if !db.IsActive(job.State) {
			break
		}
		if time.Now().After(deadline) {
			return errors.New("the transfer did not stop in time; try again")
		}
		// Cancel once per state. A queued job may start between the read and
		// the cancel; the next loop iteration sees the new state and retries.
		if job.State != cancelledState {
			if err := m.Cancel(ctx, jobID); err == nil {
				cancelledState = job.State
			} else {
				m.logger.Debug("discard cancel retry", "id", jobID, "error", err)
			}
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(discardPollInterval):
		}
	}
	if err := m.store.DeleteJob(ctx, jobID); err != nil {
		return err
	}
	m.removeJobDir(jobID)
	m.forget(jobID)
	return nil
}

func (m *Manager) forget(jobID string) {
	m.mu.Lock()
	delete(m.progress, jobID)
	m.mu.Unlock()
	m.cancelMu.Lock()
	delete(m.userCancelled, jobID)
	m.cancelMu.Unlock()
}

func (m *Manager) wasUserCancelled(jobID string) bool {
	m.cancelMu.Lock()
	defer m.cancelMu.Unlock()
	return m.userCancelled[jobID]
}

func (m *Manager) registerCancel(jobID string, cancel context.CancelFunc) {
	m.cancelMu.Lock()
	defer m.cancelMu.Unlock()
	m.jobCancels[jobID] = cancel
	delete(m.userCancelled, jobID)
}

func (m *Manager) unregisterCancel(jobID string) {
	m.cancelMu.Lock()
	defer m.cancelMu.Unlock()
	delete(m.jobCancels, jobID)
	delete(m.userCancelled, jobID)
}

// Shutdown stops the worker and waits for its cleanup. The running job is
// marked failed by the worker itself.
func (m *Manager) Shutdown(ctx context.Context) error {
	m.mu.Lock()
	m.closing = true
	m.mu.Unlock()
	m.cancel()
	done := make(chan struct{})
	go func() {
		m.wg.Wait()
		close(done)
	}()
	select {
	case <-done:
		return nil
	case <-ctx.Done():
		return errors.New("background worker did not stop in time")
	}
}

// DeleteImage removes a job's tag from Docker Hub.
func (m *Manager) DeleteImage(ctx context.Context, jobID string) error {
	job, err := m.store.GetJob(ctx, jobID)
	if err != nil {
		return err
	}
	if job.Image == "" {
		return errors.New("this job has no pushed image")
	}
	if job.ImageDeleted {
		return nil
	}
	repo, tag, err := dockerhub.SplitImage(job.Image)
	if err != nil {
		return err
	}
	if err := m.hub.DeleteTag(ctx, repo, tag); err != nil {
		return err
	}
	if err := m.store.SetImageDeleted(ctx, jobID); err != nil {
		return err
	}
	m.appendLog(ctx, jobID, "Docker Hub image tag deleted.")
	return nil
}

// PurgeImages deletes every remaining tag for jobs finished before the cutoff.
func (m *Manager) PurgeImages(ctx context.Context, days int) (int, []string, error) {
	if days < 1 {
		return 0, nil, errors.New("days must be at least 1")
	}
	cutoff := time.Now().AddDate(0, 0, -days)
	jobs, err := m.store.ListDoneBefore(ctx, cutoff)
	if err != nil {
		return 0, nil, err
	}
	deleted := 0
	var failures []string
	for _, job := range jobs {
		repo, tag, err := dockerhub.SplitImage(job.Image)
		if err == nil {
			err = m.hub.DeleteTag(ctx, repo, tag)
		}
		if err != nil {
			failures = append(failures, fmt.Sprintf("%s: %v", job.Image, err))
			continue
		}
		if err := m.store.SetImageDeleted(ctx, job.ID); err != nil {
			failures = append(failures, fmt.Sprintf("%s: %v", job.Image, err))
			continue
		}
		m.appendLog(ctx, job.ID, "Docker Hub image tag deleted by manual purge.")
		deleted++
	}
	return deleted, failures, nil
}

func (m *Manager) setProgress(jobID string, p Progress) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.progress[jobID] = p
}

func (m *Manager) appendLog(ctx context.Context, jobID, message string) {
	if strings.Contains(message, m.cfg.DockerHubToken) {
		message = strings.ReplaceAll(message, m.cfg.DockerHubToken, "[redacted]")
	}
	m.logger.Info("job", "id", jobID, "message", message)
	if err := m.store.AppendLog(ctx, jobID, message); err != nil && ctx.Err() == nil {
		m.logger.Error("append job log", "id", jobID, "error", err)
	}
}

func (m *Manager) failJob(jobID, message string) {
	message = strings.TrimSpace(message)
	if message == "" {
		message = "job failed"
	}
	bg, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := m.store.Fail(bg, jobID, message); err != nil {
		m.logger.Error("mark job failed", "id", jobID, "error", err)
	}
	m.appendLog(bg, jobID, "ERROR: "+message)
	m.setProgress(jobID, Progress{Text: "Failed: " + message})
}

func (m *Manager) deleteOrphanTag(jobID, image string) {
	repo, tag, err := dockerhub.SplitImage(image)
	if err != nil {
		m.logger.Error("cannot parse image for orphan cleanup", "id", jobID, "image", image, "error", err)
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	if err := m.hub.DeleteTag(ctx, repo, tag); err != nil {
		m.logger.Error("orphan image delete failed", "id", jobID, "image", image, "error", err)
		return
	}
	if err := m.store.SetImageDeleted(ctx, jobID); err != nil {
		m.logger.Error("mark orphan image deleted", "id", jobID, "error", err)
	}
}

// cleanupJobDirIfTerminal keeps files for a job that is still queued or
// running (for example when a transient database error aborts the worker) and
// removes them once the job reached a terminal state.
func (m *Manager) cleanupJobDirIfTerminal(jobID string) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	job, err := m.store.GetJob(ctx, jobID)
	if errors.Is(err, db.ErrNotFound) {
		m.removeJobDir(jobID)
		return
	}
	if err != nil {
		m.logger.Error("check job before cleanup", "id", jobID, "error", err)
		return
	}
	if db.IsTerminal(job.State) {
		m.removeJobDir(jobID)
	}
}

func (m *Manager) removeJobDir(jobID string) {
	dir, err := safename.JobDir(m.cfg.DataDir, jobID)
	if err != nil {
		return
	}
	if err := os.RemoveAll(dir); err != nil {
		m.logger.Error("remove job directory", "id", jobID, "error", err)
	}
}

func (m *Manager) worker() {
	for {
		select {
		case <-m.ctx.Done():
			return
		case jobID := <-m.queue:
			if m.ctx.Err() != nil {
				return
			}
			jobCtx, jobCancel := context.WithCancel(m.ctx)
			m.registerCancel(jobID, jobCancel)
			m.process(jobCtx, jobID)
			jobCancel()
			m.unregisterCancel(jobID)
		}
	}
}

func (m *Manager) process(ctx context.Context, jobID string) {
	m.mu.Lock()
	m.current = jobID
	m.mu.Unlock()
	defer func() {
		m.mu.Lock()
		if m.current == jobID {
			m.current = ""
		}
		m.mu.Unlock()
		m.cleanupJobDirIfTerminal(jobID)
		m.forget(jobID)
	}()
	defer func() {
		if r := recover(); r != nil {
			m.logger.Error("worker panic", "id", jobID, "panic", r, "stack", string(debug.Stack()))
			if ctx.Err() != nil {
				m.failJob(jobID, "interrupted by shutdown")
			} else {
				m.failJob(jobID, "internal error while processing the job; check the server logs")
			}
		}
	}()

	job, err := m.store.GetJob(ctx, jobID)
	if errors.Is(err, db.ErrNotFound) {
		// The job was discarded before the worker reached it.
		return
	}
	if err != nil {
		m.logger.Error("load queued job", "id", jobID, "error", err)
		return
	}
	// Atomic transition: a concurrent cancel marks the job failed instead, and
	// this worker then leaves it alone.
	ok, err := m.store.Transition(ctx, jobID, db.StateQueued, db.StateDownloading, "")
	if err != nil {
		m.logger.Error("start job", "id", jobID, "error", err)
		return
	}
	if !ok {
		return
	}
	m.appendLog(ctx, jobID, "Worker started.")
	m.setProgress(jobID, Progress{Text: "Preparing downloads"})

	if err := m.downloadAll(ctx, jobID); err != nil {
		m.finishError(ctx, jobID, err)
		return
	}
	if ctx.Err() != nil {
		m.finishError(ctx, jobID, errors.New("transfer stopped"))
		return
	}

	if err := m.store.SetState(ctx, jobID, db.StateBuilding, ""); err != nil {
		m.finishError(ctx, jobID, err)
		return
	}
	m.appendLog(ctx, jobID, "Building image layers from disk (streamed; no second copy is created).")
	m.setProgress(jobID, Progress{Text: "Building image"})

	files, err := m.store.ListDoneFiles(ctx, jobID)
	if err != nil {
		m.finishError(ctx, jobID, err)
		return
	}
	if len(files) == 0 {
		m.finishError(ctx, jobID, errors.New("no files are available to pack"))
		return
	}
	inputs := make([]imagebuild.InputFile, 0, len(files))
	jobDir, err := safename.JobDir(m.cfg.DataDir, jobID)
	if err != nil {
		m.finishError(ctx, jobID, err)
		return
	}
	for _, f := range files {
		path, err := jobFilePath(jobDir, f.Name)
		if err != nil {
			m.finishError(ctx, jobID, err)
			return
		}
		inputs = append(inputs, imagebuild.InputFile{
			Name: f.Name, Path: path, Size: f.Size, SHA256: f.SHA256, MD5: f.MD5,
		})
	}

	passphrase := ""
	if job.HasPassphrase {
		passphrase, err = secretbox.Open(m.cfg.SecretKey, job.PassphraseEnc)
		if err != nil {
			m.finishError(ctx, jobID, err)
			return
		}
		m.appendLog(ctx, jobID, "Files will be encrypted with the job passphrase.")
	}
	if job.Compress {
		m.appendLog(ctx, jobID, "Files will be gzip-compressed when that makes them smaller.")
	}
	opts := imagebuild.Options{
		Compress:   job.Compress,
		Passphrase: passphrase,
		OnTag: func(name string) {
			bg, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			defer cancel()
			if err := m.store.SetImage(bg, jobID, name); err != nil {
				m.logger.Error("record image tag before push", "id", jobID, "error", err)
			}
		},
	}
	for i := range inputs {
		inputs[i].Compress = job.Compress
		inputs[i].Encrypt = passphrase != ""
		inputs[i].Passphrase = passphrase
	}

	image, err := m.builder.BuildAndPush(
		ctx,
		inputs,
		opts,
		func(line string) { m.appendLog(ctx, jobID, line) },
		func(phase string) {
			if phase == db.StatePushing {
				if err := m.store.SetState(ctx, jobID, db.StatePushing, ""); err != nil {
					m.logger.Error("set pushing state", "id", jobID, "error", err)
				}
				m.appendLog(ctx, jobID, "Pushing image to Docker Hub.")
				m.setProgress(jobID, Progress{Text: "Pushing image", Done: 0, Total: 0})
			}
		},
		func(u v1.Update) {
			m.setProgress(jobID, Progress{Text: "Pushing image", Done: u.Complete, Total: u.Total})
		},
	)
	passphrase = ""
	if err != nil {
		if image != "" {
			bg, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			if setErr := m.store.SetImage(bg, jobID, image); setErr != nil {
				m.logger.Error("record image after failed push", "id", jobID, "error", setErr)
			} else {
				m.appendLog(bg, jobID, fmt.Sprintf("Recorded image tag %s so it can be deleted from Docker Hub.", image))
			}
			cancel()
		}
		m.finishError(ctx, jobID, err)
		return
	}
	bg, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	total, count, err := m.store.RecalcTotals(bg, jobID)
	if err != nil {
		m.finishError(ctx, jobID, err)
		return
	}
	if err := m.store.Complete(bg, jobID, image, total, count); err != nil {
		_ = m.store.SetImage(bg, jobID, image)
		m.failJob(jobID, "image was pushed but the job record could not be saved: "+err.Error())
		return
	}
	m.appendLog(bg, jobID, fmt.Sprintf("Done. Image: %s", image))
	m.setProgress(jobID, Progress{Text: "Done", Done: total, Total: total})
}

func (m *Manager) downloadAll(ctx context.Context, jobID string) error {
	urls, err := m.store.ListPendingURLs(ctx, jobID)
	if err != nil {
		return err
	}
	if len(urls) == 0 {
		return nil
	}
	jobDir, err := safename.JobDir(m.cfg.DataDir, jobID)
	if err != nil {
		return err
	}
	downloadDir := filepath.Join(jobDir, "downloads")
	if err := os.MkdirAll(downloadDir, 0o750); err != nil {
		return fmt.Errorf("create download directory: %w", err)
	}
	defer os.RemoveAll(downloadDir)

	for _, entry := range urls {
		if err := ctx.Err(); err != nil {
			return errors.New("interrupted by shutdown")
		}
		current, err := m.store.DeclaredTotal(ctx, jobID)
		if err != nil {
			return err
		}
		remaining := m.cfg.MaxTotalBytes - current
		if remaining <= 0 {
			return fmt.Errorf("download %s would exceed the %s job limit",
				entry.URL, formatBytes(m.cfg.MaxTotalBytes))
		}
		// URL sizes are unknown until the download starts, so reserve up to
		// 2 GiB (or the remaining quota, if smaller) before each download.
		need := remaining
		if need > 2<<30 {
			need = 2 << 30
		}
		free, err := FreeDiskBytes(m.cfg.DataDir)
		if err != nil {
			return err
		}
		if free < need {
			return fmt.Errorf("not enough free disk space to download %s: need about %s free, only %s is available in %s",
				entry.URL, formatBytes(need), formatBytes(free), m.cfg.DataDir)
		}
		tempPath := filepath.Join(downloadDir, fmt.Sprintf("%d.part", entry.ID))
		label := fmt.Sprintf("Downloading %s", entry.URL)
		m.appendLog(ctx, jobID, label)
		m.setProgress(jobID, Progress{Text: label})
		res, err := m.dl.Download(ctx, entry.URL, tempPath, remaining,
			func(done, total int64) {
				m.setProgress(jobID, Progress{Text: label, Done: done, Total: total})
			})
		if err != nil {
			_ = os.Remove(tempPath)
			if ctx.Err() != nil {
				return errors.New("interrupted by shutdown")
			}
			return fmt.Errorf("download %s failed: %w", entry.URL, err)
		}
		used, err := m.store.UsedNames(ctx, jobID)
		if err != nil {
			_ = os.Remove(tempPath)
			return err
		}
		suggested := res.Filename
		if suggested == "download" {
			suggested = fmt.Sprintf("download-%d", entry.ID)
		}
		name := safename.Unique(suggested, used)
		finalPath, err := jobFilePath(jobDir, name)
		if err != nil {
			_ = os.Remove(tempPath)
			return err
		}
		if err := os.MkdirAll(filepath.Dir(finalPath), 0o750); err != nil {
			_ = os.Remove(tempPath)
			return fmt.Errorf("create files directory: %w", err)
		}
		if _, err := os.Stat(finalPath); err == nil {
			_ = os.Remove(tempPath)
			return fmt.Errorf("a file named %q already exists in this job", name)
		}
		if err := os.Rename(tempPath, finalPath); err != nil {
			_ = os.Remove(tempPath)
			return fmt.Errorf("save downloaded file: %w", err)
		}
		if err := m.store.MarkURLDone(ctx, jobID, entry.ID, name, res.Size, res.SHA256, res.MD5); err != nil {
			return err
		}
		m.appendLog(ctx, jobID, fmt.Sprintf("Downloaded %s as %q (%s).", entry.URL, name, formatBytes(res.Size)))
	}
	return nil
}

func jobFilePath(jobDir, name string) (string, error) {
	clean := safename.Sanitize(name)
	if clean == "" || clean != name {
		return "", errors.New("unsafe filename in job")
	}
	base := filepath.Join(jobDir, "files")
	p := filepath.Join(base, clean)
	rel, err := filepath.Rel(base, p)
	if err != nil || rel == ".." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) || filepath.IsAbs(rel) {
		return "", errors.New("file path escapes the job directory")
	}
	return p, nil
}

func (m *Manager) finishError(ctx context.Context, jobID string, err error) {
	if ctx.Err() != nil {
		if m.wasUserCancelled(jobID) {
			m.failJob(jobID, "cancelled by user")
			return
		}
		m.failJob(jobID, "interrupted by shutdown")
		return
	}
	msg := err.Error()
	m.failJob(jobID, msg)
}
