package main

import (
	"context"
	"fmt"
	"io"
	"os"
	"os/signal"
	"runtime"
	"syscall"
	"time"

	"ferry/internal/update"
)

const updateCheckTimeout = 20 * time.Second

// checkUpdateCommand runs "ferry check-update" and returns a process exit code.
func checkUpdateCommand(args []string) int {
	for _, arg := range args {
		switch arg {
		case "-h", "--help", "help":
			printCheckUpdateUsage()
			return 0
		default:
			fmt.Fprintf(os.Stderr, "check-update: unknown argument %q\n\n", arg)
			printCheckUpdateUsage()
			return 2
		}
	}

	signalCtx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	ctx, cancel := context.WithTimeout(signalCtx, updateCheckTimeout)
	defer cancel()

	return reportUpdate(ctx, os.Stdout, os.Stderr, version, update.New(os.Getenv("GITHUB_TOKEN")))
}

func printCheckUpdateUsage() {
	fmt.Print(`Usage:
  ferry check-update

Asks GitHub for the newest published Ferry release and compares it with this
build. Set GITHUB_TOKEN when the repository is private.

Exit codes:
  0  this build is up to date (or is a development build)
  1  a newer release is available
  2  the check failed (network, token, or GitHub error)
`)
}

// reportUpdate prints the result of one check and returns the exit code.
func reportUpdate(ctx context.Context, stdout, stderr io.Writer, current string, checker *update.Checker) int {
	release, err := checker.Latest(ctx)
	if err != nil {
		fmt.Fprintf(stderr, "Could not check for updates: %v\n", err)
		return 2
	}

	parsed, ok := update.ParseVersion(current)
	if !ok {
		fmt.Fprintf(stdout, "This is a development build (%s); the latest release is %s.\n", current, release.Tag)
		fmt.Fprintf(stdout, "Release page: %s\n", release.URL)
		return 0
	}
	if update.Compare(parsed, release.Version) < 0 {
		fmt.Fprintf(stdout, "A newer Ferry release is available: %s (this build is %s).\n", release.Tag, current)
		fmt.Fprintf(stdout, "Download it from %s\n", release.URL)
		if runtime.GOOS == "linux" {
			fmt.Fprintln(stdout, "Install it with: sudo ferry self-update")
		}
		return 1
	}
	fmt.Fprintf(stdout, "Ferry %s is up to date (latest release: %s).\n", current, release.Tag)
	return 0
}
