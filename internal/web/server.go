// Package web serves Ferry's HTML pages and JSON API.
package web

import (
	"bytes"
	"encoding/json"
	"fmt"
	"html/template"
	"io/fs"
	"log/slog"
	"net"
	"net/http"
	"strings"
	"time"

	"ferry/internal/auth"
	"ferry/internal/config"
	"ferry/internal/db"
	"ferry/internal/jobs"
	"ferry/internal/uploads"
	webassets "ferry/web"
)

const maxJSONBody = 64 << 10

// Server holds all HTTP dependencies.
type Server struct {
	cfg     *config.Config
	store   *db.Store
	auth    *auth.Manager
	limiter *auth.Limiter
	uploads *uploads.Service
	jobs    *jobs.Manager
	logger  *slog.Logger

	templates *template.Template
	static    http.Handler
}

// New parses embedded assets and returns a server.
func New(cfg *config.Config, store *db.Store, sessions *auth.Manager,
	uploadSvc *uploads.Service, manager *jobs.Manager, logger *slog.Logger, version string) (*Server, error) {

	funcs := template.FuncMap{
		"version":    func() string { return version },
		"bytes":      formatBytes,
		"time":       formatTime,
		"state":      stateLabel,
		"isActive":   db.IsActive,
		"isTerminal": db.IsTerminal,
	}
	tmpl, err := template.New("ferry").Funcs(funcs).ParseFS(webassets.FS, "templates/*.html")
	if err != nil {
		return nil, fmt.Errorf("parse templates: %w", err)
	}
	staticFS, err := fs.Sub(webassets.FS, "static")
	if err != nil {
		return nil, fmt.Errorf("open static assets: %w", err)
	}
	staticHandler := http.StripPrefix("/static/", http.FileServer(http.FS(staticFS)))
	s := &Server{
		cfg:       cfg,
		store:     store,
		auth:      sessions,
		limiter:   auth.NewLimiter(),
		uploads:   uploadSvc,
		jobs:      manager,
		logger:    logger,
		templates: tmpl,
		static:    staticHandler,
	}
	return s, nil
}

// Handler returns the fully wrapped HTTP handler.
func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /health", s.handleHealth)
	mux.HandleFunc("GET /login", s.handleLoginPage)
	mux.HandleFunc("POST /login", s.handleLoginSubmit)
	mux.HandleFunc("GET /static/", s.handleStatic)
	mux.HandleFunc("POST /logout", s.pageAuth(s.handleLogout))
	mux.HandleFunc("GET /{$}", s.pageAuth(s.handleIndex))
	mux.HandleFunc("GET /jobs/{jobID}", s.pageAuth(s.handleJobPage))
	mux.HandleFunc("GET /history", s.pageAuth(s.handleHistory))

	mux.HandleFunc("POST /api/jobs", s.apiAuth(s.handleCreateJob))
	mux.HandleFunc("GET /api/jobs/{jobID}", s.apiAuth(s.handleGetJob))
	mux.HandleFunc("POST /api/jobs/{jobID}/start", s.apiAuth(s.handleStartJob))
	mux.HandleFunc("POST /api/jobs/{jobID}/cancel", s.apiAuth(s.handleCancelJob))
	mux.HandleFunc("POST /api/jobs/{jobID}/uploads", s.apiAuth(s.handleCreateUpload))
	mux.HandleFunc("PUT /api/jobs/{jobID}/uploads/{uploadID}", s.apiAuth(s.handleUploadChunk))
	mux.HandleFunc("GET /api/jobs/{jobID}/uploads/{uploadID}", s.apiAuth(s.handleGetUpload))
	mux.HandleFunc("POST /api/jobs/{jobID}/uploads/{uploadID}/complete", s.apiAuth(s.handleCompleteUpload))
	mux.HandleFunc("DELETE /api/jobs/{jobID}/uploads/{uploadID}", s.apiAuth(s.handleDeleteUpload))
	mux.HandleFunc("POST /api/jobs/{jobID}/urls", s.apiAuth(s.handleAddURL))
	mux.HandleFunc("DELETE /api/jobs/{jobID}/files/{fileID}", s.apiAuth(s.handleDeleteFile))
	mux.HandleFunc("POST /api/jobs/{jobID}/image-delete", s.apiAuth(s.handleDeleteImage))
	mux.HandleFunc("DELETE /api/jobs/{jobID}", s.apiAuth(s.handleDeleteJob))
	mux.HandleFunc("POST /api/history/purge-images", s.apiAuth(s.handlePurgeImages))

	return s.securityHeaders(s.logRequests(mux))
}

type authedHandler func(http.ResponseWriter, *http.Request, *auth.Session)

func (s *Server) pageAuth(next authedHandler) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		session := s.auth.FromRequest(r)
		if session == nil {
			http.Redirect(w, r, "/login", http.StatusSeeOther)
			return
		}
		w.Header().Set("Cache-Control", "no-store")
		next(w, r, session)
	}
}

func (s *Server) apiAuth(next authedHandler) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		session := s.auth.FromRequest(r)
		if session == nil {
			writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "Your session has expired. Reload the page and log in again."})
			return
		}
		if r.Method != http.MethodGet && r.Method != http.MethodHead {
			header := r.Header.Get("X-Requested-With")
			token := r.Header.Get("X-CSRF-Token")
			if header != "Ferry" || !auth.SecureCompare(token, session.CSRF) {
				writeJSON(w, http.StatusForbidden, map[string]string{"error": "Request rejected by CSRF protection. Reload the page and try again."})
				return
			}
		}
		w.Header().Set("Cache-Control", "no-store")
		next(w, r, session)
	}
}

func (s *Server) handleStatic(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "public, max-age=3600")
	s.static.ServeHTTP(w, r)
}

func (s *Server) securityHeaders(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("X-Frame-Options", "DENY")
		w.Header().Set("Referrer-Policy", "no-referrer")
		w.Header().Set("Content-Security-Policy",
			"default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; "+
				"connect-src 'self'; font-src 'self'; object-src 'none'; base-uri 'none'; "+
				"form-action 'self'; frame-ancestors 'none'")
		next.ServeHTTP(w, r)
	})
}

func (s *Server) logRequests(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		next.ServeHTTP(w, r)
		s.logger.Debug("http request", "method", r.Method, "path", r.URL.Path,
			"remote", clientIP(r, s.cfg.TrustProxy), "duration", time.Since(start).String())
	})
}

func (s *Server) handleHealth(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write([]byte("ok"))
}

func (s *Server) handleLoginPage(w http.ResponseWriter, r *http.Request) {
	if s.auth.FromRequest(r) != nil {
		http.Redirect(w, r, "/", http.StatusSeeOther)
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	s.render(w, http.StatusOK, "login.html", map[string]any{})
}

func (s *Server) handleLoginSubmit(w http.ResponseWriter, r *http.Request) {
	r.Body = http.MaxBytesReader(w, r.Body, maxJSONBody)
	if err := r.ParseForm(); err != nil {
		s.renderLoginError(w, http.StatusBadRequest, "The login form could not be read.", "")
		return
	}
	ip := clientIP(r, s.cfg.TrustProxy)
	if blocked, remaining := s.limiter.Blocked(ip); blocked {
		minutes := int(remaining.Minutes()) + 1
		s.renderLoginError(w, http.StatusTooManyRequests,
			fmt.Sprintf("Too many failed login attempts. Try again in about %d minute(s).", minutes), "")
		return
	}
	username := r.PostFormValue("username")
	password := r.PostFormValue("password")
	userOK := auth.SecureCompare(username, s.cfg.Username)
	passOK, verifyErr := auth.VerifyPassword(password, s.cfg.PasswordHash, s.cfg.Password)
	if verifyErr != nil {
		s.logger.Error("password hash is invalid", "error", verifyErr)
	}
	if !userOK || !passOK {
		s.limiter.Failure(ip)
		s.renderLoginError(w, http.StatusUnauthorized, "Incorrect username or password.", username)
		return
	}
	s.limiter.Success(ip)
	_, token, err := s.auth.NewSession()
	if err != nil {
		s.logger.Error("create session", "error", err)
		s.renderLoginError(w, http.StatusInternalServerError, "Could not create a login session. Try again.", username)
		return
	}
	s.auth.SetCookie(w, token)
	http.Redirect(w, r, "/", http.StatusSeeOther)
}

func (s *Server) renderLoginError(w http.ResponseWriter, status int, message, username string) {
	w.Header().Set("Cache-Control", "no-store")
	s.render(w, status, "login.html", map[string]any{"Error": message, "Username": username})
}

func (s *Server) handleLogout(w http.ResponseWriter, r *http.Request, session *auth.Session) {
	r.Body = http.MaxBytesReader(w, r.Body, maxJSONBody)
	if err := r.ParseForm(); err != nil {
		http.Error(w, "The logout form could not be read.", http.StatusBadRequest)
		return
	}
	if !auth.SecureCompare(r.PostFormValue("_csrf"), session.CSRF) {
		http.Error(w, "Request rejected by CSRF protection.", http.StatusForbidden)
		return
	}
	s.auth.ClearCookie(w)
	http.Redirect(w, r, "/login", http.StatusSeeOther)
}

func (s *Server) render(w http.ResponseWriter, status int, name string, data any) {
	var buf bytes.Buffer
	if err := s.templates.ExecuteTemplate(&buf, name, data); err != nil {
		s.logger.Error("render template", "template", name, "error", err)
		if status == http.StatusOK {
			status = http.StatusInternalServerError
		}
		http.Error(w, "Ferry could not render this page. Check the server logs.", status)
		return
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.WriteHeader(status)
	_, _ = w.Write(buf.Bytes())
}

func (s *Server) renderPageError(w http.ResponseWriter, status int, message string) {
	s.render(w, status, "error.html", map[string]any{
		"Error": message,
		"Title": http.StatusText(status),
	})
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	enc := json.NewEncoder(w)
	enc.SetEscapeHTML(true)
	_ = enc.Encode(v)
}

func jsonErrorMsg(w http.ResponseWriter, status int, message string) {
	writeJSON(w, status, map[string]string{"error": message})
}

func clientIP(r *http.Request, trustProxy bool) string {
	if trustProxy {
		if xff := r.Header.Get("X-Forwarded-For"); xff != "" {
			parts := strings.Split(xff, ",")
			// Caddy appends the real peer to the right. Take the last valid
			// entry so a client-supplied prefix cannot spoof the address.
			for i := len(parts) - 1; i >= 0; i-- {
				candidate := strings.TrimSpace(parts[i])
				if ip := net.ParseIP(candidate); ip != nil {
					return ip.String()
				}
			}
		}
	}
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}
	return host
}

func formatBytes(n int64) string {
	if n < 0 {
		return "0 B"
	}
	const unit = 1024
	if n < unit {
		return fmt.Sprintf("%d B", n)
	}
	div, exp := int64(unit), 0
	for v := n / unit; v >= unit; v /= unit {
		div *= unit
		exp++
	}
	return fmt.Sprintf("%.1f %ciB", float64(n)/float64(div), "KMGTPE"[exp])
}

func formatTime(t time.Time) string {
	if t.IsZero() {
		return "—"
	}
	return t.Local().Format("2006-01-02 15:04")
}

func stateLabel(state string) string {
	if state == "" {
		return "Unknown"
	}
	return strings.ToUpper(state[:1]) + state[1:]
}
