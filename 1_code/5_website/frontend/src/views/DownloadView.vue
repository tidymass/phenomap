<template>
  <div class="download-page">
    <section class="download-hero">
      <div class="download-hero-inner">
        <p class="eyebrow">Download</p>
        <h1>Download Files</h1>
        <p>Export the entity and relationship tables underlying the PhenoMAP knowledge graph as flat CSV files.</p>
      </div>
    </section>

    <section class="download-body">
      <p v-if="error" class="error">{{ error }}</p>

      <div class="download-layout">
        <section class="table-panel" aria-label="Downloadable CSV files">
          <div class="table-toolbar">
            <label class="select-all-control">
              <input
                type="checkbox"
                :checked="allSelected"
                @change="toggleAll($event.target.checked)"
              />
              Select All
            </label>

            <a
              v-if="selectedCount > 0"
              :href="selectedDownloadUrl"
              download
              class="download-link"
            >
              Download Selected ({{ selectedCount }})
            </a>
            <span v-else class="download-link disabled">Download Selected</span>
          </div>

          <div class="table-wrap">
            <table class="file-table">
              <thead>
                <tr>
                  <th class="check-column">Select</th>
                  <th>Type</th>
                  <th>CSV File</th>
                  <th>Content</th>
                  <th class="numeric-column">Rows</th>
                  <th class="numeric-column">Size</th>
                  <th class="action-column">Download</th>
                </tr>
              </thead>
              <tbody>
                <tr v-for="f in tableRows" :key="f.name" :class="{ selected: selectedMap[f.name] }">
                  <td class="check-column">
                    <input
                      v-model="selectedMap[f.name]"
                      type="checkbox"
                      :aria-label="`Select ${f.name}`"
                    />
                  </td>
                  <td>
                    <span class="type-label">{{ f.type }}</span>
                  </td>
                  <td>
                    <code>{{ f.name }}</code>
                  </td>
                  <td class="content-cell">
                    <strong>{{ f.label }}</strong>
                    <span>{{ f.desc }}</span>
                  </td>
                  <td class="numeric-column">{{ countFor(f) }}</td>
                  <td class="numeric-column">{{ fileSizes[f.name] }}</td>
                  <td class="action-column">
                    <a :href="downloadUrl(f.name)" download class="row-download">CSV</a>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </section>
      </div>
    </section>
  </div>
</template>

<script setup>
import { computed, onMounted, reactive, ref } from 'vue'
import { downloadAllUrl, downloadUrl, getStats } from '../api.js'

const stats = ref(null)
const error = ref('')

const sections = [
  {
    name: 'Entity',
    files: [
      { name: 'nodes_study.csv', label: 'Study', statType: 'node', statKey: 'Study', desc: 'Study metadata, including accession, title, study design, sample size, analytical instrument, and investigated phenotype.' },
      { name: 'nodes_phenotype.csv', label: 'Phenotype', statType: 'node', statKey: 'Phenotype', desc: 'Normalized phenotype terms used across PhenoMAP, mapped to standard ontology identifiers where available.' },
      { name: 'nodes_module.csv', label: 'Module', statType: 'node', statKey: 'Module', desc: 'Dysregulated metabolic modules identified by FeatureMAP, with module title, annotation, member metabolites, and confidence classification.' },
      { name: 'nodes_metabolite.csv', label: 'Metabolite', statType: 'node', statKey: 'Metabolite', desc: 'Metabolite identifiers and chemical classification, including HMDB, KEGG, and InChI accessions.' },
    ],
  },
  {
    name: 'Relationship',
    files: [
      { name: 'edges_study_phenotype.csv', label: 'INVESTIGATED', statType: 'rel', statKey: 'INVESTIGATED', desc: 'Study-to-phenotype links describing which phenotype each study investigates.' },
      { name: 'edges_module_study.csv', label: 'REPORTED_IN', statType: 'rel', statKey: 'REPORTED_IN', desc: 'Module-to-study links identifying the study in which each metabolic module was reported.' },
      { name: 'edges_metabolite_module.csv', label: 'MEMBER_OF', statType: 'rel', statKey: 'MEMBER_OF', desc: 'Metabolite membership within metabolic modules, classified as core, supporting, or contextual where available.' },
      { name: 'edges_metabolite_metabolite.csv', label: 'CONNECTED_WITH', statType: 'rel', statKey: 'CONNECTED_WITH', desc: 'Pairwise metabolite connections derived from the underlying metabolic reaction network.' },
      { name: 'edges_module_module.csv', label: 'SIMILAR_TO', statType: 'rel', statKey: 'SIMILAR_TO', desc: 'Cross-study module similarity quantified from biological and compositional similarity scores.' },
    ],
  },
]

const tableRows = sections.flatMap((section) => section.files.map((file) => ({
  ...file,
  type: section.name,
})))
const allFileNames = tableRows.map((f) => f.name)
const totalFiles = allFileNames.length

const selectedMap = reactive(Object.fromEntries(allFileNames.map((n) => [n, true])))
const fileSizes = reactive(Object.fromEntries(allFileNames.map((n) => [n, '...'])))

const selectedCount = computed(() => allFileNames.filter((n) => selectedMap[n]).length)
const allSelected = computed(() => selectedCount.value === totalFiles)

const selectedDownloadUrl = computed(() => {
  if (selectedCount.value === totalFiles) return downloadAllUrl()
  return downloadAllUrl(allFileNames.filter((n) => selectedMap[n]))
})

function toggleAll(value) {
  allFileNames.forEach((name) => {
    selectedMap[name] = value
  })
}

function countFor(f) {
  if (!stats.value) return '...'
  const list = f.statType === 'node' ? stats.value.nodes : stats.value.relationships
  const key = f.statType === 'node' ? 'label' : 'type'
  const row = list.find((r) => r[key] === f.statKey)
  return row ? row.count.toLocaleString() : '-'
}

function formatBytes(bytes) {
  if (!Number.isFinite(bytes) || bytes <= 0) return '-'
  const units = ['B', 'KB', 'MB', 'GB']
  let value = bytes
  let unitIndex = 0
  while (value >= 1024 && unitIndex < units.length - 1) {
    value /= 1024
    unitIndex += 1
  }
  const decimals = value >= 10 || unitIndex === 0 ? 0 : 1
  return `${value.toFixed(decimals)} ${units[unitIndex]}`
}

async function loadFileSize(file) {
  try {
    const response = await fetch(downloadUrl(file.name), { method: 'HEAD' })
    if (!response.ok) {
      fileSizes[file.name] = '-'
      return
    }
    fileSizes[file.name] = formatBytes(Number(response.headers.get('content-length')))
  } catch {
    fileSizes[file.name] = '-'
  }
}

onMounted(async () => {
  try {
    stats.value = await getStats()
  } catch (e) {
    error.value = e.message
  }
  await Promise.allSettled(tableRows.map(loadFileSize))
})
</script>

<style scoped>
.download-page {
  min-height: calc(100vh - 69px);
  overflow-x: hidden;
  background: #f7f8fa;
  color: #1b1f24;
}
.download-hero {
  background:
    radial-gradient(circle at 16% 18%, rgba(143, 215, 234, 0.3), transparent 28%),
    radial-gradient(circle at 82% 18%, rgba(79, 181, 155, 0.18), transparent 30%),
    linear-gradient(135deg, #1d5876 0%, #2d7895 52%, #245f7d 100%);
  border-bottom: 0;
}
.download-hero-inner {
  max-width: none;
  margin: 0 auto;
  padding: 34px 40px 32px;
  width: min(90vw, 1680px);
  box-sizing: border-box;
  text-align: left;
}
.eyebrow,
.section-kicker {
  display: inline-block;
  margin: 0;
  color: #8fd7ea;
  background: rgba(34, 211, 238, 0.12);
  border: 1px solid rgba(34, 211, 238, 0.3);
  border-radius: 999px;
  padding: 5px 14px;
  font-size: 12.5px;
  font-weight: 800;
  letter-spacing: 0.08em;
  text-transform: uppercase;
}
.download-hero h1 {
  max-width: none;
  margin: 12px 0 8px;
  color: #fff;
  font-size: 36px;
  font-weight: 800;
  line-height: 1.02;
  letter-spacing: -0.01em;
}
.download-hero p:not(.eyebrow) {
  max-width: 1100px;
  margin: 0;
  color: #d8e7ef;
  font-size: 15.5px;
  line-height: 1.6;
  font-weight: 600;
}
.download-body {
  max-width: none;
  margin: 0 auto;
  padding: 34px 40px 88px;
  width: min(90vw, 1680px);
  box-sizing: border-box;
}
.download-layout {
  display: block;
}
.table-panel {
  min-width: 0;
  border: 1px solid #e3ebef;
  border-top: 3px solid #8fd7ea;
  border-radius: 0;
  background: #ffffff;
  overflow: hidden;
  box-shadow: none;
}
.table-toolbar {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 20px;
  padding: 14px 16px;
  border-bottom: 1px solid #e3ebef;
  background: #f8fbfc;
}
.select-all-control {
  display: inline-flex;
  align-items: center;
  gap: 8px;
  color: #536172;
  font-size: 13px;
  font-weight: 800;
  cursor: pointer;
}
.select-all-control input,
.file-table input[type='checkbox'] {
  width: 16px;
  height: 16px;
  accent-color: #0f7c96;
  cursor: pointer;
}
.table-wrap {
  overflow-x: auto;
}
.file-table {
  width: 100%;
  min-width: 1120px;
  border-collapse: collapse;
  table-layout: fixed;
}
.file-table th {
  padding: 14px 16px;
  border-bottom: 1px solid #e3ebef;
  background: #f8fbfc;
  color: #536172;
  font-size: 13px;
  font-weight: 800;
  line-height: 1.25;
  text-align: left;
}
.file-table td {
  padding: 15px 16px;
  border-bottom: 1px solid #edf2f5;
  color: #293247;
  font-size: 15px;
  font-weight: 650;
  line-height: 1.45;
  vertical-align: top;
}
.file-table tbody tr:last-child td {
  border-bottom: 0;
}
.file-table tbody tr.selected {
  background: #ffffff;
}
.file-table tbody tr:hover {
  background: #f5fbfc;
}
.check-column {
  width: 70px;
}
.file-table th:nth-child(2),
.file-table td:nth-child(2) {
  width: 130px;
}
.file-table th:nth-child(3),
.file-table td:nth-child(3) {
  width: 230px;
}
.numeric-column {
  width: 92px;
  text-align: right;
  white-space: nowrap;
}
.action-column {
  width: 92px;
  text-align: right;
}
.type-label {
  display: inline-flex;
  align-items: center;
  gap: 7px;
  color: #536172;
  font-size: 14px;
  font-weight: 850;
}
.type-label::before {
  content: '';
  width: 8px;
  height: 8px;
  border-radius: 50%;
  background: #0f7c96;
}
.file-table code {
  color: #111827;
  font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace;
  font-size: 14px;
  font-weight: 500;
  overflow-wrap: anywhere;
}
.content-cell strong {
  display: block;
  margin-bottom: 4px;
  color: #111827;
  font-size: 15.5px;
  font-weight: 850;
}
.content-cell span {
  display: block;
  color: #667085;
  font-size: 14px;
  font-weight: 600;
  line-height: 1.5;
}
.row-download {
  color: #0f7c96;
  font-size: 14px;
  font-weight: 850;
  text-decoration: none;
}
.row-download:hover {
  color: #245c7e;
  text-decoration: underline;
}
.download-link {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  min-height: 34px;
  padding: 0 14px;
  border: 1px solid #245c7e;
  border-radius: 7px;
  background: #245c7e;
  color: #ffffff;
  font-size: 13px;
  font-weight: 850;
  text-decoration: none;
}
.download-link:hover {
  border-color: #174564;
  background: #174564;
  color: #ffffff;
}
.download-link.disabled {
  border-color: #d7dce8;
  background: #eef1f6;
  color: #9aa1b2;
  cursor: not-allowed;
}
.error {
  margin: 0 0 18px;
  color: #b42318;
  font-size: 15px;
  font-weight: 700;
}

@media (max-width: 720px) {
  .download-hero-inner {
    padding: 28px 24px 26px;
  }
  .download-hero h1 {
    font-size: 30px;
  }
  .download-body {
    padding: 28px 20px 56px;
  }
  .table-toolbar {
    align-items: flex-start;
    flex-direction: column;
    gap: 12px;
    padding: 20px;
  }
}
</style>
