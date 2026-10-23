<template>
  <div class="me">
    <!-- ============ HEADER + FORM BAND ============ -->
    <section class="me-header">
      <AnimatedNetworkField class="analysis-network-bg" :seed="41" :node-count="22" :drift-scale="0.82" />
      <div class="me-container">
        <h1>Module Enrichment</h1>

        <div class="me-form">
          <div class="me-ids-block">
            <div class="me-ids-label-row">
              <label for="me-ids">Metabolite IDs</label>
            </div>
            <textarea
              id="me-ids"
              v-model="idsText"
              rows="6"
              placeholder="One ID per line (or comma / space separated), e.g.&#10;PME002024&#10;PME005472&#10;PME005806"
            ></textarea>
            <div class="me-examples" aria-label="Example module enrichment inputs">
              <span>Examples</span>
              <button
                v-for="demo in enrichmentDemos"
                :key="demo.label"
                type="button"
                class="me-example"
                :title="demo.title"
                @click="applyDemo(demo)"
              >
                {{ demo.label }}
              </button>
            </div>
          </div>

          <div class="me-form-controls">
            <div class="me-field">
              <span class="me-field-label">ID type</span>
              <div class="me-segmented">
                <button
                  v-for="opt in idTypeOptions"
                  :key="opt.value"
                  type="button"
                  :class="{ active: idType === opt.value }"
                  @click="idType = opt.value"
                >
                  {{ opt.label }}
                </button>
              </div>
            </div>

            <div class="me-field">
              <span class="me-field-label">Module confidence</span>
              <div class="me-multi">
                <button
                  type="button"
                  class="me-multi-trigger"
                  :class="{ open: openFilter === 'confidence', partial: !allConfidenceSelected }"
                  @click.stop="toggleFilter('confidence')"
                >
                  <span class="me-multi-summary">{{ confidenceSummary }}</span>
                  <svg class="me-multi-caret" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                    <path d="m6 9 6 6 6-6" />
                  </svg>
                </button>
                <div class="me-multi-panel" v-if="openFilter === 'confidence'" @click.stop>
                  <div class="me-multi-actions">
                    <button type="button" @click="selectAll('confidence')">Select all</button>
                    <button type="button" @click="clearAll('confidence')">Clear</button>
                  </div>
                  <label class="me-multi-option" v-for="opt in confidenceOptions" :key="opt.value">
                    <input type="checkbox" :value="opt.value" v-model="confidenceSelected" />
                    <span class="me-multi-name">{{ opt.label }}</span>
                    <span class="me-multi-count" v-if="opt.n !== null">{{ opt.n.toLocaleString() }}</span>
                  </label>
                </div>
              </div>
            </div>

            <div class="me-field">
              <span class="me-field-label">Module type</span>
              <div class="me-multi">
                <button
                  type="button"
                  class="me-multi-trigger"
                  :class="{ open: openFilter === 'hypothesis', partial: !allTypesSelected }"
                  @click.stop="toggleFilter('hypothesis')"
                >
                  <span class="me-multi-summary">{{ typeSummary }}</span>
                  <svg class="me-multi-caret" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                    <path d="m6 9 6 6 6-6" />
                  </svg>
                </button>
                <div class="me-multi-panel" v-if="openFilter === 'hypothesis'" @click.stop>
                  <div class="me-multi-actions">
                    <button type="button" @click="selectAll('hypothesis')">Select all</button>
                    <button type="button" @click="clearAll('hypothesis')">Clear</button>
                  </div>
                  <label class="me-multi-option" v-for="opt in hypothesisOptions" :key="opt.value">
                    <input type="checkbox" :value="opt.value" v-model="hypothesisSelected" />
                    <span class="me-multi-name">{{ opt.label }}</span>
                    <span class="me-multi-count" v-if="opt.n !== null">{{ opt.n.toLocaleString() }}</span>
                  </label>
                </div>
              </div>
            </div>

            <div class="me-field">
              <span class="me-field-label">Significance basis</span>
              <div class="me-segmented">
                <button
                  v-for="opt in sigBasisOptions"
                  :key="opt.value"
                  type="button"
                  :class="{ active: sigBasis === opt.value }"
                  @click="sigBasis = opt.value"
                >
                  {{ opt.label }}
                </button>
              </div>
            </div>

            <label class="me-field me-number-field">
              <span class="me-field-label">{{ sigBasisLabel }} cutoff</span>
              <input type="number" v-model.number="sigCutoff" step="0.01" min="0" max="1" />
            </label>

            <label class="me-field me-number-field">
              <span class="me-field-label">Min overlap</span>
              <input type="number" v-model.number="minOverlap" step="1" min="1" />
            </label>

            <button class="me-submit" :disabled="loading || inputIdCount === 0 || filtersEmpty" @click="run">
              <span v-if="loading" class="spinner" aria-hidden="true"></span>
              {{ loading ? 'Running...' : 'Run' }}
            </button>

            <p class="me-universe-hint" :class="{ warn: filtersEmpty }">{{ universeSummary }}</p>
          </div>
        </div>
      </div>
    </section>

    <!-- ============ RESULTS ============ -->
    <section class="me-container me-results">
      <div v-if="error" class="state-block state-error">
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
          <circle cx="12" cy="12" r="9" /><path d="M12 8v5M12 16h.01" />
        </svg>
        <span>{{ error }}</span>
      </div>

      <template v-else>
        <div v-if="!result && !loading" class="card empty-state-card">
          <div class="empty-state">
            <p class="empty-kicker">How it works</p>
            <ol class="empty-steps">
              <li>
                <span class="empty-step-num">1</span>
                <div class="empty-step-copy">
                  <strong>Paste your metabolite IDs.</strong>
                  <span>HMDB, KEGG, or InChI -- one per line, or separated by commas/spaces.</span>
                </div>
              </li>
              <li>
                <span class="empty-step-num">2</span>
                <div class="empty-step-copy">
                  <strong>Tune the test.</strong>
                  <span>Set an FDR / P-value cutoff and a minimum overlap.</span>
                </div>
              </li>
              <li>
                <span class="empty-step-num">3</span>
                <div class="empty-step-copy">
                  <strong>Run enrichment.</strong>
                  <span>Every module is scored against your list and ranked by significance.</span>
                </div>
              </li>
            </ol>
          </div>
        </div>

        <div v-if="loading" class="state-block state-loading">
          <span class="spinner" aria-hidden="true"></span>
          <span>Running enrichment against every module...</span>
        </div>

        <template v-else-if="result">
          <div v-if="unmatchedRows.length" class="card me-unmatched">
            <button type="button" class="me-unmatched-toggle" @click="showUnmatched = !showUnmatched">
              <svg
                class="me-chevron"
                :class="{ open: showUnmatched }"
                viewBox="0 0 24 24"
                fill="none"
                stroke="currentColor"
                stroke-width="2"
              >
                <path d="m9 6 6 6-6 6" />
              </svg>
              {{ unmatchedRows.length }} input ID{{ unmatchedRows.length === 1 ? '' : 's' }} didn't match any module
              metabolite
            </button>
            <div v-show="showUnmatched" class="me-chip-list">
              <span v-for="u in unmatchedRows" :key="u.Input_ID" class="me-chip">{{ u.Input_ID }}</span>
            </div>
          </div>

          <div class="me-tabs">
            <button type="button" class="me-tab" :class="{ active: activeTab === 'visual' }" @click="activeTab = 'visual'">
              <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8">
                <circle cx="6" cy="6" r="2.3" />
                <circle cx="18" cy="8" r="2.3" />
                <circle cx="10" cy="18" r="2.3" />
                <path d="M8 7.1 15.7 7.9M8.6 8.1 9.5 16" />
              </svg>
              Visualization
            </button>
            <button type="button" class="me-tab" :class="{ active: activeTab === 'table' }" @click="activeTab = 'table'">
              <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round">
                <path d="M9 6h11M9 12h11M9 18h11M4 6h.01M4 12h.01M4 18h.01" />
              </svg>
              Significant modules
              <span class="me-tab-count">{{ significantCount }}</span>
            </button>
            <button v-if="visibleRows.length" type="button" class="me-export" @click="exportCsv">
              <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                <path d="M12 4v11M8 11l4 4 4-4M4 19h16" />
              </svg>
              Export CSV
            </button>
          </div>

          <div v-show="activeTab === 'visual'" class="card me-chart-card">
            <div class="me-chart-head">
              <div class="me-chart-head-text">
                <h2>Enrichment overview</h2>
                <p>
                  Each point is a module. Position = effect size vs. significance, color = significant vs.
                  not, dashed line = your {{ sigBasisLabel }} cutoff.
                </p>
              </div>
              <div class="me-chart-legend">
                <span class="me-legend-group"><i class="me-swatch sig"></i>Significant</span>
                <span class="me-legend-group"><i class="me-swatch"></i>Not significant</span>
                <span v-if="chartLayout.sizeLegend?.length" class="me-legend-group me-size-legend">
                  <svg class="me-size-legend-svg" width="54" height="28" viewBox="0 0 54 28">
                    <circle
                      v-for="(s, i) in chartLayout.sizeLegend"
                      :key="s.n"
                      :cx="i === 0 ? 12 : 38"
                      cy="16"
                      :r="Math.min(s.r, 12)"
                      class="me-size-legend-dot"
                    />
                  </svg>
                  <span>{{ chartLayout.sizeLegend[0].n }}&ndash;{{ chartLayout.sizeLegend.at(-1).n }} overlap</span>
                </span>
              </div>
            </div>

            <div v-if="!chartPoints.length" class="me-chart-empty">
              <span>No overlapping modules to visualize yet.</span>
            </div>

            <div v-else class="me-chart-panel" ref="chartPanelRef" @pointerleave="hideChartTooltip">
              <svg
                class="me-chart-svg"
                :viewBox="`0 0 ${chartLayout.width} ${chartLayout.height}`"
                preserveAspectRatio="xMidYMid meet"
              >
                <g class="me-chart-grid">
                  <line
                    v-for="t in chartLayout.yTicks"
                    :key="'gy' + t.value"
                    :x1="chartLayout.plotLeft"
                    :x2="chartLayout.plotRight"
                    :y1="t.px"
                    :y2="t.px"
                  />
                  <line
                    v-for="t in chartLayout.xTicks"
                    :key="'gx' + t.value"
                    :y1="chartLayout.plotTop"
                    :y2="chartLayout.plotBottom"
                    :x1="t.px"
                    :x2="t.px"
                  />
                </g>

                <rect
                  class="me-chart-frame"
                  :x="chartLayout.plotLeft"
                  :y="chartLayout.plotTop"
                  :width="chartLayout.plotRight - chartLayout.plotLeft"
                  :height="chartLayout.plotBottom - chartLayout.plotTop"
                  rx="8"
                />

                <line
                  v-if="chartLayout.thresholdY !== null"
                  class="me-chart-threshold"
                  :x1="chartLayout.plotLeft"
                  :x2="chartLayout.plotRight"
                  :y1="chartLayout.thresholdY"
                  :y2="chartLayout.thresholdY"
                />
                <text
                  v-if="chartLayout.thresholdY !== null"
                  class="me-chart-ref-label"
                  :x="chartLayout.plotRight - 6"
                  :y="chartLayout.thresholdY - 7"
                  text-anchor="end"
                >
                  {{ sigBasisLabel }} = {{ sigCutoff }}
                </text>
                <line
                  class="me-chart-zero"
                  :x1="chartLayout.zeroX"
                  :x2="chartLayout.zeroX"
                  :y1="chartLayout.plotTop"
                  :y2="chartLayout.plotBottom"
                />
                <text class="me-chart-ref-label" :x="chartLayout.zeroX" :y="chartLayout.plotTop - 10" text-anchor="middle">
                  ratio = 1
                </text>

                <g v-for="t in chartLayout.xTicks" :key="'xt' + t.value">
                  <text :x="t.px" :y="chartLayout.plotBottom + 22" class="me-chart-tick" text-anchor="middle">
                    {{ t.label }}
                  </text>
                </g>
                <g v-for="t in chartLayout.yTicks" :key="'yt' + t.value">
                  <text :x="chartLayout.plotLeft - 10" :y="t.px + 4" class="me-chart-tick" text-anchor="end">
                    {{ t.label }}
                  </text>
                </g>
                <text
                  class="me-chart-axis-label"
                  :x="(chartLayout.plotLeft + chartLayout.plotRight) / 2"
                  :y="chartLayout.height - 8"
                  text-anchor="middle"
                >
                  log2(Enrichment Ratio)
                </text>
                <text
                  class="me-chart-axis-label"
                  :transform="`translate(16 ${(chartLayout.plotTop + chartLayout.plotBottom) / 2}) rotate(-90)`"
                  text-anchor="middle"
                >
                  -log10({{ sigBasisLabel }})
                </text>

                <circle
                  v-for="pt in chartLayout.points"
                  :key="pt.id"
                  :cx="pt.px"
                  :cy="pt.py"
                  :r="pt.r"
                  :style="{ animationDelay: `${Math.min(pt.delay * 5, 260)}ms` }"
                  class="me-chart-point"
                  :class="{ significant: pt.significant, hovered: chartTooltip.id === pt.id }"
                  @pointerenter="showChartTooltip(pt, $event)"
                  @pointermove="moveChartTooltip($event)"
                  @click="router.push(nodeRoute(pt.id))"
                />
              </svg>

              <div
                v-if="chartTooltip.visible"
                class="me-chart-tooltip"
                :class="{ significant: chartTooltip.significant }"
                :style="{ left: `${chartTooltip.x}px`, top: `${chartTooltip.y}px` }"
              >
                <div class="me-chart-tooltip-title">{{ chartTooltip.title }}</div>
                <dl>
                  <dt>Overlap</dt>
                  <dd>{{ chartTooltip.overlap }} / {{ chartTooltip.moduleSize }}</dd>
                  <dt>Ratio</dt>
                  <dd>{{ chartTooltip.ratio }}</dd>
                  <dt>{{ chartTooltip.sigLabel }}</dt>
                  <dd>{{ chartTooltip.sig }}</dd>
                </dl>
              </div>
            </div>
          </div>

          <template v-if="activeTab === 'table'">
            <div v-if="!visibleRows.length" class="state-block state-empty">
              <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6">
                <circle cx="11" cy="11" r="7" />
                <line x1="21" y1="21" x2="16.65" y2="16.65" />
              </svg>
              <span>
                No modules clear {{ sigBasisLabel }} &lt; {{ sigCutoff }} with overlap &ge; {{ minOverlap }}. Try
                relaxing the significance cutoff or minimum overlap above.
              </span>
            </div>

            <template v-else>
              <div class="results-table-wrap">
                <div class="me-table">
                  <div class="me-thead">
                    <span>Module</span>
                    <span>Confidence</span>
                    <span title="Overlap counts against a module's core + supporting metabolites only -- broader &quot;contextual&quot; associations are excluded. See the note below the table.">
                      Overlap
                    </span>
                    <span>Overlapped Metabolites</span>
                    <span>Enrichment ratio</span>
                    <span>P-value</span>
                    <span>FDR</span>
                  </div>
                  <div
                    v-for="row in pagedRows"
                    :key="row.Module_ID"
                    class="me-row significant"
                  >
                    <span class="me-cell-module">
                      <router-link :to="nodeRoute(row.Module_ID)" class="me-module-link">
                        <span class="me-module-title">{{ row.title || row.Module_ID }}</span>
                      </router-link>
                      <span class="me-module-id">{{ row.Module_ID }}</span>
                    </span>
                    <span class="me-cell-center">
                      <span
                        v-if="row.confidence_label"
                        class="confidence-badge"
                        :class="`tier-${String(row.confidence_label).toLowerCase()}`"
                      >
                        {{ row.confidence_label }}
                      </span>
                      <span v-else class="me-dash">&mdash;</span>
                    </span>
                    <span class="me-overlap">
                      <span class="me-overlap-value">{{ row.Overlap_N }} / {{ row.Module_Set_Size }}</span>
                      <span class="me-overlap-bar">
                        <span class="me-overlap-fill" :style="{ width: overlapPct(row) + '%' }"></span>
                      </span>
                    </span>
                    <span
                      class="me-metabolites"
                      :title="overlapNames(row).join(', ')"
                    >
                      <span
                        v-if="overlapNames(row).length"
                        class="me-overlap-names"
                      >
                        {{ overlapNames(row).join(', ') }}
                      </span>
                      <span v-else class="me-dash">&mdash;</span>
                    </span>
                    <span class="me-er">{{ formatRatio(row.Enrichment_Ratio) }}</span>
                    <span class="me-fdr" :class="{ significant: sigBasis === 'pvalue' }">{{ formatP(row.P_Value) }}</span>
                    <span class="me-fdr" :class="{ significant: sigBasis === 'fdr' }">{{ formatP(row.FDR) }}</span>
                  </div>
                </div>
              </div>

              <div class="me-pagination-toolbar">
                <span class="me-pagination-range">
                  Showing {{ rangeStart }}&ndash;{{ rangeEnd }} of {{ significantCount }} significant module{{
                    significantCount === 1 ? '' : 's'
                  }}
                </span>
                <label class="me-pagination-size">
                  Per page
                  <select v-model.number="pageSize">
                    <option v-for="size in pageSizeOptions" :key="size" :value="size">{{ size }}</option>
                  </select>
                </label>
                <div class="me-pagination-pager" aria-label="Significant modules pagination">
                  <button type="button" :disabled="page <= 1" @click="setPage(page - 1)">
                    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="m15 6-6 6 6 6" /></svg>
                    Prev
                  </button>
                  <label>
                    Page
                    <select v-model.number="page">
                      <option v-for="p in totalPages" :key="p" :value="p">{{ p }}</option>
                    </select>
                    of {{ totalPages }}
                  </label>
                  <button type="button" :disabled="page >= totalPages" @click="setPage(page + 1)">
                    Next
                    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="m9 6 6 6-6 6" /></svg>
                  </button>
                </div>
              </div>
            </template>
          </template>
        </template>
      </template>
    </section>
  </div>
</template>

<script setup>
import { computed, onBeforeUnmount, onMounted, ref, watch } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { fetchEnrichmentMeta, runEnrichment } from '../api.js'
import AnimatedNetworkField from '../components/AnimatedNetworkField.vue'

const route = useRoute()
const router = useRouter()

// The router replaces this whole component on every navigation (there's no
// keep-alive on <router-view> in App.vue), so a plain "click a module row ->
// go to /node/Module/... -> click back" round trip would normally wipe the
// form and results. Stash the last run's state on window, same trick
// PathView.vue uses for its graph cache, and restore it on mount.
const enrichmentCache = window.__phenomapEnrichmentCache || (window.__phenomapEnrichmentCache = {})

function persistState() {
  enrichmentCache.idsText = idsText.value
  enrichmentCache.idType = idType.value
  enrichmentCache.sigBasis = sigBasis.value
  enrichmentCache.sigCutoff = sigCutoff.value
  enrichmentCache.minOverlap = minOverlap.value
  enrichmentCache.confidenceSelected = confidenceSelected.value.slice()
  enrichmentCache.hypothesisSelected = hypothesisSelected.value.slice()
  enrichmentCache.result = result.value
  enrichmentCache.activeTab = activeTab.value
  enrichmentCache.page = page.value
  enrichmentCache.pageSize = pageSize.value
  enrichmentCache.showUnmatched = showUnmatched.value
}

function restoreState() {
  if (!enrichmentCache.result) return
  idsText.value = enrichmentCache.idsText ?? ''
  idType.value = enrichmentCache.idType ?? 'lab_id'
  sigBasis.value = enrichmentCache.sigBasis ?? 'fdr'
  sigCutoff.value = enrichmentCache.sigCutoff ?? 0.05
  minOverlap.value = enrichmentCache.minOverlap ?? 2
  if (Array.isArray(enrichmentCache.confidenceSelected)) {
    confidenceSelected.value = enrichmentCache.confidenceSelected.slice()
    filtersRestored = true
  }
  if (Array.isArray(enrichmentCache.hypothesisSelected)) {
    hypothesisSelected.value = enrichmentCache.hypothesisSelected.slice()
    filtersRestored = true
  }
  result.value = enrichmentCache.result
  activeTab.value = enrichmentCache.activeTab ?? 'visual'
  page.value = enrichmentCache.page ?? 1
  pageSize.value = pageSizeOptions.includes(enrichmentCache.pageSize) ? enrichmentCache.pageSize : 20
  showUnmatched.value = enrichmentCache.showUnmatched ?? false
}

const idTypeOptions = [
  { value: 'lab_id', label: 'Lab ID' },
  { value: 'hmdb', label: 'HMDB' },
  { value: 'kegg', label: 'KEGG' },
  { value: 'inchi', label: 'InChI' },
]
const sigBasisOptions = [
  { value: 'fdr', label: 'FDR' },
  { value: 'pvalue', label: 'P-value' },
]

const idsText = ref('')
const idType = ref('lab_id')
const sigBasis = ref('fdr')
const sigCutoff = ref(0.05)
const minOverlap = ref(2)

// ---------- module universe filters ----------
// Restricting the universe is not cosmetic: the R side rebuilds the
// BACKGROUND from whichever modules survive, so the null model matches what
// is actually being tested (and the BH denominator shrinks with it). Both
// lists start fully selected, which is exactly the old behaviour -- the
// request omits the filter entirely when everything is checked.
const CONFIDENCE_ORDER = ['high', 'medium', 'low']
const FALLBACK_CONFIDENCE = ['high', 'medium', 'low']
const FALLBACK_TYPES = [
  'Host-Endogenous',
  'Xenobiotic / Exogenous',
  'Diet-Derived',
  'Microbiome-Derived',
  'Host\u2013Microbiome',
]

function titleCase(value) {
  const v = String(value ?? '')
  return v ? v.charAt(0).toUpperCase() + v.slice(1) : v
}
function asOption(value, n, label) {
  return { value, label: label ?? value, n: Number.isFinite(Number(n)) ? Number(n) : null }
}

const confidenceOptions = ref(FALLBACK_CONFIDENCE.map((v) => asOption(v, null, titleCase(v))))
const hypothesisOptions = ref(FALLBACK_TYPES.map((v) => asOption(v, null)))
const confidenceSelected = ref(FALLBACK_CONFIDENCE.slice())
const hypothesisSelected = ref(FALLBACK_TYPES.slice())
const openFilter = ref('')
let filtersRestored = false

const allConfidenceSelected = computed(
  () => confidenceSelected.value.length === confidenceOptions.value.length
)
const allTypesSelected = computed(
  () => hypothesisSelected.value.length === hypothesisOptions.value.length
)
const filtersEmpty = computed(
  () => confidenceSelected.value.length === 0 || hypothesisSelected.value.length === 0
)

function summarise(selected, options, allLabel) {
  if (selected.length === 0) return 'None selected'
  if (selected.length === options.length) return allLabel
  if (selected.length <= 2) {
    return selected
      .map((v) => options.find((o) => o.value === v)?.label ?? v)
      .join(', ')
  }
  return `${selected.length} of ${options.length} selected`
}
const confidenceSummary = computed(
  () => summarise(confidenceSelected.value, confidenceOptions.value, 'All confidence')
)
const typeSummary = computed(
  () => summarise(hypothesisSelected.value, hypothesisOptions.value, 'All types')
)

// Rough module count for the current selection, from the /meta counts. The
// exact background size only comes back with the result (Background_N).
const universeSummary = computed(() => {
  if (filtersEmpty.value) return 'Select at least one confidence label and one module type.'
  const known = (opts, sel) => opts.every((o) => o.n !== null) &&
    opts.filter((o) => sel.includes(o.value)).reduce((a, o) => a + o.n, 0)
  const byConf = known(confidenceOptions.value, confidenceSelected.value)
  const byType = known(hypothesisOptions.value, hypothesisSelected.value)
  if (byConf === false || byType === false) return ''
  if (allConfidenceSelected.value && allTypesSelected.value) {
    return `Testing all ${byConf.toLocaleString()} modules.`
  }
  // The two filters intersect, so the true count is at most the smaller side.
  return `Testing at most ${Math.min(byConf, byType).toLocaleString()} modules -- the exact background size is reported with the result.`
})

function toggleFilter(key) {
  openFilter.value = openFilter.value === key ? '' : key
}
function selectAll(key) {
  if (key === 'confidence') confidenceSelected.value = confidenceOptions.value.map((o) => o.value)
  else hypothesisSelected.value = hypothesisOptions.value.map((o) => o.value)
}
function clearAll(key) {
  if (key === 'confidence') confidenceSelected.value = []
  else hypothesisSelected.value = []
}
function onDocumentClick(event) {
  if (!event.target.closest?.('.me-multi')) openFilter.value = ''
}

// plumber serialises scalars unboxed, but be tolerant of length-1 arrays.
function scalar(x) {
  return Array.isArray(x) ? x[0] : x
}

async function loadFilterMeta() {
  try {
    const meta = await fetchEnrichmentMeta()
    const conf = (meta?.confidence_labels ?? [])
      .map((e) => asOption(String(scalar(e.value)), scalar(e.n), titleCase(scalar(e.value))))
      .filter((o) => o.value)
    const types = (meta?.hypothesis_types ?? [])
      .map((e) => asOption(String(scalar(e.value)), scalar(e.n)))
      .filter((o) => o.value)
    if (conf.length) {
      conf.sort((a, b) => CONFIDENCE_ORDER.indexOf(a.value) - CONFIDENCE_ORDER.indexOf(b.value))
      confidenceOptions.value = conf
      if (!filtersRestored) confidenceSelected.value = conf.map((o) => o.value)
      else confidenceSelected.value = confidenceSelected.value.filter((v) => conf.some((o) => o.value === v))
    }
    if (types.length) {
      hypothesisOptions.value = types
      if (!filtersRestored) hypothesisSelected.value = types.map((o) => o.value)
      else hypothesisSelected.value = hypothesisSelected.value.filter((v) => types.some((o) => o.value === v))
    }
  } catch (e) {
    // The form still works with the fallback lists; no need to shout.
    console.warn('enrichment meta unavailable:', e.message)
  }
}

const loading = ref(false)
const error = ref('')
const result = ref(null)
const showUnmatched = ref(false)
const activeTab = ref('visual')
const page = ref(1)
const pageSizeOptions = [10, 20, 50]
const pageSize = ref(20)

const sigBasisLabel = computed(() => (sigBasis.value === 'fdr' ? 'FDR' : 'P-value'))

// Both FDR and raw P_Value come back on every row already, so switching
// basis or dragging the cutoff re-filters instantly client-side -- no need
// to re-run the R service just to change which column gates "significant".
function isSignificant(row) {
  const val = sigBasis.value === 'fdr' ? Number(row.FDR) : Number(row.P_Value)
  return Number.isFinite(val) && val < sigCutoff.value && Number(row.Overlap_N) >= minOverlap.value
}

const enrichmentDemos = [
  {
    label: '#1',
    title:
      'HMDB: purine catabolism plus dietary methylxanthines. The top hits separate into ' +
      'Host-Endogenous "Purine metabolism" and Diet-Derived "Caffeine metabolism" modules ' +
      '-- the same 10 compounds, two different origins.',
    idType: 'hmdb',
    ids: [
      'HMDB0000157',
      'HMDB0000292',
      'HMDB0000289',
      'HMDB0000195',
      'HMDB0000050',
      'HMDB0000133',
      'HMDB0000462',
      'HMDB0001847',
      'HMDB0001889',
      'HMDB0001860',
    ],
  },
  {
    label: '#2',
    title:
      'KEGG: the primary and secondary bile acid pool. The strongest module is a ' +
      'Host-Microbiome bile acid conjugation module -- gut bacteria deconjugate and ' +
      'dehydroxylate what the liver secretes.',
    idType: 'kegg',
    ids: ['C00695', 'C04483', 'C02528', 'C01921', 'C03990', 'C07880', 'C05465'],
  },
  {
    label: '#3',
    title:
      'HMDB: the tryptophan-kynurenine axis, from tryptophan through kynurenine and ' +
      'its downstream neuroactive metabolites, against the serotonin branch.',
    idType: 'hmdb',
    ids: [
      'HMDB0000929',
      'HMDB0000684',
      'HMDB0000715',
      'HMDB0011631',
      'HMDB0000232',
      'HMDB0001123',
      'HMDB0000259',
      'HMDB0000881',
    ],
  },
  {
    label: '#4',
    title:
      'PhenoMAP Lab IDs: the three branched-chain amino acids together with their ' +
      'branched-chain keto acids -- the classic insulin-resistance signature.',
    idType: 'lab_id',
    ids: ['PME006923', 'PME006920', 'PME006975', 'PME006790', 'PME004034', 'PME000363'],
  },
]

function parseIds(text) {
  return text
    .split(/[\s,;]+/)
    .map((s) => s.trim())
    .filter(Boolean)
}

const inputIdCount = computed(() => parseIds(idsText.value).length)
const unmatchedRows = computed(() => result.value?.unmatched_input ?? [])

// The table only ever lists significant modules -- there's no "all modules"
// view. isSignificant is recomputed here (not read off the backend's own
// Significant flag, which is always FDR-based) so it responds to sigBasis.
const visibleRows = computed(() => (result.value?.enrichment ?? []).filter(isSignificant))
const significantCount = computed(() => visibleRows.value.length)
const totalPages = computed(() => Math.max(1, Math.ceil(visibleRows.value.length / pageSize.value)))
const pagedRows = computed(() => visibleRows.value.slice((page.value - 1) * pageSize.value, page.value * pageSize.value))
const rangeStart = computed(() => (visibleRows.value.length ? (page.value - 1) * pageSize.value + 1 : 0))
const rangeEnd = computed(() => Math.min(visibleRows.value.length, page.value * pageSize.value))

function setPage(p) {
  page.value = Math.min(totalPages.value, Math.max(1, Math.round(p)))
}

watch([visibleRows, pageSize], () => {
  if (page.value > totalPages.value) page.value = totalPages.value
})

// Keep the cache in sync so navigating away (e.g. clicking a module row) and
// back doesn't lose which tab/page/page-size the user was looking at.
watch([activeTab, page, pageSize], () => {
  if (result.value) persistState()
})

function overlapPct(row) {
  if (!row.Module_Set_Size) return 0
  return Math.min(100, (row.Overlap_N / row.Module_Set_Size) * 100)
}

// Overlap_Metabolite_Names comes back from the R service as a "; "-joined
// string (see collapse_text() in 01_module_enrichment.R) -- split it back
// into a list so the table can show which metabolites actually overlapped,
// not just the count.
function overlapNames(row) {
  const raw = row.Overlap_Metabolite_Names
  if (!raw) return []
  return String(raw)
    .split(';')
    .map((s) => s.trim())
    .filter(Boolean)
}

function formatRatio(v) {
  if (v === null || v === undefined || v === '') return '—'
  const n = Number(v)
  return Number.isFinite(n) ? `${n.toFixed(2)}x` : String(v)
}

function formatP(v) {
  if (v === null || v === undefined || v === '') return '—'
  const n = Number(v)
  if (!Number.isFinite(n)) return String(v)
  return n < 0.001 ? n.toExponential(2) : n.toFixed(3)
}

function applyDemo(demo) {
  idsText.value = demo.ids.join('\n')
  idType.value = demo.idType
}

function nodeRoute(moduleId) {
  return {
    path: `/node/Module/${encodeURIComponent(moduleId)}`,
    query: { returnTo: route.fullPath, returnLabel: 'Module Enrichment' },
  }
}

// ---------- bubble chart (log2 Enrichment Ratio vs -log10 FDR or P-value) ----------
// The y-axis follows the selected significance basis (sigBasis), so the
// chart, the significant coloring and the dashed cutoff line all use the
// same statistic.
// Only modules that actually share a metabolite with the input are plotted --
// modules with zero overlap have Enrichment_Ratio = 0 (log2 undefined) and
// carry no signal, so including them would just crowd the chart with points
// piled at one edge.
const chartPanelRef = ref(null)
const chartTooltip = ref({
  visible: false,
  id: '',
  title: '',
  overlap: '',
  moduleSize: '',
  ratio: '',
  sig: '',
  sigLabel: 'FDR',
  significant: false,
  x: 16,
  y: 16,
})

const MIN_LOG10_SIG_FLOOR = 1e-12

function sigValue(row) {
  const v = sigBasis.value === 'fdr' ? Number(row.FDR) : Number(row.P_Value)
  return Number.isFinite(v) ? v : 1
}

const chartPoints = computed(() => {
  if (!result.value?.enrichment) return []
  return result.value.enrichment
    .filter((r) => r.Overlap_N > 0 && Number.isFinite(Number(r.Enrichment_Ratio)) && Number(r.Enrichment_Ratio) > 0)
    .map((r) => ({
      id: r.Module_ID,
      title: r.title || r.Module_ID,
      x: Math.log2(Number(r.Enrichment_Ratio)),
      sig: sigValue(r),
      overlap: r.Overlap_N,
      moduleSize: r.Module_Set_Size,
      significant: isSignificant(r),
    }))
    .map((p) => ({ ...p, y: -Math.log10(Math.max(p.sig, MIN_LOG10_SIG_FLOOR)) }))
})

const CHART_WIDTH = 960
const CHART_HEIGHT = 440
const CHART_MARGIN = { top: 30, right: 34, bottom: 46, left: 56 }

function niceTicks(min, max, count) {
  if (!Number.isFinite(min) || !Number.isFinite(max) || min === max) return [min ?? 0]
  const step = (max - min) / (count - 1)
  return Array.from({ length: count }, (_, i) => min + step * i)
}

const chartLayout = computed(() => {
  const points = chartPoints.value
  const plotLeft = CHART_MARGIN.left
  const plotRight = CHART_WIDTH - CHART_MARGIN.right
  const plotTop = CHART_MARGIN.top
  const plotBottom = CHART_HEIGHT - CHART_MARGIN.bottom

  if (!points.length) {
    return {
      width: CHART_WIDTH,
      height: CHART_HEIGHT,
      plotLeft,
      plotRight,
      plotTop,
      plotBottom,
      points: [],
      xTicks: [],
      yTicks: [],
      zeroX: plotLeft,
      thresholdY: null,
      sizeLegend: [],
    }
  }

  const xs = points.map((p) => p.x)
  const ys = points.map((p) => p.y)
  const overlaps = points.map((p) => p.overlap)
  const xPad = Math.max(0.5, (Math.max(...xs) - Math.min(...xs)) * 0.1)
  const xMin = Math.min(0, Math.min(...xs) - xPad)
  const xMax = Math.max(...xs) + xPad
  const thresholdRaw = -Math.log10(sigCutoff.value || 0.05)
  const yMin = 0
  const yMax = Math.max(...ys, thresholdRaw) * 1.15 || 1
  const rMin = Math.min(...overlaps)
  const rMax = Math.max(...overlaps)

  const scaleX = (x) => plotLeft + ((x - xMin) / (xMax - xMin || 1)) * (plotRight - plotLeft)
  const scaleY = (y) => plotBottom - ((y - yMin) / (yMax - yMin || 1)) * (plotBottom - plotTop)
  const scaleR = (n) => {
    if (rMax === rMin) return 8
    const t = Math.sqrt((n - rMin) / (rMax - rMin))
    return 5 + t * 17
  }

  const mappedPoints = points
    .map((p, i) => ({
      ...p,
      px: scaleX(p.x),
      py: scaleY(p.y),
      r: scaleR(p.overlap),
      delay: i,
    }))
    // Draw larger bubbles first so smaller ones aren't hidden underneath.
    .sort((a, b) => b.r - a.r)

  const xTicks = niceTicks(xMin, xMax, 5).map((v) => ({ value: v, px: scaleX(v), label: v.toFixed(1) }))
  const yTicks = niceTicks(yMin, yMax, 5).map((v) => ({ value: v, px: scaleY(v), label: v.toFixed(1) }))
  // The y-axis is -log10 of the selected basis, so the cutoff for that
  // same basis always maps onto it.
  const thresholdY = thresholdRaw >= yMin && thresholdRaw <= yMax ? scaleY(thresholdRaw) : null

  const sizeLegend =
    rMax === rMin
      ? []
      : [
          { n: rMin, r: scaleR(rMin) },
          { n: rMax, r: scaleR(rMax) },
        ]

  return {
    width: CHART_WIDTH,
    height: CHART_HEIGHT,
    plotLeft,
    plotRight,
    plotTop,
    plotBottom,
    points: mappedPoints,
    xTicks,
    yTicks,
    zeroX: scaleX(0),
    thresholdY,
    sizeLegend,
  }
})

function moveChartTooltip(event) {
  const panel = chartPanelRef.value
  if (!panel) return
  const rect = panel.getBoundingClientRect()
  const width = 220
  const height = 130
  chartTooltip.value.x = Math.max(8, Math.min(event.clientX - rect.left + 14, rect.width - width))
  chartTooltip.value.y = Math.max(8, Math.min(event.clientY - rect.top + 14, rect.height - height))
}

function showChartTooltip(pt, event) {
  chartTooltip.value = {
    ...chartTooltip.value,
    visible: true,
    id: pt.id,
    title: pt.title,
    overlap: pt.overlap,
    moduleSize: pt.moduleSize,
    ratio: `${Math.pow(2, pt.x).toFixed(2)}x`,
    sig: formatP(pt.sig),
    sigLabel: sigBasisLabel.value,
    significant: pt.significant,
  }
  moveChartTooltip(event)
}

function hideChartTooltip() {
  chartTooltip.value.visible = false
  chartTooltip.value.id = ''
}

function csvEscape(v) {
  const s = v === null || v === undefined ? '' : String(v)
  return /[",\n]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s
}

function exportCsv() {
  const cols = [
    'Module_ID',
    'title',
    'hypothesis_type',
    'confidence_label',
    'Overlap_N',
    'Overlap_Metabolite_Names',
    'Module_Set_Size',
    'Enrichment_Ratio',
    'P_Value',
    'FDR',
    'Significant',
  ]
  const lines = [cols.join(',')]
  for (const row of visibleRows.value) {
    lines.push(cols.map((c) => csvEscape(row[c])).join(','))
  }
  const blob = new Blob([lines.join('\n')], { type: 'text/csv;charset=utf-8;' })
  const url = URL.createObjectURL(blob)
  const a = document.createElement('a')
  a.href = url
  a.download = 'module_enrichment_significant.csv'
  a.click()
  URL.revokeObjectURL(url)
}

async function run() {
  const ids = parseIds(idsText.value)
  if (ids.length === 0) {
    error.value = 'Paste at least one ID.'
    return
  }
  loading.value = true
  error.value = ''
  result.value = null
  showUnmatched.value = false
  activeTab.value = 'visual'
  page.value = 1
  try {
    // fdr_cutoff is a required backend param either way -- its own
    // Significant column isn't used here, since significance is recomputed
    // client-side against whichever basis (FDR or P-value) is selected.
    result.value = await runEnrichment({
      ids,
      id_type: idType.value,
      fdr_cutoff: sigCutoff.value,
      min_overlap: minOverlap.value,
      // Omitted entirely when everything is checked, so the default request
      // is byte-identical to what it was before the filters existed.
      ...(allConfidenceSelected.value ? {} : { confidence_labels: confidenceSelected.value }),
      ...(allTypesSelected.value ? {} : { hypothesis_types: hypothesisSelected.value }),
    })
    persistState()
  } catch (e) {
    error.value = e.message
  } finally {
    loading.value = false
  }
}

onMounted(() => {
  restoreState()
  loadFilterMeta()
  document.addEventListener('click', onDocumentClick)
})

onBeforeUnmount(() => {
  document.removeEventListener('click', onDocumentClick)
})
</script>

<style scoped>
.me {
  min-height: calc(100vh - 69px);
  background: #f7f8fa;
}
.me-container {
  max-width: none;
  margin: 0 auto;
  padding: 0 40px;
  width: min(90vw, 1680px);
  box-sizing: border-box;
}

/* ---------- header + form band ---------- */
.me-header {
  position: relative;
  /* The filter dropdowns open downward out of this band, so it must not
     clip them -- the network backdrop below does its own clipping instead.
     z-index puts the whole band (and anything overflowing it) above
     .me-results, which comes later in the DOM. */
  overflow: visible;
  z-index: 2;
  background:
    radial-gradient(circle at 14% 20%, rgba(143, 215, 234, 0.24), transparent 28%),
    radial-gradient(circle at 86% 18%, rgba(79, 181, 155, 0.14), transparent 32%),
    linear-gradient(135deg, #123a55 0%, #245c7e 52%, #174564 100%);
  padding: 44px 0 34px;
  border-bottom: 0;
}
.analysis-network-bg {
  position: absolute;
  inset: 0;
  overflow: hidden;
  opacity: 0.7;
  --network-line: rgba(210, 231, 244, 0.34);
  --network-node: rgba(216, 231, 239, 0.92);
  --network-line-width: 0.85;
}
.me-header .me-container {
  position: relative;
  z-index: 1;
}
.me-header h1 {
  margin: 0 0 24px;
  font-size: 36px;
  font-weight: 800;
  letter-spacing: -0.01em;
  color: #fff;
}

.me-form {
  background: #fff;
  border: 1px solid rgba(226, 232, 240, 0.92);
  border-radius: 12px;
  padding: 26px 28px;
  box-shadow: 0 18px 42px -30px rgba(4, 7, 20, 0.65);
}
.me-ids-label-row {
  display: flex;
  align-items: baseline;
  justify-content: space-between;
  margin-bottom: 6px;
}
.me-ids-label-row label {
  font-size: 12px;
  font-weight: 700;
  letter-spacing: 0.05em;
  text-transform: uppercase;
  color: #9aa1c2;
}
.me-ids-block textarea {
  width: 100%;
  padding: 12px 14px;
  border-radius: 10px;
  border: 1px solid #d7dbe0;
  font-family: ui-monospace, 'SF Mono', Menlo, monospace;
  font-size: 13.5px;
  line-height: 1.6;
  resize: vertical;
  box-sizing: border-box;
  color: #1b1f24;
}
.me-ids-block textarea:focus {
  outline: none;
  border-color: #0f7c96;
}
.me-examples {
  display: flex;
  align-items: center;
  flex-wrap: wrap;
  gap: 8px;
  margin-top: 10px;
  font-size: 12px;
}
.me-examples > span {
  font-weight: 700;
  letter-spacing: 0.04em;
  text-transform: uppercase;
  color: #9aa1c2;
}
.me-example {
  padding: 5px 12px;
  border-radius: 999px;
  border: 1px solid #dfe3f0;
  background: #fff;
  color: #0f7c96;
  font-size: 12.5px;
  font-weight: 700;
  cursor: pointer;
}
.me-example:hover {
  border-color: #0f7c96;
  background: #eef8fa;
}

.me-form-controls {
  display: flex;
  align-items: flex-end;
  flex-wrap: wrap;
  gap: 18px;
  margin-top: 20px;
  padding-top: 20px;
  border-top: 1px solid #eef0f7;
}
.me-field {
  display: flex;
  flex-direction: column;
  gap: 6px;
}
.me-field-label {
  font-size: 12px;
  font-weight: 700;
  letter-spacing: 0.05em;
  text-transform: uppercase;
  color: #9aa1c2;
}
.me-segmented {
  display: inline-flex;
  border: 1px solid #dfe3f0;
  border-radius: 9px;
  padding: 2px;
  background: #f7f8fc;
}
.me-segmented button {
  border: none;
  background: transparent;
  padding: 7px 12px;
  border-radius: 7px;
  font-size: 13px;
  font-weight: 700;
  color: #6b7280;
  cursor: pointer;
  white-space: nowrap;
}
.me-segmented button.active {
  background: #fff;
  color: #0f7c96;
  box-shadow: 0 1px 2px rgba(27, 33, 69, 0.08);
}
.me-multi {
  position: relative;
}
.me-multi-trigger {
  display: inline-flex;
  align-items: center;
  justify-content: space-between;
  gap: 10px;
  min-width: 178px;
  padding: 8px 12px;
  border: 1px solid #dfe3f0;
  border-radius: 9px;
  background: #f7f8fc;
  font-size: 13px;
  font-weight: 700;
  color: #6b7280;
  cursor: pointer;
}
.me-multi-trigger.partial {
  color: #0f7c96;
  border-color: #bfe0e8;
  background: #fff;
}
.me-multi-trigger.open {
  border-color: #0f7c96;
  background: #fff;
}
.me-multi-caret {
  width: 15px;
  height: 15px;
  flex-shrink: 0;
  transition: transform 0.15s ease;
}
.me-multi-trigger.open .me-multi-caret {
  transform: rotate(180deg);
}
.me-multi-panel {
  position: absolute;
  z-index: 60;
  top: calc(100% + 6px);
  left: 0;
  min-width: 100%;
  width: max-content;
  max-width: 300px;
  padding: 6px;
  border: 1px solid #dfe3f0;
  border-radius: 10px;
  background: #fff;
  box-shadow: 0 12px 28px rgba(27, 33, 69, 0.14);
}
.me-multi-actions {
  display: flex;
  gap: 4px;
  padding: 2px 2px 6px;
  border-bottom: 1px solid #f0f1f6;
  margin-bottom: 4px;
}
.me-multi-actions button {
  border: none;
  background: transparent;
  padding: 4px 8px;
  border-radius: 6px;
  font-size: 12px;
  font-weight: 700;
  color: #0f7c96;
  cursor: pointer;
}
.me-multi-actions button:hover {
  background: #f0f8fa;
}
.me-multi-option {
  display: flex;
  align-items: center;
  gap: 9px;
  padding: 7px 8px;
  border-radius: 7px;
  cursor: pointer;
}
.me-multi-option:hover {
  background: #f7f8fc;
}
.me-multi-option input {
  width: 15px;
  height: 15px;
  accent-color: #0f7c96;
  cursor: pointer;
  flex-shrink: 0;
}
.me-multi-name {
  font-size: 13px;
  font-weight: 600;
  color: #1b2145;
  white-space: nowrap;
}
.me-multi-count {
  margin-left: auto;
  padding-left: 12px;
  font-size: 12px;
  font-weight: 700;
  color: #9aa1c2;
  font-variant-numeric: tabular-nums;
}
.me-universe-hint {
  flex-basis: 100%;
  margin: 2px 0 0;
  color: #6b7280;
  font-size: 12.5px;
  line-height: 1.4;
}
.me-universe-hint.warn {
  color: #b3562c;
  font-weight: 600;
}
.me-number-field input {
  width: 96px;
  padding: 8px 10px;
  border-radius: 8px;
  border: 1px solid #d7dbe0;
  font-size: 14px;
  font-weight: 700;
  color: #1b1f24;
}
.me-number-field input:focus {
  outline: none;
  border-color: #0f7c96;
}
.me-submit {
  margin-left: auto;
  display: inline-flex;
  align-items: center;
  justify-content: center;
  gap: 8px;
  /* "Run" and "Running..." are very different widths -- pin a floor so the
     button does not jump around when a query starts. */
  min-width: 116px;
  padding: 12px 24px;
  border-radius: 10px;
  border: none;
  background: #245c7e;
  color: #fff;
  font-weight: 700;
  font-size: 15px;
  cursor: pointer;
}
.me-submit:hover:not(:disabled) {
  background: #174564;
}
.me-submit:disabled {
  background: #c3c8e0;
  cursor: not-allowed;
}
.me-submit .spinner {
  border-color: rgba(255, 255, 255, 0.4);
  border-top-color: #fff;
}

/* ---------- results ---------- */
.me-results {
  padding: 36px 40px 72px;
}
.state-block {
  display: flex;
  align-items: flex-start;
  gap: 10px;
  padding: 20px 22px;
  border-radius: 12px;
  background: #fff;
  border: 1px dashed #dfe3f0;
  color: #8790b3;
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
  border-style: solid;
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
  flex-shrink: 0;
}
@keyframes spin {
  to {
    transform: rotate(360deg);
  }
}

/* ---------- onboarding empty state ---------- */
.card {
  background: #fff;
  border: 1px solid #e2e5ea;
  border-radius: 14px;
  padding: 22px;
}
.empty-state-card {
  padding: 40px 24px;
}
.empty-state {
  max-width: 460px;
  margin: 0 auto;
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

/* ---------- export button (sits at the end of the tabs row) ---------- */
.me-export {
  margin-left: auto;
  display: inline-flex;
  align-items: center;
  gap: 7px;
  padding: 9px 14px;
  border-radius: 9px;
  border: 1px solid #dfe3f0;
  background: #fff;
  color: #0f7c96;
  font-size: 13px;
  font-weight: 700;
  cursor: pointer;
}
.me-export:hover {
  border-color: #0f7c96;
  background: #eef8fa;
}
.me-export svg {
  width: 15px;
  height: 15px;
}

/* ---------- unmatched panel ---------- */
.me-unmatched {
  margin-bottom: 18px;
  padding: 14px 18px;
}
.me-unmatched-toggle {
  display: flex;
  align-items: center;
  gap: 8px;
  width: 100%;
  border: none;
  background: none;
  padding: 0;
  color: #55607a;
  font-size: 13.5px;
  font-weight: 700;
  cursor: pointer;
  text-align: left;
}
.me-chevron {
  width: 14px;
  height: 14px;
  flex-shrink: 0;
  color: #9aa1c2;
  transition: transform 0.15s ease;
}
.me-chevron.open {
  transform: rotate(90deg);
}
.me-chip-list {
  display: flex;
  flex-wrap: wrap;
  gap: 6px;
  margin-top: 12px;
}
.me-chip {
  padding: 3px 10px;
  border-radius: 999px;
  background: #f7f8fb;
  border: 1px solid #eef0f7;
  color: #55607a;
  font-size: 12px;
  font-family: ui-monospace, 'SF Mono', Menlo, monospace;
}

/* ---------- bubble chart ---------- */
.me-chart-card {
  margin-bottom: 18px;
  padding: 22px 24px 14px;
}
.me-chart-head {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  justify-content: space-between;
  gap: 14px;
  margin-bottom: 14px;
}
.me-chart-head-text {
  flex: 1 1 auto;
  min-width: 0;
}
.me-chart-head h2 {
  margin: 0 0 4px;
  font-size: 15px;
  font-weight: 800;
  color: #1b2145;
}
.me-chart-head p {
  margin: 0;
  color: #8790b3;
  font-size: 12.5px;
  line-height: 1.55;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}
.me-chart-legend {
  display: flex;
  align-items: center;
  gap: 18px;
  flex-shrink: 0;
}
.me-legend-group {
  display: inline-flex;
  align-items: center;
  gap: 10px;
  font-size: 12px;
  font-weight: 700;
  color: #55607a;
  white-space: nowrap;
}
.me-swatch {
  display: inline-block;
  width: 10px;
  height: 10px;
  border-radius: 50%;
  margin-right: 5px;
  background: rgba(154, 161, 194, 0.5);
  border: 1.5px solid #9aa1c2;
}
.me-swatch.sig {
  background: rgba(26, 143, 94, 0.35);
  border-color: #1a8f5e;
}
.me-size-legend {
  padding-left: 16px;
  border-left: 1px solid #eef0f7;
}
.me-size-legend-svg {
  display: block;
  overflow: visible;
}
.me-size-legend-dot {
  fill: rgba(139, 147, 184, 0.22);
  stroke: #9aa1c2;
  stroke-width: 1.2;
  stroke-dasharray: 2.5 2;
}
.me-chart-empty {
  display: flex;
  align-items: center;
  justify-content: center;
  min-height: 240px;
  color: #a6adbf;
  font-size: 13.5px;
  font-weight: 600;
}
.me-chart-panel {
  position: relative;
  border-radius: 12px;
  background:
    radial-gradient(ellipse at 50% 0%, rgba(143, 215, 234, 0.12) 0%, rgba(143, 215, 234, 0) 60%),
    #fbfbfe;
  padding: 4px;
}
.me-chart-svg {
  display: block;
  width: 100%;
  height: auto;
}
.me-chart-frame {
  fill: #ffffff;
  stroke: #e9ebf2;
  stroke-width: 1;
}
.me-chart-grid line {
  stroke: #eef0f7;
  stroke-width: 1;
  stroke-dasharray: 3 4;
}
.me-chart-threshold {
  stroke: #b3562c;
  stroke-width: 1.3;
  stroke-dasharray: 5 4;
  opacity: 0.65;
}
.me-chart-zero {
  stroke: #c3c8e0;
  stroke-width: 1.2;
  stroke-dasharray: 2 3;
}
.me-chart-ref-label {
  font-size: 10px;
  font-weight: 700;
  fill: #a6adbf;
  paint-order: stroke;
  stroke: #fbfbfe;
  stroke-width: 4px;
}
.me-chart-tick {
  font-size: 10.5px;
  fill: #9aa1c2;
  font-weight: 600;
}
.me-chart-axis-label {
  font-size: 11px;
  fill: #6b7280;
  font-weight: 700;
}
.me-chart-point {
  fill: rgba(154, 161, 194, 0.45);
  stroke: #9aa1c2;
  stroke-width: 1.2;
  cursor: pointer;
  transform-box: fill-box;
  transform-origin: center;
  opacity: 0;
  animation: me-bubble-in 0.45s cubic-bezier(0.34, 1.56, 0.64, 1) forwards;
  transition: transform 0.15s ease, filter 0.15s ease, stroke-width 0.15s ease, fill-opacity 0.15s ease;
}
.me-chart-point.significant {
  fill: rgba(26, 143, 94, 0.4);
  stroke: #1a8f5e;
}
.me-chart-point:hover,
.me-chart-point.hovered {
  stroke-width: 2.2;
  fill-opacity: 0.75;
  transform: scale(1.22);
  filter: drop-shadow(0 4px 10px rgba(27, 33, 69, 0.3));
}
@keyframes me-bubble-in {
  from {
    opacity: 0;
    transform: scale(0.3);
  }
  to {
    opacity: 1;
    transform: scale(1);
  }
}
.me-chart-tooltip {
  position: absolute;
  z-index: 4;
  width: 220px;
  padding: 10px 12px;
  border: 1px solid rgba(31, 41, 55, 0.12);
  border-left: 3px solid #9aa1c2;
  border-radius: 8px;
  background: rgba(255, 255, 255, 0.97);
  box-shadow: 0 14px 34px rgba(27, 33, 69, 0.16);
  backdrop-filter: blur(8px);
  pointer-events: none;
}
.me-chart-tooltip.significant {
  border-left-color: #1a8f5e;
}
.me-chart-tooltip-title {
  font-size: 12.5px;
  font-weight: 800;
  color: #1b2145;
  line-height: 1.3;
  margin-bottom: 6px;
}
.me-chart-tooltip dl {
  display: grid;
  grid-template-columns: 52px minmax(0, 1fr);
  gap: 4px 8px;
  margin: 0;
  font-size: 12px;
}
.me-chart-tooltip dt {
  color: #9aa1c2;
  font-weight: 700;
}
.me-chart-tooltip dd {
  margin: 0;
  color: #30364a;
}

/* ---------- tabs ---------- */
.me-tabs {
  display: flex;
  align-items: center;
  flex-wrap: wrap;
  gap: 6px;
  margin-bottom: 16px;
}
.me-tab {
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
.me-tab svg {
  width: 16px;
  height: 16px;
}
.me-tab:hover {
  background: #eef8fa;
}
.me-tab.active {
  background: #fff;
  border-color: #cdebf1;
  color: #0f7c96;
  box-shadow: 0 1px 2px rgba(27, 33, 69, 0.05);
}
.me-tab-count {
  font-size: 11.5px;
  font-weight: 700;
  background: #eef8fa;
  color: #0f7c96;
  padding: 1px 7px;
  border-radius: 999px;
}
.me-tab.active .me-tab-count {
  background: #0f7c96;
  color: #fff;
}

/* ---------- results table ---------- */
.results-table-wrap {
  background: #fff;
  border: 1px solid #e9ebf2;
  border-radius: 14px;
  overflow-x: auto;
  overflow-y: hidden;
  box-shadow: 0 1px 2px rgba(17, 24, 60, 0.04);
}
.me-table {
  display: grid;
  grid-template-columns: minmax(220px, 1.2fr) 104px 126px minmax(320px, 1.55fr) 120px 100px 100px;
  min-width: 1180px;
}
.me-thead {
  display: contents;
}
.me-thead span {
  padding: 12px 16px;
  background: #f7f8fb;
  color: #8790b3;
  font-size: 11.5px;
  font-weight: 800;
  letter-spacing: 0.04em;
  text-transform: uppercase;
  border-bottom: 1px solid #eef0f7;
}
.me-thead span[title] {
  cursor: help;
  text-decoration: underline dotted;
  text-decoration-color: #c3c8db;
  text-underline-offset: 3px;
}
.me-row {
  display: contents;
}
.me-row > span {
  display: flex;
  align-items: center;
  padding: 13px 16px;
  border-bottom: 1px solid #eef0f7;
  color: #1b1f24;
  font-size: 13.5px;
  min-width: 0;
}
.me-row:hover > span {
  background: #f9faff;
}
.me-row.significant > span:first-child {
  box-shadow: inset 3px 0 0 #1a8f5e;
}
.me-cell-module {
  display: flex !important;
  flex-direction: column;
  gap: 2px;
  align-items: flex-start !important;
}
.me-module-title {
  font-weight: 700;
  color: #1b2145;
  line-height: 1.35;
}
.me-module-link {
  color: inherit;
  text-decoration: none;
}
.me-module-link:hover .me-module-title {
  color: #0f7c96;
  text-decoration: underline;
  text-underline-offset: 3px;
}
.me-module-id {
  font-size: 11px;
  font-family: ui-monospace, 'SF Mono', Menlo, monospace;
  color: #9aa1c2;
}
.me-cell-center {
  justify-content: flex-start;
  min-width: 0;
}
.me-dash {
  color: #c3c8db;
}
.tag {
  display: inline-block;
  max-width: 100%;
  font-size: 11.5px;
  font-weight: 600;
  padding: 3px 9px;
  border-radius: 999px;
  background: rgba(26, 143, 94, 0.12);
  color: #1a8f5e;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
  box-sizing: border-box;
}
.confidence-badge {
  display: inline-block;
  font-size: 11px;
  font-weight: 700;
  text-transform: uppercase;
  letter-spacing: 0.02em;
  padding: 3px 10px;
  border-radius: 999px;
  white-space: nowrap;
}
.tier-high {
  background: rgba(26, 143, 94, 0.12);
  color: #1a8f5e;
}
.tier-medium {
  background: rgba(179, 86, 44, 0.12);
  color: #b3562c;
}
.tier-low {
  background: #eef0f7;
  color: #6b7280;
}
.me-overlap {
  flex-direction: column !important;
  align-items: flex-start !important;
  gap: 5px;
  min-width: 0;
  width: 100%;
}
.me-overlap-value {
  font-weight: 700;
  font-size: 12.5px;
  color: #293247;
}
.me-metabolites {
  min-width: 0;
  align-items: flex-start !important;
}
.me-overlap-names {
  display: block;
  width: 100%;
  font-size: 12.5px;
  font-weight: 600;
  color: #55607a;
  line-height: 1.45;
  white-space: normal;
  overflow-wrap: anywhere;
  word-break: normal;
}
.me-overlap-bar {
  width: 100%;
  height: 5px;
  border-radius: 999px;
  background: #eef0f7;
  overflow: hidden;
}
.me-overlap-fill {
  display: block;
  height: 100%;
  border-radius: 999px;
  background: #0f7c96;
}
.me-er {
  font-weight: 700;
  color: #1b2145;
}
.me-fdr {
  font-family: ui-monospace, 'SF Mono', Menlo, monospace;
  font-size: 12.5px;
  color: #55607a;
}
.me-fdr.significant {
  color: #1a8f5e;
  font-weight: 700;
}
/* ---------- pagination toolbar ---------- */
.me-pagination-toolbar {
  display: flex;
  align-items: center;
  flex-wrap: wrap;
  gap: 10px 16px;
  margin-top: 16px;
  padding: 10px 16px;
  background: #fff;
  border: 1px solid #e9ebf2;
  border-radius: 12px;
}
.me-pagination-range {
  color: #5f6b84;
  font-size: 12.5px;
  font-weight: 700;
  margin-right: auto;
}
.me-pagination-size,
.me-pagination-pager label {
  display: inline-flex;
  align-items: center;
  gap: 7px;
  color: #667085;
  font-size: 12px;
  font-weight: 700;
}
.me-pagination-size select,
.me-pagination-pager select {
  min-width: 58px;
  height: 30px;
  padding: 0 8px;
  border: 1px solid #dfe3f0;
  border-radius: 8px;
  background: #fff;
  color: #293247;
  font-size: 12.5px;
  font-weight: 700;
}
.me-pagination-size select:focus,
.me-pagination-pager select:focus {
  outline: none;
  border-color: #0f7c96;
}
.me-pagination-pager {
  display: inline-flex;
  align-items: center;
  gap: 8px;
}
.me-pagination-pager button {
  display: inline-flex;
  align-items: center;
  gap: 5px;
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
.me-pagination-pager button svg {
  width: 14px;
  height: 14px;
}
.me-pagination-pager button:hover:not(:disabled) {
  border-color: #bfc7ea;
  background: #f6f7ff;
}
.me-pagination-pager button:disabled {
  color: #a6adbf;
  background: #f7f8fb;
  cursor: not-allowed;
}

@media (max-width: 900px) {
  .me-table {
    grid-template-columns: minmax(0, 1fr);
    min-width: 0;
  }
  .me-thead {
    display: none;
  }
  .me-row {
    display: flex !important;
    flex-direction: column;
    padding: 14px 16px;
    border-bottom: 1px solid #eef0f7;
    gap: 8px;
  }
  .me-row > span {
    padding: 0;
    border-bottom: none;
  }
  .me-row.significant > span:first-child {
    box-shadow: none;
  }
  .me-row.significant {
    box-shadow: inset 3px 0 0 #1a8f5e;
  }
}

@media (max-width: 720px) {
  .me-container {
    padding: 0 20px;
  }
  .me-form {
    padding: 22px 20px;
  }
  .me-results {
    padding: 24px 20px 48px;
  }
  .me-submit {
    margin-left: 0;
    width: 100%;
    justify-content: center;
  }
  .me-pagination-toolbar {
    align-items: stretch;
  }
  .me-pagination-range {
    width: 100%;
    margin-right: 0;
  }
  .me-pagination-pager {
    width: 100%;
    justify-content: space-between;
  }
}
</style>
