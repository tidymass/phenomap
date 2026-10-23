<template>
  <div class="chatbot-page">
    <aside class="chatbot-sidebar">
      <div class="bot-brand">
        <div class="bot-avatar" aria-hidden="true">
          <img src="/chatbot-avatar.png" alt="" @error="hideBrokenImage" />
          <span>AI</span>
        </div>
        <div class="bot-title">
          <strong>PhenoMAP Chat</strong>
          <span>{{ modelLabel }}</span>
        </div>
      </div>

      <button type="button" class="new-chat-btn" @click="newChat">
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.9">
          <path d="M12 5v14M5 12h14" />
        </svg>
        New chat
      </button>

      <section class="chat-history">
        <h2>Chats</h2>
        <div v-if="sessions.length === 0" class="empty-history">No chats yet</div>
        <div
          v-for="session in sessions"
          :key="session.id"
          class="history-row"
          :class="{ active: session.id === activeSessionId }"
        >
          <button type="button" class="history-title" @click="selectSession(session.id)">
            {{ session.title }}
          </button>
          <button type="button" class="history-delete" title="Delete chat" @click="deleteSession(session.id)">
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8">
              <path d="M4 7h16M10 11v6M14 11v6M6 7l1 14h10l1-14M9 7V4h6v3" />
            </svg>
          </button>
        </div>
      </section>

      <div class="account-block">
        <button type="button" class="account-button" @click="modelMenuOpen = !modelMenuOpen">
          <span class="user-avatar">{{ userInitials }}</span>
          <span class="account-text">
            <strong>{{ authState.user?.display_name || (authState.enabled ? 'Account' : 'Settings') }}</strong>
            <small>{{ modelLabel }}</small>
          </span>
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8">
            <path d="m7 10 5 5 5-5" />
          </svg>
        </button>

        <div v-if="modelMenuOpen" class="model-popover">
          <div class="model-popover-header">
            <span>Model settings</span>
            <button type="button" class="model-close" aria-label="Close model settings" @click="modelMenuOpen = false">
              <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                <path d="M6 6l12 12M18 6 6 18" />
              </svg>
            </button>
          </div>

          <div v-for="opt in providerOptions" :key="opt.value" class="model-provider">
            <button
              type="button"
              class="model-option"
              :class="{ active: provider === opt.value }"
              @click="provider = opt.value"
            >
              <span>{{ opt.label }}</span>
              <small>{{ opt.description }}</small>
            </button>

            <div v-if="provider === opt.value" class="provider-fields">
              <input
                v-model="providerDrafts[opt.value].apiKey"
                type="password"
                :placeholder="opt.value === 'openai' ? 'OpenAI API key' : 'SiliconFlow API key'"
              />
              <div class="model-input-row">
                <input
                  v-model="providerDrafts[opt.value].model"
                  type="text"
                  :placeholder="opt.value === 'openai' ? 'gpt-5.4' : 'Qwen/Qwen2.5-72B-Instruct'"
                />
                <a
                  class="model-doc-link"
                  :href="modelDocsUrl(opt.value)"
                  target="_blank"
                  rel="noreferrer"
                  :title="opt.value === 'openai' ? 'View OpenAI model names' : 'View SiliconFlow model names'"
                  :aria-label="opt.value === 'openai' ? 'View OpenAI model names' : 'View SiliconFlow model names'"
                >
                  <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                    <path d="M7 17 17 7" />
                    <path d="M9 7h8v8" />
                    <path d="M19 13v5a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2V7a2 2 0 0 1 2-2h5" />
                  </svg>
                </a>
              </div>
            </div>
          </div>

          <div class="model-actions">
            <span class="model-save-status" :class="modelSaveStatusType">{{ modelSaveStatus }}</span>
            <button type="button" class="model-save" @click="saveModelSettings">Save Changes</button>
          </div>
        </div>
      </div>
    </aside>

    <main ref="mainRef" class="chatbot-main" :class="{ empty: currentMessages.length === 0 }">
      <section v-if="currentMessages.length === 0" class="empty-state">
        <div class="empty-bot-avatar" aria-hidden="true">
          <img src="/chatbot-avatar.png" alt="" @error="hideBrokenImage" />
          <span>AI</span>
        </div>
        <h1>PhenoMAP Chat</h1>
      </section>

      <section v-else ref="scrollRef" class="message-list">
        <article v-for="(msg, i) in currentMessages" :key="i" class="message-row" :class="msg.role">
          <div class="message-avatar" :class="msg.role">
            <span v-if="msg.role === 'user'">{{ userInitials }}</span>
            <template v-else>
              <img src="/chatbot-avatar.png" alt="" @error="hideBrokenImage" />
              <span>AI</span>
            </template>
          </div>

          <div class="message-content">
            <div class="message-name">{{ msg.role === 'user' ? 'You' : 'PhenoMAP Chat' }}</div>
            <div class="message-bubble" :class="{ 'stopped-note': msg.stopped, 'loading-bubble': msg.streaming && !msg.content }">
              <template v-if="msg.role === 'assistant'">
                <template v-if="msg.streaming && !msg.content">
                  <span class="thinking-dot"></span>
                  <Transition name="thinking-fade" mode="out-in">
                    <span :key="thinkingStatus" class="thinking-text">{{ thinkingStatus || 'Thinking...' }}</span>
                  </Transition>
                </template>
                <div
                  v-else
                  class="markdown-body"
                  v-html="renderMarkdown(msg.content, msg.citations)"
                  @click="onMarkdownClick"
                ></div>

                <div v-if="!msg.streaming && (msg.entities?.length || msg.toolTrace?.length)" class="evidence-box">
                  <button type="button" class="evidence-toggle" @click="msg.evidenceOpen = !msg.evidenceOpen">
                    Evidence
                    <span v-if="msg.entities?.length">{{ msg.entities.length }} citations</span>
                    <span v-if="msg.toolTrace?.length">{{ msg.toolTrace.length }} tools</span>
                    <svg :class="{ open: msg.evidenceOpen }" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                      <path d="m8 10 4 4 4-4" />
                    </svg>
                  </button>

                  <div v-if="msg.evidenceOpen" class="evidence-content">
                    <div v-if="msg.entities?.length" class="citation-list">
                      <router-link
                        v-for="entity in msg.entities"
                        :key="entity.id"
                        :to="nodeRoute(entity.label, entity.id)"
                        class="citation-chip"
                      >
                        <span>{{ entity.label }}</span>
                        {{ entity.name || entity.id }}
                      </router-link>
                    </div>

                    <ol v-if="msg.toolTrace?.length" class="tool-list">
                      <li v-for="(step, k) in msg.toolTrace" :key="k">
                        <strong>{{ step.tool }}</strong>
                        <span>{{ compactArgs(step.args) }}</span>
                      </li>
                    </ol>
                  </div>
                </div>
              </template>
              <template v-else>{{ msg.content }}</template>
            </div>

            <div v-if="!msg.streaming" class="message-actions">
              <button type="button" class="msg-action" title="Copy" @click="copyMessage(msg.content, i)">
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8">
                  <rect x="8" y="8" width="12" height="12" rx="2" />
                  <path d="M16 8V6a2 2 0 0 0-2-2H6a2 2 0 0 0-2 2v8a2 2 0 0 0 2 2h2" />
                </svg>
              </button>
              <button
                type="button"
                class="msg-action"
                title="Regenerate"
                :disabled="loading"
                @click="regenerateFrom(i)"
              >
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8">
                  <path d="M20 11A8 8 0 1 0 18.5 16" />
                  <path d="M20 5v6h-6" />
                </svg>
              </button>
              <span v-if="copiedIndex === i" class="msg-copied">Copied</span>
            </div>
          </div>
        </article>

        <div v-if="error" class="chat-error">{{ error }}</div>
      </section>

      <div class="composer-wrap" :class="{ centered: currentMessages.length === 0 }">
        <form class="composer" @submit.prevent="sendMessage()">
          <textarea
            ref="inputRef"
            v-model="input"
            rows="1"
            placeholder="Ask PhenoMAP"
            @input="resizeInput"
            @keydown.enter.exact.prevent="sendMessage()"
          ></textarea>
          <button v-if="!loading" type="submit" :disabled="!input.trim()" aria-label="Send">
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2">
              <path d="M12 19V5M5 12l7-7 7 7" />
            </svg>
          </button>
          <button v-else type="button" class="stop-btn" aria-label="Stop generating" title="Stop generating" @click="stopGenerating">
            <svg viewBox="0 0 24 24" fill="currentColor">
              <rect x="5" y="5" width="14" height="14" rx="2" />
            </svg>
          </button>
        </form>
        <div v-if="currentMessages.length === 0" class="starter-block">
          <h2>Try Asking</h2>
          <div class="starter-prompts">
            <button v-for="prompt in starterPrompts" :key="prompt" type="button" @click="sendMessage(prompt)">
              <span>{{ prompt }}</span>
            </button>
          </div>
        </div>
        <p v-if="currentMessages.length === 0" class="ai-disclaimer">
          AI-generated answers may not always be accurate. Please verify important information.
        </p>
      </div>
    </main>
  </div>
</template>

<script setup>
import { computed, nextTick, onMounted, ref, watch } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import MarkdownIt from 'markdown-it'
import DOMPurify from 'dompurify'
import { postChat } from '../api.js'
import { authState } from '../auth.js'

const route = useRoute()
const router = useRouter()

const STORAGE_KEY = 'phenomap_chatbot_sessions_v1'
const MODEL_SETTINGS_KEY_PREFIX = 'phenomap_chatbot_model_settings_v1'

const sessions = ref([])
const activeSessionId = ref('')
const input = ref('')
const loading = ref(false)
const error = ref('')
const mainRef = ref(null)
const scrollRef = ref(null)
const inputRef = ref(null)
const modelMenuOpen = ref(false)
const modelSaveStatus = ref('')
const modelSaveStatusType = ref('success')
const provider = ref('siliconflow')
const providerDrafts = ref({
  openai: { apiKey: '', model: '' },
  siliconflow: { apiKey: '', model: '' },
})
const savedProvider = ref('siliconflow')
const savedApiKey = ref('')
const savedModel = ref('')
const copiedIndex = ref(null)
// Short "thinking" hint shown in place of the old static 3-dot spinner --
// updated as the backend streams progress through its pipeline (relevance
// check, intent classification, each tool call). See postChat's onEvent.
const thinkingStatus = ref('')
let modelSaveTimer = null
let copiedTimer = null
let activeAbortController = null

const providerOptions = [
  { value: 'siliconflow', label: 'SiliconFlow', description: 'Use your key' },
  { value: 'openai', label: 'ChatGPT API', description: 'Use your key' },
]

const starterPrompts = [
  'Which modules are associated with acute myeloid leukemia?',
  'Explain the tryptophan metabolism module in acute myeloid leukemia.',
  'Where does HMDB0000289 appear in PhenoMAP?',
  'Run enrichment for HMDB0000289 HMDB0000157 HMDB0000292.',
  'How are obesity and metabolic dysfunction-associated steatohepatitis connected?',
]

const modelLabel = computed(() => {
  if (savedProvider.value === 'openai') return 'ChatGPT API'
  return 'SiliconFlow'
})

const userInitials = computed(() => {
  const name = authState.user?.display_name || authState.user?.email || 'You'
  return name
    .split(/\s|@/)
    .filter(Boolean)
    .slice(0, 2)
    .map((x) => x[0]?.toUpperCase())
    .join('') || 'Y'
})

const activeSession = computed(() => sessions.value.find((s) => s.id === activeSessionId.value))
const currentMessages = computed(() => activeSession.value?.messages || [])
const accountId = computed(() => authState.user?.id || authState.user?.email || 'anonymous')
const modelSettingsKey = computed(() => `${MODEL_SETTINGS_KEY_PREFIX}:${accountId.value}`)
// Chat history is kept per account. It used to live under one browser-wide
// key, so two people signing in on the same browser saw (and added to) the
// same chat list. sessionsStorageKey records which key the sessions
// currently in memory were loaded from, so saving after an account switch
// can never write one person's chats under another person's key.
const sessionsKey = computed(() => `${STORAGE_KEY}:${accountId.value}`)
let sessionsStorageKey = 

onMounted(() => {
  loadSessions()
  loadModelSettings()

  // Coming back from an entity page's "Back to PhenoMAP Chat" link (see
  // nodeRoute() below, which stamps the current session id onto that link)
  // should land back on that exact conversation, not the "always blank"
  // behavior below -- that behavior is only for actually opening/reloading
  // the chat page fresh, not for a round trip that started here.
  const wantedSessionId = typeof route.query.session === 'string' ? route.query.session : ''
  if (wantedSessionId && sessions.value.some((s) => s.id === wantedSessionId)) {
    activeSessionId.value = wantedSessionId
    router.replace({ path: '/chat' })
    nextTick(scrollToBottom)
    return
  }

  // Reopening/reloading the page should never drop the user back into their
  // last conversation -- always land on a blank composer. newChat() itself
  // already no-ops when the most-recent session is still unused (see
  // below), so this either reuses that blank session or creates a fresh one
  // if the most recent session already has messages in it.
  newChat()
})

watch(
  sessions,
  () => {
    if (!sessionsStorageKey) return
    try {
      localStorage.setItem(sessionsStorageKey, JSON.stringify(sessions.value))
    } catch {
      // Storage full or blocked: keep the chat working in memory.
    }
  },
  { deep: true }
)

watch(accountId, () => {
  loadModelSettings()
  loadSessions()
  newChat()
})

function loadSessions() {
  sessionsStorageKey = sessionsKey.value
  try {
    // The old browser-wide history can't be attributed to an account, so
    // it is dropped rather than shown to whoever signs in next.
    localStorage.removeItem(STORAGE_KEY)
    const raw = JSON.parse(localStorage.getItem(sessionsStorageKey) || '[]')
    sessions.value = Array.isArray(raw) ? raw : []
    activeSessionId.value = sessions.value[0]?.id || ''
  } catch {
    sessions.value = []
  }
}

function newChat() {
  // If the current chat is already a fresh, unused one, clicking "New chat"
  // (or reopening the page) should be a no-op rather than piling up empty
  // "New chat" entries in the sidebar.
  if (activeSession.value && activeSession.value.messages.length === 0) {
    error.value = ''
    return
  }
  const session = {
    id: `chat_${Date.now()}_${Math.random().toString(16).slice(2)}`,
    title: 'New chat',
    messages: [],
    createdAt: Date.now(),
  }
  sessions.value.unshift(session)
  activeSessionId.value = session.id
  error.value = ''
  input.value = ''
  nextTick(resizeInput)
}

function selectSession(id) {
  activeSessionId.value = id
  error.value = ''
  nextTick(scrollToBottom)
}

function deleteSession(id) {
  const idx = sessions.value.findIndex((s) => s.id === id)
  if (idx === -1) return
  sessions.value.splice(idx, 1)
  if (activeSessionId.value === id) {
    activeSessionId.value = sessions.value[0]?.id || ''
    if (!activeSessionId.value) newChat()
  }
}

function saveModelSettings() {
  const nextProvider = provider.value
  const draft = providerDrafts.value[nextProvider] || { apiKey: '', model: '' }
  const nextApiKey = draft.apiKey.trim()
  const nextModel = draft.model.trim()

  if (!nextApiKey && !nextModel) {
    setModelSaveStatus('API key and model are required', 'error')
    return
  }
  if (!nextApiKey) {
    setModelSaveStatus('API key is required', 'error')
    return
  }
  if (!nextModel) {
    setModelSaveStatus('Model is required', 'error')
    return
  }

  savedProvider.value = provider.value
  savedApiKey.value = nextApiKey
  savedModel.value = nextModel
  // sessionStorage, not localStorage: a user-supplied OpenAI/SiliconFlow key
  // shouldn't sit on disk indefinitely (readable by anything else running
  // in this browser profile, and by any XSS in this or another tab of the
  // same origin, with no expiry). sessionStorage still means switching
  // between chats in the sidebar -- or navigating away and back -- doesn't
  // force retyping it, but closing this tab/window clears it, so the key
  // only ever lives as long as the browsing session that entered it.
  sessionStorage.setItem(
    modelSettingsKey.value,
    JSON.stringify({
      provider: savedProvider.value,
      api_key: savedApiKey.value,
      model: savedModel.value,
      drafts: providerDrafts.value,
    })
  )
  setModelSaveStatus('Saved', 'success')
  modelMenuOpen.value = false
}

function loadModelSettings() {
  let settings = null
  try {
    settings = JSON.parse(sessionStorage.getItem(modelSettingsKey.value) || 'null')
  } catch {
    settings = null
  }

  // Settings saved while "Official free" still existed fall back to the
  // default (SiliconFlow) here.
  const nextProvider = ['openai', 'siliconflow'].includes(settings?.provider)
    ? settings.provider
    : 'siliconflow'
  const drafts = {
    openai: {
      apiKey: typeof settings?.drafts?.openai?.apiKey === 'string' ? settings.drafts.openai.apiKey : '',
      model: typeof settings?.drafts?.openai?.model === 'string' ? settings.drafts.openai.model : '',
    },
    siliconflow: {
      apiKey: typeof settings?.drafts?.siliconflow?.apiKey === 'string' ? settings.drafts.siliconflow.apiKey : '',
      model: typeof settings?.drafts?.siliconflow?.model === 'string' ? settings.drafts.siliconflow.model : '',
    },
  }
  const legacyApiKey = typeof settings?.api_key === 'string' ? settings.api_key : ''
  const legacyModel = typeof settings?.model === 'string' ? settings.model : ''
  if (settings?.provider === nextProvider) {
    drafts[nextProvider].apiKey ||= legacyApiKey
    drafts[nextProvider].model ||= legacyModel
  }
  const nextApiKey = drafts[nextProvider].apiKey
  const nextModel = drafts[nextProvider].model

  provider.value = nextProvider
  providerDrafts.value = drafts
  savedProvider.value = nextProvider
  savedApiKey.value = nextApiKey
  savedModel.value = nextModel
  modelSaveStatus.value = ''
  modelSaveStatusType.value = 'success'
}

function setModelSaveStatus(message, type = 'success') {
  modelSaveStatus.value = message
  modelSaveStatusType.value = type
  if (modelSaveTimer) window.clearTimeout(modelSaveTimer)
  modelSaveTimer = window.setTimeout(() => {
    modelSaveStatus.value = ''
  }, type === 'error' ? 2600 : 1600)
}

async function scrollToBottom() {
  await nextTick()
  const el = mainRef.value || scrollRef.value
  if (el) el.scrollTop = el.scrollHeight
}

async function sendMessage(preset) {
  const text = (preset ?? input.value).trim()
  if (!text || loading.value || !activeSession.value) return
  if (!savedApiKey.value || !savedModel.value) {
    error.value = 'Please open Model settings and save your SiliconFlow or ChatGPT API key and model first.'
    modelMenuOpen.value = true
    return
  }

  const session = activeSession.value
  session.messages.push({ role: 'user', content: text })
  if (session.title === 'New chat') session.title = titleFrom(text)
  input.value = ''
  error.value = ''
  loading.value = true
  thinkingStatus.value = ''
  resizeInput()
  scrollToBottom()

  const controller = new AbortController()
  activeAbortController = controller

  try {
    const history = session.messages
      .filter((m) => m.role === 'user' || m.role === 'assistant')
      .slice(0, -1)
      .map((m) => ({
        role: m.role,
        content: m.content,
        ...(m.pendingResolution ? { pending_resolution: m.pendingResolution } : {}),
      }))
    const assistantIndex = session.messages.length
    session.messages.push({
      role: 'assistant',
      content: '',
      citations: {},
      entities: [],
      toolTrace: [],
      provider: null,
      pendingResolution: null,
      evidenceOpen: false,
      streaming: true,
    })
    const currentAssistant = () => session.messages[assistantIndex]
    const patchAssistant = (patch) => {
      const current = currentAssistant()
      if (!current) return null
      session.messages.splice(assistantIndex, 1, { ...current, ...patch })
      return currentAssistant()
    }
    scrollToBottom()
    const res = await postChat(text, history, llmPayload(), {
      signal: controller.signal,
      onEvent: (event) => {
        const assistantMsg = currentAssistant()
        if (!assistantMsg) return
        if (event.type === 'token') {
          patchAssistant({ content: `${assistantMsg.content || ''}${event.text || ''}` })
          if (localStorage.getItem('phenomap_chat_debug') === '1') {
            console.log('[PhenoMAP chat ui]', {
              seq: event.seq,
              clientTime: performance.now(),
              contentLength: currentAssistant()?.content?.length || 0,
            })
          }
          scrollToBottom()
        } else {
          thinkingStatus.value = event.text || ''
        }
      },
    })
    const assistantMsg = currentAssistant()
    if (!assistantMsg) return
    patchAssistant({
      content: res.reply || assistantMsg.content || '',
      citations: res.citations || {},
      entities: citationEntities(res.citations || {}),
      toolTrace: res.tool_calls || [],
      provider: res.provider,
      pendingResolution: res.pending_resolution || null,
      evidenceOpen: false,
      streaming: false,
    })
  } catch (e) {
    if (e.name === 'AbortError') {
      // User hit the stop button -- note it in the transcript instead of
      // showing an error banner; regenerateFrom() still works on this
      // message if they want to retry the same question.
      const assistantMsg = latestStreamingAssistant(session) || session.messages[session.messages.length - 1]
      if (assistantMsg?.role === 'assistant' && assistantMsg.streaming) {
        assistantMsg.content = assistantMsg.content || 'Stopped.'
        assistantMsg.citations = {}
        assistantMsg.entities = []
        assistantMsg.toolTrace = []
        assistantMsg.evidenceOpen = false
        assistantMsg.streaming = false
        assistantMsg.stopped = true
      }
    } else {
      const assistantMsg = latestStreamingAssistant(session) || session.messages[session.messages.length - 1]
      if (assistantMsg?.role === 'assistant' && assistantMsg.streaming && !assistantMsg.content) {
        session.messages.pop()
      } else if (assistantMsg?.role === 'assistant' && assistantMsg.streaming) {
        assistantMsg.streaming = false
      }
      error.value = e.message || 'Something went wrong talking to PhenoMAP Chat.'
    }
  } finally {
    loading.value = false
    thinkingStatus.value = ''
    activeAbortController = null
    if (activeSessionId.value === session.id) scrollToBottom()
  }
}

function latestStreamingAssistant(session) {
  for (let i = session.messages.length - 1; i >= 0; i -= 1) {
    const msg = session.messages[i]
    if (msg.role === 'assistant' && msg.streaming) return msg
  }
  return null
}

function stopGenerating() {
  if (activeAbortController) activeAbortController.abort()
}

async function copyMessage(text, i) {
  try {
    await navigator.clipboard.writeText(text || '')
  } catch {
    // Fallback for non-secure-context/older browsers where the Clipboard
    // API isn't available.
    const ta = document.createElement('textarea')
    ta.value = text || ''
    ta.style.position = 'fixed'
    ta.style.opacity = '0'
    document.body.appendChild(ta)
    ta.select()
    try {
      document.execCommand('copy')
    } catch {
      // ignore -- nothing more we can do
    }
    document.body.removeChild(ta)
  }
  copiedIndex.value = i
  if (copiedTimer) window.clearTimeout(copiedTimer)
  copiedTimer = window.setTimeout(() => {
    copiedIndex.value = null
  }, 1400)
}

// Re-ask: works from either the user question or the assistant answer that
// follows it. Both cut the conversation back to just before that question
// and resend it, so the model produces a fresh answer (dropping whatever
// came after, same as editing-and-resending in most chat UIs).
async function regenerateFrom(i) {
  const session = activeSession.value
  if (!session || loading.value) return
  const msg = session.messages[i]
  if (!msg) return
  const userIndex = msg.role === 'user' ? i : i - 1
  const userMsg = session.messages[userIndex]
  if (!userMsg || userMsg.role !== 'user') return
  const questionText = userMsg.content
  session.messages.splice(userIndex)
  await sendMessage(questionText)
}

function llmPayload() {
  return {
    provider: savedProvider.value,
    api_key: savedApiKey.value,
    model: savedModel.value,
  }
}

function modelDocsUrl(providerValue) {
  if (providerValue === 'openai') return 'https://developers.openai.com/api/docs/models/all'
  return 'https://docs.siliconflow.com/quickstart/models'
}

function citationEntities(citations) {
  return Object.entries(citations).map(([id, c]) => ({
    id,
    label: c.label,
    name: c.name || id,
  }))
}

// Real CommonMark rendering (headings, lists, **bold**, *italic*, `code`,
// code fences, tables, blockquotes, etc.) via markdown-it, the same class of
// parser ChatGPT/Claude's own UIs use -- rather than the small hand-rolled
// parser this used to be, which only understood a few hand-picked
// constructs and left things like inline `code` showing literal backticks.
//
// `breaks: true` turns a single newline inside a paragraph into <br>, which
// matches how the model tends to format replies (and how the old renderer
// behaved, via CSS white-space: pre-wrap).
const md = new MarkdownIt({ html: true, linkify: true, breaks: true })

// Real markdown links the model writes should open in a new tab rather than
// navigating the SPA away from the chat.
const defaultLinkOpen =
  md.renderer.rules.link_open ||
  ((tokens, idx, options, _env, self) => self.renderToken(tokens, idx, options))
md.renderer.rules.link_open = (tokens, idx, options, env, self) => {
  const token = tokens[idx]
  token.attrSet('target', '_blank')
  token.attrSet('rel', 'noreferrer')
  return defaultLinkOpen(tokens, idx, options, env, self)
}

// Citation tokens the backend emits: {{LAB_ID}} (looked up against the
// per-message citations map) and [[label:id|name]] (self-describing). Both
// forms are matched here, before the text is handed to markdown-it.
const CITE_TOKEN_RE = /(\{\{([^}]+)\}\}|\[\[([^:|\]]+):([^|\]]+)\|([^\]]+)\]\])/g

function escapeHtml(value) {
  return String(value).replace(/[&<>"']/g, (c) => (
    { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]
  ))
}

const INLINE_CITE_ICON =
  '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4">' +
  '<path d="M10.5 13.5a3.5 3.5 0 0 0 5 0l2.5-2.5a3.5 3.5 0 0 0-5-5l-1 1" />' +
  '<path d="M13.5 10.5a3.5 3.5 0 0 0-5 0l-2.5 2.5a3.5 3.5 0 0 0 5 5l1-1" />' +
  '</svg>'

// Replaces citation tokens with raw <a class="inline-cite"> HTML *before*
// markdown-it runs. With `html: true`, markdown-it passes recognized inline
// HTML tags through untouched, so these anchors survive markdown parsing
// intact and come out the other side ready to sanitize.
function preprocessCitations(content, citations) {
  return String(content || '').replace(
    CITE_TOKEN_RE,
    (_whole, _group, braceId, bracketLabel, bracketId, bracketName) => {
      const isBraceToken = Boolean(braceId)
      const id = isBraceToken ? braceId : bracketId
      const known = citations && citations[id]
      const label = isBraceToken ? known?.label : bracketLabel
      const name = isBraceToken ? known?.name || id : bracketName
      if (!known) return escapeHtml(name)
      const safeName = escapeHtml(name)
      const safeLabel = escapeHtml(known.label || label || '')
      const safeId = escapeHtml(id)
      // Icon-only, like a footnote marker -- the name itself isn't shown as
      // link text (it's already in the surrounding sentence the model
      // wrote); it only shows up as the hover tooltip via title/aria-label.
      return (
        `<a class="inline-cite" href="#" data-cite-label="${safeLabel}" ` +
        `data-cite-id="${safeId}" title="${safeName}" aria-label="${safeName}">` +
        `${INLINE_CITE_ICON}</a>`
      )
    },
  )
}

const SANITIZE_OPTS = {
  ADD_TAGS: ['svg', 'path'],
  ADD_ATTR: ['viewBox', 'stroke-width', 'stroke', 'fill', 'd', 'data-cite-label', 'data-cite-id', 'target'],
}

function renderMarkdown(content, citations) {
  const html = md.render(preprocessCitations(content, citations))
  return DOMPurify.sanitize(html, SANITIZE_OPTS)
}

// v-html strips Vue's normal @click handling on router-link, so citation
// clicks are caught here via delegation on the container and turned into a
// router push instead of a real navigation to href="#".
function onMarkdownClick(event) {
  const link = event.target.closest('a.inline-cite')
  if (!link) return
  event.preventDefault()
  const label = link.dataset.citeLabel
  const id = link.dataset.citeId
  if (!label || !id) return
  router.push(nodeRoute(label, id))
}

function nodeRoute(label, id) {
  // Stamping the active session id onto returnTo means the "Back to
  // PhenoMAP Chat" link on the entity page comes back to this exact
  // conversation (see onMounted above), not just the chat page in its
  // default "start blank" state.
  const returnTo = activeSessionId.value
    ? `/chat?session=${encodeURIComponent(activeSessionId.value)}`
    : '/chat'
  return {
    name: 'node-detail',
    params: { label, id },
    query: {
      returnTo,
      returnLabel: 'PhenoMAP Chat',
    },
  }
}

function compactArgs(args) {
  if (!args) return ''
  const text = JSON.stringify(args)
  return text.length > 110 ? text.slice(0, 107) + '...' : text
}

function titleFrom(text) {
  return text.length > 32 ? text.slice(0, 29) + '...' : text
}

function resizeInput() {
  const el = inputRef.value
  if (!el) return
  el.style.height = 'auto'
  el.style.height = `${Math.min(el.scrollHeight, 180)}px`
}

function hideBrokenImage(event) {
  event.target.style.display = 'none'
}
</script>

<style scoped>
.chatbot-page {
  min-height: calc(100vh - 69px);
  display: grid;
  grid-template-columns: 286px minmax(0, 1fr);
  background: #f7f8fa;
  color: #202534;
}
.chatbot-sidebar {
  height: calc(100vh - 69px);
  display: flex;
  flex-direction: column;
  border-right: 1px solid rgba(226, 232, 240, 0.16);
  background:
    radial-gradient(circle at 16% 0%, rgba(143, 215, 234, 0.16), transparent 32%),
    linear-gradient(180deg, #123a55 0%, #174564 100%);
  overflow: hidden;
}
.bot-brand {
  display: flex;
  align-items: center;
  gap: 10px;
  padding: 18px 16px 12px;
  min-width: 0;
}
.bot-avatar,
.empty-bot-avatar,
.message-avatar.assistant {
  background: linear-gradient(135deg, #0f7c96, #245c7e);
  color: #fff;
}
.bot-avatar,
.user-avatar,
.message-avatar,
.empty-bot-avatar {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  flex: none;
  border-radius: 999px;
  font-weight: 800;
}
.bot-avatar,
.user-avatar,
.message-avatar {
  width: 40px;
  height: 40px;
  font-size: 12px;
  overflow: hidden;
}
.bot-avatar img,
.message-avatar img,
.empty-bot-avatar img {
  width: 86%;
  height: 86%;
  object-fit: contain;
}
.bot-avatar img + span,
.message-avatar img + span,
.empty-bot-avatar img + span {
  display: none;
}
.bot-title {
  min-width: 0;
  display: grid;
  gap: 2px;
}
.bot-title strong {
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
  font-size: 17px;
  color: #fff;
}
.bot-title span,
.account-text small {
  color: rgba(219, 225, 247, 0.72);
  font-size: 12px;
}
.new-chat-btn {
  display: flex;
  align-items: center;
  gap: 10px;
  margin: 8px 12px 14px;
  padding: 11px 13px;
  border: 1px solid rgba(143, 215, 234, 0.22);
  border-radius: 8px;
  background: rgba(255, 255, 255, 0.1);
  color: #eef8fa;
  font: inherit;
  font-weight: 700;
  cursor: pointer;
}
.new-chat-btn:hover,
.history-row.active {
  background: rgba(255, 255, 255, 0.16);
}
.new-chat-btn svg {
  width: 19px;
  height: 19px;
}
.chat-history {
  flex: 1;
  min-height: 0;
  overflow-y: auto;
  padding: 8px 10px 18px;
}
.chat-history h2 {
  margin: 10px 8px 8px;
  color: #8fd7ea;
  font-size: 13px;
}
.empty-history {
  margin: 0 8px;
  color: rgba(219, 225, 247, 0.58);
  font-size: 13px;
}
.history-row {
  width: 100%;
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 8px;
  border-radius: 8px;
}
.history-title {
  min-width: 0;
  flex: 1;
  border: 0;
  border-radius: 8px;
  background: transparent;
  color: rgba(255, 255, 255, 0.86);
  padding: 10px 8px;
  font: inherit;
  text-align: left;
  cursor: pointer;
}
.history-row:hover {
  background: rgba(255, 255, 255, 0.1);
}
.history-title {
  min-width: 0;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.history-delete {
  display: none;
  width: 25px;
  height: 25px;
  border: 0;
  border-radius: 6px;
  background: transparent;
  color: rgba(219, 225, 247, 0.64);
  cursor: pointer;
}
.history-row:hover .history-delete {
  display: inline-flex;
  align-items: center;
  justify-content: center;
}
.history-delete:hover {
  background: rgba(255, 255, 255, 0.16);
  color: #ffd2c8;
}
.history-row svg {
  width: 16px;
  height: 16px;
}
.account-block {
  position: relative;
  border-top: 1px solid rgba(226, 232, 240, 0.16);
  padding: 10px;
}
.account-button {
  width: 100%;
  display: flex;
  align-items: center;
  gap: 10px;
  border: 0;
  border-radius: 8px;
  background: transparent;
  padding: 8px;
  cursor: pointer;
}
.account-button:hover {
  background: rgba(255, 255, 255, 0.1);
}
.user-avatar,
.message-avatar.user {
  background: #eef8fa;
  color: #0f7c96;
}
.account-text {
  flex: 1;
  min-width: 0;
  display: grid;
  text-align: left;
}
.account-text strong {
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
  font-size: 14px;
  color: #fff;
}
.account-button svg {
  width: 17px;
  height: 17px;
  color: rgba(219, 225, 247, 0.7);
}
.model-popover {
  position: absolute;
  left: 10px;
  right: 10px;
  bottom: calc(100% + 8px);
  padding: 8px;
  border: 1px solid #e0e4ee;
  border-radius: 10px;
  background: #fff;
  box-shadow: 0 18px 38px rgba(24, 31, 55, 0.16);
  z-index: 10;
}
.model-popover-header {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 8px;
  min-height: 30px;
  padding: 2px 2px 6px 8px;
  color: #7a8295;
  font-size: 12px;
  font-weight: 800;
}
.model-close {
  width: 26px;
  height: 26px;
  display: inline-flex;
  align-items: center;
  justify-content: center;
  border: 0;
  border-radius: 7px;
  background: transparent;
  color: #8a92a3;
  cursor: pointer;
}
.model-close:hover {
  background: #f0f2f7;
  color: #252b38;
}
.model-close svg {
  width: 15px;
  height: 15px;
}
.model-provider {
  display: grid;
  gap: 6px;
}
.model-option {
  width: 100%;
  display: grid;
  gap: 2px;
  border: 0;
  border-radius: 8px;
  background: transparent;
  padding: 9px;
  text-align: left;
  cursor: pointer;
}
.model-option.active,
.model-option:hover {
  background: #eef8fa;
}
.model-option span {
  font-weight: 800;
}
.model-option small {
  color: #737b8c;
}
.provider-fields {
  display: grid;
  gap: 7px;
  padding: 0 4px 8px;
}
.provider-fields input {
  width: 100%;
  border: 1px solid #dce1ec;
  border-radius: 8px;
  padding: 8px 9px;
  font: inherit;
  font-size: 12px;
}
.model-input-row {
  display: grid;
  grid-template-columns: minmax(0, 1fr) 30px;
  gap: 6px;
}
.model-doc-link {
  width: 30px;
  min-width: 30px;
  height: 34px;
  display: inline-flex;
  align-items: center;
  justify-content: center;
  border: 1px solid #dce1ec;
  border-radius: 8px;
  background: #fff;
  color: #5d6678;
}
.model-doc-link:hover {
  border-color: #b8c0d4;
  background: #f7f8fb;
  color: #0f7c96;
}
.model-doc-link svg {
  width: 15px;
  height: 15px;
}
.model-actions {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 10px;
  padding: 9px 4px 2px;
}
.model-save-status {
  min-height: 16px;
  color: #1a8f5e;
  font-size: 12px;
  font-weight: 800;
}
.model-save-status.error {
  color: #c0392b;
}
.model-save {
  border: 0;
  border-radius: 8px;
  background: #245c7e;
  color: #fff;
  padding: 8px 11px;
  font: inherit;
  font-size: 12px;
  font-weight: 800;
  cursor: pointer;
}
.model-save:hover {
  background: #174564;
}
.chatbot-main {
  position: relative;
  min-width: 0;
  height: calc(100vh - 69px);
  display: flex;
  flex-direction: column;
  overflow-y: auto;
  overflow-x: hidden;
  background:
    radial-gradient(circle at 50% 0%, rgba(143, 215, 234, 0.14), transparent 34%),
    #f7f8fa;
}
.chatbot-main.empty {
  justify-content: flex-start;
}
.empty-state {
  display: grid;
  place-items: center;
  gap: 16px;
  margin-top: clamp(34px, 10vh, 92px);
}
.empty-bot-avatar {
  width: 132px;
  height: 132px;
  font-size: 28px;
  padding: 10px;
  overflow: hidden;
  box-shadow: 0 18px 42px rgba(36, 92, 126, 0.22);
}
.empty-state h1 {
  margin: 0;
  font-size: 32px;
  line-height: 1.1;
}
.message-list {
  flex: 0 0 auto;
  overflow: visible;
  padding: 34px min(4vw, 56px) 132px;
}
.message-row {
  display: flex;
  gap: 13px;
  max-width: 1680px;
  margin: 0 auto 28px;
}
.message-row.user {
  flex-direction: row-reverse;
}
.message-content {
  min-width: 0;
  max-width: min(980px, 88%);
}
.message-row.user .message-content {
  display: grid;
  justify-items: end;
}
.message-name {
  margin-bottom: 7px;
  color: #8b93a5;
  font-size: 13px;
  font-weight: 800;
}
.message-bubble {
  width: fit-content;
  max-width: 100%;
  border-radius: 8px;
  padding: 14px 16px;
  background: #fff;
  border: 1px solid #e1e6ef;
  box-shadow: 0 8px 22px rgba(27, 34, 58, 0.05);
  line-height: 1.65;
  overflow-wrap: anywhere;
}
.message-row.user .message-bubble {
  background: #245c7e;
  border-color: #245c7e;
  color: #fff;
}
/* The markdown body's contents come from v-html (markdown-it output), so the
   compiler never sees these elements in the template and can't attach the
   usual scoped data-v-xxxx attribute to them. :deep() drops the scope
   attribute requirement on the right-hand side of the selector while still
   scoping the match to descendants of .markdown-body, which does get the
   attribute (it's a real template element). Without :deep() none of these
   rules match anything and v-html content falls back to unstyled browser
   defaults (visible blue underlined links, full-size raw SVG icons, etc). */
.markdown-body :deep(p) {
  margin: 0 0 14px;
}
.markdown-body :deep(p):last-child,
.markdown-body :deep(ul):last-child,
.markdown-body :deep(ol):last-child,
.markdown-body :deep(pre):last-child,
.markdown-body :deep(blockquote):last-child,
.markdown-body :deep(table):last-child,
.markdown-body :deep(h1):last-child,
.markdown-body :deep(h2):last-child,
.markdown-body :deep(h3):last-child,
.markdown-body :deep(h4):last-child,
.markdown-body :deep(h5):last-child,
.markdown-body :deep(h6):last-child {
  margin-bottom: 0;
}
.markdown-body :deep(h1),
.markdown-body :deep(h2),
.markdown-body :deep(h3),
.markdown-body :deep(h4),
.markdown-body :deep(h5),
.markdown-body :deep(h6) {
  margin: 18px 0 8px;
  color: #202534;
  font-size: 1em;
  line-height: 1.35;
  font-weight: 850;
}
.markdown-body :deep(h1):first-child,
.markdown-body :deep(h2):first-child,
.markdown-body :deep(h3):first-child,
.markdown-body :deep(h4):first-child,
.markdown-body :deep(h5):first-child,
.markdown-body :deep(h6):first-child {
  margin-top: 0;
}
.markdown-body :deep(ul),
.markdown-body :deep(ol) {
  margin: 0 0 14px;
  padding-left: 1.25em;
}
.markdown-body :deep(li) {
  margin: 4px 0;
}
.markdown-body :deep(li) > p {
  margin: 0;
}
.markdown-body :deep(code) {
  background: rgba(32, 54, 166, 0.08);
  border-radius: 4px;
  padding: 0.15em 0.4em;
  font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
  font-size: 0.88em;
}
.message-row.user .markdown-body :deep(code) {
  background: rgba(255, 255, 255, 0.18);
}
.markdown-body :deep(pre) {
  margin: 0 0 14px;
  padding: 12px 14px;
  background: #1d2333;
  color: #e7eaf6;
  border-radius: 8px;
  overflow-x: auto;
}
.markdown-body :deep(pre code) {
  background: none;
  padding: 0;
  color: inherit;
  font-size: 0.85em;
}
.markdown-body :deep(blockquote) {
  margin: 0 0 14px;
  padding: 2px 14px;
  border-left: 3px solid #8fd7ea;
  color: #4a5170;
}
.markdown-body :deep(table) {
  margin: 0 0 14px;
  border-collapse: collapse;
  font-size: 0.92em;
}
.markdown-body :deep(th),
.markdown-body :deep(td) {
  border: 1px solid #e1e6ef;
  padding: 6px 10px;
  text-align: left;
}
.markdown-body :deep(a):not(.inline-cite) {
  color: #0f7c96;
}
.message-row.user .markdown-body :deep(a):not(.inline-cite) {
  color: #fff;
  text-decoration-color: rgba(255, 255, 255, 0.6);
}
.markdown-body :deep(.inline-cite) {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  width: 15px;
  height: 15px;
  margin: 0 1px;
  vertical-align: super;
  flex: none;
  color: #0f7c96;
  background: #eef8fa;
  border: 1px solid #cdebf1;
  border-radius: 999px;
  padding: 0;
  text-decoration: none;
  overflow: hidden;
}
.markdown-body :deep(.inline-cite):hover {
  background: #dff3f7;
  border-color: #9bd8e5;
}
.markdown-body :deep(.inline-cite) svg {
  width: 9px;
  height: 9px;
  flex: none;
}
.message-actions {
  display: flex;
  align-items: center;
  gap: 4px;
  margin-top: 6px;
  min-height: 26px;
}
.message-row.user .message-actions {
  justify-content: flex-end;
}
.msg-action {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  width: 26px;
  height: 26px;
  border: 0;
  border-radius: 6px;
  background: transparent;
  color: #9aa1b0;
  cursor: pointer;
}
.msg-action:hover:not(:disabled) {
  background: #eef0f5;
  color: #454d5f;
}
.msg-action:disabled {
  opacity: 0.4;
  cursor: not-allowed;
}
.msg-action svg {
  width: 15px;
  height: 15px;
}
.msg-copied {
  color: #1a8f5e;
  font-size: 12px;
  font-weight: 700;
}
.evidence-box {
  margin-top: 12px;
}
.evidence-toggle {
  display: inline-flex;
  align-items: center;
  gap: 8px;
  border: 1px solid #dbe2f1;
  border-radius: 999px;
  background: #f7f8fc;
  color: #40495d;
  padding: 6px 10px;
  font: inherit;
  font-size: 12px;
  font-weight: 800;
  cursor: pointer;
}
.evidence-toggle span {
  color: #737d96;
  font-weight: 700;
}
.evidence-toggle svg {
  width: 15px;
  height: 15px;
  transition: transform 0.16s ease;
}
.evidence-toggle svg.open {
  transform: rotate(180deg);
}
.evidence-content {
  margin-top: 10px;
  border-top: 1px solid #edf0f6;
  padding-top: 10px;
}
.citation-list {
  display: flex;
  flex-wrap: wrap;
  gap: 7px;
}
.citation-chip {
  display: inline-flex;
  align-items: center;
  gap: 6px;
  max-width: 100%;
  border: 1px solid #cdebf1;
  border-radius: 999px;
  background: #eef8fa;
  color: #0f7c96;
  padding: 3px 9px;
  font-size: 12px;
  font-weight: 800;
  text-decoration: none;
}
.citation-chip span {
  color: #5e9aaa;
  font-size: 10px;
  text-transform: uppercase;
}
.tool-list {
  margin: 10px 0 0;
  padding-left: 18px;
  color: #5b6476;
  font-size: 12px;
}
.tool-list span {
  margin-left: 6px;
}
.loading-bubble {
  display: flex;
  align-items: center;
  gap: 9px;
  color: #6b7280;
  font-size: 13.5px;
}
.mini-spinner {
  display: inline-block;
  border-radius: 999px;
  background: currentColor;
}
.thinking-dot {
  display: inline-block;
  flex: none;
  width: 8px;
  height: 8px;
  border-radius: 999px;
  background: #0f7c96;
  animation: thinking-dot-pulse 1.1s infinite ease-in-out;
}
.thinking-text {
  display: inline-block;
}
.thinking-fade-enter-active,
.thinking-fade-leave-active {
  transition: opacity 160ms ease, transform 160ms ease;
}
.thinking-fade-enter-from {
  opacity: 0;
  transform: translateY(3px);
}
.thinking-fade-leave-to {
  opacity: 0;
  transform: translateY(-3px);
}
@keyframes thinking-dot-pulse {
  0%, 100% { transform: scale(0.7); opacity: 0.5; }
  50% { transform: scale(1); opacity: 1; }
}
.chat-error {
  max-width: 1680px;
  margin: 0 auto;
  color: #b42318;
  font-weight: 700;
}
.composer-wrap {
  position: sticky;
  bottom: 0;
  padding: 18px min(4vw, 56px) 24px;
  background: linear-gradient(180deg, rgba(247, 248, 250, 0), #f7f8fa 35%);
}
.composer-wrap.centered {
  position: static;
  background: transparent;
  padding-top: 34px;
  padding-bottom: 32px;
}
.composer {
  max-width: 1680px;
  margin: 0 auto;
  display: flex;
  align-items: flex-end;
  gap: 10px;
  border: 1px solid #dce5ea;
  border-radius: 10px;
  background: #fff;
  padding: 10px;
  box-shadow: 0 16px 40px rgba(36, 72, 95, 0.12);
}
.composer textarea {
  flex: 1;
  min-height: 24px;
  max-height: 180px;
  resize: none;
  border: 0;
  outline: none;
  padding: 8px 6px;
  font: inherit;
  line-height: 1.45;
  background: transparent;
}
.composer button {
  width: 36px;
  height: 36px;
  flex: none;
  border: 0;
  border-radius: 8px;
  background: #245c7e;
  color: #fff;
  display: inline-flex;
  align-items: center;
  justify-content: center;
  cursor: pointer;
}
.composer button:disabled {
  opacity: 0.45;
  cursor: not-allowed;
}
.composer button svg {
  width: 20px;
  height: 20px;
}
.stop-btn {
  background: #202534 !important;
}
.stop-btn:hover {
  background: #34394a !important;
}
.stop-btn svg {
  width: 17px !important;
  height: 17px !important;
}
.stopped-note {
  color: #8b93a5;
  font-style: italic;
}
.ai-disclaimer {
  max-width: 1680px;
  margin: 0 auto;
  color: #969dac;
  font-size: 12px;
  line-height: 1.4;
  text-align: center;
}
.composer-wrap.centered .ai-disclaimer {
  position: absolute;
  left: min(4vw, 56px);
  right: min(4vw, 56px);
  bottom: 22px;
}
.starter-block {
  max-width: 820px;
  margin: 12px auto 0;
  width: fit-content;
}
.starter-block h2 {
  margin: 0 0 7px;
  color: #7c8496;
  font-size: 13px;
  font-weight: 800;
  line-height: 1.3;
  text-align: center;
}
.starter-prompts {
  display: grid;
  justify-items: start;
  gap: 6px;
}
.starter-prompts button {
  width: 100%;
  max-width: 100%;
  display: inline-flex;
  align-items: baseline;
  gap: 8px;
  border: 0;
  border-radius: 0;
  background: transparent;
  color: #687084;
  padding: 4px 2px;
  font: inherit;
  font-size: 13px;
  text-align: left;
  cursor: pointer;
}
.starter-prompts button::before {
  content: "";
  width: 4px;
  height: 4px;
  flex: none;
  border-radius: 999px;
  background: #9aa2b4;
  transform: translateY(-2px);
}
.starter-prompts button span {
  border-bottom: 1px solid #d8deea;
  line-height: 1.5;
}
.starter-prompts button:hover {
  color: #26349b;
  background: transparent;
}
.starter-prompts button:hover span {
  border-color: #8f9be0;
}
.mini-spinner {
  width: 12px;
  height: 12px;
  color: #fff;
  animation: pulse 0.8s infinite ease-in-out;
}
@keyframes pulse {
  0%, 80%, 100% { transform: translateY(0); opacity: 0.45; }
  40% { transform: translateY(-3px); opacity: 1; }
}
@media (max-width: 840px) {
  .chatbot-page {
    grid-template-columns: 1fr;
  }
  .chatbot-sidebar {
    display: none;
  }
  .chatbot-main {
    height: calc(100vh - 69px);
  }
  .message-list,
  .composer-wrap {
    padding-left: 18px;
    padding-right: 18px;
  }
  .message-content {
    max-width: 86%;
  }
  .starter-prompts {
    grid-template-columns: 1fr;
  }
}
</style>
