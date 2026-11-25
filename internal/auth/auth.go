// Package auth implements Ferry's signed session cookie and login throttling.
package auth

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"strings"
	"time"

	"golang.org/x/crypto/bcrypt"
)

const (
	CookieName     = "ferry_session"
	SessionTimeout = 12 * time.Hour
	maxCookieSize  = 4096
)

// Session is the signed payload stored in the cookie.
type Session struct {
	Username string `json:"u"`
	IssuedAt int64  `json:"iat"`
	Expires  int64  `json:"exp"`
	CSRF     string `json:"csrf"`
}

// Manager creates and validates signed session cookies.
type Manager struct {
	key          []byte
	username     string
	cookieSecure bool
}

// New returns a session manager. username is the only account allowed to log in.
func New(secret, username string, cookieSecure bool) (*Manager, error) {
	if len(secret) < 32 {
		return nil, errors.New("session secret must be at least 32 bytes")
	}
	if username == "" {
		return nil, errors.New("session username must not be empty")
	}
	return &Manager{
		key:          []byte(secret),
		username:     username,
		cookieSecure: cookieSecure,
	}, nil
}

// NewSession creates a fresh 12-hour session and its signed cookie value.
func (m *Manager) NewSession() (*Session, string, error) {
	csrfBytes := make([]byte, 32)
	if _, err := rand.Read(csrfBytes); err != nil {
		return nil, "", err
	}
	now := time.Now()
	s := &Session{
		Username: m.username,
		IssuedAt: now.Unix(),
		Expires:  now.Add(SessionTimeout).Unix(),
		CSRF:     hex.EncodeToString(csrfBytes),
	}
	token, err := m.sign(s)
	if err != nil {
		return nil, "", err
	}
	return s, token, nil
}

// Parse validates the signature, expiry and username of a cookie value.
func (m *Manager) Parse(value string) (*Session, error) {
	if value == "" || len(value) > maxCookieSize {
		return nil, errors.New("missing or oversized session cookie")
	}
	parts := strings.Split(value, ".")
	if len(parts) != 2 {
		return nil, errors.New("malformed session cookie")
	}
	payload, err := base64.RawURLEncoding.DecodeString(parts[0])
	if err != nil {
		return nil, errors.New("malformed session payload")
	}
	sig, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return nil, errors.New("malformed session signature")
	}
	mac := hmac.New(sha256.New, m.key)
	_, _ = mac.Write([]byte(parts[0]))
	if subtle.ConstantTimeCompare(sig, mac.Sum(nil)) != 1 {
		return nil, errors.New("invalid session signature")
	}
	var s Session
	if err := json.Unmarshal(payload, &s); err != nil {
		return nil, errors.New("invalid session payload")
	}
	if s.Username != m.username {
		return nil, errors.New("session belongs to a different user")
	}
	if s.CSRF == "" || len(s.CSRF) < 32 {
		return nil, errors.New("session is missing a CSRF token")
	}
	if time.Now().Unix() >= s.Expires {
		return nil, errors.New("session expired")
	}
	return &s, nil
}

// FromRequest returns the valid session attached to r, or nil.
func (m *Manager) FromRequest(r *http.Request) *Session {
	c, err := r.Cookie(CookieName)
	if err != nil {
		return nil
	}
	s, err := m.Parse(c.Value)
	if err != nil {
		return nil
	}
	return s
}

// SetCookie writes the session cookie.
func (m *Manager) SetCookie(w http.ResponseWriter, token string) {
	http.SetCookie(w, &http.Cookie{
		Name:     CookieName,
		Value:    token,
		Path:     "/",
		HttpOnly: true,
		Secure:   m.cookieSecure,
		SameSite: http.SameSiteStrictMode,
		MaxAge:   int(SessionTimeout.Seconds()),
		Expires:  time.Now().Add(SessionTimeout),
	})
}

// ClearCookie expires the session cookie.
func (m *Manager) ClearCookie(w http.ResponseWriter) {
	http.SetCookie(w, &http.Cookie{
		Name:     CookieName,
		Value:    "",
		Path:     "/",
		HttpOnly: true,
		Secure:   m.cookieSecure,
		SameSite: http.SameSiteStrictMode,
		MaxAge:   -1,
		Expires:  time.Unix(1, 0),
	})
}

func (m *Manager) sign(s *Session) (string, error) {
	payload, err := json.Marshal(s)
	if err != nil {
		return "", err
	}
	encoded := base64.RawURLEncoding.EncodeToString(payload)
	mac := hmac.New(sha256.New, m.key)
	_, _ = mac.Write([]byte(encoded))
	return encoded + "." + base64.RawURLEncoding.EncodeToString(mac.Sum(nil)), nil
}

// SecureCompare compares two strings without leaking timing information.
func SecureCompare(a, b string) bool {
	return subtle.ConstantTimeCompare([]byte(a), []byte(b)) == 1
}

// HashPassword returns a bcrypt hash suitable for FERRY_PASSWORD_HASH.
func HashPassword(password string) (string, error) {
	if len(password) < 8 {
		return "", errors.New("password must be at least 8 characters")
	}
	if len(password) > 72 {
		return "", errors.New("password must be at most 72 bytes (bcrypt limit)")
	}
	hash, err := bcrypt.GenerateFromPassword([]byte(password), bcrypt.DefaultCost)
	if err != nil {
		return "", fmt.Errorf("hash password: %w", err)
	}
	return string(hash), nil
}

// VerifyPassword checks a login password. When hash is set it is compared with
// bcrypt; otherwise plain is compared in constant time. The error is only for
// malformed hashes and is never shown to the user.
func VerifyPassword(password, hash, plain string) (bool, error) {
	if hash != "" {
		if err := bcrypt.CompareHashAndPassword([]byte(hash), []byte(password)); err != nil {
			if errors.Is(err, bcrypt.ErrMismatchedHashAndPassword) {
				return false, nil
			}
			return false, err
		}
		return true, nil
	}
	return SecureCompare(password, plain), nil
}

// IsBcryptHash reports whether value looks like a bcrypt hash.
func IsBcryptHash(value string) bool {
	return strings.HasPrefix(value, "$2a$") || strings.HasPrefix(value, "$2b$") ||
		strings.HasPrefix(value, "$2y$")
}

// ValidateBcryptHash checks the prefix and the encoded cost/salt so a
// truncated value is rejected at startup instead of breaking every login.
func ValidateBcryptHash(value string) error {
	if !IsBcryptHash(value) {
		return errors.New("must start with $2a$, $2b$ or $2y$")
	}
	if _, err := bcrypt.Cost([]byte(value)); err != nil {
		return fmt.Errorf("is not a valid bcrypt hash: %w", err)
	}
	return nil
}
