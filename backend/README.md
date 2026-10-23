# PhenoMAP backend (Go)

Talks to your local Neo4j instance and exposes a small JSON API for the
frontend.

## Setup

```bash
brew install go        # if you don't have Go yet
cp .env.example .env    # then edit .env and put in your Neo4j password
go mod tidy
set -a; source .env; set +a
go run .
```

You should see: `phenomap-web backend listening on :8080 (neo4j db=neo4j)`

## Sign up email requires a 163 SMTP authorization code

Verification emails are sent from `featuremap@163.com` (the same mailbox the
FeatureMAP web app uses) through `smtp.163.com:465` over SSL. Before signup will work:

1. Sign in at mail.163.com -> Settings -> POP3/SMTP/IMAP, and enable the SMTP service.
2. Copy the SMTP authorization code it gives you.
3. Put that code (not the mailbox login password) into `SMTP_PASSWORD` in `.env`.

If SMTP isn't configured yet, signup still creates the account but returns
an error saying the email failed to send -- use `POST
/api/auth/resend-verification` once SMTP is set up to get a working link.

## Endpoints

- `GET /api/health`
- `GET /api/search?q=xxx&label=Module&limit=20` — `label` is optional
  (Study / Phenotype / Module / Metabolite); omit it to search all four.
- `GET /api/node/{label}/{id}` — `{id}` is a node's `Lab_ID`.

## If `go run .` fails

- `unknown directive` / module errors → run `go mod tidy` again, it
  resolves the exact neo4j-go-driver version and writes `go.sum`.
- connection errors → double check `NEO4J_URI` / `NEO4J_PASSWORD` in
  `.env` match the instance you have running in Neo4j Desktop, and that
  the database is started.
- any other compile error → paste it back, this code was written without
  being able to compile it in the environment it was written in, so a
  small driver API mismatch is possible.
