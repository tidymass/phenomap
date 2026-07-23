package main

import "context"

// NodeDetail is the full response for GET /api/node/{label}/{id}.
type NodeDetail struct {
	Label      string         `json:"label"`
	Properties map[string]any `json:"properties"`
	Neighbors  []Neighbor     `json:"neighbors"`
	Counts     []RelCount     `json:"relationship_counts"`
	// StudyPhenotypes is Module-only: a module has no direct graph edge to
	// a Phenotype (phenotype_relationship/confidence_label/etc. are just
	// free-text properties on the module), so this is resolved via the
	// module's Study instead (Module -REPORTED_IN-> Study -INVESTIGATED->
	// Phenotype) to give the Phenotype Relationship card something to link.
	StudyPhenotypes []Neighbor `json:"study_phenotypes"`
	// MetaboliteEdges is Module-only: the real CONNECTED_WITH edges (from
	// the metabolic reaction network) that exist between this module's own
	// anchor/supporting/contextual metabolites -- the actual network
	// structure, as opposed to a synthetic hub-and-spoke layout.
	MetaboliteEdges []MetaboliteEdge `json:"metabolite_edges"`
	// PhenotypeModules is Phenotype-only: the mirror image of StudyPhenotypes
	// above -- a phenotype has no direct graph edge to a Module either, so
	// this resolves Phenotype <-INVESTIGATED- Study <-REPORTED_IN- Module to
	// give the Phenotype page's Related Modules card something to link.
	PhenotypeModules []Neighbor `json:"phenotype_modules"`
}

type MetaboliteEdge struct {
	From string `json:"from"`
	To   string `json:"to"`
}

type Neighbor struct {
	RelType       string         `json:"rel_type"`
	RelProps      map[string]any `json:"rel_props"`
	NeighborLabel string         `json:"neighbor_label"`
	NeighborID    string         `json:"neighbor_id"`
	NeighborName  string         `json:"neighbor_name"`
}

type RelCount struct {
	RelType string `json:"rel_type"`
	Count   int64  `json:"count"`
}

const nodeDetailQuery = `
	MATCH (n {Lab_ID: $id})
	WHERE $label IN labels(n)
	RETURN properties(n) AS props, labels(n)[0] AS label
	LIMIT 1
`

// neighborsQuery returns a capped list of neighbors. neighbor_name is
// computed with coalesce() across every label's natural-name field, so
// the frontend doesn't need per-label logic to render a readable link.
// Within each relationship type, rows are ordered by Similarity_Score
// (SIMILAR_TO edges) descending, so the strongest matches surface first --
// coalesced to -1 so relationship types without that property (i.e.
// everything else) are unaffected and just keep Neo4j's scan order.
const neighborsQuery = `
	MATCH (n {Lab_ID: $id})-[r]-(m)
	WHERE $label IN labels(n)
	RETURN type(r) AS rel_type, properties(r) AS rel_props, labels(m)[0] AS neighbor_label,
	       m.Lab_ID AS neighbor_id,
	       coalesce(m.Accession, m.Phenotype, m.title, m.module_id, m.Metabolite_Name, '') AS neighbor_name
	ORDER BY rel_type, coalesce(r.Similarity_Score, -1) DESC
	LIMIT $cap
`

// neighborCountsQuery gives the true count per relationship type, since
// hub nodes (e.g. common metabolites) can have far more neighbors than
// the cap above returns.
const neighborCountsQuery = `
	MATCH (n {Lab_ID: $id})-[r]-(m)
	WHERE $label IN labels(n)
	RETURN type(r) AS rel_type, count(*) AS n
`

// modulePhenotypesQuery resolves the phenotype(s) a module's own study
// investigated -- a two-hop traversal, since modules only link directly to
// their study, not to a phenotype.
const modulePhenotypesQuery = `
	MATCH (n:Module {Lab_ID: $id})-[:REPORTED_IN]->(:Study)-[:INVESTIGATED]->(ph:Phenotype)
	RETURN DISTINCT ph.Lab_ID AS neighbor_id, coalesce(ph.Phenotype, '') AS neighbor_name
	ORDER BY neighbor_name
`

// phenotypeModulesQuery resolves the module(s) reported in any study that
// investigated this phenotype -- the reverse of modulePhenotypesQuery above,
// a two-hop traversal since phenotypes only link directly to a study, not a
// module.
const phenotypeModulesQuery = `
	MATCH (n:Phenotype {Lab_ID: $id})<-[:INVESTIGATED]-(:Study)<-[:REPORTED_IN]-(mod:Module)
	RETURN DISTINCT mod.Lab_ID AS neighbor_id, coalesce(mod.title, '') AS neighbor_name
	ORDER BY neighbor_name
`

// moduleMetaboliteEdgesQuery finds the real metabolite-metabolite edges
// (from the metabolic reaction network) restricted to this module's own
// anchor/supporting/contextual metabolite set -- the module's id-list
// properties are semicolon-space-joined Lab_IDs (see
// 04_tidy_module_entity.R's collapse_ids), so they're split back out here.
//
// The relationship is matched with no type name (-[r]-) rather than
// -[:CONNECTED_WITH]- on purpose: RUNBOOK.md's neo4j-admin import command
// had its --relationships type labels mismatched against their CSV files
// for a while (edges_metabolite_metabolite.csv could have landed under
// CONNECTED_WITH or SIMILAR_TO depending on which version of the command
// was actually run). Since Metabolite<->Metabolite is the only relationship
// this schema ever puts between two :Metabolite nodes, matching untyped is
// both correct and immune to that naming drift.
const moduleMetaboliteEdgesQuery = `
	MATCH (mod:Module {Lab_ID: $id})
	WITH
		[x IN split(coalesce(mod.anchor_metabolite_ids, ''), '; ') WHERE x <> ''] +
		[x IN split(coalesce(mod.supporting_metabolite_ids, ''), '; ') WHERE x <> ''] +
		[x IN split(coalesce(mod.contextual_metabolite_ids, ''), '; ') WHERE x <> ''] AS metIds
	MATCH (a:Metabolite)-[r]-(b:Metabolite)
	WHERE a.Lab_ID IN metIds AND b.Lab_ID IN metIds AND a.Lab_ID < b.Lab_ID
	RETURN DISTINCT a.Lab_ID AS from_id, b.Lab_ID AS to_id
`

// GetNode loads a single node's own properties plus a capped list of its
// neighbors (grouped by relationship type) and the true count of
// neighbors per relationship type.
func (db *DB) GetNode(ctx context.Context, label, id string, neighborCap int) (*NodeDetail, bool, error) {
	rows, err := db.query(ctx, nodeDetailQuery, map[string]any{"id": id, "label": label})
	if err != nil {
		return nil, false, err
	}
	if len(rows) == 0 {
		return nil, false, nil
	}

	props, _ := rows[0]["props"].(map[string]any)
	actualLabel := asString(rows[0]["label"])

	neighborRows, err := db.query(ctx, neighborsQuery, map[string]any{
		"id": id, "label": label, "cap": int64(neighborCap),
	})
	if err != nil {
		return nil, false, err
	}
	neighbors := make([]Neighbor, 0, len(neighborRows))
	for _, row := range neighborRows {
		relProps, _ := row["rel_props"].(map[string]any)
		neighbors = append(neighbors, Neighbor{
			RelType:       asString(row["rel_type"]),
			RelProps:      relProps,
			NeighborLabel: asString(row["neighbor_label"]),
			NeighborID:    asString(row["neighbor_id"]),
			NeighborName:  asString(row["neighbor_name"]),
		})
	}

	countRows, err := db.query(ctx, neighborCountsQuery, map[string]any{"id": id, "label": label})
	if err != nil {
		return nil, false, err
	}
	counts := make([]RelCount, 0, len(countRows))
	for _, row := range countRows {
		counts = append(counts, RelCount{
			RelType: asString(row["rel_type"]),
			Count:   asInt64(row["n"]),
		})
	}

	var studyPhenotypes []Neighbor
	var metaboliteEdges []MetaboliteEdge
	var phenotypeModules []Neighbor
	if actualLabel == "Module" {
		phRows, err := db.query(ctx, modulePhenotypesQuery, map[string]any{"id": id})
		if err != nil {
			return nil, false, err
		}
		studyPhenotypes = make([]Neighbor, 0, len(phRows))
		for _, row := range phRows {
			studyPhenotypes = append(studyPhenotypes, Neighbor{
				RelType:       "INVESTIGATED",
				NeighborLabel: "Phenotype",
				NeighborID:    asString(row["neighbor_id"]),
				NeighborName:  asString(row["neighbor_name"]),
			})
		}

		edgeRows, err := db.query(ctx, moduleMetaboliteEdgesQuery, map[string]any{"id": id})
		if err != nil {
			return nil, false, err
		}
		metaboliteEdges = make([]MetaboliteEdge, 0, len(edgeRows))
		for _, row := range edgeRows {
			metaboliteEdges = append(metaboliteEdges, MetaboliteEdge{
				From: asString(row["from_id"]),
				To:   asString(row["to_id"]),
			})
		}
	} else if actualLabel == "Phenotype" {
		modRows, err := db.query(ctx, phenotypeModulesQuery, map[string]any{"id": id})
		if err != nil {
			return nil, false, err
		}
		phenotypeModules = make([]Neighbor, 0, len(modRows))
		for _, row := range modRows {
			phenotypeModules = append(phenotypeModules, Neighbor{
				RelType:       "REPORTED_IN",
				NeighborLabel: "Module",
				NeighborID:    asString(row["neighbor_id"]),
				NeighborName:  asString(row["neighbor_name"]),
			})
		}
	}

	return &NodeDetail{
		Label:            actualLabel,
		Properties:       props,
		Neighbors:        neighbors,
		Counts:           counts,
		StudyPhenotypes:  studyPhenotypes,
		MetaboliteEdges:  metaboliteEdges,
		PhenotypeModules: phenotypeModules,
	}, true, nil
}
