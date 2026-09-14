package main

import (
	"archive/zip"
	"bytes"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestDownloadExportsCleanNodeCSVFromNeo4jImport(t *testing.T) {
	root := t.TempDir()
	importDir := filepath.Join(root, "neo4j", "import")
	if err := os.MkdirAll(importDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(
		filepath.Join(importDir, "nodes_study.csv"),
		[]byte("Lab_ID,Title,:ID,:LABEL\nPST000001,Study one,PST000001,Study\n"),
		0o644,
	); err != nil {
		t.Fatal(err)
	}

	t.Setenv("PHENOMAP_DATA_ROOT", root)
	initDownloadableFiles()

	req := httptest.NewRequest(http.MethodGet, "/api/download/nodes_study.csv", nil)
	req.SetPathValue("filename", "nodes_study.csv")
	rec := httptest.NewRecorder()

	handleDownload(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200; body=%s", rec.Code, rec.Body.String())
	}
	if got := strings.TrimSpace(rec.Body.String()); got != "Lab_ID,Title\nPST000001,Study one" {
		t.Fatalf("body = %q", got)
	}
}

func TestDownloadExportsCleanRelationshipCSVFromNeo4jImport(t *testing.T) {
	root := t.TempDir()
	importDir := filepath.Join(root, "neo4j", "import")
	if err := os.MkdirAll(importDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(
		filepath.Join(importDir, "edges_metabolite_module.csv"),
		[]byte("edge_id,:START_ID,:END_ID,:TYPE,Relationship,Type\nPMR000001,PME000001,PMO000001,MEMBER_OF,member_of,core\n"),
		0o644,
	); err != nil {
		t.Fatal(err)
	}

	t.Setenv("PHENOMAP_DATA_ROOT", root)
	initDownloadableFiles()

	req := httptest.NewRequest(http.MethodGet, "/api/download/edges_metabolite_module.csv", nil)
	req.SetPathValue("filename", "edges_metabolite_module.csv")
	rec := httptest.NewRecorder()

	handleDownload(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200; body=%s", rec.Code, rec.Body.String())
	}
	want := "Lab_ID,Metabolite_ID,Relationship,Module_ID,Type\nPMR000001,PME000001,member_of,PMO000001,core"
	if got := strings.TrimSpace(rec.Body.String()); got != want {
		t.Fatalf("body = %q, want %q", got, want)
	}
}

func TestDownloadAllUsesCleanCSVInsideZip(t *testing.T) {
	root := t.TempDir()
	importDir := filepath.Join(root, "neo4j", "import")
	if err := os.MkdirAll(importDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(
		filepath.Join(importDir, "nodes_metabolite.csv"),
		[]byte("Lab_ID,Metabolite_Name,:ID,:LABEL\nPME000001,Glucose,PME000001,Metabolite\n"),
		0o644,
	); err != nil {
		t.Fatal(err)
	}

	t.Setenv("PHENOMAP_DATA_ROOT", root)
	initDownloadableFiles()

	req := httptest.NewRequest(http.MethodGet, "/api/download-all?files=nodes_metabolite.csv", nil)
	rec := httptest.NewRecorder()

	handleDownloadAll(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", rec.Code)
	}
	zr, err := zip.NewReader(bytes.NewReader(rec.Body.Bytes()), int64(rec.Body.Len()))
	if err != nil {
		t.Fatal(err)
	}
	if len(zr.File) != 1 {
		t.Fatalf("zip entries = %d, want 1", len(zr.File))
	}
	rc, err := zr.File[0].Open()
	if err != nil {
		t.Fatal(err)
	}
	defer rc.Close()
	buf := new(bytes.Buffer)
	if _, err := buf.ReadFrom(rc); err != nil {
		t.Fatal(err)
	}
	if got := strings.TrimSpace(buf.String()); got != "Lab_ID,Metabolite_Name\nPME000001,Glucose" {
		t.Fatalf("zip csv = %q", got)
	}
}
