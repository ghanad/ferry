// Package db stores Ferry job metadata in SQLite.
package db

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"net/url"
	"path/filepath"
	"strings"
	"sync"
	"time"

	_ "modernc.org/sqlite"
)

// Job states.
const (
	StateDraft       = "draft"
	StateQueued      = "queued"
	StateDownloading = "downloading"
	StateBuilding    = "building"
	StatePushing     = "pushing"
	StateDone        = "done"
	StateFailed      = "failed"
)

const (
	sourceUpload  = "upload"
	sourceURL     = "url"
	statusDone    = "done"
	statusPending = "pending"
	maxLogBytes   = 256 * 1024
)

// IsActive reports whether a state means the worker owns the job.
func IsActive(state string) bool {
	switch state {
	case StateQueued, StateDownloading, StateBuilding, StatePushing:
		return true
	}
	return false
}

// IsTerminal reports whether a job can no longer change state by itself.
func IsTerminal(state string) bool {
	return state == StateDone || state == StateFailed
}

// Job is the metadata retained for every transfer.
type Job struct {
	ID            string
	State         string
	CreatedAt     time.Time
	UpdatedAt     time.Time
	FinishedAt    time.Time
	TotalBytes    int64
	FileCount     int
	Image         string
	Error         string
	Log           string
	ImageDeleted  bool
	Compress      bool
	Encrypted     bool
	HasPassphrase bool
	PassphraseEnc string
}

// File is one finished file in a job, or a pending URL entry.
type File struct {
	ID        int64
	JobID     string
	Name      string
	Size      int64
	SHA256    string
	MD5       string
	Source    string
	URL       string
	Status    string
	CreatedAt time.Time
}

// Upload is an in-progress (or just-completed) chunked upload.
type Upload struct {
	ID               string
	JobID            string
	Filename         string
	OriginalFilename string
	DeclaredSize     int64
	Received         int64
	Completed        bool
	CreatedAt        time.Time
}

// Store wraps the SQLite database. All access goes through one connection,
// which together with WAL and busy_timeout keeps concurrent writes safe.
type Store struct {
	db      *sql.DB
	dataDir string
	writeMu sync.Mutex
}

// Open creates or opens the database and applies the schema.
func Open(path, dataDir string) (*Store, error) {
	u := &url.URL{Scheme: "file", Path: filepath.ToSlash(path)}
	q := u.Query()
	q.Add("_pragma", "busy_timeout(5000)")
	q.Add("_pragma", "journal_mode(WAL)")
	q.Add("_pragma", "synchronous(NORMAL)")
	q.Add("_pragma", "foreign_keys(ON)")
	u.RawQuery = q.Encode()

	sqldb, err := sql.Open("sqlite", u.String())
	if err != nil {
		return nil, fmt.Errorf("open database: %w", err)
	}
	sqldb.SetMaxOpenConns(1)
	sqldb.SetMaxIdleConns(1)

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := sqldb.PingContext(ctx); err != nil {
		_ = sqldb.Close()
		return nil, fmt.Errorf("connect to database: %w", err)
	}
	s := &Store{db: sqldb, dataDir: dataDir}
	if err := s.migrate(ctx); err != nil {
		_ = sqldb.Close()
		return nil, err
	}
	return s, nil
}

func (s *Store) migrate(ctx context.Context) error {
	stmts := []string{
		`CREATE TABLE IF NOT EXISTS jobs (
			id TEXT PRIMARY KEY,
			state TEXT NOT NULL,
			created_at INTEGER NOT NULL,
			updated_at INTEGER NOT NULL,
			finished_at INTEGER NOT NULL DEFAULT 0,
			total_bytes INTEGER NOT NULL DEFAULT 0,
			file_count INTEGER NOT NULL DEFAULT 0,
			image TEXT NOT NULL DEFAULT '',
			error TEXT NOT NULL DEFAULT '',
			log TEXT NOT NULL DEFAULT '',
			image_deleted INTEGER NOT NULL DEFAULT 0,
			compress INTEGER NOT NULL DEFAULT 0,
			encrypted INTEGER NOT NULL DEFAULT 0,
			passphrase_enc TEXT NOT NULL DEFAULT ''
		)`,
		`CREATE INDEX IF NOT EXISTS idx_jobs_state ON jobs(state)`,
		`CREATE INDEX IF NOT EXISTS idx_jobs_created ON jobs(created_at DESC)`,
		`CREATE TABLE IF NOT EXISTS uploads (
			id TEXT PRIMARY KEY,
			job_id TEXT NOT NULL REFERENCES jobs(id) ON DELETE CASCADE,
			filename TEXT NOT NULL,
			original_filename TEXT NOT NULL DEFAULT '',
			declared_size INTEGER NOT NULL,
			received INTEGER NOT NULL DEFAULT 0,
			completed INTEGER NOT NULL DEFAULT 0,
			created_at INTEGER NOT NULL,
			updated_at INTEGER NOT NULL
		)`,
		`CREATE INDEX IF NOT EXISTS idx_uploads_job ON uploads(job_id)`,
		`CREATE TABLE IF NOT EXISTS job_files (
			id INTEGER PRIMARY KEY AUTOINCREMENT,
			job_id TEXT NOT NULL REFERENCES jobs(id) ON DELETE CASCADE,
			name TEXT NOT NULL DEFAULT '',
			size INTEGER NOT NULL DEFAULT 0,
			sha256 TEXT NOT NULL DEFAULT '',
			md5 TEXT NOT NULL DEFAULT '',
			source TEXT NOT NULL,
			url TEXT NOT NULL DEFAULT '',
			status TEXT NOT NULL DEFAULT 'done',
			created_at INTEGER NOT NULL,
			updated_at INTEGER NOT NULL
		)`,
		`CREATE INDEX IF NOT EXISTS idx_job_files_job ON job_files(job_id)`,
		`CREATE UNIQUE INDEX IF NOT EXISTS idx_job_files_done_name
			ON job_files(job_id, name) WHERE status = 'done'`,
	}
	for _, stmt := range stmts {
		if _, err := s.db.ExecContext(ctx, stmt); err != nil {
			return fmt.Errorf("initialize database: %w", err)
		}
	}
	if _, err := s.db.ExecContext(ctx, `PRAGMA busy_timeout = 5000`); err != nil {
		return fmt.Errorf("configure database timeout: %w", err)
	}
	if err := s.ensureColumn(ctx, "job_files", "md5", "TEXT NOT NULL DEFAULT ''"); err != nil {
		return err
	}
	if err := s.ensureColumn(ctx, "jobs", "compress", "INTEGER NOT NULL DEFAULT 0"); err != nil {
		return err
	}
	if err := s.ensureColumn(ctx, "uploads", "original_filename", "TEXT NOT NULL DEFAULT ''"); err != nil {
		return err
	}
	if err := s.ensureColumn(ctx, "jobs", "encrypted", "INTEGER NOT NULL DEFAULT 0"); err != nil {
		return err
	}
	if err := s.ensureColumn(ctx, "jobs", "passphrase_enc", "TEXT NOT NULL DEFAULT ''"); err != nil {
		return err
	}
	return nil
}

// ensureColumn adds a column to an existing table when upgrading an old
// database. It is a no-op when the column already exists.
func (s *Store) ensureColumn(ctx context.Context, table, column, definition string) error {
	rows, err := s.db.QueryContext(ctx, `PRAGMA table_info(`+table+`)`)
	if err != nil {
		return fmt.Errorf("inspect %s table: %w", table, err)
	}
	defer rows.Close()
	found := false
	for rows.Next() {
		var (
			cid       int
			name      string
			ctype     string
			notnull   int
			dfltValue sql.NullString
			pk        int
		)
		if err := rows.Scan(&cid, &name, &ctype, &notnull, &dfltValue, &pk); err != nil {
			return fmt.Errorf("inspect %s table: %w", table, err)
		}
		if name == column {
			found = true
		}
	}
	if err := rows.Err(); err != nil {
		return err
	}
	if found {
		return nil
	}
	if _, err := s.db.ExecContext(ctx, `ALTER TABLE `+table+` ADD COLUMN `+column+` `+definition); err != nil {
		return fmt.Errorf("upgrade %s table: %w", table, err)
	}
	return nil
}

// Close closes the database.
func (s *Store) Close() error {
	return s.db.Close()
}

// DataDir returns the configured data directory.
func (s *Store) DataDir() string { return s.dataDir }

// CreateJob inserts a new draft job.
func (s *Store) CreateJob(ctx context.Context, id string) (*Job, error) {
	now := time.Now().Unix()
	s.writeMu.Lock()
	defer s.writeMu.Unlock()
	if _, err := s.db.ExecContext(ctx,
		`INSERT INTO jobs (id, state, created_at, updated_at) VALUES (?, ?, ?, ?)`,
		id, StateDraft, now, now,
	); err != nil {
		return nil, fmt.Errorf("create job: %w", err)
	}
	return s.getJob(ctx, id)
}

// GetJob loads one job including its log.
func (s *Store) GetJob(ctx context.Context, id string) (*Job, error) {
	return s.getJob(ctx, id)
}

func (s *Store) getJob(ctx context.Context, id string) (*Job, error) {
	row := s.db.QueryRowContext(ctx, `SELECT id, state, created_at, updated_at, finished_at,
		total_bytes, file_count, image, error, log, image_deleted, compress, encrypted, passphrase_enc FROM jobs WHERE id = ?`, id)
	j, err := scanJob(row, true)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return nil, ErrNotFound
		}
		return nil, fmt.Errorf("load job: %w", err)
	}
	return j, nil
}

// ErrNotFound is returned when a job or file does not exist.
var ErrNotFound = errors.New("not found")

// ErrNotDraft means a job stopped being a draft during an operation.
var ErrNotDraft = errors.New("job is no longer a draft")

type rowScanner interface {
	Scan(dest ...any) error
}

func scanJob(row rowScanner, withLog bool) (*Job, error) {
	var (
		j           Job
		created     int64
		updated     int64
		finished    int64
		imageDel    int
		compress    int
		encrypted   int
		logContents string
		passEnc     string
	)
	err := row.Scan(&j.ID, &j.State, &created, &updated, &finished,
		&j.TotalBytes, &j.FileCount, &j.Image, &j.Error, &logContents, &imageDel, &compress, &encrypted, &passEnc)
	if err != nil {
		return nil, err
	}
	j.CreatedAt = time.Unix(created, 0)
	j.UpdatedAt = time.Unix(updated, 0)
	if finished > 0 {
		j.FinishedAt = time.Unix(finished, 0)
	}
	j.ImageDeleted = imageDel != 0
	j.Compress = compress != 0
	j.Encrypted = encrypted != 0
	j.PassphraseEnc = passEnc
	j.HasPassphrase = passEnc != ""
	if withLog {
		j.Log = logContents
	}
	return &j, nil
}

func scanJobNoLog(row rowScanner) (*Job, error) {
	var (
		j         Job
		created   int64
		updated   int64
		finished  int64
		imageDel  int
		compress  int
		encrypted int
		passEnc   string
	)
	err := row.Scan(&j.ID, &j.State, &created, &updated, &finished,
		&j.TotalBytes, &j.FileCount, &j.Image, &j.Error, &imageDel, &compress, &encrypted, &passEnc)
	if err != nil {
		return nil, err
	}
	j.CreatedAt = time.Unix(created, 0)
	j.UpdatedAt = time.Unix(updated, 0)
	if finished > 0 {
		j.FinishedAt = time.Unix(finished, 0)
	}
	j.ImageDeleted = imageDel != 0
	j.Compress = compress != 0
	j.Encrypted = encrypted != 0
	j.PassphraseEnc = passEnc
	j.HasPassphrase = passEnc != ""
	return &j, nil
}

// ListJobs returns the newest jobs without their logs.
func (s *Store) ListJobs(ctx context.Context, limit int) ([]Job, error) {
	if limit <= 0 || limit > 1000 {
		limit = 100
	}
	rows, err := s.db.QueryContext(ctx, `SELECT id, state, created_at, updated_at, finished_at,
		total_bytes, file_count, image, error, image_deleted, compress, encrypted, passphrase_enc FROM jobs
		ORDER BY created_at DESC LIMIT ?`, limit)
	if err != nil {
		return nil, fmt.Errorf("list jobs: %w", err)
	}
	defer rows.Close()
	var out []Job
	for rows.Next() {
		j, err := scanJobNoLog(rows)
		if err != nil {
			return nil, fmt.Errorf("read job: %w", err)
		}
		out = append(out, *j)
	}
	return out, rows.Err()
}

// ListByState returns jobs in a given state.
func (s *Store) ListByState(ctx context.Context, state string) ([]Job, error) {
	rows, err := s.db.QueryContext(ctx, `SELECT id, state, created_at, updated_at, finished_at,
		total_bytes, file_count, image, error, image_deleted, compress, encrypted, passphrase_enc FROM jobs
		WHERE state = ? ORDER BY created_at ASC`, state)
	if err != nil {
		return nil, fmt.Errorf("list jobs: %w", err)
	}
	defer rows.Close()
	var out []Job
	for rows.Next() {
		j, err := scanJobNoLog(rows)
		if err != nil {
			return nil, fmt.Errorf("read job: %w", err)
		}
		out = append(out, *j)
	}
	return out, rows.Err()
}

// ListActive returns queued and running jobs, oldest first. The first entry is
// the job the worker is processing (or will process next).
func (s *Store) ListActive(ctx context.Context) ([]Job, error) {
	rows, err := s.db.QueryContext(ctx, `SELECT id, state, created_at, updated_at, finished_at,
		total_bytes, file_count, image, error, image_deleted, compress, encrypted, passphrase_enc FROM jobs
		WHERE state IN (?, ?, ?, ?) ORDER BY created_at ASC, rowid ASC`,
		StateQueued, StateDownloading, StateBuilding, StatePushing)
	if err != nil {
		return nil, fmt.Errorf("list active jobs: %w", err)
	}
	defer rows.Close()
	var out []Job
	for rows.Next() {
		j, err := scanJobNoLog(rows)
		if err != nil {
			return nil, fmt.Errorf("read active job: %w", err)
		}
		out = append(out, *j)
	}
	return out, rows.Err()
}

// ListStaleDrafts returns draft jobs untouched before cutoff.
func (s *Store) ListStaleDrafts(ctx context.Context, cutoff time.Time) ([]Job, error) {
	rows, err := s.db.QueryContext(ctx, `SELECT id, state, created_at, updated_at, finished_at,
		total_bytes, file_count, image, error, image_deleted, compress, encrypted, passphrase_enc FROM jobs
		WHERE state = ? AND updated_at < ?`, StateDraft, cutoff.Unix())
	if err != nil {
		return nil, fmt.Errorf("list stale drafts: %w", err)
	}
	defer rows.Close()
	var out []Job
	for rows.Next() {
		j, err := scanJobNoLog(rows)
		if err != nil {
			return nil, fmt.Errorf("read stale draft: %w", err)
		}
		out = append(out, *j)
	}
	return out, rows.Err()
}

// ListDoneBefore returns done jobs finished before cutoff that still have an image.
func (s *Store) ListDoneBefore(ctx context.Context, cutoff time.Time) ([]Job, error) {
	rows, err := s.db.QueryContext(ctx, `SELECT id, state, created_at, updated_at, finished_at,
		total_bytes, file_count, image, error, image_deleted, compress, encrypted, passphrase_enc FROM jobs
		WHERE state IN (?, ?) AND finished_at > 0 AND finished_at < ? AND image != '' AND image_deleted = 0`,
		StateDone, StateFailed, cutoff.Unix())
	if err != nil {
		return nil, fmt.Errorf("list old images: %w", err)
	}
	defer rows.Close()
	var out []Job
	for rows.Next() {
		j, err := scanJobNoLog(rows)
		if err != nil {
			return nil, fmt.Errorf("read old job: %w", err)
		}
		out = append(out, *j)
	}
	return out, rows.Err()
}

// Transition atomically changes state when the current state matches from.
func (s *Store) Transition(ctx context.Context, id, from, to, errMsg string) (bool, error) {
	now := time.Now().Unix()
	finished := int64(0)
	if to == StateDone || to == StateFailed {
		finished = now
	}
	s.writeMu.Lock()
	defer s.writeMu.Unlock()
	res, err := s.db.ExecContext(ctx, `UPDATE jobs SET state = ?, error = ?, updated_at = ?,
		finished_at = CASE WHEN ? IN (?, ?) THEN ? ELSE 0 END
		WHERE id = ? AND state = ?`,
		to, errMsg, now, to, StateDone, StateFailed, finished, id, from)
	if err != nil {
		return false, fmt.Errorf("update job state: %w", err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return false, err
	}
	if n == 1 && (to == StateDone || to == StateFailed) {
		_, _ = s.db.ExecContext(ctx, `UPDATE jobs SET passphrase_enc = '' WHERE id = ?`, id)
	}
	return n == 1, nil
}

// SetState changes state unconditionally (used by the worker).
func (s *Store) SetState(ctx context.Context, id, to, errMsg string) error {
	now := time.Now().Unix()
	finished := int64(0)
	if to == StateDone || to == StateFailed {
		finished = now
	}
	s.writeMu.Lock()
	defer s.writeMu.Unlock()
	res, err := s.db.ExecContext(ctx, `UPDATE jobs SET state = ?, error = ?, updated_at = ?,
		finished_at = CASE WHEN ? IN (?, ?) THEN ? ELSE 0 END WHERE id = ?`,
		to, errMsg, now, to, StateDone, StateFailed, finished, id)
	if err != nil {
		return fmt.Errorf("update job state: %w", err)
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return ErrNotFound
	}
	if to == StateDone || to == StateFailed {
		_, _ = s.db.ExecContext(ctx, `UPDATE jobs SET passphrase_enc = '' WHERE id = ?`, id)
	}
	return nil
}

// Fail marks a job failed with a human-readable message.
func (s *Store) Fail(ctx context.Context, id, message string) error {
	return s.SetState(ctx, id, StateFailed, message)
}

// Complete marks a job done and records its image.
func (s *Store) Complete(ctx context.Context, id, image string, total int64, count int) error {
	now := time.Now().Unix()
	s.writeMu.Lock()
	defer s.writeMu.Unlock()
	res, err := s.db.ExecContext(ctx, `UPDATE jobs SET state = ?, image = ?, error = '',
		total_bytes = ?, file_count = ?, updated_at = ?, finished_at = ? WHERE id = ?`,
		StateDone, image, total, count, now, now, id)
	if err != nil {
		return fmt.Errorf("finish job: %w", err)
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return ErrNotFound
	}
	_, _ = s.db.ExecContext(ctx, `UPDATE jobs SET passphrase_enc = '' WHERE id = ?`, id)
	return nil
}

// SetImage records the image tag even when the job later fails, so retention
// and the History page can still delete the tag from Docker Hub.
func (s *Store) SetImage(ctx context.Context, id, image string) error {
	s.writeMu.Lock()
	defer s.writeMu.Unlock()
	_, err := s.db.ExecContext(ctx, `UPDATE jobs SET image = ?, updated_at = ? WHERE id = ?`,
		image, time.Now().Unix(), id)
	if err != nil {
		return fmt.Errorf("record image name: %w", err)
	}
	return nil
}

// SetImageDeleted flags that the job's Docker Hub tag was removed.
func (s *Store) SetImageDeleted(ctx context.Context, id string) error {
	s.writeMu.Lock()
	defer s.writeMu.Unlock()
	_, err := s.db.ExecContext(ctx, `UPDATE jobs SET image_deleted = 1, updated_at = ? WHERE id = ?`,
		time.Now().Unix(), id)
	if err != nil {
		return fmt.Errorf("mark image deleted: %w", err)
	}
	return nil
}

// AppendLog appends one timestamped line and caps the stored log size.
func (s *Store) AppendLog(ctx context.Context, id, line string) error {
	if !strings.HasSuffix(line, "\n") {
		line += "\n"
	}
	stamp := time.Now().UTC().Format("2006-01-02 15:04:05")
	s.writeMu.Lock()
	defer s.writeMu.Unlock()
	_, err := s.db.ExecContext(ctx, `UPDATE jobs SET log = substr(log || ?, ?), updated_at = ? WHERE id = ?`,
		stamp+" "+line, -maxLogBytes, time.Now().Unix(), id)
	if err != nil {
		return fmt.Errorf("append job log: %w", err)
	}
	return nil
}

// Touch updates the job's updated_at timestamp.
func (s *Store) Touch(ctx context.Context, id string) error {
	s.writeMu.Lock()
	defer s.writeMu.Unlock()
	_, err := s.db.ExecContext(ctx, `UPDATE jobs SET updated_at = ? WHERE id = ?`,
		time.Now().Unix(), id)
	if err != nil {
		return fmt.Errorf("touch job: %w", err)
	}
	return nil
}

// SetJobOptions stores the optional compression flag and the encrypted
// passphrase for a draft job. The passphrase is never stored in plain text.
func (s *Store) SetJobOptions(ctx context.Context, jobID, passphraseEnc string, compress bool) error {
	flag := 0
	if compress {
		flag = 1
	}
	s.writeMu.Lock()
	defer s.writeMu.Unlock()
	encrypted := 0
	if passphraseEnc != "" {
		encrypted = 1
	}
	res, err := s.db.ExecContext(ctx, `UPDATE jobs SET compress = ?, encrypted = ?, passphrase_enc = ?, updated_at = ?
		WHERE id = ? AND state = ?`, flag, encrypted, passphraseEnc, time.Now().Unix(), jobID, StateDraft)
	if err != nil {
		return fmt.Errorf("save job options: %w", err)
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return ErrNotDraft
	}
	return nil
}

// ClearJobPassphrase removes the stored passphrase once a job is finished.
func (s *Store) ClearJobPassphrase(ctx context.Context, jobID string) error {
	s.writeMu.Lock()
	defer s.writeMu.Unlock()
	_, err := s.db.ExecContext(ctx, `UPDATE jobs SET passphrase_enc = '' WHERE id = ?`, jobID)
	if err != nil {
		return fmt.Errorf("clear job passphrase: %w", err)
	}
	return nil
}

// DeleteStaleDraft atomically removes a draft that is still untouched before
// cutoff. It returns false if the job changed state or was touched meanwhile.
func (s *Store) DeleteStaleDraft(ctx context.Context, id string, cutoff time.Time) (bool, error) {
	s.writeMu.Lock()
	defer s.writeMu.Unlock()
	res, err := s.db.ExecContext(ctx, `DELETE FROM jobs WHERE id = ? AND state = ? AND updated_at < ?`,
		id, StateDraft, cutoff.Unix())
	if err != nil {
		return false, fmt.Errorf("delete stale draft: %w", err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return false, err
	}
	return n == 1, nil
}

// DeleteJob removes a job and all dependent rows.
func (s *Store) DeleteJob(ctx context.Context, id string) error {
	s.writeMu.Lock()
	defer s.writeMu.Unlock()
	_, err := s.db.ExecContext(ctx, `DELETE FROM jobs WHERE id = ?`, id)
	if err != nil {
		return fmt.Errorf("delete job: %w", err)
	}
	return nil
}

// RecalcTotals recomputes the declared total and finished file count.
func (s *Store) RecalcTotals(ctx context.Context, jobID string) (int64, int, error) {
	s.writeMu.Lock()
	defer s.writeMu.Unlock()
	return s.recalcTotalsLocked(ctx, jobID)
}

func (s *Store) recalcTotalsLocked(ctx context.Context, jobID string) (int64, int, error) {
	var pendingUploads int64
	if err := s.db.QueryRowContext(ctx, `SELECT COALESCE(SUM(declared_size), 0)
		FROM uploads WHERE job_id = ? AND completed = 0`, jobID).Scan(&pendingUploads); err != nil {
		return 0, 0, fmt.Errorf("calculate upload total: %w", err)
	}
	var doneBytes int64
	var doneCount int
	if err := s.db.QueryRowContext(ctx, `SELECT COALESCE(SUM(size), 0), COUNT(*)
		FROM job_files WHERE job_id = ? AND status = 'done'`, jobID).Scan(&doneBytes, &doneCount); err != nil {
		return 0, 0, fmt.Errorf("calculate file total: %w", err)
	}
	total := pendingUploads + doneBytes
	if _, err := s.db.ExecContext(ctx, `UPDATE jobs SET total_bytes = ?, file_count = ?, updated_at = ?
		WHERE id = ?`, total, doneCount, time.Now().Unix(), jobID); err != nil {
		return 0, 0, fmt.Errorf("update job totals: %w", err)
	}
	return total, doneCount, nil
}

// DeclaredTotal returns the sum of pending upload declarations plus finished
// file sizes. It is the number enforced against FERRY_MAX_TOTAL_BYTES.
func (s *Store) DeclaredTotal(ctx context.Context, jobID string) (int64, error) {
	var pending int64
	err := s.db.QueryRowContext(ctx, `SELECT COALESCE(SUM(declared_size), 0)
		FROM uploads WHERE job_id = ? AND completed = 0`, jobID).Scan(&pending)
	if err != nil {
		return 0, fmt.Errorf("calculate upload total: %w", err)
	}
	var done int64
	err = s.db.QueryRowContext(ctx, `SELECT COALESCE(SUM(size), 0)
		FROM job_files WHERE job_id = ? AND status = 'done'`, jobID).Scan(&done)
	if err != nil {
		return 0, fmt.Errorf("calculate file total: %w", err)
	}
	return pending + done, nil
}

// CountPendingUploads returns how many uploads are not finalized.
func (s *Store) CountPendingUploads(ctx context.Context, jobID string) (int, error) {
	var n int
	err := s.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM uploads WHERE job_id = ? AND completed = 0`, jobID).Scan(&n)
	if err != nil {
		return 0, err
	}
	return n, nil
}

// CountFiles returns the number of finished files plus pending URL entries.
func (s *Store) CountFiles(ctx context.Context, jobID string) (int, error) {
	var n int
	err := s.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM job_files WHERE job_id = ?`, jobID).Scan(&n)
	if err != nil {
		return 0, err
	}
	return n, nil
}

// CreateUpload inserts a chunked upload reservation.
func (s *Store) CreateUpload(ctx context.Context, u *Upload) error {
	now := time.Now().Unix()
	s.writeMu.Lock()
	defer s.writeMu.Unlock()
	res, err := s.db.ExecContext(ctx, `INSERT INTO uploads
		(id, job_id, filename, original_filename, declared_size, received, completed, created_at, updated_at)
		SELECT ?, ?, ?, ?, ?, 0, 0, ?, ?
		WHERE EXISTS (SELECT 1 FROM jobs WHERE id = ? AND state = ?)`,
		u.ID, u.JobID, u.Filename, u.OriginalFilename, u.DeclaredSize, now, now, u.JobID, StateDraft)
	if err != nil {
		return fmt.Errorf("create upload: %w", err)
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return ErrNotDraft
	}
	u.CreatedAt = time.Unix(now, 0)
	_, _, _ = s.recalcTotalsLocked(ctx, u.JobID)
	return nil
}

// GetUpload loads an upload belonging to jobID.
func (s *Store) GetUpload(ctx context.Context, jobID, uploadID string) (*Upload, error) {
	var (
		u         Upload
		created   int64
		completed int
	)
	err := s.db.QueryRowContext(ctx, `SELECT id, job_id, filename, original_filename, declared_size, received, completed, created_at
		FROM uploads WHERE id = ? AND job_id = ?`, uploadID, jobID).
		Scan(&u.ID, &u.JobID, &u.Filename, &u.OriginalFilename, &u.DeclaredSize, &u.Received, &completed, &created)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, fmt.Errorf("load upload: %w", err)
	}
	u.Completed = completed != 0
	u.CreatedAt = time.Unix(created, 0)
	return &u, nil
}

// ListUploads returns in-progress uploads for a job.
func (s *Store) ListUploads(ctx context.Context, jobID string) ([]Upload, error) {
	rows, err := s.db.QueryContext(ctx, `SELECT id, job_id, filename, original_filename, declared_size, received, completed, created_at
		FROM uploads WHERE job_id = ? AND completed = 0 ORDER BY created_at ASC`, jobID)
	if err != nil {
		return nil, fmt.Errorf("list uploads: %w", err)
	}
	defer rows.Close()
	var out []Upload
	for rows.Next() {
		var (
			u         Upload
			created   int64
			completed int
		)
		if err := rows.Scan(&u.ID, &u.JobID, &u.Filename, &u.OriginalFilename, &u.DeclaredSize, &u.Received, &completed, &created); err != nil {
			return nil, err
		}
		u.Completed = completed != 0
		u.CreatedAt = time.Unix(created, 0)
		out = append(out, u)
	}
	return out, rows.Err()
}

// SetUploadReceived stores the number of bytes durably written.
func (s *Store) SetUploadReceived(ctx context.Context, jobID, uploadID string, received int64) error {
	now := time.Now().Unix()
	s.writeMu.Lock()
	defer s.writeMu.Unlock()
	res, err := s.db.ExecContext(ctx, `UPDATE uploads SET received = ?, updated_at = ?
		WHERE id = ? AND job_id = ? AND completed = 0`, received, now, uploadID, jobID)
	if err != nil {
		return fmt.Errorf("update upload progress: %w", err)
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return ErrNotFound
	}
	if _, err := s.db.ExecContext(ctx, `UPDATE jobs SET updated_at = ? WHERE id = ?`, now, jobID); err != nil {
		return fmt.Errorf("touch job: %w", err)
	}
	return nil
}

// CompleteUpload inserts the finished file and marks the upload complete.
func (s *Store) CompleteUpload(ctx context.Context, jobID, uploadID string, f *File) error {
	now := time.Now().Unix()
	s.writeMu.Lock()
	defer s.writeMu.Unlock()
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("begin upload completion: %w", err)
	}
	defer tx.Rollback()

	res, err := tx.ExecContext(ctx, `UPDATE uploads SET completed = 1, updated_at = ?
		WHERE id = ? AND job_id = ? AND completed = 0`, now, uploadID, jobID)
	if err != nil {
		return fmt.Errorf("complete upload: %w", err)
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return ErrNotFound
	}
	res, err = tx.ExecContext(ctx, `INSERT INTO job_files
		(job_id, name, size, sha256, md5, source, url, status, created_at, updated_at)
		VALUES (?, ?, ?, ?, ?, 'upload', '', 'done', ?, ?)`,
		jobID, f.Name, f.Size, f.SHA256, f.MD5, now, now)
	if err != nil {
		return fmt.Errorf("record finished file: %w", err)
	}
	id, err := res.LastInsertId()
	if err != nil {
		return err
	}
	f.ID = id
	f.JobID = jobID
	f.Source = sourceUpload
	f.Status = statusDone
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("commit upload completion: %w", err)
	}
	_, _, err = s.recalcTotalsLocked(ctx, jobID)
	return err
}

// DeleteUpload removes an unfinished upload reservation.
func (s *Store) DeleteUpload(ctx context.Context, jobID, uploadID string) error {
	s.writeMu.Lock()
	defer s.writeMu.Unlock()
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if _, err := tx.ExecContext(ctx, `DELETE FROM uploads WHERE id = ? AND job_id = ? AND completed = 0`,
		uploadID, jobID); err != nil {
		return fmt.Errorf("delete upload: %w", err)
	}
	if _, err := tx.ExecContext(ctx, `UPDATE jobs SET updated_at = ? WHERE id = ?`,
		time.Now().Unix(), jobID); err != nil {
		return err
	}
	if err := tx.Commit(); err != nil {
		return err
	}
	_, _, err = s.recalcTotalsLocked(ctx, jobID)
	return err
}

// AddURLFile inserts a pending URL entry.
func (s *Store) AddURLFile(ctx context.Context, jobID, rawURL string) (*File, error) {
	now := time.Now().Unix()
	s.writeMu.Lock()
	defer s.writeMu.Unlock()
	res, err := s.db.ExecContext(ctx, `INSERT INTO job_files
		(job_id, name, size, sha256, source, url, status, created_at, updated_at)
		SELECT ?, '', 0, '', 'url', ?, 'pending', ?, ?
		WHERE EXISTS (SELECT 1 FROM jobs WHERE id = ? AND state = ?)`,
		jobID, rawURL, now, now, jobID, StateDraft)
	if err != nil {
		return nil, fmt.Errorf("add URL: %w", err)
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return nil, ErrNotDraft
	}
	id, err := res.LastInsertId()
	if err != nil {
		return nil, err
	}
	if _, err := s.db.ExecContext(ctx, `UPDATE jobs SET updated_at = ? WHERE id = ?`, now, jobID); err != nil {
		return nil, err
	}
	return &File{ID: id, JobID: jobID, Source: sourceURL, URL: rawURL, Status: statusPending, CreatedAt: time.Unix(now, 0)}, nil
}

// ListFiles returns all file rows, including pending URLs.
func (s *Store) ListFiles(ctx context.Context, jobID string) ([]File, error) {
	rows, err := s.db.QueryContext(ctx, `SELECT id, job_id, name, size, sha256, md5, source, url, status, created_at
		FROM job_files WHERE job_id = ? ORDER BY id ASC`, jobID)
	if err != nil {
		return nil, fmt.Errorf("list files: %w", err)
	}
	defer rows.Close()
	return scanFiles(rows)
}

// ListDoneFiles returns only files that exist on disk and can be packed.
func (s *Store) ListDoneFiles(ctx context.Context, jobID string) ([]File, error) {
	rows, err := s.db.QueryContext(ctx, `SELECT id, job_id, name, size, sha256, md5, source, url, status, created_at
		FROM job_files WHERE job_id = ? AND status = 'done' ORDER BY id ASC`, jobID)
	if err != nil {
		return nil, fmt.Errorf("list finished files: %w", err)
	}
	defer rows.Close()
	return scanFiles(rows)
}

// ListPendingURLs returns URL entries not downloaded yet.
func (s *Store) ListPendingURLs(ctx context.Context, jobID string) ([]File, error) {
	rows, err := s.db.QueryContext(ctx, `SELECT id, job_id, name, size, sha256, md5, source, url, status, created_at
		FROM job_files WHERE job_id = ? AND source = 'url' AND status = 'pending' ORDER BY id ASC`, jobID)
	if err != nil {
		return nil, fmt.Errorf("list pending URLs: %w", err)
	}
	defer rows.Close()
	return scanFiles(rows)
}

func scanFiles(rows *sql.Rows) ([]File, error) {
	var out []File
	for rows.Next() {
		var (
			f       File
			created int64
		)
		if err := rows.Scan(&f.ID, &f.JobID, &f.Name, &f.Size, &f.SHA256, &f.MD5, &f.Source,
			&f.URL, &f.Status, &created); err != nil {
			return nil, fmt.Errorf("read file: %w", err)
		}
		f.CreatedAt = time.Unix(created, 0)
		out = append(out, f)
	}
	return out, rows.Err()
}

// GetFile loads one file row.
func (s *Store) GetFile(ctx context.Context, jobID string, fileID int64) (*File, error) {
	var (
		f       File
		created int64
	)
	err := s.db.QueryRowContext(ctx, `SELECT id, job_id, name, size, sha256, md5, source, url, status, created_at
		FROM job_files WHERE id = ? AND job_id = ?`, fileID, jobID).
		Scan(&f.ID, &f.JobID, &f.Name, &f.Size, &f.SHA256, &f.MD5, &f.Source, &f.URL, &f.Status, &created)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, fmt.Errorf("load file: %w", err)
	}
	f.CreatedAt = time.Unix(created, 0)
	return &f, nil
}

// MarkURLDone records a successfully downloaded URL.
func (s *Store) MarkURLDone(ctx context.Context, jobID string, fileID int64, name string, size int64, sha, md5sum string) error {
	now := time.Now().Unix()
	s.writeMu.Lock()
	defer s.writeMu.Unlock()
	res, err := s.db.ExecContext(ctx, `UPDATE job_files SET name = ?, size = ?, sha256 = ?, md5 = ?,
		status = 'done', updated_at = ? WHERE id = ? AND job_id = ? AND source = 'url' AND status = 'pending'`,
		name, size, sha, md5sum, now, fileID, jobID)
	if err != nil {
		return fmt.Errorf("finish URL download: %w", err)
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return ErrNotFound
	}
	_, _, err = s.recalcTotalsLocked(ctx, jobID)
	return err
}

// DeleteFile removes a file row (finished upload or pending URL).
func (s *Store) DeleteFile(ctx context.Context, jobID string, fileID int64) error {
	s.writeMu.Lock()
	defer s.writeMu.Unlock()
	res, err := s.db.ExecContext(ctx, `DELETE FROM job_files WHERE id = ? AND job_id = ?`, fileID, jobID)
	if err != nil {
		return fmt.Errorf("delete file: %w", err)
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return ErrNotFound
	}
	if _, err := s.db.ExecContext(ctx, `UPDATE jobs SET updated_at = ? WHERE id = ?`,
		time.Now().Unix(), jobID); err != nil {
		return err
	}
	_, _, err = s.recalcTotalsLocked(ctx, jobID)
	return err
}

// UsedNames returns every filename currently reserved in a job.
func (s *Store) UsedNames(ctx context.Context, jobID string) (map[string]bool, error) {
	// Names generated by Ferry itself are reserved so a user file cannot
	// overwrite the checksum files, the manifest or the unpack tool.
	used := map[string]bool{
		"SHA256SUMS": true, "MD5SUMS": true,
		"FERRY-MANIFEST.json": true, "README-FERRY.txt": true, "ferry": true,
	}
	rows, err := s.db.QueryContext(ctx, `SELECT name FROM job_files WHERE job_id = ? AND status = 'done'
		UNION SELECT filename FROM uploads WHERE job_id = ? AND completed = 0`, jobID, jobID)
	if err != nil {
		return nil, fmt.Errorf("read names: %w", err)
	}
	defer rows.Close()
	for rows.Next() {
		var name string
		if err := rows.Scan(&name); err != nil {
			return nil, err
		}
		if name != "" {
			used[name] = true
		}
	}
	return used, rows.Err()
}

// JobExists reports whether a job row exists.
func (s *Store) JobExists(ctx context.Context, id string) (bool, error) {
	var n int
	err := s.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM jobs WHERE id = ?`, id).Scan(&n)
	if err != nil {
		return false, err
	}
	return n > 0, nil
}
