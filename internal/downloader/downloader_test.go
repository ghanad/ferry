package downloader

import (
	"net"
	"testing"
)

func TestIsBlockedIP(t *testing.T) {
	tests := []struct {
		ip      string
		blocked bool
	}{
		{"127.0.0.1", true},
		{"127.10.20.30", true},
		{"10.1.2.3", true},
		{"172.16.0.1", true},
		{"172.31.255.255", true},
		{"192.168.1.1", true},
		{"169.254.169.254", true},
		{"100.64.0.1", true},
		{"100.127.255.254", true},
		{"0.0.0.0", true},
		{"224.0.0.1", true},
		{"240.0.0.1", true},
		{"255.255.255.255", true},
		{"192.0.2.1", true},
		{"198.51.100.7", true},
		{"203.0.113.9", true},
		{"::1", true},
		{"::", true},
		{"fc00::1", true},
		{"fd12:3456::1", true},
		{"fe80::1", true},
		{"ff02::1", true},
		{"2001:db8::1", true},
		{"2001::1", true},
		{"2002:c0a8:0101::1", true},
		{"64:ff9b::c0a8:101", true},
		{"::ffff:127.0.0.1", true},
		{"::ffff:192.168.0.1", true},
		{"1.1.1.1", false},
		{"8.8.8.8", false},
		{"93.184.216.34", false},
		{"2606:4700:4700::1111", false},
		{"::ffff:8.8.8.8", false},
	}
	for _, tc := range tests {
		ip := net.ParseIP(tc.ip)
		if ip == nil {
			t.Fatalf("test IP %q did not parse", tc.ip)
		}
		if got := IsBlockedIP(ip); got != tc.blocked {
			t.Errorf("IsBlockedIP(%s) = %v, want %v", tc.ip, got, tc.blocked)
		}
	}
}

func TestValidateURL(t *testing.T) {
	good := []string{
		"http://example.com/file.zip",
		"https://example.com/a/b?x=1",
		"HTTPS://example.com/file",
	}
	for _, raw := range good {
		if _, err := ValidateURL(raw); err != nil {
			t.Errorf("ValidateURL(%q) error: %v", raw, err)
		}
	}
	bad := []string{
		"ftp://example.com/file",
		"file:///etc/passwd",
		"javascript:alert(1)",
		"http://user:pass@example.com/file",
		"http:///missing-host",
		"",
	}
	for _, raw := range bad {
		if _, err := ValidateURL(raw); err == nil {
			t.Errorf("ValidateURL(%q) unexpectedly succeeded", raw)
		}
	}
}
