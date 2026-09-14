"""PhenoMAP Chat service (Python / FastAPI).

Thin HTTP wrapper around the tool-calling agent in agent.py. Same role in
the architecture as ../enrichment-service/plumber.R: the Go backend proxies
POST /api/chat to this service's POST /chat and passes the response straight
through (see ../backend/chat.go).

Run (from this directory):
    pip install -r requirements.txt
    cp .env.example .env   # fill in LLM_API_KEY
    uvicorn main:app --port 8788

See README.md for details.
"""

import json
import logging
import asyncio
import time
from typing import List, Optional

from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import StreamingResponse
from pydantic import BaseModel

from agent import LLMConfigError, run_chat_stream
from config import PORT

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("phenomap-chat")

app = FastAPI(title="PhenoMAP Chat Service")

# Permissive CORS for convenience when testing this service directly (e.g.
# with curl or a local script). In normal operation the browser never calls
# this service directly -- it goes through the Go backend at /api/chat,
# which has its own, tighter CORS policy (see ../backend/cors.go).
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)


class HistoryTurn(BaseModel):
    role: str
    content: str
    pending_resolution: Optional[dict] = None


class ChatRequest(BaseModel):
    message: str
    history: Optional[List[HistoryTurn]] = None
    llm: Optional[dict] = None


@app.get("/health")
def health():
    return {"status": "ok"}


@app.post("/chat")
async def chat(req: ChatRequest):
    """Streams one turn as newline-delimited JSON (NDJSON): zero or more
    {"type": "status", "text": ...} progress lines while the pipeline works
    (relevance check, intent classification, each tool call), followed by
    exactly one terminal line, either {"type": "final", ...} (same shape the
    old single-shot response used to be, just wrapped) or
    {"type": "error", "message": ...}.

    This used to be a single blocking JSON response built by awaiting
    run_chat() outright. It's a stream now specifically so the frontend can
    show short "thinking" hints (searching PhenoMAP for X..., checking the
    connection..., ...) instead of a static spinner -- see backend/chat.go
    and backend/handlers.go for how the Go layer proxies this through, and
    frontend/src/views/ChatView.vue for how it's displayed.

    Because the response has already started (HTTP 200, headers sent) by the
    time any pipeline stage could fail, errors are reported as a final
    {"type": "error", ...} line rather than an HTTP error status -- there is
    no way to change the status code after streaming has begun. The one
    exception is a bad request (empty message), which is rejected before the
    stream starts and can still be a normal 400.
    """
    message = (req.message or "").strip()
    if not message:
        raise HTTPException(status_code=400, detail="message must not be empty")

    history = [h.model_dump() for h in (req.history or [])]

    async def line_stream():
        token_seq = 0

        async def emit(event: dict):
            # Tiny NDJSON chunks can be coalesced by ASGI/HTTP/TCP layers
            # before the Go proxy sees them, which makes "streaming" look
            # like a burst. A small ignored padding field on token events
            # keeps each chunk large enough to flush promptly through those
            # layers without changing the frontend contract.
            if event.get("type") == "token":
                event = {**event, "_pad": " " * 1024}
            chunk = (json.dumps(event, ensure_ascii=False) + "\n").encode("utf-8")
            return chunk

        try:
            async for event in run_chat_stream(message, history, req.llm or {}):
                if event.get("type") == "token":
                    token_seq += 1
                    event = {**event, "seq": token_seq, "server_time": time.time()}
                yield await emit(event)
                await asyncio.sleep(0.001)
        except LLMConfigError as e:
            yield await emit({"type": "error", "message": str(e)})
        except Exception as e:  # noqa: BLE001 -- last-resort so the stream always ends with a terminal line
            logger.exception("chat turn failed")
            yield await emit({"type": "error", "message": f"chat agent failed: {e}"})

    return StreamingResponse(
        line_stream(),
        media_type="application/x-ndjson",
        headers={
            "Cache-Control": "no-cache",
            "X-Accel-Buffering": "no",
        },
    )


if __name__ == "__main__":
    import uvicorn

    uvicorn.run("main:app", host="0.0.0.0", port=PORT)
