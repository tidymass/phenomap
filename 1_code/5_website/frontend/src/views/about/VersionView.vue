<template>
  <div class="version-page">
    <section class="version-hero">
      <div class="version-hero-inner">
        <nav class="about-page-nav" aria-label="About page navigation">
          <router-link to="/about/citation" class="eyebrow about-prev-link" aria-label="Previous About page: Citation">
            <svg class="about-prev-arrow" viewBox="0 0 24 24" aria-hidden="true">
              <path d="M19 12H5" />
              <path d="m11 6-6 6 6 6" />
            </svg>
          </router-link>
          <span class="eyebrow about-current-page">Version</span>
          <router-link to="/about/contact" class="eyebrow about-next-link" aria-label="Next About page: Contact">
            <svg class="about-next-arrow" viewBox="0 0 24 24" aria-hidden="true">
              <path d="M5 12h14" />
              <path d="m13 6 6 6-6 6" />
            </svg>
          </router-link>
        </nav>
        <h1>Version</h1>
        <p>Current PhenoMAP release history and graph size.</p>
      </div>
    </section>

    <section class="version-body">
      <div class="version-table-wrap">
        <table class="version-table" aria-label="PhenoMAP version history">
          <colgroup>
            <col class="version-col" />
            <col class="date-col" />
            <col class="size-col" />
            <col class="size-col" />
            <col class="size-col" />
            <col class="size-col" />
            <col class="notes-col" />
          </colgroup>
          <thead>
            <tr>
              <th>Version</th>
              <th>Date</th>
              <th>Studies</th>
              <th>Phenotypes</th>
              <th>Modules</th>
              <th>Metabolites</th>
              <th>Notes</th>
            </tr>
          </thead>
          <tbody>
            <tr>
              <td class="version-id">{{ currentVersion }}</td>
              <td>{{ releaseDate }}</td>
              <td>{{ scopeByLabel.Studies }}</td>
              <td>{{ scopeByLabel.Phenotypes }}</td>
              <td>{{ scopeByLabel.Modules }}</td>
              <td>{{ scopeByLabel.Metabolites }}</td>
              <td class="notes-cell">{{ releaseNoteSummary }}</td>
            </tr>
          </tbody>
        </table>
      </div>
      <p class="version-note">* {{ facts.version.note }}</p>
    </section>
  </div>
</template>

<script setup>
// Single source of truth: see product_facts.json's _comment.
import facts from '../../data/product_facts.json'

const currentVersion = facts.version.current_version
const releaseDate = facts.version.release_date
const graphScope = facts.version.graph_scope
const releaseNotes = facts.version.release_notes
const scopeByLabel = Object.fromEntries(graphScope.map((item) => [item.label, item.value]))
const releaseNoteSummary = releaseNotes.map((note) => note.title).join('; ')
</script>

<style scoped>
.version-page {
  min-height: calc(100vh - 69px);
  overflow-x: hidden;
  background: #f7f8fa;
  color: #1b1f24;
}
.version-hero {
  background:
    radial-gradient(circle at 16% 18%, rgba(143, 215, 234, 0.3), transparent 28%),
    radial-gradient(circle at 82% 18%, rgba(79, 181, 155, 0.18), transparent 30%),
    linear-gradient(135deg, #1d5876 0%, #2d7895 52%, #245f7d 100%);
  border-bottom: 0;
}
.version-hero-inner {
  max-width: 1200px;
  margin: 0 auto;
  padding: 34px 40px 32px;
}
.eyebrow,
.section-kicker {
  margin: 0;
  color: #0f7c96;
  font-size: 12.5px;
  font-weight: 800;
  letter-spacing: 0.08em;
  text-transform: uppercase;
}
.version-hero .eyebrow {
  color: #8fd7ea;
}
.version-hero h1 {
  max-width: 720px;
  margin: 12px 0 8px;
  color: #ffffff;
  font-size: clamp(32px, 3vw, 40px);
  font-weight: 850;
  line-height: 1.06;
  letter-spacing: 0;
}
.version-hero p:not(.eyebrow) {
  max-width: 1100px;
  margin: 0;
  color: #d8e7ef;
  font-size: 16px;
  line-height: 1.62;
  font-weight: 600;
  overflow-wrap: break-word;
}
.version-body {
  max-width: 1200px;
  margin: 0 auto;
  padding: 38px 40px 88px;
}
.version-table-wrap {
  width: 100%;
  overflow-x: auto;
  background: #fff;
  border: 1px solid #e3ebef;
  border-radius: 0;
}
.version-table {
  width: 100%;
  min-width: 1040px;
  border-collapse: collapse;
  table-layout: fixed;
}
.version-col {
  width: 150px;
}
.date-col {
  width: 130px;
}
.size-col {
  width: 118px;
}
.notes-col {
  width: auto;
}
.version-table th,
.version-table td {
  padding: 18px 20px;
  border-bottom: 1px solid #e5eaee;
  text-align: left;
  vertical-align: top;
}
.version-table th {
  background: #eef4f7;
  color: #1f2933;
  font-size: 13px;
  font-weight: 800;
  letter-spacing: 0;
  text-transform: uppercase;
}
.version-table td {
  color: #293247;
  font-size: 15px;
  font-weight: 620;
  line-height: 1.5;
}
.version-table tbody tr:last-child td {
  border-bottom: 0;
}
.version-id {
  color: #111827;
  font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace;
  font-weight: 760;
}
.notes-cell {
  color: #536172;
}
.version-note {
  margin: 24px 0 0;
  color: #6f7d8b;
  font-size: 13px;
  font-weight: 650;
  line-height: 1.55;
  text-align: left;
}

@media (max-width: 720px) {
  .version-hero-inner {
    padding: 28px 24px 26px;
  }
  .version-hero h1 {
    font-size: 30px;
  }
  .version-hero p:not(.eyebrow) {
    font-size: 15.5px;
  }
  .version-body {
    padding: 28px 20px 56px;
  }
  .version-table {
    min-width: 1020px;
  }
  .version-table th,
  .version-table td {
    padding: 15px 16px;
  }
}
</style>
