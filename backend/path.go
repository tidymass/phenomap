package main

import (
	"context"
	"fmt"
	"sort"
)

// PathGraphNode/PathGraphEdge/PathGraph describe the connection subgraph
// returned by GET /api/path.
//
// Earlier this endpoint picked one or two "best" shortest paths and tried
// to force a total order over what are often genuinely tied alternatives
// (see the old FindPaths/score logic in git history). Instead, this
// resolves every node and edge that could plausibly sit on *some* walk
// between the two endpoints of length <= maxHops, weights each edge by
// whatever strength signal its relationship type carries, and lets the
// frontend render the whole thing as a graph -- edge thickness communicates
// strength directly instead of forcing a single-file ranked list onto
// something that isn't naturally ordered.
type PathGraphNode struct {
	Label string `json:"label"`
	ID    string `json:"id"`
	Name  string `json:"name"`
}

type PathGraphEdge struct {
	From           string         `json:"from"`
	To             string         `json:"to"`
	Type           string         `json:"type"`
	Props          map[string]any `json:"props"`
	Weight         float64        `json:"weight"`
	OnShortestPath bool           `json:"on_shortest_path"`
}

type PathGraph struct {
	Nodes []PathGraphNode `json:"nodes"`
	Edges []PathGraphEdge `json:"edges"`
	// Hops is the true shortest distance between the two endpoints, or nil
	// if they aren't connected within maxHops at all.
	Hops *int64 `json:"hops"`
	// Truncated is set when the two endpoints have more equally-short routes
	// between them than maxShortestPaths enumerates, so the drawing is a
	// representative sample of those routes rather than all of them. It never
	// casts doubt on Hops, which comes from an exact, uncapped query.
	Truncated bool `json:"truncated"`
}

// nodeLookupQuery confirms a node exists and gets its display name, before
// spending any work on it.
const nodeLookupQuery = `
	MATCH (n {Lab_ID: $id})
	WHERE $label IN labels(n)
	RETURN coalesce(n.Accession, n.Phenotype, n.title, n.module_id, n.Metabolite_Name, '') AS name
	LIMIT 1
`

// nodeInfoQuery gets display label/name for the already-known set of node IDs
// that survive edge filtering. fromID and toID already have their label/name
// from nodeLookupQuery.
const nodeInfoQuery = `
	UNWIND $ids AS id
	MATCH (n {Lab_ID: id})
	RETURN n.Lab_ID AS id, labels(n)[0] AS label,
	       coalesce(n.Accession, n.Phenotype, n.title, n.module_id, '') AS name
`

// shortestPathEdgesQuery returns every relationship that lies on a shortest
// connection between the two endpoints, via Neo4j's native allShortestPaths.
//
// This replaces an earlier apoc.path.subgraphAll approach that fetched the
// whole induced subgraph within maxHops of ONE endpoint and then filtered it
// down in Go. That was fine on the old, sparse graph, but SIMILAR_TO grew
// from ~179k to ~1.67M relationships: the 5-hop ball around any Phenotype is
// now ~13,700 nodes -- essentially the entire 13,756-node graph -- so the
// fetch always hit its node cap, and the part that got cut was precisely the
// half near the *other* endpoint. The result was the worst possible outcome:
// a correct "hops: 5" from shortestHopsQuery next to an empty edge list, so
// the frontend had a connection to report and nothing to draw with.
//
// allShortestPaths is bidirectional, like shortestPath, so its cost scales
// with branchingFactor^(maxHops/2) instead of ^maxHops, and it never walks
// territory that cannot be on a path between the endpoints. Metabolite nodes
// stay out of Path Query because they are simply not in the relationship
// list (MEMBER_OF/CONNECTED_WITH-mediated bridges made results unreadable --
// see git history); no label filter is needed.
//
// pathLimit bounds enumeration: ties are common here, and a pair can have
// thousands of equally-short routes. Cypher applies LIMIT lazily, so the
// query stops as soon as it has enough. Hitting the limit sets Truncated --
// more paths of the same length exist, they just are not drawn.
//
// No APOC needed. maxHops is interpolated (Cypher cannot parameterize a
// variable-length bound); it is the maxPathHops constant, never user input.
func shortestPathEdgesQuery(maxHops int) string {
	return fmt.Sprintf(`
		MATCH (a {Lab_ID: $fromId}), (b {Lab_ID: $toId})
		MATCH p = allShortestPaths((a)-[:INVESTIGATED|REPORTED_IN|SIMILAR_TO*..%d]-(b))
		WITH p LIMIT $pathLimit
		WITH collect(p) AS paths
		WITH paths, size(paths) AS pathCount
		UNWIND paths AS p
		UNWIND relationships(p) AS r
		WITH pathCount, collect(DISTINCT r) AS rels
		UNWIND rels AS r
		RETURN startNode(r).Lab_ID AS from_id, endNode(r).Lab_ID AS to_id,
		       type(r) AS rel_type, properties(r) AS rel_props, pathCount
	`, maxHops)
}

// shortestHopsQuery answers "are fromID and toID connected within maxHops,
// and if so how many hops apart" using Neo4j's native shortestPath -- a
// bidirectional search that expands simultaneously from both ends and stops
// the moment the two frontiers meet, rather than exploring the full radius
// of a single side.
//
// This matters a lot on a graph this size: exploring outward from just one
// node to radius maxHops visits roughly branchingFactor^maxHops nodes, while
// meeting in the middle from both ends visits roughly
// 2 * branchingFactor^(maxHops/2) -- for a SIMILAR_TO fan-out in the low
// hundreds, the one-sided radius-5 ball around a well-studied phenotype now
// covers ~13,700 of the graph's 13,756 nodes -- which is exactly why the old
// one-sided visualization fetch had to be replaced (see
// shortestPathEdgesQuery). The bidirectional search below has no cap and
// stays cheap regardless of graph size, because its cost depends on
// maxHops/2, not maxHops -- this is the query that decides connectivity and
// hop count, full stop.
//
// maxHops has to be interpolated into the pattern (Cypher's variable-length
// relationship bound isn't parameterizable) -- safe here because it is the
// maxPathHops constant, never raw user input.
func shortestHopsQuery(maxHops int) string {
	return fmt.Sprintf(`
		MATCH (a {Lab_ID: $fromId}), (b {Lab_ID: $toId})
		OPTIONAL MATCH p = shortestPath((a)-[:INVESTIGATED|REPORTED_IN|SIMILAR_TO*..%d]-(b))
		RETURN length(p) AS hops
	`, maxHops)
}

// maxShortestPaths bounds how many equally-short routes the visualization
// query enumerates. A 5-hop path has 6 nodes, and consecutive shortest paths
// overlap heavily, so this typically renders as a few dozen distinct nodes --
// legible, and a hard ceiling on how much work Neo4j does per request. If it
// is hit, Truncated is set: more routes of the same length exist.
const maxShortestPaths = 60

// maxPathHops is the safety bound on the variable-length patterns below.
// It is not a user-facing setting: Path Query answers "what is the shortest
// connection between these two entities", so capping the search shorter than
// the graph's own diameter would only manufacture false "not connected"
// answers. In this graph 99.7% of phenotype pairs sit within 8 hops (and
// 82.9% at exactly 5 -- Phenotype-Study-Module-Module-Study-Phenotype is the
// structural minimum once Metabolite is excluded), so 10 is effectively "no
// limit" while still keeping the pattern bounded.
const maxPathHops = 10

func (db *DB) lookupNodeName(ctx context.Context, label, id string) (string, bool, error) {
	rows, err := db.query(ctx, nodeLookupQuery, map[string]any{"id": id, "label": label})
	if err != nil {
		return "", false, err
	}
	if len(rows) == 0 {
		return "", false, nil
	}
	return asString(rows[0]["name"]), true, nil
}

// edgeWeight derives a 0-1 rendering weight for an edge from whatever
// strength signal its relationship type carries. SIMILAR_TO is the only
// relationship type left in this schema (now that Metabolite -- and with
// it MEMBER_OF -- is excluded from Path Query entirely) with a real
// strength value; INVESTIGATED/REPORTED_IN get a flat mid-weight so they
// still render as a visible but clearly secondary connection.
func edgeWeight(relType string, props map[string]any) float64 {
	if relType == "SIMILAR_TO" {
		if v, ok := props["Similarity_Score"]; ok {
			return clamp01(asFloat64(v))
		}
		return 0.5
	}
	return 0.45
}

func clamp01(v float64) float64 {
	if v < 0 {
		return 0
	}
	if v > 1 {
		return 1
	}
	return v
}

// FindPathGraph resolves the connection subgraph between two nodes: it
// settles connectivity and the exact hop count with one cheap bidirectional
// shortestPath, then, if they are connected, fetches the relationships that
// actually lie on shortest routes between them (see shortestPathEdgesQuery).
// Every edge it returns is on a shortest path by construction -- there is no
// local distance bookkeeping and no node-count cap to fall foul of.
func (db *DB) FindPathGraph(ctx context.Context, fromLabel, fromID, toLabel, toID string) (*PathGraph, error) {
	maxHops := maxPathHops

	fromName, fromOK, err := db.lookupNodeName(ctx, fromLabel, fromID)
	if err != nil {
		return nil, err
	}
	toName, toOK, err := db.lookupNodeName(ctx, toLabel, toID)
	if err != nil {
		return nil, err
	}
	if !fromOK || !toOK {
		return &PathGraph{Nodes: []PathGraphNode{}, Edges: []PathGraphEdge{}}, nil
	}

	// Decide connectivity and true hop count first, with the cheap
	// bidirectional query -- before spending anything on the (much more
	// expensive) full subgraph fetch below. If the two nodes simply aren't
	// connected within maxHops, this is the entire query: no point walking
	// a multi-thousand-node neighborhood just to confirm a "no".
	hopsRows, err := db.query(ctx, shortestHopsQuery(maxHops), map[string]any{
		"fromId": fromID,
		"toId":   toID,
	})
	if err != nil {
		return nil, err
	}
	var hops *int64
	if len(hopsRows) > 0 && hopsRows[0]["hops"] != nil {
		h := asInt64(hopsRows[0]["hops"])
		hops = &h
	}
	if hops == nil {
		return &PathGraph{
			Nodes: []PathGraphNode{
				{Label: fromLabel, ID: fromID, Name: fromName},
				{Label: toLabel, ID: toID, Name: toName},
			},
			Edges: []PathGraphEdge{},
			Hops:  nil,
		}, nil
	}

	rows, err := db.query(ctx, shortestPathEdgesQuery(maxHops), map[string]any{
		"fromId":    fromID,
		"toId":      toID,
		"pathLimit": int64(maxShortestPaths),
	})
	if err != nil {
		return nil, err
	}

	edges := make([]PathGraphEdge, 0, len(rows))
	touched := map[string]bool{fromID: true, toID: true}
	pathCount := 0
	for _, row := range rows {
		props, _ := row["rel_props"].(map[string]any)
		e := PathGraphEdge{
			From:  asString(row["from_id"]),
			To:    asString(row["to_id"]),
			Type:  asString(row["rel_type"]),
			Props: props,
			// Every edge here came out of allShortestPaths, so it is on a
			// shortest route by construction.
			OnShortestPath: true,
		}
		e.Weight = edgeWeight(e.Type, e.Props)
		edges = append(edges, e)
		touched[e.From] = true
		touched[e.To] = true
		if pc := int(asInt64(row["pathCount"])); pc > pathCount {
			pathCount = pc
		}
	}

	// More equally-short routes exist than we asked Neo4j to enumerate, so
	// the picture is a representative sample rather than the complete set.
	// The reported Hops is unaffected -- shortestHopsQuery settled that
	// exactly, with no cap of its own.
	truncated := pathCount >= maxShortestPaths

	// Heaviest edges first, purely for rendering order.
	sort.Slice(edges, func(i, j int) bool { return edges[i].Weight > edges[j].Weight })

	otherIDs := make([]string, 0, len(touched))
	for id := range touched {
		if id != fromID && id != toID {
			otherIDs = append(otherIDs, id)
		}
	}
	infoByID := make(map[string][2]string, len(otherIDs))
	if len(otherIDs) > 0 {
		infoRows, err := db.query(ctx, nodeInfoQuery, map[string]any{"ids": otherIDs})
		if err != nil {
			return nil, err
		}
		for _, row := range infoRows {
			infoByID[asString(row["id"])] = [2]string{asString(row["label"]), asString(row["name"])}
		}
	}

	nodes := make([]PathGraphNode, 0, len(touched))
	for id := range touched {
		var label, name string
		switch id {
		case fromID:
			label, name = fromLabel, fromName
		case toID:
			label, name = toLabel, toName
		default:
			if info, ok := infoByID[id]; ok {
				label, name = info[0], info[1]
			}
		}
		nodes = append(nodes, PathGraphNode{Label: label, ID: id, Name: name})
	}

	return &PathGraph{
		Nodes:     nodes,
		Edges:     edges,
		Hops:      hops,
		Truncated: truncated,
	}, nil
}

// asString/asInt64 are defined in search.go (shared across query-result
// parsing in this package).

func asFloat64(v any) float64 {
	switch x := v.(type) {
	case float64:
		return x
	case int64:
		return float64(x)
	default:
		return 1.0
	}
}
