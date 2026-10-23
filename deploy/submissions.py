#!/usr/bin/env python3
"""Review Community submissions from the command line (curator tool).

Run it through ./submissions.sh, which points it at this deployment's auth
database. Changes take effect immediately: the submitter's Community page
reads the same database on every load, so no restart is needed.

    ./submissions.sh list                       all submissions, newest first
    ./submissions.sh show SUB-2026-001          every field + where the files are
    ./submissions.sh set SUB-2026-001 --status "under review"
    ./submissions.sh set SUB-2026-001 --status accepted --inclusion included \
        --link https://phenomap.jaspershenlab.com/node/Study/PST000502
    ./submissions.sh set SUB-2026-001 --note "waiting for raw data"   (curator-only note)

--status, --inclusion and --link are shown to the submitter on their
Community page; --note is internal and never shown to them.
"""

import argparse
import os
import sqlite3
import sys

SUGGESTED_STATUS = ["submitted", "under review", "needs revision", "accepted", "rejected"]
SUGGESTED_INCLUSION = ["pending", "included", "not included"]


def connect():
    path = os.environ.get("AUTH_DB_PATH", "")
    if not path or not os.path.exists(path):
        sys.exit(
            f"Auth database not found ({path or 'AUTH_DB_PATH not set'}). "
            "Community submissions only exist when AUTH_ENABLED=true."
        )
    conn = sqlite3.connect(path, timeout=10)
    conn.row_factory = sqlite3.Row
    return conn


def get_submission(conn, sub_id):
    row = conn.execute(
        """SELECT s.*, u.email AS account_email, u.display_name AS account_name
           FROM community_submissions s LEFT JOIN users u ON u.id = s.user_id
           WHERE s.id = ?""",
        (sub_id,),
    ).fetchone()
    if row is None:
        sys.exit(f"No submission with ID {sub_id}. Use 'list' to see the IDs.")
    return row


def cmd_list(conn, _args):
    rows = conn.execute(
        """SELECT s.id, s.created_at, s.status, s.inclusion, s.title, u.email AS account_email
           FROM community_submissions s LEFT JOIN users u ON u.id = s.user_id
           ORDER BY s.seq DESC"""
    ).fetchall()
    if not rows:
        print("No submissions yet.")
        return
    print(f"{'ID':<14} {'Submitted':<20} {'Status':<15} {'Inclusion':<13} {'Account':<28} Title")
    for r in rows:
        title = (r["title"] or "")[:60]
        print(f"{r['id']:<14} {r['created_at'][:19]:<20} {r['status']:<15} {r['inclusion']:<13} "
              f"{(r['account_email'] or '?'):<28} {title}")


def cmd_show(conn, args):
    r = get_submission(conn, args.id)
    fields = [
        ("ID", "id"), ("Submitted", "created_at"), ("Account", "account_email"),
        ("Account name", "account_name"), ("Status", "status"), ("Inclusion", "inclusion"),
        ("PhenoMAP link", "phenomap_link"), ("Curator note", "admin_notes"),
        ("Title", "title"), ("Phenotype", "phenotype"), ("Phenotype ID", "phenotype_id"),
        ("Study design", "study_design"), ("Sample size", "sample_size"),
        ("Biospecimen", "biospecimen"), ("MS2 support", "ms2_supported"),
        ("Chromatography", "chromatography"), ("Mass spectrometry", "mass_spectrometry"),
        ("DOI", "doi"), ("Source link", "source_link"), ("Contact", "contact_name"),
        ("Contact email", "contact_email"), ("Submitter notes", "notes"), ("Summary", "summary"),
    ]
    for label, key in fields:
        print(f"{label + ':':<19} {r[key] if r[key] not in (None, '') else '-'}")
    files = conn.execute(
        """SELECT file_key, original_name, stored_path, size_bytes
           FROM community_submission_files WHERE submission_id = ? ORDER BY id""",
        (args.id,),
    ).fetchall()
    print("Files:")
    for f in files or []:
        print(f"  {f['file_key']:<22} {f['original_name']}  ({f['size_bytes'] / 1e6:.1f} MB)")
        print(f"  {'':<22} {f['stored_path']}")
    if not files:
        print("  (none)")


def cmd_set(conn, args):
    get_submission(conn, args.id)
    updates = {}
    if args.status is not None:
        updates["status"] = args.status.strip().lower()
    if args.inclusion is not None:
        updates["inclusion"] = args.inclusion.strip().lower()
    if args.link is not None:
        updates["phenomap_link"] = args.link.strip()
    if args.note is not None:
        updates["admin_notes"] = args.note.strip()
    if not updates:
        sys.exit("Nothing to change: give at least one of --status, --inclusion, --link, --note.")
    if "status" in updates and updates["status"] not in SUGGESTED_STATUS:
        print(f"note: '{updates['status']}' is not one of the usual values {SUGGESTED_STATUS}; saving it anyway.")
    if "inclusion" in updates and updates["inclusion"] not in SUGGESTED_INCLUSION:
        print(f"note: '{updates['inclusion']}' is not one of the usual values {SUGGESTED_INCLUSION}; saving it anyway.")
    sets = ", ".join(f"{k} = ?" for k in updates)
    with conn:
        conn.execute(f"UPDATE community_submissions SET {sets} WHERE id = ?", (*updates.values(), args.id))
    print(f"Updated {args.id}:")
    cmd_show(conn, args)


def main():
    p = argparse.ArgumentParser(description="Review PhenoMAP Community submissions.")
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("list", help="list all submissions")
    s = sub.add_parser("show", help="show one submission")
    s.add_argument("id")
    s = sub.add_parser("set", help="update status / inclusion / link / curator note")
    s.add_argument("id")
    s.add_argument("--status", help=f"shown to the submitter, e.g. {', '.join(SUGGESTED_STATUS)}")
    s.add_argument("--inclusion", help=f"shown to the submitter, e.g. {', '.join(SUGGESTED_INCLUSION)}")
    s.add_argument("--link", help="PhenoMAP record URL shown as 'Open record' (empty string clears it)")
    s.add_argument("--note", help="curator-only note, never shown to the submitter")
    args = p.parse_args()
    conn = connect()
    {"list": cmd_list, "show": cmd_show, "set": cmd_set}[args.cmd](conn, args)


if __name__ == "__main__":
    main()
