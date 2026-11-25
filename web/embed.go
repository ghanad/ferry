// Package webassets embeds Ferry's HTML templates and static files.
package webassets

import "embed"

// FS contains templates/*.html and static/*.
//
//go:embed templates/*.html static/*
var FS embed.FS
