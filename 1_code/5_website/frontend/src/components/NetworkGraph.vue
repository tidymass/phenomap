<template>
  <div class="ng-wrap">
    <svg
      class="ng-svg"
      :viewBox="`0 0 ${size} ${size}`"
      :width="size"
      :height="size"
      @click="selectedEdgeKey = ''"
    >
      <g
        v-for="e in edges"
        :key="e.key"
        class="ng-edge-group"
        :class="{ selected: selectedEdgeKey === e.key }"
        @click.stop="toggleEdge(e)"
      >
        <line :x1="e.x1" :y1="e.y1" :x2="e.x2" :y2="e.y2" class="ng-edge" />
        <line :x1="e.x1" :y1="e.y1" :x2="e.x2" :y2="e.y2" class="ng-edge-hit" />
      </g>
      <g
        v-for="n in nodes"
        :key="n.id"
        class="ng-node"
        :class="{ center: n.isCenter, clickable: !n.isCenter }"
        @click.stop="!n.isCenter && $emit('node-click', n)"
        @pointerenter="hovered = n.id"
        @pointerleave="hovered === n.id && (hovered = '')"
      >
        <circle
          v-if="n.isCenter"
          :cx="n.x"
          :cy="n.y"
          :r="n.r + 4"
          class="ng-node-ring"
          :style="{ stroke: n.color }"
        />
        <circle :cx="n.x" :cy="n.y" :r="n.r" :fill="n.color" class="ng-node-dot" />
        <title>{{ n.name }} ({{ n.label }})</title>
      </g>
      <text
        v-if="hoveredNode"
        :x="hoveredNode.x"
        :y="hoveredNode.y - hoveredNode.r - 8"
        class="ng-node-label"
      >{{ hoveredNode.name }}</text>
    </svg>

    <div class="ng-edge-label" v-if="selectedEdge">{{ selectedEdge.relLabel }}</div>

    <div class="ng-legend" v-if="legend.length">
      <span v-for="item in legend" :key="item.label">
        <i class="dot" :style="{ background: item.color }"></i>{{ item.label }}
      </span>
    </div>
  </div>
</template>

<script setup>
// Reusable presentational network graph: renders a set of already-laid-out
// nodes/edges (x, y computed by the caller, typically via
// lib/forceLayout.js) as an SVG with a hover label on nodes, a click-to-
// reveal label on edges (each edge carries a pre-formatted relLabel from
// the caller, since only the caller knows how to phrase its own
// relationship types), and an optional type-color legend. Shared by the
// Entity Detail page's neighbor network card and intended to be reusable
// anywhere else a small node/edge graph needs to render -- layout math and
// data fetching stay in the parent, this component only draws.
import { computed, ref, watch } from 'vue'

const props = defineProps({
  nodes: { type: Array, default: () => [] },
  edges: { type: Array, default: () => [] },
  size: { type: Number, default: 320 },
  legend: { type: Array, default: () => [] },
})
defineEmits(['node-click'])

const hovered = ref('')
const hoveredNode = computed(() => props.nodes.find((n) => n.id === hovered.value) || null)

// Click (not hover) reveals an edge's relationship label -- edges are thin
// and packed close together in a small graph, so a hover tooltip would
// flicker between neighbors; a click is a deliberate "tell me what this
// line is" ask, and clicking again (or the empty canvas, or another edge)
// dismisses it.
const selectedEdgeKey = ref('')
const selectedEdge = computed(() => props.edges.find((e) => e.key === selectedEdgeKey.value) || null)
function toggleEdge(e) {
  selectedEdgeKey.value = selectedEdgeKey.value === e.key ? '' : e.key
}
// The selected edge can disappear out from under the selection (a hop
// change, an entity-type toggle) -- clear it rather than pointing at
// nothing.
watch(
  () => props.edges,
  (edges) => {
    if (selectedEdgeKey.value && !edges.some((e) => e.key === selectedEdgeKey.value)) {
      selectedEdgeKey.value = ''
    }
  }
)
</script>

<style scoped>
.ng-wrap {
  position: relative;
  display: flex;
  align-items: center;
  gap: 20px;
  flex-wrap: wrap;
}
.ng-svg {
  max-width: 100%;
  height: auto;
  flex-shrink: 0;
  overflow: visible;
}
.ng-edge-group {
  cursor: pointer;
}
.ng-edge {
  stroke: #9aa1c2;
  stroke-width: 1;
  stroke-opacity: 0.35;
  transition: stroke 0.12s ease, stroke-opacity 0.12s ease, stroke-width 0.12s ease;
}
/* Invisible wide hit-target so a thin 1px line is still easy to click. */
.ng-edge-hit {
  stroke: transparent;
  stroke-width: 10;
}
.ng-edge-group:hover .ng-edge {
  stroke: #6b7280;
  stroke-opacity: 0.7;
}
.ng-edge-group.selected .ng-edge {
  stroke: #3949ab;
  stroke-opacity: 0.9;
  stroke-width: 1.6;
}
.ng-edge-label {
  position: absolute;
  left: 8px;
  bottom: 8px;
  max-width: calc(100% - 16px);
  padding: 4px 9px;
  font-size: 11.5px;
  font-weight: 700;
  color: #1b2145;
  background: #fff;
  border: 1px solid #e6e9f5;
  border-radius: 6px;
  box-shadow: 0 1px 2px rgba(27, 33, 69, 0.08);
  pointer-events: none;
  z-index: 2;
}
.ng-node {
  cursor: default;
}
.ng-node.clickable {
  cursor: pointer;
}
.ng-node-dot {
  stroke: #fff;
  stroke-width: 1.2;
  transition: r 0.1s ease;
}
.ng-node-ring {
  fill: none;
  stroke-width: 1.4;
  opacity: 0.5;
}
.ng-node:hover .ng-node-dot {
  stroke: #1b2145;
}
.ng-node-label {
  font-size: 10.5px;
  font-weight: 600;
  fill: #1b2145;
  text-anchor: middle;
  pointer-events: none;
}
.ng-legend {
  display: flex;
  flex-direction: column;
  gap: 8px;
  padding: 12px 14px;
  background: #fff;
  border: 1px solid #e6e9f5;
  border-radius: 10px;
  box-shadow: 0 1px 2px rgba(27, 33, 69, 0.04);
}
.ng-legend span {
  display: flex;
  align-items: center;
  font-size: 12.5px;
  font-weight: 600;
  color: #444b63;
}
.ng-legend .dot {
  display: inline-block;
  width: 9px;
  height: 9px;
  border-radius: 50%;
  margin-right: 8px;
  flex-shrink: 0;
}
</style>
