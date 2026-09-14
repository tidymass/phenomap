package main

import (
	"log"
	"mime"
	"net/http"
	"os"
	"path"
	"path/filepath"
	"strconv"
	"strings"
)

// newSPAHandler serves the built Vue frontend (frontend/dist) directly from
// this process, so a deployment needs one port and one origin instead of a
// separate static file server plus CORS. Returns nil when FRONTEND_DIST_DIR
// is unset or doesn't contain an index.html -- that's the local dev setup,
// where Vite serves the frontend on :5173 and nothing here changes.
//
// vue-router runs in createWebHistory mode, so a reload of /node/Module/xxx
// or /chat arrives here as a real HTTP path that has no file behind it. Any
// path that isn't an existing file falls back to index.html and lets the
// router sort it out client-side.
func newSPAHandler(dir string) http.Handler {
	if dir == "" {
		return nil
	}
	abs, err := filepath.Abs(dir)
	if err != nil {
		log.Printf("warning: FRONTEND_DIST_DIR %q is not a usable path: %v", dir, err)
		return nil
	}
	index := filepath.Join(abs, "index.html")
	if _, err := os.Stat(index); err != nil {
		log.Printf("warning: no index.html under FRONTEND_DIST_DIR %q -- not serving a frontend", abs)
		return nil
	}
	log.Printf("serving frontend from %s", abs)

	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// An /api/ path that reached the fallback matched no route above
		// (wrong method, or a typo'd endpoint). It must stay a 404: quietly
		// answering it with 200 + index.html would hand the frontend a page
		// of HTML where it expects JSON.
		if strings.HasPrefix(r.URL.Path, "/api/") {
			http.NotFound(w, r)
			return
		}
		// path.Clean on a rooted path collapses any "..", so a request for
		// /../../etc/passwd can't escape the dist directory.
		upath := path.Clean("/" + r.URL.Path)
		if upath != "/" {
			onDisk := filepath.Join(abs, filepath.FromSlash(upath[1:]))
			if st, err := os.Stat(onDisk); err == nil && !st.IsDir() {
				serveStaticFile(w, r, onDisk, upath)
				return
			}
		}
		// index.html names hashed asset files, so it must never be cached --
		// otherwise a browser keeps loading the previous build's JS after a
		// redeploy. The assets themselves are content-hashed and get long
		// cache lifetimes in serveStaticFile.
		w.Header().Set("Cache-Control", "no-cache, no-store, must-revalidate")
		serveStaticFile(w, r, index, "/index.html")
	})
}

func serveStaticFile(w http.ResponseWriter, r *http.Request, filePath, requestPath string) {
	if cacheControl := cacheControlForStaticPath(requestPath); cacheControl != "" {
		w.Header().Set("Cache-Control", cacheControl)
	}
	if !isCompressibleStaticPath(requestPath) || (r.Method != http.MethodGet && r.Method != http.MethodHead) {
		http.ServeFile(w, r, filePath)
		return
	}

	w.Header().Add("Vary", "Accept-Encoding")
	if clientAcceptsEncoding(r, "br") && serveEncodedStaticFile(w, r, filePath+".br", requestPath, "br") {
		return
	}
	if clientAcceptsEncoding(r, "gzip") && serveEncodedStaticFile(w, r, filePath+".gz", requestPath, "gzip") {
		return
	}
	http.ServeFile(w, r, filePath)
}

func serveEncodedStaticFile(w http.ResponseWriter, r *http.Request, encodedPath, originalPath, encoding string) bool {
	f, err := os.Open(encodedPath)
	if err != nil {
		return false
	}
	defer f.Close()

	st, err := f.Stat()
	if err != nil || st.IsDir() {
		return false
	}

	if contentType := mime.TypeByExtension(filepath.Ext(originalPath)); contentType != "" {
		w.Header().Set("Content-Type", contentType)
	}
	w.Header().Set("Content-Encoding", encoding)
	w.Header().Set("X-Content-Type-Options", "nosniff")
	http.ServeContent(w, r, path.Base(originalPath), st.ModTime(), f)
	return true
}

func cacheControlForStaticPath(requestPath string) string {
	if strings.HasPrefix(requestPath, "/assets/") {
		return "public, max-age=31536000, immutable"
	}
	return ""
}

func isCompressibleStaticPath(requestPath string) bool {
	switch strings.ToLower(filepath.Ext(requestPath)) {
	case ".css", ".html", ".js", ".json", ".map", ".svg", ".txt", ".wasm", ".xml":
		return true
	default:
		return false
	}
}

func clientAcceptsEncoding(r *http.Request, encoding string) bool {
	for _, rawPart := range strings.Split(r.Header.Get("Accept-Encoding"), ",") {
		part := strings.TrimSpace(rawPart)
		if part == "" {
			continue
		}
		pieces := strings.Split(part, ";")
		if !strings.EqualFold(strings.TrimSpace(pieces[0]), encoding) {
			continue
		}
		for _, rawParam := range pieces[1:] {
			param := strings.TrimSpace(rawParam)
			if !strings.HasPrefix(param, "q=") {
				continue
			}
			q, err := strconv.ParseFloat(strings.TrimSpace(strings.TrimPrefix(param, "q=")), 64)
			if err == nil && q <= 0 {
				return false
			}
		}
		return true
	}
	return false
}
