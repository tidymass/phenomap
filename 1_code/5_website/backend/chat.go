package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"time"
)

// ChatHistoryTurn/ChatRequest mirror the JSON body the Python chat-service
// expects at POST /chat (see chat-service/main.py).
type ChatHistoryTurn struct {
	Role    string `json:"role"`
	Content string `json:"content"`
}

type ChatRequest struct {
	Message string            `json:"message"`
	History []ChatHistoryTurn `json:"history"`
	LLM     ChatLLMConfig     `json:"llm"`
}

// ChatLLMConfig selects which OpenAI-compatible LLM endpoint the Python
// chat-service should use for this turn. For provider=official_qwen, API
// credentials live only in the chat-service environment. For openai and
// siliconflow, the user can pass a key for this request; the backend only
// proxies it and never persists it.
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
		// A tool-calling turn can involve several LLM round trips plus
		// several backend calls (one of which, enrichment, already has its
		// own 30s budget) -- give this the longest timeout of any client
		// in this package.
		http: &http.Client{Timeout: 60 * time.Second},
	}
}

func (c *ChatClient) Run(ctx context.Context, req ChatRequest) (json.RawMessage, error) {
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
	defer resp.Body.Close()

	respBody, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("read chat response: %w", err)
	}
	if resp.StatusCode >= 400 {
		return nil, fmt.Errorf("chat service returned %d: %s", resp.StatusCode, string(respBody))
	}
	return respBody, nil
}
