<template>
  <div class="picker">
    <div class="picker-tabs">
      <button
        v-for="opt in labelOptions"
        :key="opt.value"
        type="button"
        class="picker-tab"
        :class="{ active: label === opt.value }"
        :style="{ '--tab-color': opt.color }"
        @click="selectLabel(opt.value)"
      >
        <span class="picker-tab-icon">
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

    <div class="picker-input-wrap">
      <input
        v-model="query"
        type="text"
        :placeholder="currentPlaceholder"
        @input="onInput"
        @focus="onInput"
      />
      <button
        v-if="query"
        type="button"
        class="picker-clear"
        aria-label="Clear selected node"
        @click="clearSelection"
      >
        <svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round">
          <path d="M4.5 4.5 11.5 11.5M11.5 4.5 4.5 11.5" />
        </svg>
      </button>
    </div>
    <ul v-if="results.length" class="dropdown">
      <li v-for="r in results" :key="r.lab_id" @click="select(r)">
        <div class="result-line1">
          <span class="lab-id">{{ r.lab_id }}</span>
        </div>
        <div class="result-line2">
          <span class="title">{{ r.title || '(untitled)' }}</span>
          <span class="subtitle" v-if="r.subtitle">{{ r.subtitle }}</span>
        </div>
      </li>
    </ul>
  </div>
</template>

<script setup>
import { ref, computed, watch } from 'vue'
import { searchNodes } from '../api.js'

const props = defineProps({
  selected: {
    type: Object,
    default: null,
  },
})

const emit = defineEmits(['select', 'clear'])

// Same type-tab pattern as the Entity Search page (SearchPageView.vue): the
// user picks a type first, and every search is scoped to that single label.
// Previously this component searched all four types at once (searchNodes
// with no label), which hits the "no unified cross-type ranking" limitation
// in backend/search.go -- results are really four independently-ranked
// lists concatenated, not one true relevance ranking. Scoping to a single
// label sidesteps that entirely, same as the Entity Search page already
// does.
// Metabolite is deliberately excluded here -- Path Query only lets users
// pick a Study, Phenotype, or Module as an endpoint. Metabolites can still
// show up as intermediate nodes in the returned connection graph (see
// PathView.vue's typeColor/legend), just not as a pickable "from"/"to".
const labelOptions = [
  { value: 'Module', text: 'Module', color: '#1a8f5e' },
  { value: 'Study', text: 'Study', color: '#3949ab' },
  { value: 'Phenotype', text: 'Phenotype', color: '#b3562c' },
]

// Same wording used on the Entity Search / homepage search boxes, so the
// hint text matches whichever type is currently selected instead of a
// generic "search a study, phenotype, or module" that doesn't reflect what
// the box will actually match.
const placeholders = {
  Study: 'Search a study accession, title, or keyword...',
  Phenotype: 'Search a phenotype name or keyword...',
  Module: 'Search a module title, ID, or keyword...',
}

const label = ref('Module')
const currentPlaceholder = computed(() => placeholders[label.value] || 'Search...')
const query = ref('')
const results = ref([])
let debounceTimer = null

watch(
  () => props.selected,
  (selected) => {
    if (!selected) {
      query.value = ''
      results.value = []
      return
    }
    label.value = selected.label
    query.value = selected.name || selected.id || ''
    results.value = []
  },
  { immediate: true },
)

function selectLabel(value) {
  if (label.value === value) return
  label.value = value
  query.value = ''
  results.value = []
}

function onInput() {
  clearTimeout(debounceTimer)
  debounceTimer = setTimeout(runSearch, 250)
}

async function runSearch() {
  if (query.value.trim().length < 2) {
    results.value = []
    return
  }
  try {
    const data = await searchNodes(query.value.trim(), label.value)
    results.value = data.results
  } catch (e) {
    results.value = []
  }
}

function select(r) {
  query.value = r.title || r.lab_id
  results.value = []
  emit('select', { label: r.label, id: r.lab_id, name: r.title || r.lab_id })
}

function clearSelection() {
  clearTimeout(debounceTimer)
  query.value = ''
  results.value = []
  emit('clear')
}
</script>

<style scoped>
.picker {
  position: relative;
}
.picker-tabs {
  display: flex;
  flex-wrap: wrap;
  gap: 6px;
  margin-bottom: 8px;
}
.picker-tab {
  display: flex;
  align-items: center;
  gap: 6px;
  padding: 5px 12px 5px 5px;
  border-radius: 999px;
  border: 1.5px solid #dfe3f0;
  background: #fff;
  color: #55607a;
  font-size: 13px;
  font-weight: 700;
  cursor: pointer;
  transition: border-color 0.12s ease, background 0.12s ease, color 0.12s ease;
}
.picker-tab:hover {
  border-color: #c7cce0;
}
.picker-tab.active {
  border-color: var(--tab-color);
  background: color-mix(in srgb, var(--tab-color) 10%, #fff);
  color: var(--tab-color);
}
.picker-tab-icon {
  width: 18px;
  height: 18px;
  border-radius: 50%;
  background: var(--tab-color);
  display: flex;
  align-items: center;
  justify-content: center;
  flex-shrink: 0;
}
.picker-tab-icon svg {
  width: 10px;
  height: 10px;
}
.picker-input-wrap {
  position: relative;
}
.picker input {
  width: 100%;
  padding: 12px 44px 12px 15px;
  border-radius: 10px;
  border: 1px solid #d7dbe0;
  font-size: 16px;
  box-sizing: border-box;
}
.picker-clear {
  position: absolute;
  top: 50%;
  right: 10px;
  width: 26px;
  height: 26px;
  display: grid;
  place-items: center;
  transform: translateY(-50%);
  border: none;
  border-radius: 50%;
  background: #eef0f7;
  color: #7a83a3;
  cursor: pointer;
}
.picker-clear:hover {
  background: #dfe3f0;
  color: #3949ab;
}
.picker-clear svg {
  width: 14px;
  height: 14px;
}
.dropdown {
  position: absolute;
  z-index: 10;
  top: 100%;
  left: 0;
  right: 0;
  background: #fff;
  border: 1px solid #e2e5ea;
  border-radius: 10px;
  margin-top: 5px;
  max-height: 300px;
  overflow-y: auto;
  list-style: none;
  padding: 4px;
}
.dropdown li {
  padding: 10px 12px;
  border-radius: 8px;
  cursor: pointer;
  display: flex;
  flex-direction: column;
  gap: 3px;
}
.dropdown li:hover {
  background: #f7f8fa;
}
.result-line1 {
  display: flex;
  align-items: center;
  gap: 8px;
}
.result-line2 {
  display: flex;
  align-items: baseline;
  gap: 8px;
}
.lab-id {
  font-family: 'SFMono-Regular', Menlo, Consolas, monospace;
  font-size: 11.5px;
  color: #9aa1c2;
}
.subtitle {
  color: #6b7280;
  font-size: 12.5px;
}
</style>
