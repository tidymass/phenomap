package main

import (
	"context"
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"strconv"
	"strings"
	"time"
)

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if err := json.NewEncoder(w).Encode(v); err != nil {
		log.Printf("write json: %v", err)
	}
}

func writeError(w http.ResponseWriter, status int, message string) {
	writeJSON(w, status, map[string]string{"error": message})
}

func handleHealth(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

// GET /api/stats
func handleStats(db *DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		ctx, cancel := context.WithTimeout(r.Context(), 8*time.Second)
		defer cancel()

		stats, err := db.Stats(ctx)
		if err != nil {
			log.Printf("stats error: %v", err)
			writeError(w, http.StatusInternalServerError, "failed to load stats")
			return
		}
		writeJSON(w, http.StatusOK, stats)
	}
}

// GET /api/search?q=...&label=Module&page=1&page_size=20
//
// An empty q with a label falls back to "browse" mode: every node of that
// label, sorted by Lab_ID, paginated -- this is what backs the Entity Search
// page's default view (before the user has typed anything).
func handleSearch(db *DB) http.HandlerFunc {
	const defaultPageSize = 20
	const maxPageSize = 100

	return func(w http.ResponseWriter, r *http.Request) {
		q := strings.TrimSpace(r.URL.Query().Get("q"))
		label := r.URL.Query().Get("label")
		pageSize := defaultPageSize
		if v := r.URL.Query().Get("page_size"); v != "" {
			if parsed, err := strconv.Atoi(v); err == nil && parsed > 0 && parsed <= maxPageSize {
				pageSize = parsed
			}
		}
		page := 1
		if v := r.URL.Query().Get("page"); v != "" {
			if parsed, err := strconv.Atoi(v); err == nil && parsed > 0 {
				page = parsed
			}
		}
		offset := (page - 1) * pageSize

		ctx, cancel := context.WithTimeout(r.Context(), 8*time.Second)
		defer cancel()

		var results []SearchResult
		var total int
		var err error

		switch {
		case q == "" && label != "":
			results, total, err = db.Browse(ctx, label, offset, pageSize)
		case len(q) < 2:
			// Too short to search, and no label given to browse instead.
			writeJSON(w, http.StatusOK, SearchResponse{Results: []SearchResult{}, Total: 0, Page: page, PageSize: pageSize})
			return
		default:
			results, total, err = db.Search(ctx, q, label, offset, pageSize)
		}
		if err != nil {
			log.Printf("search error: %v", err)
			writeError(w, http.StatusInternalServerError, "search failed")
			return
		}
		writeJSON(w, http.StatusOK, SearchResponse{Results: results, Total: total, Page: page, PageSize: pageSize})
	}
}

// POST /api/enrichment
func handleEnrichment(client *EnrichmentClient) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		var req EnrichmentRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeError(w, http.StatusBadRequest, "invalid request body")
			return
		}
		if len(req.IDs) == 0 {
			writeError(w, http.StatusBadRequest, "ids must not be empty")
			return
		}
		if req.IDType == "" {
			req.IDType = "hmdb"
		}
		if req.Method == "" {
			req.Method = "fisher"
		}
		if req.FDRCutoff == 0 {
			req.FDRCutoff = 0.05
		}
		if req.MinOverlap == 0 {
			req.MinOverlap = 2
		}

		ctx, cancel := context.WithTimeout(r.Context(), 30*time.Second)
		defer cancel()

		result, err := client.Run(ctx, req)
		if err != nil {
			log.Printf("enrichment error: %v", err)
			writeError(w, http.StatusBadGateway, "enrichment service failed: "+err.Error())
			return
		}

		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write(result)
	}
}

// GET /api/chat/quota
func handleChatQuota(authDB *AuthDB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
		defer cancel()

		quota, err := authDB.OfficialChatQuota(ctx, sessionTokenFromRequest(r))
		if err != nil {
			if errors.Is(err, ErrNotFound) {
				writeError(w, http.StatusUnauthorized, "not signed in")
				return
			}
			log.Printf("chat quota error: %v", err)
			writeError(w, http.StatusInternalServerError, "failed to load chat quota")
			return
		}
		writeJSON(w, http.StatusOK, quota)
	}
}

// POST /api/chat
func handleChat(client *ChatClient, authDB *AuthDB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		var req ChatRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeError(w, http.StatusBadRequest, "invalid request body")
			return
		}
		if strings.TrimSpace(req.Message) == "" {
			writeError(w, http.StatusBadRequest, "message must not be empty")
			return
		}

		// LLM tool-calling loops are slower than a single DB query or even
		// the enrichment call -- give this the longest timeout of any
		// handler in this file.
		ctx, cancel := context.WithTimeout(r.Context(), 70*time.Second)
		defer cancel()

		var quota *ChatQuota
		provider := strings.ToLower(strings.TrimSpace(req.LLM.Provider))
		if provider == "" || provider == "official_qwen" {
			q, allowed, err := authDB.ConsumeOfficialChatQuota(ctx, sessionTokenFromRequest(r))
			if err != nil {
				if errors.Is(err, ErrNotFound) {
					writeError(w, http.StatusUnauthorized, "not signed in")
					return
				}
				log.Printf("consume chat quota error: %v", err)
				writeError(w, http.StatusInternalServerError, "failed to check chat quota")
				return
			}
			quota = &q
			if !allowed {
				writeJSON(w, http.StatusTooManyRequests, map[string]any{
					"error": "official free daily quota used up",
					"quota": q,
				})
				return
			}
		}

		result, err := client.Run(ctx, req)
		if err != nil {
			log.Printf("chat error: %v", err)
			writeError(w, http.StatusBadGateway, "chat service failed: "+err.Error())
			return
		}

		if quota != nil {
			var payload map[string]any
			if err := json.Unmarshal(result, &payload); err == nil {
				payload["quota"] = *quota
				writeJSON(w, http.StatusOK, payload)
				return
			}
		}

		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write(result)
	}
}

type contactRequest struct {
	Name    string `json:"name"`
	Email   string `json:"email"`
	Message string `json:"message"`
}

// POST /api/contact -- relays the Contact page's "Send a Message" form to
// contactRecipient via email.
func handleContact(emailCfg EmailConfig) http.HandlerFunc {
	const maxMessageLen = 4000

	return func(w http.ResponseWriter, r *http.Request) {
		var req contactRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeError(w, http.StatusBadRequest, "invalid request body")
			return
		}
		req.Name = strings.TrimSpace(req.Name)
		req.Email = strings.TrimSpace(req.Email)
		req.Message = strings.TrimSpace(req.Message)

		if req.Name == "" {
			writeError(w, http.StatusBadRequest, "name is required")
			return
		}
		if req.Email == "" || !strings.Contains(req.Email, "@") {
			writeError(w, http.StatusBadRequest, "a valid email is required")
			return
		}
		if req.Message == "" {
			writeError(w, http.StatusBadRequest, "message is required")
			return
		}
		if len(req.Message) > maxMessageLen {
			writeError(w, http.StatusBadRequest, "message is too long")
			return
		}

		if err := emailCfg.sendContactMessage(req.Name, req.Email, req.Message); err != nil {
			log.Printf("contact form send error: %v", err)
			writeError(w, http.StatusInternalServerError, "failed to send message")
			return
		}
		writeJSON(w, http.StatusOK, map[string]bool{"sent": true})
	}
}

// GET /api/path?from_label=X&from_id=Y&to_label=A&to_id=B&max_hops=5
func handlePath(db *DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		q := r.URL.Query()
		fromLabel := q.Get("from_label")
		fromID := q.Get("from_id")
		toLabel := q.Get("to_label")
		toID := q.Get("to_id")
		if fromLabel == "" || fromID == "" || toLabel == "" || toID == "" {
			writeError(w, http.StatusBadRequest, "from_label, from_id, to_label, to_id are required")
			return
		}

		maxHops := defaultPathHops
		if v := q.Get("max_hops"); v != "" {
			if parsed, err := strconv.Atoi(v); err == nil {
				maxHops = parsed
			}
		}

		// Path finding is heavier than a single-node lookup, so this gets
		// a longer timeout than the other handlers.
		ctx, cancel := context.WithTimeout(r.Context(), 20*time.Second)
		defer cancel()

		graph, err := db.FindPathGraph(ctx, fromLabel, fromID, toLabel, toID, maxHops)
		if err != nil {
			log.Printf("path error: %v", err)
			writeError(w, http.StatusInternalServerError, "path query failed")
			return
		}
		writeJSON(w, http.StatusOK, graph)
	}
}

// GET /api/node/{label}/{id}
func handleNodeDetail(db *DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		label := r.PathValue("label")
		id := r.PathValue("id")
		if label == "" || id == "" {
			writeError(w, http.StatusBadRequest, "label and id are required")
			return
		}

		ctx, cancel := context.WithTimeout(r.Context(), 8*time.Second)
		defer cancel()

		detail, found, err := db.GetNode(ctx, label, id, 300)
		if err != nil {
			log.Printf("node detail error: %v", err)
			writeError(w, http.StatusInternalServerError, "failed to load node")
			return
		}
		if !found {
			writeError(w, http.StatusNotFound, "node not found")
			return
		}
		writeJSON(w, http.StatusOK, detail)
	}
}
