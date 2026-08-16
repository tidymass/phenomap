<template>
  <div v-if="loading" class="hint">Loading...</div>
  <div v-else-if="error" class="error">{{ error }}</div>

  <div v-else-if="node" class="node-detail">
    <!-- ============ HEADER BAND ============ -->
    <section class="nd-header" :style="{ '--accent': typeColor(node.label) }">
      <div class="nd-container nd-header-flex">
        <div class="nd-header-left">
          <router-link :to="backLink.to" class="back">&larr; {{ backLink.label }}</router-link>

          <div class="nd-header-top">
            <span class="badge-lg" :data-label="node.label">{{ node.label }}</span>
            <span class="tag" v-if="node.label === 'Module' && p.hypothesis_type">{{ p.hypothesis_type }}</span>
            <span class="tag" v-if="node.label === 'Phenotype' && p.Type">{{ p.Type }}</span>
            <span class="tag" v-if="node.label === 'Metabolite' && p.Origin">{{ p.Origin }}</span>
          </div>

          <h1>{{ primaryName }}</h1>
          <div class="nd-id-row">
            <div class="nd-id-badge" v-if="p.Lab_ID">{{ p.Lab_ID }}</div>
            <a
              v-if="node.label === 'Study' && p.Accession"
              class="nd-accession-badge"
              :href="p.Link"
              target="_blank"
              rel="noopener noreferrer"
            >{{ p.Accession }} ↗</a>
            <a
              v-if="node.label === 'Phenotype' && p.OLS_ID"
              class="nd-accession-badge"
              :href="p.OLS_Link"
              target="_blank"
              rel="noopener noreferrer"
            >{{ p.OLS_ID }} ↗</a>
            <a
              v-if="node.label === 'Metabolite' && p.HMDB_ID"
              class="nd-accession-badge"
              :href="p.HMDB_URL"
              target="_blank"
              rel="noopener noreferrer"
            >{{ p.HMDB_ID }} ↗</a>
            <a
              v-if="node.label === 'Metabolite' && p.KEGG_ID"
              class="nd-accession-badge"
              :href="p.KEGG_URL"
              target="_blank"
              rel="noopener noreferrer"
            >{{ p.KEGG_ID }} ↗</a>
          </div>
          <p class="nd-summary" v-if="node.label === 'Module' && p.functional_summary">{{ p.functional_summary }}</p>
          <p class="nd-summary nd-summary-wide" v-else-if="node.label === 'Study' && p.Study_Summary">{{ p.Study_Summary }}</p>
          <p class="nd-summary nd-summary-wide" v-else-if="node.label === 'Phenotype' && p.OLS_Definition">{{ p.OLS_Definition }}</p>
        </div>

        <div class="nd-graph-panel" v-if="moduleGraph">
          <svg
            class="nd-graph-svg"
            :viewBox="`0 0 ${moduleGraph.size} ${moduleGraph.size}`"
            :width="moduleGraph.size"
            :height="moduleGraph.size"
          >
            <line
              v-for="(e, i) in moduleGraph.edges"
              :key="'e-' + i"
              :x1="e.x1"
              :y1="e.y1"
              :x2="e.x2"
              :y2="e.y2"
              class="nd-graph-edge"
            />
            <circle
              v-for="n in moduleGraph.nodes"
              :key="n.id"
              :cx="n.x"
              :cy="n.y"
              :r="n.r"
              :fill="n.color"
              class="nd-graph-node"
            >
              <title>{{ n.name }}</title>
            </circle>
          </svg>
          <div class="nd-graph-side">
            <div class="nd-graph-legend">
              <span><i class="dot" style="background: #1a8f5e"></i>Anchor</span>
              <span><i class="dot" style="background: #b3562c"></i>Supporting</span>
              <span><i class="dot" style="background: #9aa1c2"></i>Contextual</span>
            </div>
          </div>
        </div>
      </div>
    </section>

    <!-- ============ SIDEBAR + CONTENT ============ -->
    <div class="nd-container nd-body">
      <aside class="nd-sidebar" v-if="sections.length">
        <div class="nd-sidebar-label">On This Page</div>
        <nav :style="{ '--accent': typeColor(node.label) }">
          <a
            v-for="sec in sections"
            :key="sec.id"
            :href="`#${sec.id}`"
            class="nd-nav-link"
            :class="{ active: activeSectionId === sec.id }"
          >{{ sec.label }}</a>
        </nav>
      </aside>

      <main class="nd-content">
        <!-- ============ MODULE: curated layout ============ -->
        <template v-if="node.label === 'Module'">
          <div class="card" id="class-coverage" v-if="classCoverage.length">
            <h2><TermInfo label="Class Coverage" :definition="termDefinition('Class Coverage')" heading /></h2>
            <div class="chip-list">
              <span class="tag tag-static" v-for="c in classCoverage" :key="c">{{ c }}</span>
            </div>
          </div>

          <div class="card" id="pathway-coverage" v-if="keggPathways.length || hmdbPathways.length">
            <h2><TermInfo label="Pathway Coverage" :definition="termDefinition('Pathway Coverage')" heading /></h2>

            <div class="coverage-group" v-if="keggPathways.length">
              <h3>KEGG Pathways</h3>
              <div class="pathway-grid">
                <div class="pathway-card" v-for="item in keggPathways" :key="item.id">
                  <span class="pathway-id">{{ item.id }}</span>
                  <span class="pathway-name">{{ item.name }}</span>
                </div>
              </div>
            </div>

            <div class="coverage-group" v-if="hmdbPathways.length">
              <h3>HMDB Pathways</h3>
              <div class="pathway-grid">
                <div class="pathway-card" v-for="item in hmdbPathways" :key="item.id">
                  <span class="pathway-id">{{ item.id }}</span>
                  <span class="pathway-name">{{ item.name }}</span>
                </div>
              </div>
            </div>
          </div>

          <div class="card" id="origin" v-if="originFracs">
            <h2><TermInfo label="Metabolite Origin" :definition="termDefinition('Metabolite Origin')" heading /></h2>
            <div class="origin-bar">
              <div class="origin-bar-endo" :style="{ width: originFracs.endoPct + '%' }"></div>
              <div class="origin-bar-exo" :style="{ width: originFracs.exoPct + '%' }"></div>
              <div class="origin-bar-unknown" :style="{ width: originFracs.unknownPct + '%' }"></div>
            </div>
            <div class="origin-legend">
              <span v-if="originFracs.endo"><i class="dot dot-endo"></i>Endogenous {{ originFracs.endo }}</span>
              <span v-if="originFracs.exo"><i class="dot dot-exo"></i>Exogenous {{ originFracs.exo }}</span>
              <span v-if="originFracs.unknown" class="unknown"><i class="dot dot-unknown"></i>Unknown {{ originFracs.unknown }}</span>
            </div>
          </div>

          <div class="card" id="phenotype-relationship" v-if="relationshipItems.length || studyPhenotypes.length || pmidList.length">
            <h2><TermInfo label="Phenotype Relationship" :definition="termDefinition('Phenotype Relationship')" heading /></h2>
            <dl class="props">
              <template v-if="studyPhenotypes.length">
                <dt>Phenotype Name</dt>
                <dd class="phenotype-badge-list">
                  <router-link
                    v-for="ph in studyPhenotypes"
                    :key="ph.neighbor_id"
                    :to="`/node/Phenotype/${ph.neighbor_id}`"
                    class="phenotype-badge"
                  >{{ ph.neighbor_name || ph.neighbor_id }}</router-link>
                </dd>
              </template>
              <template v-for="item in relationshipItems" :key="item.label">
                <dt>{{ item.label }}</dt>
                <dd>
                  <span v-if="item.label === 'Confidence'" class="confidence-badge" :class="`tier-${String(item.value).toLowerCase()}`">{{ item.value }}</span>
                  <span v-else-if="item.label === 'Direction'" class="direction-badge" :class="`dir-${String(item.value).toLowerCase()}`">{{ item.value }}</span>
                  <template v-else>{{ item.value }}</template>
                </dd>
              </template>
            </dl>

            <div class="relationship-evidence" v-if="pmidList.length">
              <h3><TermInfo label="PubMed Evidence" :definition="termDefinition('PubMed Evidence')" heading /></h3>
              <div class="ref-list">
                <a
                  v-for="pmid in pmidList"
                  :key="pmid"
                  class="ref-card"
                  :href="`https://pubmed.ncbi.nlm.nih.gov/${pmid}/`"
                  target="_blank"
                  rel="noopener noreferrer"
                >
                  <span class="ref-pmid">PMID {{ pmid }}</span>
                  <svg class="ref-arrow" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                    <path d="M7 17 17 7M9 7h8v8" />
                  </svg>
                </a>
              </div>
            </div>
          </div>

          <div class="card" id="metabolite-membership" v-if="membershipGroups.length">
            <h2><TermInfo label="Metabolite Membership" :definition="termDefinition('Metabolite Membership')" heading /></h2>
            <div class="membership-group" v-for="g in membershipGroups" :key="g.key">
              <h3>
                {{ g.label }}
                <span class="count">{{ g.items.length }}</span>
              </h3>
              <div class="chip-list">
                <router-link
                  v-for="(item, i) in g.items"
                  :key="item.id || item.name || i"
                  :to="item.id ? `/node/Metabolite/${item.id}` : ''"
                  class="chip"
                  :class="{ 'chip-disabled': !item.id }"
                >
                  {{ item.name || item.id }}
                </router-link>
              </div>
            </div>
          </div>
        </template>

        <!-- ============ STUDY: curated layout ============ -->
        <template v-else-if="node.label === 'Study'">
          <div class="card" id="study-design" v-if="studyDesignItems.length">
            <h2><TermInfo label="Study Design" :definition="termDefinition('Study Design')" heading /></h2>
            <dl class="props">
              <template v-for="item in studyDesignItems" :key="item.label">
                <dt>{{ item.label }}</dt>
                <dd>
                  <span
                    v-if="item.label === 'MS2 Supported'"
                    class="direction-badge"
                    :class="item.value === 'Yes' ? 'dir-up' : item.value === 'No' ? 'dir-down' : 'dir-neutral'"
                  >{{ item.value }}</span>
                  <template v-else>{{ item.value }}</template>
                </dd>
              </template>
            </dl>
          </div>

          <div class="card" id="phenotype" v-if="studyPhenotypeLink">
            <h2><TermInfo label="Phenotype" :definition="termDefinition('Phenotype')" heading /></h2>
            <dl class="props">
              <dt>Phenotype Name</dt>
              <dd class="phenotype-badge-list">
                <router-link
                  v-if="studyPhenotypeLink.id"
                  :to="`/node/Phenotype/${studyPhenotypeLink.id}`"
                  class="phenotype-badge"
                >{{ studyPhenotypeLink.name || studyPhenotypeLink.id }}</router-link>
                <span v-else>{{ studyPhenotypeLink.name }}</span>
              </dd>
            </dl>
          </div>

          <div class="card" id="source" v-if="studySourceItems.length || p.Link || doiUrl">
            <h2><TermInfo label="Source & Publication" :definition="termDefinition('Source & Publication')" heading /></h2>
            <dl class="props" v-if="studySourceItems.length">
              <template v-for="item in studySourceItems" :key="item.label">
                <dt>{{ item.label }}</dt>
                <dd>{{ item.value }}</dd>
              </template>
            </dl>
            <div class="ref-list" v-if="p.Link || doiUrl">
              <a
                v-if="p.Link"
                class="ref-card"
                :href="p.Link"
                target="_blank"
                rel="noopener noreferrer"
              >
                <span class="ref-pmid">View on {{ p.Repository || 'Source Repository' }}</span>
                <svg class="ref-arrow" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                  <path d="M7 17 17 7M9 7h8v8" />
                </svg>
              </a>
              <a
                v-if="doiUrl"
                class="ref-card"
                :href="doiUrl"
                target="_blank"
                rel="noopener noreferrer"
              >
                <span class="ref-pmid">DOI {{ p.Publication_DOI }}</span>
                <svg class="ref-arrow" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                  <path d="M7 17 17 7M9 7h8v8" />
                </svg>
              </a>
            </div>
          </div>
        </template>

        <!-- ============ PHENOTYPE: curated layout ============ -->
        <template v-else-if="node.label === 'Phenotype'">
          <div class="card" id="ontology" v-if="phenotypeOntologyItems.length || p.OLS_Link">
            <h2><TermInfo label="Ontology Reference" :definition="termDefinition('Ontology Reference')" heading /></h2>
            <dl class="props" v-if="phenotypeOntologyItems.length">
              <template v-for="item in phenotypeOntologyItems" :key="item.label">
                <dt>{{ item.label }}</dt>
                <dd>{{ item.value }}</dd>
              </template>
            </dl>
            <div class="ref-list" v-if="p.OLS_Link">
              <a class="ref-card" :href="p.OLS_Link" target="_blank" rel="noopener noreferrer">
                <span class="ref-pmid">View on Ontology Lookup Service (OLS)</span>
                <svg class="ref-arrow" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                  <path d="M7 17 17 7M9 7h8v8" />
                </svg>
              </a>
            </div>
          </div>

          <div class="card" id="related-modules" v-if="phenotypeModules.length">
            <h2>
              <TermInfo label="Related Modules" :definition="termDefinition('Related Modules')" heading />
              <span class="count">{{ phenotypeModules.length }}</span>
            </h2>
            <div class="chip-list">
              <router-link
                v-for="m in phenotypeModules"
                :key="m.neighbor_id"
                :to="`/node/Module/${m.neighbor_id}`"
                class="chip"
              >{{ m.neighbor_name || m.neighbor_id }}</router-link>
            </div>
          </div>
        </template>

        <!-- ============ METABOLITE: curated layout ============ -->
        <template v-else-if="node.label === 'Metabolite'">
          <div class="card" id="classification" v-if="metaboliteClassificationItems.length">
            <h2><TermInfo label="Chemical Classification" :definition="termDefinition('Chemical Classification')" heading /></h2>
            <dl class="props">
              <template v-for="item in metaboliteClassificationItems" :key="item.label">
                <dt>{{ item.label }}</dt>
                <dd>{{ item.value }}</dd>
              </template>
            </dl>
          </div>

          <div class="card" id="identifiers" v-if="metaboliteIdentifierItems.length || p.HMDB_URL || p.KEGG_URL">
            <h2><TermInfo label="Chemical Identifiers" :definition="termDefinition('Chemical Identifiers')" heading /></h2>
            <dl class="props" v-if="metaboliteIdentifierItems.length">
              <template v-for="item in metaboliteIdentifierItems" :key="item.label">
                <dt>{{ item.label }}</dt>
                <dd>{{ item.value }}</dd>
              </template>
            </dl>
            <div class="ref-list" v-if="p.HMDB_URL || p.KEGG_URL">
              <a v-if="p.HMDB_URL" class="ref-card" :href="p.HMDB_URL" target="_blank" rel="noopener noreferrer">
                <span class="ref-pmid">View on HMDB</span>
                <svg class="ref-arrow" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                  <path d="M7 17 17 7M9 7h8v8" />
                </svg>
              </a>
              <a v-if="p.KEGG_URL" class="ref-card" :href="p.KEGG_URL" target="_blank" rel="noopener noreferrer">
                <span class="ref-pmid">View on KEGG</span>
                <svg class="ref-arrow" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                  <path d="M7 17 17 7M9 7h8v8" />
                </svg>
              </a>
            </div>
          </div>
        </template>

        <!-- ============ EVERY OTHER LABEL: generic property dump (for now) ============ -->
        <div class="card" id="overview" v-else>
          <dl class="props">
            <template v-for="(value, key) in node.properties" :key="key">
              <dt>{{ key }}</dt>
              <dd>{{ formatValue(value) }}</dd>
            </template>
          </dl>
        </div>

        <div class="card" id="relationships" v-for="group in neighborGroups" :key="group.relType">
          <h2>
            <TermInfo
              :label="relTypeLabel(group.relType, node.label)"
              :definition="termDefinition(relTypeLabel(group.relType, node.label))"
              heading
            />
            <span class="count">
              {{ group.items.length }}{{ group.total > group.items.length ? ` of ${group.total}` : '' }}
            </span>
          </h2>
          <div class="neighbor-list">
            <router-link
              v-for="n in group.items"
              :key="n.neighbor_label + n.neighbor_id"
              :to="`/node/${n.neighbor_label}/${n.neighbor_id}`"
              class="neighbor-row"
              :style="{ '--accent': typeColor(n.neighbor_label) }"
            >
              <span class="badge small" :data-label="n.neighbor_label">{{ n.neighbor_label }}</span>
              <span class="neighbor-row-name">{{ n.neighbor_name || n.neighbor_id }}</span>
              <span class="neighbor-row-tier" v-if="tierLabel(n)" :class="`tier-${tierLabel(n)}`">{{ tierLabel(n) }}</span>
              <span class="neighbor-row-bar" v-if="similarityPct(n) !== null">
                <span class="neighbor-row-bar-fill" :style="{ width: similarityPct(n) + '%' }"></span>
              </span>
              <span class="neighbor-row-pct" v-if="similarityPct(n) !== null">{{ similarityPct(n) }}%</span>
              <svg class="neighbor-row-arrow" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                <path d="m9 6 6 6-6 6" />
              </svg>
            </router-link>
          </div>
        </div>
      </main>
    </div>
  </div>
</template>

<script setup>
import { computed, ref, watch, onBeforeUnmount } from 'vue'
import { useRoute } from 'vue-router'
import { getNode } from '../api.js'
import TermInfo from '../components/TermInfo.vue'
import { forceDirectedLayout, fitPositionsToCanvas } from '../lib/forceLayout.js'

const route = useRoute()

const props = defineProps({
  label: { type: String, required: true },
  id: { type: String, required: true },
})

const node = ref(null)
const loading = ref(true)
const error = ref('')

const backLink = computed(() => {
  const returnTo = typeof route.query.returnTo === 'string' ? route.query.returnTo : ''
  const returnLabel = typeof route.query.returnLabel === 'string' ? route.query.returnLabel : 'Entity Search'
  if (returnTo.startsWith('/') && !returnTo.startsWith('//')) {
    return { to: returnTo, label: `Back to ${returnLabel}` }
  }
  return { to: '/search', label: 'Back to Entity Search' }
})

const primaryNameFields = {
  Study: 'Title',
  Phenotype: 'Phenotype',
  Module: 'title',
  Metabolite: 'Metabolite_Name',
}

const primaryName = computed(() => {
  if (!node.value) return ''
  const field = primaryNameFields[node.value.label]
  const value = field && node.value.properties[field]
  if (value) return value
  if (node.value.label === 'Study') return node.value.properties.Accession || props.id
  return node.value.properties.module_id || props.id
})

// Same accent colors used on the Entity Search page, so a node's detail
// page reads as a continuation of the same type, not a different site.
const typeColors = { Study: '#3949ab', Phenotype: '#b3562c', Module: '#1a8f5e', Metabolite: '#0f7c96' }
function typeColor(l) {
  return typeColors[l] || '#6b7280'
}

const termDefinitions = {
  Accession: 'The external study accession assigned by the source repository, such as MetaboLights or Metabolomics Workbench.',
  Anchor: 'Core metabolites that define the module signal and give the module its main biochemical identity.',
  Biospecimen: 'The sample material analyzed in the study, such as plasma, serum, tissue, or cell culture.',
  'Chemical Classification': 'Database-derived chemical taxonomy for this metabolite, shown from HMDB and KEGG when available.',
  'Chemical Identifiers': 'External database and structure identifiers that can be used to look up the metabolite outside PhenoMAP.',
  'Class Coverage': 'Chemical classes represented by metabolites in this module. It is computed by collecting class annotations from member metabolites and summarizing which classes are covered.',
  Chromatography: 'The separation method used before mass spectrometry, when reported by the source study.',
  Confidence: 'A qualitative confidence level assigned during module interpretation based on the amount and consistency of supporting evidence.',
  'Connected Metabolites': 'Metabolites connected to this metabolite in the metabolic reaction network.',
  Direction: 'The overall dysregulation direction for the module when the source evidence supports an up or down trend.',
  DOI: 'The publication Digital Object Identifier linked to the source study.',
  'HMDB Chemical Class': 'The chemical class annotation imported from the Human Metabolome Database.',
  'HMDB ID': 'The Human Metabolome Database identifier for this metabolite.',
  'HMDB Pathways': 'HMDB pathway annotations represented by member metabolites in this module.',
  'INCHI ID': 'A structure-based chemical identifier that encodes the metabolite structure.',
  Instrumentation: 'The analytical platform settings reported by the study, including chromatography and mass spectrometry information.',
  'KEGG Chemical Class': 'The chemical class annotation imported from KEGG when available.',
  'KEGG ID': 'The KEGG Compound identifier for this metabolite.',
  'KEGG Pathways': 'KEGG pathway annotations represented by member metabolites in this module.',
  'Mass Spectrometry': 'The mass spectrometry platform or acquisition mode used to generate the metabolomics data.',
  'Metabolite Membership': 'The metabolites assigned to this module, grouped by their role in the module signal.',
  'Metabolite Origin': 'The distribution of member metabolites by origin annotation. Percentages are calculated from endogenous, exogenous, and unknown origin labels across module members.',
  'Module Membership': 'Modules that contain this metabolite. The badge shows the metabolite role when that relationship is available.',
  'Modules In This Study': 'Modules reported by this study and linked back to the study record.',
  'MS2 Supported': 'Whether tandem MS/MS evidence is reported for metabolite annotation support in the study metadata.',
  'Ontology ID': 'The ontology identifier for the normalized phenotype term.',
  'Ontology Reference': 'The normalized phenotype ontology record used by PhenoMAP, usually linked through OLS.',
  Origin: 'The metabolite origin annotation, such as endogenous, exogenous, or unknown.',
  'Pathway Coverage': 'Pathways represented by this module. The values are calculated by mapping member metabolites to KEGG or HMDB pathways and summarizing the most covered pathways.',
  Phenotype: 'The phenotype, disease, condition, or biological state investigated by a study or connected to an entity.',
  'Phenotype Name': 'The normalized phenotype term linked to the study or module.',
  'Phenotype Relationship': 'A curated summary of how the module is related to the phenotype investigated by the linked study.',
  'PubMed Evidence': 'PubMed records retrieved as supporting literature evidence by searching the module name or anchor metabolites together with the connected phenotype.',
  Rationale: 'A short explanation of why the module was linked to the phenotype or assigned its interpretation.',
  'Related Modules': 'Modules connected to this phenotype through studies that investigated the phenotype.',
  'Reported In': 'The study record in which this module was reported.',
  Repository: 'The public source repository where the study metadata or metabolomics dataset was collected.',
  'Sample Size': 'The number of samples, participants, or experimental units reported by the source study when available.',
  'Similar Modules': 'Modules connected by a similarity score based on overlap or relatedness between their metabolite sets.',
  Source: 'The originating data source or repository for this record.',
  'Source & Publication': 'Links and identifiers for the source dataset and associated publication.',
  Study: 'A metabolomics study record connected to phenotypes and reported modules.',
  'Studies Investigating This Phenotype': 'Study records whose metadata links them to this phenotype.',
  'Study Design': 'The study-level design metadata, including design type, sample size, and biospecimen when available.',
  Supporting: 'Additional metabolites that support the module interpretation but are not the main anchor metabolites.',
  Contextual: 'Related metabolites that provide biochemical context around the module signal.',
}
function termDefinition(labelName) {
  return termDefinitions[labelName] || ''
}

// Shorthand for the raw properties map, used throughout the Module layout.
const p = computed(() => node.value?.properties || {})

function firstProperty(...keys) {
  for (const key of keys) {
    if (Object.prototype.hasOwnProperty.call(p.value, key)) return p.value[key]
  }
  const normalized = Object.fromEntries(
    Object.entries(p.value).map(([key, value]) => [key.toLowerCase().replace(/[^a-z0-9]/g, ''), value]),
  )
  for (const key of keys) {
    const value = normalized[key.toLowerCase().replace(/[^a-z0-9]/g, '')]
    if (value !== undefined) return value
  }
  return null
}

function formatBooleanLabel(value) {
  if (value === null || value === undefined || value === '') return 'Not reported'
  if (typeof value === 'boolean') return value ? 'Yes' : 'No'
  if (typeof value === 'number') return value === 1 ? 'Yes' : value === 0 ? 'No' : 'Not reported'
  const normalized = String(value).trim().toLowerCase()
  if (['true', 't', 'yes', 'y', '1', 'supported', 'ms2 supported'].includes(normalized)) return 'Yes'
  if (['false', 'f', 'no', 'n', '0', 'not supported', 'unsupported'].includes(normalized)) return 'No'
  return formatValue(value)
}

function splitList(v) {
  if (v === null || v === undefined) return []
  return String(v)
    .split(';')
    .map((s) => s.trim())
    .filter(Boolean)
}

// Several module fields come as two semicolon-separated lists generated
// together in lockstep (same index = same item) -- anchor/supporting/
// contextual_metabolites + their *_ids, and top_kegg/hmdb_pathways + their
// *_pathway_ids. This zips any such pair back into {name, id} pairs.
function zipPairs(namesStr, idsStr) {
  const names = splitList(namesStr)
  const ids = splitList(idsStr)
  const len = Math.max(names.length, ids.length)
  const items = []
  for (let i = 0; i < len; i++) {
    items.push({ name: names[i] || null, id: ids[i] || null })
  }
  return items
}

const membershipGroups = computed(() => {
  if (!node.value || node.value.label !== 'Module') return []
  return [
    { key: 'anchor', label: 'Anchor', items: zipPairs(p.value.anchor_metabolites, p.value.anchor_metabolite_ids) },
    { key: 'supporting', label: 'Supporting', items: zipPairs(p.value.supporting_metabolites, p.value.supporting_metabolite_ids) },
    { key: 'contextual', label: 'Contextual', items: zipPairs(p.value.contextual_metabolites, p.value.contextual_metabolite_ids) },
  ].filter((g) => g.items.length)
})

// Static network preview shown in the header's right-hand side: the
// module's own anchor/supporting/contextual metabolites laid out by their
// *real* connectivity (the metabolic reaction network edges among them),
// so connected metabolites cluster together and isolated ones drift out --
// an actual module shape, not every node placed on a ring regardless of
// whether it connects to anything. Kept small and compact (thumbnail-sized,
// not a full canvas) -- it's a preview, not the main content.
const GRAPH_COLORS = { anchor: '#1a8f5e', supporting: '#b3562c', contextual: '#9aa1c2' }
const GRAPH_NODE_R = { anchor: 4.5, supporting: 3.8, contextual: 2.2 }
const GRAPH_MARGIN = 16

const moduleGraph = computed(() => {
  if (!node.value || node.value.label !== 'Module') return null
  const order = ['anchor', 'supporting', 'contextual']
  const groups = order
    .map((key) => membershipGroups.value.find((g) => g.key === key))
    .filter((g) => g && g.items.length)
  if (!groups.length) return null

  const flat = groups.flatMap((g) => g.items.map((item, i) => ({ ...item, group: g.key, fallbackId: `${g.key}-${i}` })))
  const nodeIds = flat.map((item) => item.id || item.fallbackId)
  const infoById = new Map(flat.map((item, i) => [nodeIds[i], item]))

  const idSet = new Set(nodeIds)
  const edgeList = (node.value.metabolite_edges || [])
    .filter((e) => idSet.has(e.from) && idSet.has(e.to))
    .map((e) => [e.from, e.to])

  const size = Math.ceil(Math.max(220, Math.min(340, 170 + Math.sqrt(nodeIds.length) * 18)))
  const layoutSpan = size - GRAPH_MARGIN * 2
  const rawPositions = forceDirectedLayout(nodeIds, edgeList, layoutSpan)
  const positions = fitPositionsToCanvas(rawPositions, size, GRAPH_MARGIN)

  const nodeById = new Map()
  const nodes = nodeIds.map((id) => {
    const item = infoById.get(id)
    const pt = positions.get(id)
    const n = {
      id,
      name: item.name || item.id || 'Unknown metabolite',
      x: pt.x,
      y: pt.y,
      r: GRAPH_NODE_R[item.group],
      color: GRAPH_COLORS[item.group],
    }
    nodeById.set(id, n)
    return n
  })

  const edges = edgeList
    .map(([a, b]) => {
      const na = nodeById.get(a)
      const nb = nodeById.get(b)
      if (!na || !nb) return null
      return { x1: na.x, y1: na.y, x2: nb.x, y2: nb.y }
    })
    .filter(Boolean)

  return { nodes, edges, size }
})

const relationshipItems = computed(() => {
  if (!node.value || node.value.label !== 'Module') return []
  return [
    { label: 'Phenotype Relationship', value: p.value.phenotype_relationship },
    { label: 'Confidence', value: p.value.confidence_label },
    { label: 'Direction', value: p.value.global_direction },
    { label: 'Rationale', value: p.value.rationale },
  ].filter((item) => item.value !== null && item.value !== undefined && item.value !== '')
})

// A module has no direct graph edge to a Phenotype -- the backend resolves
// it via the module's own study (Module -> Study -> Phenotype) so it can be
// linked here instead of just named in the free-text fields above.
const studyPhenotypes = computed(() => node.value?.study_phenotypes || [])

function toPercent(v) {
  const n = Number(v)
  if (Number.isNaN(n)) return null
  return Math.round(n * 1000) / 10 // one decimal place
}

const originFracs = computed(() => {
  if (!node.value || node.value.label !== 'Module') return null
  const endoPct = toPercent(p.value.origin_endogenous_frac)
  const exoPct = toPercent(p.value.origin_exogenous_frac)
  if (endoPct === null && exoPct === null) return null
  const endoVal = endoPct === null ? 0 : endoPct
  const exoVal = exoPct === null ? 0 : exoPct
  // The two fractions don't always add up to 100% -- whatever's left over
  // is metabolite origin we couldn't classify, shown as a labeled "Unknown"
  // segment rather than silently leaving unlabeled grey space in the bar.
  const unknownVal = Math.max(0, Math.round((100 - endoVal - exoVal) * 10) / 10)
  return {
    endo: endoPct === null ? null : `${endoPct}%`,
    exo: exoPct === null ? null : `${exoPct}%`,
    unknown: unknownVal > 0.05 ? `${unknownVal}%` : null,
    endoPct: endoVal,
    exoPct: exoVal,
    unknownPct: unknownVal,
  }
})

const classCoverage = computed(() => {
  if (!node.value || node.value.label !== 'Module') return []
  return splitList(p.value.class_names)
})

// top_kegg/hmdb_pathways hold the pathway names (with a "(42/83, 50.6%)"
// stat suffix); *_pathway_ids hold the matching IDs at the same index --
// zipped into single "id: name" cards instead of two separate rows.
const keggPathways = computed(() => {
  if (!node.value || node.value.label !== 'Module') return []
  return zipPairs(p.value.top_kegg_pathways, p.value.kegg_pathway_ids).filter((item) => item.id || item.name)
})
const hmdbPathways = computed(() => {
  if (!node.value || node.value.label !== 'Module') return []
  return zipPairs(p.value.top_hmdb_pathways, p.value.hmdb_pathway_ids).filter((item) => item.id || item.name)
})

const pmidList = computed(() => {
  if (!node.value || node.value.label !== 'Module') return []
  return splitList(p.value.pubmed_pmids)
})

// ---------- Study-only fields ----------
// Grouped in the order a reader actually needs them: what kind of study
// this is and how big (design), how the data was generated
// (instrumentation), what phenotype it was studying (a linked entity, not
// free text), then where it came from (source/publication) -- mirroring the
// Module page's anchor -> supporting -> contextual -> evidence ordering.
const studyDesignItems = computed(() => {
  if (!node.value || node.value.label !== 'Study') return []
  return [
    { label: 'Study Design', value: p.value.Study_Design },
    { label: 'Sample Size', value: p.value.Sample_Size },
    { label: 'Biospecimen', value: p.value.Biospecimen },
    { label: 'MS2 Supported', value: studyMs2Supported.value },
    { label: 'Chromatography', value: p.value.Chromatography },
    { label: 'Mass Spectrometry', value: p.value.Mass_Spectrometry },
  ].filter((item) => item.value !== null && item.value !== undefined && item.value !== '')
})

const studyMs2Supported = computed(() => {
  if (!node.value || node.value.label !== 'Study') return ''
  return formatBooleanLabel(firstProperty('MS2_Supported', 'ms2_supported', 'MS2 Supported', 'MS2Supported'))
})

// Study carries its investigated phenotype as free-text (Phenotype) plus a
// resolvable Phenotype_ID -- shown as a clickable badge (same style as the
// Module page's Phenotype Name) instead of plain unlinked text.
const studyPhenotypeLink = computed(() => {
  if (!node.value || node.value.label !== 'Study') return null
  const id = p.value.Phenotype_ID
  const name = p.value.Phenotype
  if (!id && !name) return null
  return { id, name }
})

const studySourceItems = computed(() => {
  if (!node.value || node.value.label !== 'Study') return []
  return [
    { label: 'Repository', value: p.value.Repository },
    { label: 'Accession', value: p.value.Accession },
  ].filter((item) => item.value !== null && item.value !== undefined && item.value !== '')
})

const doiUrl = computed(() => {
  const doi = p.value.Publication_DOI
  if (!doi) return null
  return String(doi).startsWith('http') ? doi : `https://doi.org/${doi}`
})

// ---------- Phenotype-only fields ----------
// OLS_Definition is used as the header summary (see template), so it's
// intentionally left out of this card to avoid repeating it.
const phenotypeOntologyItems = computed(() => {
  if (!node.value || node.value.label !== 'Phenotype') return []
  return [{ label: 'Ontology ID', value: p.value.OLS_ID }].filter(
    (item) => item.value !== null && item.value !== undefined && item.value !== ''
  )
})

// A phenotype has no direct graph edge to a Module -- resolved via
// Phenotype <-INVESTIGATED- Study <-REPORTED_IN- Module on the backend, the
// mirror image of the Module page's studyPhenotypes.
const phenotypeModules = computed(() => node.value?.phenotype_modules || [])

// ---------- Metabolite-only fields ----------
const metaboliteClassificationItems = computed(() => {
  if (!node.value || node.value.label !== 'Metabolite') return []
  return [
    { label: 'HMDB Chemical Class', value: p.value.HMDB_Chemical_Class },
    { label: 'KEGG Chemical Class', value: p.value.KEGG_Chemical_Class },
    { label: 'Origin', value: p.value.Origin },
  ].filter((item) => item.value !== null && item.value !== undefined && item.value !== '')
})

const metaboliteIdentifierItems = computed(() => {
  if (!node.value || node.value.label !== 'Metabolite') return []
  return [
    { label: 'INCHI ID', value: p.value.INCHI_ID },
    { label: 'HMDB ID', value: p.value.HMDB_ID },
    { label: 'KEGG ID', value: p.value.KEGG_ID },
  ].filter((item) => item.value !== null && item.value !== undefined && item.value !== '')
})

// Human-readable headings for relationship types (falls back to a
// title-cased version of the raw Neo4j type for anything not listed).
// viewingLabel lets the same relationship type read naturally from either
// side of the edge -- e.g. REPORTED_IN is "Reported In" from a Module's
// perspective but "Modules In This Study" from a Study's. MEMBER_OF only
// ever surfaces here (Module pages filter it out below), so it's safe to
// give it its Metabolite-side label directly rather than a per-view branch.
const relTypeLabels = {
  SIMILAR_TO: 'Similar Modules',
  REPORTED_IN: 'Reported In',
  MEMBER_OF: 'Module Membership',
}
function relTypeLabel(relType, viewingLabel) {
  if (viewingLabel === 'Study' && relType === 'REPORTED_IN') return 'Modules In This Study'
  if (viewingLabel === 'Phenotype' && relType === 'INVESTIGATED') return 'Studies Investigating This Phenotype'
  // CONNECTED_WITH is the correct type for metabolite-metabolite (MRN) edges,
  // but RUNBOOK.md's import command had its relationship type labels
  // mismatched against their CSV files for a while, so a live database may
  // still have these landed under SIMILAR_TO instead -- label defensively by
  // viewing context rather than trusting the raw type name here.
  if (viewingLabel === 'Metabolite' && (relType === 'CONNECTED_WITH' || relType === 'SIMILAR_TO')) return 'Connected Metabolites'
  if (relTypeLabels[relType]) return relTypeLabels[relType]
  return relType
    .toLowerCase()
    .split('_')
    .map((w) => w[0].toUpperCase() + w.slice(1))
    .join(' ')
}

// SIMILAR_TO edges (module <-> module) carry a Similarity_Score (0-1) and
// Similarity_Tier (high/medium/low) -- surfaced on each neighbor card
// instead of being silently dropped.
function similarityPct(n) {
  const v = n.rel_props?.Similarity_Score
  if (v === undefined || v === null) return null
  const num = Number(v)
  return Number.isNaN(num) ? null : Math.round(num * 100)
}
// MEMBER_OF edges (metabolite <-> module) carry a Type property
// (core/supporting/contextual) instead of Similarity_Tier -- reusing the
// same tier-badge slot on the neighbor row so a metabolite's role in each
// module is visible without a separate column.
function tierLabel(n) {
  const v = n.rel_props?.Similarity_Tier || n.rel_props?.Type
  return v ? String(v).toLowerCase() : null
}

// MEMBER_OF (metabolite <-> module) is omitted for Module pages -- it's the
// exact same relationship already shown, broken out by anchor/supporting/
// contextual, in the Metabolite Membership card above. INVESTIGATED is
// omitted for Study pages for the same reason -- it's the exact same
// phenotype already shown as a linked badge in the Phenotype card above.
const neighborGroups = computed(() => {
  if (!node.value) return []
  const counts = Object.fromEntries((node.value.relationship_counts || []).map((c) => [c.rel_type, c.count]))
  const groups = {}
  for (const n of node.value.neighbors || []) {
    if (node.value.label === 'Module' && n.rel_type === 'MEMBER_OF') continue
    if (node.value.label === 'Study' && n.rel_type === 'INVESTIGATED') continue
    if (!groups[n.rel_type]) groups[n.rel_type] = []
    groups[n.rel_type].push(n)
  }
  return Object.entries(groups).map(([relType, items]) => ({
    relType,
    items,
    total: counts[relType] || items.length,
  }))
})

// Sidebar section nav -- only lists sections that actually have content.
const sections = computed(() => {
  if (!node.value) return []
  if (node.value.label === 'Module') {
    return [
      classCoverage.value.length && { id: 'class-coverage', label: 'Class Coverage' },
      (keggPathways.value.length || hmdbPathways.value.length) && { id: 'pathway-coverage', label: 'Pathway Coverage' },
      originFracs.value && { id: 'origin', label: 'Metabolite Origin' },
      (relationshipItems.value.length || studyPhenotypes.value.length || pmidList.value.length) && { id: 'phenotype-relationship', label: 'Phenotype Relationship' },
      membershipGroups.value.length && { id: 'metabolite-membership', label: 'Metabolite Membership' },
      neighborGroups.value.length && { id: 'relationships', label: 'Related Records' },
    ].filter(Boolean)
  }
  if (node.value.label === 'Study') {
    return [
      studyDesignItems.value.length && { id: 'study-design', label: 'Study Design' },
      studyPhenotypeLink.value && { id: 'phenotype', label: 'Phenotype' },
      (studySourceItems.value.length || p.value.Link || doiUrl.value) && { id: 'source', label: 'Source & Publication' },
      neighborGroups.value.length && { id: 'relationships', label: 'Related Records' },
    ].filter(Boolean)
  }
  if (node.value.label === 'Phenotype') {
    return [
      (phenotypeOntologyItems.value.length || p.value.OLS_Link) && { id: 'ontology', label: 'Ontology Reference' },
      phenotypeModules.value.length && { id: 'related-modules', label: 'Related Modules' },
      neighborGroups.value.length && { id: 'relationships', label: 'Related Records' },
    ].filter(Boolean)
  }
  if (node.value.label === 'Metabolite') {
    return [
      metaboliteClassificationItems.value.length && { id: 'classification', label: 'Chemical Classification' },
      (metaboliteIdentifierItems.value.length || p.value.HMDB_URL || p.value.KEGG_URL) && { id: 'identifiers', label: 'Chemical Identifiers' },
      neighborGroups.value.length && { id: 'relationships', label: 'Related Records' },
    ].filter(Boolean)
  }
  return [
    { id: 'overview', label: 'Overview' },
    neighborGroups.value.length && { id: 'relationships', label: 'Related Records' },
  ].filter(Boolean)
})

function formatValue(value) {
  if (value === null || value === undefined || value === '') return '—'
  if (typeof value === 'object') return JSON.stringify(value)
  return String(value)
}

async function load() {
  loading.value = true
  error.value = ''
  try {
    node.value = await getNode(props.label, props.id)
  } catch (e) {
    error.value = e.message
  } finally {
    loading.value = false
  }
}

watch(() => [props.label, props.id], load, { immediate: true })

// ---------- Sidebar scroll-spy ----------
// Highlights whichever section is currently at the top of the viewport, so
// the "On This Page" nav reflects scroll position instead of being a static
// list with no sense of where you are on a long page.
const activeSectionId = ref('')
let sectionObserver = null

function setupSectionObserver() {
  if (sectionObserver) sectionObserver.disconnect()
  const ids = sections.value.map((s) => s.id)
  const els = ids.map((id) => document.getElementById(id)).filter(Boolean)
  if (!els.length) {
    activeSectionId.value = ''
    return
  }
  sectionObserver = new IntersectionObserver(
    (entries) => {
      const visible = entries.filter((e) => e.isIntersecting)
      if (visible.length) {
        visible.sort((a, b) => a.boundingClientRect.top - b.boundingClientRect.top)
        activeSectionId.value = visible[0].target.id
      }
    },
    // Treat a section as "active" once it's within the top ~30% of the
    // viewport (below the sticky header) rather than requiring it to be
    // fully visible.
    { rootMargin: '-96px 0px -70% 0px', threshold: 0 }
  )
  els.forEach((el) => sectionObserver.observe(el))
  if (!ids.includes(activeSectionId.value)) {
    activeSectionId.value = ids[0]
  }
}

watch(sections, () => setupSectionObserver(), { flush: 'post' })

onBeforeUnmount(() => {
  if (sectionObserver) sectionObserver.disconnect()
})
</script>

<style scoped>
.node-detail {
  min-height: calc(100vh - 69px);
  background: #f7f8fc;
}
.nd-container {
  max-width: none;
  margin: 0 auto;
  padding: 0 40px;
  width: min(90vw, 1680px);
  box-sizing: border-box;
}
.hint,
.error {
  padding: 24px;
  color: #6b7280;
}
.error {
  color: #c0392b;
}

/* ---------- header band ---------- */
.nd-header {
  background:
    radial-gradient(ellipse at 20% 0%, color-mix(in srgb, var(--accent) 12%, transparent) 0%, transparent 55%),
    linear-gradient(180deg, #eef1ff 0%, #f4f6fd 55%, #f7f8fc 100%);
  padding: 28px 0 32px;
  border-bottom: 1px solid #e6e9f5;
}
.back {
  display: inline-block;
  margin-bottom: 18px;
  color: #3949ab;
  text-decoration: none;
  font-size: 13.5px;
  font-weight: 600;
}
.back:hover {
  text-decoration: underline;
}
.nd-header-top {
  display: flex;
  align-items: center;
  gap: 8px;
  margin-bottom: 10px;
}
.badge-lg {
  font-size: 12px;
  font-weight: 700;
  letter-spacing: 0.03em;
  text-transform: uppercase;
  padding: 4px 12px;
  border-radius: 999px;
  background: var(--accent);
  color: #fff;
}
.nd-header h1 {
  margin: 0 0 12px;
  font-size: 30px;
  font-weight: 800;
  letter-spacing: -0.01em;
  color: #1b2145;
}
.nd-id-row {
  display: flex;
  align-items: center;
  gap: 10px;
  margin-bottom: 16px;
}
.nd-id-badge {
  display: inline-block;
  font-family: 'SFMono-Regular', Menlo, Consolas, monospace;
  font-size: 15px;
  font-weight: 700;
  letter-spacing: 0.01em;
  color: var(--accent);
  background: color-mix(in srgb, var(--accent) 8%, #fff);
  border: 1.5px solid color-mix(in srgb, var(--accent) 35%, transparent);
  padding: 5px 14px;
  border-radius: 8px;
}
.nd-accession-badge {
  display: inline-block;
  font-family: 'SFMono-Regular', Menlo, Consolas, monospace;
  font-size: 13px;
  font-weight: 600;
  letter-spacing: 0.01em;
  color: #6b7280;
  background: #fff;
  border: 1.5px solid #e2e5f0;
  padding: 5px 12px;
  border-radius: 8px;
  text-decoration: none;
}
.nd-accession-badge:hover {
  border-color: color-mix(in srgb, var(--accent) 45%, transparent);
  color: var(--accent);
}
.nd-summary {
  max-width: 760px;
  color: #3a3f4a;
  font-size: 15px;
  line-height: 1.6;
  margin: 0;
}
/* Used when there's no graph panel competing for header space (e.g. Study)
   -- let the summary fill the full header width instead of staying capped
   to the width chosen to leave room for the Module graph. */
.nd-summary-wide {
  max-width: 100%;
}

.nd-header-flex {
  display: flex;
  align-items: flex-start;
  justify-content: space-between;
  gap: 32px;
}
.nd-header-left {
  flex: 1 1 auto;
  min-width: 0;
}
.nd-graph-panel {
  flex-shrink: 0;
  display: flex;
  align-items: center;
  gap: 16px;
  padding-top: 4px;
}
.nd-graph-svg {
  max-width: 100%;
  height: auto;
  flex-shrink: 0;
}
.nd-graph-edge {
  stroke: #9aa1c2;
  stroke-width: 1;
  stroke-opacity: 0.35;
}
.nd-graph-node {
  stroke: #fff;
  stroke-width: 1.2;
  transition: r 0.1s ease;
}
.nd-graph-node:hover {
  stroke: #1b2145;
}
.nd-graph-side {
  display: flex;
  flex-direction: column;
  gap: 10px;
  max-width: 130px;
}
.nd-graph-legend {
  display: flex;
  flex-direction: column;
  gap: 8px;
  padding: 12px 14px;
  background: #fff;
  border: 1px solid #e6e9f5;
  border-radius: 10px;
  box-shadow: 0 1px 2px rgba(27, 33, 69, 0.04);
}
.nd-graph-legend span {
  display: flex;
  align-items: center;
  font-size: 12.5px;
  font-weight: 600;
  color: #444b63;
}
.nd-graph-legend .dot {
  display: inline-block;
  width: 9px;
  height: 9px;
  border-radius: 50%;
  margin-right: 8px;
  flex-shrink: 0;
}

/* ---------- sidebar + content ---------- */
.nd-body {
  display: flex;
  align-items: flex-start;
  gap: 40px;
  padding: 32px 40px 64px;
}
.nd-sidebar {
  flex: 0 0 220px;
  position: sticky;
  top: 24px;
}
.nd-sidebar-label {
  font-size: 11px;
  font-weight: 700;
  letter-spacing: 0.07em;
  text-transform: uppercase;
  color: #9aa1c2;
  padding-left: 13px;
  margin-bottom: 10px;
}
.nd-sidebar nav {
  display: flex;
  flex-direction: column;
  gap: 1px;
  border-left: 1.5px solid #e6e9f5;
}
.nd-nav-link {
  padding: 7px 12px;
  margin-left: -1.5px;
  font-size: 13.5px;
  font-weight: 500;
  line-height: 1.35;
  color: #6b7280;
  text-decoration: none;
  border-left: 1.5px solid transparent;
  transition: background 0.12s ease, color 0.12s ease, border-color 0.12s ease;
}
.nd-nav-link:hover {
  color: #3949ab;
}
.nd-nav-link.active {
  color: var(--accent);
  font-weight: 700;
  border-left-color: var(--accent);
  background: color-mix(in srgb, var(--accent) 7%, transparent);
}
.nd-content {
  flex: 1 1 auto;
  min-width: 0;
  max-width: 940px;
}

.card {
  background: #fff;
  border: 1px solid #e2e5ea;
  border-radius: 12px;
  padding: 22px 24px;
  margin-bottom: 16px;
  scroll-margin-top: 24px;
}
h2 {
  font-size: 15px;
  margin: 0 0 14px;
  display: flex;
  align-items: center;
  gap: 8px;
  color: #1b2145;
}
h3 {
  margin: 0;
}
.membership-group h3,
h2 {
  overflow: visible;
}
.count {
  font-weight: 400;
  font-size: 12px;
  color: #6b7280;
}
.badge {
  font-size: 11px;
  font-weight: 700;
  padding: 2px 8px;
  border-radius: 999px;
  background: #eef1ff;
  color: #3949ab;
}
.badge.small {
  margin-right: 8px;
}
.props {
  display: grid;
  grid-template-columns: 200px 1fr;
  gap: 6px 12px;
  font-size: 14px;
}
.props dt {
  color: #6b7280;
  overflow: visible;
}
.props dd {
  margin: 0;
  word-break: break-word;
}
.relationship-evidence {
  margin-top: 18px;
  padding-top: 16px;
  border-top: 1px solid #edf1f5;
}
.relationship-evidence h3 {
  display: flex;
  align-items: center;
  gap: 6px;
  margin: 0 0 10px;
  color: #1b2145;
  font-size: 13px;
  font-weight: 750;
}
.prop-link {
  color: #3949ab;
  font-weight: 600;
  text-decoration: none;
}
.prop-link:hover {
  text-decoration: underline;
}
.confidence-badge,
.direction-badge {
  display: inline-block;
  font-size: 11px;
  font-weight: 700;
  text-transform: uppercase;
  letter-spacing: 0.02em;
  padding: 3px 10px;
  border-radius: 999px;
}
.phenotype-badge-list {
  display: flex;
  flex-wrap: wrap;
  gap: 8px;
}
.phenotype-badge {
  display: inline-block;
  font-size: 12.5px;
  font-weight: 700;
  padding: 3px 12px;
  border-radius: 999px;
  background: rgba(179, 86, 44, 0.1);
  color: #b3562c;
  text-decoration: none;
  transition: background 0.1s ease;
}
.phenotype-badge:hover {
  background: rgba(179, 86, 44, 0.18);
}
.dir-up {
  background: rgba(26, 143, 94, 0.12);
  color: #1a8f5e;
}
.dir-down {
  background: rgba(179, 86, 44, 0.12);
  color: #b3562c;
}
.dir-neutral {
  background: rgba(108, 117, 125, 0.12);
  color: #6b7280;
}
/* A spacious ranked list (name + similarity bar), not a dense card grid --
   closer to how reference platforms show ranked associations. */
.neighbor-list {
  display: flex;
  flex-direction: column;
}
.neighbor-row {
  display: flex;
  align-items: center;
  gap: 14px;
  padding: 12px 4px;
  border-bottom: 1px solid #f0f1f6;
  text-decoration: none;
  color: #1b1f24;
  transition: background 0.1s ease;
}
.neighbor-row:last-child {
  border-bottom: none;
}
.neighbor-row:hover {
  background: #f7f8fc;
}
.neighbor-row-name {
  flex: 1 1 auto;
  min-width: 0;
  font-size: 14px;
  font-weight: 600;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}
.neighbor-row-tier {
  flex-shrink: 0;
  font-size: 11px;
  font-weight: 700;
  text-transform: uppercase;
  letter-spacing: 0.02em;
  padding: 2px 8px;
  border-radius: 999px;
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
/* Reuses the same tier-badge slot for MEMBER_OF's core/supporting/contextual
   role (Metabolite page), matching the anchor/supporting/contextual color
   language used for module membership elsewhere on the site. */
.tier-core {
  background: rgba(26, 143, 94, 0.12);
  color: #1a8f5e;
}
.tier-supporting {
  background: rgba(179, 86, 44, 0.12);
  color: #b3562c;
}
.tier-contextual {
  background: #eef0f7;
  color: #6b7280;
}
.neighbor-row-bar {
  flex-shrink: 0;
  width: 110px;
  height: 6px;
  border-radius: 999px;
  background: #eef0f7;
  overflow: hidden;
}
.neighbor-row-bar-fill {
  display: block;
  height: 100%;
  background: var(--accent);
  border-radius: 999px;
}
.neighbor-row-pct {
  flex-shrink: 0;
  width: 38px;
  text-align: right;
  font-size: 13px;
  font-weight: 700;
  color: var(--accent);
  font-variant-numeric: tabular-nums;
}
.neighbor-row-arrow {
  flex-shrink: 0;
  width: 14px;
  height: 14px;
  color: #c3c8db;
}
.neighbor-row:hover .neighbor-row-arrow {
  color: var(--accent);
}

/* ---------- Module layout ---------- */
.tag {
  font-size: 12px;
  font-weight: 600;
  padding: 3px 10px;
  border-radius: 999px;
  background: rgba(26, 143, 94, 0.12);
  color: #1a8f5e;
}
.tag-static {
  background: #eef0f7;
  color: #55607a;
}

.membership-group {
  margin-bottom: 18px;
}
.membership-group:last-child {
  margin-bottom: 0;
}
.membership-group h3 {
  font-size: 13px;
  font-weight: 700;
  color: #1b2145;
  margin: 0 0 8px;
  display: flex;
  align-items: center;
  gap: 8px;
}
.chip-list {
  display: flex;
  flex-wrap: wrap;
  gap: 6px;
}
.chip {
  display: inline-block;
  font-size: 12.5px;
  padding: 5px 12px;
  border-radius: 999px;
  background: #f0f4ff;
  color: #3949ab;
  text-decoration: none;
  border: 1px solid #dde3fb;
}
.chip:hover {
  background: #e3e9ff;
}
.chip-disabled {
  pointer-events: none;
  background: #f2f3f6;
  color: #8790b3;
  border-color: #e6e8ef;
}

.origin-bar {
  display: flex;
  height: 10px;
  border-radius: 999px;
  overflow: hidden;
  background: #eef0f7;
  margin-bottom: 10px;
}
.origin-bar-endo {
  background: #1a8f5e;
}
.origin-bar-exo {
  background: #b3562c;
}
.origin-bar-unknown {
  background: #d7dbe6;
}
.origin-legend {
  display: flex;
  flex-wrap: wrap;
  gap: 18px;
  font-size: 13.5px;
  color: #3a3f4a;
}
.origin-legend .unknown {
  color: #8790b3;
}
.origin-legend .dot {
  display: inline-block;
  width: 9px;
  height: 9px;
  border-radius: 50%;
  margin-right: 6px;
}
.dot-endo {
  background: #1a8f5e;
}
.dot-exo {
  background: #b3562c;
}
.dot-unknown {
  background: #d7dbe6;
}

.coverage-group {
  margin-bottom: 18px;
}
.coverage-group:last-child {
  margin-bottom: 0;
}
.coverage-group h3 {
  font-size: 13px;
  font-weight: 700;
  color: #1b2145;
  margin: 0 0 8px;
}
.pathway-grid {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(220px, 1fr));
  gap: 8px;
}
.pathway-card {
  display: flex;
  flex-direction: column;
  gap: 3px;
  padding: 10px 12px;
  border-radius: 10px;
  border: 1px solid #e2e5ea;
  background: #f7f8fa;
}
.pathway-id {
  font-family: 'SFMono-Regular', Menlo, Consolas, monospace;
  font-size: 11.5px;
  font-weight: 700;
  color: #3949ab;
}
.pathway-name {
  font-size: 13px;
  color: #3a3f4a;
  line-height: 1.4;
}

.ref-list {
  display: flex;
  flex-wrap: wrap;
  gap: 8px;
}
.ref-card {
  display: flex;
  align-items: center;
  gap: 8px;
  padding: 8px 14px;
  border-radius: 10px;
  border: 1px solid #e2e5ea;
  background: #f7f8fa;
  color: #3949ab;
  text-decoration: none;
  font-size: 13px;
  font-weight: 600;
}
.ref-card:hover {
  background: #eef1ff;
  border-color: #b9c3ff;
}
.ref-arrow {
  width: 12px;
  height: 12px;
  flex-shrink: 0;
}

@media (max-width: 1100px) {
  .nd-graph-panel {
    display: none;
  }
}

@media (max-width: 900px) {
  .nd-body {
    flex-direction: column;
  }
  .nd-sidebar {
    position: static;
    flex: 0 0 auto;
    width: 100%;
  }
  .nd-sidebar nav {
    flex-direction: row;
    flex-wrap: wrap;
    border-left: none;
    gap: 6px;
  }
  .nd-nav-link {
    margin-left: 0;
    border-left: none;
    border-bottom: 1.5px solid transparent;
    background: #f0f2f9;
    border-radius: 999px;
    padding: 6px 14px;
  }
  .nd-nav-link.active {
    border-bottom-color: transparent;
  }
  .nd-content {
    max-width: none;
  }
}
</style>
