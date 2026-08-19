package main

import (
	"context"
	"log"
	"net/http"
	"time"
)

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

	enrichClient := NewEnrichmentClient()
	chatClient := NewChatClient()
	initDownloadableFiles()

	authDB, err := NewAuthDB()
	if err != nil {
		log.Fatalf("failed to open auth db: %v", err)
	}
	defer authDB.Close()
	emailCfg := loadEmailConfig()

	mux := http.NewServeMux()
	mux.HandleFunc("GET /api/health", handleHealth)
	mux.HandleFunc("GET /api/stats", handleStats(db))
	mux.HandleFunc("GET /api/graph/overview", handleGraphOverview(db))
	mux.HandleFunc("GET /api/search", handleSearch(db))
	mux.HandleFunc("GET /api/path", handlePath(db))
	mux.HandleFunc("POST /api/enrichment", handleEnrichment(enrichClient))
	mux.HandleFunc("GET /api/chat/quota", handleChatQuota(authDB))
	mux.HandleFunc("POST /api/chat", handleChat(chatClient, authDB))
	mux.HandleFunc("POST /api/contact", handleContact(emailCfg))
	mux.HandleFunc("GET /api/download-all", handleDownloadAll)
	mux.HandleFunc("GET /api/download/{filename}", handleDownload)
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
	mux.HandleFunc("GET /api/node/{label}/{id}", handleNodeDetail(db))

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
