package main

import (
	"context"
	"fmt"
	"regexp"
	"sort"
	"sync"
)

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

var (
	statsCacheMu   sync.Mutex
	statsCacheData *GraphStats
)

// safeSchemaName guards the only place in this codebase where a name is
// interpolated into Cypher instead of being passed as a parameter (see
// countFromStore below for why it has to be). The names come from
// db.labels()/db.relationshipTypes() -- the database's own schema, not
// anything a user can send -- but the check is cheap and keeps that
// guarantee local to this file rather than implied from three calls away.
var safeSchemaName = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_]*$`)

// Stats gives live node/relationship counts by label and type, so pages
// like the homepage stats strip and Download don't need hardcoded numbers
// that go stale as the graph grows.
//
// Counts are read from Neo4j's count store, one cheap lookup per label and
// per relationship type, rather than with the obvious
//
//	MATCH (n) RETURN labels(n)[0] AS label, count(*)
//	MATCH ()-[r]->() RETURN type(r) AS rel, count(*)
//
// Those two read correctly but are full scans: grouping by labels(n)[0] /
// type(r) means the planner can't use the count store, so answering a
// decorative homepage number walked all ~1.7M relationships and took long
// enough that the cards visibly popped in after the rest of the page.
//
// The result is then cached for the rest of this backend process's
// lifetime. The graph is only ever written by deploy/import_neo4j.sh, which
// requires stopping the database, so a restart is already part of changing
// these numbers -- there is nothing for a TTL to catch. A failure isn't
// cached; the next request just tries again.
func (db *DB) Stats(ctx context.Context) (*GraphStats, error) {
	statsCacheMu.Lock()
	if statsCacheData != nil {
		cached := statsCacheData
		statsCacheMu.Unlock()
		return cached, nil
	}
	statsCacheMu.Unlock()

	fresh, err := db.fetchStats(ctx)
	if err != nil {
		return nil, err
	}

	statsCacheMu.Lock()
	statsCacheData = fresh
	statsCacheMu.Unlock()

	return fresh, nil
}

// WarmStats fills the cache ahead of the first request, so the very first
// visitor after a restart doesn't pay for it either. Best-effort: on
// failure Stats just computes it on demand as before.
func (db *DB) WarmStats(ctx context.Context) error {
	_, err := db.Stats(ctx)
	return err
}

func (db *DB) fetchStats(ctx context.Context) (*GraphStats, error) {
	labels, err := db.schemaNames(ctx, `CALL db.labels() YIELD label RETURN label AS name`)
	if err != nil {
		return nil, err
	}
	relTypes, err := db.schemaNames(ctx, `CALL db.relationshipTypes() YIELD relationshipType RETURN relationshipType AS name`)
	if err != nil {
		return nil, err
	}

	nodes := make([]LabelCount, 0, len(labels))
	for _, label := range labels {
		// Every node in this graph carries exactly one label (see
		// deploy/import_neo4j.sh: one --nodes=Label per CSV), so a per-label
		// count is exactly what the old labels(n)[0] grouping returned.
		n, err := db.countFromStore(ctx, fmt.Sprintf("MATCH (n:`%s`) RETURN count(n) AS n", label))
		if err != nil {
			return nil, err
		}
		nodes = append(nodes, LabelCount{Label: label, Count: n})
	}

	rels := make([]RelTypeCount, 0, len(relTypes))
	for _, relType := range relTypes {
		n, err := db.countFromStore(ctx, fmt.Sprintf("MATCH ()-[r:`%s`]->() RETURN count(r) AS n", relType))
		if err != nil {
			return nil, err
		}
		rels = append(rels, RelTypeCount{Type: relType, Count: n})
	}

	// db.labels()/db.relationshipTypes() return schema order, which isn't
	// stable across imports. Sort so the payload is deterministic; the
	// frontend picks the entries it wants by name anyway.
	sort.Slice(nodes, func(i, j int) bool { return nodes[i].Label < nodes[j].Label })
	sort.Slice(rels, func(i, j int) bool { return rels[i].Type < rels[j].Type })

	return &GraphStats{Nodes: nodes, Relationships: rels}, nil
}

func (db *DB) schemaNames(ctx context.Context, cypher string) ([]string, error) {
	rows, err := db.query(ctx, cypher, nil)
	if err != nil {
		return nil, err
	}
	names := make([]string, 0, len(rows))
	for _, row := range rows {
		name := asString(row["name"])
		if name == "" {
			continue
		}
		if !safeSchemaName.MatchString(name) {
			// A name this backend can't safely quote is skipped rather than
			// failing the whole endpoint -- none of the labels or
			// relationship types this graph actually uses can hit this.
			continue
		}
		names = append(names, name)
	}
	return names, nil
}

// countFromStore runs a single count query. The label/type has to be
// literal in the pattern for the planner to answer it from the count store
// -- a parameter would force a scan, which is the whole thing this avoids.
func (db *DB) countFromStore(ctx context.Context, cypher string) (int64, error) {
	rows, err := db.query(ctx, cypher, nil)
	if err != nil {
		return 0, err
	}
	if len(rows) == 0 {
		return 0, nil
	}
	return asInt64(rows[0]["n"]), nil
}
