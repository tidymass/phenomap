package main

import (
	"context"
	"log"
	"net/http"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// Per-file and per-request caps for Community study-data uploads. Feature
// tables and metabolite annotation files are usually small text/CSV
// exports, so 20MB/file is generous while still bounding memory use during
// ParseMultipartForm; the total cap covers up to three such files plus
// form fields with headroom.
const (
	maxSubmissionFileBytes  = 20 << 20
	maxSubmissionTotalBytes = 64 << 20
)

var allowedSubmissionExt = map[string]bool{
	".csv": true, ".tsv": true, ".txt": true, ".xlsx": true,
}

// communitySubmissionFileSpecs mirrors the frontend's fileRequirements in
// CommunityView.vue -- same keys, same required/optional split.
var communitySubmissionFileSpecs = []struct {
	key      string
	required bool
	label    string
}{
	{"feature_table", true, "feature table"},
	{"sample_metadata", true, "sample metadata"},
	{"metabolite_annotation", false, "metabolite annotation"},
}

// POST /api/community/submissions (multipart/form-data) -- auth required.
func handleCreateSubmission(authDB *AuthDB, emailCfg EmailConfig) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		authCtx, authCancel := context.WithTimeout(r.Context(), 8*time.Second)
		user, err := authDB.CurrentUser(authCtx, sessionTokenFromRequest(r))
		authCancel()
		if err != nil {
			writeError(w, http.StatusUnauthorized, "please sign in before submitting study data")
			return
		}

		r.Body = http.MaxBytesReader(w, r.Body, maxSubmissionTotalBytes)
		if err := r.ParseMultipartForm(maxSubmissionFileBytes); err != nil {
			writeError(w, http.StatusBadRequest, "request too large or malformed: "+err.Error())
			return
		}
		defer r.MultipartForm.RemoveAll()

		// Started only after the upload has been fully received: a large
		// upload on a slow connection can take longer than 30s by itself,
		// and the DB/disk work below must not inherit an already-expired
		// deadline.
		ctx, cancel := context.WithTimeout(r.Context(), 30*time.Second)
		defer cancel()

		field := func(name string) string { return strings.TrimSpace(r.FormValue(name)) }
		in := CommunitySubmissionInput{
			Title:            field("title"),
			Phenotype:        field("phenotype"),
			PhenotypeID:      field("phenotype_id"),
			StudyDesign:      field("study_design"),
			Biospecimen:      field("biospecimen"),
			MS2Supported:     field("ms2_supported"),
			Chromatography:   field("chromatography"),
			MassSpectrometry: field("mass_spectrometry"),
			Summary:          field("summary"),
			DOI:              field("doi"),
			SourceLink:       field("source_link"),
			ContactName:      field("contact_name"),
			ContactEmail:     field("contact_email"),
			Notes:            field("notes"),
		}

		var missing []string
		requireField := func(v, label string) {
			if v == "" {
				missing = append(missing, label)
			}
		}
		requireField(in.Title, "study title")
		requireField(in.Phenotype, "phenotype")
		requireField(in.StudyDesign, "study design")
		requireField(in.Biospecimen, "biospecimen")
		requireField(in.MS2Supported, "MS2 support")
		requireField(in.Chromatography, "chromatography")
		requireField(in.MassSpectrometry, "mass spectrometry")
		requireField(in.Summary, "study summary")
		requireField(in.ContactName, "contact name")
		if in.ContactEmail == "" || !strings.Contains(in.ContactEmail, "@") {
			missing = append(missing, "a valid contact email")
		}

		sampleSize, sizeErr := strconv.Atoi(field("sample_size"))
		if sizeErr != nil || sampleSize <= 0 {
			missing = append(missing, "a valid sample size")
		}
		in.SampleSize = sampleSize

		if len(missing) > 0 {
			writeError(w, http.StatusBadRequest, "missing or invalid: "+strings.Join(missing, ", "))
			return
		}

		files := map[string]uploadedFile{}
		for _, spec := range communitySubmissionFileSpecs {
			f, header, err := r.FormFile(spec.key)
			if err != nil {
				if spec.required {
					writeError(w, http.StatusBadRequest, "missing required file: "+spec.label)
					return
				}
				continue
			}
			defer f.Close()
			if header.Size > maxSubmissionFileBytes {
				writeError(w, http.StatusBadRequest, spec.label+" is larger than 20 MB")
				return
			}
			ext := strings.ToLower(filepath.Ext(header.Filename))
			if !allowedSubmissionExt[ext] {
				writeError(w, http.StatusBadRequest, spec.label+" must be CSV, TSV, TXT, or XLSX")
				return
			}
			files[spec.key] = uploadedFile{Filename: header.Filename, Reader: f}
		}

		submission, err := authDB.CreateSubmission(ctx, user.ID, in, files)
		if err != nil {
			log.Printf("create submission error: %v", err)
			writeError(w, http.StatusInternalServerError, "failed to save submission")
			return
		}

		// The submission is already saved at this point -- a failed
		// notification email shouldn't make the caller think their upload
		// was lost, so this is logged rather than returned as an error. It
		// is sent in the background so a slow SMTP server doesn't hold up
		// the response.
		go func() {
			if err := emailCfg.sendCommunitySubmissionNotice(user, submission); err != nil {
				log.Printf("community submission notice email error: %v", err)
			}
		}()

		writeJSON(w, http.StatusOK, submission)
	}
}

// GET /api/community/submissions -- auth required.
func handleListSubmissions(authDB *AuthDB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		ctx, cancel := context.WithTimeout(r.Context(), 8*time.Second)
		defer cancel()

		user, err := authDB.CurrentUser(ctx, sessionTokenFromRequest(r))
		if err != nil {
			writeError(w, http.StatusUnauthorized, "not signed in")
			return
		}

		submissions, err := authDB.ListSubmissions(ctx, user.ID)
		if err != nil {
			log.Printf("list submissions error: %v", err)
			writeError(w, http.StatusInternalServerError, "failed to load submissions")
			return
		}
		writeJSON(w, http.StatusOK, submissions)
	}
}

// GET /api/community/submissions/{id}/files/{key} -- auth required, owner
// only (see AuthDB.SubmissionFilePath).
func handleDownloadSubmissionFile(authDB *AuthDB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		ctx, cancel := context.WithTimeout(r.Context(), 8*time.Second)
		defer cancel()

		user, err := authDB.CurrentUser(ctx, sessionTokenFromRequest(r))
		if err != nil {
			writeError(w, http.StatusUnauthorized, "not signed in")
			return
		}

		path, filename, err := authDB.SubmissionFilePath(ctx, user.ID, r.PathValue("id"), r.PathValue("key"))
		if err != nil {
			writeError(w, http.StatusNotFound, "file not found")
			return
		}

		w.Header().Set("Content-Disposition", `attachment; filename="`+filename+`"`)
		http.ServeFile(w, r, path)
	}
}
