# AGENTS.md

**Ferry** is a single-user, self-hosted web application that packs uploaded files
and/or public download URLs into a **private Docker Hub image** and shows the
image name. The destination machine pulls that image and extracts the files, so
the two machines never need a direct connection.

Ferry is pure Go. It does **not** use Docker, the Docker CLI, the Docker daemon,
or `/var/run/docker.sock`. It builds the image with
`github.com/google/go-containerregistry` and pushes it straight to Docker Hub.
There is no local image to clean up.

This file is the operating manual for AI coding agents. `README.md` is the
end-user manual (written for a non-programmer deploying to Ubuntu 24.04); keep it
accurate, but do not turn it into developer documentation.

---

## TL;DR — rules for agents

- Go 1.23+ (CI pins 1.23). `gofmt`, `go vet ./...`, and `go test ./...` must pass.
- Standard library first. Do not add a dependency without a concrete reason.
- Never reintroduce Docker, a Dockerfile, docker-compose, or a Docker socket.
- Preserve the security invariants in §9. They are the product, not decoration.
- The image format (§7) and SQLite schema (§6) are compatibility contracts.
- When configuration changes, update `internal/config/config.go`,
  `.env.example`, `deploy/ferry.env.example`, `README.md`, and (for required
  values) `deploy/install.sh`.
- Never commit secrets. `.gitignore` excludes `.env`, `*.env` (except
  `.env.example`), `data/`, `*.db`, and the built `ferry` binary.
- The frontend is embedded vanilla JS/CSS under a strict CSP: no inline
  scripts/styles, no CDN, no build step.
- Keep diffs focused and small. This is a deliberately compact codebase.

---

## 1. What Ferry does (and does not do)

**Does:**

- Single login user; signed session cookie; CSRF protection; login throttling.
- Resumable chunked uploads (8 MiB chunks) with exact-offset resume.
- SSRF-safe streaming downloads from public `http(s)` URLs.
- Per-job size cap across uploads **plus** downloads.
- Optional gzip compression and optional AES-256-GCM passphrase encryption.
- Builds a `busybox:stable`-based image with one layer per file, pushes it to a
  private Docker Hub repository, verifies the pushed digest, and records the tag.
- Job history, cancel, delete image tag, delete record, retention cleanup.
- Update check against GitHub Releases (`ferry check-update`) plus a cached
  "newer release" banner on the home page.
- In-place self-update from the CLI (`sudo ferry self-update`): verifies the
  published SHA-256, replaces the binary atomically, and restarts systemd.
- Restart recovery, stale-draft cleanup, orphan-directory cleanup.
- A destination-side `ferry unpack` command shipped inside packed images, and a
  `ferry download <image>` command that pulls an image with go-containerregistry
  (no Docker daemon, CLI, or socket) and extracts/unpacks it in one step.

**Does not:**

- Multi-user accounts, registration, sharing, or permissions.
- Run more than one job at a time (one worker, one queue).
- Read a `.env` file. Configuration comes from environment variables only.
- Require Go, Docker, or Python on the production server.
- Store finished files on the server. Job directories are deleted on every
  terminal outcome.

---

## 2. Quick commands

| Task | Command |
| --- | --- |
| Format check | `gofmt -l .` (must print nothing) |
| Vet | `go vet ./...` |
| Test everything | `go test ./...` |
| Test one package | `go test ./internal/downloader/` |
| Build (dev version) | `CGO_ENABLED=0 go build -trimpath -ldflags "-s -w -X main.version=dev" -o ferry ./cmd/ferry` |
| Run locally | see below |
| Version | `./ferry --version` |
| Check for a newer release | `./ferry check-update` |
| Self-update (root, Linux) | `sudo ./ferry self-update` |
| Hash a password | `./ferry hash-password` |
| Unpack already extracted files | `./ferry unpack --dir ./ferry-files` |
| Pull an image and extract its files | `./ferry download <image>` |
| Validate installer syntax | `bash -n deploy/install.sh` |

The module is named `ferry` (not a URL). Import internal packages as
`ferry/internal/...` and embedded assets as `ferry/web`.

### Run locally

Ferry validates all required configuration at startup, including Docker Hub
credentials. Dummy credentials are enough to exercise login, uploads, downloads,
history, and cancellation; only the final push will fail.

```bash
export FERRY_USERNAME=dev
export FERRY_PASSWORD=dev-password
export FERRY_SECRET_KEY="$(openssl rand -hex 32)"
export FERRY_LISTEN_ADDR=127.0.0.1:8080
export FERRY_DATA_DIR="$PWD/.testdata"
export DOCKERHUB_USERNAME=dev
export DOCKERHUB_TOKEN=dummy
export DOCKERHUB_REPO=ferry

go run ./cmd/ferry
# open http://127.0.0.1:8080
```

`.testdata/` is gitignored and already used for local runs. Do not point
`FERRY_DATA_DIR` at `/var/lib/ferry` on a development machine.

### Sandbox note

If `go` fails with `operation not permitted` while opening
`~/Library/Caches/go-build`, the agent sandbox is blocking the default cache.
Use the repository-local caches (gitignored):

```bash
GOCACHE="$PWD/.gocache/build" GOMODCACHE="$PWD/.gocache/mod" go test ./...
```

The same environment variables work for `go build`, `go vet`, and `go run`.

---

## 3. Repository map

```text
cmd/ferry/            main, CLI (--version, hash-password, download, unpack, check-update, self-update), wiring, shutdown
internal/config/      environment parsing and aggregated validation
internal/auth/        signed session cookie, bcrypt/constant-time login, IP throttling
internal/db/          SQLite schema, migrations, job/upload/file queries
internal/uploads/     resumable chunk storage, offsets, quota, filename rules
internal/downloader/  SSRF-safe streaming HTTP downloads
internal/imagebuild/  pure-Go layers, compression, encryption, push, digest verification
internal/securefile/  streaming AES-256-GCM file encryption format
internal/secretbox/   encrypts the job passphrase at rest
internal/dockerhub/   Docker Hub tag deletion over the HTTP API
internal/jobs/        single worker, queue, cancel, recovery, cleanup, retention
internal/update/      GitHub release check and cached update status
internal/safename/    filename sanitization, uniqueness, job-path containment
internal/web/         routes, HTML handlers, JSON API, CSRF, security headers
web/                  //go:embed templates and static assets
web/templates/        html/template pages (no base template; each page is standalone)
web/static/           vanilla app.js and style.css
deploy/               systemd unit, installer, env example, Caddy example
.github/workflows/    test, cross-build/package, and GitHub Release workflow
```

### Dependency direction

```text
cmd/ferry -> config, auth, db, uploads, downloader, imagebuild, dockerhub, jobs, update, web
web       -> auth, config, db, downloader, jobs, update, uploads, web(assets)
jobs      -> config, db, dockerhub, downloader, imagebuild, safename, secretbox
uploads   -> db, safename
imagebuild-> safename, securefile
config    -> auth (only for bcrypt hash validation)
downloader-> safename
leaves    -> auth, db, dockerhub, safename, secretbox, securefile, update (no internal imports)
```

Do not introduce cycles. `internal/web` and `cmd/ferry` are the only places that
wire dependencies; lower layers must stay reusable and testable.

---

## 4. Architecture and data flow

1. `cmd/ferry/main.go` loads config, creates the data directory, opens SQLite,
   constructs the auth manager, upload service, downloader, image builder,
   Docker Hub client, job manager, and web server.
2. `jobs.Manager.Start()` launches one worker goroutine and one hourly cleanup
   loop. `Recover()` repairs state left by a previous process **before** serving.
3. The browser creates a draft job, uploads chunks to
   `PUT /api/jobs/{id}/uploads/{uploadID}?offset=N`, or adds URLs.
4. Starting a job validates the draft, atomically transitions it to `queued`, and
   enqueues its ID.
5. The worker downloads pending URLs, builds layers from disk, pushes, verifies
   the manifest digest, and marks the job `done`.
6. Every terminal path removes the job directory and clears the stored
   passphrase. Metadata and the capped log remain in SQLite.

There is no DI framework, no ORM, no router library, and no frontend framework.
Keep it that way unless there is a compelling reason.

---

## 5. Job lifecycle

States are defined in `internal/db/db.go`:

```text
draft -> queued -> downloading -> building -> pushing -> done
   |        |           |            |           |
   +--------+-----------+------------+-----------+--> failed
```

- **draft** — editable. Uploads, URLs, compression, and passphrase can change.
  Drafts untouched for 24 hours are deleted by cleanup.
- **queued** — `StartJob` has validated: no pending uploads, at least one entry,
  total within `FERRY_MAX_TOTAL_BYTES`, and free disk ≥ 1.5× the job size.
- **downloading** — pending URLs are streamed to `jobs/<id>/downloads/`, then
  renamed into `jobs/<id>/files/` and recorded with SHA-256/MD5.
- **building** — layers are streamed from disk; no second full copy is made.
- **pushing** — bytes go to Docker Hub. The tag is persisted via `OnTag`
  **before** the push so a crash still leaves something to clean up.
- **done / failed** — terminal. `finished_at` is set and `passphrase_enc` is
  cleared atomically with the transition.

Invariants:

- Only one job runs at a time. `Manager.Current()` exposes the worker's job, and
  `Store.ListActive()` returns every queued/running job (oldest first) so the
  home page still shows an unfinished transfer after a page reload.
- Request paths use `Store.Transition(ctx, id, from, to, msg)` for atomic
  compare-and-set transitions. Only the worker uses `Store.SetState`.
- Cancelling a queued job marks it failed immediately. Cancelling a running job
  cancels its context; the worker records `cancelled by user`.
- `Manager.Discard` is the cleanup path: it cancels an active job, waits for it
  to reach a terminal state, then deletes the record and job directory. It
  never deletes the Docker Hub tag.
- On restart, `downloading`/`building`/`pushing` jobs are failed with
  `interrupted by restart`, their directories removed, and any recorded tag
  deleted. `queued` jobs are re-enqueued.
- Cleanup runs 2 minutes after startup, then hourly: stale drafts, orphan
  directories, and optional Docker Hub retention.
- Live progress lives in memory only. The persisted log is capped at 256 KiB.

---

## 6. Persistence and disk layout

`FERRY_DATA_DIR` defaults to `/data` in code; production uses `/var/lib/ferry`
(created by `deploy/install.sh`). The process creates it with mode `0750`.

```text
<data-dir>/
  ferry.db              SQLite database (WAL mode)
  ferry.db-wal
  ferry.db-shm
  jobs/
    <32-hex-job-id>/
      uploads/          in-progress chunk files (0600)
      files/            completed files (0600)
      downloads/        temporary URL downloads (removed after the job)
```

SQLite details:

- Driver: `modernc.org/sqlite` (pure Go; **do not** switch to a CGO driver).
- WAL, `busy_timeout(5000)`, `synchronous(NORMAL)`, `foreign_keys(ON)`.
- `SetMaxOpenConns(1)` plus a `writeMu` mutex: all writes are serialized. Keep
  transactions short; do not hold the DB while doing network or disk I/O.
- Tables: `jobs`, `uploads`, `job_files` (with a unique partial index on
  `(job_id, name)` for completed files).
- Schema changes: add `CREATE TABLE IF NOT EXISTS` / indexes in `migrate`, and
  use `ensureColumn` for additive columns. Never drop or rewrite user data
  without an explicit migration plan; old databases must upgrade in place.
- Job IDs and upload IDs are 32 lowercase hex characters. `safename.JobDir`
  enforces this and path containment.
- Reserved image filenames: `SHA256SUMS`, `MD5SUMS`, `FERRY-MANIFEST.json`,
  `README-FERRY.txt`, `ferry`. Users cannot upload these names.

---

## 7. Image format contract

Changing this breaks already-pushed images and the destination-side unpacker.
Treat it as a versioned format.

- Base: `busybox:stable` for `FERRY_PLATFORM` (default `linux/amd64`).
- Config: `WorkingDir=/data`, `Cmd=["sh"]`.
- One layer per file, plus a checksums layer, a manifest layer, and — only when
  compression or encryption is enabled — a layer with the running `ferry` binary
  (mode 0755) and `README-FERRY.txt`.
- Files:
  - `SHA256SUMS`, `MD5SUMS` — checksums of the **stored** bytes.
  - `FERRY-MANIFEST.json` — array of `{stored, original, compressed, encrypted}`.
    Required so a plain file ending in `.gz`/`.ferry` is not misidentified.
  - `<name>` — unchanged file.
  - `<name>.gz` — gzip, only when smaller than the original.
  - `<name>.ferry` — encrypted with the job passphrase.
  - `<name>.gz.ferry` — compressed then encrypted.
- Encryption format (`internal/securefile`): magic `FERRYENC`, version `1`,
  16-byte random salt, 8-byte big-endian plaintext size, then 1 MiB
  AES-256-GCM chunks. Key: scrypt (`N=2^15`, `r=8`, `p=1`, 32 bytes).
  The same salt and input must produce identical stored bytes so Ferry can hash
  the stored form before streaming the layer.
- Layer entries use a fixed modtime (`2020-01-01T00:00:00Z`); the image
  `CreatedAt` is the current time. Preserve the fixed modtime for determinism.
- Tag format: `job-YYYYMMDD-HHMMSS-<4 hex>`, image name
  `<lowercase-dockerhub-user>/<repo>:<tag>`.
- Push: up to 3 attempts with 5-second backoff for retryable network errors;
  after success, re-fetch the tag and verify the manifest digest.
- The destination either runs `ferry download <image>` (pulls with
  go-containerregistry, extracts only `data/` entries, then unpacks) or extracts
  `/data` with `docker cp` and runs `ferry unpack` for `.gz`/`.ferry` files.
  `ferry unpack` supports `--passphrase`, `--dir`, `--verify-only`, and
  `--force`; `ferry download` adds `--platform`, `--username`, `--password`,
  `--insecure`, and `--dir` (default: the image tag).
- `ferry download` is CLI-only. It must never be exposed through the web API,
  and it must reject tar entries outside `data/`, absolute paths, `..`
  components, and links before writing anything.

Compression and encryption require Ferry to run on Linux with `FERRY_PLATFORM`
matching `runtime.GOARCH`, because the image embeds the running Ferry binary as
the unpack tool. Do not weaken this check without replacing the tool-shipping
mechanism.

---

## 8. Configuration

All configuration is environment-only. `internal/config.Load()` aggregates every
problem into one actionable error. Secrets are never logged.

| Variable | Default | Notes |
| --- | --- | --- |
| `FERRY_USERNAME` | required | Single login user; `[A-Za-z0-9][A-Za-z0-9._-]{0,99}` |
| `FERRY_PASSWORD` | — | Plain password, constant-time compared |
| `FERRY_PASSWORD_HASH` | — | bcrypt hash; wins over `FERRY_PASSWORD` |
| `FERRY_SECRET_KEY` | required | ≥ 32 chars; signs sessions and encrypts passphrases at rest |
| `FERRY_LISTEN_ADDR` | `:<FERRY_PORT>` | `host:port`; production `0.0.0.0:8080` or `127.0.0.1:8080` behind Caddy |
| `FERRY_PORT` | `8080` | Legacy fallback, used only when `FERRY_LISTEN_ADDR` is empty |
| `FERRY_MAX_TOTAL_BYTES` | `10737418240` (10 GiB) | Per job: uploads **plus** downloads |
| `FERRY_DATA_DIR` | `/data` | Created if missing; production `/var/lib/ferry` |
| `FERRY_COOKIE_SECURE` | `false` | Must be `true` only when served over HTTPS |
| `FERRY_TRUST_PROXY` | `false` | Read `X-Forwarded-For` (last valid hop) only behind a trusted proxy |
| `FERRY_PLATFORM` | `linux/amd64` | Platform of the base image; must match the destination |
| `DOCKERHUB_USERNAME` | required | Docker Hub username, not email |
| `DOCKERHUB_TOKEN` | required | PAT with Read, Write, Delete; never logged |
| `DOCKERHUB_REPO` | `ferry` | Single lowercase repository name |
| `FERRY_RETENTION_DAYS` | `0` | `0` disables automatic tag cleanup |
| `FERRY_DOMAIN` | empty | Informational for the Caddy example; unused by Ferry |
| `GITHUB_TOKEN` | empty | Optional; read-only token for the private release repository, used by `ferry check-update`, `ferry self-update`, and the home-page update banner. Never logged. |

Rules for adding a variable:

1. Parse and validate it in `internal/config/config.go`; add it to `Config`.
2. Add it to `.env.example` with a comment and a safe placeholder.
3. Add it to `deploy/ferry.env.example` if the installer should ship it.
4. Document it in `README.md` (both the setup steps and the reference notes).
5. If it is required, update the placeholder checks in `deploy/install.sh`.
6. Never make the app read a `.env` file. Never log the value of a secret.

Placeholder values (`CHANGE_ME`) are rejected for username, password, secret key
and Docker Hub credentials. The installer refuses to start the service while
required placeholders remain.

---

## 9. Security invariants (do not regress)

**Authentication and sessions**

- One user only. No registration, password reset, or multi-tenant concepts.
- Passwords: bcrypt when `FERRY_PASSWORD_HASH` is set, otherwise constant-time
  comparison. Username comparison is constant-time.
- Session cookie: HMAC-SHA256 signed, 12-hour expiry, `HttpOnly`,
  `SameSite=Strict`, `Secure` when configured. The CSRF token is inside the
  signed payload.
- Login throttling: 5 failures per IP in 10 minutes blocks that IP for 10
  minutes. `X-Forwarded-For` is honored only with `FERRY_TRUST_PROXY=true`, and
  only the last valid hop is trusted.

**HTTP**

- Every state-changing API request requires `X-Requested-With: Ferry` **and** a
  matching `X-CSRF-Token`. Page forms use a hidden `_csrf` field.
- Security headers: `nosniff`, `DENY`, `no-referrer`, and a strict CSP
  (`default-src 'self'`, no inline scripts/styles, no external origins).
- Authenticated pages send `Cache-Control: no-store`.
- JSON bodies are capped at 64 KiB; upload chunks are capped by the remaining
  declared size with `http.MaxBytesReader`.
- The HTTP server intentionally has **no** `ReadTimeout`/`WriteTimeout`:
  multi-gigabyte uploads and long downloads must not be killed. Keep
  `ReadHeaderTimeout`, `IdleTimeout`, and `MaxHeaderBytes`.

**URL downloads (SSRF)**

- Only `http`/`https`; max 4096 chars; reject control characters and userinfo.
- Block loopback, private, link-local, CGNAT, multicast, unspecified, reserved,
  documentation, and IPv4-mapped IPv6 ranges (`internal/downloader/ssrf.go`).
- The check runs in the dialer's `Control` hook on the **actual connected IP**,
  for every request and every redirect hop. This also defeats DNS rebinding.
- Proxy environment variables are ignored (`Proxy: nil`).
- Max 5 redirects; redirects to non-http(s) or credential-bearing URLs fail.
- Only a plain HTTP 200 is accepted. The size cap is enforced while streaming,
  even when `Content-Length` is missing or wrong. A 60-second stall aborts.

**Files and paths**

- Sanitize every untrusted filename with `safename.Sanitize`; enforce reserved
  names and uniqueness; reject names that change under sanitization.
- All job/file paths must stay under the data directory. Use
  `safename.JobDir` and `jobFilePath`; never concatenate user input into paths.
- Upload offsets must exactly match the server's received count.
- Job directories are `0750`; files and chunks are `0600`.

**Secrets and crypto**

- The Docker Hub token is never logged and is redacted from errors and job logs.
- The job passphrase is encrypted at rest with `internal/secretbox` (AES-GCM key
  derived from `FERRY_SECRET_KEY` via SHA-256 with a context string). It is
  cleared on every terminal transition and never written to logs.
- File encryption is AES-256-GCM in 1 MiB chunks with scrypt-derived keys; the
  header authenticates the plaintext size. Wrong passphrase must fail clearly.
- Do not invent custom crypto, weaken scrypt parameters, or reuse nonces.

**Deployment**

- The service runs as an unprivileged `ferry` user with systemd hardening
  (`NoNewPrivileges`, `PrivateTmp`, `ProtectSystem=strict`, `ProtectHome`,
  `ReadWritePaths=/var/lib/ferry`, etc.).
- No Docker socket is used or needed anywhere.
- The web app never replaces its own binary. `ferry self-update` is CLI-only,
  requires root, and verifies the release SHA-256 before the atomic rename.

---

## 10. Coding conventions

**Go**

- `gofmt` is the formatter; no project-specific style config.
- Add a package comment when creating a package, and document exported
  identifiers you add. (A few existing packages, such as `internal/jobs` and
  `internal/downloader`, currently lack a package comment; do not copy that.)
- Wrap errors with `%w` and context: `fmt.Errorf("download %s: %w", url, err)`.
  Use sentinel errors (`ErrQuota`, `ErrNotFound`, `ErrBlockedAddress`, …) when
  callers need `errors.Is`/`errors.As`.
- Internal error text is lowercase and specific. User-facing messages are
  complete sentences and actionable (the UI displays them verbatim).
- Pass `context.Context` as the first parameter through I/O paths; honor
  cancellation in loops and streams.
- Use `log/slog` with structured key/value pairs. Do not use `fmt.Println` in
  server code (CLI output is the exception). Never log secrets, passphrases, or
  full tokens.
- Guard shared state with mutexes; document what a mutex protects. Do not rely
  on the worker's panic recovery for normal error handling.
- Prefer small functions and explicit dependencies over globals. `cmd/ferry` is
  the composition root.

**HTTP / web**

- Register routes in `internal/web/server.go` with method+pattern
  (`"POST /api/jobs/{jobID}/start"`). Wrap pages with `pageAuth` and API routes
  with `apiAuth`; do not hand-roll session checks.
- Return JSON with `writeJSON`; return API errors with `jsonErrorMsg`. Keep the
  `{"error": "..."}` shape.
- New mutation routes automatically require CSRF through `apiAuth`; do not add
  an exemption.
- Templates are parsed at startup from `web/templates/*.html`; a syntax error
  prevents the server from starting. Each page is standalone (no shared base
  template).
- Static files are embedded at compile time (`//go:embed`). Editing
  `web/static/*` or templates requires a rebuild/restart; there is no live
  reload and no frontend build step.
- Frontend: vanilla JS in an IIFE, no dependencies, no bundler. Use the `api()`
  helper (it adds `X-Requested-With` and `X-CSRF-Token`). Use `data-page` and
  other `data-*` attributes for page wiring. No inline `onclick`, `<script>`, or
  `style=` attributes — the CSP blocks them. Poll job state every 2 seconds.

**Database**

- All access goes through `db.Store`. Do not open a second `*sql.DB`.
- Use `Transition` for request-driven state changes and `SetState` only from the
  worker. Keep writes short; do not hold `writeMu` during network I/O.
- Recalculate totals with `RecalcTotals` after file changes; do not maintain
  counters by hand in multiple places.

**Docs**

- `README.md` is for a Mac user deploying to Ubuntu 24.04 with no Go/Docker on
  the server. Keep commands copy-pasteable and expected output accurate.
- Local task notes (for example `TODO2`) are excluded via `.git/info/exclude`;
  they are not repository specs. Verify any request against the code.
- Update `AGENTS.md` when you introduce a new invariant, package, or workflow
  that future agents must know.

---

## 11. Testing

- Tests must not need network access, Docker Hub credentials, a Docker daemon,
  or a running server. Use `t.TempDir()` for files and `httptest` for HTTP.
- Table-driven tests are the norm. Test the security boundaries explicitly:
  SSRF ranges, URL validation, path traversal, reserved/colliding names, quota,
  upload offsets, CSRF/session parsing, encryption round-trips, checksum and
  manifest generation, and unpack behavior.
- `internal/imagebuild/layer_test.go` and `internal/securefile` tests cover the
  image format without a registry. Do not add tests that require a real push.
- Use `context.Background()` (the module targets Go 1.23; `t.Context()` needs
  Go 1.24). Avoid `time.Sleep` for synchronization.
- Run the full suite before finishing:

```bash
gofmt -l .
go vet ./...
go test ./...
```

- If you change compression/encryption, also reason about the macOS limitation:
  the end-to-end path requires Linux with a matching `FERRY_PLATFORM`; unit
  tests still must pass on any platform.

---

## 12. CI, releases, and deployment

`.github/workflows/build.yml`:

- **test** — on pushes to `main`, tags `v*`, pull requests, and manual dispatch:
  checkout, Go 1.23, `go mod download`, `go mod tidy`, `go vet ./...`,
  `go test ./...`.
- **build** — only for `v*` tags or `workflow_dispatch`; matrix `amd64`/`arm64`;
  `CGO_ENABLED=0`, `GOOS=linux`, `-trimpath`,
  `-ldflags "-s -w -X main.version=<tag or 7-char sha>"`. Packages
  `ferry-<version>-linux-<arch>.tar.gz` containing the binary, `deploy/`
  files, and `README.md`, plus a `.sha256` file. Artifacts expire after 30 days.
- **release** — tags only, `contents: write`, downloads artifacts and publishes
  a GitHub Release with generated notes.

Rules:

- The version defaults to `dev` in source; only `-ldflags` overrides it. Do not
  hardcode a release version in Go code.
- The package layout is part of the installer contract: `install.sh` expects
  `../ferry`, `ferry.service`, `ferry.env.example`, `Caddyfile.example`, and
  `../README.md`.
- `deploy/install.sh` must stay idempotent, root-only, `set -euo pipefail`, and
  safe for upgrades. It must never overwrite `/etc/ferry/ferry.env` or
  `/var/lib/ferry`, must install the binary atomically, and must not start the
  service while required placeholders remain.
- Do not add a Dockerfile, compose file, or a Docker-based deployment path.
- `ferry self-update` must stay root-only and CLI-only: it verifies the
  published SHA-256, checks the new binary, renames atomically, and restarts
  the `ferry` unit. Never expose binary replacement through the web API.

---

## 13. Common change recipes

**Add a configuration variable**

1. Parse/validate in `internal/config/config.go`; add the field to `Config`.
2. Add it to `.env.example` and `deploy/ferry.env.example`.
3. Document it in `README.md`.
4. If required, add a placeholder check to `deploy/install.sh`.
5. Add a test if validation is non-trivial.

**Add an API endpoint**

1. Add the route in `internal/web/server.go` with the right method and
   `apiAuth`/`pageAuth` wrapper.
2. Implement the handler in `internal/web/handlers.go`; decode with
   `decodeJSON`/`decodeOptionalJSON`, return `jsonErrorMsg` on failure.
3. Add the corresponding method to the relevant service (`jobs`, `uploads`, …),
   not directly in the handler.
4. Wire the frontend call through `api()` in `web/static/app.js`.
5. Add tests for the service logic and, where practical, the handler.

**Add or change a job state**

1. Add the constant in `internal/db/db.go` and update `IsActive`/`IsTerminal`.
2. Update every transition site in `internal/jobs/manager.go` and the state
   labels in the UI.
3. Update `Recover` for the new non-terminal state.
4. Update the History/Job templates and `app.js` if the UI must react.
5. Add a test for the transition and for restart recovery.

**Change the image format or unpack behavior**

1. Treat it as a compatibility change. Existing images must keep working.
2. Update `internal/imagebuild/layer.go` (stored names, sums, manifest),
   `cmd/ferry/unpack.go`, and the `data/` extraction in
   `cmd/ferry/download.go` together.
3. Update `README.md` and the in-image `README-FERRY.txt` text.
4. Add/extend tests for checksums, manifest entries, compression, encryption,
   and unpack round-trips.

**Add a database column**

1. Add the column to the `CREATE TABLE` statement (for new databases) and to
   `ensureColumn` (for upgrades).
2. Update the `Job`/`File`/`Upload` struct and all scan/insert/update queries.
3. Keep old databases readable; do not renumber or rename existing columns.

**Change the frontend**

1. Edit `web/static/app.js` and/or `web/static/style.css`; no build step.
2. Keep the CSP rules: no inline handlers, no external assets.
3. Use `api()` for requests so CSRF headers are sent.
4. Rebuild and restart to see embedded assets.

---

## 14. Known pitfalls and environment notes

- **`create-project.sh` was removed as stale.** Do not recreate it or treat a
  generated copy of the tree as the source of truth; the repository is the
  source of truth.
- **`.testdata/` and `.gocache/` are local artifacts.** They are gitignored;
  never commit them or use them as test fixtures.
- **`.env.example` is documentation only.** Ferry never reads `.env`; it reads
  process environment variables (systemd `EnvironmentFile` in production).
- **`internal/jobs/disk.go` uses `syscall.Statfs`.** It is Unix-only. The CI
  targets Linux; macOS works for development. Do not claim Windows support
  without replacing this.
- **Compression/encryption cannot be fully exercised on macOS.** The builder
  embeds the running binary and requires Linux with matching
  `FERRY_PLATFORM`. Use unit tests for the format and note the limitation.
- **No HTTP read/write timeouts by design.** Do not "fix" this; large transfers
  depend on it. Keep header and idle timeouts.
- **8 MiB upload chunks.** Any reverse proxy must allow at least 16 MiB request
  bodies and must not buffer or time out long requests. The supplied Caddyfile
  is fine; nginx needs `client_max_body_size 0;` and
  `proxy_request_buffering off;`.
- **`FERRY_COOKIE_SECURE=true` over plain HTTP breaks login** (the browser will
  not send the cookie). Use `false` for HTTP-only testing.
- **`FERRY_TRUST_PROXY=true` is only safe behind a trusted proxy.** Otherwise a
  client can spoof `X-Forwarded-For` and evade login throttling.
- **`FERRY_PLATFORM` must match the destination architecture.** Old images keep
  the platform they were built with.
- **Docker Hub 404 on tag deletion is success** ("already deleted"). 401/403
  usually means the token lacks Read, Write, Delete.
- **The job log is capped at 256 KiB.** Do not log per-chunk or per-byte lines.
- **Single SQLite connection.** Long-running writes block everything; keep them
  short and never hold the DB during network I/O.
- **`go mod tidy` runs in CI.** Keep `go.mod`/`go.sum` tidy and pinned; avoid
  floating versions.
- **`modernc.org/sqlite` is pure Go.** Keep `CGO_ENABLED=0` viable; do not add a
  CGO dependency.
- **The server parses templates at startup.** A malformed template is a startup
  failure, not a runtime 500.
- **Static assets are embedded.** A browser refresh alone will not show changes;
  rebuild/restart.

---

## 15. Definition of done

Before declaring a change complete:

- [ ] `gofmt -l .` prints nothing.
- [ ] `go vet ./...` passes.
- [ ] `go test ./...` passes.
- [ ] New behavior has tests, especially security boundaries.
- [ ] `README.md`, `.env.example`, and `deploy/ferry.env.example` are updated if
      configuration or user-visible behavior changed.
- [ ] No secret, token, passphrase, or real credential is in the diff.
- [ ] Existing SQLite databases and already-pushed images remain compatible.
- [ ] The strict CSP still holds (no inline scripts/styles, no external assets).
- [ ] `bash -n deploy/install.sh` passes if the installer changed.
- [ ] The CI workflow remains valid YAML and its package layout still matches
      `install.sh`.
- [ ] The diff is focused; unrelated refactors are not mixed in.

---

## 16. References

- `README.md` — end-user setup, deployment, usage, troubleshooting, security
  notes, manual test checklist.
- `.env.example` — annotated configuration reference for manual runs.
- `deploy/ferry.env.example` — production configuration template.
- `deploy/install.sh` — installer/upgrader contract.
- `deploy/ferry.service` — systemd unit and hardening.
- `deploy/Caddyfile.example` — HTTPS reverse-proxy example.
- Local task notes (for example `TODO2`) — excluded from git via
  `.git/info/exclude`; not authoritative.
