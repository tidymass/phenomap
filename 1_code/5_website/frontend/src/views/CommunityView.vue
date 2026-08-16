<template>
  <div class="community-page">
    <section class="community-hero">
      <div class="hero-inner">
        <p class="eyebrow">PhenoMAP Community</p>
        <h1>Community</h1>
        <p>Submit metabolomics study data for PhenoMAP review, curation, and future public release.</p>
      </div>
    </section>

    <main class="community-container community-workspace">
      <section class="workspace-panel submissions-panel">
        <div class="panel-head">
          <div>
            <h2>My submissions</h2>
            <p>Track uploaded studies and review status.</p>
          </div>
          <span class="record-count">{{ submissions.length }} records</span>
        </div>

        <div class="submission-table-wrap">
          <table class="submission-table">
            <thead>
              <tr>
                <th>Upload #</th>
                <th>Phenotype</th>
                <th>Submitted</th>
                <th>Status</th>
                <th>Included</th>
                <th>PhenoMAP link</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              <tr v-if="!submissions.length">
                <td colspan="7">
                  <div class="table-empty">
                    <strong>{{ authState.user ? 'No submitted studies yet' : 'Sign in to track your submissions' }}</strong>
                    <span>{{ authState.user ? 'New submissions will appear here after you send them for review.' : 'Submission history is linked to your PhenoMAP account.' }}</span>
                  </div>
                </td>
              </tr>
              <tr
                v-for="submission in submissions"
                :key="submission.id"
                class="clickable-row"
                :class="{ selected: selectedSubmission?.id === submission.id }"
                @click="selectedSubmission = submission"
              >
                <td>
                  <strong>#{{ submission.uploadNumber }}</strong>
                  <span>{{ submission.id }}</span>
                </td>
                <td>{{ submission.phenotype }}</td>
                <td>{{ submission.submittedAt }}</td>
                <td><span class="status-pill">{{ submission.status }}</span></td>
                <td><span class="included-pill" :class="submission.inclusionClass">{{ submission.included }}</span></td>
                <td>
                  <a v-if="submission.phenomapLink" :href="submission.phenomapLink" class="phenomap-link">Open record</a>
                  <span v-else class="pending-link">Pending</span>
                </td>
                <td><button type="button" class="details-link">Details</button></td>
              </tr>
            </tbody>
          </table>
        </div>

        <div v-if="selectedSubmission" class="submission-details">
          <div>
            <span>Study title</span>
            <strong>{{ selectedSubmission.title || 'Not provided' }}</strong>
          </div>
          <div>
            <span>Study design</span>
            <strong>{{ selectedSubmission.studyDesign || 'Not provided' }}</strong>
          </div>
          <div>
            <span>Biospecimen</span>
            <strong>{{ selectedSubmission.biospecimen || 'Not provided' }}</strong>
          </div>
          <div>
            <span>Files</span>
            <strong>{{ selectedSubmission.files }}</strong>
          </div>
          <div>
            <span>Contact</span>
            <strong>{{ selectedSubmission.contactEmail || 'Not provided' }}</strong>
          </div>
        </div>
      </section>

      <section class="workspace-panel submit-panel">
        <div class="panel-head submit-head">
          <div>
            <h2>New submission</h2>
            <p>Complete the study metadata, upload files in the required format, and send the dataset for review.</p>
          </div>
          <span class="draft-chip">Draft</span>
        </div>

        <ol class="submission-steps" aria-label="Submission sections">
          <li class="active"><span>1</span>Study metadata</li>
          <li><span>2</span>Data files</li>
          <li><span>3</span>Contact</li>
        </ol>

        <form class="submission-form" @submit.prevent="handleSubmit">
          <section class="form-section">
            <div class="section-title">
              <span>01</span>
              <h3>Study metadata</h3>
            </div>
            <div class="form-grid">
              <label class="wide">
                <span>Study title <b>*</b></span>
                <input v-model="form.title" type="text" placeholder="Plasma metabolomics in ulcerative colitis" />
              </label>
              <label>
                <span>Phenotype <b>*</b></span>
                <input v-model="form.phenotype" type="text" placeholder="Ulcerative colitis" />
              </label>
              <label>
                <span>Ontology ID</span>
                <input v-model="form.phenotypeId" type="text" placeholder="MONDO / EFO / HP ID" />
              </label>
              <label>
                <span>Study design <b>*</b></span>
                <select v-model="form.studyDesign">
                  <option value="">Select design</option>
                  <option>case-control</option>
                  <option>cohort</option>
                  <option>intervention</option>
                  <option>time-course</option>
                  <option>cross-sectional</option>
                  <option>other</option>
                </select>
              </label>
              <label>
                <span>Sample size <b>*</b></span>
                <input v-model="form.sampleSize" type="number" min="1" placeholder="Analyzed samples" />
              </label>
              <label>
                <span>Biospecimen <b>*</b></span>
                <input v-model="form.biospecimen" type="text" placeholder="plasma, serum, urine" />
              </label>
              <label>
                <span>MS2 support <b>*</b></span>
                <select v-model="form.ms2Supported">
                  <option value="">Select one</option>
                  <option value="yes">Yes</option>
                  <option value="partial">Partial</option>
                  <option value="no">No</option>
                  <option value="unknown">Not reported</option>
                </select>
              </label>
              <label>
                <span>Chromatography <b>*</b></span>
                <input v-model="form.chromatography" type="text" placeholder="UHPLC, HILIC, GC" />
              </label>
              <label>
                <span>Mass spectrometry <b>*</b></span>
                <input v-model="form.massSpectrometry" type="text" placeholder="Orbitrap, QTOF, QQQ" />
              </label>
              <label class="wide">
                <span>Study summary <b>*</b></span>
                <textarea v-model="form.summary" rows="3" placeholder="Briefly describe cohort, sample groups, assay, and study purpose."></textarea>
              </label>
            </div>
          </section>

          <section class="form-section">
            <div class="section-title">
              <span>02</span>
              <h3>Data files</h3>
            </div>
            <div class="upload-grid">
              <div
                v-for="file in fileRequirements"
                :key="file.key"
                class="upload-card"
                :class="{ hasFile: fileNames[file.key] }"
                @dragover.prevent
                @drop.prevent="dropFile(file.key, $event)"
              >
                <input
                  :id="`file-${file.key}`"
                  type="file"
                  :accept="file.accept"
                  @change="setFile(file.key, $event)"
                />
                <label :for="`file-${file.key}`" class="upload-target">
                  <span class="file-icon" aria-hidden="true">
                    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8">
                      <path d="M12 4v10" />
                      <path d="m8 10 4 4 4-4" />
                      <path d="M5 20h14" />
                    </svg>
                  </span>
                  <strong>{{ file.title }}</strong>
                  <small>{{ fileNames[file.key] || file.hint }}</small>
                  <em :class="{ optional: !file.required }">{{ file.required ? 'Required' : 'Optional' }}</em>
                </label>
                <button
                  type="button"
                  class="format-button"
                  :aria-label="`Show ${file.title} format`"
                  @click="toggleFormat(file.key)"
                >
                  i
                </button>
                <div v-if="activeFormatKey === file.key" class="format-panel">
                  <strong>Required format</strong>
                  <span>{{ file.format }}</span>
                  <code>{{ file.example }}</code>
                </div>
              </div>
            </div>
          </section>

          <section class="form-section">
            <div class="section-title">
              <span>03</span>
              <h3>Publication & contact</h3>
            </div>
            <div class="form-grid">
              <label>
                <span>Publication DOI</span>
                <input v-model="form.doi" type="text" placeholder="10.xxxx/xxxxx" />
              </label>
              <label>
                <span>Source link</span>
                <input v-model="form.sourceLink" type="url" placeholder="Repository or publication URL" />
              </label>
              <label>
                <span>Contact name <b>*</b></span>
                <input v-model="form.contactName" type="text" placeholder="Submitter or corresponding author" />
              </label>
              <label>
                <span>Contact email <b>*</b></span>
                <input v-model="form.contactEmail" type="email" placeholder="name@institution.edu" />
              </label>
              <label class="wide">
                <span>Reviewer notes</span>
                <textarea v-model="form.notes" rows="2" placeholder="Optional notes about preprocessing or feature identifiers."></textarea>
              </label>
            </div>
          </section>

          <div class="submit-row">
            <p>Accepted studies receive a PhenoMAP study ID in a future release.</p>
            <button type="submit">{{ authState.user ? 'Submit for review' : 'Sign in to submit' }}</button>
          </div>
          <p v-if="submitMessage" class="submit-message">{{ submitMessage }}</p>
        </form>
      </section>
    </main>
  </div>
</template>

<script setup>
import { reactive, ref } from 'vue'
import { authState } from '../auth.js'

const form = reactive({
  title: '',
  phenotype: '',
  phenotypeId: '',
  studyDesign: '',
  sampleSize: '',
  biospecimen: '',
  ms2Supported: '',
  chromatography: '',
  massSpectrometry: '',
  summary: '',
  doi: '',
  sourceLink: '',
  contactName: '',
  contactEmail: '',
  notes: '',
})

const fileNames = reactive({
  featureTable: '',
  sampleMetadata: '',
  metaboliteAnnotation: '',
})

const submitMessage = ref('')
const submissions = ref([])
const selectedSubmission = ref(null)
const activeFormatKey = ref('')

const fileRequirements = [
  {
    key: 'featureTable',
    title: 'Feature table',
    hint: 'CSV, TSV, TXT, or XLSX',
    required: true,
    accept: '.csv,.tsv,.txt,.xlsx',
    format: 'Rows are metabolite features. The first column must be feature_id; all following columns must be sample IDs with numeric intensity values.',
    example: 'feature_id,sample_001,sample_002',
  },
  {
    key: 'sampleMetadata',
    title: 'Sample metadata',
    hint: 'CSV, TSV, TXT, or XLSX',
    required: true,
    accept: '.csv,.tsv,.txt,.xlsx',
    format: 'Rows are samples. Required columns are sample_id and phenotype or group. Batch, sex, age, and other covariates can be added when available.',
    example: 'sample_id,group,batch',
  },
  {
    key: 'metaboliteAnnotation',
    title: 'Metabolite annotation',
    hint: 'CSV, TSV, TXT, or XLSX',
    required: false,
    accept: '.csv,.tsv,.txt,.xlsx',
    format: 'Rows map feature IDs to metabolite annotations. Required column: feature_id. Provide at least one identifier column among hmdb_id, kegg_id, or inchi_id.',
    example: 'feature_id,metabolite_name,hmdb_id,kegg_id,inchi_id',
  },
]

function setFile(key, event) {
  const file = event.target.files?.[0]
  fileNames[key] = file?.name || ''
}

function dropFile(key, event) {
  const file = event.dataTransfer?.files?.[0]
  fileNames[key] = file?.name || ''
}

function toggleFormat(key) {
  activeFormatKey.value = activeFormatKey.value === key ? '' : key
}

function handleSubmit() {
  if (!authState.user) {
    submitMessage.value = 'Please sign in before submitting study data.'
    return
  }

  const now = new Date()
  const uploadNumber = submissions.value.length + 1
  const id = `SUB-${now.getFullYear()}-${String(uploadNumber).padStart(3, '0')}`
  const uploadedFiles = Object.values(fileNames).filter(Boolean)
  const submission = {
    id,
    uploadNumber,
    title: form.title || 'Untitled study',
    phenotype: form.phenotype || 'Not provided',
    submittedAt: now.toLocaleDateString(undefined, { month: 'short', day: 'numeric', year: 'numeric' }),
    status: 'Submitted',
    included: 'Pending',
    inclusionClass: 'pending',
    phenomapLink: '',
    studyDesign: form.studyDesign,
    biospecimen: form.biospecimen,
    files: uploadedFiles.length ? uploadedFiles.join(', ') : 'No files uploaded',
    contactEmail: form.contactEmail,
  }

  submissions.value = [submission, ...submissions.value]
  selectedSubmission.value = submission
  submitMessage.value = 'Submission added to your review queue preview. Review endpoints still need to be connected.'
}
</script>

<style scoped>
.community-page {
  min-height: calc(100vh - 69px);
  background: #f4f7fa;
  color: #182033;
}

.community-container {
  width: min(100%, 1680px);
  margin: 0 auto;
  padding: 0 48px;
  box-sizing: border-box;
}

.community-hero {
  background:
    radial-gradient(circle at 16% 18%, rgba(143, 215, 234, 0.3), transparent 28%),
    radial-gradient(circle at 82% 18%, rgba(79, 181, 155, 0.18), transparent 30%),
    linear-gradient(135deg, #1d5876 0%, #2d7895 52%, #245f7d 100%);
  border-bottom: 0;
}

.hero-inner {
  max-width: 1680px;
  margin: 0 auto;
  padding: 34px 0 32px;
  width: 90vw;
  box-sizing: border-box;
  text-align: left;
}

.eyebrow {
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

.hero-inner h1 {
  max-width: none;
  margin: 12px 0 8px;
  color: #fff;
  font-size: 36px;
  font-weight: 800;
  line-height: 1.02;
  letter-spacing: -0.01em;
}

.hero-inner p:not(.eyebrow) {
  max-width: 1100px;
  margin: 0;
  color: #d8e7ef;
  font-size: 15.5px;
  line-height: 1.6;
  font-weight: 600;
}

.community-workspace {
  display: grid;
  gap: 22px;
  width: min(90vw, 1680px);
  max-width: none;
  padding-right: 0;
  padding-left: 0;
  padding-top: 30px;
  padding-bottom: 72px;
}

.workspace-panel {
  background: #fff;
  border: 1px solid #dfe6ee;
  border-radius: 10px;
  box-shadow: 0 18px 40px -34px rgba(15, 23, 42, 0.45);
}

.panel-head {
  display: flex;
  align-items: flex-start;
  justify-content: space-between;
  gap: 18px;
  padding: 24px 26px 18px;
}

.panel-head h2 {
  margin: 0;
  color: #182033;
  font-size: 24px;
  font-weight: 850;
  letter-spacing: 0;
}

.panel-head p {
  margin: 6px 0 0;
  color: #68778b;
  font-size: 14px;
}

.record-count,
.draft-chip {
  display: inline-flex;
  align-items: center;
  min-height: 28px;
  padding: 0 11px;
  border-radius: 999px;
  background: #eef7fa;
  color: #0f7c96;
  font-size: 12px;
  font-weight: 850;
  white-space: nowrap;
}

.submission-table-wrap {
  margin: 0 26px 24px;
  overflow-x: auto;
  border: 1px solid #e3e9f0;
  border-radius: 8px;
}

.submission-table {
  width: 100%;
  min-width: 980px;
  border-collapse: collapse;
}

.submission-table th,
.submission-table td {
  padding: 14px 16px;
  border-bottom: 1px solid #edf1f5;
  text-align: left;
}

.submission-table th {
  background: #f7f9fb;
  color: #6a7788;
  font-size: 11px;
  font-weight: 850;
  letter-spacing: 0.045em;
  text-transform: uppercase;
}

.submission-table td {
  color: #344155;
  font-size: 14px;
}

.submission-table tbody tr:last-child td {
  border-bottom: 0;
}

.submission-table td strong {
  display: block;
  color: #1f2738;
  font-weight: 850;
}

.submission-table td span {
  display: block;
  margin-top: 3px;
  color: #78869a;
  font-size: 12px;
}

.clickable-row {
  cursor: pointer;
  transition: background 0.16s ease;
}

.clickable-row:hover,
.clickable-row.selected {
  background: #f3fafc;
}

.status-pill {
  display: inline-flex !important;
  width: fit-content;
  margin: 0 !important;
  padding: 5px 9px;
  border-radius: 999px;
  background: #eef7fa;
  color: #0f7c96 !important;
  font-size: 12px !important;
  font-weight: 850;
}

.included-pill {
  display: inline-flex !important;
  width: fit-content;
  margin: 0 !important;
  padding: 5px 9px;
  border-radius: 999px;
  background: #eef1f5;
  color: #607086 !important;
  font-size: 12px !important;
  font-weight: 850;
}

.included-pill.pending {
  background: #fff7ed;
  color: #b3562c !important;
}

.phenomap-link,
.pending-link {
  display: inline-flex !important;
  width: fit-content;
  margin: 0 !important;
  font-size: 13px !important;
  font-weight: 850;
}

.phenomap-link {
  color: #0f7c96 !important;
  text-decoration: none;
}

.phenomap-link:hover {
  text-decoration: underline;
}

.pending-link {
  color: #8a96a8 !important;
}

.details-link {
  border: 0;
  background: transparent;
  color: #0f7c96;
  font: inherit;
  font-size: 13px;
  font-weight: 850;
  cursor: pointer;
}

.table-empty {
  display: grid;
  gap: 4px;
  padding: 20px 0;
  text-align: center;
}

.table-empty strong {
  color: #20283a;
  font-size: 15px;
}

.table-empty span {
  color: #68778b !important;
  font-size: 13px !important;
}

.submission-details {
  display: grid;
  grid-template-columns: repeat(4, minmax(0, 1fr));
  gap: 14px;
  margin: -8px 26px 24px;
  padding: 16px;
  border-radius: 8px;
  background: #f7f9fb;
}

.submission-details div {
  display: grid;
  gap: 4px;
  min-width: 0;
}

.submission-details span {
  color: #6a7788;
  font-size: 11px;
  font-weight: 850;
  letter-spacing: 0.045em;
  text-transform: uppercase;
}

.submission-details strong {
  overflow: hidden;
  color: #1f2738;
  font-size: 13px;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.submit-panel {
  padding-bottom: 26px;
}

.submission-steps {
  display: grid;
  grid-template-columns: repeat(3, 1fr);
  gap: 8px;
  margin: 0 26px 4px;
  padding: 0;
  list-style: none;
}

.submission-steps li {
  display: flex;
  align-items: center;
  gap: 8px;
  min-height: 38px;
  padding: 0 12px;
  border-radius: 8px;
  background: #f5f8fb;
  color: #59677a;
  font-size: 13px;
  font-weight: 800;
}

.submission-steps li.active {
  background: #eef7fa;
  color: #0f7c96;
}

.submission-steps span {
  width: 20px;
  height: 20px;
  display: inline-flex;
  align-items: center;
  justify-content: center;
  flex: 0 0 auto;
  border-radius: 999px;
  background: #fff;
  font-size: 11px;
}

.submission-form {
  margin: 0 26px;
}

.form-section {
  padding: 22px 0;
  border-top: 1px solid #edf1f5;
}

.section-title {
  display: flex;
  align-items: center;
  gap: 10px;
  margin-bottom: 14px;
}

.section-title span {
  color: #0f7c96;
  font-size: 13px;
  font-weight: 900;
}

.section-title h3 {
  margin: 0;
  color: #20283a;
  font-size: 16px;
  font-weight: 850;
}

.form-grid {
  display: grid;
  grid-template-columns: repeat(2, minmax(0, 1fr));
  gap: 13px 14px;
}

.wide {
  grid-column: 1 / -1;
}

label {
  display: grid;
  gap: 6px;
}

label span {
  color: #647286;
  font-size: 11px;
  font-weight: 850;
  letter-spacing: 0.045em;
  text-transform: uppercase;
}

label b {
  color: #b3562c;
}

input,
select,
textarea {
  width: 100%;
  box-sizing: border-box;
  border: 1px solid #d9e0e8;
  border-radius: 7px;
  background: #fbfcfd;
  color: #20283a;
  font: inherit;
  font-size: 14px;
  padding: 10px 11px;
}

textarea {
  resize: vertical;
}

.upload-grid {
  display: grid;
  grid-template-columns: repeat(3, minmax(0, 1fr));
  gap: 18px;
}

.upload-card {
  position: relative;
  min-width: 0;
  border: 1px dashed #cdd8e3;
  border-radius: 8px;
  background: #fbfcfd;
  transition: border-color 0.16s ease, background 0.16s ease;
}

.upload-card:hover,
.upload-card.hasFile {
  border-color: #86bdca;
  background: #f5fbfc;
}

.upload-card input {
  display: none;
}

.upload-target {
  display: grid;
  grid-template-columns: 40px minmax(0, 1fr);
  gap: 7px 14px;
  align-items: center;
  min-height: 126px;
  padding: 18px 56px 18px 18px;
  cursor: pointer;
}

.file-icon {
  grid-row: span 3;
  width: 40px;
  height: 40px;
  display: inline-flex;
  align-items: center;
  justify-content: center;
  border-radius: 8px;
  background: #eef7fa;
  color: #0f7c96;
}

.file-icon svg {
  width: 20px;
  height: 20px;
}

.upload-target strong {
  min-width: 0;
  color: #20283a;
  font-size: 15px;
  font-weight: 850;
}

.upload-target small {
  color: #68778b;
  font-size: 13px;
  line-height: 1.35;
  white-space: normal;
}

.upload-target em {
  width: fit-content;
  padding: 4px 8px;
  border-radius: 999px;
  background: rgba(179, 86, 44, 0.1);
  color: #b3562c;
  font-size: 10px;
  font-style: normal;
  font-weight: 850;
  text-transform: uppercase;
}

.upload-target em.optional {
  background: #eef1f5;
  color: #607086;
}

.format-button {
  position: absolute;
  top: 10px;
  right: 10px;
  width: 22px;
  height: 22px;
  border: 1px solid #b8d2dc;
  border-radius: 999px;
  background: #fff;
  color: #0f7c96;
  font: inherit;
  font-size: 12px;
  font-weight: 850;
  cursor: pointer;
}

.format-panel {
  position: absolute;
  z-index: 5;
  right: 10px;
  left: 10px;
  top: 40px;
  display: grid;
  gap: 6px;
  padding: 12px;
  border: 1px solid #d8e3eb;
  border-radius: 8px;
  background: #fff;
  box-shadow: 0 18px 30px -24px rgba(15, 23, 42, 0.45);
}

.format-panel strong {
  color: #20283a;
  font-size: 12px;
}

.format-panel span {
  color: #59677a;
  font-size: 12px;
  line-height: 1.45;
  overflow-wrap: anywhere;
}

.format-panel code {
  border-radius: 6px;
  background: #f2f5f8;
  color: #0f667d;
  font-size: 11px;
  line-height: 1.45;
  padding: 7px;
  white-space: normal;
  overflow-wrap: anywhere;
}

.submit-row {
  display: flex;
  justify-content: space-between;
  align-items: center;
  gap: 16px;
  padding-top: 18px;
  border-top: 1px solid #edf1f5;
}

.submit-row p,
.submit-message {
  margin: 0;
  color: #68778b;
  font-size: 13px;
  line-height: 1.45;
}

.submit-row button {
  border: 0;
  border-radius: 7px;
  background: #0f7c96;
  color: #fff;
  padding: 11px 16px;
  font: inherit;
  font-size: 14px;
  font-weight: 850;
  cursor: pointer;
  white-space: nowrap;
}

.submit-message {
  margin-top: 12px;
  padding: 10px 12px;
  border-radius: 7px;
  background: #eef7fa;
  color: #0f667d;
}

@media (max-width: 960px) {
  .submission-details,
  .upload-grid {
    grid-template-columns: 1fr;
  }
}

@media (max-width: 720px) {
  .community-container {
    padding: 0 22px;
  }

  .hero-inner {
    padding: 30px 22px 30px;
  }

  .panel-head,
  .submit-row {
    align-items: stretch;
    flex-direction: column;
  }

  .submission-steps,
  .form-grid {
    grid-template-columns: 1fr;
  }
}
</style>
