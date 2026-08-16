<template>
  <div class="home">
    <!-- ============ HERO ============ -->
    <section class="hero">
      <AnimatedNetworkField class="hero-bg" :seed="7" />

      <div class="hero-inner">
        <span class="eyebrow">Phenotype-aware Metabolic Module Atlas Portal</span>
        <h1>PhenoMAP</h1>
        <p class="tagline">
          A phenotype-centered knowledge graph connecting phenotypes,
          metabolomics studies, co-regulated metabolite modules, and
          individual metabolites.
        </p>

        <div class="search-panel" :style="{ '--type-width': typeWidth }">
          <form class="search-bar" @submit.prevent="goToSearch()">
            <div class="type-select-wrap">
              <select v-model="label" class="type-select" aria-label="Search type">
                <option v-for="opt in labelOptions" :key="opt.value" :value="opt.value">
                  {{ opt.text }}
                </option>
              </select>
            </div>
            <span class="search-divider" aria-hidden="true"></span>
            <input
              v-model="query"
              type="text"
              :placeholder="currentPlaceholder"
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
            <span class="search-divider right" aria-hidden="true"></span>
            <button type="submit" class="search-icon-btn" aria-label="Search">
              <svg class="search-icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                <circle cx="11" cy="11" r="7" />
                <line x1="21" y1="21" x2="16.65" y2="16.65" />
              </svg>
            </button>
          </form>
        </div>

        <div class="example-chips" v-if="!query && currentExamples.length">
          <span class="chip-label">Try</span>
          <button
            v-for="ex in currentExamples"
            :key="ex"
            type="button"
            class="chip"
            @click="goToSearch(ex)"
          >
            {{ ex }}
          </button>
        </div>
      </div>

    </section>

    <!-- ============ HOMEPAGE BODY ============ -->
      <section class="stats-strip">
        <div class="container stats-grid">
          <div class="stat-card" v-for="s in statCards" :key="s.key">
            <span class="stat-icon" :data-label="s.key">
              <svg v-if="s.key === 'Metabolite'" viewBox="0 0 24 24" fill="none" stroke="#fff" stroke-width="1.7">
                <circle cx="6" cy="6" r="2.3" />
                <circle cx="18" cy="6" r="2.3" />
                <circle cx="12" cy="17" r="2.3" />
                <path d="M7.7 7.3 10.6 14.9M16.3 7.3 13.4 14.9M8.3 6h7.4" />
              </svg>
              <svg v-else-if="s.key === 'Module'" viewBox="0 0 24 24" fill="none" stroke="#fff" stroke-width="1.7">
                <circle cx="6" cy="6.5" r="2.1" />
                <circle cx="18" cy="6.5" r="2.1" />
                <circle cx="6" cy="17.5" r="2.1" />
                <circle cx="18" cy="17.5" r="2.1" />
                <circle cx="12" cy="12" r="2.3" />
                <path d="M7.6 7.9 10.3 10.6M16.4 7.9 13.7 10.6M7.6 16.1 10.3 13.4M16.4 16.1 13.7 13.4" />
              </svg>
              <svg v-else-if="s.key === 'Study'" viewBox="0 0 24 24" fill="none" stroke="#fff" stroke-width="1.7">
                <rect x="4" y="5" width="16" height="15" rx="2" />
                <path d="M8 3v4M16 3v4M4 10h16M8.5 14h3M8.5 17h6" />
              </svg>
              <svg v-else viewBox="0 0 24 24" fill="none" stroke="#fff" stroke-width="1.7" stroke-linejoin="round">
                <path d="M3 13h3.2l2 6.5L13 4.5l1.8 8.5H21" />
              </svg>
            </span>
            <div class="stat-text">
              <div class="stat-number">{{ s.display }}</div>
              <div class="stat-label">{{ s.label }}</div>
            </div>
          </div>
        </div>
      </section>

      <div class="analysis-jump-row">
        <button type="button" class="analysis-jump" aria-label="Jump to Analysis Tools" @click="scrollToAnalysisTools">
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3">
            <path d="M5 8.5 12 15.5 19 8.5" />
          </svg>
        </button>
      </div>

      <section id="analysis-tools" class="container-wide features-section">
        <h2 class="section-title">Analysis Tools</h2>
        <div class="feature-grid">
          <router-link to="/search" class="feature-card">
            <div class="tool-visual">
              <svg viewBox="0 0 96 72" fill="none" aria-hidden="true">
                <rect x="19" y="18" width="13" height="28" rx="2" fill="#f6a23a" stroke="#24485f" stroke-width="3" />
                <rect x="39" y="10" width="13" height="36" rx="2" fill="#4fb59b" stroke="#24485f" stroke-width="3" />
                <rect x="59" y="25" width="13" height="21" rx="2" fill="#5aa0c8" stroke="#24485f" stroke-width="3" />
                <path d="M16 52h60" stroke="#24485f" stroke-width="4" stroke-linecap="round" />
                <circle cx="67" cy="22" r="13" stroke="#24485f" stroke-width="4" />
                <path d="M76 31l11 11" stroke="#24485f" stroke-width="5" stroke-linecap="round" />
              </svg>
            </div>
            <h3>Entity Search</h3>
            <p>Search or browse studies, phenotypes, modules, and metabolites across the graph.</p>
          </router-link>

          <router-link to="/path" class="feature-card">
            <div class="tool-visual">
              <svg viewBox="0 0 96 72" fill="none" aria-hidden="true">
                <path d="M20 50c10-23 25-23 34-12s18 11 25-11" stroke="#24485f" stroke-width="5" stroke-linecap="round" />
                <circle cx="20" cy="50" r="8" fill="#4fb59b" stroke="#24485f" stroke-width="3" />
                <circle cx="48" cy="34" r="9" fill="#f6a23a" stroke="#24485f" stroke-width="3" />
                <circle cx="78" cy="24" r="8" fill="#5aa0c8" stroke="#24485f" stroke-width="3" />
                <circle cx="61" cy="45" r="6" fill="#ef7f58" stroke="#24485f" stroke-width="3" />
              </svg>
            </div>
            <h3>Path Query</h3>
            <p>Explore how any two entities in the PhenoMAP knowledge graph are connected.</p>
          </router-link>

          <router-link to="/enrichment" class="feature-card">
            <div class="tool-visual">
              <svg viewBox="0 0 96 72" fill="none" aria-hidden="true">
                <path d="M17 53h62M17 53V17" stroke="#24485f" stroke-width="4" stroke-linecap="round" />
                <path d="M22 42h52" stroke="#24485f" stroke-width="2.4" stroke-linecap="round" stroke-dasharray="4 6" opacity="0.45" />
                <path d="M22 48 35 39 46 43 58 28 74 20" stroke="#24485f" stroke-width="5" stroke-linecap="round" stroke-linejoin="round" />
                <circle cx="35" cy="39" r="5.5" fill="#f6a23a" stroke="#24485f" stroke-width="3" />
                <circle cx="58" cy="28" r="6.5" fill="#4fb59b" stroke="#24485f" stroke-width="3" />
                <circle cx="74" cy="20" r="5.5" fill="#5aa0c8" stroke="#24485f" stroke-width="3" />
              </svg>
            </div>
            <h3>Module Enrichment</h3>
            <p>Paste a list of interested metabolite IDs and find which modules they're enriched in.</p>
          </router-link>

          <router-link to="/chat" class="feature-card">
            <div class="tool-visual">
              <svg viewBox="0 0 96 72" fill="none" aria-hidden="true">
                <path d="M18 20h60v31H36L22 61V51h-4z" fill="#fff" stroke="#24485f" stroke-width="4" stroke-linejoin="round" />
                <circle cx="38" cy="36" r="4" fill="#f6a23a" />
                <circle cx="50" cy="36" r="4" fill="#4fb59b" />
                <circle cx="62" cy="36" r="4" fill="#5aa0c8" />
                <path d="M25 13c7-6 17-8 28-5" stroke="#ef7f58" stroke-width="4" stroke-linecap="round" />
              </svg>
            </div>
            <h3>PhenoMAP Chat</h3>
            <p>Ask questions about the graph in plain language and get cited, sourced answers.</p>
          </router-link>
        </div>
      </section>

      <div class="analysis-jump-row about-jump-row">
        <button type="button" class="analysis-jump" aria-label="Jump to About PhenoMAP" @click="scrollToAboutPhenoMap">
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3">
            <path d="M5 8.5 12 15.5 19 8.5" />
          </svg>
        </button>
      </div>

      <section id="about-phenomap" class="container-wide schema-section">
        <h2 class="section-title">About PhenoMAP</h2>
        <p class="hint">
          PhenoMAP is organized as a phenotype-centered knowledge graph
          comprising four core entity types: phenotypes, studies, dysregulated
          metabolic modules, and metabolites. Studies are linked to their
          normalized phenotypes, modules are connected to the studies in which
          they are identified, and metabolites are linked to both their
          corresponding modules and the underlying metabolic reaction network.
          Similarity relationships are further established between modules
          based on their metabolic composition and functional interpretation,
          enabling cross-study and cross-phenotype comparison, evidence
          tracing, and module-level querying.
        </p>
        <div class="schema-image-frame">
          <img src="/phenomap.png" alt="PhenoMAP knowledge graph schema" />
        </div>
      </section>
  </div>
</template>

<script setup>
import { onMounted, ref, reactive, computed } from 'vue'
import { useRouter } from 'vue-router'
import { getStats } from '../api.js'
import AnimatedNetworkField from '../components/AnimatedNetworkField.vue'

const router = useRouter()

// This is just a simplified entry point into the real Search page (under
// Analysis) -- submitting here never runs a query or shows results inline,
// it only navigates to /search?q=...&label=..., which does the actual
// search (same as Path Query / Module Enrichment each having their own page).
const query = ref('')
const label = ref('Module')

const labelOptions = [
  { value: 'Module', text: 'Module' },
  { value: 'Study', text: 'Study' },
  { value: 'Phenotype', text: 'Phenotype' },
  { value: 'Metabolite', text: 'Metabolite' },
]

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
const typeWidths = {
  Study: '108px',
  Module: '126px',
  Phenotype: '148px',
  Metabolite: '154px',
}
const typeWidth = computed(() => typeWidths[label.value] || '126px')

function clearQuery() {
  query.value = ''
}

function goToSearch(explicitQuery) {
  const q = (explicitQuery ?? query.value).trim()
  if (q.length < 2) return
  router.push({ path: '/search', query: { q, label: label.value } })
}

function scrollToAnalysisTools() {
  document.getElementById('analysis-tools')?.scrollIntoView({
    behavior: 'smooth',
    block: 'start',
  })
}

function scrollToAboutPhenoMap() {
  document.getElementById('about-phenomap')?.scrollIntoView({
    behavior: 'smooth',
    block: 'start',
  })
}

// --- live stats strip ---
const stats = ref(null)
const statOrder = ['Metabolite', 'Module', 'Study', 'Phenotype']
const statLabels = { Study: 'Studies', Phenotype: 'Phenotypes', Module: 'Modules', Metabolite: 'Metabolites' }

// Counts animate up from 0 on every load instead of just appearing.
const animatedCounts = reactive({ Study: 0, Phenotype: 0, Module: 0, Metabolite: 0 })

function animateCount(key, target, duration = 1800) {
  const start = performance.now()
  function step(now) {
    const t = Math.min((now - start) / duration, 1)
    const eased = 1 - Math.pow(1 - t, 5) // ease-out quint: fast start, long slow crawl to the finish
    animatedCounts[key] = Math.round(target * eased)
    if (t < 1) requestAnimationFrame(step)
  }
  requestAnimationFrame(step)
}

const statCards = computed(() => {
  return statOrder.map((key) => {
    const row = stats.value?.nodes?.find((n) => n.label === key)
    return {
      key,
      label: statLabels[key],
      display: row ? animatedCounts[key].toLocaleString() : '—',
    }
  })
})

onMounted(async () => {
  try {
    stats.value = await getStats()
    statOrder.forEach((key) => {
      const row = stats.value?.nodes?.find((n) => n.label === key)
      if (row) animateCount(key, row.count)
    })
  } catch (e) {
    // Homepage should still render fine without live counts.
  }
})
</script>

<style scoped>
.home {
  display: flex;
  flex-direction: column;
}
.container {
  max-width: 1080px;
  margin: 0 auto;
  padding: 0 24px;
  width: 100%;
  box-sizing: border-box;
}
/* Explore-the-platform cards and the schema diagram don't need to line up
   with the hero/stats-strip above -- a bit wider so the cards get more
   breathing room instead of matching that narrower column. */
.container-wide {
  max-width: 1280px;
  margin: 0 auto;
  padding: 0 24px;
  width: 100%;
  box-sizing: border-box;
}

/* ---------- hero ---------- */
.hero {
  position: relative;
  overflow: hidden;
  background: radial-gradient(circle at 50% 42%, rgba(42, 90, 128, 0.5), transparent 34%),
    linear-gradient(135deg, #123a55 0%, #245c7e 48%, #174564 100%);
  padding: 96px 24px 160px;
  text-align: center;
}
.hero-bg {
  position: absolute;
  inset: 0;
  width: 100%;
  height: 100%;
  --network-line: rgba(210, 231, 244, 0.42);
  --network-node: #d8e7ef;
  --network-line-width: 0.9;
}
.hero-inner {
  position: relative;
  max-width: 860px;
  margin: 0 auto;
}
.eyebrow {
  display: inline-block;
  font-size: 14px;
  font-weight: 700;
  letter-spacing: 0.08em;
  text-transform: uppercase;
  color: #8fd7ea;
  background: rgba(34, 211, 238, 0.12);
  border: 1px solid rgba(34, 211, 238, 0.3);
  padding: 6px 16px;
  border-radius: 999px;
  margin-bottom: 24px;
}
.hero h1 {
  margin: 0 0 18px;
  font-size: 60px;
  font-weight: 800;
  letter-spacing: -0.01em;
  color: #fff;
}
.tagline {
  color: #b9c2e6;
  font-size: 19px;
  line-height: 1.6;
  margin: 0 0 36px;
}

.search-panel {
  width: min(100%, 880px);
  margin: 0 auto;
}
.search-bar {
  display: flex;
  align-items: center;
  min-height: 62px;
  border: 1px solid rgba(226, 232, 240, 0.92);
  border-radius: 999px;
  background: rgba(255, 255, 255, 0.96);
  box-shadow: 0 14px 34px -24px rgba(4, 7, 20, 0.6);
  text-align: left;
  overflow: hidden;
  transition: box-shadow 0.16s ease, border-color 0.16s ease, background 0.16s ease;
}
.search-bar:focus-within {
  border-color: #8fd7ea;
  background: #fff;
  box-shadow: 0 18px 42px -26px rgba(34, 211, 238, 0.5);
}
.type-select-wrap {
  position: relative;
  display: flex;
  align-items: center;
  flex: 0 0 var(--type-width);
  align-self: stretch;
  min-width: 0;
}
.type-select-wrap::after {
  content: '';
  position: absolute;
  right: 12px;
  top: 50%;
  width: 10px;
  height: 10px;
  border-right: 2px solid #1f2937;
  border-bottom: 2px solid #1f2937;
  pointer-events: none;
  transform: translateY(-68%) rotate(45deg);
}
.type-select {
  width: 100%;
  height: 100%;
  border: 0;
  outline: 0;
  background: transparent;
  color: #1f2937;
  font-size: 18px;
  font-weight: 500;
  padding: 0 30px 0 22px;
  cursor: pointer;
  appearance: none;
  -webkit-appearance: none;
}
.type-select:focus-visible {
  background: #f7f9fc;
}
.search-divider {
  width: 1px;
  height: 38px;
  flex: 0 0 1px;
  background: #d9dde5;
}
.search-divider.right {
  height: 100%;
  align-self: stretch;
}
.search-icon-btn {
  border: none;
  background: transparent;
  padding: 0;
  width: 54px;
  align-self: stretch;
  flex-shrink: 0;
  display: flex;
  align-items: center;
  justify-content: center;
  cursor: pointer;
  color: #111827;
  transition: background 0.16s ease, color 0.16s ease;
}
.search-icon-btn:hover {
  background: #f6f8fb;
  color: #3949ab;
}
.search-icon {
  width: 24px;
  height: 24px;
  flex-shrink: 0;
}
.search-bar input {
  flex: 1;
  border: none;
  outline: none;
  font-size: 18px;
  padding: 0 18px;
  background: transparent;
  color: #1b1f24;
  min-width: 120px;
}
.search-bar input::placeholder {
  color: #a3a9c2;
}
.clear-btn {
  border: none;
  background: #eef0f7;
  color: #6b7280;
  width: 26px;
  height: 26px;
  border-radius: 50%;
  font-size: 16px;
  line-height: 1;
  cursor: pointer;
  margin-right: 14px;
  flex-shrink: 0;
}
.clear-btn:hover {
  background: #dde1f0;
}

.example-chips {
  margin-top: 18px;
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  justify-content: center;
  gap: 18px;
}
.chip-label {
  color: #8790b3;
  font-size: 14px;
  margin-right: 2px;
}
.chip {
  border: none;
  background: transparent;
  color: #dbe1f7;
  font-size: 14px;
  padding: 2px 0;
  cursor: pointer;
  text-decoration: underline;
  text-decoration-color: rgba(219, 225, 247, 0.4);
  text-underline-offset: 4px;
  transition: color 0.15s ease, text-decoration-color 0.15s ease;
}
.chip:hover {
  color: #fff;
  text-decoration-color: rgba(255, 255, 255, 0.85);
}
.analysis-jump-row {
  display: flex;
  justify-content: center;
  margin: 28px 0 -36px;
  position: relative;
  z-index: 3;
}
.about-jump-row {
  margin: 52px 0 -18px;
}
.analysis-jump {
  width: 54px;
  height: 54px;
  border: 1px solid rgba(226, 232, 240, 0.86);
  border-radius: 50%;
  background: rgba(255, 255, 255, 0.96);
  color: #3d4654;
  box-shadow: 0 16px 34px -18px rgba(4, 7, 20, 0.75);
  cursor: pointer;
  transition: transform 0.16s ease, box-shadow 0.16s ease, color 0.16s ease, background 0.16s ease;
}
.analysis-jump:hover {
  color: #0f7c96;
  background: #fff;
  box-shadow: 0 18px 38px -18px rgba(34, 211, 238, 0.55);
  transform: translateY(3px);
}
.analysis-jump:focus-visible {
  outline: 2px solid rgba(143, 215, 234, 0.9);
  outline-offset: 4px;
}
.analysis-jump svg {
  width: 30px;
  height: 30px;
  stroke-linecap: round;
  stroke-linejoin: round;
}

/* ---------- stats strip (floats over hero edge) ---------- */
.stats-strip {
  margin-top: -70px;
  position: relative;
  z-index: 2;
}
.stats-grid {
  display: grid;
  grid-template-columns: repeat(4, 1fr);
  gap: 0;
  background: #fff;
  border-radius: 16px;
  box-shadow: 0 16px 36px -18px rgba(17, 24, 60, 0.35);
  padding: 26px 8px;
}
.stat-card {
  display: flex;
  align-items: center;
  gap: 16px;
  padding: 10px 22px;
  border-radius: 12px;
  transition: background 0.15s ease, transform 0.15s ease;
}
.stat-card:not(:last-child) {
  border-right: 1px solid #eef0f5;
}
.stat-card:hover {
  background: #f7f8fc;
  transform: translateY(-1px);
}
.stat-icon {
  width: 54px;
  height: 54px;
  border-radius: 50%;
  flex-shrink: 0;
  display: flex;
  align-items: center;
  justify-content: center;
  color: #fff;
}
.stat-icon svg {
  width: 27px;
  height: 27px;
}
.stat-icon[data-label='Study'] { background: #3949ab; }
.stat-icon[data-label='Phenotype'] { background: #b3562c; }
.stat-icon[data-label='Module'] { background: #1a8f5e; }
.stat-icon[data-label='Metabolite'] { background: #0f7c96; }
.stat-text {
  text-align: left;
}
.stat-number {
  font-size: 34px;
  font-weight: 800;
  color: #1b2145;
  line-height: 1.15;
  letter-spacing: 0;
}
.stat-label {
  margin-top: 3px;
  font-size: 14px;
  font-weight: 600;
  letter-spacing: 0.03em;
  text-transform: uppercase;
  color: #8790b3;
}

/* ---------- schema section ---------- */
.schema-section {
  margin: 56px auto 72px;
}
.section-title {
  margin: 0 0 8px;
  text-align: center;
  font-size: 34px;
  font-weight: 700;
  letter-spacing: 0;
  color: #1b1f24;
}
.schema-section .hint {
  margin: 0 0 28px;
  max-width: none;
  text-align: justify;
  font-size: 18px;
  line-height: 1.75;
}
.schema-image-frame {
  overflow: hidden;
}
.schema-image-frame img {
  display: block;
  width: 100%;
  height: auto;
}

/* ---------- feature cards ---------- */
.features-section {
  margin: 76px auto 0;
}
.feature-grid {
  display: grid;
  grid-template-columns: repeat(4, minmax(0, 1fr));
  gap: 44px;
  margin-top: 34px;
}
.feature-card {
  display: flex;
  flex-direction: column;
  align-items: flex-start;
  gap: 0;
  background: transparent;
  border: 0;
  border-radius: 0;
  padding: 0;
  text-decoration: none;
  color: #1b1f24;
  transition: transform 0.16s ease;
}
.feature-card:hover {
  transform: translateY(-2px);
}
.tool-visual {
  width: 100%;
  aspect-ratio: 1.72;
  border-radius: 8px;
  background: #eef0f2;
  display: flex;
  align-items: center;
  justify-content: center;
  margin-bottom: 24px;
  transition: background 0.16s ease, box-shadow 0.16s ease;
}
.feature-card:hover .tool-visual {
  background: #e8edf1;
  box-shadow: inset 0 0 0 1px rgba(36, 72, 95, 0.08);
}
.tool-visual svg {
  width: 42%;
  min-width: 92px;
  max-width: 126px;
  height: auto;
}
.feature-card h3 {
  margin: 0 0 10px;
  font-size: 22px;
  font-weight: 600;
  letter-spacing: 0;
  line-height: 1.2;
  color: #303235;
}
.feature-card p {
  margin: 0;
  color: #6f7378;
  font-size: 16px;
  line-height: 1.36;
}

@media (max-width: 720px) {
  .hero h1 { font-size: 34px; }
  .stats-grid {
    grid-template-columns: repeat(2, 1fr);
  }
  .search-bar {
    min-height: 54px;
  }
  .type-select-wrap {
    flex-basis: min(var(--type-width), 108px);
  }
  .type-select-wrap::after {
    right: 10px;
    width: 8px;
    height: 8px;
  }
  .type-select {
    font-size: 15px;
    padding: 0 26px 0 14px;
  }
  .search-divider {
    height: 30px;
  }
  .search-icon-btn {
    width: 48px;
  }
  .search-bar input {
    font-size: 16px;
    min-width: 0;
    padding: 0 12px;
  }
  .analysis-jump {
    width: 48px;
    height: 48px;
  }
  .analysis-jump svg {
    width: 26px;
    height: 26px;
  }
  .feature-grid {
    grid-template-columns: 1fr;
    gap: 28px;
  }
  .section-title {
    font-size: 28px;
  }
  .tool-visual {
    margin-bottom: 16px;
  }
}
</style>
