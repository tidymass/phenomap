package main

import (
	"net/http"
	"strings"
)

// withCORS handles cross-origin API calls.
//
// A deployed PhenoMAP serves the frontend from this same process (see
// static.go), so the browser makes same-origin requests and never sends an
// Origin header on them -- CORS is simply not involved and nothing below
// runs. It still matters in two cases: local development, where Vite serves
// the frontend on :5173 while this API listens on :8080, and any future
// setup that puts the frontend on a different host.
//
// ALLOWED_ORIGINS, when set, is a comma-separated allow-list ("*" means any)
// and requests from anything else get no CORS headers, so the browser blocks
// them. When it's unset any origin is echoed back, which keeps local
// development frictionless -- set it explicitly in a deployment.
func withCORS(next http.Handler) http.Handler {
	var allowed []string
	for _, o := range strings.Split(getenv("ALLOWED_ORIGINS", ""), ",") {
		if o = strings.TrimSpace(o); o != "" {
			allowed = append(allowed, o)
		}
	}

	originOK := func(origin string) bool {
		if len(allowed) == 0 {
			return true
		}
		for _, a := range allowed {
			if a == "*" || strings.EqualFold(a, origin) {
				return true
			}
		}
		return false
	}

	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		origin := r.Header.Get("Origin")
		if origin != "" && originOK(origin) {
			// An explicit origin, not "*": browsers reject a wildcard on
			// credentialed requests, and the session cookie rides on these.
			w.Header().Set("Access-Control-Allow-Origin", origin)
			w.Header().Set("Access-Control-Allow-Credentials", "true")
			w.Header().Set("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
			w.Header().Set("Access-Control-Allow-Headers", "Content-Type")
			w.Header().Set("Vary", "Origin")
		}
		if r.Method == http.MethodOptions {
			w.WriteHeader(http.StatusNoContent)
			return
		}
		next.ServeHTTP(w, r)
	})
}
