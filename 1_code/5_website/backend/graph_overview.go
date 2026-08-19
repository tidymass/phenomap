package main

import (
	"context"
	"fmt"
	"sync"
)

// OverviewNode is one real graph node (any of the four labels), reduced to
// just what a caller needs to display it.
type OverviewNode struct {
	Label string `json:"label"`
	LabID string `json:"lab_id"`
	Title string `json:"title"`
}

// OverviewEdge is one real edge between two real nodes above.
type OverviewEdge struct {
	FromLabel string `json:"from_label"`
	FromID    string `json:"from_id"`
	ToLabel   string `json:"to_label"`
	ToID      string `json:"to_id"`
	RelType   string `json:"rel_type"`
}

// GraphOverview is a real *sample* of the schema graph -- see
// overviewSampleSize for why this stopped being the complete graph.
type GraphOverview struct {
	Nodes []OverviewNode `json:"nodes"`
	Edges []OverviewEdge `json:"edges"`
}

// overviewSampleSize bounds how many real nodes of each label the homepage
// graph panel draws. This endpoint originally returned the *complete* real
// graph (all ~12.5k nodes), but that turned out to be the wrong call on
// both fronts it was meant to serve: even reference sites with far more
// entities than PhenoMAP (100k+) only ever render a representative sample
// for a decorative panel like this, not their whole graph -- so matching
// their look means sampling too, not drawing more. And full density made
// the client-side force layout expensive enough to visibly stall the page
// on real hardware. Individual per-node click-through was also dropped
// (see KnowledgeGraphGlobe.vue's browse-click), so there's no remaining
// functional reason every real entity needs to be present.
//
// The sample is still real -- real Lab_IDs, real relationships among
// exactly the sampled nodes -- not synthetic placeholder data. It's drawn
// once (see GraphOverview) and reused for the backend process's lifetime,
// not re-rolled on a timer. Sizes are weighted by sqrt(real count)
// per label so every type stays clearly visible instead of Metabolite
// (9.7k of the ~12.5k real nodes) crowding out Study/Phenotype/Module --
// the same weighting the frontend's decorative fallback graph already used
// for the same reason. /api/stats (the Entities/Relations totals and
// legend counts) still reports the true full counts, unaffected by this.
//
// These are targets, not independent draws -- see fetchGraphOverview for
// why sampling each label independently at these sizes left most sampled
// nodes with no edges at all.
var overviewSampleSize = map[string]int{
	"Study":      45,
	"Phenotype":  40,
	"Module":     170,
	"Metabolite": 345,
}

// overviewSimilarToCap bounds how many Module<->Module SIMILAR_TO edges a
// single overview fetch keeps, applied *within* the already-sampled Module
// subset above. Belt-and-suspenders: at real scale SIMILAR_TO is a
// near-complete similarity network (300k+ edges among only ~2.4k modules
// pre-sampling), and even among a few hundred sampled modules a dense
// pocket of it could still be a lot of edges -- keeping only the
// strongest by Similarity_Score keeps this bounded and, more usefully,
// keeps only the most meaningful similarity edges.
const overviewSimilarToCap = 3000

var (
	overviewCacheMu   sync.Mutex
	overviewCacheData *GraphOverview
)

// overviewEdgeQueries is the single source of truth for which real
// relationships GraphOverview renders: Metabolite-[:MEMBER_OF]->Module,
// Module-[:REPORTED_IN]->Study, Study-[:INVESTIGATED]->Phenotype, and
// Module-[:SIMILAR_TO]-Module -- exactly the four relationships
// product_facts.json's graph_structure describes ("Study context,
// phenotype links, module membership, and similarity edges"). Deliberately
// excludes the Metabolite<->Metabolite metabolic reaction network: that's
// a much denser, separate sub-graph (see node.go's moduleMetaboliteEdgesQuery)
// that isn't part of the four-entity schema story this overview tells.
//
// Every query filters both endpoints to the already-sampled node IDs for
// their label ($fromIds/$toIds, bound in fetchGraphOverview) -- an edge
// only appears here if both nodes it connects were themselves sampled.
var overviewEdgeQueries = []struct {
	cypher      string
	fromLabel   string
	toLabel     string
	relType     string
	extraParams map[string]any // merged in alongside fromIds/toIds; nil if none needed
}{
	{
		cypher: `MATCH (a:Metabolite)-[:MEMBER_OF]->(b:Module)
		         WHERE a.Lab_ID IN $fromIds AND b.Lab_ID IN $toIds
		         RETURN a.Lab_ID AS from_id, b.Lab_ID AS to_id`,
		fromLabel: "Metabolite", toLabel: "Module", relType: "MEMBER_OF",
	},
	{
		cypher: `MATCH (a:Module)-[:REPORTED_IN]->(b:Study)
		         WHERE a.Lab_ID IN $fromIds AND b.Lab_ID IN $toIds
		         RETURN a.Lab_ID AS from_id, b.Lab_ID AS to_id`,
		fromLabel: "Module", toLabel: "Study", relType: "REPORTED_IN",
	},
	{
		cypher: `MATCH (a:Study)-[:INVESTIGATED]->(b:Phenotype)
		         WHERE a.Lab_ID IN $fromIds AND b.Lab_ID IN $toIds
		         RETURN a.Lab_ID AS from_id, b.Lab_ID AS to_id`,
		fromLabel: "Study", toLabel: "Phenotype", relType: "INVESTIGATED",
	},
	{
		// SIMILAR_TO is stored directed (Module_ID_1 -> Module_ID_2, see
		// 05_tidy_module_module_relationship.R) but is semantically
		// symmetric -- match undirected and only take Lab_ID < Lab_ID so
		// each pair comes back once, not twice. Capped to the strongest
		// overviewSimilarToCap edges by Similarity_Score within the sampled
		// Module subset -- see that constant's comment.
		cypher: `MATCH (a:Module)-[r:SIMILAR_TO]-(b:Module)
		         WHERE a.Lab_ID < b.Lab_ID AND a.Lab_ID IN $fromIds AND b.Lab_ID IN $toIds
		         RETURN a.Lab_ID AS from_id, b.Lab_ID AS to_id
		         ORDER BY coalesce(r.Similarity_Score, -1) DESC
		         LIMIT $limit`,
		fromLabel: "Module", toLabel: "Module", relType: "SIMILAR_TO",
		extraParams: map[string]any{"limit": int64(overviewSimilarToCap)},
	},
}

// GraphOverview returns a real sample of the graph (see overviewSampleSize),
// computed once and reused for the rest of this backend process's
// lifetime -- there's no real benefit to re-rolling a fresh random sample
// on a timer for a decorative homepage panel, and skipping that keeps this
// simpler: one sample, picked the first time anyone asks, kept until the
// backend restarts. If the first attempt fails (e.g. a Neo4j hiccup), the
// failure isn't cached -- the next request just tries again.
func (db *DB) GraphOverview(ctx context.Context) (*GraphOverview, error) {
	overviewCacheMu.Lock()
	if overviewCacheData != nil {
		cached := overviewCacheData
		overviewCacheMu.Unlock()
		return cached, nil
	}
	overviewCacheMu.Unlock()

	fresh, err := db.fetchGraphOverview(ctx)
	if err != nil {
		return nil, err
	}

	overviewCacheMu.Lock()
	overviewCacheData = fresh
	overviewCacheMu.Unlock()

	return fresh, nil
}

// sampleNodes runs a Cypher query returning lab_id/title columns (plus
// whatever the caller's WHERE clause needs, passed via params + $limit),
// records every row into overview under label, and returns just the
// sampled Lab_IDs -- for use as a $moduleIds/$studyIds-style filter in a
// later sampling step, or as $fromIds/$toIds in overviewEdgeQueries.
func (db *DB) sampleNodes(ctx context.Context, overview *GraphOverview, label, cypher string, params map[string]any) ([]string, error) {
	rows, err := db.query(ctx, cypher, params)
	if err != nil {
		return nil, fmt.Errorf("overview nodes (%s): %w", label, err)
	}
	ids := make([]string, 0, len(rows))
	for _, row := range rows {
		id := asString(row["lab_id"])
		overview.Nodes = append(overview.Nodes, OverviewNode{Label: label, LabID: id, Title: asString(row["title"])})
		ids = append(ids, id)
	}
	return ids, nil
}

func (db *DB) fetchGraphOverview(ctx context.Context) (*GraphOverview, error) {
	specs := labSpecs()
	titleExpr := func(label string) string {
		if spec, ok := specs[label]; ok {
			return spec.titleExpr
		}
		return "n.Lab_ID" // defensive fallback; shouldn't happen for the four schema labels
	}
	overview := &GraphOverview{}

	// Sample Module first, independently and purely at random -- it's the
	// hub label (every relationship type here touches it: Metabolite
	// MEMBER_OF it, it's REPORTED_IN a Study, and it's SIMILAR_TO other
	// modules) -- then sample Metabolite/Study/Phenotype *from among what's
	// actually connected to these specific sampled modules*, not
	// independently from their full label.
	//
	// The first version sampled all four labels independently (each its
	// own random draw from its full ~9.7k/2.4k/174/138), which looked
	// right on paper (every node and edge still real) but broke
	// connectivity almost completely in practice: a Metabolite drawn from
	// the full 9.7k only had a ~7% chance (170/2438) that its actual
	// Module was also independently sampled, so well over 90% of sampled
	// Metabolites ended up with zero edges at all. An edgeless node has
	// nothing pulling it toward the cluster in the force layout (see
	// layoutForceDirected in KnowledgeGraphGlobe.vue) -- only repulsion
	// pushing it away -- so it drifts out into a stray orbiting dot,
	// which is exactly the "spread out, not a clean ball" shape reported
	// after that version. Sampling outward from a Module backbone instead
	// guarantees nearly every sampled node has at least one real edge
	// into the sample.
	moduleIDs, err := db.sampleNodes(ctx, overview, "Module",
		fmt.Sprintf(`MATCH (n:Module) WITH n, rand() AS r ORDER BY r LIMIT $limit
		             RETURN n.Lab_ID AS lab_id, %s AS title`, titleExpr("Module")),
		map[string]any{"limit": int64(overviewSampleSize["Module"])},
	)
	if err != nil {
		return nil, err
	}

	metaboliteIDs, err := db.sampleNodes(ctx, overview, "Metabolite",
		fmt.Sprintf(`MATCH (n:Metabolite)-[:MEMBER_OF]->(mod:Module) WHERE mod.Lab_ID IN $moduleIds
		             WITH DISTINCT n, rand() AS r ORDER BY r LIMIT $limit
		             RETURN n.Lab_ID AS lab_id, %s AS title`, titleExpr("Metabolite")),
		map[string]any{"moduleIds": moduleIDs, "limit": int64(overviewSampleSize["Metabolite"])},
	)
	if err != nil {
		return nil, err
	}

	studyIDs, err := db.sampleNodes(ctx, overview, "Study",
		fmt.Sprintf(`MATCH (mod:Module)-[:REPORTED_IN]->(n:Study) WHERE mod.Lab_ID IN $moduleIds
		             WITH DISTINCT n, rand() AS r ORDER BY r LIMIT $limit
		             RETURN n.Lab_ID AS lab_id, %s AS title`, titleExpr("Study")),
		map[string]any{"moduleIds": moduleIDs, "limit": int64(overviewSampleSize["Study"])},
	)
	if err != nil {
		return nil, err
	}

	phenotypeIDs, err := db.sampleNodes(ctx, overview, "Phenotype",
		fmt.Sprintf(`MATCH (s:Study)-[:INVESTIGATED]->(n:Phenotype) WHERE s.Lab_ID IN $studyIds
		             WITH DISTINCT n, rand() AS r ORDER BY r LIMIT $limit
		             RETURN n.Lab_ID AS lab_id, %s AS title`, titleExpr("Phenotype")),
		map[string]any{"studyIds": studyIDs, "limit": int64(overviewSampleSize["Phenotype"])},
	)
	if err != nil {
		return nil, err
	}

	sampledIDs := map[string][]string{
		"Module":     moduleIDs,
		"Metabolite": metaboliteIDs,
		"Study":      studyIDs,
		"Phenotype":  phenotypeIDs,
	}

	for _, eq := range overviewEdgeQueries {
		params := map[string]any{
			"fromIds": sampledIDs[eq.fromLabel],
			"toIds":   sampledIDs[eq.toLabel],
		}
		for k, v := range eq.extraParams {
			params[k] = v
		}
		rows, err := db.query(ctx, eq.cypher, params)
		if err != nil {
			return nil, fmt.Errorf("overview edges (%s): %w", eq.relType, err)
		}
		for _, row := range rows {
			overview.Edges = append(overview.Edges, OverviewEdge{
				FromLabel: eq.fromLabel,
				FromID:    asString(row["from_id"]),
				ToLabel:   eq.toLabel,
				ToID:      asString(row["to_id"]),
				RelType:   eq.relType,
			})
		}
	}

	return overview, nil
}
