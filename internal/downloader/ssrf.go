package downloader

import (
	"errors"
	"fmt"
	"net"
	"net/netip"
	"net/url"
	"strings"
)

// ErrBlockedAddress is returned when a download would connect to a private,
// loopback, link-local, multicast or otherwise reserved address.
var ErrBlockedAddress = errors.New("blocked address: Ferry only downloads from public internet addresses")

var blockedV4 = mustPrefixes(
	"0.0.0.0/8",
	"10.0.0.0/8",
	"100.64.0.0/10",
	"127.0.0.0/8",
	"169.254.0.0/16",
	"172.16.0.0/12",
	"192.0.0.0/24",
	"192.0.2.0/24",
	"192.88.99.0/24",
	"192.168.0.0/16",
	"198.18.0.0/15",
	"198.51.100.0/24",
	"203.0.113.0/24",
	"224.0.0.0/4",
	"240.0.0.0/4",
)

var blockedV6 = mustPrefixes(
	"::/128",
	"::1/128",
	"::ffff:0:0/96",
	"64:ff9b::/96",
	"64:ff9b:1::/48",
	"100::/64",
	"2001::/32",
	"2001:2::/48",
	"2001:10::/28",
	"2001:20::/28",
	"2001:db8::/32",
	"2002::/16",
	"3fff::/20",
	"5f00::/16",
	"fc00::/7",
	"fe80::/10",
	"fec0::/10",
	"ff00::/8",
)

func mustPrefixes(values ...string) []netip.Prefix {
	out := make([]netip.Prefix, 0, len(values))
	for _, v := range values {
		out = append(out, netip.MustParsePrefix(v))
	}
	return out
}

// IsBlockedIP reports whether an IP must not be dialed by the URL downloader.
func IsBlockedIP(ip net.IP) bool {
	if ip == nil {
		return true
	}
	addr, ok := netip.AddrFromSlice(ip)
	if !ok {
		return true
	}
	// Treat IPv4-mapped IPv6 exactly as the IPv4 address it contains.
	addr = addr.Unmap()
	if !addr.IsValid() || addr.IsUnspecified() || addr.IsLoopback() ||
		addr.IsPrivate() || addr.IsLinkLocalUnicast() || addr.IsLinkLocalMulticast() ||
		addr.IsMulticast() {
		return true
	}
	prefixes := blockedV6
	if addr.Is4() {
		prefixes = blockedV4
	}
	for _, p := range prefixes {
		if p.Contains(addr) {
			return true
		}
	}
	return false
}

// ValidateURL performs syntax and scheme checks. The actual IP check happens
// in the dialer's Control function, after DNS resolution, on every hop.
func ValidateURL(raw string) (*url.URL, error) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return nil, errors.New("URL is empty")
	}
	if len(raw) > 4096 {
		return nil, errors.New("URL is too long (maximum 4096 characters)")
	}
	for _, r := range raw {
		if r < 0x20 || r == 0x7f {
			return nil, errors.New("URL contains control characters")
		}
	}
	u, err := url.Parse(raw)
	if err != nil {
		return nil, fmt.Errorf("invalid URL: %w", err)
	}
	scheme := strings.ToLower(u.Scheme)
	if scheme != "http" && scheme != "https" {
		return nil, errors.New("only http:// and https:// URLs are allowed")
	}
	if u.Host == "" || u.Hostname() == "" {
		return nil, errors.New("URL is missing a hostname")
	}
	if u.User != nil {
		return nil, errors.New("URLs containing a username or password are not allowed")
	}
	u.Scheme = scheme
	return u, nil
}
