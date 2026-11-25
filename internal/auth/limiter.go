package auth

import (
	"sync"
	"time"
)

const (
	maxFailures    = 5
	failureWindow  = 10 * time.Minute
	blockDuration  = 10 * time.Minute
	limiterMaxIdle = time.Hour
)

type loginAttempts struct {
	failures     []time.Time
	blockedUntil time.Time
	lastSeen     time.Time
}

// Limiter blocks an IP after five failed logins in ten minutes for ten minutes.
type Limiter struct {
	mu      sync.Mutex
	entries map[string]*loginAttempts
	now     func() time.Time
}

// NewLimiter creates an empty login limiter.
func NewLimiter() *Limiter {
	return &Limiter{entries: make(map[string]*loginAttempts), now: time.Now}
}

// Blocked reports whether ip is currently blocked and for how much longer.
func (l *Limiter) Blocked(ip string) (bool, time.Duration) {
	l.mu.Lock()
	defer l.mu.Unlock()
	now := l.now()
	e := l.entries[ip]
	if e == nil {
		return false, 0
	}
	if now.After(e.blockedUntil) {
		if e.blockedUntil.IsZero() {
			return false, 0
		}
		// Block expired. Forget the history so the next failure starts fresh.
		delete(l.entries, ip)
		return false, 0
	}
	return true, e.blockedUntil.Sub(now)
}

// Failure records one failed login for ip.
func (l *Limiter) Failure(ip string) {
	l.mu.Lock()
	defer l.mu.Unlock()
	now := l.now()
	e := l.entries[ip]
	if e == nil {
		e = &loginAttempts{}
		l.entries[ip] = e
	}
	e.lastSeen = now
	cutoff := now.Add(-failureWindow)
	kept := e.failures[:0]
	for _, t := range e.failures {
		if t.After(cutoff) {
			kept = append(kept, t)
		}
	}
	e.failures = append(kept, now)
	if len(e.failures) >= maxFailures {
		e.blockedUntil = now.Add(blockDuration)
		e.failures = nil
	}
	l.sweepLocked(now)
}

// Success clears the failure history for ip.
func (l *Limiter) Success(ip string) {
	l.mu.Lock()
	defer l.mu.Unlock()
	delete(l.entries, ip)
}

func (l *Limiter) sweepLocked(now time.Time) {
	if len(l.entries) < 256 {
		return
	}
	for ip, e := range l.entries {
		if now.Sub(e.lastSeen) > limiterMaxIdle && now.After(e.blockedUntil) {
			delete(l.entries, ip)
		}
	}
}
