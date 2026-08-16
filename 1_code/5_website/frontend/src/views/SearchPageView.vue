<template>
  <div class="entity-search">
    <!-- ============ HEADER / CONTROLS BAND ============ -->
    <section class="es-header">
      <AnimatedNetworkField class="analysis-network-bg" :seed="17" :node-count="22" :drift-scale="0.82" />
      <div class="es-container es-header-flex">
        <div class="es-header-left">
        <h1>Entity Search</h1>

        <div class="type-tabs">
          <button
            v-for="opt in labelOptions"
            :key="opt.value"
            type="button"
            class="type-tab"
            :class="{ active: label === opt.value }"
            :style="{ '--tab-color': opt.color }"
            @click="selectLabel(opt.value)"
          >
            <span class="type-tab-icon">
              <svg v-if="opt.value === 'Metabolite'" viewBox="0 0 24 24" fill="none" stroke="#fff" stroke-width="1.8">
                <circle cx="6" cy="6" r="2.3" />
                <circle cx="18" cy="6" r="2.3" />
                <circle cx="12" cy="17" r="2.3" />
                <path d="M7.7 7.3 10.6 14.9M16.3 7.3 13.4 14.9M8.3 6h7.4" />
              </svg>
              <svg v-else-if="opt.value === 'Module'" viewBox="0 0 24 24" fill="none" stroke="#fff" stroke-width="1.8">
                <circle cx="6" cy="6.5" r="2.1" />
                <circle cx="18" cy="6.5" r="2.1" />
                <circle cx="6" cy="17.5" r="2.1" />
                <circle cx="18" cy="17.5" r="2.1" />
                <circle cx="12" cy="12" r="2.3" />
                <path d="M7.6 7.9 10.3 10.6M16.4 7.9 13.7 10.6M7.6 16.1 10.3 13.4M16.4 16.1 13.7 13.4" />
              </svg>
              <svg v-else-if="opt.value === 'Study'" viewBox="0 0 24 24" fill="none" stroke="#fff" stroke-width="1.8">
                <rect x="4" y="5" width="16" height="15" rx="2" />
                <path d="M8 3v4M16 3v4M4 10h16M8.5 14h3M8.5 17h6" />
              </svg>
              <svg v-else viewBox="0 0 24 24" fill="none" stroke="#fff" stroke-width="1.8" stroke-linejoin="round">
                <path d="M3 13h3.2l2 6.5L13 4.5l1.8 8.5H21" />
              </svg>
            </span>
            {{ opt.text }}
          </button>
        </div>

        <div class="search-bar">
          <svg class="search-icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
            <circle cx="11" cy="11" r="7" />
            <line x1="21" y1="21" x2="16.65" y2="16.65" />
          </svg>
          <input
            v-model="query"
            type="text"
            :placeholder="currentPlaceholder"
            @input="onInput"
            autofocus
          />
          <button
            v-if="query"
            type="button"
            class="clear-btn"
            aria-label="Clear search"
            @click="clearQuery"
          >
            &times;
          </button>
        </div>

        <div class="example-chips" v-if="!query && currentExamples.length">
          <span class="chip-label">Try:</span>
          <template v-for="(ex, i) in currentExamples" :key="ex">
            <button type="button" class="chip" @click="tryExample(ex)">{{ ex }}</button>
            <span v-if="i < currentExamples.length - 1" class="chip-sep">,</span>
          </template>
        </div>
        </div>

        <div class="header-decoration" aria-hidden="true">
          <div class="decoration-blob"></div>
          <img
            v-if="!decorIconFailed[label]"
            :src="`/icons/${label.toLowerCase()}.svg`"
            class="decoration-icon-img"
            alt=""
            @error="decorIconFailed[label] = true"
          />
          <svg
            v-else
            class="decoration-icon-fallback"
            viewBox="0 0 24 24"
            fill="none"
            stroke="rgba(216, 231, 239, 0.88)"
            stroke-width="1"
          >
            <template v-if="label === 'Metabolite'">
              <circle cx="6" cy="6" r="2.3" />
              <circle cx="18" cy="6" r="2.3" />
              <circle cx="12" cy="17" r="2.3" />
              <path d="M7.7 7.3 10.6 14.9M16.3 7.3 13.4 14.9M8.3 6h7.4" />
            </template>
            <template v-else-if="label === 'Module'">
              <circle cx="6" cy="6.5" r="2.1" />
              <circle cx="18" cy="6.5" r="2.1" />
              <circle cx="6" cy="17.5" r="2.1" />
              <circle cx="18" cy="17.5" r="2.1" />
              <circle cx="12" cy="12" r="2.3" />
              <path d="M7.6 7.9 10.3 10.6M16.4 7.9 13.7 10.6M7.6 16.1 10.3 13.4M16.4 16.1 13.7 13.4" />
            </template>
            <template v-else-if="label === 'Study'">
              <rect x="4" y="5" width="16" height="15" rx="2" />
              <path d="M8 3v4M16 3v4M4 10h16M8.5 14h3M8.5 17h6" />
            </template>
            <template v-else>
              <path d="M3 13h3.2l2 6.5L13 4.5l1.8 8.5H21" />
            </template>
          </svg>
        </div>
      </div>
    </section>

    <!-- ============ RESULTS ============ -->
    <section class="es-container results-section">
      <div v-if="error" class="state-block state-error">
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
          <circle cx="12" cy="12" r="9" /><path d="M12 8v5M12 16h.01" />
        </svg>
        <span>{{ error }}</span>
      </div>

      <div v-else-if="loading" class="state-block state-loading">
        <span class="spinner" aria-hidden="true"></span>
        <span>Loading...</span>
      </div>

      <template v-else>
        <p v-if="query.trim().length === 1" class="hint">Keep typing...</p>

        <div v-else-if="results.length === 0" class="state-block state-empty">
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6">
            <circle cx="11" cy="11" r="7" />
            <line x1="21" y1="21" x2="16.65" y2="16.65" />
          </svg>
          <span>No matches.</span>
        </div>

        <template v-else>
          <p class="results-meta">
            <span v-if="isBrowsing">All {{ total.toLocaleString() }} {{ pluralLabel }}, sorted by PhenoMAP ID</span>
            <span v-else>{{ total.toLocaleString() }} result{{ total === 1 ? '' : 's' }} for &ldquo;{{ query }}&rdquo;</span>
          </p>

          <div class="results-table-wrap">
            <div class="results-table" :class="`results-table-${label.toLowerCase()}`">
              <div class="table-head">
                <span><TermInfo label="Type" :definition="resultHeaderDefinition('Type', 'entity')" /></span>
                <span><TermInfo label="PhenoMAP ID" :definition="resultHeaderDefinition('PhenoMAP ID')" /></span>
                <span><TermInfo label="Title" :definition="resultHeaderDefinition('Title')" /></span>
                <span><TermInfo :label="detailHeader" :definition="resultHeaderDefinition(detailHeader, 'detail')" /></span>
                <span v-if="detail2Header"><TermInfo :label="detail2Header" :definition="resultHeaderDefinition(detail2Header)" /></span>
                <span></span>
              </div>
              <router-link
                v-for="r in results"
                :key="r.label + r.lab_id"
                :to="nodeRoute(r.label, r.lab_id)"
                class="table-row"
                :style="{ '--accent': typeColor(r.label) }"
              >
                <span class="cell-type">
                  <span class="badge" :data-label="r.label">{{ r.label }}</span>
                </span>
                <span class="cell-id">{{ r.lab_id }}</span>
                <span class="cell-title">{{ r.title || '(untitled)' }}</span>
                <span class="cell-detail">{{ r.subtitle || '—' }}</span>
                <span class="cell-detail2" v-if="detail2Header">{{ r.extra || '—' }}</span>
                <span class="cell-arrow">
                  <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                    <path d="m9 6 6 6-6 6" />
                  </svg>
                </span>
              </router-link>
            </div>
          </div>

          <div class="pagination" v-if="totalPages > 1">
            <button type="button" class="page-nav" :disabled="page <= 1" @click="goToPage(page - 1)">
              <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="m15 6-6 6 6 6" /></svg>
              Prev
            </button>
            <span class="page-pill">{{ page }} / {{ totalPages }}</span>
            <button type="button" class="page-nav" :disabled="page >= totalPages" @click="goToPage(page + 1)">
              Next
              <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="m9 6 6 6-6 6" /></svg>
            </button>
          </div>
        </template>
      </template>
    </section>
  </div>
</template>

<script setup>
import { onMounted, onUnmounted, ref, computed } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { searchNodes } from '../api.js'
import AnimatedNetworkField from '../components/AnimatedNetworkField.vue'
import TermInfo from '../components/TermInfo.vue'

const route = useRoute()
const router = useRouter()

const query = ref('')
const label = ref('Module')
const results = ref([])
const total = ref(0)
const page = ref(1)
const pageSize = 20
const totalPages = computed(() => Math.max(1, Math.ceil(total.value / pageSize)))
const loading = ref(false)
const error = ref('')
let debounceTimer = null

// Per-type header illustration: tries /icons/{label}.svg (public folder --
// drop a file there and it's picked up automatically, no rebuild-time
// import needed) and falls back to a scaled-up version of the tab icon.
const decorIconFailed = ref({})

const labelOptions = [
  { value: 'Module', text: 'Module', color: '#1a8f5e' },
  { value: 'Study', text: 'Study', color: '#3949ab' },
  { value: 'Phenotype', text: 'Phenotype', color: '#b3562c' },
  { value: 'Metabolite', text: 'Metabolite', color: '#0f7c96' },
]
const typeColors = Object.fromEntries(labelOptions.map((o) => [o.value, o.color]))
function typeColor(l) {
  return typeColors[l] || '#6b7280'
}

const pluralLabels = { Study: 'studies', Phenotype: 'phenotypes', Module: 'modules', Metabolite: 'metabolites' }
const pluralLabel = computed(() => pluralLabels[label.value] || 'entities')

const detailHeaders = { Study: 'Accession', Module: 'Hypothesis Type', Phenotype: 'Type', Metabolite: 'HMDB ID' }
const detailHeader = computed(() => detailHeaders[label.value] || 'Details')

// Second detail column -- only Phenotype (OLS ID) and Metabolite (KEGG ID)
// have one; the column is omitted entirely for Study/Module (see
// hasExtraColumn usage in the template, which conditionally renders it).
const detail2Headers = { Phenotype: 'OLS ID', Metabolite: 'KEGG ID' }
const detail2Header = computed(() => detail2Headers[label.value] || '')

const resultHeaderDefinitions = {
  Type: 'The entity category used in the PhenoMAP graph: Study, Phenotype, Module, or Metabolite.',
  'PhenoMAP ID': 'The internal stable identifier used by PhenoMAP to link this entity across search results, detail pages, and graph relationships.',
  Title: 'The primary display name for the matched entity.',
  Accession: 'The external study accession from the source repository when available.',
  'Hypothesis Type': 'The module interpretation category assigned during the FeatureMAP workflow.',
  'HMDB ID': 'The Human Metabolome Database identifier for this metabolite.',
  'KEGG ID': 'The KEGG Compound identifier for this metabolite.',
  'OLS ID': 'The Ontology Lookup Service identifier for the normalized phenotype term.',
}
function resultHeaderDefinition(labelName, context = '') {
  if (labelName === 'Type' && context === 'detail' && label.value === 'Phenotype') {
    return 'For phenotype rows, this is the phenotype category or ontology type when available.'
  }
  return resultHeaderDefinitions[labelName] || ''
}

const placeholders = {
  Study: 'Search a study accession, title, or keyword...',
  Phenotype: 'Search a phenotype name or keyword...',
  Module: 'Search a module title, ID, or keyword...',
  Metabolite: 'Search a metabolite name, HMDB ID, KEGG ID, or keyword...',
}
const currentPlaceholder = computed(() => placeholders[label.value] || 'Search...')

// Confirmed-working example queries per type.
const examplesByType = {
  Study: ['ST000288', 'lipidomics', 'glucose tolerance'],
  Phenotype: ['acute myeloid leukemia', 'ulcerative colitis', 'macrophage differentiation'],
  Module: ['Arachidonic acid', 'Purine', 'Glutathione'],
  Metabolite: ['HMDB0000122', 'C00219', 'HMDB0000289'],
}
const currentExamples = computed(() => examplesByType[label.value] || [])

// Empty query = "browse everything of this type" (see api.js/backend
// handleSearch), not "no search yet" -- this drives the default view.
const isBrowsing = computed(() => query.value.trim().length === 0)

function selectLabel(value) {
  if (label.value === value) return
  label.value = value
  runSearch()
}

function tryExample(q) {
  query.value = q
  runSearch()
}

function clearQuery() {
  query.value = ''
  runSearch()
}

function onInput() {
  clearTimeout(debounceTimer)
  debounceTimer = setTimeout(() => runSearch(), 250)
}

// Guards against out-of-order results: if the user types fast enough to
// fire a second search before the first one's response lands, the first
// (now-stale) request is aborted so it can never overwrite fresher results.
let searchAbortController = null

// Keeps the URL in sync with the live search state (query/type/page) via
// router.replace (no new history entry per keystroke) so that: (1) reloading
// or sharing the URL reproduces the same view, and (2) a node detail page
// opened from a result row can carry a `returnTo` back here that actually
// still has the search typed in, instead of bouncing back to a blank /search
// -- the same problem Path Query solves with its own state persistence.
function syncUrl() {
  router.replace({
    path: '/search',
    query: {
      q: query.value.trim() || undefined,
      label: label.value,
      page: page.value > 1 ? String(page.value) : undefined,
    },
  }).catch(() => {})
}

// resetPage: true for a brand-new search (typing, switching type, an example
// click, clearing) -- false when just paging through the same result set.
async function runSearch({ resetPage = true } = {}) {
  error.value = ''
  const trimmed = query.value.trim()
  if (trimmed.length === 1) {
    // Too short to search or browse meaningfully -- wait for more input.
    results.value = []
    total.value = 0
    syncUrl()
    return
  }
  if (resetPage) page.value = 1
  syncUrl()
  searchAbortController?.abort()
  const controller = new AbortController()
  searchAbortController = controller
  loading.value = true
  try {
    const data = await searchNodes(trimmed, label.value, {
      signal: controller.signal,
      page: page.value,
      pageSize,
    })
    if (controller.signal.aborted) return
    results.value = data.results
    total.value = data.total
  } catch (e) {
    if (e.name === 'AbortError') return
    error.value = e.message
  } finally {
    if (searchAbortController === controller) loading.value = false
  }
}

// Carries the current search state back with the link so "Back to Entity
// Search" on the node detail page returns here with the query/type/page
// still intact, instead of a blank search box.
function nodeRoute(label, id) {
  return {
    path: `/node/${label}/${id}`,
    query: {
      returnTo: route.fullPath,
      returnLabel: 'Entity Search',
    },
  }
}

function goToPage(p) {
  if (p < 1 || p > totalPages.value || p === page.value) return
  page.value = p
  runSearch({ resetPage: false })
}

onMounted(() => {
  // Arriving from the homepage search bar (?q=...&label=...), a shared/
  // reloaded URL, or navigating back from a node detail page all land here
  // the same way -- restore whatever state the URL carries before searching.
  const q = route.query.q
  const l = route.query.label
  const p = route.query.page
  if (typeof l === 'string' && labelOptions.some((opt) => opt.value === l)) {
    label.value = l
  }
  if (typeof q === 'string' && q.trim().length >= 2) {
    query.value = q
  }
  const parsedPage = typeof p === 'string' ? parseInt(p, 10) : NaN
  if (Number.isFinite(parsedPage) && parsedPage > 1) {
    page.value = parsedPage
  }
  runSearch({ resetPage: false })
})
onUnmounted(() => {
  searchAbortController?.abort()
})
</script>

<style scoped>
.entity-search {
  display: flex;
  flex-direction: column;
  min-height: calc(100vh - 69px);
  background: #f7f8fa;
}
.es-container {
  max-width: none;
  margin: 0 auto;
  padding: 0 40px;
  width: min(90vw, 1680px);
  box-sizing: border-box;
}
.es-header .es-container {
  max-width: none;
}

/* ---------- header band ---------- */
.es-header {
  position: relative;
  overflow: hidden;
  background:
    radial-gradient(circle at 16% 18%, rgba(143, 215, 234, 0.3), transparent 28%),
    radial-gradient(circle at 82% 18%, rgba(79, 181, 155, 0.18), transparent 30%),
    linear-gradient(135deg, #1d5876 0%, #2d7895 52%, #245f7d 100%);
  padding: 46px 0 38px;
  border-bottom: 0;
}
.analysis-network-bg {
  position: absolute;
  inset: 0;
  opacity: 0.7;
  --network-line: rgba(210, 231, 244, 0.34);
  --network-node: rgba(216, 231, 239, 0.92);
  --network-line-width: 0.85;
}
.es-header-flex {
  position: relative;
  z-index: 1;
  display: flex;
  align-items: center;
  gap: 24px;
}
.es-header-left {
  flex: 1;
  min-width: 0;
}
.es-header h1 {
  margin: 0 0 8px;
  font-size: 36px;
  font-weight: 800;
  letter-spacing: -0.01em;
  color: #fff;
}

/* ---------- type tabs ---------- */
.type-tabs {
  display: flex;
  flex-wrap: wrap;
  gap: 8px;
  margin: 24px 0 16px;
}
.type-tab {
  display: flex;
  align-items: center;
  gap: 8px;
  padding: 8px 15px 8px 10px;
  border-radius: 999px;
  border: 1.5px solid rgba(216, 231, 239, 0.36);
  background: transparent;
  color: #eef8fa;
  font-weight: 600;
  font-size: 14px;
  cursor: pointer;
  transition: border-color 0.15s ease, background 0.15s ease, color 0.15s ease, box-shadow 0.15s ease;
}
.type-tab:hover {
  border-color: #8fd7ea;
  background: rgba(255, 255, 255, 0.08);
}
.type-tab.active {
  border-color: var(--tab-color);
  background: rgba(255, 255, 255, 0.1);
  color: #fff;
  box-shadow: none;
}
.type-tab-icon {
  width: 22px;
  height: 22px;
  border-radius: 50%;
  background: var(--tab-color);
  display: flex;
  align-items: center;
  justify-content: center;
  flex-shrink: 0;
}
.type-tab-icon svg {
  width: 13px;
  height: 13px;
}

/* ---------- search bar ---------- */
.search-bar {
  display: flex;
  align-items: center;
  max-width: 540px;
  border-radius: 999px;
  overflow: hidden;
  background: #fff;
  box-shadow: 0 14px 34px -24px rgba(4, 7, 20, 0.6);
  border: 1.5px solid rgba(226, 232, 240, 0.92);
  transition: border-color 0.15s ease;
}
.search-bar:focus-within {
  border-color: #8fd7ea;
}
.search-icon {
  width: 19px;
  height: 19px;
  color: #8b93ab;
  flex-shrink: 0;
  margin-left: 18px;
}
.search-bar input {
  flex: 1;
  border: none;
  outline: none;
  font-size: 15.5px;
  padding: 15px;
  background: transparent;
  color: #1b1f24;
  min-width: 0;
}
.search-bar input::placeholder {
  color: #a3a9c2;
}
.clear-btn {
  border: none;
  background: #eef0f7;
  color: #6b7280;
  width: 22px;
  height: 22px;
  border-radius: 50%;
  font-size: 14px;
  line-height: 1;
  cursor: pointer;
  margin-right: 14px;
  flex-shrink: 0;
}
.clear-btn:hover {
  background: #dde1f0;
}

.example-chips {
  margin-top: 12px;
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: 3px;
  font-size: 13px;
}
.chip-label {
  color: #d8e7ef;
  font-weight: 700;
  margin-right: 3px;
}
.chip {
  border: none;
  background: none;
  color: #eef8fa;
  font-size: 13px;
  font-weight: 600;
  padding: 0;
  cursor: pointer;
  text-decoration: none;
}
.chip:hover {
  color: #fff;
  text-decoration: underline;
}
.chip-sep {
  color: rgba(216, 231, 239, 0.64);
}

/* ---------- header decoration (large translucent type icon) ---------- */
.header-decoration {
  position: relative;
  display: flex;
  align-items: center;
  justify-content: center;
  margin-left: auto;
  flex-shrink: 0;
  width: 220px;
  height: 220px;
}
.decoration-blob {
  position: absolute;
  inset: 14px;
  border-radius: 50%;
  border: 2px solid rgba(238, 248, 250, 0.2);
  background: transparent;
}
.decoration-icon-img,
.decoration-icon-fallback {
  position: relative;
  width: 132px;
  height: 132px;
  opacity: 0.78;
  color: rgba(238, 248, 250, 0.86);
}
.decoration-icon-fallback {
  stroke-width: 1.35;
}

/* ---------- results ---------- */
.results-section {
  padding: 30px 40px 64px;
  flex: 1;
}
.results-meta {
  margin: 0 0 14px;
  font-size: 13px;
  font-weight: 700;
  color: #536172;
}
.results-table-wrap {
  background: #fff;
  border: 1px solid #e3ebef;
  border-top: 3px solid #8fd7ea;
  border-radius: 8px;
  overflow: hidden;
  box-shadow: 0 16px 34px -28px rgba(36, 72, 95, 0.42);
}
.results-table {
  display: grid;
  grid-template-columns: 140px 200px minmax(0, 1.6fr) minmax(0, 1.2fr) 32px;
}
.results-table-study {
  grid-template-columns: 140px 200px minmax(0, 1fr) 140px 32px;
}
.results-table-phenotype,
.results-table-metabolite {
  grid-template-columns: 140px 200px minmax(0, 1.3fr) minmax(0, 0.9fr) minmax(0, 0.9fr) 32px;
}
.table-head {
  display: contents;
}
.table-head > span {
  padding: 14px 18px;
  font-size: 12px;
  font-weight: 800;
  letter-spacing: 0.04em;
  text-transform: uppercase;
  color: #536172;
  background: #f8fbfc;
  border-bottom: 1px solid #e3ebef;
}
.table-row {
  display: contents;
  text-decoration: none;
  color: inherit;
}
.table-row > span {
  display: flex;
  align-items: center;
  padding: 15px 18px;
  border-bottom: 1px solid #edf2f5;
  font-size: 14.5px;
  color: #1b1f24;
  min-width: 0;
  overflow: hidden;
  transition: background 0.12s ease, color 0.12s ease;
}
.table-row:hover > span {
  background: #f5fbfc;
}
.table-row:last-of-type > span {
  border-bottom: none;
}
.cell-type {
  gap: 8px;
}
.cell-type::before {
  content: '';
  width: 8px;
  height: 8px;
  border-radius: 50%;
  background: var(--accent);
  flex: 0 0 auto;
}
.cell-type .badge {
  border: 1px solid color-mix(in srgb, var(--accent) 22%, transparent);
  background: color-mix(in srgb, var(--accent) 8%, #fff);
  color: var(--accent);
  font-size: 11.5px;
  padding: 3px 9px;
}
.cell-id {
  font-family: 'SFMono-Regular', Menlo, Consolas, monospace;
  font-size: 13px;
  font-weight: 400;
  color: #334155;
}
.cell-title {
  font-weight: 400;
  color: #1f2933;
  white-space: nowrap;
  text-overflow: ellipsis;
}
.cell-detail {
  color: #52606d;
  font-size: 14px;
  white-space: nowrap;
  text-overflow: ellipsis;
}
.cell-detail2 {
  font-family: 'SFMono-Regular', Menlo, Consolas, monospace;
  color: #52606d;
  font-size: 13px;
  white-space: nowrap;
  text-overflow: ellipsis;
}
.cell-arrow svg {
  width: 14px;
  height: 14px;
  color: #c3c8db;
  transition: transform 0.15s ease, color 0.15s ease;
}
.table-row:hover .cell-arrow svg {
  color: var(--accent);
  transform: translateX(2px);
}

@media (max-width: 860px) {
  .results-table-wrap {
    overflow-x: auto;
  }
  .results-table {
    grid-template-columns: 110px 160px 220px 180px 28px;
    min-width: 700px;
  }
  .results-table-study {
    grid-template-columns: 110px 160px 360px 120px 28px;
    min-width: 778px;
  }
  .results-table-phenotype,
  .results-table-metabolite {
    grid-template-columns: 110px 160px 260px 150px 150px 28px;
    min-width: 858px;
  }
}

/* ---------- state blocks (loading / empty / error) ---------- */
.state-block {
  display: flex;
  align-items: center;
  justify-content: center;
  gap: 10px;
  padding: 48px 20px;
  color: #8790b3;
  font-size: 14.5px;
  background: #fff;
  border: 1px dashed #dfe3f0;
}
.state-block svg {
  width: 20px;
  height: 20px;
  flex-shrink: 0;
}
.state-error {
  color: #c0392b;
  border-color: rgba(192, 57, 43, 0.3);
  background: rgba(192, 57, 43, 0.04);
}
.spinner {
  width: 16px;
  height: 16px;
  border-radius: 50%;
  border: 2px solid #d7dbe0;
  border-top-color: #0f7c96;
  animation: spin 0.7s linear infinite;
}
@keyframes spin {
  to { transform: rotate(360deg); }
}

/* ---------- pagination ---------- */
.pagination {
  display: flex;
  align-items: center;
  justify-content: center;
  gap: 14px;
  margin-top: 26px;
}
.page-nav {
  display: flex;
  align-items: center;
  gap: 6px;
  padding: 8px 16px;
  border-radius: 999px;
  border: 1px solid #dfe3f0;
  background: #fff;
  color: #0f7c96;
  font-weight: 600;
  font-size: 13.5px;
  cursor: pointer;
}
.page-nav svg {
  width: 14px;
  height: 14px;
}
.page-nav:hover:not(:disabled) {
  border-color: #8fd7ea;
  background: #eef8fa;
}
.page-nav:disabled {
  color: #c3c8db;
  cursor: not-allowed;
}
.page-pill {
  padding: 6px 14px;
  border-radius: 999px;
  background: #eef8fa;
  color: #0f7c96;
  font-weight: 700;
  font-size: 13px;
}

@media (max-width: 860px) {
  .header-decoration {
    display: none;
  }
}

@media (max-width: 640px) {
  .es-header { padding: 40px 0 28px; }
  .es-header h1 { font-size: 28px; }
}
</style>
