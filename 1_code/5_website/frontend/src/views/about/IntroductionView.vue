<template>
  <div class="introduction-page">
    <section class="introduction-hero">
      <div class="introduction-hero-inner">
        <nav class="about-page-nav" aria-label="About page navigation">
          <router-link to="/about/contact" class="eyebrow about-prev-link" aria-label="Previous About page: Contact">
            <svg class="about-prev-arrow" viewBox="0 0 24 24" aria-hidden="true">
              <path d="M19 12H5" />
              <path d="m11 6-6 6 6 6" />
            </svg>
          </router-link>
          <span class="eyebrow about-current-page">Introduction</span>
          <router-link to="/about/authors" class="eyebrow about-next-link" aria-label="Next About page: Authors">
            <svg class="about-next-arrow" viewBox="0 0 24 24" aria-hidden="true">
              <path d="M5 12h14" />
              <path d="m13 6 6 6-6 6" />
            </svg>
          </router-link>
        </nav>
        <h1>About PhenoMAP</h1>
        <p>{{ facts.introduction.hero_tagline }}</p>
      </div>
    </section>

    <section class="introduction-body">
      <div class="introduction-layout">
        <section class="overview-panel" aria-label="Overview">
          <p class="section-kicker">Overview</p>
          <h2>{{ facts.introduction.overview_heading }}</h2>
          <p v-for="(para, i) in facts.introduction.overview_paragraphs" :key="i">{{ para }}</p>
        </section>

        <aside class="structure-panel" aria-label="Graph structure">
          <p class="section-kicker">Graph Structure</p>
          <dl class="structure-list">
            <div v-for="item in graphStructure" :key="item.label" class="structure-row">
              <dt>{{ item.label }}</dt>
              <dd>{{ item.value }}</dd>
            </div>
          </dl>
        </aside>
      </div>

      <section class="pipeline-section" aria-label="Data flow">
        <div class="section-head">
          <p class="section-kicker">Data Flow</p>
          <h2>From Raw Studies To Web Queries</h2>
        </div>
        <ol class="pipeline-list">
          <li v-for="step in pipelineSteps" :key="step.number">
            <span class="step-number">{{ step.number }}</span>
            <div>
              <h3>{{ step.title }}</h3>
              <p>{{ step.body }}</p>
            </div>
          </li>
        </ol>
      </section>
    </section>
  </div>
</template>

<script setup>
// Single source of truth: this page (and the chat-service's PRODUCT_FACTS,
// via chat-service/product_facts.py) both read from this same file, so the
// PhenoMAP Chat's "how do you work" answers can never drift from what this page
// actually shows. Edit product_facts.json, not the copy below.
import facts from '../../data/product_facts.json'

const graphStructure = facts.introduction.graph_structure
const pipelineSteps = facts.introduction.pipeline_steps
</script>

<style scoped>
.introduction-page {
  min-height: calc(100vh - 69px);
  overflow-x: hidden;
  background: #f7f8fa;
  color: #1b1f24;
}
.introduction-hero {
  background:
    radial-gradient(circle at 16% 18%, rgba(143, 215, 234, 0.3), transparent 28%),
    radial-gradient(circle at 82% 18%, rgba(79, 181, 155, 0.18), transparent 30%),
    linear-gradient(135deg, #1d5876 0%, #2d7895 52%, #245f7d 100%);
  border-bottom: 0;
}
.introduction-hero-inner {
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
.introduction-hero .eyebrow {
  color: #8fd7ea;
}
.introduction-hero h1 {
  max-width: 720px;
  margin: 12px 0 8px;
  color: #ffffff;
  font-size: clamp(32px, 3vw, 40px);
  font-weight: 850;
  line-height: 1.06;
  letter-spacing: 0;
}
.introduction-hero p:not(.eyebrow) {
  max-width: 1100px;
  margin: 0;
  color: #d8e7ef;
  font-size: 16px;
  line-height: 1.62;
  font-weight: 600;
  overflow-wrap: break-word;
}
.introduction-body {
  max-width: 1200px;
  margin: 0 auto;
  padding: 44px 40px 88px;
}
.introduction-layout {
  display: grid;
  grid-template-columns: minmax(0, 1.08fr) minmax(360px, 0.72fr);
  gap: 36px;
  align-items: stretch;
}
.overview-panel,
.structure-panel,
.pipeline-section {
  min-width: 0;
  background: #ffffff;
  border: 1px solid #e3ebef;
  border-top: 3px solid #8fd7ea;
  border-radius: 0;
}
.overview-panel,
.structure-panel {
  padding: 32px;
}
.overview-panel h2 {
  max-width: 660px;
  margin: 12px 0 18px;
  color: #111827;
  font-size: clamp(24px, 2.5vw, 34px);
  font-weight: 850;
  line-height: 1.15;
  letter-spacing: 0;
}
.overview-panel p:not(.section-kicker) {
  max-width: 760px;
  margin: 0;
  color: #667085;
  font-size: 15.5px;
  font-weight: 600;
  line-height: 1.72;
}
.overview-panel p:not(.section-kicker) + p {
  margin-top: 16px;
}
.structure-list {
  display: grid;
  gap: 0;
  margin: 24px 0 0;
  border-top: 1px solid #e3ebef;
}
.structure-row {
  padding: 20px 0;
  border-bottom: 1px solid #e3ebef;
}
.structure-row dt {
  margin: 0 0 8px;
  color: #8292a3;
  font-size: 11.5px;
  font-weight: 800;
  text-transform: uppercase;
}
.structure-row dd {
  margin: 0;
  color: #293247;
  font-size: 15px;
  font-weight: 750;
  line-height: 1.5;
}
.pipeline-section {
  margin-top: 36px;
  padding: 32px;
}
.section-head {
  display: flex;
  align-items: flex-start;
  flex-direction: column;
  gap: 8px;
  margin-bottom: 24px;
  padding-bottom: 16px;
  border-bottom: 1px solid #e3ebef;
}
.section-head h2 {
  margin: 8px 0 0;
  color: #111827;
  font-size: 30px;
  font-weight: 850;
  line-height: 1.12;
  letter-spacing: 0;
}
.pipeline-list {
  display: grid;
  grid-template-columns: repeat(4, minmax(0, 1fr));
  gap: 0;
  margin: 0;
  padding: 0;
  list-style: none;
  border-top: 1px solid #e3ebef;
  border-left: 1px solid #e3ebef;
}
.pipeline-list li {
  min-width: 0;
  padding: 22px;
  border-right: 1px solid #e3ebef;
  border-bottom: 1px solid #e3ebef;
  background: #fbfdfe;
}
.step-number {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  width: 34px;
  height: 34px;
  margin-bottom: 18px;
  border-radius: 50%;
  background: #e9f7f9;
  color: #0f7c96;
  font-size: 12px;
  font-weight: 850;
}
.pipeline-list h3 {
  margin: 0 0 8px;
  color: #111827;
  font-size: 17px;
  font-weight: 850;
  line-height: 1.22;
  letter-spacing: 0;
}
.pipeline-list p {
  margin: 0;
  color: #667085;
  font-size: 14px;
  font-weight: 600;
  line-height: 1.58;
  overflow-wrap: break-word;
}

@media (max-width: 1080px) {
  .pipeline-list {
    grid-template-columns: repeat(2, minmax(0, 1fr));
  }
}

@media (max-width: 980px) {
  .introduction-layout {
    grid-template-columns: 1fr;
  }
}

@media (max-width: 720px) {
  .introduction-hero-inner {
    padding: 28px 24px 26px;
  }
  .introduction-hero h1 {
    font-size: 30px;
  }
  .introduction-hero p:not(.eyebrow) {
    max-width: 330px;
    font-size: 15.5px;
  }
  .introduction-body {
    padding: 28px 20px 56px;
  }
  .overview-panel,
  .structure-panel,
  .pipeline-section {
    padding: 24px 22px;
  }
  .overview-panel h2,
  .section-head h2 {
    font-size: 24px;
  }
  .pipeline-list {
    grid-template-columns: 1fr;
  }
}
</style>
