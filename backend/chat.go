package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
)

// ChatHistoryTurn/ChatRequest mirror the JSON body the Python chat-service
// expects at POST /chat (see chat-service/main.py).
type ChatHistoryTurn struct {
	Role              string         `json:"role"`
	Content           string         `json:"content"`
	PendingResolution map[string]any `json:"pending_resolution,omitempty"`
}

type ChatRequest struct {
	Message string            `json:"message"`
	History []ChatHistoryTurn `json:"history"`
	LLM     ChatLLMConfig     `json:"llm"`
}

// ChatLLMConfig selects which OpenAI-compatible LLM endpoint the Python
// chat-service should use for this turn (provider "siliconflow", the
// default, or "openai"). The user passes their own key for this request;
// the backend only proxies it and never persists it.
type ChatLLMConfig struct {
	Provider string `json:"provider"`
	APIKey   string `json:"api_key,omitempty"`
	BaseURL  string `json:"base_url,omitempty"`
	Model    string `json:"model,omitempty"`
}

// ChatClient calls the Python chat-service, which runs an LLM tool-calling
// loop over this same backend's /api/search, /api/node, /api/path, and
// /api/enrichment endpoints (see chat-service/tools.py). Like
// EnrichmentClient, the response is passed through as raw JSON rather than
// decoded into Go structs -- {reply, citations, tool_calls} is easiest to
// keep as a single source of truth on the Python side.
type ChatClient struct {
	baseURL string
	http    *http.Client
}

func NewChatClient() *ChatClient {
	return &ChatClient{
		baseURL: getenv("CHAT_SERVICE_URL", "http://127.0.0.1:8788"),
		// A turn now runs a 3-stage pipeline (relevance check, intent
		// classification, then execution's own tool-calling loop) instead of
		// one big loop, which is a couple more sequential LLM round trips
		// than before on top of however many backend calls execution makes
		// -- bumped from 60s to give that extra latency headroom. This is
		// also why /chat streams progressively now (see Stream below)
		// rather than making the caller wait the full budget in silence.
		// No client-wide timeout: it would cut the stream mid-answer with no
		// explanation. handleChat bounds the turn with its own context
		// (chatTurnTimeout) and tells the browser when that limit is hit.
		http: &http.Client{},
	}
}

// Stream sends the chat request and returns the raw HTTP response for the
// caller to read as newline-delimited JSON and close when done, instead of
// buffering the whole body first the way Run used to. This is what lets
// handleChat proxy each pipeline stage's progress line to the browser as it
// arrives, rather than the browser seeing nothing until the entire turn
// (relevance check + intent classification + every tool call) has finished.
func (c *ChatClient) Stream(ctx context.Context, req ChatRequest) (*http.Response, error) {
	body, err := json.Marshal(req)
	if err != nil {
		return nil, fmt.Errorf("encode request: %w", err)
	}

	httpReq, err := http.NewRequestWithContext(ctx, http.MethodPost, c.baseURL+"/chat", bytes.NewReader(body))
	if err != nil {
		return nil, fmt.Errorf("build request: %w", err)
	}
	httpReq.Header.Set("Content-Type", "application/json")

	resp, err := c.http.Do(httpReq)
	if err != nil {
		return nil, fmt.Errorf("call chat service (is it running on %s?): %w", c.baseURL, err)
	}
	if resp.StatusCode >= 400 {
		defer resp.Body.Close()
		respBody, _ := io.ReadAll(resp.Body)
		return nil, fmt.Errorf("chat service returned %d: %s", resp.StatusCode, string(respBody))
	}
	return resp, nil
}
