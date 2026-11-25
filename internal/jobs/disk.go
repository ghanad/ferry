package jobs

import (
	"fmt"
	"syscall"
)

// FreeDiskBytes returns available bytes for the filesystem containing path.
func FreeDiskBytes(path string) (int64, error) {
	var st syscall.Statfs_t
	if err := syscall.Statfs(path, &st); err != nil {
		return 0, fmt.Errorf("read free disk space: %w", err)
	}
	bsize := int64(st.Bsize)
	avail := int64(st.Bavail)
	if bsize <= 0 || avail < 0 {
		return 0, fmt.Errorf("read free disk space: unexpected filesystem values")
	}
	if avail > (1<<63-1)/bsize {
		return 1<<63 - 1, nil
	}
	return avail * bsize, nil
}

// CheckDiskSpace requires 1.5 times the job size to be free. Layers are
// streamed, so a second full copy is not needed.
func CheckDiskSpace(path string, total int64) error {
	free, err := FreeDiskBytes(path)
	if err != nil {
		return err
	}
	required := float64(total) * 1.5
	if float64(free) < required {
		return fmt.Errorf("not enough free disk space: the job needs about %s free (1.5x its %s size), but only %s is available in %s",
			formatBytes(int64(required)), formatBytes(total), formatBytes(free), path)
	}
	return nil
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
