<template>
  <div class="help-page">
    <aside class="help-sidebar" aria-label="Help navigation">
      <div class="sidebar-inner">
        <div class="sidebar-title">
          <span>PhenoMAP Help</span>
          <strong>Tool tutorials</strong>
        </div>
        <p class="sidebar-label">Contents</p>
        <nav>
          <router-link to="/help/get-started" class="tool-link">
            <span class="tool-mark neutral"></span>
            <span>Get Started</span>
          </router-link>
          <router-link v-for="tool in tools" :key="tool.id" :to="`/help/${tool.id}`" class="tool-link">
            <span class="tool-mark" :style="{ background: tool.color }"></span>
            <span>{{ tool.title }}</span>
          </router-link>
        </nav>
      </div>
    </aside>

    <main class="help-content">
      <section v-if="activeTopic === 'get-started'" id="get-started" class="get-started">
        <div class="section-heading">
          <h2>Get Started</h2>
        </div>
        <p class="intro-copy">
          Welcome to the PhenoMAP tool tutorials!
        </p>
        <p class="intro-copy">
          This Help section explains how to use the four analysis tools in PhenoMAP:
          Entity Search, Path Query, Module Enrichment, and the PhenoMAP Chat.
          Each tutorial focuses on what the tool is for, what inputs it expects,
          and how to read the main outputs.
        </p>
        <p class="intro-copy">
          The tutorials follow one worked example, purine metabolism and its link between gout and anemia of
          chronic renal failure, so you can repeat each step yourself. Numbered red markers in the text match the
          numbered callouts in the screenshots.
        </p>
        <p class="intro-copy">
          You can open a tool from the <span class="inline-chip">Analysis menu</span>
          in the top navigation bar, or from the matching
          <span class="inline-chip">Analysis Tool</span> on the home page. Use the
          directory on the left to switch between tutorial pages.
        </p>
        <p v-if="authState.enabled" class="intro-copy">
          The analysis tools require a free PhenoMAP account. Use
          <span class="inline-chip">Sign In</span> in the top-right corner to sign in or create one; the
          verification email is sent from featuremap@163.com.
        </p>
        <p class="intro-copy">
          PhenoMAP Chat runs on your own SiliconFlow or OpenAI API key, which you enter in its model settings.
          The other three tools need no key.
        </p>
        <p class="intro-copy">
          To reuse the graph outside the website, the <span class="inline-chip">Download</span> page provides the
          graph tables<template v-if="authState.enabled">, and the <span class="inline-chip">Community</span> page
          lets you submit your own study for inclusion in a future release</template>.
        </p>
        <p class="intro-copy">
          Now you are ready to start your analysis!
        </p>
      </section>

      <section v-else-if="activeTool" :id="activeTool.id" class="tutorial-section">
        <div class="section-heading">
          <h2>{{ activeTool.title }}</h2>
        </div>

        <div v-if="activeTool.sections" class="tutorial-article">
          <div v-for="section in activeTool.sections" :key="section.heading" class="article-block">
            <div class="article-copy">
              <span class="article-step" v-if="section.step">{{ section.step }}</span>
              <h3>
                {{ section.heading }}
                <span v-for="m in section.markers || []" :key="m" class="shot-marker" :aria-label="`Screenshot marker ${m}`">{{ m }}</span>
              </h3>
              <p><template v-for="part in renderParts(section.body)" :key="part.key"><a v-if="part.href" :href="part.href" target="_blank" rel="noreferrer">{{ part.text }}</a><template v-else>{{ part.text }}</template></template></p>
              <ul v-if="section.points?.length">
                <li v-for="(point, i) in section.points" :key="i"><template v-for="part in renderParts(point)" :key="part.key"><a v-if="part.href" :href="part.href" target="_blank" rel="noreferrer">{{ part.text }}</a><template v-else>{{ part.text }}</template></template></li>
              </ul>
            </div>
            <figure
              v-if="section.image && !failedImages.has(section.image)"
              class="screenshot-shot"
            >
              <img
                :src="section.image"
                :alt="section.visual || section.heading"
                loading="lazy"
                @error="failedImages.add(section.image)"
              />
              <figcaption v-if="section.caption">{{ section.caption }}</figcaption>
            </figure>
            <div v-else-if="section.visual" class="screenshot-slot">
              <div class="slot-topbar">
                <span></span>
                <span></span>
                <span></span>
              </div>
              <div class="slot-body">
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8">
                  <rect x="3" y="5" width="18" height="14" rx="2" />
                  <path d="m7 14 3-3 2.5 2.5L15 11l2 3" />
                  <circle cx="8" cy="9" r="1" />
                </svg>
                <span>{{ section.visual }}</span>
              </div>
            </div>
          </div>
        </div>

        <div v-else class="tutorial-layout">
          <div class="tutorial-main">
            <h3>Workflow</h3>
            <ol class="step-list">
              <li v-for="step in activeTool.steps" :key="step">
                <span>{{ step }}</span>
              </li>
            </ol>
          </div>

          <div class="tutorial-notes">
            <h3>Content to add</h3>
            <ul>
              <li v-for="note in activeTool.notes" :key="note">{{ note }}</li>
            </ul>
          </div>
        </div>
      </section>

      <nav class="topic-pager" aria-label="Help page navigation">
        <router-link v-if="prevTopic" :to="prevTopic.to" class="pager-link pager-prev">
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8">
            <path d="M15 6 9 12l6 6" />
          </svg>
          <span>
            <small>Previous</small>
            {{ prevTopic.title }}
          </span>
        </router-link>
        <span v-else class="pager-spacer"></span>

        <router-link v-if="nextTopic" :to="nextTopic.to" class="pager-link pager-next">
          <span>
            <small>Next</small>
            {{ nextTopic.title }}
          </span>
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8">
            <path d="m9 6 6 6-6 6" />
          </svg>
        </router-link>
        <span v-else class="pager-spacer"></span>
      </nav>
    </main>
  </div>
</template>

<script setup>
import { computed, ref } from 'vue'
import { useRoute } from 'vue-router'
import { authState } from '../auth.js'

const route = useRoute()

// A tutorial section shows its real screenshot when one is present under
// frontend/public/help/. Until that file exists the dev server answers with
// the SPA index.html, which fails to decode as an image -- so a failed load
// falls back to the placeholder box instead of a broken-image icon, and the
// page looks finished either way.
const failedImages = ref(new Set())

function renderParts(value) {
  if (!Array.isArray(value)) return [{ key: 'text-0', text: value }]
  return value.map((part, index) => (typeof part === 'string' ? { key: `text-${index}`, text: part } : { key: `link-${index}`, ...part }))
}

// The four screenshots under frontend/public/help/ follow one worked example
// (purine metabolism, the same example used in the PhenoMAP paper) and carry
// numbered red callouts 1-10. `markers` on a section puts the matching
// number next to its heading so the text and the picture line up.
const tools = [
  {
    id: 'entity-search',
    title: 'Entity Search',
    kicker: 'Find and inspect graph entities',
    color: '#0f7c96',
    sections: [
      {
        step: '01',
        heading: 'What Entity Search is for',
        body: 'Entity Search is the main way to find one record in the PhenoMAP graph and open its detail page. Use it when you know a study accession, phenotype name, module title, metabolite name, database ID, or PhenoMAP ID and want to inspect the matched entity. The example below searches for purine-related modules and opens one of them.',
        image: '/help/entity-search-results.png',
        caption: 'Worked example: searching Module records for "purine" (1), the result table (2), and a module detail page (3).',
      },
      {
        step: '02',
        heading: 'Choose the entity type and type a query',
        markers: ['1'],
        body: 'Select Module, Study, Phenotype, or Metabolite above the search box, then type at least two characters. Search only looks inside the selected type. Names and titles use prefix-style full-text search, so partial multi-word queries can work; ID fields use contains matching, and ID matches are listed before name or title matches.',
        points: [
          'Study searches Title, Accession, and PhenoMAP ID.',
          'Phenotype searches Phenotype, OLS ID, and PhenoMAP ID.',
          'Module searches title and PhenoMAP ID.',
          'Metabolite searches Metabolite_Name, HMDB ID, KEGG ID, InChI, and PhenoMAP ID.',
          'If you see No matches, check the type first: a metabolite name, for example, returns nothing while Module is selected.',
        ],
      },
      {
        step: '03',
        heading: 'Browse the results',
        markers: ['2'],
        body: 'Results appear as a table with the entity type, PhenoMAP ID, title, and one or two type-specific columns, such as Accession, Hypothesis Type, OLS ID, HMDB ID, or KEGG ID. The line above the table reports how many records matched (276 for "purine" in the example), and the pager at the bottom moves through the pages or jumps to a page number.',
        points: [
          'An empty query lists every record of the selected type, sorted by PhenoMAP ID.',
          'Hover the (i) icon next to a column header for a short definition.',
          'You can also start from the search box on the home page; it opens this page with the same type and query.',
        ],
      },
      {
        step: '04',
        heading: 'Open a record',
        markers: ['3'],
        body: 'Click a row to open its detail page. A module page shows its type badge and hypothesis type, its PhenoMAP ID, a functional summary, and a network of its member metabolites colored as Anchor, Supporting, or Contextual. The On this page menu jumps to Class Coverage, Pathway Coverage, Metabolite Origin, Phenotype Relationship, Metabolite Membership, and Connections. Study, phenotype, and metabolite pages follow the same layout with their own sections.',
        points: [
          'Back to Entity Search returns to the same query and page.',
          'Records listed in a section are links, so you can keep walking through the graph from here.',
        ],
      },
    ],
  },
  {
    id: 'path-query',
    title: 'Path Query',
    kicker: 'Trace connections between two entities',
    color: '#1a8f5e',
    sections: [
      {
        step: '01',
        heading: 'What Path Query is for',
        body: 'Path Query shows how two records are connected in the PhenoMAP graph. It always returns the shortest connection, so there is nothing to configure beyond the two endpoints. It is best for tracing phenotype-to-phenotype, phenotype-to-module, or study-to-module routes. The example below asks how gout and anemia of chronic renal failure are connected.',
        image: '/help/path-query-graph.png',
        caption: 'Worked example: Gout to Anemia of chronic renal failure (4), and the resulting shortest connection (5).',
      },
      {
        step: '02',
        heading: 'Choose the two endpoints',
        markers: ['4'],
        body: 'In From and To, select the record type (Module, Study, or Phenotype) and search for the record by name, title, accession, or PhenoMAP ID, then pick it from the list. The example buttons #1 to #5 fill in ready-made pairs. Select Find connections to run the query.',
        points: [
          'Metabolites cannot be endpoints; Path Query leaves them out to keep the graph readable. To explore a metabolite, open its detail page from Entity Search.',
        ],
      },
      {
        step: '03',
        heading: 'Read the visualization',
        markers: ['5'],
        body: 'The header reports the length of the shortest connection, and the Visualization tab draws every shortest route between the two endpoints. Node colors show the entity type (Study, Phenotype, Module). In the example, the 5-hop route runs Gout → study → module → similar module → study → Anemia of chronic renal failure; one of the bridges is a Purine catabolism module from the gout study that is similar to a Purine metabolism module from the renal-failure study.',
        points: [
          'Two phenotypes are usually five hops apart, because the shortest route between them passes through their studies and two similar modules.',
          'Hover a node or edge to see its label and relationship type; click a node to open its detail page.',
        ],
      },
      {
        step: '04',
        heading: 'List the connections',
        body: 'The Connections tab lists the same routes one per row (11 in the example), in order from the source to the target with their relationship labels. Use it when the network is dense or when you want to read each route exactly.',
      },
      {
        step: '05',
        heading: 'When results look unexpected',
        body: 'No connection means the two records really have no route through the study, phenotype, and module backbone; try endpoints that are more closely related. If the result is marked as truncated, there are more equally short routes than the page draws, so the picture is a representative sample; the reported hop count is still exact.',
      },
    ],
  },
  {
    id: 'module-enrichment',
    title: 'Module Enrichment',
    kicker: 'Test metabolite lists against modules',
    color: '#b3562c',
    sections: [
      {
        step: '01',
        heading: 'What Module Enrichment is for',
        body: 'Module Enrichment tests whether a metabolite list overlaps PhenoMAP modules more than expected by chance. Use it for metabolite lists obtained outside FeatureMAP, such as differential metabolites from an annotated untargeted dataset or a targeted assay, without reanalyzing feature-level data. The example below tests a list of KEGG IDs against high-confidence Host-Endogenous modules.',
        image: '/help/enrichment-results.png',
        caption: 'Worked example: KEGG IDs (6), the settings (7), and the enrichment overview (8).',
      },
      {
        step: '02',
        heading: 'Paste your metabolite IDs',
        markers: ['6'],
        body: 'Paste your IDs into Metabolite IDs, one per line or separated by commas, spaces, or semicolons. The example buttons #1 to #4 fill in sample lists if you want to try the workflow first.',
      },
      {
        step: '03',
        heading: 'Choose the settings',
        markers: ['7'],
        body: 'Set the options in the panel below the ID box, then select Run.',
        points: [
          'ID type must match what you pasted: Lab ID (e.g. PME002024), HMDB (e.g. HMDB0000122), KEGG (e.g. C00219), or InChI.',
          'Module confidence (high, medium, low) and Module type (Host-Endogenous, Xenobiotic / Exogenous, Diet-Derived, Microbiome-Derived, Host–Microbiome) choose which modules are tested. Both start with everything selected, which tests all 12,929 modules; the line under the panel shows how many modules the current choice tests (1,090 in the example).',
          'Significance basis chooses whether FDR or the raw p-value decides significance, and the cutoff next to it sets the threshold.',
          'Min overlap drops modules that share too few metabolites with your list.',
        ],
      },
      {
        step: '04',
        heading: 'How the test works',
        body: 'Each module is represented by its core and supporting metabolites, and the background is rebuilt from the modules you selected, so the null model always matches what is being tested. Significance comes from a one-sided hypergeometric test (equivalent to a one-sided Fisher’s exact test) with Benjamini-Hochberg correction. FDR and p-value are both returned for every module, so changing the significance basis, cutoff, or minimum overlap after a run updates the results instantly without re-running the test.',
      },
      {
        step: '05',
        heading: 'Read the enrichment overview',
        markers: ['8'],
        body: 'In the Visualization tab, each point is one module. The x-axis is log2 of the enrichment ratio, the y-axis is -log10 of the selected significance basis, point size is the number of overlapping metabolites, and green points pass your cutoff. The dashed line marks the cutoff itself.',
        points: [
          'Points farther right are more enriched; points higher up are more significant.',
          'Hover a point to see the module title, overlap, enrichment ratio, and its FDR or p-value; click it to open the module.',
        ],
      },
      {
        step: '06',
        heading: 'Review and export the significant modules',
        body: 'The Significant modules tab lists the modules that pass the current settings (35 in the example), with their overlapping metabolites, enrichment ratio, p-value, and FDR. Export CSV downloads that list.',
        points: [
          'The panel above the tabs lists input IDs that did not match any module metabolite (10 in the example). A long list usually means the wrong ID type is selected.',
        ],
      },
    ],
  },
  {
    id: 'phenomap-chat',
    title: 'PhenoMAP Chat',
    kicker: 'Ask guided questions about the graph',
    color: '#3949ab',
    sections: [
      {
        step: '01',
        heading: 'What PhenoMAP Chat is for',
        body: 'PhenoMAP Chat answers natural-language questions about PhenoMAP data. Behind the scenes it calls the same functions as the website (entity search, record details, path query, and module enrichment) and writes its answer only from the records those calls return. The example below asks the gout and renal-failure question from the Path Query tutorial in plain language.',
        image: '/help/chat-answer.png',
        caption: 'Worked example: a question (9) and the answer with its cited records (10).',
      },
      {
        step: '02',
        heading: 'Set up your model',
        body: 'Open the model settings from the bottom of the chat sidebar, choose SiliconFlow (the default) or ChatGPT API, enter your own API key, and select Save Changes before sending a message.',
        points: [
          'The model name is optional. Leave it blank to use the default (Qwen/Qwen2.5-72B-Instruct on SiliconFlow, gpt-5.4 on ChatGPT API), or enter any model from the provider’s list that supports tool calling.',
          'SiliconFlow keys from either siliconflow.cn or siliconflow.com work; PhenoMAP detects which site the key belongs to.',
          'Your key is kept only in this browser tab and is cleared when the tab is closed. PhenoMAP does not store it.',
        ],
      },
      {
        step: '03',
        heading: 'Ask a focused question',
        markers: ['9'],
        body: 'Type your question and send it. The best questions name the phenotype, study, module, metabolite, or ID you care about and the kind of answer you want, such as related modules, member metabolites, supporting studies, a connection, or an enrichment result.',
        points: [
          '“Which Host-Endogenous metabolic modules connect Gout and Anemia of chronic renal failure in PhenoMAP?”',
          '“Which modules are associated with acute myeloid leukemia?”',
          '“Where does HMDB0000289 appear in PhenoMAP?”',
        ],
      },
      {
        step: '04',
        heading: 'Check the cited records',
        markers: ['10'],
        body: 'The answer streams in as it is written. Each phenotype, study, module, or metabolite it mentions is followed by a link icon to that record, so every statement can be checked. In the example, the answer finds the same purine bridge as Path Query: Purine catabolism on the gout side and Purine metabolism on the renal-failure side. Open the cited records before using an answer in a report or figure.',
        points: [
          'The Evidence panel under an answer shows which PhenoMAP functions were called.',
          'Use the stop button to cancel a long answer, and the copy button to copy one.',
          'Ask a follow-up if an answer is too broad or misses the entity type you need.',
        ],
      },
      {
        step: '05',
        heading: 'Manage your chats',
        body: 'Use New chat to start a separate conversation and pick earlier chats from the sidebar. Chats are saved in this browser only, and you can delete old ones from the sidebar. Keep unrelated questions in separate chats.',
      },
    ],
  },
]

const topicAliases = { 'phenomap-chatbot': 'phenomap-chat' }
const validTopics = new Set(['get-started', ...tools.map((tool) => tool.id), ...Object.keys(topicAliases)])
const topicOrder = [
  { id: 'get-started', title: 'Get Started', to: '/help/get-started' },
  ...tools.map((tool) => ({ id: tool.id, title: tool.title, to: `/help/${tool.id}` })),
]
const activeTopic = computed(() => {
  const topic = typeof route.params.topic === 'string' ? route.params.topic : 'get-started'
  return validTopics.has(topic) ? topicAliases[topic] || topic : 'get-started'
})
const activeTool = computed(() => tools.find((tool) => tool.id === activeTopic.value) || null)
const activeTopicIndex = computed(() => topicOrder.findIndex((topic) => topic.id === activeTopic.value))
const prevTopic = computed(() => (activeTopicIndex.value > 0 ? topicOrder[activeTopicIndex.value - 1] : null))
const nextTopic = computed(() =>
  activeTopicIndex.value >= 0 && activeTopicIndex.value < topicOrder.length - 1 ? topicOrder[activeTopicIndex.value + 1] : null
)
</script>

<style scoped>
.help-page {
  display: grid;
  grid-template-columns: 188px minmax(0, 1fr);
  gap: 36px;
  max-width: 1280px;
  margin: 0 auto;
  padding: 56px 32px 88px;
}

.help-sidebar {
  border-right: 1px solid #edf1f5;
}
.sidebar-inner {
  position: sticky;
  top: 96px;
  padding-right: 16px;
}
.sidebar-title {
  padding-bottom: 22px;
  margin-bottom: 18px;
  border-bottom: 1px solid #edf1f5;
}
.sidebar-title span {
  display: block;
  margin-bottom: 8px;
  color: #0f7c96;
  font-size: 11px;
  font-weight: 800;
  letter-spacing: 0.09em;
  text-transform: uppercase;
}
.sidebar-title strong {
  display: block;
  color: #172033;
  font-size: 24px;
  line-height: 1.08;
  letter-spacing: -0.01em;
}
.sidebar-label {
  margin: 0 0 10px;
  font-size: 12px;
  font-weight: 800;
  letter-spacing: 0.09em;
  text-transform: uppercase;
  color: #7a8794;
}
.tool-link {
  display: flex;
  align-items: center;
  gap: 8px;
  min-height: 34px;
  color: #34404c;
  font-size: 13.5px;
  font-weight: 650;
  text-decoration: none;
  border-radius: 7px;
  padding: 0 8px;
}
.tool-link:hover {
  background: #eef7fa;
  color: #0f7c96;
}
.tool-link.router-link-active {
  background: #eef7fa;
  color: #0f7c96;
  font-weight: 800;
}
.tool-mark {
  width: 6px;
  height: 6px;
  border-radius: 50%;
  flex-shrink: 0;
}
.tool-mark.neutral {
  background: #98a6b3;
}

.help-content {
  min-width: 0;
}
.topic-pager {
  max-width: 860px;
  display: flex;
  align-items: stretch;
  justify-content: space-between;
  gap: 14px;
  margin-top: 22px;
  padding-top: 22px;
  border-top: 1px solid #e4e9ef;
}
.pager-link,
.pager-spacer {
  min-width: 0;
  min-height: 46px;
  flex: 1 1 0;
}
.pager-link {
  display: inline-flex;
  align-items: center;
  gap: 10px;
  padding: 8px 12px;
  border: 1px solid #dce5ea;
  border-radius: 8px;
  background: #fff;
  color: #34404c;
  text-decoration: none;
  transition: border-color 0.15s ease, background 0.15s ease, color 0.15s ease;
}
.pager-link:hover {
  border-color: #bcd4dd;
  background: #f6fbfc;
  color: #0f7c96;
}
.pager-link svg {
  width: 18px;
  height: 18px;
  flex: 0 0 auto;
}
.pager-link span {
  min-width: 0;
  display: grid;
  gap: 2px;
  font-size: 13.5px;
  font-weight: 750;
  line-height: 1.2;
}
.pager-link small {
  color: #8a98a6;
  font-size: 10.5px;
  font-weight: 800;
  letter-spacing: 0.08em;
  text-transform: uppercase;
}
.pager-next {
  justify-content: flex-end;
  text-align: right;
}
.get-started {
  scroll-margin-top: 88px;
  max-width: 860px;
  padding: 0 0 46px;
}
.get-started .intro-copy {
  margin: -8px 0 0;
  max-width: 860px;
  color: #586675;
  font-size: 16.5px;
  font-weight: 500;
  line-height: 1.72;
}
.get-started .intro-copy:first-of-type {
  color: #25313f;
  font-size: 18px;
  font-weight: 700;
}
.get-started .intro-copy + .intro-copy {
  margin-top: 12px;
}
.inline-chip {
  display: inline-flex;
  align-items: center;
  padding: 2px 8px;
  border: 1px solid #cfe1e8;
  border-radius: 6px;
  background: #f6fbfc;
  color: #0f7c96;
  font-weight: 750;
  line-height: 1.35;
}

.tutorial-section {
  scroll-margin-top: 88px;
  padding: 0 0 46px;
}
.section-heading {
  margin-bottom: 26px;
}
.section-heading h2 {
  margin: 0;
  color: #172033;
  font-size: 30px;
  line-height: 1.18;
}
.tutorial-layout {
  display: grid;
  grid-template-columns: minmax(0, 1.45fr) minmax(260px, 0.75fr);
  gap: 34px;
}
.tutorial-main,
.tutorial-notes {
  background: #fff;
  border: 1px solid #e4e9ef;
  border-radius: 8px;
  padding: 24px;
}
.tutorial-article {
  max-width: 860px;
  padding: 0;
}
.article-block {
  padding: 0;
}
.article-block + .article-block {
  margin-top: 38px;
}
.article-copy {
  min-width: 0;
  max-width: 860px;
}
.article-step {
  display: inline-block;
  margin-bottom: 8px;
  color: #0f7c96;
  font-size: 12px;
  font-weight: 800;
  letter-spacing: 0.08em;
  text-transform: uppercase;
}
.article-block h3 {
  margin: 0 0 12px;
  color: #25313f;
  font-size: 21px;
  line-height: 1.28;
}
.article-block p {
  margin: 0;
  color: #44515e;
  font-size: 16.5px;
  line-height: 1.72;
}
.article-block ul {
  margin: 14px 0 0;
  padding-left: 20px;
  color: #4f5d69;
  font-size: 15.5px;
  line-height: 1.65;
}
.article-block li + li {
  margin-top: 8px;
}
.article-block p a,
.article-block li a {
  color: #0f7c96;
  font-weight: 750;
  text-decoration: underline;
  text-decoration-color: rgba(15, 124, 150, 0.32);
  text-underline-offset: 4px;
}
.article-block p a:hover,
.article-block li a:hover {
  color: #245c7e;
  text-decoration-color: rgba(36, 92, 126, 0.72);
}
.screenshot-slot {
  width: min(100%, 620px);
  min-height: 160px;
  margin: 20px auto 0;
}
.screenshot-shot {
  width: min(100%, 760px);
  margin: 22px auto 0;
}
.screenshot-shot figcaption {
  margin-top: 10px;
  color: #667085;
  font-size: 13.5px;
  line-height: 1.55;
  text-align: center;
}
/* Same look as the numbered red callouts drawn on the screenshots. */
.shot-marker {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  width: 24px;
  height: 24px;
  margin-left: 8px;
  border: 2px solid #e0262f;
  border-radius: 50%;
  color: #e0262f;
  font-size: 13px;
  font-weight: 800;
  line-height: 1;
  vertical-align: 3px;
}
.screenshot-shot img {
  display: block;
  width: 100%;
  height: auto;
  border: 1px solid #e3e8ef;
  border-radius: 10px;
  box-shadow: 0 14px 34px -26px rgba(4, 7, 20, 0.7);
}
.slot-topbar {
  display: none;
}
.slot-body {
  min-height: 160px;
  display: flex;
  flex-direction: column;
  align-items: center;
  justify-content: center;
  gap: 12px;
  padding: 18px;
  text-align: center;
  color: #6e7f8b;
  font-size: 13px;
  line-height: 1.45;
}
.slot-body svg {
  width: 36px;
  height: 36px;
  color: #0f7c96;
  opacity: 0.72;
}
.tutorial-main h3,
.tutorial-notes h3 {
  margin: 0 0 18px;
  color: #25313f;
  font-size: 16px;
}
.step-list {
  margin: 0;
  padding: 0;
  list-style: none;
  counter-reset: steps;
}
.step-list li {
  counter-increment: steps;
  display: grid;
  grid-template-columns: 32px minmax(0, 1fr);
  gap: 12px;
  align-items: start;
  color: #44515e;
  line-height: 1.55;
}
.step-list li + li {
  margin-top: 16px;
}
.step-list li::before {
  content: counter(steps);
  width: 32px;
  height: 32px;
  border-radius: 50%;
  background: #edf7fa;
  color: #0f7c96;
  display: inline-flex;
  align-items: center;
  justify-content: center;
  font-weight: 800;
}
.tutorial-notes ul {
  margin: 0;
  padding-left: 18px;
  color: #5d6976;
  line-height: 1.55;
}
.tutorial-notes li + li {
  margin-top: 10px;
}

@media (max-width: 900px) {
  .help-page {
    grid-template-columns: 1fr;
    gap: 28px;
    padding: 36px 22px 72px;
  }
  .help-sidebar {
    border-right: 0;
    border-bottom: 1px solid #e2e8ee;
  }
  .sidebar-inner {
    position: static;
    padding: 0 0 18px;
  }
  .sidebar-inner nav {
    display: grid;
    grid-template-columns: repeat(2, minmax(0, 1fr));
    gap: 6px;
  }
  .help-header h1 {
    font-size: 34px;
  }
  .tutorial-layout {
    grid-template-columns: 1fr;
  }
  .topic-pager {
    max-width: none;
    flex-direction: column;
  }
  .pager-spacer {
    display: none;
  }
  .pager-next {
    text-align: left;
    justify-content: space-between;
  }
  .get-started .intro-copy {
    margin-left: 0;
  }
  .article-block {
    grid-template-columns: 1fr;
    padding: 24px;
  }
}
</style>
