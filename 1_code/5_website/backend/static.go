package main

import (
	"log"
	"net/http"
	"os"
	"path"
	"path/filepath"
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
	files := http.FileServer(http.Dir(abs))
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
				files.ServeHTTP(w, r)
				return
			}
		}
		// index.html names hashed asset files, so it must never be cached --
		// otherwise a browser keeps loading the previous build's JS after a
		// redeploy. The assets themselves are content-hashed and cached by
		// http.FileServer's own ETag handling.
		w.Header().Set("Cache-Control", "no-cache, no-store, must-revalidate")
		http.ServeFile(w, r, index)
	})
}
