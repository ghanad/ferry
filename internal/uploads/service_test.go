package uploads

import (
	"errors"
	"testing"
)

func TestCheckQuota(t *testing.T) {
	if err := CheckQuota(4, 6, 10); err != nil {
		t.Fatalf("exact fit rejected: %v", err)
	}
	if err := CheckQuota(5, 6, 10); !errors.Is(err, ErrQuota) {
		t.Fatalf("over-quota error = %v, want ErrQuota", err)
	}
	if err := CheckQuota(0, 10, 10); err != nil {
		t.Fatalf("full-size file rejected: %v", err)
	}
	if err := CheckQuota(0, -1, 10); err == nil {
		t.Fatal("negative size accepted")
	}
}

func TestValidateOffset(t *testing.T) {
	if err := ValidateOffset(0, 0, 10); err != nil {
		t.Fatalf("fresh offset rejected: %v", err)
	}
	if err := ValidateOffset(10, 10, 10); err != nil {
		t.Fatalf("complete offset rejected: %v", err)
	}
	for _, tc := range []struct {
		offset   int64
		received int64
		declared int64
		current  int64
	}{
		{3, 4, 10, 4},
		{5, 4, 10, 4},
		{-1, 0, 10, 0},
		{11, 10, 10, 10},
	} {
		err := ValidateOffset(tc.offset, tc.received, tc.declared)
		var oe *OffsetError
		if !errors.As(err, &oe) {
			t.Fatalf("ValidateOffset(%d,%d,%d) = %v, want OffsetError", tc.offset, tc.received, tc.declared, err)
		}
		if oe.Current != tc.current {
			t.Fatalf("current = %d, want %d", oe.Current, tc.current)
		}
	}
}
