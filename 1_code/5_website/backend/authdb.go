package main

import (
	"context"
	"database/sql"
	"fmt"

	_ "modernc.org/sqlite"
)

// AuthDB is a small SQLite-backed store for accounts, sessions, and email
// verification tokens. Kept separate from Neo4j on purpose -- accounts
// are relational, not graph data, and SQLite needs zero extra services
// to run locally (a single file, pure-Go driver, no CGO).
type AuthDB struct {
	db *sql.DB
}

func NewAuthDB() (*AuthDB, error) {
	path := getenv("AUTH_DB_PATH", "phenomap_auth.db")
	db, err := sql.Open("sqlite", path)
	if err != nil {
		return nil, fmt.Errorf("open auth db: %w", err)
	}
	if err := db.Ping(); err != nil {
		return nil, fmt.Errorf("ping auth db: %w", err)
	}

	schema := `
	CREATE TABLE IF NOT EXISTS users (
		id TEXT PRIMARY KEY,
		email TEXT UNIQUE NOT NULL,
		password_hash TEXT NOT NULL,
		display_name TEXT NOT NULL,
		institution TEXT NOT NULL DEFAULT '',
		country TEXT NOT NULL DEFAULT '',
		role TEXT NOT NULL DEFAULT 'user',
		email_verified INTEGER NOT NULL DEFAULT 0,
		created_at TEXT NOT NULL DEFAULT (datetime('now'))
	);
	CREATE TABLE IF NOT EXISTS sessions (
		token TEXT PRIMARY KEY,
		user_id TEXT NOT NULL REFERENCES users(id),
		created_at TEXT NOT NULL DEFAULT (datetime('now')),
		expires_at TEXT NOT NULL
	);
	CREATE TABLE IF NOT EXISTS email_verifications (
		token TEXT PRIMARY KEY,
		user_id TEXT NOT NULL REFERENCES users(id),
		created_at TEXT NOT NULL DEFAULT (datetime('now')),
		expires_at TEXT NOT NULL
	);
	CREATE TABLE IF NOT EXISTS password_resets (
		token TEXT PRIMARY KEY,
		user_id TEXT NOT NULL REFERENCES users(id),
		created_at TEXT NOT NULL DEFAULT (datetime('now')),
		expires_at TEXT NOT NULL
	);
	CREATE TABLE IF NOT EXISTS email_changes (
		token TEXT PRIMARY KEY,
		user_id TEXT NOT NULL REFERENCES users(id),
		new_email TEXT NOT NULL,
		created_at TEXT NOT NULL DEFAULT (datetime('now')),
		expires_at TEXT NOT NULL
	);
		CREATE TABLE IF NOT EXISTS account_deletions (
			token TEXT PRIMARY KEY,
			user_id TEXT NOT NULL REFERENCES users(id),
			created_at TEXT NOT NULL DEFAULT (datetime('now')),
			expires_at TEXT NOT NULL
		);
		CREATE TABLE IF NOT EXISTS chat_daily_usage (
			user_id TEXT NOT NULL REFERENCES users(id),
			usage_date TEXT NOT NULL,
			official_free_count INTEGER NOT NULL DEFAULT 0,
			PRIMARY KEY (user_id, usage_date)
		);
		`
	if _, err := db.ExecContext(context.Background(), schema); err != nil {
		return nil, fmt.Errorf("create auth schema: %w", err)
	}

	// Older databases created before profile fields existed won't have
	// these columns -- CREATE TABLE IF NOT EXISTS above is a no-op for
	// them, so add missing columns here.
	if err := addUserTextColumnIfMissing(db, "institution"); err != nil {
		return nil, fmt.Errorf("migrate auth schema: %w", err)
	}
	if err := addUserTextColumnIfMissing(db, "country"); err != nil {
		return nil, fmt.Errorf("migrate auth schema: %w", err)
	}

	return &AuthDB{db: db}, nil
}

func addUserTextColumnIfMissing(db *sql.DB, column string) error {
	rows, err := db.Query(`PRAGMA table_info(users)`)
	if err != nil {
		return err
	}
	defer rows.Close()

	hasColumn := false
	for rows.Next() {
		var cid int
		var name, colType string
		var notNull, pk int
		var dflt sql.NullString
		if err := rows.Scan(&cid, &name, &colType, &notNull, &dflt, &pk); err != nil {
			return err
		}
		if name == column {
			hasColumn = true
		}
	}
	if err := rows.Err(); err != nil {
		return err
	}
	if hasColumn {
		return nil
	}
	_, err = db.Exec(fmt.Sprintf(`ALTER TABLE users ADD COLUMN %s TEXT NOT NULL DEFAULT ''`, column))
	return err
}

func (a *AuthDB) Close() error {
	return a.db.Close()
}
