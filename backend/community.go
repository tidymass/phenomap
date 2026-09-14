package main

// community.go -- backend storage for the Community page's "submit study
// data" feature. Submissions and their file metadata live in the same
// SQLite database as accounts (see authdb.go): like accounts, a submission
// is relational bookkeeping, not graph data, so it doesn't belong in Neo4j.
// The uploaded files themselves are written to disk under
// communityUploadDir(), one directory per submission ID, and are only ever
// served back to the submitter (see handleDownloadSubmissionFile in
// community_handlers.go) -- there's no public browse/download path yet,
// since accepted studies aren't folded into the public graph until a
// curator has reviewed them (out of scope for this backend).

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"time"
)

// CommunitySubmissionFile is one uploaded file attached to a submission.
type CommunitySubmissionFile struct {
	Key       string `json:"key"`
	Name      string `json:"name"`
	SizeBytes int64  `json:"size_bytes"`
}

// CommunitySubmission is a study-data submission made through the
// Community page. Status/Inclusion/PhenomapLink start out at their zero
// values ("submitted" / "pending" / "") and are only ever changed by a
// curator reviewing the submission -- there's no API for that yet, since
// review is still a manual, offline process.
type CommunitySubmission struct {
	ID               string                    `json:"id"`
	UploadNumber     int64                     `json:"upload_number"`
	Title            string                    `json:"title"`
	Phenotype        string                    `json:"phenotype"`
	PhenotypeID      string                    `json:"phenotype_id"`
	StudyDesign      string                    `json:"study_design"`
	SampleSize       int                       `json:"sample_size"`
	Biospecimen      string                    `json:"biospecimen"`
	MS2Supported     string                    `json:"ms2_supported"`
	Chromatography   string                    `json:"chromatography"`
	MassSpectrometry string                    `json:"mass_spectrometry"`
	Summary          string                    `json:"summary"`
	DOI              string                    `json:"doi"`
	SourceLink       string                    `json:"source_link"`
	ContactName      string                    `json:"contact_name"`
	ContactEmail     string                    `json:"contact_email"`
	Notes            string                    `json:"notes"`
	Status           string                    `json:"status"`
	Inclusion        string                    `json:"inclusion"`
	PhenomapLink     string                    `json:"phenomap_link"`
	CreatedAt        string                    `json:"created_at"`
	Files            []CommunitySubmissionFile `json:"files"`
}

// CommunitySubmissionInput carries the new-submission form fields, already
// trimmed and validated by the HTTP handler.
type CommunitySubmissionInput struct {
	Title            string
	Phenotype        string
	PhenotypeID      string
	StudyDesign      string
	SampleSize       int
	Biospecimen      string
	MS2Supported     string
	Chromatography   string
	MassSpectrometry string
	Summary          string
	DOI              string
	SourceLink       string
	ContactName      string
	ContactEmail     string
	Notes            string
}

// uploadedFile is one incoming multipart file, already opened for reading.
type uploadedFile struct {
	Filename string
	Reader   io.Reader
}

var (
	ErrSubmissionNotFound = errors.New("submission not found")
	reUnsafeFilename      = regexp.MustCompile(`[^A-Za-z0-9._-]+`)
)

// submissionFileOrder fixes the order files are saved/returned in,
// regardless of multipart form field order.
var submissionFileOrder = []string{"feature_table", "sample_metadata", "metabolite_annotation"}

// communityUploadDir returns the directory uploaded study files are stored
// under, creating it if missing. Kept outside the repo's tracked data
// directories on purpose -- these are unreviewed third-party uploads, not
// curated PhenoMAP data.
func communityUploadDir() (string, error) {
	dir := getenv("COMMUNITY_UPLOAD_DIR", "community_uploads")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return "", fmt.Errorf("create community upload dir: %w", err)
	}
	return dir, nil
}

// sanitizeFilename strips any directory components and anything that
// isn't a safe filename character, so a crafted multipart filename (e.g.
// "../../etc/passwd") can never escape the submission's upload directory.
func sanitizeFilename(name string) string {
	base := filepath.Base(name)
	base = reUnsafeFilename.ReplaceAllString(base, "_")
	if base == "" || base == "." || base == ".." {
		base = "file"
	}
	return base
}

// CreateSubmission inserts a new submission owned by userID and saves its
// uploaded files to disk under a directory named after the submission's
// generated ID (SUB-<year>-<seq>). If anything fails after files start
// being written, already-saved files for this submission are removed on a
// best-effort basis so a half-written submission doesn't leave orphaned
// files behind.
func (a *AuthDB) CreateSubmission(ctx context.Context, userID string, in CommunitySubmissionInput, files map[string]uploadedFile) (*CommunitySubmission, error) {
	tx, err := a.db.BeginTx(ctx, nil)
	if err != nil {
		return nil, fmt.Errorf("begin submission tx: %w", err)
	}
	defer tx.Rollback()

	res, err := tx.ExecContext(ctx, `
		INSERT INTO community_submissions (
			user_id, title, phenotype, phenotype_id, study_design, sample_size,
			biospecimen, ms2_supported, chromatography, mass_spectrometry, summary,
			doi, source_link, contact_name, contact_email, notes
		) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		userID, in.Title, in.Phenotype, in.PhenotypeID, in.StudyDesign, in.SampleSize,
		in.Biospecimen, in.MS2Supported, in.Chromatography, in.MassSpectrometry, in.Summary,
		in.DOI, in.SourceLink, in.ContactName, in.ContactEmail, in.Notes,
	)
	if err != nil {
		return nil, fmt.Errorf("insert submission: %w", err)
	}
	seq, err := res.LastInsertId()
	if err != nil {
		return nil, fmt.Errorf("read submission seq: %w", err)
	}
	id := fmt.Sprintf("SUB-%d-%03d", time.Now().UTC().Year(), seq)
	if _, err := tx.ExecContext(ctx, `UPDATE community_submissions SET id = ? WHERE seq = ?`, id, seq); err != nil {
		return nil, fmt.Errorf("assign submission id: %w", err)
	}

	uploadDir, err := communityUploadDir()
	if err != nil {
		return nil, err
	}
	submissionDir := filepath.Join(uploadDir, id)
	if err := os.MkdirAll(submissionDir, 0o755); err != nil {
		return nil, fmt.Errorf("create submission dir: %w", err)
	}

	var savedPaths []string
	cleanupOnFailure := func() {
		for _, p := range savedPaths {
			_ = os.Remove(p)
		}
		_ = os.Remove(submissionDir)
	}

	savedFiles := make([]CommunitySubmissionFile, 0, len(files))
	for _, key := range submissionFileOrder {
		uf, ok := files[key]
		if !ok {
			continue
		}
		name := sanitizeFilename(uf.Filename)
		storedPath := filepath.Join(submissionDir, key+"__"+name)
		out, err := os.Create(storedPath)
		if err != nil {
			cleanupOnFailure()
			return nil, fmt.Errorf("save %s: %w", key, err)
		}
		size, err := io.Copy(out, uf.Reader)
		out.Close()
		if err != nil {
			cleanupOnFailure()
			return nil, fmt.Errorf("write %s: %w", key, err)
		}
		savedPaths = append(savedPaths, storedPath)

		if _, err := tx.ExecContext(ctx, `
			INSERT INTO community_submission_files (submission_id, file_key, original_name, stored_path, size_bytes)
			VALUES (?, ?, ?, ?, ?)`,
			id, key, uf.Filename, storedPath, size,
		); err != nil {
			cleanupOnFailure()
			return nil, fmt.Errorf("record %s: %w", key, err)
		}
		savedFiles = append(savedFiles, CommunitySubmissionFile{Key: key, Name: uf.Filename, SizeBytes: size})
	}

	if err := tx.Commit(); err != nil {
		cleanupOnFailure()
		return nil, fmt.Errorf("commit submission: %w", err)
	}

	return &CommunitySubmission{
		ID: id, UploadNumber: seq, Title: in.Title, Phenotype: in.Phenotype, PhenotypeID: in.PhenotypeID,
		StudyDesign: in.StudyDesign, SampleSize: in.SampleSize, Biospecimen: in.Biospecimen,
		MS2Supported: in.MS2Supported, Chromatography: in.Chromatography, MassSpectrometry: in.MassSpectrometry,
		Summary: in.Summary, DOI: in.DOI, SourceLink: in.SourceLink, ContactName: in.ContactName,
		ContactEmail: in.ContactEmail, Notes: in.Notes, Status: "submitted", Inclusion: "pending",
		CreatedAt: time.Now().UTC().Format(time.RFC3339), Files: savedFiles,
	}, nil
}

// ListSubmissions returns every submission owned by userID, most recent
// first, each with its attached file list populated.
func (a *AuthDB) ListSubmissions(ctx context.Context, userID string) ([]CommunitySubmission, error) {
	rows, err := a.db.QueryContext(ctx, `
		SELECT seq, id, title, phenotype, phenotype_id, study_design, sample_size, biospecimen,
			ms2_supported, chromatography, mass_spectrometry, summary, doi, source_link,
			contact_name, contact_email, notes, status, inclusion, phenomap_link, created_at
		FROM community_submissions WHERE user_id = ? ORDER BY seq DESC`, userID)
	if err != nil {
		return nil, fmt.Errorf("list submissions: %w", err)
	}
	defer rows.Close()

	var subs []CommunitySubmission
	for rows.Next() {
		var s CommunitySubmission
		if err := rows.Scan(&s.UploadNumber, &s.ID, &s.Title, &s.Phenotype, &s.PhenotypeID, &s.StudyDesign,
			&s.SampleSize, &s.Biospecimen, &s.MS2Supported, &s.Chromatography, &s.MassSpectrometry,
			&s.Summary, &s.DOI, &s.SourceLink, &s.ContactName, &s.ContactEmail, &s.Notes,
			&s.Status, &s.Inclusion, &s.PhenomapLink, &s.CreatedAt,
		); err != nil {
			return nil, fmt.Errorf("scan submission: %w", err)
		}
		subs = append(subs, s)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}

	for i := range subs {
		files, err := a.submissionFiles(ctx, subs[i].ID)
		if err != nil {
			return nil, err
		}
		subs[i].Files = files
	}
	if subs == nil {
		subs = []CommunitySubmission{}
	}
	return subs, nil
}

func (a *AuthDB) submissionFiles(ctx context.Context, submissionID string) ([]CommunitySubmissionFile, error) {
	rows, err := a.db.QueryContext(ctx, `
		SELECT file_key, original_name, size_bytes FROM community_submission_files
		WHERE submission_id = ? ORDER BY id`, submissionID)
	if err != nil {
		return nil, fmt.Errorf("list submission files: %w", err)
	}
	defer rows.Close()

	files := make([]CommunitySubmissionFile, 0)
	for rows.Next() {
		var f CommunitySubmissionFile
		if err := rows.Scan(&f.Key, &f.Name, &f.SizeBytes); err != nil {
			return nil, fmt.Errorf("scan submission file: %w", err)
		}
		files = append(files, f)
	}
	return files, rows.Err()
}

// SubmissionFilePath resolves the on-disk path and original filename for
// one uploaded file, only if submissionID belongs to userID -- so a
// signed-in user can never fetch another user's uploaded study data just
// by guessing or enumerating submission IDs.
func (a *AuthDB) SubmissionFilePath(ctx context.Context, userID, submissionID, fileKey string) (path, filename string, err error) {
	var owner int
	if err := a.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM community_submissions WHERE id = ? AND user_id = ?`, submissionID, userID).Scan(&owner); err != nil {
		return "", "", fmt.Errorf("check submission owner: %w", err)
	}
	if owner == 0 {
		return "", "", ErrSubmissionNotFound
	}

	err = a.db.QueryRowContext(ctx, `
		SELECT stored_path, original_name FROM community_submission_files
		WHERE submission_id = ? AND file_key = ?`, submissionID, fileKey,
	).Scan(&path, &filename)
	if errors.Is(err, sql.ErrNoRows) {
		return "", "", ErrSubmissionNotFound
	}
	if err != nil {
		return "", "", fmt.Errorf("look up submission file: %w", err)
	}
	return path, filename, nil
}
