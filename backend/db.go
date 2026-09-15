package main

import (
	"context"
	"fmt"
	"os"

	"github.com/neo4j/neo4j-go-driver/v5/neo4j"
)

// DB wraps a Neo4j driver and exposes a small query helper used by the
// HTTP handlers. Every Cypher query in this project returns only plain
// scalars and maps (never raw Node/Relationship objects), so decoding on
// the Go side stays simple and stable across driver versions.
type DB struct {
	driver   neo4j.DriverWithContext
	database string
}

func NewDB(ctx context.Context) (*DB, error) {
	uri := getenv("NEO4J_URI", "bolt://127.0.0.1:7687")
	user := getenv("NEO4J_USER", "neo4j")
	password := os.Getenv("NEO4J_PASSWORD")
	database := getenv("NEO4J_DATABASE", "neo4j")

	driver, err := neo4j.NewDriverWithContext(uri, neo4j.BasicAuth(user, password, ""))
	if err != nil {
		return nil, fmt.Errorf("create neo4j driver: %w", err)
	}
	if err := driver.VerifyConnectivity(ctx); err != nil {
		return nil, fmt.Errorf("connect to neo4j at %s: %w", uri, err)
	}
	return &DB{driver: driver, database: database}, nil
}

func (db *DB) Close(ctx context.Context) {
	_ = db.driver.Close(ctx)
}

// query runs a read Cypher statement and returns each record as a
// map[string]any, keyed by the RETURN aliases.
func (db *DB) query(ctx context.Context, cypher string, params map[string]any) ([]map[string]any, error) {
	result, err := neo4j.ExecuteQuery(
		ctx,
		db.driver,
		cypher,
		params,
		neo4j.EagerResultTransformer,
		neo4j.ExecuteQueryWithDatabase(db.database),
	)
	if err != nil {
		return nil, fmt.Errorf("run query: %w", err)
	}

	rows := make([]map[string]any, 0, len(result.Records))
	for _, record := range result.Records {
		rows = append(rows, record.AsMap())
	}
	return rows, nil
}

func getenv(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
