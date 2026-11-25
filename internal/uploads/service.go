// Package uploads implements resumable chunked uploads and their quota rules.
package uploads

import (
	"context"
	"crypto/md5"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sync"

	"ferry/internal/db"
	"ferry/internal/safename"
)

// ErrQuota is returned when a file would exceed the job byte cap.
var ErrQuota = errors.New("job size limit exceeded")

// ErrInvalidName is returned for empty or unusable filenames.
var ErrInvalidName = errors.New("invalid filename")

// ErrReservedName is returned for names Ferry uses for its own image files.
var ErrReservedName = errors.New("that filename is reserved by Ferry; rename the file and try again")

// OffsetError reports a resumable upload offset mismatch.
type OffsetError struct {
	Current int64
	Message string
}

func (e *OffsetError) Error() string {
	if e.Message != "" {
		return e.Message
	}
	return fmt.Sprintf("upload offset mismatch: server has %d bytes", e.Current)
}

// Service coordinates upload metadata and temp files.
type Service struct {
	store   *db.Store
	dataDir string
	max     int64
	mu      sync.Mutex
	locks   sync.Map // upload id -> *sync.Mutex
}

// New creates an upload service.
func New(store *db.Store, dataDir string, maxTotal int64) *Service {
	return &Service{store: store, dataDir: dataDir, max: maxTotal}
}

// MaxTotal returns the configured per-job cap.
func (s *Service) MaxTotal() int64 { return s.max }

// CheckQuota verifies that adding add bytes to current stays under max.
func CheckQuota(current, add, max int64) error {
	if add < 0 {
		return errors.New("size cannot be negative")
	}
	if current < 0 {
		current = 0
	}
	if add > max-current {
		return ErrQuota
	}
	return nil
}

// ValidateOffset checks the browser-supplied offset against the bytes already
// received. Resuming is only allowed at exactly the current position.
func ValidateOffset(offset, received, declared int64) error {
	if offset < 0 || offset > declared {
		return &OffsetError{Current: received, Message: "offset is outside the declared file size"}
	}
	if offset != received {
		return &OffsetError{Current: received}
	}
	return nil
}

// Create reserves an upload and creates its empty temporary file.
func (s *Service) Create(ctx context.Context, jobID, filename string, size int64) (*db.Upload, error) {
	if size < 0 {
		return nil, errors.New("file size cannot be negative")
	}
	if size > s.max {
		return nil, ErrQuota
	}
	s.mu.Lock()
	defer s.mu.Unlock()

	job, err := s.store.GetJob(ctx, jobID)
	if err != nil {
		return nil, err
	}
	if job.State != db.StateDraft {
		return nil, errors.New("files can only be added while the job is a draft")
	}
	current, err := s.store.DeclaredTotal(ctx, jobID)
	if err != nil {
		return nil, err
	}
	if err := CheckQuota(current, size, s.max); err != nil {
		return nil, err
	}
	base := safename.Sanitize(filename)
	if base == "" {
		return nil, ErrInvalidName
	}
	if safename.Reserved(base) {
		return nil, ErrReservedName
	}
	used, err := s.store.UsedNames(ctx, jobID)
	if err != nil {
		return nil, err
	}
	name := safename.Unique(base, used)

	id, err := randomID()
	if err != nil {
		return nil, err
	}
	dir, err := safename.JobDir(s.dataDir, jobID)
	if err != nil {
		return nil, err
	}
	uploadDir := filepath.Join(dir, "uploads")
	if err := os.MkdirAll(uploadDir, 0o750); err != nil {
		return nil, fmt.Errorf("create upload directory: %w", err)
	}
	partPath := filepath.Join(uploadDir, id+".part")
	f, err := os.OpenFile(partPath, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
	if err != nil {
		return nil, fmt.Errorf("create upload file: %w", err)
	}
	if err := f.Close(); err != nil {
		_ = os.Remove(partPath)
		return nil, err
	}
	u := &db.Upload{ID: id, JobID: jobID, Filename: name, OriginalFilename: base, DeclaredSize: size}
	if err := s.store.CreateUpload(ctx, u); err != nil {
		_ = os.Remove(partPath)
		if errors.Is(err, db.ErrNotDraft) {
			return nil, errors.New("the job started while the file was being added; refresh the page")
		}
		return nil, err
	}
	return u, nil
}

// Get returns the current upload record.
func (s *Service) Get(ctx context.Context, jobID, uploadID string) (*db.Upload, error) {
	return s.store.GetUpload(ctx, jobID, uploadID)
}

// Append writes a chunk to the temp file. It truncates back to offset when the
// body turns out to be longer than the declared remainder.
func (s *Service) Append(ctx context.Context, jobID, uploadID string, offset int64, body io.Reader) (int64, error) {
	lock := s.uploadLock(uploadID)
	lock.Lock()
	defer lock.Unlock()

	job, err := s.store.GetJob(ctx, jobID)
	if err != nil {
		return 0, err
	}
	if job.State != db.StateDraft {
		return 0, errors.New("uploads are closed because the job has started")
	}
	u, err := s.store.GetUpload(ctx, jobID, uploadID)
	if err != nil {
		return 0, err
	}
	if u.Completed {
		return u.Received, errors.New("upload is already complete")
	}
	dir, err := safename.JobDir(s.dataDir, jobID)
	if err != nil {
		return 0, err
	}
	partPath := filepath.Join(dir, "uploads", uploadID+".part")
	f, err := os.OpenFile(partPath, os.O_WRONLY|os.O_APPEND, 0)
	if err != nil {
		return 0, fmt.Errorf("open upload file: %w", err)
	}
	defer f.Close()

	st, err := f.Stat()
	if err != nil {
		return 0, err
	}
	// The file is the source of truth after a crash between write and DB update.
	if st.Size() != u.Received {
		u.Received = st.Size()
		if err := s.store.SetUploadReceived(ctx, jobID, uploadID, u.Received); err != nil {
			return 0, err
		}
	}
	if err := ValidateOffset(offset, u.Received, u.DeclaredSize); err != nil {
		return u.Received, err
	}
	remaining := u.DeclaredSize - offset
	if remaining < 0 {
		return u.Received, &OffsetError{Current: u.Received}
	}

	limited := io.LimitReader(body, remaining+1)
	written, copyErr := io.Copy(f, limited)
	if copyErr != nil || written > remaining {
		// Discard a partial or oversized chunk so retries start from the same
		// known-good offset.
		_ = f.Truncate(offset)
		if copyErr != nil {
			return u.Received, fmt.Errorf("write upload chunk: %w", copyErr)
		}
		return u.Received, fmt.Errorf("chunk exceeds the remaining %d bytes", remaining)
	}
	if err := f.Sync(); err != nil {
		_ = f.Truncate(offset)
		return u.Received, fmt.Errorf("flush upload chunk: %w", err)
	}
	newReceived := offset + written
	if err := s.store.SetUploadReceived(ctx, jobID, uploadID, newReceived); err != nil {
		return u.Received, err
	}
	return newReceived, nil
}

// Complete verifies the declared size, hashes the file and moves it into place.
func (s *Service) Complete(ctx context.Context, jobID, uploadID string) (*db.File, error) {
	lock := s.uploadLock(uploadID)
	lock.Lock()
	defer lock.Unlock()

	job, err := s.store.GetJob(ctx, jobID)
	if err != nil {
		return nil, err
	}
	if job.State != db.StateDraft {
		return nil, errors.New("uploads are closed because the job has started")
	}
	u, err := s.store.GetUpload(ctx, jobID, uploadID)
	if err != nil {
		return nil, err
	}
	if u.Completed {
		return nil, errors.New("upload is already complete")
	}
	dir, err := safename.JobDir(s.dataDir, jobID)
	if err != nil {
		return nil, err
	}
	partPath := filepath.Join(dir, "uploads", uploadID+".part")
	st, err := os.Stat(partPath)
	if err != nil {
		return nil, fmt.Errorf("open upload file: %w", err)
	}
	if st.Size() != u.DeclaredSize {
		return nil, &OffsetError{Current: st.Size(),
			Message: fmt.Sprintf("upload is incomplete: received %d of %d bytes", st.Size(), u.DeclaredSize)}
	}
	if err := s.store.SetUploadReceived(ctx, jobID, uploadID, st.Size()); err != nil {
		return nil, err
	}
	sum, md5sum, err := hashFile(partPath)
	if err != nil {
		return nil, err
	}
	filesDir := filepath.Join(dir, "files")
	if err := os.MkdirAll(filesDir, 0o750); err != nil {
		return nil, fmt.Errorf("create files directory: %w", err)
	}
	name := safename.Sanitize(u.Filename)
	if name == "" {
		return nil, ErrInvalidName
	}
	if safename.Reserved(name) {
		return nil, ErrReservedName
	}
	finalPath, err := safeChild(filesDir, name)
	if err != nil {
		return nil, err
	}
	if _, err := os.Stat(finalPath); err == nil {
		return nil, fmt.Errorf("a file named %q already exists in this job", name)
	} else if !os.IsNotExist(err) {
		return nil, err
	}
	if err := os.Rename(partPath, finalPath); err != nil {
		return nil, fmt.Errorf("finalize upload: %w", err)
	}
	f := &db.File{JobID: jobID, Name: name, Size: u.DeclaredSize, SHA256: sum, MD5: md5sum, Source: "upload", Status: "done"}
	if err := s.store.CompleteUpload(ctx, jobID, uploadID, f); err != nil {
		// Put the bytes back so the user can retry completing the upload.
		_ = os.Rename(finalPath, partPath)
		return nil, err
	}
	return f, nil
}

// Delete cancels and removes an unfinished upload.
func (s *Service) Delete(ctx context.Context, jobID, uploadID string) error {
	lock := s.uploadLock(uploadID)
	lock.Lock()
	defer lock.Unlock()

	job, err := s.store.GetJob(ctx, jobID)
	if err != nil {
		return err
	}
	if job.State != db.StateDraft {
		return errors.New("files can only be removed while the job is a draft")
	}
	u, err := s.store.GetUpload(ctx, jobID, uploadID)
	if err != nil {
		return err
	}
	if u.Completed {
		return errors.New("upload is already complete")
	}
	dir, err := safename.JobDir(s.dataDir, jobID)
	if err != nil {
		return err
	}
	if err := s.store.DeleteUpload(ctx, jobID, uploadID); err != nil {
		return err
	}
	if err := os.Remove(filepath.Join(dir, "uploads", uploadID+".part")); err != nil && !os.IsNotExist(err) {
		return fmt.Errorf("remove upload file: %w", err)
	}
	return nil
}

// DeleteFile removes a finished upload or a URL entry while the job is a draft.
func (s *Service) DeleteFile(ctx context.Context, jobID string, fileID int64) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	job, err := s.store.GetJob(ctx, jobID)
	if err != nil {
		return err
	}
	if job.State != db.StateDraft {
		return errors.New("files can only be removed while the job is a draft")
	}
	f, err := s.store.GetFile(ctx, jobID, fileID)
	if err != nil {
		return err
	}
	if err := s.store.DeleteFile(ctx, jobID, fileID); err != nil {
		return err
	}
	if f.Status == "done" && f.Name != "" {
		dir, err := safename.JobDir(s.dataDir, jobID)
		if err != nil {
			return err
		}
		path, err := safeChild(filepath.Join(dir, "files"), f.Name)
		if err != nil {
			return err
		}
		if err := os.Remove(path); err != nil && !os.IsNotExist(err) {
			return fmt.Errorf("remove file: %w", err)
		}
	}
	return nil
}

// RemoveJobDir removes all bytes belonging to a job.
func (s *Service) RemoveJobDir(jobID string) error {
	dir, err := safename.JobDir(s.dataDir, jobID)
	if err != nil {
		return err
	}
	if err := os.RemoveAll(dir); err != nil {
		return fmt.Errorf("remove job directory: %w", err)
	}
	return nil
}

func (s *Service) uploadLock(id string) *sync.Mutex {
	v, _ := s.locks.LoadOrStore(id, &sync.Mutex{})
	return v.(*sync.Mutex)
}

func safeChild(base, name string) (string, error) {
	name = safename.Sanitize(name)
	if name == "" {
		return "", ErrInvalidName
	}
	p := filepath.Join(base, filepath.Base(name))
	rel, err := filepath.Rel(base, p)
	if err != nil || rel == ".." || filepath.IsAbs(rel) {
		return "", errors.New("file path escapes the job directory")
	}
	return p, nil
}

// hashFile streams the file once and returns its SHA-256 and MD5 hex digests.
func hashFile(path string) (string, string, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", "", fmt.Errorf("open file for hashing: %w", err)
	}
	defer f.Close()
	sha := sha256.New()
	md := md5.New()
	if _, err := io.Copy(io.MultiWriter(sha, md), f); err != nil {
		return "", "", fmt.Errorf("hash file: %w", err)
	}
	return hex.EncodeToString(sha.Sum(nil)), hex.EncodeToString(md.Sum(nil)), nil
}

func randomID() (string, error) {
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return hex.EncodeToString(b), nil
}
