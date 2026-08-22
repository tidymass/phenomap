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
	// Truncated is set if the visited-node safety cap during traversal was
	// hit -- the graph shown may be missing some legitimate connections for a
	// very well-connected endpoint (e.g. a Module with a huge SIMILAR_TO
	// neighborhood).
	Truncated bool `json:"truncated"`
}

// rawEdge is one relationship as fetched from Neo4j, before any filtering.
type rawEdge struct {
	From, To, Type string
	Props          map[string]any
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

// subgraphRelationshipsQuery fetches the complete induced subgraph -- every
// relationship between any two nodes both within maxLevel hops of the seed
// -- via APOC's apoc.path.subgraphAll, in one native call.
//
// This is the single source of truth for the whole connection graph: every
// downstream computation (distance from fromID, distance from toID, which
// edges qualify as "between" the two endpoints) is derived in Go from
// exactly this edge set, rather than from separate Neo4j calls. That matters
// because two independent APOC traversals over the same seed/config aren't
// guaranteed to explore in the same order or hit their `limit` cap at the
// same point -- an earlier version of this file ran a *separate*
// apoc.path.expandConfig call (just for fromID's own distance table) and
// this subgraphAll call side by side, and on well-connected pairs they could
// genuinely disagree about which nodes got reached before truncation, which
// showed up as an endpoint the backend confidently reported "5 hops" to but
// then rendered with zero edges anywhere near it. Computing every distance
// locally, over this one fetched edge set, makes that kind of disagreement
// structurally impossible: there's only one edge set anything downstream can
// see.
//
// labelFilter: '-Metabolite' walls Metabolite nodes off from the traversal
// entirely (see git history for why -- MEMBER_OF/CONNECTED_WITH-mediated
// bridges between otherwise-unrelated nodes turned out to make results
// unreadable). Path Query's connection graph stays on the curated
// Study/Phenotype/Module backbone: INVESTIGATED, REPORTED_IN, SIMILAR_TO.
//
// limit caps how many nodes the traversal will expand to, as a safety valve
// against an extremely well-connected seed -- see maxBFSVisited.
//
// Requires the APOC Core plugin (see RUNBOOK.md).
const subgraphRelationshipsQuery = `
	MATCH (start {Lab_ID: $id})
	CALL apoc.path.subgraphAll(start, {
		maxLevel: $maxHops,
		labelFilter: '-Metabolite',
		limit: $limit
	}) YIELD nodes, relationships
	WITH relationships, size(nodes) AS nodeCount
	UNWIND relationships AS r
	RETURN startNode(r).Lab_ID AS from_id, endNode(r).Lab_ID AS to_id,
	       type(r) AS rel_type, properties(r) AS rel_props, nodeCount
`

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
// tens, the one-sided radius-5 ball around a well-studied phenotype already
// exceeds the old maxBFSVisited safety cap (confirmed against the current
// graph: several phenotypes' 5-hop neighborhoods run 4000-4800+ nodes,
// meaning "no connection found" was sometimes a false negative from hitting
// that cap, not an actual absence of a path). The bidirectional search below
// has no such cap and stays cheap regardless of graph size, because its cost
// depends on maxHops/2, not maxHops -- this is the query that should decide
// connectivity and hop count, full stop.
//
// maxHops has to be interpolated into the pattern (Cypher's variable-length
// relationship bound isn't parameterizable) -- safe here because maxHops is
// an int clamped server-side in FindPathGraph, never raw user input.
func shortestHopsQuery(maxHops int) string {
	return fmt.Sprintf(`
		MATCH (a {Lab_ID: $fromId}), (b {Lab_ID: $toId})
		OPTIONAL MATCH p = shortestPath((a)-[:INVESTIGATED|REPORTED_IN|SIMILAR_TO*..%d]-(b))
		RETURN length(p) AS hops
	`, maxHops)
}

// maxBFSVisited caps how many nodes the *visualization* subgraph fetch
// (subgraphRelationshipsQuery, below) will expand to. It is no longer what
// decides whether two nodes are connected -- shortestHopsQuery answers that
// cheaply and exactly, with no cap of its own. This constant only bounds how
// much of the connection subgraph gets rendered once we already know a path
// exists: if it's hit, Truncated is set and some legitimate edges near a
// very well-connected endpoint may be missing from the picture, but the
// reported Hops count and the yes/no answer are unaffected either way.
const maxBFSVisited = 8000

const defaultPathHops = 5
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

// buildAdjacency turns a flat edge list into an undirected adjacency list
// (every relationship in this schema is matched undirected elsewhere too).
func buildAdjacency(edges []rawEdge) map[string][]string {
	adj := make(map[string][]string, len(edges)*2)
	for _, e := range edges {
		adj[e.From] = append(adj[e.From], e.To)
		adj[e.To] = append(adj[e.To], e.From)
	}
	return adj
}

// bfsLocal computes shortest hop distance from seedID to every node
// reachable within maxHops, over an already-fetched in-memory adjacency
// list -- a plain, ordinary BFS, safe to run in Go since it's operating on
// a small, already-bounded edge set (at most maxBFSVisited nodes' worth of
// relationships) rather than querying Neo4j.
func bfsLocal(seedID string, adj map[string][]string, maxHops int) map[string]int {
	dist := map[string]int{seedID: 0}
	queue := []string{seedID}
	for len(queue) > 0 {
		cur := queue[0]
		queue = queue[1:]
		if dist[cur] >= maxHops {
			continue
		}
		for _, next := range adj[cur] {
			if _, seen := dist[next]; seen {
				continue
			}
			dist[next] = dist[cur] + 1
			queue = append(queue, next)
		}
	}
	return dist
}

// combinedDistance returns the length of the shortest known a-b walk that
// passes directly through edge (u, v), trying both orientations since
// every relationship in this schema is matched undirected. false means
// neither orientation stays within maxHops using the two distance tables.
func combinedDistance(u, v string, distA, distB map[string]int, maxHops int) (int, bool) {
	best := -1
	consider := func(x, y string) {
		dx, ok1 := distA[x]
		dy, ok2 := distB[y]
		if !ok1 || !ok2 {
			return
		}
		total := dx + 1 + dy
		if total <= maxHops && (best == -1 || total < best) {
			best = total
		}
	}
	consider(u, v)
	consider(v, u)
	if best == -1 {
		return 0, false
	}
	return best, true
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

// FindPathGraph resolves the connection subgraph between two nodes. It
// fetches the complete induced subgraph within maxHops of fromID in one
// APOC call, computes both endpoints' shortest distances locally over that
// same fetched edge set (see bfsLocal), and keeps every edge that could sit
// on some fromID<->toID walk no longer than maxHops.
func (db *DB) FindPathGraph(ctx context.Context, fromLabel, fromID, toLabel, toID string, maxHops int) (*PathGraph, error) {
	if maxHops < 1 {
		maxHops = 1
	}
	// Keep path queries bounded even if callers bypass the frontend dropdown.
	// 10 hops covers the structural Phenotype-Study-Module-...-Module-Study-
	// Phenotype cases while keeping traversal and route enumeration tractable.
	if maxHops > maxPathHops {
		maxHops = maxPathHops
	}

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

	rows, err := db.query(ctx, subgraphRelationshipsQuery, map[string]any{
		"id":      fromID,
		"maxHops": int64(maxHops),
		"limit":   int64(maxBFSVisited),
	})
	if err != nil {
		return nil, err
	}

	rawEdges := make([]rawEdge, 0, len(rows))
	nodeCount := 0
	for _, row := range rows {
		props, _ := row["rel_props"].(map[string]any)
		rawEdges = append(rawEdges, rawEdge{
			From:  asString(row["from_id"]),
			To:    asString(row["to_id"]),
			Type:  asString(row["rel_type"]),
			Props: props,
		})
		if nc := int(asInt64(row["nodeCount"])); nc > nodeCount {
			nodeCount = nc
		}
	}
	// subgraphAll's limit caps the induced subgraph at maxBFSVisited nodes;
	// hitting that exactly is the signal that fromID's neighborhood is
	// larger than what got explored, so the *visualization* may be missing
	// some legitimate edges. It no longer means the connection itself is in
	// doubt -- shortestHopsQuery above already settled that with an exact,
	// uncapped answer, so a truncated fetch here just means "fewer edges
	// drawn," never "path might not exist."
	truncated := len(rawEdges) > 0 && nodeCount >= maxBFSVisited

	adj := buildAdjacency(rawEdges)
	distA := bfsLocal(fromID, adj, maxHops)
	distB := bfsLocal(toID, adj, maxHops)

	type candidateEdge struct {
		edge           PathGraphEdge
		total          int
		onShortestPath bool
	}
	kept := make([]candidateEdge, 0, len(rawEdges))

	for _, e := range rawEdges {
		total, ok := combinedDistance(e.From, e.To, distA, distB, maxHops)
		if !ok {
			continue
		}
		onShortest := hops != nil && int64(total) == *hops
		kept = append(kept, candidateEdge{
			edge: PathGraphEdge{
				From:   e.From,
				To:     e.To,
				Type:   e.Type,
				Props:  e.Props,
				Weight: edgeWeight(e.Type, e.Props),
			},
			total:          total,
			onShortestPath: onShortest,
		})
	}

	// True-shortest-path edges always come first, then highest weight, then
	// shortest total distance. There is intentionally no final edge-count cap:
	// the visualization should reflect the complete qualifying connection
	// subgraph returned by the bounded traversal.
	sort.Slice(kept, func(i, j int) bool {
		if kept[i].onShortestPath != kept[j].onShortestPath {
			return kept[i].onShortestPath
		}
		if kept[i].edge.Weight != kept[j].edge.Weight {
			return kept[i].edge.Weight > kept[j].edge.Weight
		}
		return kept[i].total < kept[j].total
	})

	touched := map[string]bool{fromID: true, toID: true}
	edges := make([]PathGraphEdge, 0, len(kept))
	for _, ce := range kept {
		ce.edge.OnShortestPath = ce.onShortestPath
		edges = append(edges, ce.edge)
		touched[ce.edge.From] = true
		touched[ce.edge.To] = true
	}

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
