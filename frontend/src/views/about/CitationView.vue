<template>
  <div class="citation-page">
    <section class="citation-hero">
      <div class="citation-hero-inner">
        <nav class="about-page-nav" aria-label="About page navigation">
          <router-link to="/about/authors" class="eyebrow about-prev-link" aria-label="Previous About page: Authors">
            <svg class="about-prev-arrow" viewBox="0 0 24 24" aria-hidden="true">
              <path d="M19 12H5" />
              <path d="m11 6-6 6 6 6" />
            </svg>
          </router-link>
          <span class="eyebrow about-current-page">Citation</span>
          <router-link to="/about/version" class="eyebrow about-next-link" aria-label="Next About page: Version">
            <svg class="about-next-arrow" viewBox="0 0 24 24" aria-hidden="true">
              <path d="M5 12h14" />
              <path d="m13 6 6 6-6 6" />
            </svg>
          </router-link>
        </nav>
        <h1>Citations</h1>
        <p>{{ facts.citation.intro }}</p>
      </div>
    </section>

    <section class="citation-body">
      <section class="citation-record" aria-label="Manuscript citation">
        <table class="citation-table">
          <tbody>
            <tr>
              <th>Title</th>
              <td class="title-cell">{{ facts.citation.manuscript_title }}</td>
            </tr>
            <tr>
              <th>Authors</th>
              <td>
                <p class="authors">
                  <template v-for="(part, i) in citationAuthorParts" :key="i"
                    ><template v-if="part.type === 'name'"
                      >{{ part.text }}<sup v-if="part.mark === 'equal'">+</sup><sup v-else-if="part.mark === 'corresponding'">*</sup></template
                    ><template v-else>{{ part.text }}</template></template
                  >
                </p>
                <p class="authors-note">
                  <sup>+</sup> Equal contribution · <sup>*</sup> Corresponding author
                </p>
              </td>
            </tr>
            <tr v-for="item in metadata" :key="item.label">
              <th>{{ item.label }}</th>
              <td>{{ item.value }}</td>
            </tr>
          </tbody>
        </table>
      </section>
      <p class="citation-note">* {{ facts.citation.note }}</p>
    </section>
  </div>
</template>

<script setup>
// Single source of truth: see product_facts.json's _comment.
import facts from '../../data/product_facts.json'

const citationAuthors = facts.citation.authors
const metadata = facts.citation.metadata

// Flattened into {type:'name'|'sep', ...} parts once here so the template
// only has to render, not also work out comma/"and" placement inline.
const citationAuthorParts = citationAuthors.flatMap((a, i) => {
  const parts = [{ type: 'name', text: a.name, mark: a.mark }]
  if (i < citationAuthors.length - 1) {
    parts.push({ type: 'sep', text: i === citationAuthors.length - 2 ? ', and ' : ', ' })
  }
  return parts
})
</script>

<style scoped>
.citation-page {
  min-height: calc(100vh - 69px);
  overflow-x: hidden;
  background: #f7f8fa;
  color: #1b1f24;
}
.citation-hero {
  background:
    radial-gradient(circle at 16% 18%, rgba(143, 215, 234, 0.3), transparent 28%),
    radial-gradient(circle at 82% 18%, rgba(79, 181, 155, 0.18), transparent 30%),
    linear-gradient(135deg, #1d5876 0%, #2d7895 52%, #245f7d 100%);
  border-bottom: 0;
}
.citation-hero-inner {
  max-width: none;
  margin: 0 auto;
  padding: 34px 40px 32px;
  width: min(90vw, 1680px);
  box-sizing: border-box;
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
.citation-hero .eyebrow {
  color: #8fd7ea;
}
.citation-hero h1 {
  max-width: 720px;
  margin: 12px 0 8px;
  color: #ffffff;
  font-size: clamp(32px, 3vw, 40px);
  font-weight: 850;
  line-height: 1.06;
  letter-spacing: 0;
}
.citation-hero p:not(.eyebrow) {
  max-width: 1100px;
  margin: 0;
  color: #d8e7ef;
  font-size: 16px;
  line-height: 1.62;
  font-weight: 600;
  overflow-wrap: break-word;
}
.citation-body {
  max-width: none;
  margin: 0 auto;
  padding: 38px 40px 88px;
  width: min(90vw, 1680px);
  box-sizing: border-box;
}
.citation-record {
  background: #fff;
  border: 1px solid #e3ebef;
  border-radius: 0;
}
.citation-table {
  width: 100%;
  border-collapse: collapse;
  table-layout: fixed;
}
.citation-table th,
.citation-table td {
  padding: 20px 24px;
  border-bottom: 1px solid #e5eaee;
  vertical-align: top;
  text-align: left;
}
.citation-table tr:last-child th,
.citation-table tr:last-child td {
  border-bottom: 0;
}
.citation-table th {
  width: 170px;
  background: #eef4f7;
  color: #1f2933;
  font-size: 13px;
  font-weight: 800;
  letter-spacing: 0;
  text-transform: uppercase;
}
.citation-table td {
  color: #293247;
  font-size: 15px;
  font-weight: 620;
  line-height: 1.55;
}
.title-cell {
  color: #111827;
  font-size: 22px;
  font-weight: 780;
  line-height: 1.32;
  overflow-wrap: break-word;
}
.authors {
  margin: 0;
  color: #293247;
  font-size: 15px;
  font-weight: 600;
  line-height: 1.65;
  overflow-wrap: break-word;
}
.authors sup {
  color: #536172;
  font-weight: 800;
}
.authors-note {
  margin: 10px 0 0;
  color: #6f7d8b;
  font-size: 13px;
  font-weight: 700;
}
.authors-note sup {
  color: #6f7d8b;
}
.citation-note {
  margin: 24px 0 0;
  color: #6f7d8b;
  font-size: 13px;
  font-weight: 650;
  line-height: 1.55;
  text-align: left;
}
@media (max-width: 720px) {
  .citation-hero-inner {
    padding: 28px 24px 26px;
  }
  .citation-hero h1 {
    font-size: 30px;
  }
  .citation-hero p:not(.eyebrow) {
    max-width: 330px;
    font-size: 15.5px;
  }
  .citation-body {
    padding: 28px 20px 56px;
  }
  .citation-table,
  .citation-table tbody,
  .citation-table tr,
  .citation-table th,
  .citation-table td {
    display: block;
    width: 100%;
  }
  .citation-table th {
    padding: 14px 18px 6px;
    border-bottom: 0;
  }
  .citation-table td {
    padding: 0 18px 16px;
  }
  .title-cell {
    font-size: 20px;
  }
  .authors {
    font-size: 14px;
  }
}
</style>
