<template>
  <div class="pq">
    <!-- ============ HEADER BAND ============ -->
    <section class="pq-header">
      <div class="pq-container">
        <span class="eyebrow">Analysis</span>
        <h1>Path Query</h1>

        <div class="pq-form">
          <div class="pq-form-pickers">
            <div class="pq-picker-slot">
              <span class="pq-picker-label">From</span>
              <NodePicker :selected="from" @select="(v) => setEndpoint('from', v)" @clear="clearEndpoint('from')" />
            </div>
            <span class="pq-arrow" aria-hidden="true">
              <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                <path d="M5 12h14M13 6l6 6-6 6" />
              </svg>
            </span>
            <div class="pq-picker-slot">
              <span class="pq-picker-label">To</span>
              <NodePicker :selected="to" @select="(v) => setEndpoint('to', v)" @clear="clearEndpoint('to')" />
            </div>
          </div>

          <div class="pq-examples" aria-label="Example path queries">
            <span>Examples</span>
            <button
              v-for="demo in pathDemos"
              :key="demo.label"
              type="button"
              class="pq-example"
              @click="applyDemo(demo)"
            >
              {{ demo.label }}
            </button>
          </div>

          <div class="pq-form-controls">
            <label class="pq-hops">
              Within
              <select
                v-model.number="maxHops"
                @change="clampHops"
              >
                <option v-for="hop in hopOptions" :key="hop" :value="hop">
                  {{ hop }}
                </option>
              </select>
              hops
            </label>
            <button class="pq-submit" :disabled="!from || !to || loading" @click="search">
              {{ loading ? 'Searching...' : 'Find connections' }}
            </button>
          </div>
        </div>
      </div>
    </section>

    <!-- ============ RESULTS ============ -->
    <section class="pq-container pq-results">
      <div v-if="error" class="state-block state-error">
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
          <circle cx="12" cy="12" r="9" /><path d="M12 8v5M12 16h.01" />
        </svg>
        <span>{{ error }}</span>
      </div>

      <div v-else-if="searched && !loading && graph && graph.hops === null" class="state-block state-empty">
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6">
          <circle cx="11" cy="11" r="7" />
          <line x1="21" y1="21" x2="16.65" y2="16.65" />
        </svg>
        <span>
          No connection found within {{ maxHops }} hops.
          <template v-if="graph.truncated">
            One (or both) of these nodes has too large a neighborhood to fully check -- this search stopped early
            rather than finish, so a connection may still exist that just wasn't reached. Picking a more specific
            endpoint (e.g. a Module instead of a Phenotype or Study) usually narrows the search enough to complete.
          </template>
        </span>
      </div>

      <template v-else>
        <div v-if="layout" class="pq-meta">
          <span v-if="graph.hops !== null" class="pq-meta-hops">
            Shortest connection: {{ graph.hops }} hop{{ graph.hops === 1 ? '' : 's' }}
          </span>
          <span v-if="graph.truncated" class="pq-meta-truncated">
            Showing a limited subset -- these nodes are very well connected, so not everything within range is drawn.
          </span>
        </div>

        <div class="pq-tabs">
          <button type="button" class="pq-tab" :class="{ active: activeTab === 'visual' }" @click="activeTab = 'visual'">
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8">
              <circle cx="6" cy="6" r="2.3" />
              <circle cx="18" cy="8" r="2.3" />
              <circle cx="10" cy="18" r="2.3" />
              <path d="M8 7.1 15.7 7.9M8.6 8.1 9.5 16" />
            </svg>
            Visualization
          </button>
          <button
            type="button"
            class="pq-tab"
            :class="{ active: activeTab === 'table' }"
            :disabled="!layout"
            @click="activeTab = 'table'"
          >
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round">
              <path d="M9 6h11M9 12h11M9 18h11M4 6h.01M4 12h.01M4 18h.01" />
            </svg>
            Connections
            <span class="pq-tab-count">{{ pathChains.chains.length }}</span>
          </button>
        </div>

        <div
          v-show="activeTab === 'visual'"
          ref="graphPanelRef"
          class="card graph-panel"
          @pointerleave="hideGraphTooltip"
        >
          <div v-if="!layout" class="graph-empty">
            <div class="empty-state">
              <div class="empty-icon" aria-hidden="true">
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6">
                  <circle cx="5" cy="6" r="2.2" />
                  <circle cx="19" cy="6" r="2.2" />
                  <circle cx="12" cy="18" r="2.2" />
                  <path d="M7 6.9 17 6.9M6.4 8 11 16.4M17.6 8 13 16.4" />
                </svg>
              </div>
              <p class="empty-kicker">Path query workflow</p>
              <ol class="empty-steps">
                <li>
                  <span class="empty-step-num">1</span>
                  <div class="empty-step-copy">
                    <strong>Choose endpoint types.</strong>
                    <span>Select the type for each side of the path, such as Phenotype, Study, or Module.</span>
                  </div>
                </li>
                <li>
                  <span class="empty-step-num">2</span>
                  <div class="empty-step-copy">
                    <strong>Search by name or ID.</strong>
                    <span>Use each search box to find the exact starting and ending entity you want to connect.</span>
                  </div>
                </li>
                <li>
                  <span class="empty-step-num">3</span>
                  <div class="empty-step-copy">
                    <strong>Select the hop range.</strong>
                    <span>Choose how many relationship steps the query may explore between the two endpoints.</span>
                  </div>
                </li>
                <li>
                  <span class="empty-step-num">4</span>
                  <div class="empty-step-copy">
                    <strong>Find connections.</strong>
                    <span>Run the query to render the network and inspect the connection paths below.</span>
                  </div>
                </li>
              </ol>
            </div>
          </div>

          <svg
            v-else
            class="graph-svg"
            :viewBox="`0 0 ${layout.size} ${layout.size}`"
            :width="layout.size"
            :height="layout.size"
          >
            <g
              v-for="(e, i) in layout.edges"
              :key="'e' + i"
              class="graph-edge-group"
              @pointerenter="showEdgeTooltip(e, $event)"
              @pointermove="moveGraphTooltip($event)"
              @pointerleave="hideGraphTooltip"
            >
              <path
                :d="e.path"
                class="graph-edge"
                :class="{ shortest: e.onShortestPath, hovered: graphTooltip.id === e.key }"
                :style="{ strokeWidth: e.strokeWidth, strokeOpacity: graphTooltip.id === e.key ? 0.95 : e.opacity }"
              />
              <path
                :d="e.path"
                class="graph-edge-hit"
              />
            </g>
            <g
              v-for="n in layout.nodes"
              :key="n.id"
              class="graph-node"
              :class="{ endpoint: n.isEndpoint, hovered: graphTooltip.id === n.id }"
              @pointerenter="showNodeTooltip(n, $event)"
              @pointermove="moveGraphTooltip($event)"
              @pointerleave="hideGraphTooltip"
              @click="goTo(n)"
            >
              <circle v-if="n.isEndpoint" :cx="n.x" :cy="n.y" :r="n.r + 4" class="endpoint-ring" :style="{ stroke: n.color }" />
              <circle :cx="n.x" :cy="n.y" :r="n.r + 8" class="node-hover-halo" :style="{ fill: n.color }" />
              <circle :cx="n.x" :cy="n.y" :r="n.r" :fill="n.color" class="graph-node-dot" />
              <text v-if="n.isEndpoint" :x="n.x" :y="n.y - n.r - 8" class="graph-label endpoint">{{ n.name || n.id }}</text>
            </g>
          </svg>

          <div
            v-if="graphTooltip.visible"
            class="graph-tooltip"
            :style="{ left: `${graphTooltip.x}px`, top: `${graphTooltip.y}px`, '--tooltip-color': graphTooltip.color }"
          >
            <div class="tooltip-kicker">{{ graphTooltip.kind }}</div>
            <div class="tooltip-title">{{ graphTooltip.title }}</div>
            <dl>
              <template v-for="row in graphTooltip.rows" :key="row.label">
                <dt>{{ row.label }}</dt>
                <dd>{{ row.value }}</dd>
              </template>
            </dl>
          </div>

          <div class="graph-legend">
            <span v-for="lab in legendLabels" :key="lab">
              <i class="dot" :style="{ background: typeColor(lab) }"></i>{{ lab }}
            </span>
            <span class="legend-line"><i class="line shortest"></i>on shortest connection</span>
            <span class="legend-line"><i class="line"></i>other connection</span>
          </div>
        </div>

        <div v-if="layout" v-show="activeTab === 'table'" class="card edges-panel">
          <div v-if="!pathChains.chains.length" class="state-block state-empty chains-empty">
            <span>No connecting routes to show.</span>
          </div>

          <div v-else class="connections-toolbar">
            <span class="connections-range">
              Showing {{ connectionRangeStart }}-{{ connectionRangeEnd }} of {{ totalConnectionCount }} connections
            </span>
            <label class="connections-size">
              Per page
              <select v-model.number="connectionPageSize">
                <option v-for="size in connectionPageSizeOptions" :key="size" :value="size">{{ size }}</option>
              </select>
            </label>
            <div class="connections-pager" aria-label="Connections pagination">
              <button type="button" :disabled="connectionPage <= 1" @click="setConnectionPage(connectionPage - 1)">
                Previous
              </button>
              <label>
                Page
                <select v-model.number="connectionPage">
                  <option v-for="page in connectionPageCount" :key="page" :value="page">{{ page }}</option>
                </select>
                of {{ connectionPageCount }}
              </label>
              <button type="button" :disabled="connectionPage >= connectionPageCount" @click="setConnectionPage(connectionPage + 1)">
                Next
              </button>
            </div>
          </div>

          <div v-for="(chain, ci) in paginatedChains" :key="connectionRangeStart + ci" class="chain-block">
            <span class="chain-label">
              {{ chain.steps.length }} hop{{ chain.steps.length === 1 ? '' : 's' }}
              <span v-if="graph.hops !== null && chain.steps.length === graph.hops" class="shortest-tag">shortest</span>
            </span>
            <div class="chain-row">
              <router-link
                :to="nodeRoute(nodeInfo(chain.start).label, chain.start)"
                class="chain-node"
                :style="{ '--node-color': typeColor(nodeInfo(chain.start).label) }"
                @click="persistPathState()"
              >
                <span class="badge small">{{ nodeInfo(chain.start).label }}</span>
                {{ nodeInfo(chain.start).name || chain.start }}
              </router-link>
              <template v-for="(step, i) in chain.steps" :key="i">
                <span class="chain-arrow">
                  <svg viewBox="0 0 30 10" fill="none" stroke="currentColor" stroke-width="1.6">
                    <path d="M0 5h24M18 1l6 4-6 4" />
                  </svg>
                  <span class="chain-rel">{{ chainRelLabel(step.edge, step.forward) }}</span>
                </span>
                <router-link
                  :to="nodeRoute(nodeInfo(step.node).label, step.node)"
                  class="chain-node"
                  :style="{ '--node-color': typeColor(nodeInfo(step.node).label) }"
                  @click="persistPathState()"
                >
                  <span class="badge small">{{ nodeInfo(step.node).label }}</span>
                  {{ nodeInfo(step.node).name || step.node }}
                </router-link>
              </template>
            </div>
          </div>

        </div>
      </template>
    </section>
  </div>
</template>

<script setup>
import { ref, computed, onMounted, watch } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import NodePicker from '../components/NodePicker.vue'
import { findPathGraph } from '../api.js'

const router = useRouter()
const route = useRoute()
const pathGraphCache =
  window.__phenomapPathGraphCache || (window.__phenomapPathGraphCache = new Map())

const from = ref(null)
const to = ref(null)
const defaultMaxHops = 5
const maxSelectableHops = 10
const hopOptions = Array.from({ length: maxSelectableHops }, (_, i) => i + 1)
const maxHops = ref(defaultMaxHops)
const graph = ref(null)
const loading = ref(false)
const error = ref('')
const searched = ref(false)
const activeTab = ref('visual')
const connectionPageSizeOptions = [10, 25, 50]
const connectionPage = ref(1)
const connectionPageSize = ref(10)
const graphPanelRef = ref(null)
const graphTooltip = ref({
  visible: false,
  id: '',
  kind: '',
  title: '',
  rows: [],
  x: 16,
  y: 16,
  color: '#3949ab',
})

function pathCacheKey(fromNode = from.value, toNode = to.value, hops = maxHops.value) {
  if (!fromNode || !toNode) return ''
  return [fromNode.label, fromNode.id, toNode.label, toNode.id, hops].join('|')
}

function compactCache() {
  const maxEntries = 6
  while (pathGraphCache.size > maxEntries) {
    const oldest = pathGraphCache.keys().next().value
    pathGraphCache.delete(oldest)
  }
}

function persistPathState({ replaceRoute = false } = {}) {
  if (!from.value || !to.value) return
  const key = pathCacheKey()
  pathGraphCache.set(key, {
    from: { ...from.value },
    to: { ...to.value },
    maxHops: maxHops.value,
    graph: graph.value,
    searched: searched.value,
    activeTab: activeTab.value,
    connectionPage: connectionPage.value,
    connectionPageSize: connectionPageSize.value,
  })
  compactCache()

  if (!replaceRoute) return
  void router.replace({
    path: '/path',
    query: {
      from_label: from.value.label,
      from_id: from.value.id,
      from_name: from.value.name || from.value.id,
      to_label: to.value.label,
      to_id: to.value.id,
      to_name: to.value.name || to.value.id,
      max_hops: String(maxHops.value),
    },
  }).catch(() => {})
}

function restorePathState() {
  const q = route.query
  // Only restore from the URL's own query params -- e.g. the exact
  // /path?from_label=...&to_id=... link that a node detail page's "Back to
  // Path Query" carries (see nodeRoute/persistPathState -- that link's
  // returnTo is captured from route.fullPath *after* the query params are
  // synced in, so it always has them). Landing on a bare /path -- nav bar,
  // the homepage card, a typed URL -- should always start from a clean
  // slate. Previously this fell back to whatever was last searched
  // (window.__phenomapLastPathGraphKey) any time those params were missing,
  // which meant navigating to /path from *anywhere* kept showing old
  // results, not just when actually returning from a node page.
  if (!q.from_label || !q.from_id || !q.to_label || !q.to_id) return
  const restoredFrom = {
    label: String(q.from_label),
    id: String(q.from_id),
    name: String(q.from_name || q.from_id),
  }
  const restoredTo = {
    label: String(q.to_label),
    id: String(q.to_id),
    name: String(q.to_name || q.to_id),
  }
  const restoredHops = Number(q.max_hops || defaultMaxHops)
  from.value = restoredFrom
  to.value = restoredTo
  maxHops.value = Number.isFinite(restoredHops) ? restoredHops : defaultMaxHops
  clampHops()

  const cached = pathGraphCache.get(pathCacheKey(restoredFrom, restoredTo, maxHops.value))
  if (!cached) return
  graph.value = cached.graph
  searched.value = cached.searched
  activeTab.value = cached.activeTab || 'visual'
  connectionPage.value = cached.connectionPage || 1
  connectionPageSize.value = cached.connectionPageSize || 10
}

const pathDemos = [
  {
    label: '#1',
    hops: 5,
    from: { label: 'Phenotype', id: 'PMAP_PHENO_000131', name: 'ulcerative colitis' },
    to: { label: 'Phenotype', id: 'PMAP_PHENO_000082', name: 'macrophage differentiation' },
  },
  {
    label: '#2',
    hops: 3,
    from: { label: 'Study', id: 'PMAP_STUDY_000132', name: 'ST003865' },
    to: { label: 'Study', id: 'PMAP_STUDY_000151', name: 'ST004308' },
  },
  {
    label: '#3',
    hops: 5,
    from: { label: 'Phenotype', id: 'PMAP_PHENO_000061', name: 'hepatocellular carcinoma' },
    to: { label: 'Phenotype', id: 'PMAP_PHENO_000046', name: 'estrogen-receptor positive breast cancer' },
  },
  {
    label: '#4',
    hops: 3,
    from: { label: 'Phenotype', id: 'PMAP_PHENO_000131', name: 'ulcerative colitis' },
    to: { label: 'Module', id: 'PMAP_MOUDLE_001855', name: 'Bacterial cell wall biosynthesis and shikimate pathway' },
  },
]

// The UI exposes a dropdown, while the backend clamps independently so direct
// API callers cannot request a wider traversal than the supported range.
function clampHops() {
  if (!Number.isFinite(maxHops.value)) {
    maxHops.value = defaultMaxHops
    return
  }
  maxHops.value = Math.min(maxSelectableHops, Math.max(1, Math.round(maxHops.value)))
}

function applyDemo(demo) {
  from.value = { ...demo.from }
  to.value = { ...demo.to }
  maxHops.value = demo.hops
  graph.value = null
  error.value = ''
  searched.value = false
  activeTab.value = 'visual'
  connectionPage.value = 1
  persistPathState({ replaceRoute: true })
}

function setEndpoint(which, value) {
  if (which === 'from') {
    from.value = value
  } else {
    to.value = value
  }
  graph.value = null
  error.value = ''
  searched.value = false
  activeTab.value = 'visual'
  connectionPage.value = 1
}

function clearEndpoint(which) {
  if (which === 'from') {
    from.value = null
  } else {
    to.value = null
  }
  graph.value = null
  error.value = ''
  searched.value = false
  activeTab.value = 'visual'
  connectionPage.value = 1
}

async function search() {
  if (!from.value || !to.value) return
  clampHops()
  loading.value = true
  error.value = ''
  searched.value = true
  graph.value = null
  activeTab.value = 'visual'
  connectionPage.value = 1
  try {
    graph.value = await findPathGraph(from.value, to.value, maxHops.value)
    persistPathState({ replaceRoute: true })
  } catch (e) {
    error.value = e.message
    graph.value = null
  } finally {
    loading.value = false
  }
}

watch(activeTab, () => {
  if (graph.value) persistPathState()
})

onMounted(() => {
  restorePathState()
})

// Same accent colors used across Entity Search / node detail pages, so this
// graph reads as a continuation of the same site rather than a different
// visual language.
const typeColors = { Study: '#3949ab', Phenotype: '#b3562c', Module: '#1a8f5e', Metabolite: '#0f7c96' }
function typeColor(label) {
  return typeColors[label] || '#6b7280'
}

function clamp01(v) {
  return Math.max(0, Math.min(1, v))
}

const NODE_R = 7
const ENDPOINT_R = 11
const GRAPH_MARGIN = 46
const GRAPH_CANVAS_SIZE = 1000
const GRAPH_VERTICAL_MARGIN = 92

function buildGraphAdjacency(nodeIds, edges) {
  const adj = new Map(nodeIds.map((id) => [id, []]))
  for (const e of edges) {
    if (!adj.has(e.from)) adj.set(e.from, [])
    if (!adj.has(e.to)) adj.set(e.to, [])
    adj.get(e.from).push(e.to)
    adj.get(e.to).push(e.from)
  }
  return adj
}

function bfsDistances(seedId, adj) {
  const dist = new Map([[seedId, 0]])
  const queue = [seedId]
  while (queue.length) {
    const cur = queue.shift()
    for (const next of adj.get(cur) || []) {
      if (dist.has(next)) continue
      dist.set(next, dist.get(cur) + 1)
      queue.push(next)
    }
  }
  return dist
}

function layeredPathPositions(nodeIds, edges, infoById, fromId, toId, size) {
  const adj = buildGraphAdjacency(nodeIds, edges)
  const distFrom = bfsDistances(fromId, adj)
  const distTo = bfsDistances(toId, adj)
  const left = GRAPH_MARGIN + 24
  const right = size - GRAPH_MARGIN - 24
  const centerY = size / 2
  const usableY = size - GRAPH_VERTICAL_MARGIN * 2
  const layers = new Map()

  for (const id of nodeIds) {
    let progress = 0.5
    if (id === fromId) {
      progress = 0
    } else if (id === toId) {
      progress = 1
    } else {
      const df = distFrom.get(id)
      const dt = distTo.get(id)
      if (Number.isFinite(df) && Number.isFinite(dt) && df + dt > 0) {
        progress = df / (df + dt)
      }
      progress = Math.max(0.08, Math.min(0.92, progress))
    }
    const key = progress.toFixed(3)
    if (!layers.has(key)) layers.set(key, { progress, ids: [] })
    layers.get(key).ids.push(id)
  }

  const positions = new Map()
  Array.from(layers.values())
    .sort((a, b) => a.progress - b.progress)
    .forEach((layer) => {
      layer.ids.sort((a, b) => {
        const ia = infoById.get(a) || {}
        const ib = infoById.get(b) || {}
        return `${ia.label || ''}:${ia.name || a}`.localeCompare(`${ib.label || ''}:${ib.name || b}`)
      })
      const n = layer.ids.length
      const spacing = n <= 1 ? 0 : Math.min(86, usableY / (n - 1))
      const startY = centerY - (spacing * (n - 1)) / 2
      layer.ids.forEach((id, index) => {
        positions.set(id, {
          x: left + (right - left) * layer.progress,
          y: n === 1 ? centerY : startY + spacing * index,
        })
      })
    })

  return positions
}

function edgeCurvePath(a, b) {
  const dx = b.x - a.x
  const bend = Math.max(42, Math.abs(dx) * 0.5)
  const c1x = a.x + (dx >= 0 ? bend : -bend)
  const c2x = b.x - (dx >= 0 ? bend : -bend)
  return `M ${a.x} ${a.y} C ${c1x} ${a.y}, ${c2x} ${b.y}, ${b.x} ${b.y}`
}

function edgeIdentity(e) {
  return `${e.from}|${e.to}|${e.type}|${JSON.stringify(e.props || {})}`
}

// Reconstructs fromId->toId routes through the returned graph as ordered
// sequences of (node, relationship) steps -- for the "Study A
// --REPORTED_IN--> Module A --SIMILAR_TO--> Module B --REPORTED_IN-->
// Study B" style chains in the Connections tab, not just the shortest one.
// This runs in two stages rather than one general search so true shortest
// routes are always found first and shown distinctly, while longer simple
// routes are still enumerated completely within maxHops.
//
// Stage 1, findShortestChains, is restricted to edges the backend already
// flagged on_shortest_path and layered by BFS distance from fromId. Walking
// it forward-only enumerates every true shortest route with no backtracking.
//
// Stage 2, findLongerChains, does general DFS backtracking over every edge,
// restricted to simple routes strictly longer than the shortest and no
// longer than maxHops. It intentionally has no route-count or step-count cap
// so the Connections tab preserves scientific completeness for the returned
// graph.
function findShortestChains(fromId, toId, edges) {
  const adj = new Map()
  for (const e of edges) {
    if (!e.on_shortest_path) continue
    if (!adj.has(e.from)) adj.set(e.from, [])
    if (!adj.has(e.to)) adj.set(e.to, [])
    adj.get(e.from).push({ to: e.to, edge: e })
    adj.get(e.to).push({ to: e.from, edge: e })
  }

  const dist = new Map([[fromId, 0]])
  const queue = [fromId]
  while (queue.length) {
    const cur = queue.shift()
    for (const { to: next } of adj.get(cur) || []) {
      if (dist.has(next)) continue
      dist.set(next, dist.get(cur) + 1)
      queue.push(next)
    }
  }
  if (!dist.has(toId)) return []

  const chains = []
  const path = []
  function walk(node) {
    if (node === toId) {
      chains.push({ start: fromId, steps: [...path] })
      return
    }
    for (const { to: next, edge } of adj.get(node) || []) {
      if (dist.get(next) !== dist.get(node) + 1) continue
      // edge.from/edge.to still carry Neo4j's stored direction for this
      // relationship, even though adjacency itself is undirected -- forward
      // here means this hop walks with that stored direction, so the
      // Connections tab can show "reported in" vs. "reports" correctly
      // instead of the same label regardless of which way it's being read.
      path.push({ node: next, edge, forward: edge.from === node })
      walk(next)
      path.pop()
    }
  }
  walk(fromId)
  return chains
}

function findLongerChains(fromId, toId, edges, minLen, maxLen) {
  const adj = new Map()
  for (const e of edges) {
    if (!adj.has(e.from)) adj.set(e.from, [])
    if (!adj.has(e.to)) adj.set(e.to, [])
    adj.get(e.from).push({ to: e.to, edge: e })
    adj.get(e.to).push({ to: e.from, edge: e })
  }

  const chains = []
  const visited = new Set([fromId])
  const path = []

  function dfs(node) {
    if (node === toId) {
      if (path.length > minLen) chains.push({ start: fromId, steps: [...path] })
      return
    }
    if (path.length >= maxLen) return
    for (const { to: next, edge } of adj.get(node) || []) {
      if (visited.has(next)) continue
      visited.add(next)
      path.push({ node: next, edge, forward: edge.from === node })
      dfs(next)
      path.pop()
      visited.delete(next)
    }
  }
  dfs(fromId)
  return chains
}

const pathChains = computed(() => {
  if (!graph.value || graph.value.hops == null) return { chains: [] }
  const fromId = from.value?.id
  const toId = to.value?.id
  if (!fromId || !toId || fromId === toId) return { chains: [] }

  const shortest = findShortestChains(fromId, toId, graph.value.edges)
  const longer = findLongerChains(fromId, toId, graph.value.edges, graph.value.hops, maxHops.value)

  const chains = [...shortest, ...longer].sort((a, b) => a.steps.length - b.steps.length)
  return { chains }
})

const totalConnectionCount = computed(() => pathChains.value.chains.length)
const connectionPageCount = computed(() => Math.max(1, Math.ceil(totalConnectionCount.value / connectionPageSize.value)))
const connectionRangeStart = computed(() => {
  if (!totalConnectionCount.value) return 0
  return (connectionPage.value - 1) * connectionPageSize.value + 1
})
const connectionRangeEnd = computed(() => {
  if (!totalConnectionCount.value) return 0
  return Math.min(totalConnectionCount.value, connectionPage.value * connectionPageSize.value)
})
const paginatedChains = computed(() => {
  const start = (connectionPage.value - 1) * connectionPageSize.value
  return pathChains.value.chains.slice(start, start + connectionPageSize.value)
})

function setConnectionPage(page) {
  connectionPage.value = Math.min(connectionPageCount.value, Math.max(1, Math.round(page)))
  persistPathState()
}

function clampConnectionPage() {
  if (!connectionPageSizeOptions.includes(connectionPageSize.value)) {
    connectionPageSize.value = 10
  }
  setConnectionPage(connectionPage.value)
}

watch([totalConnectionCount, connectionPageSize], clampConnectionPage)

function buildConnectionSubgraph(sourceGraph, chains) {
  if (!sourceGraph || !chains?.length) return { nodes: [], edges: [] }
  const nodeIds = new Set()
  const edgeIds = new Set()
  const edges = []

  for (const chain of chains) {
    nodeIds.add(chain.start)
    for (const step of chain.steps) {
      nodeIds.add(step.node)
      const key = edgeIdentity(step.edge)
      if (edgeIds.has(key)) continue
      edgeIds.add(key)
      edges.push(step.edge)
    }
  }

  return {
    nodes: sourceGraph.nodes.filter((n) => nodeIds.has(n.id)),
    edges,
  }
}

const connectionSubgraph = computed(() => buildConnectionSubgraph(graph.value, pathChains.value.chains))

// Lays out only the routes shown in the Connections tab. The backend may
// return extra traversal context when maxHops is wider than the shortest
// route; drawing that raw exploration graph makes the visible path appear
// broken. Path Query is an endpoint-to-endpoint task, so the canvas mirrors
// the actual connection paths and keeps them layered left-to-right.
const layout = computed(() => {
  const visualGraph = connectionSubgraph.value
  if (!visualGraph.nodes?.length) return null
  const nodeIds = visualGraph.nodes.map((n) => n.id)
  const size = GRAPH_CANVAS_SIZE

  const infoById = new Map(visualGraph.nodes.map((n) => [n.id, n]))
  const fromId = from.value?.id
  const toId = to.value?.id
  const positions = layeredPathPositions(nodeIds, visualGraph.edges, infoById, fromId, toId, size)

  const nodeById = new Map()
  const nodes = nodeIds.map((id) => {
    const info = infoById.get(id)
    const pt = positions.get(id)
    const isEndpoint = id === fromId || id === toId
    const n = {
      id,
      label: info.label,
      name: info.name || info.id,
      x: pt.x,
      y: pt.y,
      r: isEndpoint ? ENDPOINT_R : NODE_R,
      color: typeColor(info.label),
      isEndpoint,
    }
    nodeById.set(id, n)
    return n
  })

  const edges = visualGraph.edges
    .map((e, i) => {
      const na = nodeById.get(e.from)
      const nb = nodeById.get(e.to)
      if (!na || !nb) return null
      const w = clamp01(e.weight)
      return {
        key: `${e.from}:${e.to}:${e.type}:${i}`,
        from: e.from,
        to: e.to,
        x1: na.x,
        y1: na.y,
        x2: nb.x,
        y2: nb.y,
        path: edgeCurvePath(na, nb),
        type: e.type,
        props: e.props || {},
        weight: w,
        onShortestPath: e.on_shortest_path,
        strokeWidth: e.on_shortest_path ? 1.9 + w * 1.5 : 0.75 + w * 1.05,
        opacity: e.on_shortest_path ? 0.86 : 0.16 + w * 0.3,
        scoreLabel: formatEdgeScore(e),
      }
    })
    .filter(Boolean)

  return { nodes, edges, size }
})

watch(layout, (currentLayout) => {
  if (!currentLayout && activeTab.value === 'table') {
    activeTab.value = 'visual'
  }
})

const legendLabels = computed(() => {
  if (!layout.value) return []
  const seen = new Set(layout.value.nodes.map((n) => n.label))
  return ['Study', 'Phenotype', 'Module', 'Metabolite'].filter((l) => seen.has(l))
})

const nodeInfoMap = computed(() => new Map((graph.value?.nodes || []).map((n) => [n.id, n])))
function nodeInfo(id) {
  return nodeInfoMap.value.get(id) || { label: '', name: id }
}

function moveGraphTooltip(event) {
  const panel = graphPanelRef.value
  if (!panel) return
  const rect = panel.getBoundingClientRect()
  const width = 310
  const height = 176
  graphTooltip.value.x = Math.max(12, Math.min(event.clientX - rect.left + 16, rect.width - width))
  graphTooltip.value.y = Math.max(12, Math.min(event.clientY - rect.top + 16, rect.height - height))
}

function showNodeTooltip(node, event) {
  graphTooltip.value = {
    ...graphTooltip.value,
    visible: true,
    id: node.id,
    kind: node.label,
    title: node.name || node.id,
    color: node.color,
    rows: [
      { label: 'ID', value: node.id },
      { label: 'Type', value: node.label },
      { label: 'Role', value: node.isEndpoint ? 'Selected endpoint' : 'Intermediate node' },
    ],
  }
  moveGraphTooltip(event)
}

function showEdgeTooltip(edge, event) {
  const fromNode = nodeInfo(edge.from)
  const toNode = nodeInfo(edge.to)
  const rows = [
    { label: 'From', value: fromNode.name || edge.from },
    { label: 'To', value: toNode.name || edge.to },
    { label: 'Relation', value: formatRelType(edge.type) },
  ]
  if (edge.type === 'SIMILAR_TO' && edge.props?.Similarity_Score != null) {
    rows.push({ label: 'Score', value: Number(edge.props.Similarity_Score).toFixed(3) })
  }
  rows.push({ label: 'Route', value: edge.onShortestPath ? 'On shortest connection' : 'Within selected hop range' })

  graphTooltip.value = {
    ...graphTooltip.value,
    visible: true,
    id: edge.key,
    kind: 'Relationship',
    title: formatRelType(edge.type),
    color: edge.onShortestPath ? '#64748b' : '#7a83a3',
    rows,
  }
  moveGraphTooltip(event)
}

function hideGraphTooltip() {
  graphTooltip.value.visible = false
  graphTooltip.value.id = ''
}

function formatRelType(type) {
  return type
    .toLowerCase()
    .split('_')
    .map((w) => w[0].toUpperCase() + w.slice(1))
    .join(' ')
}

// Same forward/backward phrasing as the "About PhenoMAP" schema diagram on
// the homepage, so a relationship reads the same way everywhere it shows up.
// SIMILAR_TO and CONNECTED_WITH connect two nodes of the same type, so
// there's no meaningful forward/backward distinction -- one phrase covers
// both directions.
const relLabels = {
  REPORTED_IN: { fwd: 'reported in', bwd: 'reports' },
  MEMBER_OF: { fwd: 'member of', bwd: 'has member' },
  INVESTIGATED: { fwd: 'investigates', bwd: 'investigated in' },
  SIMILAR_TO: { fwd: 'similar to', bwd: 'similar to' },
  CONNECTED_WITH: { fwd: 'connected with', bwd: 'connected with' },
}

// Connections-tab chains can walk a given edge in either direction relative
// to how Neo4j actually stored it (edge.from/edge.to), so the same
// REPORTED_IN edge needs to read as "reported in" one way and "reports" the
// other -- formatRelType alone can't tell those apart.
function chainRelLabel(edge, forward) {
  const pair = relLabels[edge.type]
  if (!pair) return formatRelType(edge.type)
  return forward ? pair.fwd : pair.bwd
}

function formatEdgeScore(e) {
  if (e.type === 'SIMILAR_TO' && e.props?.Similarity_Score != null) {
    return ` (${Number(e.props.Similarity_Score).toFixed(2)})`
  }
  if (e.type === 'MEMBER_OF' && e.props?.Type) {
    return ` (${e.props.Type})`
  }
  return ''
}

function goTo(n) {
  persistPathState()
  router.push(nodeRoute(n.label, n.id))
}

function nodeRoute(label, id) {
  return {
    path: `/node/${encodeURIComponent(label)}/${encodeURIComponent(id)}`,
    query: {
      returnTo: route.fullPath,
      returnLabel: 'Path Query',
    },
  }
}
</script>

<style scoped>
.pq {
  min-height: calc(100vh - 69px);
  background: #f7f8fa;
}
.pq-container {
  max-width: 1280px;
  margin: 0 auto;
  padding: 0 40px;
  width: 100%;
  box-sizing: border-box;
}

/* ---------- header band ---------- */
.pq-header {
  background:
    radial-gradient(circle at 14% 20%, rgba(143, 215, 234, 0.24), transparent 28%),
    radial-gradient(circle at 86% 18%, rgba(79, 181, 155, 0.14), transparent 32%),
    linear-gradient(135deg, #123a55 0%, #245c7e 52%, #174564 100%);
  padding: 48px 0 36px;
  border-bottom: 0;
}
.eyebrow {
  display: inline-block;
  font-size: 12.5px;
  font-weight: 700;
  letter-spacing: 0.08em;
  text-transform: uppercase;
  color: #8fd7ea;
  background: rgba(34, 211, 238, 0.12);
  border: 1px solid rgba(34, 211, 238, 0.3);
  padding: 5px 14px;
  border-radius: 999px;
}
.pq-header h1 {
  margin: 14px 0 26px;
  font-size: 36px;
  font-weight: 800;
  letter-spacing: -0.01em;
  color: #fff;
}

/* ---------- picker + controls form ---------- */
.pq-form {
  background: #fff;
  border: 1px solid rgba(226, 232, 240, 0.92);
  border-radius: 12px;
  padding: 26px 28px;
  box-shadow: 0 18px 42px -30px rgba(4, 7, 20, 0.65);
}
.pq-form-pickers {
  display: flex;
  align-items: flex-end;
  gap: 22px;
}
.pq-picker-slot {
  flex: 1;
  min-width: 0;
}
.pq-picker-label {
  display: block;
  font-size: 12px;
  font-weight: 700;
  letter-spacing: 0.05em;
  text-transform: uppercase;
  color: #9aa1c2;
  margin-bottom: 6px;
}
.pq-arrow {
  flex-shrink: 0;
  display: flex;
  align-items: center;
  justify-content: center;
  width: 38px;
  height: 38px;
  color: #8fd7ea;
  margin-bottom: 4px;
}
.pq-arrow svg {
  width: 24px;
  height: 24px;
}
.pq-examples {
  display: flex;
  align-items: center;
  flex-wrap: wrap;
  gap: 8px;
  margin-top: 18px;
}
.pq-examples span {
  font-size: 12px;
  font-weight: 700;
  letter-spacing: 0.04em;
  text-transform: uppercase;
  color: #9aa1c2;
  margin-right: 2px;
}
.pq-example {
  min-width: 38px;
  padding: 6px 9px;
  border-radius: 8px;
  border: 1px solid #dfe3f0;
  background: #ffffff;
  color: #0f7c96;
  font-size: 13px;
  font-weight: 700;
  cursor: pointer;
}
.pq-example:hover {
  border-color: #0f7c96;
  background: #eef8fa;
}
.pq-form-controls {
  display: flex;
  align-items: center;
  gap: 18px;
  margin-top: 20px;
  padding-top: 20px;
  border-top: 1px solid #eef0f7;
}
.pq-hops {
  display: flex;
  align-items: center;
  gap: 8px;
  font-size: 14.5px;
  font-weight: 600;
  color: #55607a;
}
.pq-hops select {
  width: 72px;
  padding: 8px 9px;
  border-radius: 8px;
  border: 1px solid #d7dbe0;
  background: #ffffff;
  font-size: 14.5px;
  font-weight: 700;
  color: #1b1f24;
}
.pq-hops select:focus {
  outline: none;
  border-color: #0f7c96;
}
.pq-submit {
  margin-left: auto;
  padding: 12px 24px;
  border-radius: 10px;
  border: none;
  background: #245c7e;
  color: #fff;
  font-weight: 700;
  font-size: 15px;
  cursor: pointer;
}
.pq-submit:hover:not(:disabled) {
  background: #174564;
}
.pq-submit:disabled {
  background: #c3c8e0;
  cursor: not-allowed;
}

/* ---------- results ---------- */
.pq-results {
  padding: 36px 40px 72px;
}
.state-block {
  display: flex;
  align-items: flex-start;
  gap: 10px;
  padding: 18px 20px;
  border-radius: 12px;
  background: #fff;
  border: 1px solid #e6e9f5;
  color: #6b7280;
  font-size: 14.5px;
  line-height: 1.6;
}
.state-block svg {
  width: 20px;
  height: 20px;
  flex-shrink: 0;
  margin-top: 1px;
}
.state-error {
  color: #c0392b;
  border-color: rgba(192, 57, 43, 0.25);
}
.pq-meta {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: 14px;
  margin-bottom: 14px;
  font-size: 13.5px;
  font-weight: 600;
  color: #3a3f4a;
}
.pq-meta-truncated {
  font-weight: 500;
  color: #b3562c;
}

/* ---------- tabs ---------- */
.pq-tabs {
  display: flex;
  gap: 6px;
  margin-bottom: 16px;
}
.pq-tab {
  display: flex;
  align-items: center;
  gap: 7px;
  padding: 9px 16px;
  border-radius: 10px;
  border: 1.5px solid transparent;
  background: transparent;
  color: #6b7280;
  font-size: 14px;
  font-weight: 600;
  cursor: pointer;
}
.pq-tab svg {
  width: 16px;
  height: 16px;
}
.pq-tab:hover {
  background: #eef8fa;
}
.pq-tab:disabled {
  cursor: not-allowed;
  opacity: 0.45;
}
.pq-tab:disabled:hover {
  background: transparent;
}
.pq-tab.active {
  background: #fff;
  border-color: #cdebf1;
  color: #0f7c96;
  box-shadow: 0 1px 2px rgba(27, 33, 69, 0.05);
}
.pq-tab-count {
  font-size: 11.5px;
  font-weight: 700;
  background: #eef8fa;
  color: #0f7c96;
  padding: 1px 7px;
  border-radius: 999px;
}
.pq-tab.active .pq-tab-count {
  background: #0f7c96;
  color: #fff;
}

.card {
  background: #fff;
  border: 1px solid #e2e5ea;
  border-radius: 14px;
  padding: 22px;
}

/* ---------- visualization tab ---------- */
.graph-panel {
  position: relative;
  display: flex;
  flex-direction: column;
  align-items: center;
  overflow: hidden;
  background:
    linear-gradient(rgba(36, 72, 95, 0.06) 1px, transparent 1px),
    linear-gradient(90deg, rgba(36, 72, 95, 0.06) 1px, transparent 1px),
    radial-gradient(circle at 50% 42%, rgba(143, 215, 234, 0.12), transparent 48%),
    #ffffff;
  background-size: 28px 28px, 28px 28px, 100% 100%, auto;
}
.graph-svg {
  display: block;
  width: min(100%, 1040px);
  height: auto;
  aspect-ratio: 1 / 1;
}
.graph-empty {
  width: min(100%, 1040px);
  min-height: 380px;
  display: flex;
  align-items: center;
  justify-content: center;
  padding: 48px 24px;
  box-sizing: border-box;
}
.empty-state {
  width: 100%;
  max-width: 440px;
}
.empty-icon {
  display: flex;
  justify-content: center;
  margin-bottom: 14px;
  color: #b6bdda;
}
.empty-icon svg {
  width: 32px;
  height: 32px;
}
.empty-kicker {
  margin: 0 0 24px;
  color: #0f7c96;
  font-size: 12px;
  font-weight: 800;
  letter-spacing: 0.04em;
  text-transform: uppercase;
  text-align: center;
}
.empty-steps {
  position: relative;
  display: flex;
  flex-direction: column;
  gap: 22px;
  margin: 0;
  padding: 0;
  list-style: none;
}
.empty-steps li {
  position: relative;
  display: flex;
  gap: 14px;
  align-items: flex-start;
}
.empty-steps li:not(:last-child)::after {
  content: '';
  position: absolute;
  left: 14px;
  top: 30px;
  width: 1px;
  height: calc(100% + 22px - 30px);
  background: #e6e9f5;
}
.empty-step-num {
  position: relative;
  z-index: 1;
  flex: none;
  display: flex;
  align-items: center;
  justify-content: center;
  width: 29px;
  height: 29px;
  border-radius: 999px;
  border: 1px solid #cfd6ea;
  background: #ffffff;
  color: #0f7c96;
  font-size: 13px;
  font-weight: 800;
}
.empty-step-copy {
  flex: 1 1 auto;
  min-width: 0;
}
.empty-step-copy strong {
  display: block;
  color: #293247;
  font-size: 14.5px;
  font-weight: 800;
  line-height: 1.35;
}
.empty-step-copy span {
  display: block;
  margin-top: 4px;
  color: #667085;
  font-size: 13px;
  font-weight: 600;
  line-height: 1.55;
}
.graph-edge-group {
  cursor: default;
}
.graph-edge {
  fill: none;
  stroke: #a4acbb;
  stroke-linecap: round;
  transition: stroke 0.16s ease, stroke-opacity 0.16s ease, stroke-width 0.16s ease;
}
.graph-edge.shortest {
  stroke: #64748b;
}
.graph-edge.hovered {
  stroke: #475569;
}
.graph-edge-hit {
  fill: none;
  stroke: transparent;
  stroke-width: 18;
  pointer-events: stroke;
}
.graph-node {
  cursor: pointer;
}
.node-hover-halo {
  opacity: 0;
  transition: opacity 0.16s ease;
}
.graph-node-dot {
  stroke: #fff;
  stroke-width: 1.8;
  filter: drop-shadow(0 4px 8px rgba(27, 33, 69, 0.2));
  transition: stroke 0.16s ease, stroke-width 0.16s ease, transform 0.16s ease;
}
.graph-node.hovered .node-hover-halo,
.graph-node:hover .node-hover-halo {
  opacity: 0.16;
}
.graph-node.hovered .graph-node-dot,
.graph-node:hover .graph-node-dot {
  stroke: #1b2145;
  stroke-width: 2.8;
}
.endpoint-ring {
  fill: none;
  stroke-width: 2;
  opacity: 0.55;
}
.graph-label {
  paint-order: stroke;
  stroke: rgba(255, 255, 255, 0.86);
  stroke-width: 5px;
  font-size: 13px;
  font-weight: 750;
  fill: #1b1f24;
  text-anchor: middle;
  pointer-events: none;
}
.graph-tooltip {
  position: absolute;
  z-index: 4;
  width: min(292px, calc(100% - 24px));
  padding: 12px 14px;
  border: 1px solid rgba(31, 41, 55, 0.12);
  border-left: 3px solid var(--tooltip-color);
  border-radius: 8px;
  background: rgba(255, 255, 255, 0.96);
  box-shadow: 0 14px 34px rgba(27, 33, 69, 0.16);
  color: #1b1f24;
  pointer-events: none;
  backdrop-filter: blur(10px);
}
.tooltip-kicker {
  margin-bottom: 4px;
  font-size: 10.5px;
  font-weight: 800;
  letter-spacing: 0.08em;
  text-transform: uppercase;
  color: var(--tooltip-color);
}
.tooltip-title {
  font-size: 14px;
  font-weight: 800;
  line-height: 1.28;
  color: #1b2145;
}
.graph-tooltip dl {
  display: grid;
  grid-template-columns: 58px minmax(0, 1fr);
  gap: 5px 10px;
  margin: 10px 0 0;
  font-size: 12.5px;
  line-height: 1.35;
}
.graph-tooltip dt {
  color: #7a83a3;
  font-weight: 700;
}
.graph-tooltip dd {
  margin: 0;
  color: #30364a;
  overflow-wrap: anywhere;
}
.graph-legend {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  justify-content: center;
  gap: 16px;
  margin-top: 18px;
  padding-top: 16px;
  border-top: 1px solid #eef0f7;
  width: 100%;
  font-size: 12.5px;
  color: #55607a;
}
.graph-legend .dot {
  display: inline-block;
  width: 9px;
  height: 9px;
  border-radius: 50%;
  margin-right: 6px;
  vertical-align: middle;
}
.legend-line {
  display: inline-flex;
  align-items: center;
}
.legend-line .line {
  display: inline-block;
  width: 20px;
  height: 0;
  border-top: 3px solid #9aa1c2;
  opacity: 0.5;
  margin-right: 6px;
}
.legend-line .line.shortest {
  border-top-color: #64748b;
  opacity: 0.9;
}

/* ---------- connections tab ---------- */
.edges-panel {
  padding: 8px;
}
.connections-toolbar {
  display: flex;
  align-items: center;
  flex-wrap: wrap;
  gap: 10px 14px;
  margin: 4px 4px 14px;
  padding: 10px 12px;
  border-bottom: 1px solid #eef0f7;
}
.connections-range {
  color: #5f6b84;
  font-size: 12.5px;
  font-weight: 750;
  margin-right: auto;
}
.connections-size,
.connections-pager label {
  display: inline-flex;
  align-items: center;
  gap: 7px;
  color: #667085;
  font-size: 12px;
  font-weight: 700;
}
.connections-size select,
.connections-pager select {
  min-width: 58px;
  height: 30px;
  padding: 0 8px;
  border: 1px solid #dfe3f0;
  border-radius: 8px;
  background: #fff;
  color: #293247;
  font-size: 12.5px;
  font-weight: 750;
}
.connections-size select:focus,
.connections-pager select:focus {
  outline: none;
  border-color: #0f7c96;
}
.connections-pager {
  display: inline-flex;
  align-items: center;
  gap: 8px;
}
.connections-pager button {
  height: 30px;
  padding: 0 10px;
  border: 1px solid #dfe3f0;
  border-radius: 8px;
  background: #fff;
  color: #0f7c96;
  font-size: 12px;
  font-weight: 800;
  cursor: pointer;
}
.connections-pager button:hover:not(:disabled) {
  border-color: #bfc7ea;
  background: #f6f7ff;
}
.connections-pager button:disabled {
  color: #a6adbf;
  background: #f7f8fb;
  cursor: not-allowed;
}
.chain-block {
  margin: 6px 6px 20px;
  padding-bottom: 18px;
  border-bottom: 1px solid #eef0f7;
}
.chain-label {
  display: block;
  font-size: 12px;
  font-weight: 700;
  text-transform: uppercase;
  letter-spacing: 0.04em;
  color: #9aa1c2;
  margin-bottom: 10px;
}
.chain-row {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: 6px;
}
.chain-node {
  display: flex;
  align-items: center;
  gap: 6px;
  padding: 6px 10px 6px 6px;
  border-radius: 999px;
  border: 1.5px solid var(--node-color);
  background: color-mix(in srgb, var(--node-color) 5%, #fff);
  color: #1b1f24;
  text-decoration: none;
  font-weight: 600;
  font-size: 13px;
}
.chain-node:hover {
  background: color-mix(in srgb, var(--node-color) 10%, #fff);
}
.chain-arrow {
  display: flex;
  flex-direction: column;
  align-items: center;
  color: #b6bdda;
  flex-shrink: 0;
}
.chain-arrow svg {
  width: 30px;
  height: 10px;
}
.chain-rel {
  font-size: 10.5px;
  font-weight: 700;
  color: #6b7280;
  white-space: nowrap;
  margin-top: 1px;
}
.chains-empty {
  margin: 6px;
}
.shortest-tag {
  font-size: 10px;
  font-weight: 700;
  text-transform: uppercase;
  letter-spacing: 0.03em;
  padding: 1px 7px;
  border-radius: 999px;
  background: rgba(15, 124, 150, 0.12);
  color: #0f7c96;
  margin-left: 6px;
}
.badge {
  font-size: 11px;
  font-weight: 700;
  padding: 2px 8px;
  border-radius: 999px;
  border: 1px solid color-mix(in srgb, var(--node-color) 24%, transparent);
  background: color-mix(in srgb, var(--node-color) 7%, #fff);
  color: var(--node-color);
  white-space: nowrap;
}

@media (max-width: 720px) {
  .pq-container {
    padding: 0 20px;
  }
  .pq-form {
    padding: 22px 20px;
  }
  .pq-results {
    padding: 24px 20px 48px;
  }
  .pq-form-pickers {
    flex-direction: column;
    align-items: stretch;
  }
  .pq-arrow {
    align-self: center;
    transform: rotate(90deg);
  }
  .graph-empty {
    min-height: 320px;
    padding: 28px 18px;
  }
  .empty-steps {
    gap: 16px;
  }
  .empty-steps li:not(:last-child)::after {
    top: 26px;
    height: calc(100% + 16px - 26px);
  }
  .empty-step-num {
    width: 26px;
    height: 26px;
    font-size: 12px;
  }
  .empty-step-copy strong {
    font-size: 13.5px;
  }
  .empty-step-copy span {
    font-size: 12.5px;
  }
  .connections-toolbar {
    align-items: stretch;
  }
  .connections-range {
    width: 100%;
    margin-right: 0;
  }
  .connections-pager {
    width: 100%;
    justify-content: space-between;
  }
}
</style>
