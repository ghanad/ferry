package web

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"strings"
	"time"

	"ferry/internal/auth"
	"ferry/internal/db"
	"ferry/internal/downloader"
	"ferry/internal/jobs"
	"ferry/internal/uploads"
)

type indexView struct {
	User            string
	CSRF            string
	Drafts          []db.Job
	Recent          []db.Job
	Current         *db.Job
	CurrentProgress jobs.Progress
	Error           string
}

func (s *Server) handleIndex(w http.ResponseWriter, r *http.Request, session *auth.Session) {
	all, err := s.store.ListJobs(r.Context(), 100)
	if err != nil {
		s.logger.Error("list jobs for home page", "error", err)
		s.renderPageError(w, http.StatusInternalServerError, "Ferry could not read the job list. Check the server logs.")
		return
	}
	view := indexView{User: session.Username, CSRF: session.CSRF}
	if currentID, progress := s.jobs.Current(); currentID != "" {
		if currentJob, err := s.store.GetJob(r.Context(), currentID); err == nil {
			view.Current = currentJob
			view.CurrentProgress = progress
		}
	}
	for _, job := range all {
		if job.State == db.StateDraft {
			view.Drafts = append(view.Drafts, job)
		} else {
			view.Recent = append(view.Recent, job)
		}
		if len(view.Recent) >= 20 {
			break
		}
	}
	s.render(w, http.StatusOK, "index.html", view)
}

func (s *Server) handleJobPage(w http.ResponseWriter, r *http.Request, session *auth.Session) {
	jobID := r.PathValue("jobID")
	if _, err := s.store.GetJob(r.Context(), jobID); err != nil {
		if errors.Is(err, db.ErrNotFound) {
			s.renderPageError(w, http.StatusNotFound, "That transfer does not exist.")
			return
		}
		s.logger.Error("load job page", "error", err)
		s.renderPageError(w, http.StatusInternalServerError, "Ferry could not load that transfer.")
		return
	}
	s.render(w, http.StatusOK, "job.html", map[string]any{
		"User":          session.Username,
		"CSRF":          session.CSRF,
		"JobID":         jobID,
		"MaxTotalBytes": s.cfg.MaxTotalBytes,
		"MaxTotalText":  formatBytes(s.cfg.MaxTotalBytes),
	})
}

func (s *Server) handleHistory(w http.ResponseWriter, r *http.Request, session *auth.Session) {
	jobs, err := s.store.ListJobs(r.Context(), 500)
	if err != nil {
		s.logger.Error("load history", "error", err)
		s.renderPageError(w, http.StatusInternalServerError, "Ferry could not load the transfer history.")
		return
	}
	s.render(w, http.StatusOK, "history.html", map[string]any{
		"User":          session.Username,
		"CSRF":          session.CSRF,
		"Jobs":          jobs,
		"RetentionDays": s.cfg.RetentionDays,
	})
}

type fileJSON struct {
	ID     int64  `json:"id"`
	Name   string `json:"name"`
	Size   int64  `json:"size"`
	SHA256 string `json:"sha256"`
	MD5    string `json:"md5"`
	Source string `json:"source"`
	URL    string `json:"url"`
	Status string `json:"status"`
}

type uploadJSON struct {
	ID               string `json:"id"`
	Filename         string `json:"filename"`
	OriginalFilename string `json:"original_filename"`
	Size             int64  `json:"size"`
	Received         int64  `json:"received"`
}

type progressJSON struct {
	Text  string `json:"text"`
	Done  int64  `json:"done"`
	Total int64  `json:"total"`
}

type jobJSON struct {
	ID            string       `json:"id"`
	State         string       `json:"state"`
	CreatedAt     string       `json:"created_at"`
	UpdatedAt     string       `json:"updated_at"`
	FinishedAt    string       `json:"finished_at,omitempty"`
	TotalBytes    int64        `json:"total_bytes"`
	MaxTotalBytes int64        `json:"max_total_bytes"`
	FileCount     int          `json:"file_count"`
	Image         string       `json:"image"`
	Error         string       `json:"error"`
	Log           string       `json:"log"`
	ImageDeleted  bool         `json:"image_deleted"`
	Files         []fileJSON   `json:"files"`
	Uploads       []uploadJSON `json:"uploads"`
	Progress      progressJSON `json:"progress"`
	CanStart      bool         `json:"can_start"`
	CanCancel     bool         `json:"can_cancel"`
	IsActive      bool         `json:"is_active"`
	Compress      bool         `json:"compress"`
	Encrypted     bool         `json:"encrypted"`
	HasPassphrase bool         `json:"has_passphrase"`
}

func (s *Server) handleCreateJob(w http.ResponseWriter, r *http.Request, _ *auth.Session) {
	id, err := randomJobID()
	if err != nil {
		s.logger.Error("generate job id", "error", err)
		jsonErrorMsg(w, http.StatusInternalServerError, "Could not create a job id.")
		return
	}
	job, err := s.store.CreateJob(r.Context(), id)
	if err != nil {
		s.logger.Error("create job", "error", err)
		jsonErrorMsg(w, http.StatusInternalServerError, "Could not create the transfer in the database.")
		return
	}
	writeJSON(w, http.StatusCreated, map[string]any{"id": job.ID})
}

func (s *Server) handleGetJob(w http.ResponseWriter, r *http.Request, _ *auth.Session) {
	jobID := r.PathValue("jobID")
	job, err := s.store.GetJob(r.Context(), jobID)
	if err != nil {
		s.jobStoreError(w, err)
		return
	}
	files, err := s.store.ListFiles(r.Context(), jobID)
	if err != nil {
		s.logger.Error("list job files", "error", err)
		jsonErrorMsg(w, http.StatusInternalServerError, "Could not read the file list.")
		return
	}
	pending, err := s.store.ListUploads(r.Context(), jobID)
	if err != nil {
		s.logger.Error("list uploads", "error", err)
		jsonErrorMsg(w, http.StatusInternalServerError, "Could not read upload progress.")
		return
	}
	resp := jobJSON{
		ID:            job.ID,
		State:         job.State,
		CreatedAt:     job.CreatedAt.Format(time.RFC3339),
		UpdatedAt:     job.UpdatedAt.Format(time.RFC3339),
		TotalBytes:    job.TotalBytes,
		MaxTotalBytes: s.cfg.MaxTotalBytes,
		FileCount:     job.FileCount,
		Image:         job.Image,
		Error:         job.Error,
		Log:           job.Log,
		ImageDeleted:  job.ImageDeleted,
		IsActive:      db.IsActive(job.State),
		CanCancel:     db.IsActive(job.State),
		Compress:      job.Compress,
		Encrypted:     job.Encrypted,
		HasPassphrase: job.HasPassphrase,
	}
	if !job.FinishedAt.IsZero() {
		resp.FinishedAt = job.FinishedAt.Format(time.RFC3339)
	}
	for _, f := range files {
		resp.Files = append(resp.Files, fileJSON{
			ID: f.ID, Name: f.Name, Size: f.Size, SHA256: f.SHA256, MD5: f.MD5,
			Source: f.Source, URL: f.URL, Status: f.Status,
		})
	}
	for _, u := range pending {
		resp.Uploads = append(resp.Uploads, uploadJSON{
			ID: u.ID, Filename: u.Filename, OriginalFilename: u.OriginalFilename,
			Size: u.DeclaredSize, Received: u.Received,
		})
	}
	p := s.jobs.Progress(jobID)
	resp.Progress = progressJSON{Text: p.Text, Done: p.Done, Total: p.Total}
	resp.CanStart = job.State == db.StateDraft && len(pending) == 0 && len(files) > 0 && job.TotalBytes <= s.cfg.MaxTotalBytes
	writeJSON(w, http.StatusOK, resp)
}

func (s *Server) handleStartJob(w http.ResponseWriter, r *http.Request, _ *auth.Session) {
	jobID := r.PathValue("jobID")
	var body struct {
		Passphrase      string `json:"passphrase"`
		Compress        bool   `json:"compress"`
		ClearPassphrase bool   `json:"clear_passphrase"`
	}
	if err := decodeOptionalJSON(w, r, &body); err != nil {
		jsonErrorMsg(w, http.StatusBadRequest, err.Error())
		return
	}
	if err := s.jobs.SetOptions(r.Context(), jobID, body.Passphrase, body.Compress, body.ClearPassphrase); err != nil {
		if errors.Is(err, db.ErrNotFound) {
			jsonErrorMsg(w, http.StatusNotFound, "That transfer does not exist.")
			return
		}
		jsonErrorMsg(w, http.StatusBadRequest, err.Error())
		return
	}
	if err := s.jobs.StartJob(r.Context(), jobID); err != nil {
		if errors.Is(err, db.ErrNotFound) {
			jsonErrorMsg(w, http.StatusNotFound, "That transfer does not exist.")
			return
		}
		jsonErrorMsg(w, http.StatusBadRequest, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"state": db.StateQueued})
}

func (s *Server) handleCancelJob(w http.ResponseWriter, r *http.Request, _ *auth.Session) {
	jobID := r.PathValue("jobID")
	if err := s.jobs.Cancel(r.Context(), jobID); err != nil {
		if errors.Is(err, db.ErrNotFound) {
			jsonErrorMsg(w, http.StatusNotFound, "That transfer does not exist.")
			return
		}
		jsonErrorMsg(w, http.StatusBadRequest, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"state": "cancelling"})
}

func (s *Server) handleCreateUpload(w http.ResponseWriter, r *http.Request, _ *auth.Session) {
	var body struct {
		Filename string `json:"filename"`
		Size     int64  `json:"size"`
	}
	if err := decodeJSON(w, r, &body); err != nil {
		jsonErrorMsg(w, http.StatusBadRequest, err.Error())
		return
	}
	jobID := r.PathValue("jobID")
	u, err := s.uploads.Create(r.Context(), jobID, body.Filename, body.Size)
	if err != nil {
		switch {
		case errors.Is(err, db.ErrNotFound):
			jsonErrorMsg(w, http.StatusNotFound, "That transfer does not exist.")
		case errors.Is(err, uploads.ErrQuota):
			jsonErrorMsg(w, http.StatusRequestEntityTooLarge,
				fmt.Sprintf("This file would exceed the job size limit of %s. Remove something or raise FERRY_MAX_TOTAL_BYTES.", formatBytes(s.cfg.MaxTotalBytes)))
		case errors.Is(err, uploads.ErrInvalidName):
			jsonErrorMsg(w, http.StatusBadRequest, "That filename is not usable. Use a normal file name.")
		case errors.Is(err, uploads.ErrReservedName):
			jsonErrorMsg(w, http.StatusBadRequest, err.Error())
		default:
			jsonErrorMsg(w, http.StatusBadRequest, err.Error())
		}
		return
	}
	writeJSON(w, http.StatusCreated, map[string]any{
		"upload_id":         u.ID,
		"filename":          u.Filename,
		"original_filename": u.OriginalFilename,
		"size":              u.DeclaredSize,
	})
}

func (s *Server) handleUploadChunk(w http.ResponseWriter, r *http.Request, _ *auth.Session) {
	jobID := r.PathValue("jobID")
	uploadID := r.PathValue("uploadID")
	offset, err := strconv.ParseInt(r.URL.Query().Get("offset"), 10, 64)
	if err != nil || offset < 0 {
		jsonErrorMsg(w, http.StatusBadRequest, "The offset query parameter must be a non-negative whole number.")
		return
	}
	u, err := s.uploads.Get(r.Context(), jobID, uploadID)
	if err != nil {
		s.jobStoreError(w, err)
		return
	}
	if u.Completed {
		jsonErrorMsg(w, http.StatusConflict, "This upload is already complete.")
		return
	}
	if offset != u.Received {
		writeJSON(w, http.StatusConflict, map[string]any{
			"error":    fmt.Sprintf("Upload offset mismatch. The server has %d bytes; resume from there.", u.Received),
			"received": u.Received,
		})
		return
	}
	remaining := u.DeclaredSize - offset
	if remaining < 0 {
		jsonErrorMsg(w, http.StatusConflict, "The offset is beyond the declared file size.")
		return
	}
	// MaxBytesReader guarantees the handler cannot read more than the
	// remaining declared bytes. The upload service enforces the same cap again.
	r.Body = http.MaxBytesReader(w, r.Body, remaining)
	received, err := s.uploads.Append(r.Context(), jobID, uploadID, offset, r.Body)
	if err != nil {
		var oe *uploads.OffsetError
		if errors.As(err, &oe) {
			writeJSON(w, http.StatusConflict, map[string]any{
				"error":    oe.Error(),
				"received": oe.Current,
			})
			return
		}
		var maxErr *http.MaxBytesError
		if errors.As(err, &maxErr) {
			jsonErrorMsg(w, http.StatusRequestEntityTooLarge, "The chunk is larger than the remaining declared file size.")
			return
		}
		jsonErrorMsg(w, http.StatusBadRequest, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"received": received})
}

func (s *Server) handleGetUpload(w http.ResponseWriter, r *http.Request, _ *auth.Session) {
	u, err := s.uploads.Get(r.Context(), r.PathValue("jobID"), r.PathValue("uploadID"))
	if err != nil {
		s.jobStoreError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"received":  u.Received,
		"size":      u.DeclaredSize,
		"completed": u.Completed,
	})
}

func (s *Server) handleCompleteUpload(w http.ResponseWriter, r *http.Request, _ *auth.Session) {
	jobID := r.PathValue("jobID")
	uploadID := r.PathValue("uploadID")
	f, err := s.uploads.Complete(r.Context(), jobID, uploadID)
	if err != nil {
		var oe *uploads.OffsetError
		if errors.As(err, &oe) {
			writeJSON(w, http.StatusConflict, map[string]any{
				"error":    oe.Error(),
				"received": oe.Current,
			})
			return
		}
		if errors.Is(err, db.ErrNotFound) {
			jsonErrorMsg(w, http.StatusNotFound, "That upload does not exist.")
			return
		}
		jsonErrorMsg(w, http.StatusBadRequest, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"id": f.ID, "name": f.Name, "size": f.Size, "sha256": f.SHA256, "md5": f.MD5,
	})
}

func (s *Server) handleDeleteUpload(w http.ResponseWriter, r *http.Request, _ *auth.Session) {
	if err := s.uploads.Delete(r.Context(), r.PathValue("jobID"), r.PathValue("uploadID")); err != nil {
		if errors.Is(err, db.ErrNotFound) {
			jsonErrorMsg(w, http.StatusNotFound, "That upload does not exist.")
			return
		}
		jsonErrorMsg(w, http.StatusBadRequest, err.Error())
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleAddURL(w http.ResponseWriter, r *http.Request, _ *auth.Session) {
	var body struct {
		URL string `json:"url"`
	}
	if err := decodeJSON(w, r, &body); err != nil {
		jsonErrorMsg(w, http.StatusBadRequest, err.Error())
		return
	}
	if _, err := downloader.ValidateURL(body.URL); err != nil {
		jsonErrorMsg(w, http.StatusBadRequest, err.Error())
		return
	}
	jobID := r.PathValue("jobID")
	job, err := s.store.GetJob(r.Context(), jobID)
	if err != nil {
		s.jobStoreError(w, err)
		return
	}
	if job.State != db.StateDraft {
		jsonErrorMsg(w, http.StatusConflict, "URLs can only be added while the job is a draft.")
		return
	}
	if job.TotalBytes >= s.cfg.MaxTotalBytes {
		jsonErrorMsg(w, http.StatusRequestEntityTooLarge, "The job is already at its size limit.")
		return
	}
	f, err := s.store.AddURLFile(r.Context(), jobID, strings.TrimSpace(body.URL))
	if errors.Is(err, db.ErrNotDraft) {
		jsonErrorMsg(w, http.StatusConflict, "The job started before this URL was added. Refresh the page.")
		return
	}
	if err != nil {
		s.logger.Error("add URL", "error", err)
		jsonErrorMsg(w, http.StatusInternalServerError, "Could not save the URL.")
		return
	}
	writeJSON(w, http.StatusCreated, fileJSON{ID: f.ID, Source: f.Source, URL: f.URL, Status: f.Status})
}

func (s *Server) handleDeleteFile(w http.ResponseWriter, r *http.Request, _ *auth.Session) {
	fileID, err := strconv.ParseInt(r.PathValue("fileID"), 10, 64)
	if err != nil || fileID <= 0 {
		jsonErrorMsg(w, http.StatusBadRequest, "Invalid file id.")
		return
	}
	if err := s.uploads.DeleteFile(r.Context(), r.PathValue("jobID"), fileID); err != nil {
		if errors.Is(err, db.ErrNotFound) {
			jsonErrorMsg(w, http.StatusNotFound, "That file entry does not exist.")
			return
		}
		jsonErrorMsg(w, http.StatusBadRequest, err.Error())
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleDeleteImage(w http.ResponseWriter, r *http.Request, _ *auth.Session) {
	if err := s.jobs.DeleteImage(r.Context(), r.PathValue("jobID")); err != nil {
		if errors.Is(err, db.ErrNotFound) {
			jsonErrorMsg(w, http.StatusNotFound, "That transfer does not exist.")
			return
		}
		jsonErrorMsg(w, http.StatusBadRequest, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"deleted": true})
}

func (s *Server) handleDeleteJob(w http.ResponseWriter, r *http.Request, _ *auth.Session) {
	jobID := r.PathValue("jobID")
	job, err := s.store.GetJob(r.Context(), jobID)
	if err != nil {
		s.jobStoreError(w, err)
		return
	}
	if db.IsActive(job.State) {
		jsonErrorMsg(w, http.StatusConflict, "A queued or running transfer cannot be deleted. Wait for it to finish.")
		return
	}
	if err := s.store.DeleteJob(r.Context(), jobID); err != nil {
		s.logger.Error("delete job record", "error", err)
		jsonErrorMsg(w, http.StatusInternalServerError, "Could not delete the transfer record.")
		return
	}
	if err := s.uploads.RemoveJobDir(jobID); err != nil {
		s.logger.Error("remove deleted job directory", "error", err)
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handlePurgeImages(w http.ResponseWriter, r *http.Request, _ *auth.Session) {
	var body struct {
		Days int `json:"days"`
	}
	if err := decodeJSON(w, r, &body); err != nil {
		jsonErrorMsg(w, http.StatusBadRequest, err.Error())
		return
	}
	if body.Days < 1 {
		jsonErrorMsg(w, http.StatusBadRequest, "Enter a number of days of at least 1.")
		return
	}
	deleted, failures, err := s.jobs.PurgeImages(r.Context(), body.Days)
	if err != nil {
		jsonErrorMsg(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"deleted": deleted, "failures": failures})
}

func (s *Server) jobStoreError(w http.ResponseWriter, err error) {
	if errors.Is(err, db.ErrNotFound) {
		jsonErrorMsg(w, http.StatusNotFound, "That transfer or file does not exist.")
		return
	}
	s.logger.Error("job request", "error", err)
	jsonErrorMsg(w, http.StatusInternalServerError, "Ferry could not complete that request. Check the server logs.")
}

// decodeOptionalJSON accepts an empty body as "no options".
func decodeOptionalJSON(w http.ResponseWriter, r *http.Request, dst any) error {
	r.Body = http.MaxBytesReader(w, r.Body, maxJSONBody)
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()
	if err := dec.Decode(dst); err != nil {
		if errors.Is(err, io.EOF) {
			return nil
		}
		return fmt.Errorf("invalid JSON body: %w", err)
	}
	if err := dec.Decode(&struct{}{}); err != io.EOF {
		return errors.New("invalid JSON body: expected a single object")
	}
	return nil
}

func decodeJSON(w http.ResponseWriter, r *http.Request, dst any) error {
	r.Body = http.MaxBytesReader(w, r.Body, maxJSONBody)
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()
	if err := dec.Decode(dst); err != nil {
		return fmt.Errorf("invalid JSON body: %w", err)
	}
	if err := dec.Decode(&struct{}{}); err != io.EOF {
		return errors.New("invalid JSON body: expected a single object")
	}
	return nil
}

func randomJobID() (string, error) {
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return hex.EncodeToString(b), nil
}
