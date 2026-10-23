package main

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"io"
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

// GET /api/graph/overview
//
// Returns a real sample of the schema graph -- a weighted random sample of
// Study/Phenotype/Module/Metabolite nodes and the real MEMBER_OF/
// REPORTED_IN/INVESTIGATED/SIMILAR_TO edges among exactly those sampled
// nodes (see overviewSampleSize in graph_overview.go for why this is a
// sample, not the complete graph). Backs the homepage's 3D knowledge graph
// panel -- every node and edge it returns is real, just not necessarily
// every one that exists.
func handleGraphOverview(db *DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		ctx, cancel := context.WithTimeout(r.Context(), 20*time.Second)
		defer cancel()

		overview, err := db.GraphOverview(ctx)
		if err != nil {
			log.Printf("graph overview error: %v", err)
			writeError(w, http.StatusInternalServerError, "failed to load graph overview")
			return
		}
		writeJSON(w, http.StatusOK, overview)
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

// GET /api/enrichment/meta
func handleEnrichmentMeta(client *EnrichmentClient) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		ctx, cancel := context.WithTimeout(r.Context(), 10*time.Second)
		defer cancel()

		result, err := client.Meta(ctx)
		if err != nil {
			log.Printf("enrichment meta error: %v", err)
			writeError(w, http.StatusBadGateway, "enrichment service failed: "+err.Error())
			return
		}

		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write(result)
	}
}

// POST /api/chat
//
// Streams the response as newline-delimited JSON (NDJSON): the Python
// chat-service now runs a 3-stage pipeline (relevance check, intent
// classification, execution) and emits one progress line per stage/tool
// call plus exactly one terminal line (see chat-service/main.py). This
// handler proxies each line to the browser as it arrives instead of
// buffering the whole turn the way it used to, which is what lets the
// frontend show short "thinking" hints instead of a static spinner. Each
// status/token/final/error line only gets a proxy timestamp added.
func handleChat(client *ChatClient) http.HandlerFunc {
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
		// handler in this file. Bumped alongside ChatClient's own timeout
		// (see chat.go) now that a turn runs 3 sequential pipeline stages
		// instead of one.
		ctx, cancel := context.WithTimeout(r.Context(), 100*time.Second)
		defer cancel()

		resp, err := client.Stream(ctx, req)
		if err != nil {
			log.Printf("chat error: %v", err)
			writeError(w, http.StatusBadGateway, "chat service failed: "+err.Error())
			return
		}
		defer resp.Body.Close()

		w.Header().Set("Content-Type", "application/x-ndjson")
		w.Header().Set("Cache-Control", "no-cache")
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("X-Accel-Buffering", "no")
		w.WriteHeader(http.StatusOK)
		flusher, canFlush := w.(http.Flusher)

		reader := bufio.NewReaderSize(resp.Body, 1024)
		for {
			line, err := reader.ReadBytes('\n')
			if err != nil && !errors.Is(err, io.EOF) {
				log.Printf("chat stream read error: %v", err)
				return
			}
			line = []byte(strings.TrimRight(string(line), "\r\n"))
			if len(line) == 0 {
				if errors.Is(err, io.EOF) {
					return
				}
				continue
			}
			out := line
			var payload map[string]any
			if err := json.Unmarshal(line, &payload); err == nil {
				if t, _ := payload["type"].(string); t == "status" || t == "token" || t == "final" || t == "error" {
					payload["proxy_time"] = float64(time.Now().UnixNano()) / 1e9
					if reEncoded, err := json.Marshal(payload); err == nil {
						out = reEncoded
					}
				}
			}
			if _, err := w.Write(out); err != nil {
				log.Printf("chat stream write error: %v", err)
				return
			}
			if _, err := w.Write([]byte("\n")); err != nil {
				return
			}
			if canFlush {
				flusher.Flush()
			}
			if errors.Is(err, io.EOF) {
				return
			}
		}
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

// GET /api/path?from_label=X&from_id=Y&to_label=A&to_id=B
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

		// Path finding is heavier than a single-node lookup, so this gets
		// a longer timeout than the other handlers.
		ctx, cancel := context.WithTimeout(r.Context(), 20*time.Second)
		defer cancel()

		graph, err := db.FindPathGraph(ctx, fromLabel, fromID, toLabel, toID)
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
