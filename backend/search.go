package main

import (
	"context"
	"fmt"
	"log"
	"regexp"
	"sort"
	"strings"
)

// SearchResult is one row in the autocomplete/search results list.
type SearchResult struct {
	Label    string `json:"label"`
	LabID    string `json:"lab_id"`
	Title    string `json:"title"`
	Subtitle string `json:"subtitle"`
	// Extra is a second, label-specific detail column (e.g. Phenotype's OLS
	// ID, Metabolite's KEGG ID). Empty string if the label has none.
	Extra string `json:"extra"`
}

// SearchResponse is the GET /api/search response body: one page of results
// plus the true total match count, so the frontend can render "page X of Y"
// / "N results" without a separate count query.
type SearchResponse struct {
	Results  []SearchResult `json:"results"`
	Total    int            `json:"total"`
	Page     int            `json:"page"`
	PageSize int            `json:"page_size"`
}

// idFieldNormalize controls how the user's query is compared against an
// ID-style property. We normalize the *query* (lower/upper) rather than
// wrapping the indexed property in a function, so the comparison stays
// index-friendly if a text index is ever added on these fields.
type idFieldNormalize string

const (
	normLower idFieldNormalize = "lower"
	normUpper idFieldNormalize = "upper"
	normRaw   idFieldNormalize = "raw"
)

// idField is one exact/ID-style property to match against (accession,
// HMDB/KEGG/InChI ID, OLS ID, PhenoMAP Lab_ID, ...).
type idField struct {
	expr string // Cypher expression for the property, e.g. "coalesce(n.Accession,'')"
	norm idFieldNormalize
}

func (f idField) clause() string {
	switch f.norm {
	case normUpper:
		return fmt.Sprintf("toUpper(%s) CONTAINS $qUpper", f.expr)
	case normRaw:
		return fmt.Sprintf("%s CONTAINS $qRaw", f.expr)
	default:
		return fmt.Sprintf("toLower(%s) CONTAINS $q", f.expr)
	}
}

// labelSpec describes, for one node label, how free-text relevance search
// (a Neo4j fulltext index) and exact/ID-style search (CONTAINS) combine,
// plus how to render a result row.
type labelSpec struct {
	fulltextIndex string // "" if this label has no fulltext index
	idFields      []idField
	titleExpr     string
	subtitleExpr  string
	extraExpr     string // second detail column; "''" (empty literal) if unused
}

// labSpecs is the single source of truth for "what does search match, per
// entity type":
//   - Study: accession, title
//   - Module: title
//   - Phenotype: name, OLS ID
//   - Metabolite: name, HMDB ID, KEGG ID, InChI ID
//   - every label additionally matches its PhenoMAP Lab_ID
func labSpecs() map[string]labelSpec {
	labID := idField{expr: "coalesce(n.Lab_ID,'')", norm: normLower}
	return map[string]labelSpec{
		"Study": {
			fulltextIndex: "study_fulltext",
			idFields: []idField{
				{expr: "coalesce(n.Accession,'')", norm: normLower},
				labID,
			},
			titleExpr:    "coalesce(n.Title,'')",
			subtitleExpr: "coalesce(n.Accession,'')",
			extraExpr:    "''",
		},
		"Module": {
			fulltextIndex: "module_fulltext",
			idFields:      []idField{labID},
			titleExpr:     "coalesce(n.title, n.module_id, '')",
			subtitleExpr:  "coalesce(n.hypothesis_type,'')",
			extraExpr:     "''",
		},
		"Phenotype": {
			fulltextIndex: "phenotype_fulltext",
			idFields: []idField{
				{expr: "coalesce(n.OLS_ID,'')", norm: normLower},
				labID,
			},
			titleExpr:    "coalesce(n.Phenotype,'')",
			subtitleExpr: "coalesce(n.Type,'')",
			extraExpr:    "coalesce(n.OLS_ID,'')",
		},
		"Metabolite": {
			fulltextIndex: "metabolite_fulltext",
			idFields: []idField{
				{expr: "coalesce(n.HMDB_ID,'')", norm: normUpper},
				{expr: "coalesce(n.KEGG_ID,'')", norm: normUpper},
				{expr: "coalesce(n.INCHI_ID,'')", norm: normRaw},
				labID,
			},
			titleExpr:    "coalesce(n.Metabolite_Name,'')",
			subtitleExpr: "coalesce(n.HMDB_ID,'')",
			extraExpr:    "coalesce(n.KEGG_ID,'')",
		},
	}
}

var allLabels = []string{"Study", "Phenotype", "Module", "Metabolite"}

// fulltextIndexDefs is used once at startup to create/keep the Neo4j
// fulltext indexes in sync with labSpecs(). Kept separate so index
// provisioning doesn't need to run on every search request.
var fulltextIndexDefs = []struct {
	name  string
	label string
	field string
}{
	{"study_fulltext", "Study", "Title"},
	{"module_fulltext", "Module", "title"},
	{"phenotype_fulltext", "Phenotype", "Phenotype"},
	{"metabolite_fulltext", "Metabolite", "Metabolite_Name"},
}

// labIDIndexDefs is a regular (btree) index per label on Lab_ID -- separate
// from the fulltext indexes above. It backs the "browse everything, sorted
// by Lab_ID" list (see Browse below): with this index, ORDER BY n.Lab_ID
// SKIP/LIMIT is an indexed ordered scan instead of Neo4j sorting the whole
// label in memory on every page request.
var labIDIndexDefs = []struct {
	name  string
	label string
}{
	{"study_lab_id", "Study"},
	{"phenotype_lab_id", "Phenotype"},
	{"module_lab_id", "Module"},
	{"metabolite_lab_id", "Metabolite"},
}

// EnsureSearchIndexes creates the fulltext + Lab_ID indexes backing search
// and browse if they don't already exist yet, and waits for them to come
// online. Safe to call every time the backend starts (IF NOT EXISTS makes it
// a no-op on subsequent runs).
func (db *DB) EnsureSearchIndexes(ctx context.Context) error {
	for _, def := range fulltextIndexDefs {
		cypher := fmt.Sprintf(
			"CREATE FULLTEXT INDEX %s IF NOT EXISTS FOR (n:%s) ON EACH [n.%s]",
			def.name, def.label, def.field,
		)
		if _, err := db.query(ctx, cypher, nil); err != nil {
			return fmt.Errorf("create fulltext index %s: %w", def.name, err)
		}
	}
	for _, def := range labIDIndexDefs {
		cypher := fmt.Sprintf(
			"CREATE INDEX %s IF NOT EXISTS FOR (n:%s) ON (n.Lab_ID)",
			def.name, def.label,
		)
		if _, err := db.query(ctx, cypher, nil); err != nil {
			return fmt.Errorf("create index %s: %w", def.name, err)
		}
	}
	if _, err := db.query(ctx, "CALL db.awaitIndexes()", nil); err != nil {
		return fmt.Errorf("await indexes: %w", err)
	}
	return nil
}

var luceneSpecial = regexp.MustCompile(`([+\-!(){}\[\]^"~*?:\\/&|])`)

// buildFulltextQuery turns free-typed user input into a Lucene query that
// prefix-matches every whitespace-separated term -- e.g. "ulcerative col"
// becomes `ulcerative* AND col*` -- so partial, still-being-typed, and
// multi-word queries match sensibly, instead of requiring the whole input
// to appear as one contiguous substring.
func buildFulltextQuery(q string) string {
	terms := strings.Fields(q)
	parts := make([]string, 0, len(terms))
	for _, t := range terms {
		esc := luceneSpecial.ReplaceAllString(t, `\$1`)
		if esc == "" {
			continue
		}
		parts = append(parts, esc+"*")
	}
	return strings.Join(parts, " AND ")
}

type scoredResult struct {
	SearchResult
	score float64
}

// idMatchScore is a flat score high enough to always outrank fulltext
// relevance scores (small floats), so exact/ID hits surface above fuzzy
// name matches -- searching an HMDB ID should never be out-ranked by a
// loosely-related name match.
const idMatchScore = 1_000_000

// candidateCap bounds how many candidate rows each underlying Cypher query
// (ID match, fulltext match) is allowed to pull from Neo4j before Go-side
// merge/sort/paginate. It is intentionally much larger than any page size --
// it exists only as a safety ceiling so a pathological query (e.g. a single
// common letter) can't pull the entire label into memory, not as the page
// size. Pagination always reflects the true total up to this ceiling.
const candidateCap = 500

// Search looks up nodes across one label (if given) or all four labels,
// combining fulltext relevance search (on name/title fields, ranked by
// Neo4j's Lucene score) with case-normalized CONTAINS search on ID-style
// fields (accession, HMDB/KEGG/InChI ID, OLS ID, and every label's PhenoMAP
// Lab_ID). Results are deduped by Lab_ID and sorted so ID matches come
// first, then fulltext matches by relevance.
//
// offset/pageSize select a page out of the full (deduped, sorted) match
// list; total is the true number of matches found (up to candidateCap), so
// callers can render "page X of Y" / "N results" without a second query.
//
// Note: pagination is applied per label independently. When label == "" (all
// four types searched at once), offset/pageSize/total are each computed
// per-label and summed, not across one globally-ranked list -- fine for the
// current UI, which always searches one label at a time.
func (db *DB) Search(ctx context.Context, q string, label string, offset, pageSize int) (results []SearchResult, total int, err error) {
	// Start from an empty (non-nil) slice: a nil slice is encoded as JSON
	// null, and the frontend reads results.length -- which crashed the
	// Entity Search page and the Path Query picker into a blank page when a
	// query had no matches for the selected type.
	results = []SearchResult{}
	labels := allLabels
	if label != "" {
		labels = []string{label}
	}
	specs := labSpecs()

	trimmed := strings.TrimSpace(q)
	params := map[string]any{
		"q":      strings.ToLower(trimmed),
		"qUpper": strings.ToUpper(trimmed),
		"qRaw":   trimmed,
		"limit":  int64(candidateCap),
	}
	fulltextQuery := buildFulltextQuery(trimmed)

	for _, l := range labels {
		spec, ok := specs[l]
		if !ok {
			continue
		}
		merged := map[string]scoredResult{}

		// -- ID / exact-style matches --
		if len(spec.idFields) > 0 {
			clauses := make([]string, len(spec.idFields))
			for i, f := range spec.idFields {
				clauses[i] = f.clause()
			}
			cypher := fmt.Sprintf(
				`MATCH (n:%s) WHERE %s
				 RETURN n.Lab_ID AS lab_id, %s AS title, %s AS subtitle, %s AS extra
				 LIMIT $limit`,
				l, strings.Join(clauses, " OR "), spec.titleExpr, spec.subtitleExpr, spec.extraExpr,
			)
			rows, qErr := db.query(ctx, cypher, params)
			if qErr != nil {
				return nil, 0, fmt.Errorf("id search (%s): %w", l, qErr)
			}
			for _, row := range rows {
				labID := asString(row["lab_id"])
				merged[labID] = scoredResult{
					SearchResult: SearchResult{Label: l, LabID: labID, Title: asString(row["title"]), Subtitle: asString(row["subtitle"]), Extra: asString(row["extra"])},
					score:        idMatchScore,
				}
			}
		}

		// -- fulltext relevance matches --
		if spec.fulltextIndex != "" && fulltextQuery != "" {
			cypher := fmt.Sprintf(
				`CALL db.index.fulltext.queryNodes('%s', $fulltextQuery) YIELD node AS n, score
				 RETURN n.Lab_ID AS lab_id, %s AS title, %s AS subtitle, %s AS extra, score AS score
				 LIMIT $limit`,
				spec.fulltextIndex, spec.titleExpr, spec.subtitleExpr, spec.extraExpr,
			)
			ftParams := map[string]any{"fulltextQuery": fulltextQuery, "limit": int64(candidateCap)}
			rows, qErr := db.query(ctx, cypher, ftParams)
			if qErr != nil {
				// The index may not exist yet (e.g. backend hasn't run
				// EnsureSearchIndexes against this database) -- degrade to
				// ID-only search instead of failing the whole request.
				log.Printf("fulltext search skipped for %s: %v", l, qErr)
			} else {
				for _, row := range rows {
					labID := asString(row["lab_id"])
					score := asFloat(row["score"])
					if existing, ok := merged[labID]; ok && existing.score >= score {
						continue // already have this node via a higher/equal-scoring match
					}
					merged[labID] = scoredResult{
						SearchResult: SearchResult{Label: l, LabID: labID, Title: asString(row["title"]), Subtitle: asString(row["subtitle"]), Extra: asString(row["extra"])},
						score:        score,
					}
				}
			}
		}

		rows := make([]scoredResult, 0, len(merged))
		for _, r := range merged {
			rows = append(rows, r)
		}
		sort.Slice(rows, func(i, j int) bool { return rows[i].score > rows[j].score })

		total += len(rows)

		start := offset
		if start > len(rows) {
			start = len(rows)
		}
		end := start + pageSize
		if end > len(rows) {
			end = len(rows)
		}
		for _, r := range rows[start:end] {
			results = append(results, r.SearchResult)
		}
	}
	return results, total, nil
}

// Browse lists every node of a given label, sorted by Lab_ID, paginated --
// used when the search box is empty so the page isn't just blank. Only
// pageSize rows are ever fetched per call (SKIP/LIMIT, backed by the Lab_ID
// index from EnsureSearchIndexes), so this stays cheap regardless of how
// many nodes exist for the label.
func (db *DB) Browse(ctx context.Context, label string, offset, pageSize int) ([]SearchResult, int, error) {
	spec, ok := labSpecs()[label]
	if !ok {
		return nil, 0, fmt.Errorf("unknown label: %s", label)
	}

	countRows, err := db.query(ctx, fmt.Sprintf("MATCH (n:%s) RETURN count(n) AS total", label), nil)
	if err != nil {
		return nil, 0, fmt.Errorf("browse count (%s): %w", label, err)
	}
	total := 0
	if len(countRows) > 0 {
		total = int(asInt64(countRows[0]["total"]))
	}

	cypher := fmt.Sprintf(
		`MATCH (n:%s)
		 RETURN n.Lab_ID AS lab_id, %s AS title, %s AS subtitle, %s AS extra
		 ORDER BY n.Lab_ID
		 SKIP $offset LIMIT $pageSize`,
		label, spec.titleExpr, spec.subtitleExpr, spec.extraExpr,
	)
	rows, err := db.query(ctx, cypher, map[string]any{"offset": int64(offset), "pageSize": int64(pageSize)})
	if err != nil {
		return nil, 0, fmt.Errorf("browse (%s): %w", label, err)
	}

	results := make([]SearchResult, 0, len(rows))
	for _, row := range rows {
		results = append(results, SearchResult{
			Label:    label,
			LabID:    asString(row["lab_id"]),
			Title:    asString(row["title"]),
			Subtitle: asString(row["subtitle"]),
			Extra:    asString(row["extra"]),
		})
	}
	return results, total, nil
}

func asString(v any) string {
	if v == nil {
		return ""
	}
	s, _ := v.(string)
	return s
}

func asFloat(v any) float64 {
	if v == nil {
		return 0
	}
	switch n := v.(type) {
	case float64:
		return n
	case int64:
		return float64(n)
	}
	return 0
}

func asInt64(v any) int64 {
	if v == nil {
		return 0
	}
	i, _ := v.(int64)
	return i
}
