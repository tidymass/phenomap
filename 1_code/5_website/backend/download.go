package main

import (
	"archive/zip"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
)

// downloadableFiles is an explicit allow-list mapping a public filename to
// its absolute path on disk, so the download endpoint can never be used
// to read arbitrary files off the server.
var downloadableFiles map[string]string

// downloadOrder fixes the order files are added to the "download all" zip
// (and mirrors the order the Download page lists them in).
var downloadOrder = []string{
	"nodes_study.csv",
	"nodes_phenotype.csv",
	"nodes_module.csv",
	"nodes_metabolite.csv",
	"edges_study_phenotype.csv",
	"edges_module_study.csv",
	"edges_metabolite_module.csv",
	"edges_metabolite_metabolite.csv",
	"edges_module_module.csv",
}

func initDownloadableFiles() {
	// The backend is run from 1_code/5_website/backend, so the project
	// root is three levels up. Override with PHENOMAP_DATA_ROOT if the
	// backend is ever run from somewhere else.
	root := getenv("PHENOMAP_DATA_ROOT", filepath.Join("..", "..", ".."))
	abs, err := filepath.Abs(root)
	if err != nil {
		abs = root
	}

	entity := filepath.Join(abs, "2_data", "tidy_entity")
	relationship := filepath.Join(abs, "2_data", "tidy_relationship")

	downloadableFiles = map[string]string{
		"nodes_study.csv":                 filepath.Join(entity, "nodes_study.csv"),
		"nodes_phenotype.csv":             filepath.Join(entity, "nodes_phenotype.csv"),
		"nodes_module.csv":                filepath.Join(entity, "nodes_module.csv"),
		"nodes_metabolite.csv":            filepath.Join(entity, "nodes_metabolite.csv"),
		"edges_study_phenotype.csv":       filepath.Join(relationship, "edges_study_phenotype.csv"),
		"edges_module_study.csv":          filepath.Join(relationship, "edges_module_study.csv"),
		"edges_metabolite_module.csv":     filepath.Join(relationship, "edges_metabolite_module.csv"),
		"edges_metabolite_metabolite.csv": filepath.Join(relationship, "edges_metabolite_metabolite.csv"),
		"edges_module_module.csv":         filepath.Join(relationship, "edges_module_module.csv"),
	}
}

// GET /api/download/{filename}
func handleDownload(w http.ResponseWriter, r *http.Request) {
	name := r.PathValue("filename")
	path, ok := downloadableFiles[name]
	if !ok {
		writeError(w, http.StatusNotFound, "unknown file")
		return
	}

	f, err := os.Open(path)
	if err != nil {
		writeError(w, http.StatusNotFound, "file not available on disk: "+path)
		return
	}
	defer f.Close()

	info, err := f.Stat()
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to read file")
		return
	}

	w.Header().Set("Content-Type", "text/csv")
	w.Header().Set("Content-Disposition", `attachment; filename="`+name+`"`)
	http.ServeContent(w, r, name, info.ModTime(), f)
}

// GET /api/download-all[?files=a.csv,b.csv] -- bundles the requested CSVs
// into a single zip archive, or every downloadable CSV if no ?files filter
// is given. Each entry inside the zip stays a plain .csv file; only the
// outer transport is compressed. Requested names are matched against the
// same allow-list handleDownload uses and re-ordered to downloadOrder, so
// this can't be used to smuggle in arbitrary files or reorder the archive.
func handleDownloadAll(w http.ResponseWriter, r *http.Request) {
	names := downloadOrder
	if raw := r.URL.Query().Get("files"); raw != "" {
		requested := make(map[string]bool)
		for _, n := range strings.Split(raw, ",") {
			requested[strings.TrimSpace(n)] = true
		}
		filtered := make([]string, 0, len(downloadOrder))
		for _, n := range downloadOrder {
			if requested[n] {
				filtered = append(filtered, n)
			}
		}
		if len(filtered) == 0 {
			writeError(w, http.StatusBadRequest, "no valid files requested")
			return
		}
		names = filtered
	}

	w.Header().Set("Content-Type", "application/zip")
	w.Header().Set("Content-Disposition", `attachment; filename="phenomap_data.zip"`)

	zw := zip.NewWriter(w)
	defer zw.Close()

	for _, name := range names {
		path, ok := downloadableFiles[name]
		if !ok {
			continue
		}
		if err := addFileToZip(zw, name, path); err != nil {
			// Response headers are already flushed by this point, so there's
			// no clean way to surface an error status; just stop writing.
			return
		}
	}
}

func addFileToZip(zw *zip.Writer, name, path string) error {
	f, err := os.Open(path)
	if err != nil {
		return err
	}
	defer f.Close()

	fw, err := zw.Create(name)
	if err != nil {
		return err
	}
	_, err = io.Copy(fw, f)
	return err
}
