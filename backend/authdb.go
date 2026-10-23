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
		CREATE TABLE IF NOT EXISTS community_submissions (
			seq INTEGER PRIMARY KEY AUTOINCREMENT,
			id TEXT NOT NULL DEFAULT '',
			user_id TEXT NOT NULL REFERENCES users(id),
			title TEXT NOT NULL,
			phenotype TEXT NOT NULL,
			phenotype_id TEXT NOT NULL DEFAULT '',
			study_design TEXT NOT NULL,
			sample_size INTEGER NOT NULL,
			biospecimen TEXT NOT NULL,
			ms2_supported TEXT NOT NULL,
			chromatography TEXT NOT NULL,
			mass_spectrometry TEXT NOT NULL,
			summary TEXT NOT NULL,
			doi TEXT NOT NULL DEFAULT '',
			source_link TEXT NOT NULL DEFAULT '',
			contact_name TEXT NOT NULL,
			contact_email TEXT NOT NULL,
			notes TEXT NOT NULL DEFAULT '',
			status TEXT NOT NULL DEFAULT 'submitted',
			inclusion TEXT NOT NULL DEFAULT 'pending',
			phenomap_link TEXT NOT NULL DEFAULT '',
			admin_notes TEXT NOT NULL DEFAULT '',
			created_at TEXT NOT NULL DEFAULT (datetime('now')),
			updated_at TEXT NOT NULL DEFAULT (datetime('now'))
		);
		CREATE UNIQUE INDEX IF NOT EXISTS idx_community_submissions_id ON community_submissions(id);
		CREATE INDEX IF NOT EXISTS idx_community_submissions_user ON community_submissions(user_id);
		CREATE TABLE IF NOT EXISTS community_submission_files (
			id INTEGER PRIMARY KEY AUTOINCREMENT,
			submission_id TEXT NOT NULL REFERENCES community_submissions(id),
			file_key TEXT NOT NULL,
			original_name TEXT NOT NULL,
			stored_path TEXT NOT NULL,
			size_bytes INTEGER NOT NULL,
			created_at TEXT NOT NULL DEFAULT (datetime('now'))
		);
		CREATE INDEX IF NOT EXISTS idx_community_files_submission ON community_submission_files(submission_id);
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
