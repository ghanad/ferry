package main

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"golang.org/x/term"

	"ferry/internal/auth"
	"ferry/internal/config"
	"ferry/internal/db"
	"ferry/internal/dockerhub"
	"ferry/internal/downloader"
	"ferry/internal/imagebuild"
	"ferry/internal/jobs"
	"ferry/internal/update"
	"ferry/internal/uploads"
	"ferry/internal/web"
)

// version is injected at build time with -ldflags "-X main.version=...".
var version = "dev"

func main() {
	if len(os.Args) > 1 {
		switch os.Args[1] {
		case "--version", "-version", "version":
			fmt.Printf("ferry %s\n", version)
			return
		case "hash-password":
			if err := hashPassword(); err != nil {
				fmt.Fprintf(os.Stderr, "Could not hash the password: %v\n", err)
				os.Exit(1)
			}
			return
		case "unpack":
			if err := unpackCommand(os.Args[2:]); err != nil {
				fmt.Fprintf(os.Stderr, "Unpack failed: %v\n", err)
				os.Exit(1)
			}
			return
		case "check-update":
			os.Exit(checkUpdateCommand(os.Args[2:]))
		case "self-update":
			if err := selfUpdateCommand(os.Args[2:]); err != nil {
				fmt.Fprintf(os.Stderr, "Self-update failed: %v\n", err)
				os.Exit(1)
			}
			return
		case "--help", "-help", "help":
			printUsage()
			return
		}
	}
	if err := run(); err != nil {
		fmt.Fprintf(os.Stderr, "\nFerry could not start:\n\n%v\n\n", err)
		os.Exit(1)
	}
}

func printUsage() {
	fmt.Print(`Ferry - pack files into a private Docker Hub image.

Usage:
  ferry                 start the web server (configuration comes from environment variables)
  ferry --version       print the version
  ferry hash-password   read a password from the terminal and print a bcrypt hash
  ferry unpack          verify, decrypt and decompress files inside an image
  ferry check-update    ask GitHub whether a newer release is available
  ferry self-update     download and install the newest release (run with sudo)
  ferry help            show this help

The hash-password output is used as FERRY_PASSWORD_HASH in the environment file.
`)
}

func hashPassword() error {
	var password string
	if term.IsTerminal(int(os.Stdin.Fd())) {
		fmt.Fprint(os.Stderr, "New password (typing is hidden): ")
		raw, err := term.ReadPassword(int(os.Stdin.Fd()))
		fmt.Fprintln(os.Stderr)
		if err != nil {
			return err
		}
		password = string(raw)
	} else {
		reader := bufio.NewReader(os.Stdin)
		line, err := reader.ReadString('\n')
		if err != nil && line == "" {
			return err
		}
		password = strings.TrimRight(line, "\r\n")
	}
	if password == "" {
		return errors.New("no password was entered")
	}
	hash, err := auth.HashPassword(password)
	if err != nil {
		return err
	}
	fmt.Println(hash)
	return nil
}

func run() error {
	cfg, err := config.Load()
	if err != nil {
		return err
	}

	logger := slog.New(slog.NewTextHandler(os.Stdout, &slog.HandlerOptions{Level: slog.LevelInfo}))
	slog.SetDefault(logger)

	if err := os.MkdirAll(cfg.DataDir, 0o750); err != nil {
		return fmt.Errorf("create FERRY_DATA_DIR %s: %w", cfg.DataDir, err)
	}
	jobsDir := filepath.Join(cfg.DataDir, "jobs")
	if err := os.MkdirAll(jobsDir, 0o750); err != nil {
		return fmt.Errorf("create jobs directory %s: %w", jobsDir, err)
	}

	store, err := db.Open(filepath.Join(cfg.DataDir, "ferry.db"), cfg.DataDir)
	if err != nil {
		return err
	}
	defer store.Close()

	sessions, err := auth.New(cfg.SecretKey, cfg.Username, cfg.CookieSecure)
	if err != nil {
		return fmt.Errorf("set up sessions: %w", err)
	}
	uploadSvc := uploads.New(store, cfg.DataDir, cfg.MaxTotalBytes)
	dl := downloader.New()
	builder, err := imagebuild.New(cfg.DockerHubUsername, cfg.DockerHubToken, cfg.DockerHubRepo, cfg.Platform)
	if err != nil {
		return err
	}
	hub := dockerhub.New(cfg.DockerHubUsername, cfg.DockerHubToken)
	manager := jobs.New(cfg, store, dl, builder, hub, logger)
	updates := update.NewWatcher(update.New(cfg.GitHubToken), version)
	server, err := web.New(cfg, store, sessions, uploadSvc, manager, logger, version, updates)
	if err != nil {
		return err
	}

	updateCtx, stopUpdates := context.WithCancel(context.Background())
	defer stopUpdates()
	updates.Start(updateCtx)

	manager.Start()
	if err := manager.Recover(context.Background()); err != nil {
		logger.Error("startup recovery finished with errors", "error", err)
	}

	httpServer := &http.Server{
		Addr:              cfg.ListenAddr,
		Handler:           server.Handler(),
		ReadHeaderTimeout: 15 * time.Second,
		IdleTimeout:       120 * time.Second,
		MaxHeaderBytes:    1 << 20,
		// ReadTimeout and WriteTimeout are intentionally unset: multi-gigabyte
		// uploads and long-running downloads must not be killed by them.
	}

	signalCtx, stopSignals := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stopSignals()

	errCh := make(chan error, 1)
	go func() {
		logger.Info("Ferry is running", "addr", cfg.ListenAddr, "data_dir", cfg.DataDir, "platform", cfg.Platform, "version", version)
		errCh <- httpServer.ListenAndServe()
	}()

	var serveErr error
	select {
	case serveErr = <-errCh:
		if !errors.Is(serveErr, http.ErrServerClosed) {
			logger.Error("http server stopped", "error", serveErr)
		}
	case <-signalCtx.Done():
		logger.Info("shutdown signal received; draining requests")
	}

	httpShutdownCtx, cancelHTTP := context.WithTimeout(context.Background(), 25*time.Second)
	if err := httpServer.Shutdown(httpShutdownCtx); err != nil {
		logger.Error("http shutdown", "error", err)
	}
	cancelHTTP()

	logger.Info("stopping the job worker")
	workerShutdownCtx, cancelWorker := context.WithTimeout(context.Background(), 25*time.Second)
	if err := manager.Shutdown(workerShutdownCtx); err != nil {
		logger.Error("worker shutdown", "error", err)
	}
	cancelWorker()
	logger.Info("Ferry stopped")
	if serveErr != nil && !errors.Is(serveErr, http.ErrServerClosed) {
		return fmt.Errorf("HTTP server: %w", serveErr)
	}
	return nil
}
