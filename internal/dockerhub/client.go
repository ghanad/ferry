// Package dockerhub deletes image tags through the Docker Hub HTTP API.
package dockerhub

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"
)

// These are constants so they are easy to update if the API changes.
const (
	AuthTokenURL    = "https://hub.docker.com/v2/auth/token"
	LoginURL        = "https://hub.docker.com/v2/users/login"
	RepositoriesURL = "https://hub.docker.com/v2/repositories"
)

// Client removes tags from Docker Hub.
type Client struct {
	http     *http.Client
	username string
	token    string
}

// New creates a Docker Hub API client.
func New(username, token string) *Client {
	return &Client{
		http:     &http.Client{Timeout: 30 * time.Second},
		username: username,
		token:    token,
	}
}

type authResponse struct {
	Token       string `json:"token"`
	AccessToken string `json:"access_token"`
}

// DeleteTag removes one tag. A 404 is treated as already deleted, which makes
// retention cleanup idempotent.
func (c *Client) DeleteTag(ctx context.Context, repository, tag string) error {
	if strings.TrimSpace(repository) == "" {
		return errors.New("repository is empty")
	}
	if strings.TrimSpace(tag) == "" {
		return errors.New("tag is empty")
	}
	jwt, err := c.authenticate(ctx)
	if err != nil {
		return err
	}
	endpoint := RepositoriesURL + "/" + escapeRepository(repository) + "/tags/" + url.PathEscape(tag) + "/"
	req, err := http.NewRequestWithContext(ctx, http.MethodDelete, endpoint, nil)
	if err != nil {
		return fmt.Errorf("create tag delete request: %w", err)
	}
	req.Header.Set("Authorization", "Bearer "+jwt)
	req.Header.Set("Accept", "application/json")
	req.Header.Set("User-Agent", "ferry/1.0")
	resp, err := c.http.Do(req)
	if err != nil {
		return fmt.Errorf("delete Docker Hub tag: %w", err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))

	switch {
	case resp.StatusCode == http.StatusNoContent || resp.StatusCode == http.StatusOK:
		return nil
	case resp.StatusCode == http.StatusNotFound:
		return nil
	case resp.StatusCode == http.StatusUnauthorized || resp.StatusCode == http.StatusForbidden:
		return fmt.Errorf("Docker Hub refused the delete (HTTP %d). The access token needs Read, Write and Delete permission for %s",
			resp.StatusCode, repository)
	default:
		return fmt.Errorf("Docker Hub returned HTTP %d while deleting %s:%s: %s",
			resp.StatusCode, repository, tag, compactBody(body))
	}
}

func (c *Client) authenticate(ctx context.Context) (string, error) {
	payload, err := json.Marshal(map[string]string{
		"identifier": c.username,
		"secret":     c.token,
	})
	if err != nil {
		return "", err
	}
	jwt, err1 := c.requestToken(ctx, AuthTokenURL, payload, "authenticate with Docker Hub")
	if err1 == nil {
		return jwt, nil
	}

	loginPayload, err := json.Marshal(map[string]string{
		"username": c.username,
		"password": c.token,
	})
	if err != nil {
		return "", err
	}
	jwt, err2 := c.requestToken(ctx, LoginURL, loginPayload, "log in to Docker Hub")
	if err2 == nil {
		return jwt, nil
	}
	return "", fmt.Errorf("%v; fallback login also failed: %v", err1, err2)
}

func (c *Client) requestToken(ctx context.Context, endpoint string, payload []byte, action string) (string, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, bytes.NewReader(payload))
	if err != nil {
		return "", fmt.Errorf("%s: %w", action, err)
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "application/json")
	req.Header.Set("User-Agent", "ferry/1.0")
	resp, err := c.http.Do(req)
	if err != nil {
		return "", fmt.Errorf("%s: %w", action, err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 64*1024))
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		if resp.StatusCode == http.StatusUnauthorized || resp.StatusCode == http.StatusForbidden {
			return "", fmt.Errorf("%s: Docker Hub rejected the credentials (HTTP %d). Check DOCKERHUB_USERNAME and use a token with Read, Write and Delete permission",
				action, resp.StatusCode)
		}
		return "", fmt.Errorf("%s: HTTP %d: %s", action, resp.StatusCode, compactBody(body))
	}
	var ar authResponse
	if err := json.Unmarshal(body, &ar); err != nil {
		return "", fmt.Errorf("%s: invalid Docker Hub response: %w", action, err)
	}
	token := ar.Token
	if token == "" {
		token = ar.AccessToken
	}
	if token == "" {
		return "", fmt.Errorf("%s: Docker Hub response did not contain a token", action)
	}
	return token, nil
}

func escapeRepository(repository string) string {
	parts := strings.Split(repository, "/")
	for i := range parts {
		parts[i] = url.PathEscape(parts[i])
	}
	return strings.Join(parts, "/")
}

func compactBody(body []byte) string {
	s := strings.TrimSpace(string(body))
	s = strings.ReplaceAll(s, "\n", " ")
	if len(s) > 300 {
		s = s[:300] + "..."
	}
	if s == "" {
		return "(empty response)"
	}
	return s
}

// SplitImage splits "user/repo:tag" into its repository and tag.
func SplitImage(image string) (repository, tag string, err error) {
	image = strings.TrimSpace(image)
	if image == "" {
		return "", "", errors.New("image name is empty")
	}
	lastSlash := strings.LastIndex(image, "/")
	lastColon := strings.LastIndex(image, ":")
	if lastColon <= lastSlash {
		return "", "", fmt.Errorf("image name %q has no tag", image)
	}
	repository = image[:lastColon]
	tag = image[lastColon+1:]
	if repository == "" || tag == "" || strings.Contains(tag, "/") {
		return "", "", fmt.Errorf("image name %q is invalid", image)
	}
	return repository, tag, nil
}
