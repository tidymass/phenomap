package main

import (
	"archive/zip"
	"encoding/csv"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
)

type csvColumn struct {
	source string
	target string
	index  int
}

type downloadableCSV struct {
	path    string
	columns []csvColumn
}

// downloadableFiles is an explicit allow-list mapping a public filename to its
// source path and exported schema, so the download endpoint can never be used
// to read arbitrary files off the server.
var downloadableFiles map[string]downloadableCSV

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
	// The backend is run from backend/, so the project root is one level up.
	// Override with PHENOMAP_NEO4J_IMPORT_DIR or
	// PHENOMAP_DATA_ROOT if the backend is ever run from somewhere else.
	root := getenv("PHENOMAP_DATA_ROOT", filepath.Join(".."))
	abs, err := filepath.Abs(root)
	if err != nil {
		abs = root
	}

	importDir := getenv("PHENOMAP_NEO4J_IMPORT_DIR", filepath.Join(abs, "neo4j", "import"))

	downloadableFiles = map[string]downloadableCSV{
		"nodes_study.csv":                 nodeCSV(filepath.Join(importDir, "nodes_study.csv")),
		"nodes_phenotype.csv":             nodeCSV(filepath.Join(importDir, "nodes_phenotype.csv")),
		"nodes_module.csv":                nodeCSV(filepath.Join(importDir, "nodes_module.csv")),
		"nodes_metabolite.csv":            nodeCSV(filepath.Join(importDir, "nodes_metabolite.csv")),
		"edges_study_phenotype.csv":       edgeCSV(filepath.Join(importDir, "edges_study_phenotype.csv"), "Study_ID", "Phenotype_ID", nil),
		"edges_module_study.csv":          edgeCSV(filepath.Join(importDir, "edges_module_study.csv"), "Module_ID", "Study_ID", nil),
		"edges_metabolite_module.csv":     edgeCSV(filepath.Join(importDir, "edges_metabolite_module.csv"), "Metabolite_ID", "Module_ID", []string{"Type"}),
		"edges_metabolite_metabolite.csv": edgeCSV(filepath.Join(importDir, "edges_metabolite_metabolite.csv"), "Metabolite_ID_1", "Metabolite_ID_2", nil),
		"edges_module_module.csv": edgeCSV(filepath.Join(importDir, "edges_module_module.csv"), "Module_ID_1", "Module_ID_2", []string{
			"Type", "Similarity_Score", "Similarity_Tier", "Biological_Score", "Compositional_Score", "Cross_Study",
		}),
	}
}

func nodeCSV(path string) downloadableCSV {
	return downloadableCSV{path: path}
}

func edgeCSV(path, startName, endName string, extra []string) downloadableCSV {
	columns := []csvColumn{
		{source: "edge_id", target: "Lab_ID"},
		{source: ":START_ID", target: startName},
		{source: "Relationship", target: "Relationship"},
		{source: ":END_ID", target: endName},
	}
	for _, name := range extra {
		columns = append(columns, csvColumn{source: name, target: name})
	}
	return downloadableCSV{path: path, columns: columns}
}

// GET /api/download/{filename}
func handleDownload(w http.ResponseWriter, r *http.Request) {
	name := r.PathValue("filename")
	spec, ok := downloadableFiles[name]
	if !ok {
		writeError(w, http.StatusNotFound, "unknown file")
		return
	}

	info, err := os.Stat(spec.path)
	if err != nil {
		writeError(w, http.StatusNotFound, "file not available on disk: "+spec.path)
		return
	}

	w.Header().Set("Content-Type", "text/csv")
	w.Header().Set("Content-Disposition", `attachment; filename="`+name+`"`)
	if r.Method == http.MethodHead {
		w.Header().Set("Content-Length", fmt.Sprint(info.Size()))
		return
	}

	if err := writeCleanCSV(w, spec); err != nil {
		logDownloadError(name, err)
	}
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
		spec, ok := downloadableFiles[name]
		if !ok {
			continue
		}
		if err := addFileToZip(zw, name, spec); err != nil {
			// Response headers are already flushed by this point, so there's
			// no clean way to surface an error status; just stop writing.
			return
		}
	}
}

func addFileToZip(zw *zip.Writer, name string, spec downloadableCSV) error {
	fw, err := zw.Create(name)
	if err != nil {
		return err
	}
	return writeCleanCSV(fw, spec)
}

func writeCleanCSV(w io.Writer, spec downloadableCSV) error {
	f, err := os.Open(spec.path)
	if err != nil {
		return err
	}
	defer f.Close()

	reader := csv.NewReader(f)
	reader.FieldsPerRecord = -1
	writer := csv.NewWriter(w)
	defer writer.Flush()

	header, err := reader.Read()
	if err != nil {
		return err
	}
	columns, err := exportColumns(header, spec.columns)
	if err != nil {
		return err
	}
	if err := writer.Write(exportHeader(columns)); err != nil {
		return err
	}

	for {
		record, err := reader.Read()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return err
		}
		if err := writer.Write(projectRecord(record, columns)); err != nil {
			return err
		}
	}
	return writer.Error()
}

func exportColumns(header []string, requested []csvColumn) ([]csvColumn, error) {
	indexByName := make(map[string]int, len(header))
	for i, name := range header {
		indexByName[name] = i
	}

	if len(requested) == 0 {
		columns := make([]csvColumn, 0, len(header))
		for _, name := range header {
			if strings.HasPrefix(name, ":") {
				continue
			}
			columns = append(columns, csvColumn{source: name, target: name, index: indexByName[name]})
		}
		return columns, nil
	}

	columns := make([]csvColumn, len(requested))
	for i, col := range requested {
		idx, ok := indexByName[col.source]
		if !ok {
			return nil, fmt.Errorf("source CSV missing column %q", col.source)
		}
		col.index = idx
		columns[i] = col
	}
	return columns, nil
}

func exportHeader(columns []csvColumn) []string {
	header := make([]string, len(columns))
	for i, col := range columns {
		header[i] = col.target
	}
	return header
}

func projectRecord(record []string, columns []csvColumn) []string {
	out := make([]string, len(columns))
	for i, col := range columns {
		if col.index < len(record) {
			out[i] = record[col.index]
		}
	}
	return out
}

func logDownloadError(name string, err error) {
	fmt.Fprintf(os.Stderr, "download %s failed: %v\n", name, err)
}
