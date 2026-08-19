<template>
  <div ref="containerRef" class="kg-globe-wrap">
    <div ref="canvasHost" class="kg-globe-canvas"></div>

    <div class="kg-loading" v-if="isLoading">Laying out the graph…</div>

    <div class="kg-totals" v-if="totals">
      <div class="kg-total">
        <strong>{{ totals.entities.toLocaleString() }}</strong>
        <span>Entities</span>
      </div>
      <div class="kg-total">
        <strong>{{ totals.relations.toLocaleString() }}</strong>
        <span>Relations</span>
      </div>
    </div>

    <div class="kg-legend" v-if="legend.length">
      <span v-for="item in legend" :key="item.label">
        <i class="dot" :style="{ background: item.color }"></i>
        <b>{{ item.label }}</b>
        <em>{{ item.count.toLocaleString() }}</em>
      </span>
    </div>

    <div class="kg-hint">drag to rotate · click to browse all entities</div>
  </div>
</template>

<script setup>
// Real-data-driven 3D knowledge graph for the homepage "About PhenoMAP"
// panel. Replaces the static schema PNG that used to sit here.
//
// This draws real graph data, not a stylized decoration -- but a real
// *sample* of it, not the complete ~12.5k-node graph. On mount it fetches
// /api/graph/overview (backend/graph_overview.go), which returns a
// weighted random sample of real Study/Phenotype/Module/Metabolite nodes
// (sized per label so every type stays visible -- see overviewSampleSize)
// plus the real MEMBER_OF/REPORTED_IN/INVESTIGATED/SIMILAR_TO edges among
// exactly those sampled nodes. Sampling instead of drawing everything
// turned out to be the right call on both fronts it affects: full density
// made the client-side layout expensive enough to visibly stall the page,
// and even reference sites with far more entities than PhenoMAP (100k+)
// only ever render a representative sample for a panel like this, not
// their whole graph -- so a full-density version was never going to look
// like the clean reference it was inspired by, regardless of performance.
// Every sphere is still a real entity and every line a real relationship,
// just not literally every one that exists. Positions come from an actual
// force-directed layout run client-side on mount (see layoutForceDirected
// below) -- connected nodes settle close together and unconnected clusters
// spread apart with real empty space between them, with sphere size
// scaling automatically to the sampled node count. /api/stats still backs
// the legend counts and the Entities/Relations card, since those should
// reflect the true full graph, unaffected by this panel's sampling.
//
// Nodes are real InstancedMesh spheres (lit, so they read as 3D, not flat
// dots). There's no per-node hover/click routing -- raycasting into
// thousands of instances on every pointer move was a real interaction-cost
// (and the dense real graph makes precise node-picking impractical at a
// glance anyway) -- instead a click anywhere on the panel (as opposed to a
// drag) emits browse-click so the caller can route to the full entity
// search/browse page. Drag (mouse or touch) rotates freely with a bit of
// released inertia; a slow auto-rotate resumes after a short idle beat.
import { onMounted, onUnmounted, reactive, ref } from 'vue'
import * as THREE from 'three'
import { getStats, getGraphOverview } from '../api.js'
import { typeColors } from '../lib/typeColors.js'
import facts from '../data/product_facts.json'

const emit = defineEmits(['browse-click'])

const containerRef = ref(null)
const canvasHost = ref(null)

const TYPE_ORDER = ['Metabolite', 'Module', 'Study', 'Phenotype']
// Ball radius (fallback graph only, see buildFallbackGraph) and per-sphere
// radius both scale with cbrt(node count) so density -- and therefore how
// "full" the graph reads -- stays roughly constant across node counts:
// today that's the real ~600-node sample the backend draws (see
// overviewSampleSize in graph_overview.go), but the formula still holds up
// if that sample size ever changes. Clamped so a very small or very large
// graph still renders something reasonable instead of a single giant
// sphere or a cloud of invisible specks.
const BALL_RADIUS_COEF = 0.1035
const BALL_RADIUS_MIN = 1.5
const BALL_RADIUS_MAX = 4.2
const SPHERE_RADIUS_COEF = 0.22
const SPHERE_RADIUS_MIN = 0.008
const SPHERE_RADIUS_MAX = 0.03
// Sphere fill colors are a *lightness-boosted* variant of typeColors, not a
// blend toward white -- blending toward white desaturates every hue toward
// the same pale gray, which made Metabolite's teal and Study's indigo (both
// blue-leaning) collapse into a near-identical washed-out blue-gray and read
// as "missing". Lifting lightness in HSL while keeping (and slightly
// boosting) saturation keeps each type's hue clearly distinct while still
// rendering brighter than the flat legend swatch.
const SPHERE_LIGHTNESS_BOOST = 0.22
const SPHERE_MAX_LIGHTNESS = 0.72
const SPHERE_SATURATION_BOOST = 1.15

function sphereColor(hex) {
  const c = new THREE.Color(hex)
  const hsl = { h: 0, s: 0, l: 0 }
  c.getHSL(hsl)
  c.setHSL(hsl.h, Math.min(hsl.s * SPHERE_SATURATION_BOOST, 1), Math.min(hsl.l + SPHERE_LIGHTNESS_BOOST, SPHERE_MAX_LIGHTNESS))
  return c
}

const legend = reactive(TYPE_ORDER.map((label) => ({ label, color: typeColors[label], count: 0 })))
const totals = ref(null)
// True while the force layout (see layoutForceDirected) is settling --
// brief at today's ~600-node sample size, but the panel still shows a
// small placeholder instead of an empty canvas for that moment rather than
// assuming it's instant.
const isLoading = ref(true)

// Fallback counts (current release scope) if the API is unreachable -- the
// panel should never render empty just because the backend had a hiccup.
function fallbackCounts() {
  const scope = {}
  facts.version.graph_scope.forEach((item) => {
    const key = item.label.replace(/s$/, '')
    scope[key] = Number(String(item.value).replace(/,/g, ''))
  })
  return {
    Study: scope.Study || scope.Studie || 174,
    Phenotype: scope.Phenotype || 138,
    Module: scope.Module || 2438,
    Metabolite: scope.Metabolite || 9730,
  }
}

function mulberry32(seed) {
  let s = seed | 0
  return function () {
    s = (s + 0x6d2b79f5) | 0
    let t = Math.imul(s ^ (s >>> 15), 1 | s)
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296
  }
}
function hashSeed(str) {
  let h = 0
  for (let i = 0; i < str.length; i++) h = (Math.imul(31, h) + str.charCodeAt(i)) | 0
  return h || 1
}

// Uniform random point inside a solid ball (not just its surface). Used to
// seed starting positions before the force layout below settles them, and
// for the small decorative fallback graph (which has no real edges to lay
// out, so random placement is all it needs).
function randomPointInBall(radius, rand) {
  let x, y, z, d2
  do {
    x = rand() * 2 - 1
    y = rand() * 2 - 1
    z = rand() * 2 - 1
    d2 = x * x + y * y + z * z
  } while (d2 > 1 || d2 === 0)
  const r = radius * Math.cbrt(rand())
  const inv = r / Math.sqrt(d2)
  return new THREE.Vector3(x * inv, y * inv, z * inv)
}

function clamp(v, min, max) {
  return Math.max(min, Math.min(max, v))
}

// See the BALL_RADIUS_*/SPHERE_RADIUS_* comment above: both scale with
// cbrt(node count) so density stays roughly constant as the real graph
// grows, clamped so very small (fallback) or very large graphs still
// render something reasonable.
function adaptiveSizing(nodeCount) {
  const n = Math.max(nodeCount, 1)
  return {
    ballRadius: clamp(BALL_RADIUS_COEF * Math.cbrt(n), BALL_RADIUS_MIN, BALL_RADIUS_MAX),
    sphereRadius: clamp(SPHERE_RADIUS_COEF / Math.cbrt(n), SPHERE_RADIUS_MIN, SPHERE_RADIUS_MAX),
  }
}

// ---- Grid-based force-directed layout ---------------------------------
// A textbook O(n^2) force layout (every node checks every other node each
// step) doesn't scale well as node/edge counts grow. Repulsion instead
// only checks nearby nodes via a uniform spatial grid rebuilt each
// iteration: every node compares against its own grid cell plus the 26
// neighboring cells, not every other node. That keeps each iteration
// roughly O(n) in practice; it still runs on the main thread, chunked with
// requestAnimationFrame yields so the tab doesn't freeze solid while it
// runs.
//
// Real edges act as springs pulling connected nodes toward a short rest
// length; a weak centering force keeps the whole cluster near the origin.
// The result is an organic layout where densely-interconnected nodes (e.g.
// a Module and the Metabolites that are MEMBER_OF it) end up close
// together with short edges, and unrelated clusters end up with real empty
// space between them -- instead of every node sitting at a uniformly
// random depth inside one solid ball, which is what an earlier version
// did (and which read as a single dense, hazy mass regardless of sphere
// size).
//
// The backend now caps the panel to a real ~600-node sample (see
// overviewSampleSize in graph_overview.go) instead of the complete
// ~12.5k-node graph, so this only ever runs against a few hundred nodes
// and at most a few thousand edges -- no edge downsampling or other
// large-graph handling needed here anymore, just the plain O(n) grid
// layout below.
const LAYOUT_ITERATIONS = 90
const LAYOUT_CHUNK = 6 // iterations per animation-frame yield
const LAYOUT_DAMPING = 0.82
const LAYOUT_SETTLE_EPS = 0.0006 // avg per-node speed below which we stop early
// The physics below takes a single `unit` and derives every distance
// (restLength, repelRadius, maxRadius...) from it as a multiple -- which
// means if `unit` were just sphereRadius, shrinking sphereRadius to draw
// smaller spheres would shrink the *spacing* between nodes by the exact
// same factor and change nothing about how crowded they look (the whole
// scene just gets smaller, and the camera zooms in to compensate -- see
// buildGraph). LAYOUT_SPACING_RATIO decouples the two: buildGraph passes
// in sphereRadius * LAYOUT_SPACING_RATIO as `unit`, so nodes settle
// further apart *relative to their own drawn size* than a 1:1 ratio would
// give, which is what actually makes gaps and edges visible between them.
const LAYOUT_SPACING_RATIO = 2.4

async function layoutForceDirected(nodes, edgePairs, unit) {
  const n = nodes.length
  if (n === 0) return

  const restLength = unit * 6.4 // target length of a real edge once settled
  const repelRadius = unit * 7 // nodes farther apart than this don't repel
  const repelRadiusSq = repelRadius * repelRadius
  const repelStrength = unit * unit * 2.6
  const springStrength = 0.06
  // Pulls every node toward the origin -- stronger than it looks like it
  // needs to be on paper, because it's also the safety net for any node
  // that ends up with few or no real edges (the backend now samples
  // outward from a Module backbone specifically to avoid this -- see
  // overviewSampleSize in graph_overview.go -- but this is cheap insurance
  // regardless): with only a weak center pull, such a node has nothing but
  // repulsion acting on it and drifts out into a stray orbiting dot,
  // which is exactly what "spread out, not a clean ball" looked like
  // before both this and the sampling fix.
  const centerStrength = 0.012
  // Hard containment: whatever the cause, no node is allowed to end up
  // farther than this from the origin -- rescaled back in if it does (see
  // the integrate step below). This is what actually *guarantees* the
  // overall shape reads as a bounded ball rather than relying entirely on
  // centerStrength being tuned exactly right for every possible sample.
  const maxRadius = unit * 30
  const maxRadiusSq = maxRadius * maxRadius
  const cellSize = repelRadius

  const pos = nodes.map((node) => node.pos)
  const vel = nodes.map(() => new THREE.Vector3())
  const force = nodes.map(() => new THREE.Vector3())

  for (let step = 0; step < LAYOUT_ITERATIONS; step++) {
    // Bin nodes into a uniform grid keyed by integer cell coordinate.
    const grid = new Map()
    for (let i = 0; i < n; i++) {
      const p = pos[i]
      const key = `${Math.floor(p.x / cellSize)}|${Math.floor(p.y / cellSize)}|${Math.floor(p.z / cellSize)}`
      let bucket = grid.get(key)
      if (!bucket) {
        bucket = []
        grid.set(key, bucket)
      }
      bucket.push(i)
    }

    for (let i = 0; i < n; i++) force[i].set(0, 0, 0)

    // Repulsion: every node vs. everything in its own cell + 26 neighbors.
    for (let i = 0; i < n; i++) {
      const p = pos[i]
      const cx = Math.floor(p.x / cellSize)
      const cy = Math.floor(p.y / cellSize)
      const cz = Math.floor(p.z / cellSize)
      for (let dx = -1; dx <= 1; dx++) {
        for (let dy = -1; dy <= 1; dy++) {
          for (let dz = -1; dz <= 1; dz++) {
            const bucket = grid.get(`${cx + dx}|${cy + dy}|${cz + dz}`)
            if (!bucket) continue
            for (const j of bucket) {
              if (j <= i) continue
              const q = pos[j]
              const ddx = p.x - q.x
              const ddy = p.y - q.y
              const ddz = p.z - q.z
              const distSq = ddx * ddx + ddy * ddy + ddz * ddz
              if (distSq > repelRadiusSq || distSq < 1e-6) continue
              const dist = Math.sqrt(distSq)
              const f = repelStrength / distSq
              const fx = (ddx / dist) * f
              const fy = (ddy / dist) * f
              const fz = (ddz / dist) * f
              force[i].x += fx
              force[i].y += fy
              force[i].z += fz
              force[j].x -= fx
              force[j].y -= fy
              force[j].z -= fz
            }
          }
        }
      }
    }

    // Attraction: real edges pull their two nodes toward restLength apart.
    for (const [i, j] of edgePairs) {
      const p = pos[i]
      const q = pos[j]
      const ddx = q.x - p.x
      const ddy = q.y - p.y
      const ddz = q.z - p.z
      const dist = Math.max(Math.sqrt(ddx * ddx + ddy * ddy + ddz * ddz), 1e-6)
      const f = springStrength * (dist - restLength)
      const fx = (ddx / dist) * f
      const fy = (ddy / dist) * f
      const fz = (ddz / dist) * f
      force[i].x += fx
      force[i].y += fy
      force[i].z += fz
      force[j].x -= fx
      force[j].y -= fy
      force[j].z -= fz
    }

    // Pull toward the origin (see centerStrength above) + integrate with
    // damping so the layout actually settles instead of oscillating
    // forever, then clamp to maxRadius (see above) as a hard backstop.
    // Also tracks total speed so we can stop early once the layout has
    // visibly settled, instead of always burning the full iteration
    // budget.
    let speedSum = 0
    for (let i = 0; i < n; i++) {
      const p = pos[i]
      force[i].x -= p.x * centerStrength
      force[i].y -= p.y * centerStrength
      force[i].z -= p.z * centerStrength
      const v = vel[i]
      v.x = (v.x + force[i].x) * LAYOUT_DAMPING
      v.y = (v.y + force[i].y) * LAYOUT_DAMPING
      v.z = (v.z + force[i].z) * LAYOUT_DAMPING
      p.x += v.x
      p.y += v.y
      p.z += v.z
      const distSq = p.x * p.x + p.y * p.y + p.z * p.z
      if (distSq > maxRadiusSq) {
        const scale = maxRadius / Math.sqrt(distSq)
        p.x *= scale
        p.y *= scale
        p.z *= scale
        // Also kill most of its outward velocity -- otherwise a node
        // pinned at the boundary every iteration just reflects at full
        // speed instead of settling there.
        v.x *= 0.2
        v.y *= 0.2
        v.z *= 0.2
      }
      speedSum += Math.abs(v.x) + Math.abs(v.y) + Math.abs(v.z)
    }

    if (step % LAYOUT_CHUNK === LAYOUT_CHUNK - 1) {
      // Yield to the browser every few iterations so this doesn't block
      // the tab for a solid multi-second stretch.
      await new Promise((resolve) => requestAnimationFrame(resolve))
      if (speedSum / n < LAYOUT_SETTLE_EPS) break
    }
  }
}

// overview: { nodes: [{label, lab_id, title}], edges: [{from_label, from_id,
// to_label, to_id, rel_type}] } from GET /api/graph/overview -- a real
// weighted-random sample of nodes (see overviewSampleSize in
// graph_overview.go) plus every real edge among exactly those sampled
// nodes. Everything here is real and resolved by matching lab_id, not an
// approximation -- it's just a sample, not the complete graph. Positions
// are computed here, not fetched -- layoutForceDirected below settles them
// based on that real connectivity.
async function buildGraph(overview) {
  const rawNodes = overview?.nodes || []
  const rawEdges = overview?.edges || []
  const rand = mulberry32(hashSeed(`${rawNodes.length}:${rawEdges.length}`))
  const { sphereRadius } = adaptiveSizing(rawNodes.length)
  // layoutUnit, not sphereRadius, is what the physics uses for spacing --
  // see LAYOUT_SPACING_RATIO above for why the two need to be different.
  const layoutUnit = sphereRadius * LAYOUT_SPACING_RATIO
  // Seed positions just need to not all start on top of each other -- the
  // force layout below determines the real (organically-shaped) spread, so
  // this radius doesn't need to be tuned precisely.
  const seedRadius = Math.max(layoutUnit * Math.cbrt(rawNodes.length) * 3, 1)

  const nodes = [] // { pos, type, color, degree, labId, title, real }
  const indexByKey = new Map()
  rawNodes.forEach((n) => {
    const idx = nodes.length
    indexByKey.set(`${n.label}|${n.lab_id}`, idx)
    nodes.push({
      pos: randomPointInBall(seedRadius, rand),
      type: n.label,
      color: sphereColor(typeColors[n.label] || '#6b7280'),
      degree: 0,
      labId: n.lab_id,
      title: n.title || n.label,
      real: true,
    })
  })

  const edgePairs = [] // [i, j] node-array indices, resolved once up front
  rawEdges.forEach((e) => {
    const i = indexByKey.get(`${e.from_label}|${e.from_id}`)
    const j = indexByKey.get(`${e.to_label}|${e.to_id}`)
    if (i === undefined || j === undefined || i === j) return
    edgePairs.push([i, j])
    nodes[i].degree++
    nodes[j].degree++
  })

  await layoutForceDirected(nodes, edgePairs, layoutUnit)

  const edgeVerts = []
  edgePairs.forEach(([i, j]) => {
    const a = nodes[i]
    const b = nodes[j]
    edgeVerts.push(a.pos.x, a.pos.y, a.pos.z, b.pos.x, b.pos.y, b.pos.z)
  })

  // ballRadius now reflects the layout's *actual* settled spread, used to
  // frame the camera (see init()) -- the true farthest node, not a
  // percentile, since layoutForceDirected's maxRadius clamp already
  // guarantees no single node can be a wild outlier; framing on anything
  // less than the true max is exactly what left nodes poking outside the
  // panel edges in an earlier version.
  const maxDist = nodes.reduce((max, node) => Math.max(max, node.pos.length()), 0)
  const ballRadius = clamp(maxDist, BALL_RADIUS_MIN, BALL_RADIUS_MAX * 6)

  return { nodes, edgeVerts, sphereRadius, ballRadius }
}

// Small, non-clickable decorative fallback if /api/graph/overview couldn't
// be reached (API down) -- the panel should never render empty just
// because the backend had a hiccup, but a placeholder has no real lab_id
// to link to, so it renders with no edges and ignores clicks.
function buildFallbackGraph() {
  const counts = fallbackCounts()
  const budget = 140
  const weights = TYPE_ORDER.map((t) => Math.sqrt(Math.max(counts[t] || 0, 1)))
  const weightSum = weights.reduce((a, b) => a + b, 0)
  const rand = mulberry32(hashSeed('fallback'))
  const { ballRadius, sphereRadius } = adaptiveSizing(budget)

  const nodes = []
  TYPE_ORDER.forEach((type, i) => {
    const want = Math.max(10, Math.round((weights[i] / weightSum) * budget))
    const color = sphereColor(typeColors[type])
    for (let k = 0; k < want; k++) {
      nodes.push({ pos: randomPointInBall(ballRadius, rand), type, color, degree: 0, labId: null, title: type, real: false })
    }
  })

  return { nodes, edgeVerts: [], sphereRadius, ballRadius }
}

let renderer, scene, camera, group, mesh, animationId, resizeObserver
let nodesData = []
let dragging = false
let movedDist = 0
let lastX = 0
let lastY = 0
let velX = 0
let velY = 0
let idleTimer = 0
const IDLE_BEFORE_AUTOROTATE = 90 // frames (~1.5s at 60fps)
const CLICK_MOVE_THRESHOLD = 5 // px
const prefersReducedMotion =
  typeof window !== 'undefined' && window.matchMedia?.('(prefers-reduced-motion: reduce)').matches

async function buildScene(overview) {
  const { nodes, edgeVerts, sphereRadius, ballRadius } = overview ? await buildGraph(overview) : buildFallbackGraph()
  nodesData = nodes

  // Fewer segments per sphere as the node count grows -- at today's
  // ~600-node sample this stays at the roundest tier, but keeps total
  // triangle count reasonable if the sample size (overviewSampleSize in
  // graph_overview.go) is ever increased.
  const n = nodes.length
  const [wSeg, hSeg] = n > 6000 ? [8, 6] : n > 1500 ? [12, 9] : [16, 12]
  const geometry = new THREE.SphereGeometry(1, wSeg, hSeg)
  const material = new THREE.MeshStandardMaterial({ roughness: 0.55, metalness: 0 })
  mesh = new THREE.InstancedMesh(geometry, material, n)
  mesh.instanceColor = new THREE.InstancedBufferAttribute(new Float32Array(n * 3), 3)

  const m = new THREE.Matrix4()
  const q = new THREE.Quaternion()
  const degreeBonusMax = sphereRadius * 0.5
  const degreeBonusPerTier = degreeBonusMax / 6
  nodes.forEach((node, i) => {
    const r = sphereRadius + Math.min(node.degree, 6) * degreeBonusPerTier
    m.compose(node.pos, q, new THREE.Vector3(r, r, r))
    mesh.setMatrixAt(i, m)
    mesh.setColorAt(i, node.color)
  })
  mesh.instanceMatrix.needsUpdate = true
  if (mesh.instanceColor) mesh.instanceColor.needsUpdate = true

  const lineGeo = new THREE.BufferGeometry()
  lineGeo.setAttribute('position', new THREE.Float32BufferAttribute(edgeVerts, 3))
  // Denser graphs get more transparent lines -- otherwise a lot of
  // overlapping real edges reads as one solid gray mass. Edges are also
  // short (the force layout above pulls connected nodes toward a fixed
  // rest length) so they mostly overlap only *within* a local cluster
  // rather than crisscrossing the whole graph.
  const edgeCount = edgeVerts.length / 6
  const lineOpacity = clamp(3000 / Math.max(edgeCount, 1), 0.04, 0.26)
  const lineMat = new THREE.LineBasicMaterial({ color: 0x9aa2c4, transparent: true, opacity: lineOpacity, depthWrite: false })
  const lines = new THREE.LineSegments(lineGeo, lineMat)

  const g = new THREE.Group()
  g.add(lines)
  g.add(mesh)
  return { group: g, ballRadius, sphereRadius }
}

function handleResize() {
  const el = canvasHost.value
  if (!el || !renderer || !camera) return
  const w = el.clientWidth
  const h = el.clientHeight
  if (w === 0 || h === 0) return
  camera.aspect = w / h
  camera.updateProjectionMatrix()
  renderer.setSize(w, h)
}

function onPointerDown(e) {
  dragging = true
  movedDist = 0
  velX = 0
  velY = 0
  lastX = e.clientX
  lastY = e.clientY
  idleTimer = 0
  containerRef.value?.setPointerCapture?.(e.pointerId)
  containerRef.value?.classList.add('kg-dragging')
}
function onPointerMove(e) {
  // No per-node hover here on purpose -- see the intro comment above for
  // why (raycasting thousands of instances on every pointer move was a
  // real cost, and precise node-picking isn't practical at a glance in a
  // graph this dense anyway). The whole panel just rotates on drag.
  if (!dragging) return
  const dx = e.clientX - lastX
  const dy = e.clientY - lastY
  lastX = e.clientX
  lastY = e.clientY
  velX = dx
  velY = dy
  movedDist += Math.abs(dx) + Math.abs(dy)
  if (group) {
    group.rotation.y += dx * 0.006
    group.rotation.x = Math.max(-0.9, Math.min(0.9, group.rotation.x + dy * 0.006))
  }
}
function onPointerUp(e) {
  dragging = false
  containerRef.value?.classList.remove('kg-dragging')
  try {
    containerRef.value?.releasePointerCapture?.(e.pointerId)
  } catch (err) {
    // capture may already be released -- safe to ignore
  }
  // A click (not a drag) anywhere on the panel opens the full entity
  // search/browse page -- there's no per-node destination anymore.
  if (movedDist < CLICK_MOVE_THRESHOLD) {
    emit('browse-click')
  }
}
function onPointerLeave() {
  // No-op now that there's no hover state to clear -- kept as a listener
  // target (see the addEventListener calls in init()) in case a future
  // change needs it again.
}

async function loadData() {
  let counts = fallbackCounts()
  let relations = 0
  let overview = null

  try {
    // /api/stats backs the legend counts and the Entities/Relations card --
    // the *true* full-graph totals, including relationship types/edges this
    // panel doesn't render at all or caps (the Metabolite<->Metabolite
    // reaction network, and SIMILAR_TO beyond overviewSimilarToCap; see
    // graph_overview.go). /api/graph/overview backs what's actually drawn:
    // the complete real Study/Phenotype/Module/Metabolite node set, every
    // real MEMBER_OF/REPORTED_IN/INVESTIGATED edge, and the strongest real
    // SIMILAR_TO edges.
    const [stats, ov] = await Promise.all([getStats(), getGraphOverview()])
    const live = {}
    TYPE_ORDER.forEach((t) => {
      const row = stats?.nodes?.find((n) => n.label === t)
      if (row?.count) live[t] = row.count
    })
    counts = { ...counts, ...live }
    relations = (stats?.relationships || []).reduce((sum, r) => sum + (r.count || 0), 0)
    overview = ov
  } catch (e) {
    // stay on fallback counts / no overview -- the panel should never break
    // just because the API had a hiccup (buildScene falls back to a small
    // non-clickable decorative graph when overview is null).
  }

  legend.forEach((item) => {
    item.count = counts[item.label] || 0
  })
  const totalEntities = TYPE_ORDER.reduce((sum, t) => sum + (counts[t] || 0), 0)
  totals.value = { entities: totalEntities, relations }

  return overview
}

async function init() {
  const el = canvasHost.value
  const width = el.clientWidth || 1
  const height = el.clientHeight || 1

  scene = new THREE.Scene()
  camera = new THREE.PerspectiveCamera(40, width / height, 0.1, 100)
  camera.position.set(0, 0, 6.2)
  camera.lookAt(0, 0, 0)

  renderer = new THREE.WebGLRenderer({ antialias: true, alpha: true })
  renderer.setPixelRatio(Math.min(window.devicePixelRatio || 1, 2))
  renderer.setSize(width, height)
  el.appendChild(renderer.domElement)

  // Mostly-flat, even lighting -- a strong directional key light would leave
  // each small sphere's far side reading as dark, so ambient does most of
  // the work here and the directional lights only add a soft, subtle cue
  // that these are 3D spheres, not a hard shadowed look.
  scene.add(new THREE.AmbientLight(0xffffff, 1.15))
  const key = new THREE.DirectionalLight(0xffffff, 0.45)
  key.position.set(4, 5, 6)
  scene.add(key)
  const fill = new THREE.DirectionalLight(0xffffff, 0.35)
  fill.position.set(-5, -3, -4)
  scene.add(fill)

  const overview = await loadData()
  const built = await buildScene(overview)
  isLoading.value = false
  group = built.group
  scene.add(group)
  // Frame the camera so the settled cluster actually fits inside the
  // panel -- ballRadius is the true farthest node's distance from center
  // (see buildGraph), padded by sphereRadius*1.5 for a sphere's own
  // visible radius (the *1.5 covers the degree-based size bonus in
  // buildScene, so even the biggest hub node sitting near the edge is
  // still accounted for). 1/tan(halfFOV) is exactly the camera distance
  // at which a circle of that padded radius touches the vertical edges of
  // the view -- the tighter of the two axes on a wide panel, since
  // horizontal FOV is wider by the aspect ratio -- multiplied up further
  // for comfortable margin so nothing sits flush against the panel edge.
  // The upper clamp is generous on purpose: an earlier, tighter clamp
  // (16) was exactly why nodes ended up poking outside the panel once the
  // layout's real spread grew past it.
  const paddedRadius = built.ballRadius + built.sphereRadius * 1.5
  const halfFov = THREE.MathUtils.degToRad(camera.fov / 2)
  const fitDistance = paddedRadius / Math.tan(halfFov)
  camera.position.z = clamp(fitDistance * 1.3, 3.2, 60)
  camera.updateProjectionMatrix()

  function animate() {
    if (dragging) {
      idleTimer = 0
    } else if (Math.abs(velX) > 0.01 || Math.abs(velY) > 0.01) {
      group.rotation.y += velX * 0.006
      group.rotation.x = Math.max(-0.9, Math.min(0.9, group.rotation.x + velY * 0.006))
      velX *= 0.94
      velY *= 0.94
      idleTimer = 0
    } else {
      idleTimer++
      if (!prefersReducedMotion && idleTimer > IDLE_BEFORE_AUTOROTATE) {
        group.rotation.y += 0.0018
      }
    }
    renderer.render(scene, camera)
    animationId = requestAnimationFrame(animate)
  }
  animate()

  resizeObserver = new ResizeObserver(handleResize)
  resizeObserver.observe(el)

  containerRef.value.addEventListener('pointerdown', onPointerDown)
  containerRef.value.addEventListener('pointermove', onPointerMove)
  containerRef.value.addEventListener('pointerup', onPointerUp)
  containerRef.value.addEventListener('pointercancel', onPointerUp)
  containerRef.value.addEventListener('pointerleave', onPointerLeave)
}

onMounted(() => {
  init()
})

onUnmounted(() => {
  if (animationId) cancelAnimationFrame(animationId)
  if (resizeObserver) resizeObserver.disconnect()
  containerRef.value?.removeEventListener('pointerdown', onPointerDown)
  containerRef.value?.removeEventListener('pointermove', onPointerMove)
  containerRef.value?.removeEventListener('pointerup', onPointerUp)
  containerRef.value?.removeEventListener('pointercancel', onPointerUp)
  containerRef.value?.removeEventListener('pointerleave', onPointerLeave)
  if (scene) {
    scene.traverse((obj) => {
      if (obj.geometry) obj.geometry.dispose()
      if (obj.material) {
        if (Array.isArray(obj.material)) obj.material.forEach((m) => m.dispose())
        else obj.material.dispose()
      }
    })
  }
  if (renderer) {
    renderer.dispose()
    if (renderer.domElement && renderer.domElement.parentNode) {
      renderer.domElement.parentNode.removeChild(renderer.domElement)
    }
  }
})
</script>

<style scoped>
.kg-globe-wrap {
  position: relative;
  width: 100%;
  height: 100%;
  touch-action: none;
  cursor: grab;
}
.kg-globe-wrap.kg-dragging {
  cursor: grabbing;
}
.kg-globe-canvas {
  width: 100%;
  height: 100%;
}
.kg-globe-canvas :deep(canvas) {
  display: block;
}

.kg-loading {
  position: absolute;
  inset: 0;
  display: flex;
  align-items: center;
  justify-content: center;
  font-size: 13px;
  font-weight: 600;
  color: #8a92ab;
  pointer-events: none;
}

.kg-totals {
  position: absolute;
  right: 18px;
  top: 18px;
  display: flex;
  gap: 10px;
  padding: 12px 18px;
  background: rgba(255, 255, 255, 0.94);
  border: 1px solid #e6e9f5;
  border-radius: 12px;
  box-shadow: 0 8px 22px -14px rgba(27, 33, 69, 0.35);
  pointer-events: none;
}
.kg-total {
  display: flex;
  flex-direction: column;
  align-items: flex-start;
  padding: 0 10px;
  border-left: 1px solid #e6e9f5;
}
.kg-total:first-child {
  border-left: 0;
  padding-left: 0;
}
.kg-total strong {
  font-size: 21px;
  font-weight: 800;
  color: #1b2145;
  line-height: 1.15;
}
.kg-total span {
  margin-top: 2px;
  font-size: 10.5px;
  font-weight: 700;
  letter-spacing: 0.06em;
  text-transform: uppercase;
  color: #8a92ab;
}

.kg-legend {
  position: absolute;
  left: 18px;
  bottom: 18px;
  display: flex;
  flex-direction: column;
  gap: 7px;
  padding: 12px 16px;
  background: rgba(255, 255, 255, 0.92);
  border: 1px solid #e6e9f5;
  border-radius: 10px;
  box-shadow: 0 6px 20px -14px rgba(27, 33, 69, 0.35);
  pointer-events: none;
}
.kg-legend span {
  display: flex;
  align-items: baseline;
  gap: 7px;
  font-size: 12.5px;
  color: #444b63;
}
.kg-legend .dot {
  display: inline-block;
  width: 9px;
  height: 9px;
  border-radius: 50%;
  flex-shrink: 0;
  align-self: center;
}
.kg-legend b {
  font-weight: 650;
  white-space: nowrap;
}
.kg-legend em {
  font-style: normal;
  color: #9aa1b8;
  font-size: 11.5px;
  font-weight: 600;
  margin-left: auto;
  padding-left: 10px;
}

.kg-hint {
  position: absolute;
  right: 18px;
  bottom: 18px;
  padding: 5px 11px;
  font-size: 11.5px;
  font-weight: 650;
  letter-spacing: 0.02em;
  color: #7a8296;
  background: rgba(255, 255, 255, 0.85);
  border: 1px solid #e6e9f5;
  border-radius: 999px;
  pointer-events: none;
}

@media (max-width: 720px) {
  .kg-totals {
    right: 12px;
    top: 12px;
    padding: 9px 12px;
    gap: 6px;
  }
  .kg-total strong {
    font-size: 16px;
  }
  .kg-legend {
    left: 12px;
    bottom: 12px;
    padding: 9px 12px;
    gap: 5px;
  }
  .kg-legend span {
    font-size: 11px;
  }
  .kg-hint {
    display: none;
  }
}
</style>
