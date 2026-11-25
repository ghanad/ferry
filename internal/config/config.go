// Package config loads and validates Ferry's environment configuration.
package config

import (
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"

	v1 "github.com/google/go-containerregistry/pkg/v1"

	"ferry/internal/auth"
)

const (
	defaultPort        = 8080
	defaultMaxBytes    = int64(10737418240) // 10 GiB
	defaultDataDir     = "/data"
	defaultPlatform    = "linux/amd64"
	defaultDockerRepo  = "ferry"
	defaultRetention   = 0
	minSecretKeyLength = 32
)

var (
	usernameRE = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$`)
	repoRE     = regexp.MustCompile(`^[a-z0-9][a-z0-9._-]{0,99}$`)
)

// Config holds every setting Ferry needs. Secrets are never logged.
type Config struct {
	Username      string
	Password      string
	PasswordHash  string
	SecretKey     string
	Port          int
	ListenAddr    string
	MaxTotalBytes int64
	DataDir       string
	CookieSecure  bool
	Platform      string
	TrustProxy    bool

	DockerHubUsername string
	DockerHubToken    string
	DockerHubRepo     string

	RetentionDays int
	Domain        string

	// GitHubToken is optional. It lets the update check read releases from the
	// GitHub repository when that repository is private. It is never logged.
	GitHubToken string
}

// Load reads the process environment. It returns one aggregated, actionable
// error when anything required is missing or invalid.
func Load() (*Config, error) {
	var problems []string

	username := strings.TrimSpace(os.Getenv("FERRY_USERNAME"))
	if username == "" {
		problems = append(problems, "FERRY_USERNAME is required (the single login username).")
	} else if !usernameRE.MatchString(username) {
		problems = append(problems, "FERRY_USERNAME may only contain letters, digits, dot, underscore and dash (max 100 characters).")
	}

	password := os.Getenv("FERRY_PASSWORD")
	passwordHash := strings.TrimSpace(os.Getenv("FERRY_PASSWORD_HASH"))
	if passwordHash != "" {
		if err := auth.ValidateBcryptHash(passwordHash); err != nil {
			problems = append(problems, "FERRY_PASSWORD_HASH "+err.Error()+". Generate a new one with: ferry hash-password")
		}
		if password == "CHANGE_ME" {
			password = ""
		}
	} else if password == "" {
		problems = append(problems, "FERRY_PASSWORD or FERRY_PASSWORD_HASH is required.")
	} else if password == "CHANGE_ME" {
		problems = append(problems, "FERRY_PASSWORD is still the placeholder CHANGE_ME; choose a real password or set FERRY_PASSWORD_HASH.")
	}
	if username == "CHANGE_ME" {
		problems = append(problems, "FERRY_USERNAME is still the placeholder CHANGE_ME; choose a real username.")
	}

	secret := os.Getenv("FERRY_SECRET_KEY")
	if len(secret) < minSecretKeyLength {
		problems = append(problems, fmt.Sprintf("FERRY_SECRET_KEY is required and must be at least %d characters. Generate one with: openssl rand -hex 32", minSecretKeyLength))
	}

	port, err := intEnv("FERRY_PORT", defaultPort)
	if err != nil {
		problems = append(problems, err.Error())
	} else if port < 1 || port > 65535 {
		problems = append(problems, "FERRY_PORT must be between 1 and 65535.")
	}

	listenAddr := strings.TrimSpace(os.Getenv("FERRY_LISTEN_ADDR"))
	if listenAddr == "" {
		listenAddr = ":" + strconv.Itoa(port)
	} else if err := validateListenAddr(listenAddr); err != nil {
		problems = append(problems, err.Error())
	}

	maxTotal, err := int64Env("FERRY_MAX_TOTAL_BYTES", defaultMaxBytes)
	if err != nil {
		problems = append(problems, err.Error())
	} else if maxTotal <= 0 {
		problems = append(problems, "FERRY_MAX_TOTAL_BYTES must be greater than zero.")
	}

	dataDir := strings.TrimSpace(os.Getenv("FERRY_DATA_DIR"))
	if dataDir == "" {
		dataDir = defaultDataDir
	}
	if abs, err := filepath.Abs(dataDir); err == nil {
		dataDir = abs
	} else {
		problems = append(problems, fmt.Sprintf("FERRY_DATA_DIR is invalid: %v", err))
	}

	cookieSecure, err := boolEnv("FERRY_COOKIE_SECURE", false)
	if err != nil {
		problems = append(problems, err.Error())
	}

	trustProxy, err := boolEnv("FERRY_TRUST_PROXY", false)
	if err != nil {
		problems = append(problems, err.Error())
	}

	platform := strings.TrimSpace(os.Getenv("FERRY_PLATFORM"))
	if platform == "" {
		platform = defaultPlatform
	}
	if p, err := v1.ParsePlatform(platform); err != nil || p == nil || p.OS == "" || p.Architecture == "" {
		problems = append(problems, "FERRY_PLATFORM must look like linux/amd64 or linux/arm64.")
	}

	hubUser := strings.TrimSpace(os.Getenv("DOCKERHUB_USERNAME"))
	if hubUser == "" {
		problems = append(problems, "DOCKERHUB_USERNAME is required (your Docker Hub username).")
	}

	hubToken := strings.TrimSpace(os.Getenv("DOCKERHUB_TOKEN"))
	if hubToken == "" {
		problems = append(problems, "DOCKERHUB_TOKEN is required (a Docker Hub Personal Access Token with Read, Write and Delete permission).")
	} else if hubToken == "CHANGE_ME" {
		problems = append(problems, "DOCKERHUB_TOKEN is still the placeholder CHANGE_ME; create a Docker Hub access token.")
	}
	if hubUser == "CHANGE_ME" {
		problems = append(problems, "DOCKERHUB_USERNAME is still the placeholder CHANGE_ME; enter your Docker Hub username.")
	}

	hubRepo := strings.TrimSpace(os.Getenv("DOCKERHUB_REPO"))
	if hubRepo == "" {
		hubRepo = defaultDockerRepo
	}
	if !repoRE.MatchString(hubRepo) {
		problems = append(problems, "DOCKERHUB_REPO must be a single lowercase repository name (letters, digits, dot, underscore, dash), for example ferry.")
	}

	retention, err := intEnv("FERRY_RETENTION_DAYS", defaultRetention)
	if err != nil {
		problems = append(problems, err.Error())
	} else if retention < 0 {
		problems = append(problems, "FERRY_RETENTION_DAYS must be 0 (disabled) or a positive number of days.")
	}

	if len(problems) > 0 {
		return nil, errors.New("invalid configuration:\n  - " + strings.Join(problems, "\n  - "))
	}

	return &Config{
		Username:          username,
		Password:          password,
		PasswordHash:      passwordHash,
		SecretKey:         secret,
		Port:              port,
		ListenAddr:        listenAddr,
		MaxTotalBytes:     maxTotal,
		DataDir:           dataDir,
		CookieSecure:      cookieSecure,
		Platform:          platform,
		TrustProxy:        trustProxy,
		DockerHubUsername: hubUser,
		DockerHubToken:    hubToken,
		DockerHubRepo:     hubRepo,
		RetentionDays:     retention,
		Domain:            strings.TrimSpace(os.Getenv("FERRY_DOMAIN")),
		GitHubToken:       strings.TrimSpace(os.Getenv("GITHUB_TOKEN")),
	}, nil
}

func validateListenAddr(value string) error {
	host, port, err := net.SplitHostPort(value)
	if err != nil {
		return fmt.Errorf("FERRY_LISTEN_ADDR must look like 0.0.0.0:8080 or 127.0.0.1:8080, got %q.", value)
	}
	_ = host
	n, err := strconv.Atoi(port)
	if err != nil || n < 1 || n > 65535 {
		return fmt.Errorf("FERRY_LISTEN_ADDR has an invalid port %q.", port)
	}
	return nil
}

func intEnv(name string, def int) (int, error) {
	raw := strings.TrimSpace(os.Getenv(name))
	if raw == "" {
		return def, nil
	}
	v, err := strconv.Atoi(raw)
	if err != nil {
		return 0, fmt.Errorf("%s must be a whole number, got %q.", name, raw)
	}
	return v, nil
}

func int64Env(name string, def int64) (int64, error) {
	raw := strings.TrimSpace(os.Getenv(name))
	if raw == "" {
		return def, nil
	}
	v, err := strconv.ParseInt(raw, 10, 64)
	if err != nil {
		return 0, fmt.Errorf("%s must be a whole number of bytes, got %q.", name, raw)
	}
	return v, nil
}

func boolEnv(name string, def bool) (bool, error) {
	raw := strings.TrimSpace(os.Getenv(name))
	if raw == "" {
		return def, nil
	}
	v, err := strconv.ParseBool(raw)
	if err != nil {
		return false, fmt.Errorf("%s must be true or false, got %q.", name, raw)
	}
	return v, nil
}
