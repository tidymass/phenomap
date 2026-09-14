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
          You can open a tool from the <span class="inline-chip">Analysis menu</span>
          in the top navigation bar, or from the matching
          <span class="inline-chip">Analysis Tool</span> on the home page. Use the
          directory on the left to switch between tutorial pages.
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
              <h3>{{ section.heading }}</h3>
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
        body: 'Entity Search is the main way to find one record in the PhenoMAP graph and open its detail page. Use it when you know a study accession, phenotype name, module title, metabolite name, database ID, or PhenoMAP ID and want to inspect the matched entity.',
      },
      {
        step: '02',
        heading: 'Choose the entity type first',
        body: 'Start by selecting the entity type. This tells PhenoMAP which group of records to search and which fields to match. Names and titles use prefix-style full-text search, so partial multi-word queries can work. ID fields use contains matching, and ID matches are shown before ordinary name or title matches.',
        points: [
          'Study searches Title, Accession, and PhenoMAP Lab_ID.',
          'Phenotype searches Phenotype, OLS_ID, and PhenoMAP Lab_ID.',
          'Module searches title and PhenoMAP Lab_ID.',
          'Metabolite searches Metabolite_Name, HMDB_ID, KEGG_ID, INCHI_ID, and PhenoMAP Lab_ID.',
        ],
      },
      {
        step: '03',
        heading: 'Run a search from the home page',
        body: 'On the home page, choose the type on the left side of the search box, enter at least two characters, and submit the search. The example links under the search box are shortcuts: clicking one opens the full Entity Search page with that type and query already filled in.',
      },
      {
        step: '04',
        heading: 'Browse and refine results',
        body: 'The Entity Search page shows a paginated table. Each row includes the entity type, PhenoMAP ID, title, and one or two type-specific detail columns, such as Accession, Hypothesis Type, OLS ID, HMDB ID, or KEGG ID.',
        visual: 'Entity Search: the results list with entity-type filtering',
        image: '/help/entity-search-results.png',
        points: [
          'An empty query browses all entities of the selected type.',
          'One-character queries are ignored until more text is entered.',
          'Changing the type resets the result list so the table stays scoped to the selected entity class.',
        ],
      },
      {
        step: '05',
        heading: 'Open an entity detail page',
        body: 'Click a result row to open its detail page. Detail pages show the selected record, important properties, and related records grouped by relationship type. For example, a phenotype can lead to related studies and modules, while a module can show pathway coverage, phenotype relationship, PubMed evidence, member metabolites, and similar modules.',
        visual: 'An entity detail page with its relationship sections',
        image: '/help/entity-search-detail.png',
      },
      {
        step: '06',
        heading: 'How to search effectively',
        body: 'Use exact IDs when you have them; they rank first and usually find the intended record quickly. Use names or short title words when you are exploring. If the result list is too broad, switch to the correct entity type first, then add a more specific word or identifier.',
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
        body: 'Path Query shows how two selected records are connected in the PhenoMAP graph. It always returns the shortest connection between them, so there is nothing to configure beyond the two endpoints. It is best for tracing connections among phenotypes, studies, and modules, such as phenotype-to-module, study-to-module, or phenotype-to-phenotype routes.',
      },
      {
        step: '02',
        heading: 'Choose the two endpoints',
        body: 'Select a source record and a target record with the two node pickers. The picker uses the same Entity Search logic, so you can search by name, title, accession, database ID, or PhenoMAP ID before choosing the exact node.',
        visual: 'Path Query: the source and target node pickers with the Find connections button',
        image: '/help/path-query-form.png',
        points: [
          'Use Study, Phenotype, or Module endpoints for the clearest paths.',
          'Metabolite records can be selected in the picker, but Path Query excludes metabolites from the traversal to keep the graph readable.',
          'Confirm the entity type and PhenoMAP ID before running the query so the route starts and ends on the intended records.',
          'There is no hop setting: once both endpoints are chosen, select Find connections.',
        ],
      },
      {
        step: '03',
        heading: 'Read the visualization',
        body: 'After the query runs, the visualization shows the shortest connection between the endpoints, and the header reports how many hops that is. Every edge drawn lies on a shortest route; node colors show entity types.',
        visual: 'Path Query: the network visualization of the shortest connection',
        image: '/help/path-query-graph.png',
        points: [
          'Hover a node or edge to inspect its label and relationship type.',
          'Use edge thickness as a visual cue for relationship strength when a similarity score is available.',
          'Click a node to open its entity detail page.',
          'Two phenotypes are usually five hops apart, because the shortest route between them runs phenotype to study to module to a similar module to study to phenotype.',
        ],
      },
      {
        step: '04',
        heading: 'Compare connection paths',
        body: 'The Connections tab lists every shortest route in a linear form. Use it when the network view is dense or when you want to read the exact order of records and relationship labels from the source to the target.',
      },
      {
        step: '05',
        heading: 'How to read difficult results',
        body: 'If Path Query reports no connection, the two records genuinely have no route through the curated study, phenotype, and module backbone; choosing endpoints that are more closely related usually helps. If the result is marked as truncated, the two endpoints have more equally short routes than the page draws, so the picture is a representative sample; the reported hop count is still exact. For metabolite-centered exploration, open the metabolite detail page instead, since Path Query deliberately keeps metabolites out of the traversal.',
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
        body: 'Module Enrichment tests whether your metabolite list overlaps with PhenoMAP modules more than expected by chance. Use it when you have metabolites from an experiment or external analysis and want to find modules that are enriched for those metabolites.',
      },
      {
        step: '02',
        heading: 'Paste your metabolite identifiers',
        body: 'Paste your metabolite IDs into the input box. The page accepts one ID per line, or IDs separated by commas, spaces, or semicolons. Example buttons can fill in sample inputs if you want to test the workflow first.',
        visual: 'Module Enrichment: the metabolite ID box, ID type, module filters and Run button',
        image: '/help/enrichment-form.png',
        points: [
          'Lab ID works best when your input already uses PhenoMAP metabolite IDs.',
          'HMDB and KEGG are useful for common metabolomics annotation outputs.',
          'InChI is available when your input uses structural identifiers.',
        ],
      },
      {
        step: '03',
        heading: 'Choose the identifier type',
        body: 'Choose the ID type that matches the identifiers you pasted. The enrichment service maps your input to PhenoMAP metabolites using the selected field before it calculates overlap with modules.',
        points: [
          'Choose Lab ID for IDs such as PME002024.',
          'Choose HMDB for IDs such as HMDB0000122.',
          'Choose KEGG for IDs such as C00219.',
          'Choose InChI only when your input values are InChI strings.',
        ],
      },
      {
        step: '04',
        heading: 'Choose the module universe and cutoffs',
        body: 'PhenoMAP uses a one-sided hypergeometric test, which is mathematically the same as a one-sided Fisher’s exact test, and corrects for multiple testing with Benjamini-Hochberg across the modules that actually share at least one metabolite with your list. Module confidence and Module type let you narrow which modules are tested; the background metabolite set is rebuilt from whatever you select, so the null model always matches what is being tested.',
        points: [
          'Both filters start with everything selected, which tests all 12,929 modules against a background of 6,631 metabolites.',
          'Module confidence is high (1,090 modules), medium (4,708), or low (7,131).',
          'Module type is Host-Endogenous, Xenobiotic / Exogenous, Diet-Derived, Microbiome-Derived, or Host–Microbiome.',
          'Significance basis switches the visible results between FDR and raw p-value; both values are returned for every module, so switching does not re-run the test.',
          'Minimum overlap removes modules supported by too few shared metabolites.',
        ],
      },
      {
        step: '05',
        heading: 'Read the enrichment overview',
        body: 'The overview plot summarizes the returned modules. Each point is one module. The x-axis reflects enrichment ratio, the y-axis reflects FDR significance, and point size reflects the number of overlapping metabolites.',
        visual: 'Module Enrichment: the bubble plot and the significant module table',
        image: '/help/enrichment-results.png',
        points: [
          'Points farther right have higher enrichment ratio.',
          'Points higher on the plot have smaller FDR values.',
          'Hover a point to inspect module title, overlap count, ratio, p-value, and FDR.',
        ],
      },
      {
        step: '06',
        heading: 'Review significant modules',
        body: 'The table lists modules that pass the current significance basis, cutoff, and minimum overlap. Use it to compare module titles, confidence labels, overlapped metabolites, enrichment ratios, p-values, and FDR values.',
      },
      {
        step: '07',
        heading: 'Check unmatched IDs and export results',
        body: 'If input IDs cannot be mapped to PhenoMAP metabolites, they appear in the unmatched ID panel. Review them before interpreting the analysis. When the result table is ready, use Export CSV to download the currently visible significant modules.',
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
        body: 'PhenoMAP Chat lets you ask natural-language questions about PhenoMAP data. Behind the scenes, the chat service can call the same graph tools used by the website, including Entity Search, node detail lookup, Path Query, and Module Enrichment.',
        points: [
          'Use it for lookup, connection, association, and enrichment-style questions.',
          'Ask focused questions that name the phenotype, study, module, metabolite, or ID you care about.',
          'Treat important answers as a starting point, then open cited records to verify details.',
        ],
      },
      {
        step: '02',
        heading: 'Choose model settings',
        body: 'Open the model settings panel from the account area in the chat sidebar. You can use the official free channel when quota is available, or provide your own OpenAI-compatible provider settings for ChatGPT API or SiliconFlow.',
        points: [
          'Official free shows the remaining daily quota and does not require your own API key.',
          'ChatGPT API requires your own API key and model name.',
          'SiliconFlow requires your own API key and model name.',
          'Save changes before sending a message.',
        ],
      },
      {
        step: '03',
        heading: 'Start or resume a chat',
        body: 'Use New chat to start a clean conversation, or select a previous chat from the sidebar. Chat history is organized by conversation, so you can keep separate analysis questions in separate threads.',
        points: [
          'Starter prompts are available on an empty chat screen.',
          'You can delete old chats from the sidebar.',
          'Use separate chats when you are working on unrelated phenotypes or metabolite lists.',
        ],
      },
      {
        step: '04',
        heading: 'Ask a focused question',
        body: 'Type your question into the composer and send it. The best prompts include the record name or ID and the kind of answer you want, such as related modules, member metabolites, supporting studies, a connection path, or an enrichment result.',
        points: [
          'Good: “Which modules are associated with acute myeloid leukemia?”',
          'Good: “Where does HMDB0000289 appear in PhenoMAP?”',
          'Good: “How are obesity and metabolic dysfunction-associated steatohepatitis connected?”',
        ],
      },
      {
        step: '05',
        heading: 'Watch progress and stop if needed',
        body: 'While the assistant works, the page can show short progress messages as the backend classifies the request and calls graph tools. If a response is taking too long or you sent the wrong prompt, use the stop button in the composer.',
        points: [
          'The answer streams into the chat as it is generated.',
          'Stopped messages remain in the conversation so you can revise and try again.',
          'You can copy an answer from the message actions.',
        ],
      },
      {
        step: '06',
        heading: 'Check evidence and citations',
        body: 'PhenoMAP Chat answers are designed to cite graph records it retrieved. Citation tokens and evidence panels help you inspect where an answer came from. Open cited entity pages before using results in a report, figure, or downstream analysis.',
        visual: 'PhenoMAP Chat: an answer with its citations and evidence panel',
        image: '/help/chat-answer.png',
        points: [
          'Click cited records to inspect the underlying entity detail page.',
          'Open the evidence panel to see which tools were used.',
          'Ask a follow-up if the answer is too broad, ambiguous, or missing a specific entity type.',
        ],
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
  width: min(100%, 620px);
  margin: 20px auto 0;
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
