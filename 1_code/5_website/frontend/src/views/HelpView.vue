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
            <div v-if="section.visual" class="screenshot-slot">
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
import { computed } from 'vue'
import { useRoute } from 'vue-router'

const route = useRoute()

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
        body: 'Entity Search is the fastest way to move from a name, accession, module title, or metabolite identifier into the PhenoMAP knowledge graph. Use it when you already have a clue, such as a phenotype name, study accession, metabolite ID, or pathway-related keyword, and want to inspect the matching entity and its graph neighborhood.',
      },
      {
        step: '02',
        heading: 'Choose the entity type first',
        body: 'Start by selecting the type you want to search. PhenoMAP currently supports four entity types, and choosing the type narrows both the matching fields and the examples shown on the home page.',
        visual: 'Screenshot placeholder: home search type selector',
        points: [
          'Study: search by study accession, title, or study-related keywords.',
          'Phenotype: search by normalized phenotype names or phenotype keywords.',
          'Module: search by module title, module identifier, pathway, class, or functional keyword.',
          'Metabolite: search by compound name, HMDB ID, KEGG ID, InChI ID, or related keyword.',
        ],
      },
      {
        step: '03',
        heading: 'Run a search from the home page',
        body: 'On the home page, pick an entity type from the left side of the search box, enter at least two characters, and submit the search. The example links below the search box are type-specific shortcuts; clicking one sends the example query to the full Entity Search page with the same selected type.',
        visual: 'Screenshot placeholder: query entered in the homepage search bar',
      },
      {
        step: '04',
        heading: 'Browse and refine results',
        body: 'The Entity Search page shows results in a table designed for quick scanning. The main title identifies the matched entity, while the detail columns expose type-specific identifiers or metadata. You can change the selected type, update the search text, clear the query, or use pagination to move through larger result sets.',
        visual: 'Screenshot placeholder: Entity Search results table',
        points: [
          'An empty query browses all entities of the selected type.',
          'One-character queries are ignored until more text is entered.',
          'Changing the type resets the result list so the table stays scoped to the selected entity class.',
        ],
      },
      {
        step: '05',
        heading: 'Open an entity detail page',
        body: 'Click any result to open its detail page. The detail page is where Entity Search becomes exploratory: it lists the selected node properties and groups connected neighbors by relationship type. This lets you move from a phenotype to its studies, from a study to its modules, or from a module to member metabolites and similar modules.',
        visual: 'Screenshot placeholder: entity detail page with relationships',
      },
      {
        step: '06',
        heading: 'How to search effectively',
        body: 'Use precise identifiers when you have them, and broader keywords when you want discovery. For example, a study accession is best for finding one exact study, while a pathway word such as “Purine” or “Glutathione” is useful for finding related modules. If a query returns too many results, switch to a more specific entity type or add a more specific term.',
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
        body: 'Path Query helps you ask how two PhenoMAP entities are connected in the knowledge graph. Use it when you want to move beyond a single node and inspect the shortest evidence path between a phenotype, study, module, or metabolite pair.',
      },
      {
        step: '02',
        heading: 'Choose the two endpoints',
        body: 'Start by selecting a source entity and a target entity. Each endpoint uses a node picker, so you can search by entity name, PhenoMAP ID, accession, or other type-specific identifiers before choosing the exact node.',
        visual: 'Screenshot placeholder: source and target node pickers',
        points: [
          'Use specific modules or metabolites when you want a compact path.',
          'Use phenotypes or studies when you want to trace broader biological context.',
          'Confirm the displayed entity type before running the query so the path starts and ends where you expect.',
        ],
      },
      {
        step: '03',
        heading: 'Set the maximum hop range',
        body: 'The hop range controls how many relationship steps Path Query may explore between the two endpoints. A smaller range gives a stricter, cleaner answer; a larger range can reveal indirect connections but may include more intermediate nodes.',
        visual: 'Screenshot placeholder: max hop selector',
        points: [
          'Start with a lower hop count when both endpoints are specific.',
          'Increase the hop count if no connection is found.',
          'Very highly connected endpoints may return a limited subset to keep the visualization readable.',
        ],
      },
      {
        step: '04',
        heading: 'Read the visualization',
        body: 'After the query runs, the visualization shows the entities and relationships involved in the returned connection. Endpoint nodes are emphasized, node colors identify entity types, and relationship lines show how the graph links the selected pair.',
        visual: 'Screenshot placeholder: Path Query network visualization',
        points: [
          'Hover a node to inspect its label and core metadata.',
          'Hover a relationship line to inspect the relationship type.',
          'Click a node to open its entity detail page for deeper inspection.',
        ],
      },
      {
        step: '05',
        heading: 'Compare connection paths',
        body: 'The Connections tab lists the returned routes in a linear form. Use it when the network view is visually dense or when you want to read the exact sequence of entities and relationship labels from one endpoint to the other.',
        visual: 'Screenshot placeholder: Connections tab with route list',
      },
      {
        step: '06',
        heading: 'How to refine difficult queries',
        body: 'If Path Query returns no connection, try increasing the hop range or selecting more specific endpoints. If the result is too broad, reduce the hop range or choose a module/metabolite instead of a phenotype/study. The best paths usually come from endpoint pairs that are biologically meaningful and specific enough to avoid very large neighborhoods.',
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
        body: 'Module Enrichment tests whether a list of metabolites is over-represented in any PhenoMAP metabolic modules. Use it when you have a metabolite set from an experiment, pathway, annotation result, or external analysis and want to see which dysregulated modules it matches.',
      },
      {
        step: '02',
        heading: 'Paste your metabolite identifiers',
        body: 'Enter one or more metabolite identifiers into the input box. You can paste one ID per line, or separate IDs with commas, spaces, or semicolons. The tool will parse the list before submitting it to the enrichment service.',
        visual: 'Screenshot placeholder: metabolite ID input area',
        points: [
          'Lab ID works best when you already have PhenoMAP metabolite IDs.',
          'HMDB and KEGG IDs are useful for common external metabolomics outputs.',
          'InChI can be used when structural identifiers are available.',
        ],
      },
      {
        step: '03',
        heading: 'Choose the identifier type',
        body: 'Select the ID type that matches the identifiers you pasted. The selected type controls how the input list is matched against PhenoMAP metabolites before enrichment is calculated.',
        visual: 'Screenshot placeholder: ID type selector',
        points: [
          'If your IDs look like PMAP_METAB_000901, choose Lab ID.',
          'If your IDs look like HMDB0000122, choose HMDB.',
          'If your IDs look like C00219, choose KEGG.',
        ],
      },
      {
        step: '04',
        heading: 'Set the test and filters',
        body: 'Choose the statistical method, significance basis, cutoff, and minimum overlap before running the analysis. These controls let you decide how strict the result list should be and whether significance is evaluated by FDR or raw p-value.',
        visual: 'Screenshot placeholder: enrichment controls',
        points: [
          'Fisher’s exact test is a good default for most input lists.',
          'FDR is usually preferred when comparing many modules at once.',
          'Minimum overlap prevents modules with only one shared metabolite from dominating the result list.',
        ],
      },
      {
        step: '05',
        heading: 'Read the enrichment overview',
        body: 'The visualization plots modules by effect size and significance. Each point represents a module, with point size reflecting overlap and color indicating whether it passes the current significance and overlap filters.',
        visual: 'Screenshot placeholder: enrichment bubble plot',
        points: [
          'Modules farther to the right have stronger enrichment ratios.',
          'Modules higher on the plot have stronger FDR significance.',
          'Hover points to inspect overlap counts, ratio, and FDR.',
        ],
      },
      {
        step: '06',
        heading: 'Review significant modules',
        body: 'The Significant modules table lists modules that pass the selected cutoff and minimum overlap. Use this table to compare module titles, confidence labels, overlapped metabolites, enrichment ratios, p-values, and FDR values.',
        visual: 'Screenshot placeholder: significant modules table',
      },
      {
        step: '07',
        heading: 'Check unmatched IDs and export results',
        body: 'If some input IDs cannot be matched to PhenoMAP metabolites, they appear in the unmatched ID panel. Review these IDs before interpreting the result. When results are ready, export the visible significant modules as a CSV file for downstream analysis or reporting.',
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
        heading: 'Choose a model provider first',
        body: 'Before using PhenoMAP Chat, choose how the language model should be provided. PhenoMAP Chat can use the built-in official channel when available, or you can configure your own API provider from the model settings panel. The provider choice controls which API key, model name, quota, and billing account are used for chat responses.',
        visual: 'Screenshot placeholder: model provider settings',
        points: [
          'Official channel: use the built-in PhenoMAP-provided model route, subject to the displayed free quota.',
          'OpenAI API: use your own OpenAI Platform API key and model name.',
          'SiliconFlow: use your own SiliconFlow API key and a supported model from the SiliconFlow platform.',
        ],
      },
      {
        step: '02',
        heading: 'Use the built-in official channel',
        body: 'If you use the official channel, no personal API key is required. The model settings panel shows the daily free quota available for this route. This option is the simplest way to try PhenoMAP Chat, but it may be limited by quota, availability, or the model chosen by the PhenoMAP deployment.',
        visual: 'Screenshot placeholder: official provider and quota panel',
        points: [
          'Use this mode when you want to test PhenoMAP Chat quickly.',
          'Watch the displayed daily quota before long exploratory sessions.',
          'Switch to a personal API provider when you need your own billing, model control, or higher usage.',
        ],
      },
      {
        step: '03',
        heading: 'Create and fund an OpenAI API account',
        body: [
          'To use your own GPT/OpenAI model, create an OpenAI Platform account, open the ',
          { text: 'API key page', href: 'https://platform.openai.com/api-keys' },
          ', create an API key, and make sure the API organization has billing enabled in the ',
          { text: 'billing overview', href: 'https://platform.openai.com/settings/organization/billing/overview' },
          '. ChatGPT Plus/Pro/Team subscriptions are managed separately from API usage, so a paid ChatGPT subscription does not automatically pay for API calls.',
        ],
        visual: 'Screenshot placeholder: OpenAI API key and billing settings',
        points: [
          ['Create an API key from the ', { text: 'OpenAI Platform dashboard', href: 'https://platform.openai.com/api-keys' }, ' and keep it private.'],
          'OpenAI API usage is billed through the API Platform, not through the ChatGPT subscription page.',
          ['For prepaid billing, add credits in the ', { text: 'Billing area', href: 'https://platform.openai.com/settings/organization/billing/overview' }, '; new API accounts are commonly enrolled in prepaid billing.'],
          ['Check ', { text: 'OpenAI API pricing', href: 'https://openai.com/api/pricing/' }, ' before choosing a model for heavy usage.'],
          'Purchased API credits can expire and are generally non-refundable, so start with a small balance while testing.',
        ],
      },
      {
        step: '04',
        heading: 'Configure OpenAI in PhenoMAP',
        body: [
          'In the PhenoMAP Chat model settings, choose the OpenAI provider, paste your OpenAI API key, and enter the model name you want to use. If you need to find or rotate a key, use the ',
          { text: 'OpenAI API key page', href: 'https://platform.openai.com/api-keys' },
          '. Save the settings before sending a message. The request will then be charged to your own OpenAI API account according to the selected model and token usage.',
        ],
        visual: 'Screenshot placeholder: OpenAI provider fields',
        points: [
          'Use an API model name supported by your OpenAI account.',
          ['If requests fail, check that the key is valid, billing is active, and your account has enough credit or quota; the ', { text: 'usage dashboard', href: 'https://platform.openai.com/usage' }, ' can help you inspect recent API activity.'],
          'Do not paste personal API keys into shared screenshots or public issue reports.',
        ],
      },
      {
        step: '05',
        heading: 'Create and recharge a SiliconFlow account',
        body: [
          'To use SiliconFlow, create a SiliconFlow account from the ',
          { text: 'SiliconFlow console', href: 'https://cloud.siliconflow.cn/' },
          ', complete any required account verification, create an API key from the ',
          { text: 'API key page', href: 'https://cloud.siliconflow.cn/account/ak' },
          ', and recharge the account balance from the console. SiliconFlow provides OpenAI-compatible API access for supported large language models, so PhenoMAP Chat can call it with the SiliconFlow key and model name.',
        ],
        visual: 'Screenshot placeholder: SiliconFlow API key and recharge pages',
        points: [
          ['Create an API key from the SiliconFlow ', { text: 'API key page', href: 'https://cloud.siliconflow.cn/account/ak' }, '.'],
          ['Recharge from the balance or finance area before high-volume usage; see the ', { text: 'SiliconFlow finance FAQ', href: 'https://api-docs.siliconflow.cn/docs/userguide/faqs/misc_finance' }, ' for the current recharge path.'],
          ['Choose a supported model name from the ', { text: 'SiliconFlow model list', href: 'https://cloud.siliconflow.cn/models' }, ', such as a Qwen or DeepSeek model available to your account.'],
          'SiliconFlow OpenAI-compatible calls use the base URL https://api.siliconflow.cn/v1.',
        ],
      },
      {
        step: '06',
        heading: 'Configure SiliconFlow in PhenoMAP',
        body: [
          'In the PhenoMAP Chat model settings, choose the SiliconFlow provider, paste your SiliconFlow API key, and enter the exact model name you want PhenoMAP Chat to call. SiliconFlow’s ',
          { text: 'quickstart documentation', href: 'https://docs.siliconflow.cn/cn/userguide/quickstart' },
          ' shows the OpenAI-compatible base URL and request format. Save the settings, then send a test prompt to confirm that the provider, key, balance, and model name are all working.',
        ],
        visual: 'Screenshot placeholder: SiliconFlow provider fields',
        points: [
          ['If the request fails, check the API key, account balance, model availability in the ', { text: 'model list', href: 'https://cloud.siliconflow.cn/models' }, ', and model spelling.'],
          'Model behavior may differ from OpenAI models, so compare answers before using results in a report.',
          'Keep provider-specific keys separate if multiple users share the same PhenoMAP account.',
        ],
      },
      {
        step: '07',
        heading: 'Ask graph-grounded questions after setup',
        body: 'After the provider is configured, ask focused questions about PhenoMAP entities and relationships. Good prompts name the phenotype, study, module, metabolite, or ID you care about and ask for a specific output such as connected modules, supporting studies, member metabolites, or cited evidence.',
        visual: 'Screenshot placeholder: graph-grounded PhenoMAP Chat answer with evidence',
        points: [
          'Use citations and evidence links to verify important answers.',
          'Open cited entity pages when preparing final results or figures.',
          'If an answer is too broad, ask a follow-up that narrows the entity type, phenotype, module, or evidence source.',
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
