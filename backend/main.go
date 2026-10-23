package main

import (
	"context"
	"log"
	"net/http"
	"strings"
	"time"
)

// authEnabled reports whether accounts (sign up / sign in / account page)
// and the account-linked Community submissions are turned on. Controlled
// by AUTH_ENABLED: the public deployment keeps it on (the default, so an
// unset variable never silently opens anything up), the lab-internal
// deployment sets AUTH_ENABLED=false so everyone can use the site without
// an account. The frontend asks GET /api/config at startup and hides the
// matching pages and links.
func authEnabled() bool {
	switch strings.ToLower(strings.TrimSpace(getenv("AUTH_ENABLED", "true"))) {
	case "false", "0", "no", "off":
		return false
	}
	return true
}

func main() {
	ctx := context.Background()

	db, err := NewDB(ctx)
	if err != nil {
		log.Fatalf("failed to connect to neo4j: %v", err)
	}
	defer db.Close(ctx)

	if err := db.EnsureSearchIndexes(ctx); err != nil {
		// Don't fail startup over this -- search.go falls back to ID-only
		// matching per label if a fulltext index is missing.
		log.Printf("warning: failed to ensure search indexes: %v", err)
	}

	// The homepage asks for /api/stats on first paint, so pay for it here
	// rather than making the first visitor after a restart wait for it.
	// Best-effort: Stats() just computes on demand if this fails.
	go func() {
		if err := db.WarmStats(context.Background()); err != nil {
			log.Printf("warning: failed to warm graph stats cache: %v", err)
		}
	}()

	enrichClient := NewEnrichmentClient()
	chatClient := NewChatClient()
	initDownloadableFiles()

	withAuth := authEnabled()
	emailCfg := loadEmailConfig()

	mux := http.NewServeMux()
	mux.HandleFunc("GET /api/health", handleHealth)
	mux.HandleFunc("GET /api/config", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, http.StatusOK, map[string]bool{"auth_enabled": withAuth})
	})
	mux.HandleFunc("GET /api/stats", handleStats(db))
	mux.HandleFunc("GET /api/graph/overview", handleGraphOverview(db))
	mux.HandleFunc("GET /api/search", handleSearch(db))
	mux.HandleFunc("GET /api/path", handlePath(db))
	mux.HandleFunc("POST /api/enrichment", handleEnrichment(enrichClient))
	mux.HandleFunc("GET /api/enrichment/meta", handleEnrichmentMeta(enrichClient))
	mux.HandleFunc("POST /api/chat", handleChat(chatClient))
	mux.HandleFunc("POST /api/contact", handleContact(emailCfg))
	mux.HandleFunc("GET /api/download-all", handleDownloadAll)
	mux.HandleFunc("GET /api/download/{filename}", handleDownload)
	// Accounts and Community submissions only exist when auth is on; with
	// AUTH_ENABLED=false their routes aren't registered at all (so they 404)
	// and the auth database is never opened or created.
	if withAuth {
		authDB, err := NewAuthDB()
		if err != nil {
			log.Fatalf("failed to open auth db: %v", err)
		}
		defer authDB.Close()
		registerAuthRoutes(mux, authDB, emailCfg)
	} else {
		log.Printf("AUTH_ENABLED=false: accounts and Community submissions are disabled")
	}
	mux.HandleFunc("GET /api/node/{label}/{id}", handleNodeDetail(db))

	// Deployed as a single service, the backend also serves the built
	// frontend; in local dev FRONTEND_DIST_DIR is unset and this is a no-op.
	if spa := newSPAHandler(getenv("FRONTEND_DIST_DIR", "")); spa != nil {
		mux.Handle("/", spa)
	}

	addr := ":" + getenv("PORT", "8080")
	srv := &http.Server{
		Addr:        addr,
		Handler:     withCORS(mux),
		ReadTimeout: 10 * time.Second,
		// WriteTimeout bounds the whole handler, not just time spent
		// physically writing bytes -- for a streaming handler like
		// handleChat (see handlers.go), that's the entire 3-stage pipeline
		// (relevance check + intent classification + execution's own
		// tool-calling loop against Neo4j and the LLM), which can easily
		// run well past what used to be a comfortable margin for this
		// server's other, single-query endpoints. 15s was already tight for
		// chat's old single-loop design and is routinely exceeded by the
		// new pipeline; raised well above ChatClient's own 90s budget (see
		// chat.go) so the server doesn't kill the connection out from under
		// a request handleChat's own timeout would otherwise have let run.
		WriteTimeout: 120 * time.Second,
	}

	log.Printf("phenomap-web backend listening on %s (neo4j db=%s)", addr, db.database)
	if err := srv.ListenAndServe(); err != nil {
		log.Fatal(err)
	}
}

// registerAuthRoutes wires up the account and Community submission
// endpoints -- only called when authEnabled() is true.
func registerAuthRoutes(mux *http.ServeMux, authDB *AuthDB, emailCfg EmailConfig) {
	mux.HandleFunc("POST /api/auth/signup", handleSignUp(authDB, emailCfg))
	mux.HandleFunc("POST /api/auth/login", handleLogin(authDB))
	mux.HandleFunc("POST /api/auth/logout", handleLogout(authDB))
	mux.HandleFunc("POST /api/auth/delete-account", handleDeleteAccount(authDB, emailCfg))
	mux.HandleFunc("GET /api/auth/confirm-delete-account", handleConfirmAccountDeletion(authDB))
	mux.HandleFunc("POST /api/auth/update-profile", handleUpdateProfile(authDB))
	mux.HandleFunc("POST /api/auth/update-email", handleUpdateEmail(authDB, emailCfg))
	mux.HandleFunc("GET /api/auth/confirm-email-change", handleConfirmEmailChange(authDB))
	mux.HandleFunc("POST /api/auth/change-password", handleChangePassword(authDB))
	mux.HandleFunc("GET /api/auth/me", handleMe(authDB))
	mux.HandleFunc("GET /api/auth/verify", handleVerifyEmail(authDB))
	mux.HandleFunc("POST /api/auth/resend-verification", handleResendVerification(authDB, emailCfg))
	mux.HandleFunc("POST /api/auth/forgot-password", handleForgotPassword(authDB, emailCfg))
	mux.HandleFunc("POST /api/auth/reset-password", handleResetPassword(authDB))
	mux.HandleFunc("POST /api/community/submissions", handleCreateSubmission(authDB, emailCfg))
	mux.HandleFunc("GET /api/community/submissions", handleListSubmissions(authDB))
	mux.HandleFunc("GET /api/community/submissions/{id}/files/{key}", handleDownloadSubmissionFile(authDB))
}
