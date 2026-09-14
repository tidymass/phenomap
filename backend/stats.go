package main

import "context"

type LabelCount struct {
	Label string `json:"label"`
	Count int64  `json:"count"`
}

type RelTypeCount struct {
	Type  string `json:"type"`
	Count int64  `json:"count"`
}

type GraphStats struct {
	Nodes         []LabelCount   `json:"nodes"`
	Relationships []RelTypeCount `json:"relationships"`
}

// Stats gives live node/relationship counts by label and type, so pages
// like Download don't need hardcoded numbers that go stale as the graph
// grows.
func (db *DB) Stats(ctx context.Context) (*GraphStats, error) {
	nodeRows, err := db.query(ctx, `MATCH (n) RETURN labels(n)[0] AS label, count(*) AS n`, nil)
	if err != nil {
		return nil, err
	}
	nodes := make([]LabelCount, 0, len(nodeRows))
	for _, row := range nodeRows {
		nodes = append(nodes, LabelCount{Label: asString(row["label"]), Count: asInt64(row["n"])})
	}

	relRows, err := db.query(ctx, `MATCH ()-[r]->() RETURN type(r) AS rel, count(*) AS n`, nil)
	if err != nil {
		return nil, err
	}
	rels := make([]RelTypeCount, 0, len(relRows))
	for _, row := range relRows {
		rels = append(rels, RelTypeCount{Type: asString(row["rel"]), Count: asInt64(row["n"])})
	}

	return &GraphStats{Nodes: nodes, Relationships: rels}, nil
}
