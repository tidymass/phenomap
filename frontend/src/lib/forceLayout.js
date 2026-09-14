// Deterministic Fruchterman-Reingold-style force-directed graph layout,
// shared by the Module detail page's metabolite network preview
// (NodeDetailView.vue) and the Path Query page's connection subgraph
// (PathView.vue). Both need the same thing: lay out a small heterogeneous
// node/edge list so connected nodes cluster together and isolated nodes
// don't drift off into empty space, with a stable (non-reshuffling) result
// across re-renders.

// Deterministic seeded RNG (mulberry32) -- the layout needs a starting
// position per node, but plain Math.random() would reshuffle the whole
// layout on every unrelated re-render. Seeding from the node id list keeps
// the same graph producing the same layout every time.
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

// Weak centering pull applied to every node each iteration -- keeps
// disconnected components from drifting apart indefinitely (see the
// comment inside the loop below for why this is necessary).
export const GRAPH_GRAVITY = 0.6
// Repulsion is only applied within this fraction of the layout span. Global
// (uncapped) repulsion among many mostly-unconnected nodes needs a much
// stronger gravity than looks good on a small connected cluster to hold
// everything together; capping repulsion to nearby nodes only means an
// isolated node just stops being pushed once it clears the crowd, so a
// moderate gravity is enough to bring it back rather than fighting a
// tug-of-war against every other node in the graph.
export const GRAPH_REPULSION_RANGE = 0.5

// Fruchterman-Reingold force-directed layout: repulsion between every pair
// of nodes, attraction along real edges, run for a fixed number of cooling
// iterations. This is what makes the picture read as "a connected group" --
// connected nodes pull into a cluster, unconnected ones drift to the
// margins -- instead of every node being placed at a predetermined spot (a
// ring, a grid) regardless of whether it's connected to anything.
//
// nodeIds: array of unique node id strings.
// edgeList: array of [fromId, toId] pairs.
// span: layout canvas size (square) to lay nodes out within.
// options.gravity / options.repulsionRange: override the defaults above --
// a sparser or denser graph than the Module metabolite network may want a
// different balance.
export function forceDirectedLayout(nodeIds, edgeList, span, options = {}) {
  const gravity = options.gravity ?? GRAPH_GRAVITY
  const repulsionRange = options.repulsionRange ?? GRAPH_REPULSION_RANGE

  const n = nodeIds.length
  const rand = mulberry32(hashSeed(nodeIds.join(',')))
  const pos = new Map(nodeIds.map((id) => [id, { x: (rand() - 0.5) * span * 0.3, y: (rand() - 0.5) * span * 0.3 }]))
  if (n <= 1) return pos

  const k = Math.sqrt((span * span) / n) * 0.9 // ideal edge length
  const repulsionCutoff = span * repulsionRange
  let temperature = span / 10
  const iterations = 300

  for (let iter = 0; iter < iterations; iter++) {
    const disp = new Map(nodeIds.map((id) => [id, { x: 0, y: 0 }]))

    for (let i = 0; i < n; i++) {
      for (let j = i + 1; j < n; j++) {
        const a = nodeIds[i]
        const b = nodeIds[j]
        const pa = pos.get(a)
        const pb = pos.get(b)
        let dx = pa.x - pb.x
        let dy = pa.y - pb.y
        const dist = Math.sqrt(dx * dx + dy * dy) || 0.01
        if (dist > repulsionCutoff) continue
        const force = (k * k) / dist
        dx = (dx / dist) * force
        dy = (dy / dist) * force
        const da = disp.get(a)
        const db = disp.get(b)
        da.x += dx
        da.y += dy
        db.x -= dx
        db.y -= dy
      }
    }

    edgeList.forEach(([a, b]) => {
      const pa = pos.get(a)
      const pb = pos.get(b)
      if (!pa || !pb) return
      let dx = pa.x - pb.x
      let dy = pa.y - pb.y
      const dist = Math.sqrt(dx * dx + dy * dy) || 0.01
      const force = (dist * dist) / k
      dx = (dx / dist) * force
      dy = (dy / dist) * force
      const da = disp.get(a)
      const db = disp.get(b)
      da.x -= dx
      da.y -= dy
      db.x += dx
      db.y += dy
    })

    // Weak centering force ("gravity") pulling every node toward the
    // shared origin. Repulsion alone pushes disconnected pieces apart
    // forever with nothing to pull them back -- a node with no edge to
    // anything else would just drift off into empty space. This keeps the
    // whole graph reading as one cohesive shape instead of several
    // unrelated-looking fragments scattered around the canvas.
    nodeIds.forEach((id) => {
      const p = pos.get(id)
      const d = disp.get(id)
      d.x -= p.x * gravity
      d.y -= p.y * gravity
    })

    nodeIds.forEach((id) => {
      const d = disp.get(id)
      const dist = Math.sqrt(d.x * d.x + d.y * d.y) || 0.01
      const p = pos.get(id)
      const move = Math.min(dist, temperature)
      p.x += (d.x / dist) * move
      p.y += (d.y / dist) * move
    })

    temperature *= 0.97
  }

  return pos
}

// Normalizes a raw position Map (arbitrary coordinate range from the layout
// above) into a size x size canvas with the given margin, preserving
// aspect ratio (never stretches, only uniformly scales + centers).
export function fitPositionsToCanvas(positions, size, margin) {
  let minX = Infinity
  let maxX = -Infinity
  let minY = Infinity
  let maxY = -Infinity
  positions.forEach((pt) => {
    minX = Math.min(minX, pt.x)
    maxX = Math.max(maxX, pt.x)
    minY = Math.min(minY, pt.y)
    maxY = Math.max(maxY, pt.y)
  })
  const spanX = Math.max(maxX - minX, 1)
  const spanY = Math.max(maxY - minY, 1)
  const inner = size - margin * 2
  const scale = Math.min(inner / spanX, inner / spanY, 1)
  const offsetX = (size - spanX * scale) / 2
  const offsetY = (size - spanY * scale) / 2

  const fitted = new Map()
  positions.forEach((pt, id) => {
    fitted.set(id, {
      x: offsetX + (pt.x - minX) * scale,
      y: offsetY + (pt.y - minY) * scale,
    })
  })
  return fitted
}
