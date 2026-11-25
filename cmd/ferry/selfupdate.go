package main

import (
	"archive/tar"
	"compress/gzip"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"runtime"
	"strings"
	"syscall"
	"time"

	"ferry/internal/update"
)

const (
	selfUpdateTimeout = 15 * time.Minute
	maxBinaryBytes    = 256 << 20
	serviceUnitName   = "ferry"
)

// selfUpdateCommand runs "ferry self-update".
func selfUpdateCommand(args []string) error {
	for _, arg := range args {
		if arg == "-h" || arg == "--help" || arg == "help" {
			printSelfUpdateUsage(os.Stdout)
			return nil
		}
	}

	flags := flag.NewFlagSet("self-update", flag.ContinueOnError)
	flags.SetOutput(os.Stderr)
	noRestart := flags.Bool("no-restart", false, "replace the binary but do not restart the service")
	force := flags.Bool("force", false, "reinstall even when this build is not older than the latest release")
	flags.Usage = func() { printSelfUpdateUsage(flags.Output()) }
	if err := flags.Parse(args); err != nil {
		return err
	}
	if flags.NArg() > 0 {
		return fmt.Errorf("unexpected argument %q", flags.Arg(0))
	}

	if runtime.GOOS != "linux" {
		return fmt.Errorf("self-update is only supported on Linux; download the %s/%s release manually", runtime.GOOS, runtime.GOARCH)
	}
	if os.Geteuid() != 0 {
		return errors.New("self-update must run as root; use: sudo ferry self-update")
	}

	signalCtx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	ctx, cancel := context.WithTimeout(signalCtx, selfUpdateTimeout)
	defer cancel()

	return runSelfUpdate(ctx, os.Stdout, version, update.New(os.Getenv("GITHUB_TOKEN")), *noRestart, *force)
}

func printSelfUpdateUsage(w io.Writer) {
	fmt.Fprint(w, `Usage:
  sudo ferry self-update [--no-restart] [--force]

Downloads the newest published Ferry release for this Linux architecture,
verifies its SHA-256 checksum, replaces the running binary atomically, and
restarts the ferry systemd service.

  --no-restart   replace the binary but do not restart the service
  --force        reinstall even when this build is not older than the latest release

Restarting interrupts an active transfer. Set GITHUB_TOKEN when the release
repository is private.
`)
}

// runSelfUpdate performs one update. It is separate from the command so the
// steps stay readable and testable.
func runSelfUpdate(ctx context.Context, out io.Writer, current string, checker *update.Checker, noRestart, force bool) error {
	release, err := checker.Latest(ctx)
	if err != nil {
		return err
	}

	if parsed, ok := update.ParseVersion(current); ok && !force {
		switch cmp := update.Compare(parsed, release.Version); {
		case cmp == 0:
			fmt.Fprintf(out, "Ferry %s is already up to date (latest release: %s).\n", current, release.Tag)
			return nil
		case cmp > 0:
			fmt.Fprintf(out, "This build (%s) is newer than the latest release (%s); nothing to do. Use --force to reinstall %s.\n", current, release.Tag, release.Tag)
			return nil
		}
	}

	assetName := fmt.Sprintf("ferry-%s-linux-%s.tar.gz", release.Tag, runtime.GOARCH)
	archiveAsset, ok := release.AssetByName(assetName)
	if !ok {
		return fmt.Errorf("release %s has no asset named %s", release.Tag, assetName)
	}
	checksumAsset, ok := release.AssetByName(assetName + ".sha256")
	if !ok {
		return fmt.Errorf("release %s has no checksum asset named %s.sha256", release.Tag, assetName)
	}

	// Work next to the installed binary: the directory is executable (some
	// systems mount /tmp noexec) and the final rename stays on one filesystem.
	target, err := executablePath()
	if err != nil {
		return err
	}
	dir, err := os.MkdirTemp(filepath.Dir(target), ".ferry-self-update-*")
	if err != nil {
		return fmt.Errorf("create a temporary directory next to %s: %w", target, err)
	}
	defer os.RemoveAll(dir)

	fmt.Fprintf(out, "Downloading Ferry %s for linux/%s...\n", release.Tag, runtime.GOARCH)
	archivePath := filepath.Join(dir, assetName)
	gotSum, err := downloadToFile(ctx, checker, archiveAsset, archivePath)
	if err != nil {
		return err
	}
	checksumPath := filepath.Join(dir, assetName+".sha256")
	if _, err := downloadToFile(ctx, checker, checksumAsset, checksumPath); err != nil {
		return err
	}
	wantSum, err := readChecksum(checksumPath, assetName)
	if err != nil {
		return err
	}
	if !strings.EqualFold(gotSum, wantSum) {
		return fmt.Errorf("checksum mismatch for %s: got %s, want %s", assetName, gotSum, wantSum)
	}

	newBinary := filepath.Join(dir, "ferry")
	if err := extractFerryBinary(archivePath, newBinary); err != nil {
		return err
	}
	if err := verifyBinary(ctx, newBinary, release.Tag); err != nil {
		return err
	}

	if err := replaceBinary(newBinary, target); err != nil {
		return fmt.Errorf("replace %s: %w", target, err)
	}
	fmt.Fprintf(out, "Installed Ferry %s at %s.\n", release.Tag, target)

	if noRestart {
		fmt.Fprintln(out, "Restart the service to use the new version: sudo systemctl restart ferry")
		return nil
	}
	return restartService(ctx, out)
}

// downloadToFile streams an asset to path and returns its SHA-256 hex digest.
func downloadToFile(ctx context.Context, checker *update.Checker, asset update.Asset, path string) (string, error) {
	file, err := os.OpenFile(path, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
	if err != nil {
		return "", fmt.Errorf("create %s: %w", filepath.Base(path), err)
	}
	digest := sha256.New()
	if err := checker.DownloadAsset(ctx, asset, io.MultiWriter(file, digest)); err != nil {
		file.Close()
		return "", err
	}
	if err := file.Close(); err != nil {
		return "", fmt.Errorf("write %s: %w", filepath.Base(path), err)
	}
	return hex.EncodeToString(digest.Sum(nil)), nil
}

// readChecksum parses a sha256sum-style file and checks that it names assetName.
func readChecksum(path, assetName string) (string, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return "", fmt.Errorf("read %s: %w", filepath.Base(path), err)
	}
	fields := strings.Fields(string(data))
	if len(fields) == 0 {
		return "", fmt.Errorf("checksum file %s is empty", filepath.Base(path))
	}
	sum := strings.ToLower(fields[0])
	if len(sum) != sha256.Size*2 {
		return "", fmt.Errorf("checksum file %s does not contain a SHA-256 hash", filepath.Base(path))
	}
	if _, err := hex.DecodeString(sum); err != nil {
		return "", fmt.Errorf("checksum file %s does not contain a SHA-256 hash", filepath.Base(path))
	}
	if len(fields) > 1 {
		named := strings.TrimPrefix(fields[1], "*")
		if named != assetName {
			return "", fmt.Errorf("checksum file is for %q, not %q", named, assetName)
		}
	}
	return sum, nil
}

// extractFerryBinary copies the "ferry" entry out of a release archive.
func extractFerryBinary(archivePath, dest string) error {
	file, err := os.Open(archivePath)
	if err != nil {
		return fmt.Errorf("open archive: %w", err)
	}
	defer file.Close()

	gz, err := gzip.NewReader(file)
	if err != nil {
		return fmt.Errorf("read archive: %w", err)
	}
	defer gz.Close()

	reader := tar.NewReader(gz)
	for {
		header, err := reader.Next()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return fmt.Errorf("read archive: %w", err)
		}
		if strings.TrimPrefix(header.Name, "./") != "ferry" {
			continue
		}
		if header.Typeflag != tar.TypeReg {
			return errors.New("archive entry ferry is not a regular file")
		}
		out, err := os.OpenFile(dest, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o755)
		if err != nil {
			return fmt.Errorf("create the new binary: %w", err)
		}
		written, err := io.Copy(out, io.LimitReader(reader, maxBinaryBytes+1))
		if err != nil {
			out.Close()
			return fmt.Errorf("extract the new binary: %w", err)
		}
		if written > maxBinaryBytes {
			out.Close()
			return fmt.Errorf("the new binary is larger than %d bytes", maxBinaryBytes)
		}
		if err := out.Close(); err != nil {
			return fmt.Errorf("write the new binary: %w", err)
		}
		return nil
	}
	return errors.New("archive does not contain the ferry binary")
}

// verifyBinary checks the ELF header and the version reported by the new binary.
func verifyBinary(ctx context.Context, path, tag string) error {
	file, err := os.Open(path)
	if err != nil {
		return fmt.Errorf("open the new binary: %w", err)
	}
	var magic [4]byte
	_, readErr := io.ReadFull(file, magic[:])
	file.Close()
	if readErr != nil {
		return fmt.Errorf("read the new binary: %w", readErr)
	}
	if magic != [4]byte{0x7f, 'E', 'L', 'F'} {
		return errors.New("the downloaded file is not a Linux ELF executable")
	}

	checkCtx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	output, err := exec.CommandContext(checkCtx, path, "--version").Output()
	if err != nil {
		return fmt.Errorf("the new binary did not run: %w", err)
	}
	got := strings.TrimSpace(string(output))
	want := "ferry " + tag
	if got != want {
		return fmt.Errorf("the new binary reports %q, want %q", got, want)
	}
	return nil
}

// executablePath returns the resolved path of the running binary.
func executablePath() (string, error) {
	exe, err := os.Executable()
	if err != nil {
		return "", fmt.Errorf("locate the running binary: %w", err)
	}
	resolved, err := filepath.EvalSymlinks(exe)
	if err != nil {
		return "", fmt.Errorf("resolve %s: %w", exe, err)
	}
	return resolved, nil
}

// replaceBinary atomically replaces dest with src. The temporary file lives in
// the destination directory so the rename cannot cross filesystems.
func replaceBinary(src, dest string) error {
	temp, err := os.CreateTemp(filepath.Dir(dest), ".ferry-update-*")
	if err != nil {
		return err
	}
	tempName := temp.Name()
	defer os.Remove(tempName) // a no-op after a successful rename

	in, err := os.Open(src)
	if err != nil {
		temp.Close()
		return err
	}
	if _, err := io.Copy(temp, in); err != nil {
		in.Close()
		temp.Close()
		return err
	}
	if err := in.Close(); err != nil {
		temp.Close()
		return err
	}
	if err := temp.Chmod(0o755); err != nil {
		temp.Close()
		return err
	}
	if err := temp.Sync(); err != nil {
		temp.Close()
		return err
	}
	if err := temp.Close(); err != nil {
		return err
	}
	return os.Rename(tempName, dest)
}

// restartService restarts the systemd unit and confirms that it came back up.
func restartService(ctx context.Context, out io.Writer) error {
	if _, err := os.Stat("/run/systemd/system"); err != nil {
		fmt.Fprintln(out, "systemd was not detected; restart Ferry yourself to use the new version.")
		return nil
	}
	systemctl, err := exec.LookPath("systemctl")
	if err != nil {
		fmt.Fprintln(out, "systemctl was not found; restart Ferry yourself to use the new version.")
		return nil
	}

	fmt.Fprintf(out, "Restarting the %s service...\n", serviceUnitName)
	restartCtx, cancel := context.WithTimeout(ctx, 60*time.Second)
	defer cancel()
	cmd := exec.CommandContext(restartCtx, systemctl, "restart", serviceUnitName)
	cmd.Stdout = out
	cmd.Stderr = out
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("restart the %s service: %w (the new binary is installed; run: sudo systemctl restart %s)", serviceUnitName, err, serviceUnitName)
	}
	checkCtx, cancelCheck := context.WithTimeout(ctx, 10*time.Second)
	defer cancelCheck()
	if err := exec.CommandContext(checkCtx, systemctl, "is-active", "--quiet", serviceUnitName).Run(); err != nil {
		return fmt.Errorf("the %s service did not become active after the update; check: sudo journalctl -u %s -n 50", serviceUnitName, serviceUnitName)
	}
	fmt.Fprintln(out, "Ferry was restarted with the new version.")
	return nil
}
