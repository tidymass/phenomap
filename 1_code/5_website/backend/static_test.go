package main

import (
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestSPAHandlerServesPrecompressedAssets(t *testing.T) {
	dist := t.TempDir()
	assetDir := filepath.Join(dist, "assets")
	if err := os.Mkdir(assetDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dist, "index.html"), []byte("<div id=\"app\"></div>"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(assetDir, "app.js"), []byte("console.log('plain')"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(assetDir, "app.js.gz"), []byte("gzip-bytes"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(assetDir, "app.js.br"), []byte("br-bytes"), 0o644); err != nil {
		t.Fatal(err)
	}

	handler := newSPAHandler(dist)
	req := httptest.NewRequest(http.MethodGet, "/assets/app.js", nil)
	req.Header.Set("Accept-Encoding", "gzip, br")
	rec := httptest.NewRecorder()

	handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", rec.Code)
	}
	if got := rec.Header().Get("Content-Encoding"); got != "br" {
		t.Fatalf("Content-Encoding = %q, want br", got)
	}
	if got := rec.Body.String(); got != "br-bytes" {
		t.Fatalf("body = %q, want br-bytes", got)
	}
	if got := rec.Header().Get("Cache-Control"); got != "public, max-age=31536000, immutable" {
		t.Fatalf("Cache-Control = %q, want immutable asset cache", got)
	}
	if got := rec.Header().Values("Vary"); !containsHeaderValue(got, "Accept-Encoding") {
		t.Fatalf("Vary = %v, want Accept-Encoding", got)
	}
	if got := rec.Header().Get("Content-Type"); !strings.Contains(got, "javascript") {
		t.Fatalf("Content-Type = %q, want javascript", got)
	}
}

func TestSPAHandlerServesGzipWhenBrotliUnavailable(t *testing.T) {
	dist := t.TempDir()
	assetDir := filepath.Join(dist, "assets")
	if err := os.Mkdir(assetDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dist, "index.html"), []byte("<div id=\"app\"></div>"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(assetDir, "app.css"), []byte("body{}"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(assetDir, "app.css.gz"), []byte("gzip-css"), 0o644); err != nil {
		t.Fatal(err)
	}

	handler := newSPAHandler(dist)
	req := httptest.NewRequest(http.MethodGet, "/assets/app.css", nil)
	req.Header.Set("Accept-Encoding", "br;q=0, gzip")
	rec := httptest.NewRecorder()

	handler.ServeHTTP(rec, req)

	if got := rec.Header().Get("Content-Encoding"); got != "gzip" {
		t.Fatalf("Content-Encoding = %q, want gzip", got)
	}
	if got := rec.Body.String(); got != "gzip-css" {
		t.Fatalf("body = %q, want gzip-css", got)
	}
}

func TestSPAHandlerKeepsIndexNoCache(t *testing.T) {
	dist := t.TempDir()
	if err := os.WriteFile(filepath.Join(dist, "index.html"), []byte("<div id=\"app\"></div>"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dist, "index.html.br"), []byte("br-index"), 0o644); err != nil {
		t.Fatal(err)
	}

	handler := newSPAHandler(dist)
	req := httptest.NewRequest(http.MethodGet, "/community", nil)
	req.Header.Set("Accept-Encoding", "br")
	rec := httptest.NewRecorder()

	handler.ServeHTTP(rec, req)

	if got := rec.Header().Get("Content-Encoding"); got != "br" {
		t.Fatalf("Content-Encoding = %q, want br", got)
	}
	if got := rec.Body.String(); got != "br-index" {
		t.Fatalf("body = %q, want br-index", got)
	}
	if got := rec.Header().Get("Cache-Control"); got != "no-cache, no-store, must-revalidate" {
		t.Fatalf("Cache-Control = %q, want no-cache index", got)
	}
}

func containsHeaderValue(values []string, want string) bool {
	for _, value := range values {
		for _, part := range strings.Split(value, ",") {
			if strings.EqualFold(strings.TrimSpace(part), want) {
				return true
			}
		}
	}
	return false
}
