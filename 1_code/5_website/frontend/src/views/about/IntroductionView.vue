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

    <main class="about-shell">
      <aside class="about-toc" aria-label="About introduction contents">
        <p>Contents</p>
        <a href="#overview">Resource Overview</a>
        <a href="#scope">Release Content</a>
        <a href="#graph-model">Knowledge Graph</a>
        <a href="#construction">Data Assembly</a>
        <a href="#analysis">Ways to Explore</a>
        <a href="#access">Data Access</a>
      </aside>

      <article class="about-article">
        <section id="overview" class="article-section">
          <p class="section-kicker">Resource Overview</p>
          <h2>A phenotype-centered resource for interpreting metabolomics studies at module scale.</h2>
          <p>
            PhenoMAP organizes public human metabolomics studies into a searchable knowledge graph. Rather than
            treating each study, metabolite, or pathway result as an isolated record, PhenoMAP preserves the
            relationships between phenotypes, studies, dysregulated modules, and the metabolites that define those
            modules.
          </p>
          <p>
            The goal is to support module-level interpretation across studies: users can start from a phenotype,
            a study accession, a metabolite, or a module title, then inspect how the matched entity is connected
            to surrounding evidence in the graph.
          </p>
        </section>

        <section id="scope" class="article-section">
          <p class="section-kicker">Release Content</p>
          <h2>What is included in the current PhenoMAP graph.</h2>
          <p>
            The current development release contains <strong>{{ scopeText }}</strong>. These counts describe the
            public graph currently served by the PhenoMAP web interface and will be updated as additional studies
            and reviewed submissions are incorporated.
          </p>
        </section>

        <section id="graph-model" class="article-section">
          <p class="section-kicker">Knowledge Graph</p>
          <h2>How phenotype context is connected to studies, modules, and metabolites.</h2>
          <p>
            The graph centers on four entity types. Phenotypes provide the biological or disease context, studies
            provide the experimental source, modules summarize coordinated metabolic dysregulation, and metabolites
            provide the molecular membership layer.
          </p>
          <figure class="schema-figure">
            <img src="/phenomap.png" alt="PhenoMAP knowledge graph schema" />
            <figcaption>
              The schema links studies to normalized phenotypes, modules to the studies in which they were identified,
              and metabolites to their corresponding modules. Similarity relationships connect modules with related
              metabolic composition or interpretation.
            </figcaption>
          </figure>
        </section>

        <section id="construction" class="article-section">
          <p class="section-kicker">Data Assembly</p>
          <h2>How study metadata and module outputs become graph evidence.</h2>
          <p>
            PhenoMAP combines standardized metabolomics study metadata with FeatureMAP-derived module outputs.
            Study-level information is normalized into graph entities, while module and metabolite tables preserve
            the links needed to trace each module back to the study and phenotype context in which it was observed.
          </p>
          <dl class="definition-list">
            <div>
              <dt>Study metadata</dt>
              <dd>Study design, biospecimen, sample size, phenotype label, source accession, and publication context.</dd>
            </div>
            <div>
              <dt>Module evidence</dt>
              <dd>Dysregulated metabolic modules derived from FeatureMAP outputs and connected to their study source.</dd>
            </div>
            <div>
              <dt>Metabolite membership</dt>
              <dd>Metabolites linked to modules using compound identifiers and available annotation evidence.</dd>
            </div>
            <div>
              <dt>Cross-study comparison</dt>
              <dd>Similarity edges that help users compare modules across phenotypes and study contexts.</dd>
            </div>
          </dl>
        </section>

        <section id="analysis" class="article-section">
          <p class="section-kicker">Ways to Explore</p>
          <h2>Search, connect, enrich, and ask questions across the graph.</h2>
          <dl class="definition-list">
            <div v-for="workflow in workflows" :key="workflow.title">
              <dt>{{ workflow.title }}</dt>
              <dd>{{ workflow.body }}</dd>
            </div>
          </dl>
        </section>

        <section id="access" class="article-section">
          <p class="section-kicker">Data Access</p>
          <h2>Built for interactive exploration and reusable graph tables.</h2>
          <p>
            PhenoMAP can be explored through the website, queried through analysis pages, and downloaded as flat
            graph tables for reuse. The web application is backed by a Neo4j graph database and a Go API for entity
            search, relationship retrieval, path queries, and enrichment workflows.
          </p>
        </section>
      </article>
    </main>
  </div>
</template>

<script setup>
import facts from '../../data/product_facts.json'

const scopeText = facts.version.graph_scope
  .map((item) => `${item.value} ${item.label.toLowerCase()}`)
  .join(', ')

const workflows = [
  {
    title: 'Entity Search',
    body: 'Search phenotypes, studies, modules, and metabolites, then inspect the selected graph record and its evidence.',
  },
  {
    title: 'Path Query',
    body: 'Find graph paths between two selected entities and use the returned relationships to trace biological context.',
  },
  {
    title: 'Module Enrichment',
    body: 'Submit metabolite identifiers and test which PhenoMAP modules are enriched for the submitted list.',
  },
  {
    title: 'PhenoMAP Chat',
    body: 'Ask guided questions that call the same graph tools used by the website and return cited graph records.',
  },
]
</script>

<style scoped>
.introduction-page {
  min-height: calc(100vh - 69px);
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

.introduction-hero-inner,
.about-shell {
  width: min(90vw, 1680px);
  max-width: none;
  margin: 0 auto;
  box-sizing: border-box;
}

.introduction-hero-inner {
  padding: 34px 40px 32px;
}

.eyebrow,
.section-kicker {
  margin: 0;
  color: #0f7c96;
  font-size: 12px;
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
}

.about-shell {
  display: grid;
  grid-template-columns: 220px minmax(0, 1120px);
  gap: 72px;
  align-items: start;
  padding: 48px 40px 92px;
}

.about-toc {
  position: sticky;
  top: 24px;
  align-self: start;
  display: grid;
  gap: 2px;
  max-height: calc(100vh - 48px);
  overflow-y: auto;
  padding-top: 4px;
  border-top: 1px solid #dfe6ee;
}

.about-toc p {
  margin: 16px 0 10px;
  color: #8a96a8;
  font-size: 11px;
  font-weight: 850;
  letter-spacing: 0.12em;
  text-transform: uppercase;
}

.about-toc a {
  display: block;
  padding: 8px 0;
  color: #4f5d70;
  font-size: 14px;
  font-weight: 750;
  line-height: 1.3;
  text-decoration: none;
}

.about-toc a:hover {
  color: #0f7c96;
}

.about-article {
  width: 100%;
}

.article-section {
  width: 100%;
  padding: 0 0 42px;
  margin: 0 0 42px;
  border-bottom: 1px solid #dfe6ee;
  scroll-margin-top: 24px;
}

.article-section:last-child {
  margin-bottom: 0;
}

.article-section h2 {
  max-width: 900px;
  margin: 10px 0 14px;
  color: #111827;
  font-size: clamp(23px, 2vw, 29px);
  font-weight: 850;
  line-height: 1.22;
  letter-spacing: 0;
}

.article-section p {
  max-width: 900px;
  margin: 0;
  color: #5f6f83;
  font-size: 15.5px;
  font-weight: 600;
  line-height: 1.68;
}

.article-section p + p {
  margin-top: 14px;
}

.article-section strong {
  color: #243247;
  font-weight: 850;
}

.schema-figure {
  max-width: 900px;
  margin: 24px 0 0;
}

.schema-figure img {
  display: block;
  width: 100%;
  height: auto;
  border: 1px solid #e0e6ee;
  background: #ffffff;
}

.schema-figure figcaption {
  margin: 13px 0 0;
  color: #667085;
  font-size: 13.5px;
  font-weight: 600;
  line-height: 1.6;
}

.definition-list {
  display: grid;
  gap: 0;
  max-width: 900px;
  margin: 22px 0 0;
  border-top: 1px solid #dfe6ee;
}

.definition-list div {
  display: grid;
  grid-template-columns: 210px minmax(0, 1fr);
  gap: 32px;
  padding: 17px 0;
  border-bottom: 1px solid #dfe6ee;
}

.definition-list dt {
  margin: 0;
  color: #182033;
  font-size: 15px;
  font-weight: 850;
  line-height: 1.45;
}

.definition-list dd {
  margin: 0;
  color: #667085;
  font-size: 15px;
  font-weight: 600;
  line-height: 1.62;
}

@media (max-width: 1040px) {
  .about-shell {
    grid-template-columns: 1fr;
    gap: 30px;
  }

  .about-toc {
    position: static;
    display: flex;
    flex-wrap: wrap;
    gap: 10px 18px;
    padding-bottom: 18px;
    border-bottom: 1px solid #dfe6ee;
  }

  .about-toc p {
    flex-basis: 100%;
    margin-bottom: 0;
  }
}

@media (max-width: 760px) {
  .introduction-hero-inner {
    padding: 28px 24px 26px;
  }

  .introduction-hero h1 {
    font-size: 30px;
  }

  .about-shell {
    width: 100%;
    padding: 30px 22px 60px;
  }

  .article-section {
    padding-bottom: 32px;
    margin-bottom: 32px;
  }

  .article-section h2 {
    font-size: 23px;
  }

  .article-section p,
  .definition-list dd {
    font-size: 15px;
  }

  .definition-list div {
    grid-template-columns: 1fr;
    gap: 6px;
  }
}
</style>
