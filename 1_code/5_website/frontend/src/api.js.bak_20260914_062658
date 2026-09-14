// An empty VITE_API_BASE_URL (set in .env.production) means "same origin":
// the deployed build talks to /api/... on whatever host it was served from,
// so the site works over any hostname or IP without a rebuild. Note ?? not
// || -- an empty string is a deliberate value here, not a missing one.
const BASE_URL = import.meta.env.VITE_API_BASE_URL ?? 'http://localhost:8080'

async function getJSON(path, opts = {}) {
  const res = await fetch(`${BASE_URL}${path}`, { credentials: 'include', signal: opts.signal })
  if (!res.ok) {
    const body = await res.json().catch(() => ({}))
    const err = new Error(body.error || `Request failed: ${res.status}`)
    if (body.quota) err.quota = body.quota
    throw err
  }
  return res.json()
}

async function postJSON(path, payload, opts = {}) {
  const res = await fetch(`${BASE_URL}${path}`, {
    method: 'POST',
    credentials: 'include',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(payload),
    signal: opts.signal,
  })
  if (!res.ok) {
    const body = await res.json().catch(() => ({}))
    throw new Error(body.error || `Request failed: ${res.status}`)
  }
  return res.json()
}

// Returns { results, total, page, page_size }. opts.signal is passed through
// for request cancellation; opts.page / opts.pageSize select a page (default
// page 1, page_size 20 -- same defaults as the backend).
export function searchNodes(q, label = '', opts = {}) {
  const params = new URLSearchParams({ q })
  if (label) params.set('label', label)
  if (opts.page) params.set('page', String(opts.page))
  if (opts.pageSize) params.set('page_size', String(opts.pageSize))
  return getJSON(`/api/search?${params.toString()}`, opts)
}

export function getNode(label, id) {
  return getJSON(`/api/node/${encodeURIComponent(label)}/${encodeURIComponent(id)}`)
}

export function apiSignUp(payload) {
  return postJSON('/api/auth/signup', payload)
}

export function apiLogIn(payload) {
  return postJSON('/api/auth/login', payload)
}

export function apiLogOut() {
  return postJSON('/api/auth/logout', {})
}

export function apiDeleteAccount(payload) {
  return postJSON('/api/auth/delete-account', payload)
}

export function apiUpdateProfile(payload) {
  return postJSON('/api/auth/update-profile', payload)
}

export function apiUpdateEmail(payload) {
  return postJSON('/api/auth/update-email', payload)
}

export function apiChangePassword(payload) {
  return postJSON('/api/auth/change-password', payload)
}

export function fetchCurrentUser() {
  return getJSON('/api/auth/me')
}

export function resendVerification(email) {
  return postJSON('/api/auth/resend-verification', { email })
}

export function forgotPassword(email) {
  return postJSON('/api/auth/forgot-password', { email })
}

export function resetPassword(token, password) {
  return postJSON('/api/auth/reset-password', { token, password })
}

export function getStats() {
  return getJSON('/api/stats')
}

// Returns { nodes, edges }: a real weighted-random sample of Study/
// Phenotype/Module/Metabolite nodes and the real MEMBER_OF/REPORTED_IN/
// INVESTIGATED/SIMILAR_TO edges among exactly those sampled nodes -- not
// the complete graph (see overviewSampleSize in backend/graph_overview.go
// for why). The sample is drawn once and cached server-side for the
// backend process's lifetime, not re-rolled on a timer -- restart the
// backend to get a new draw. Backs the homepage's 3D knowledge graph panel.
export function getGraphOverview() {
  return getJSON('/api/graph/overview')
}

export function getChatQuota() {
  return getJSON('/api/chat/quota')
}

export function downloadUrl(filename) {
  return `${BASE_URL}/api/download/${encodeURIComponent(filename)}`
}

// downloadAllUrl() returns a zip of every downloadable CSV; pass an array
// of filenames to get a zip containing only those (used by the Download
// page's per-table checkboxes).
export function downloadAllUrl(files) {
  if (files && files.length) {
    return `${BASE_URL}/api/download-all?files=${encodeURIComponent(files.join(','))}`
  }
  return `${BASE_URL}/api/download-all`
}

export function runEnrichment(payload) {
  return postJSON('/api/enrichment', payload)
}

// Submits the Contact page's "Send a Message" form; the backend relays it
// by email to the PhenoMAP inbox with Reply-To set to the submitter.
export function submitContact(payload) {
  return postJSON('/api/contact', payload)
}

// Lists the signed-in user's Community page study-data submissions, most
// recent first. Each entry includes its attached files (see
// backend/community.go for the shape). 401s if not signed in.
export function listCommunitySubmissions() {
  return getJSON('/api/community/submissions')
}

// Submits the Community page's "New submission" form. formData is a
// browser FormData built by the caller with the text fields (title,
// phenotype, phenotype_id, study_design, sample_size, biospecimen,
// ms2_supported, chromatography, mass_spectrometry, summary, doi,
// source_link, contact_name, contact_email, notes) and up to three files
// under keys feature_table / sample_metadata / metabolite_annotation
// (feature_table and sample_metadata are required). Returns the created
// submission. Deliberately bypasses postJSON -- multipart/form-data needs
// the browser to set its own Content-Type boundary, not
// 'application/json'.
export async function submitCommunityStudy(formData) {
  const res = await fetch(`${BASE_URL}/api/community/submissions`, {
    method: 'POST',
    credentials: 'include',
    body: formData,
  })
  if (!res.ok) {
    const body = await res.json().catch(() => ({}))
    throw new Error(body.error || `Request failed: ${res.status}`)
  }
  return res.json()
}

// Sends one turn and streams its progress rather than waiting silently for
// the whole thing. The backend now runs a 3-stage pipeline per turn
// (relevance check, intent classification, execution) and streams
// newline-delimited JSON: zero or more {type:"status", text} progress lines
// while it works, zero or more {type:"token", text} pieces of the final
// answer as the model actually generates them (openai/siliconflow only --
// official_qwen's manual JSON-planning mode has no token events and jumps
// straight from status lines to the terminal line, since its final answer
// only ever arrives already wrapped in a JSON string, not as it's produced),
// followed by exactly one terminal line, either {type:"final", reply,
// citations, tool_calls, provider, tool_mode, ...} or {type:"error",
// message}. opts.onEvent(event), if given, is called for every status/token
// event as it arrives -- this is what lets the UI show short "thinking"
// hints and, where available, a real typing effect instead of a static
// spinner. The returned promise resolves with the final event's payload
// (the authoritative, fully-processed text -- e.g. with any citation
// backstop applied -- so the caller should treat it as the source of truth
// once it arrives, not just the concatenation of token events), or rejects
// with an Error (message from the error event, or the usual fetch/HTTP
// failure) -- `history` and opts.signal work exactly as before (resend
// prior turns since there's no server-side memory yet; abort an in-flight
// turn for the "stop generating" button).
export async function postChat(message, history = [], llm = {}, opts = {}) {
  const res = await fetch(`${BASE_URL}/api/chat`, {
    method: 'POST',
    credentials: 'include',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ message, history, llm }),
    signal: opts.signal,
  })

  if (!res.ok) {
    // Some failures (quota exceeded, bad request, not signed in) are still
    // a single non-streamed JSON error response returned before any
    // pipeline stage runs -- handled exactly like the old blocking postJSON
    // did.
    const body = await res.json().catch(() => ({}))
    const err = new Error(body.error || `Request failed: ${res.status}`)
    if (body.quota) err.quota = body.quota
    throw err
  }

  if (!res.body) {
    // Fallback if a streaming body isn't available for some reason -- fail
    // safely rather than hang forever waiting for events that can't arrive.
    return res.json()
  }

  const reader = res.body.getReader()
  const decoder = new TextDecoder()
  let buffer = ''

  const handleLine = (line) => {
    const trimmed = line.trim()
    if (!trimmed) return undefined
    const event = JSON.parse(trimmed)
    if (localStorage.getItem('phenomap_chat_debug') === '1') {
      console.log('[PhenoMAP chat stream]', {
        type: event.type,
        seq: event.seq,
        serverTime: event.server_time,
        proxyTime: event.proxy_time,
        clientTime: performance.now(),
        textLength: event.text?.length || 0,
      })
    }
    if (event.type === 'status' || event.type === 'token') {
      opts.onEvent?.(event)
      return undefined
    }
    if (event.type === 'final') return event
    if (event.type === 'error') {
      const err = new Error(event.message || 'chat agent failed')
      if (event.quota) err.quota = event.quota
      throw err
    }
    return undefined
  }

  while (true) {
    const { done, value } = await reader.read()
    if (done) break
    buffer += decoder.decode(value, { stream: true })
    let newlineIndex
    while ((newlineIndex = buffer.indexOf('\n')) !== -1) {
      const line = buffer.slice(0, newlineIndex)
      buffer = buffer.slice(newlineIndex + 1)
      const result = handleLine(line)
      if (result) return result
    }
  }
  // Anything left in the buffer once the stream closes without a trailing
  // newline (should not normally happen -- the backend always terminates
  // each line -- but handle it rather than silently dropping a final line).
  if (buffer.trim()) {
    const result = handleLine(buffer)
    if (result) return result
  }
  throw new Error('chat stream ended unexpectedly without a final response')
}

// Returns a PathGraph: { nodes, edges, hops, truncated } -- the full
// connection subgraph between the two nodes (every node/edge that could sit
// on some walk of length <= maxHops between them), not a ranked list of
// individual paths. See backend/path.go for why.
export function findPathGraph(from, to, maxHops = 5) {
  const params = new URLSearchParams({
    from_label: from.label,
    from_id: from.id,
    to_label: to.label,
    to_id: to.id,
    max_hops: String(maxHops),
  })
  return getJSON(`/api/path?${params.toString()}`)
}
