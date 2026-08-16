<template>
  <svg class="animated-network-field" :viewBox="`0 0 ${props.viewWidth} ${props.viewHeight}`" preserveAspectRatio="xMidYMid slice" aria-hidden="true">
    <g class="network-lines" fill="none">
      <line
        v-for="(e, i) in graphEdges"
        :key="'e' + i"
        :x1="nodePos[e.from].x"
        :y1="nodePos[e.from].y"
        :x2="nodePos[e.to].x"
        :y2="nodePos[e.to].y"
        :opacity="e.opacity"
      />
    </g>
    <g class="network-nodes">
      <circle
        v-for="n in graphNodes"
        :key="n.id"
        :cx="nodePos[n.id].x"
        :cy="nodePos[n.id].y"
        :r="n.r"
        :opacity="n.opacity"
      />
    </g>
  </svg>
</template>

<script setup>
import { onMounted, onUnmounted, reactive } from 'vue'

const props = defineProps({
  seed: { type: Number, default: 7 },
  variant: { type: String, default: 'side' },
  nodeCount: { type: Number, default: 24 },
  viewWidth: { type: Number, default: 1200 },
  viewHeight: { type: Number, default: 520 },
  driftScale: { type: Number, default: 1 },
})

function makeRand(seed) {
  let state = seed
  return () => {
    state = (state * 1664525 + 1013904223) % 4294967296
    return state / 4294967296
  }
}

const rand = makeRand(props.seed)

function randomIn([min, max]) {
  return min + rand() * (max - min)
}

function inContentQuietZone(x, y) {
  return x > props.viewWidth * 0.26 && x < props.viewWidth * 0.74 && y > props.viewHeight * 0.28 && y < props.viewHeight * 0.68
}

function graphBands() {
  if (props.variant === 'full') {
    return [{ count: props.nodeCount, x: [-40, props.viewWidth + 40], y: [0, props.viewHeight] }]
  }
  return [
    { count: props.nodeCount, x: [-70, props.viewWidth * 0.28], y: [10, props.viewHeight + 30] },
    { count: props.nodeCount, x: [props.viewWidth * 0.72, props.viewWidth + 70], y: [10, props.viewHeight + 30] },
  ]
}

function makeGraphNodes() {
  const nodes = []
  let id = 0
  for (const band of graphBands()) {
    for (let i = 0; i < band.count; i += 1) {
      let x = randomIn(band.x)
      let y = randomIn(band.y)
      if (props.variant === 'side' && inContentQuietZone(x, y)) {
        y = y < props.viewHeight / 2 ? props.viewHeight * 0.22 - rand() * 70 : props.viewHeight * 0.78 + rand() * 95
      }
      const sizeRoll = rand()
      nodes.push({
        id: `n${id}`,
        x,
        y,
        r: sizeRoll > 0.86 ? 10 + rand() * 7 : sizeRoll > 0.56 ? 4.5 + rand() * 5 : 2.1 + rand() * 3,
        phase: rand() * Math.PI * 2,
        drift: (4 + rand() * 9) * props.driftScale,
        opacity: 0.24 + rand() * 0.2,
      })
      id += 1
    }
  }
  return nodes
}

function makeGraphEdges(nodes) {
  const edges = []
  const seen = new Set()
  const maxDistance = props.variant === 'full' ? 135 : 155
  for (const node of nodes) {
    const neighbors = nodes
      .filter((other) => other.id !== node.id)
      .map((other) => {
        const distance = Math.hypot(node.x - other.x, node.y - other.y)
        return { other, distance }
      })
      .filter(({ distance }) => distance < maxDistance)
      .sort((a, b) => a.distance - b.distance)
      .slice(0, 3)

    for (const { other, distance } of neighbors) {
      const key = [node.id, other.id].sort().join(':')
      if (seen.has(key)) continue
      seen.add(key)
      edges.push({
        from: node.id,
        to: other.id,
        opacity: Math.max(0.14, 0.38 - distance / 700),
      })
    }
  }
  return edges
}

const graphNodes = makeGraphNodes()
const graphEdges = makeGraphEdges(graphNodes)
const nodePos = reactive(Object.fromEntries(graphNodes.map((n) => [n.id, { x: n.x, y: n.y }])))

let rafId = null
function tick(t) {
  const time = t / 1000
  for (const n of graphNodes) {
    nodePos[n.id].x = n.x + Math.sin(time * 0.48 + n.phase) * n.drift
    nodePos[n.id].y = n.y + Math.cos(time * 0.36 + n.phase) * n.drift
  }
  rafId = requestAnimationFrame(tick)
}

onMounted(() => {
  rafId = requestAnimationFrame(tick)
})
onUnmounted(() => {
  if (rafId) cancelAnimationFrame(rafId)
})
</script>

<style scoped>
.animated-network-field {
  display: block;
  width: 100%;
  height: 100%;
  pointer-events: none;
}
.network-lines {
  stroke: var(--network-line, rgba(210, 231, 244, 0.42));
  stroke-width: var(--network-line-width, 0.9);
}
.network-nodes {
  fill: var(--network-node, #d8e7ef);
}
</style>
