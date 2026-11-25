#!/usr/bin/env bash
# Recreates the complete Ferry project tree in the current directory.
# Usage: bash create-project.sh
set -euo pipefail

if [[ -e go.mod ]]; then
  echo "ERROR: go.mod already exists here. Run this script in an empty directory." >&2
  exit 1
fi

mkdir -p '.github/workflows'
mkdir -p 'cmd/ferry'
mkdir -p 'deploy'
mkdir -p 'internal/auth'
mkdir -p 'internal/config'
mkdir -p 'internal/db'
mkdir -p 'internal/dockerhub'
mkdir -p 'internal/downloader'
mkdir -p 'internal/imagebuild'
mkdir -p 'internal/jobs'
mkdir -p 'internal/safename'
mkdir -p 'internal/secretbox'
mkdir -p 'internal/securefile'
mkdir -p 'internal/uploads'
mkdir -p 'internal/web'
mkdir -p 'web'
mkdir -p 'web/static'
mkdir -p 'web/templates'

cat > '.env.example' <<'FERRY_EOF_1'
# ── Ferry configuration reference ────────────────────────────────────────────
# This file is a reference for running Ferry manually (for example during
# development). Production uses /etc/ferry/ferry.env, created by
# deploy/install.sh from deploy/ferry.env.example. Ferry reads environment
# variables only; it never reads a file named .env by itself.

# Single login user. Password is compared in constant time.
FERRY_USERNAME=CHANGE_ME
FERRY_PASSWORD=CHANGE_ME
# Optional: use a bcrypt hash instead of FERRY_PASSWORD.
# Generate one with: ferry hash-password
# FERRY_PASSWORD_HASH=$2a$10$...

# Session signing key. Generate with: openssl rand -hex 32
# Must be at least 32 characters. Keep it secret.
FERRY_SECRET_KEY=CHANGE_ME

# Listen address. Use 0.0.0.0:8080 when Ferry is exposed directly, or
# 127.0.0.1:8080 when it runs behind Caddy on the same machine.
FERRY_LISTEN_ADDR=0.0.0.0:8080

# Total cap per job: uploaded files + downloaded files. 10737418240 = 10 GiB.
FERRY_MAX_TOTAL_BYTES=10737418240

# Where Ferry stores its SQLite database and temporary job files.
# For a systemd install use /var/lib/ferry (created by deploy/install.sh).
FERRY_DATA_DIR=/var/lib/ferry

# Set to true when the site is served over HTTPS (for example with Caddy).
FERRY_COOKIE_SECURE=false

# Set to true ONLY when Ferry is behind a trusted reverse proxy such as Caddy,
# so it can read the client IP from X-Forwarded-For for login throttling.
FERRY_TRUST_PROXY=false

# Platform of the busybox base image. Use linux/arm64 on ARM servers.
FERRY_PLATFORM=linux/amd64

# Docker Hub. Create a PRIVATE repository named ferry and a Personal Access
# Token with Read, Write and Delete permission.
DOCKERHUB_USERNAME=CHANGE_ME
DOCKERHUB_TOKEN=CHANGE_ME
DOCKERHUB_REPO=ferry

# 0 disables automatic Docker Hub tag cleanup. Otherwise old images are deleted
# after this many days (checked hourly).
FERRY_RETENTION_DAYS=0

# Informational only for the Caddy example; Ferry itself does not use it.
FERRY_DOMAIN=ferry.example.com
FERRY_EOF_1

cat > '.github/workflows/build.yml' <<'FERRY_EOF_2'
name: Build Ferry

on:
  push:
    branches: [main]
    tags: ["v*"]
  workflow_dispatch:

# The build job only reads the repository. The release job needs write access.
permissions:
  contents: read

jobs:
  test:
    name: Vet and test
    runs-on: ubuntu-24.04
    steps:
      - name: Check out source
        uses: actions/checkout@v4

      - name: Install Go 1.23
        uses: actions/setup-go@v5
        with:
          go-version: "1.23"
          cache: false

      # Dependencies are pinned in go.mod/go.sum. Download them and verify the
      # module files are tidy instead of resolving versions at build time.
      - name: Resolve dependencies
        shell: bash
        env:
          GOTOOLCHAIN: local
        run: |
          go mod download
          go mod tidy

      - name: Vet
        env:
          GOTOOLCHAIN: local
        run: go vet ./...

      - name: Test
        env:
          GOTOOLCHAIN: local
        run: go test ./...

  build:
    name: Package (${{ matrix.goarch }})
    needs: test
    runs-on: ubuntu-24.04
    strategy:
      fail-fast: false
      matrix:
        goarch: [amd64, arm64]
    steps:
      - name: Check out source
        uses: actions/checkout@v4

      - name: Install Go 1.23
        uses: actions/setup-go@v5
        with:
          go-version: "1.23"
          cache: false

      - name: Decide version
        id: version
        shell: bash
        run: |
          if [[ "${GITHUB_REF_TYPE}" == "tag" ]]; then
            version="${GITHUB_REF_NAME}"
          else
            version="${GITHUB_SHA::7}"
          fi
          echo "value=${version}" >> "${GITHUB_OUTPUT}"

      - name: Resolve dependencies
        shell: bash
        env:
          GOTOOLCHAIN: local
        run: |
          go mod download
          go mod tidy

      - name: Build static binary
        shell: bash
        env:
          GOTOOLCHAIN: local
          CGO_ENABLED: "0"
          GOOS: linux
          GOARCH: ${{ matrix.goarch }}
          VERSION: ${{ steps.version.outputs.value }}
        run: |
          go build -trimpath \
            -ldflags "-s -w -X main.version=${VERSION}" \
            -o ferry ./cmd/ferry

      - name: Package release archive
        shell: bash
        env:
          GOARCH: ${{ matrix.goarch }}
          VERSION: ${{ steps.version.outputs.value }}
        run: |
          set -euo pipefail
          package_dir="package"
          rm -rf "${package_dir}"
          mkdir -p "${package_dir}/deploy"
          cp ferry "${package_dir}/ferry"
          cp deploy/install.sh deploy/ferry.service deploy/ferry.env.example \
            deploy/Caddyfile.example "${package_dir}/deploy/"
          cp README.md "${package_dir}/README.md"
          chmod 0755 "${package_dir}/ferry" "${package_dir}/deploy/install.sh"
          archive="ferry-${VERSION}-linux-${GOARCH}.tar.gz"
          tar -C "${package_dir}" -czf "${archive}" .
          sha256sum "${archive}" > "${archive}.sha256"

      - name: Upload package
        uses: actions/upload-artifact@v4
        with:
          name: ferry-${{ steps.version.outputs.value }}-linux-${{ matrix.goarch }}
          path: |
            ferry-${{ steps.version.outputs.value }}-linux-${{ matrix.goarch }}.tar.gz
            ferry-${{ steps.version.outputs.value }}-linux-${{ matrix.goarch }}.tar.gz.sha256
          retention-days: 30

  release:
    name: Publish GitHub Release
    if: startsWith(github.ref, 'refs/tags/v')
    needs: build
    runs-on: ubuntu-24.04
    permissions:
      contents: write
    steps:
      - name: Download all packages
        uses: actions/download-artifact@v4
        with:
          pattern: ferry-*
          path: dist
          merge-multiple: true

      - name: Publish release
        uses: softprops/action-gh-release@v2
        with:
          files: dist/*
          generate_release_notes: true
FERRY_EOF_2

cat > '.gitignore' <<'FERRY_EOF_3'
.env
.env.*
*.env
!.env.example
data/
.gocache/
.testdata/
/ferry
*.db
*.db-shm
*.db-wal
.DS_Store
FERRY_EOF_3

cat > 'README.md' <<'FERRY_EOF_4'
# Ferry

Ferry is a small self-hosted web application that packs uploaded files (and/or
public download links) into a **private Docker Hub image** and shows you the
image name. On another machine you pull that image and extract the files, so the
two machines never need a direct file transfer.

Ferry is written in pure Go. It **does not use Docker, the Docker CLI, the
Docker daemon, or `/var/run/docker.sock`**. It builds the image in pure Go with
`github.com/google/go-containerregistry` and pushes it straight to Docker Hub.
There is no local image to clean up. On the server Ferry runs as an unprivileged
systemd service under the `ferry` user.

You do **not** need Go, Docker, or Python on the Ubuntu server. GitHub Actions
builds a single static binary; you download it and run the installer.

---

## What you need

- A **Mac** with Terminal (for `scp`).
- A **private GitHub repository** containing this project.
- An **Ubuntu Server 24.04 LTS** VPS (amd64 or arm64) with at least 20 GB free
  disk and root/sudo access.
- A **Docker Hub** account and a **private repository named `ferry`**.
- Optional: a domain name for automatic HTTPS.

Disk rule: Ferry requires free space of at least **1.5 × the largest job size**
before it starts a job, and refuses with a clear message otherwise. Uploaded and
downloaded files are deleted as soon as a job finishes or fails.

Ferry needs **outbound HTTPS (port 443)** to:

- `registry-1.docker.io` and `auth.docker.io` — pushing image data
- `hub.docker.com` — deleting tags
- any public site you paste as a download URL

Inbound, you only need the web port (8080), plus 80/443 if you enable Caddy.

---

## Project layout

```text
cmd/ferry/            entrypoint, --version, hash-password, graceful shutdown
internal/config/      environment validation
internal/auth/        signed sessions, bcrypt/constant-time login, throttling
internal/db/          SQLite schema and metadata queries
internal/uploads/     resumable chunked uploads and quota rules
internal/downloader/  SSRF-safe streaming downloads
internal/imagebuild/  pure-Go image layers, compression, encryption, push
internal/securefile/  streaming AES-256-GCM file encryption
internal/secretbox/   encrypts the job passphrase at rest
internal/dockerhub/   tag deletion through the Docker Hub HTTP API
internal/jobs/        single worker, queue, cancel, recovery, cleanup, retention
internal/web/         HTML handlers, JSON API, CSRF and security headers
web/templates/        embedded HTML templates
web/static/           embedded CSS and vanilla JavaScript
deploy/               systemd unit, installer, env example, Caddy example
.github/workflows/    GitHub Actions build/release workflow
```

Dependencies are pinned in `go.mod` and `go.sum`. The CI workflow downloads
them, verifies they are tidy, and builds a static binary.

---

## Step 1 — Put the project on GitHub

1. In a browser, open <https://github.com/new>.
2. Repository name: `ferry`. Select **Private**. Do **not** add a README,
   `.gitignore`, or license. Click **Create repository**.
3. On the empty repository page click **Add file → Upload files**.
4. Drag the whole project folder contents (not the folder itself) into the
   browser. Make sure these are included:
   - `go.mod`, `go.sum`
   - `cmd/`, `internal/`, `web/`
   - `deploy/`, `.github/`
   - `README.md`, `.gitignore`
5. Click **Commit changes**.
6. Open the **Actions** tab. A run named **Build Ferry** starts automatically.
   Wait until both **Vet and test** and **Package (amd64)** / **Package (arm64)**
   show green check marks. A first run takes a few minutes.

If the run is red, click it, open the failing step, and read the last lines.
The most common cause is a missing file in the upload.

> Never commit real secrets. `.gitignore` already excludes `.env`, `*.env`,
> `data/`, and the built `ferry` binary. Configuration lives only on the server
> in `/etc/ferry/ferry.env`.

---

## Step 2 — Create a release and download the binary

1. In the repository, click **Releases** (right sidebar) → **Draft a new
   release**.
2. Click **Choose a tag**, type `v1.0.0`, and click **Create new tag on
   publish**.
3. Title: `v1.0.0`. Click **Publish release**.
4. A new **Build Ferry** run starts for the tag. Wait for it to finish.
5. Reload the release page. Under **Assets** you should see:
   - `ferry-v1.0.0-linux-amd64.tar.gz`
   - `ferry-v1.0.0-linux-amd64.tar.gz.sha256`
   - `ferry-v1.0.0-linux-arm64.tar.gz`
   - `ferry-v1.0.0-linux-arm64.tar.gz.sha256`
6. Download the `amd64` archive (use `arm64` only for ARM servers).

For a normal push to `main` (no tag), the packages are **not** on the Releases
page. Open **Actions → the run → Artifacts** and download
`ferry-<short-sha>-linux-amd64`. Those artifacts expire after **30 days**.

Each archive contains:

```text
ferry
deploy/install.sh
deploy/ferry.service
deploy/ferry.env.example
deploy/Caddyfile.example
README.md
```

---

## Step 3 — Create the private Docker Hub repository and token

1. Log in at <https://hub.docker.com>.
2. **Repositories → Create repository**.
3. Name: **`ferry`**. Visibility: **Private**. Create.
4. Avatar → **Account settings** → **Security** → **New access token**.
5. Name it `ferry-vps`, select **Read, Write, Delete**, create it.
6. Copy the token immediately (Docker Hub shows it once).

Keep the token somewhere safe for now. You will paste it into
`/etc/ferry/ferry.env` as `DOCKERHUB_TOKEN` in Step 6, after the installer has
created that file.

Do **not** use your Docker Hub account password as the token.

---

## Step 4 — Copy the archive to the server

On your Mac, in Terminal, from the folder where the archive was downloaded
(usually `~/Downloads`):

```bash
cd ~/Downloads
scp ferry-v1.0.0-linux-amd64.tar.gz youruser@YOUR_SERVER_IP:/tmp/
```

Replace `youruser` with your Ubuntu login and `YOUR_SERVER_IP` with the server's
IP address. Enter your SSH password when asked.

Then connect:

```bash
ssh youruser@YOUR_SERVER_IP
```

On the server:

```bash
mkdir -p ~/ferry-v1.0.0
tar -xzf /tmp/ferry-v1.0.0-linux-amd64.tar.gz -C ~/ferry-v1.0.0
cd ~/ferry-v1.0.0
ls
```

Expected output:

```text
README.md  deploy  ferry
```

Optional integrity check:

```bash
sha256sum -c /tmp/ferry-v1.0.0-linux-amd64.tar.gz.sha256
```

It must print `OK` (run it in `/tmp` where the archive is).

---

## Step 5 — Run the installer

```bash
cd ~/ferry-v1.0.0
sudo ./deploy/install.sh
```

The installer:

- creates the `ferry` system user (no login shell) and group,
- creates `/var/lib/ferry` (owner `ferry`, mode 0750) and `/etc/ferry`,
- installs `/usr/local/bin/ferry`,
- on first install copies `deploy/ferry.env.example` to
  `/etc/ferry/ferry.env`, sets mode `0640 root:ferry`, and generates a random
  `FERRY_SECRET_KEY`,
- installs and enables the systemd unit,
- **does not start Ferry** while the required values are still `CHANGE_ME`.

Expected output on first install:

```text
======================================================================
 Ferry is installed, but it is NOT running yet.
 Edit the required values first:

   sudo nano /etc/ferry/ferry.env

 Replace CHANGE_ME for FERRY_USERNAME, FERRY_PASSWORD,
 DOCKERHUB_USERNAME and DOCKERHUB_TOKEN.
 Then start it with:

   sudo systemctl restart ferry
   sudo systemctl status ferry
======================================================================
```

---

## Step 6 — Edit the configuration

```bash
sudo nano /etc/ferry/ferry.env
```

Set:

```dotenv
FERRY_USERNAME=yourname
FERRY_PASSWORD=a-long-password-you-will-remember
FERRY_SECRET_KEY=already-generated-for-you
FERRY_LISTEN_ADDR=0.0.0.0:8080
FERRY_DATA_DIR=/var/lib/ferry
DOCKERHUB_USERNAME=your-dockerhub-username
DOCKERHUB_TOKEN=the-token-you-created
DOCKERHUB_REPO=ferry
```

Keep the other defaults for now:

```dotenv
FERRY_MAX_TOTAL_BYTES=10737418240
FERRY_COOKIE_SECURE=false
FERRY_TRUST_PROXY=false
FERRY_PLATFORM=linux/amd64
FERRY_RETENTION_DAYS=0
```

Notes:

- `FERRY_LISTEN_ADDR` is the single way to choose the address. Use
  `0.0.0.0:8080` when exposing Ferry directly, or `127.0.0.1:8080` behind Caddy
  on the same machine.
- `FERRY_MAX_TOTAL_BYTES` is per job: uploads **plus** downloaded URLs.
- `FERRY_PLATFORM` is the platform of the `busybox:stable` base image. Use
  `linux/arm64` if the destination machine is ARM.
- `FERRY_RETENTION_DAYS=0` disables automatic Docker Hub cleanup. A positive
  number deletes image tags after that many days (checked hourly).
- In `nano`: save with `Ctrl+O`, press Enter, exit with `Ctrl+X`.

### Optional: store a bcrypt hash instead of a plain password

Ferry accepts either `FERRY_PASSWORD` (compared in constant time) or
`FERRY_PASSWORD_HASH` (bcrypt). To generate a hash:

```bash
sudo /usr/local/bin/ferry hash-password
```

Type the password (input is hidden), press Enter, and copy the printed
`$2a$...` value into:

```dotenv
FERRY_PASSWORD_HASH=$2a$10$...
```

Then remove or comment out `FERRY_PASSWORD`. If both are set, the hash wins.

---

## Step 7 — Start Ferry

```bash
sudo systemctl restart ferry
sudo systemctl status ferry
```

Expected status contains:

```text
Active: active (running)
```

Follow the logs:

```bash
sudo journalctl -u ferry -f
```

You should see:

```text
level=INFO msg="Ferry is running" addr=0.0.0.0:8080 ...
```

Press `Ctrl+C` to stop following logs (Ferry keeps running).

Check the version and health:

```bash
/usr/local/bin/ferry --version
curl http://127.0.0.1:8080/health
```

Expected:

```text
ferry v1.0.0
ok
```

Open `http://YOUR_SERVER_IP:8080` in a browser and log in.

### Open the firewall

```bash
sudo ufw allow 22/tcp
sudo ufw allow 8080/tcp
sudo ufw enable
sudo ufw status
```

Many cloud providers (Hetzner, DigitalOcean, AWS, Oracle, etc.) also have a
firewall in their web console. Open TCP 8080 there too.

---

## Step 8 — Optional automatic HTTPS with Caddy

You need a domain name. Create a DNS **A record** pointing at the server's IPv4
address (and AAAA for IPv6). Wait until it resolves:

```bash
dig +short ferry.example.com
```

Install Caddy from the official apt repository:

```bash
sudo apt-get install -y debian-keyring debian-archive-keyring apt-transport-https curl
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
  | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
  | sudo tee /etc/apt/sources.list.d/caddy-stable.list
sudo chmod o+r /usr/share/keyrings/caddy-stable-archive-keyring.gpg
sudo chmod o+r /etc/apt/sources.list.d/caddy-stable.list
sudo apt-get update
sudo apt-get install -y caddy
```

Copy the example Caddyfile and set your domain:

```bash
sudo cp ~/ferry-v1.0.0/deploy/Caddyfile.example /etc/caddy/Caddyfile
sudo nano /etc/caddy/Caddyfile
```

Change `ferry.example.com` to your domain, save, then update
`/etc/ferry/ferry.env`:

```dotenv
FERRY_LISTEN_ADDR=127.0.0.1:8080
FERRY_COOKIE_SECURE=true
FERRY_TRUST_PROXY=true
FERRY_DOMAIN=ferry.example.com
```

Restart both services:

```bash
sudo systemctl restart ferry
sudo systemctl reload caddy
sudo systemctl status caddy
```

Open ports 80 and 443 and close the temporary direct 8080 access:

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw delete allow 8080/tcp
sudo ufw status
```

Open `https://ferry.example.com`. Caddy obtains and renews the certificate
automatically; the first request can take up to a minute. Check:

```bash
sudo journalctl -u caddy -f
```

If the certificate fails: confirm DNS, that ports 80/443 are reachable from the
internet, and that no other web server owns those ports.

---

## How to use Ferry

1. Log in. The home page shows the **current job** if one is running.
2. Click **New transfer**.
3. Add files by drag-and-drop or by choosing them. Files upload in 8 MiB chunks
   and resume automatically after a short network interruption.
4. Or paste one or more public `http://` / `https://` download URLs.
5. Watch the total size. **Start transfer** is disabled when there is nothing
   added or the total exceeds the limit.
6. Optionally open **Compress and encrypt files**:
   - **Passphrase** encrypts every file with AES-256-GCM before packing. The
     destination needs this passphrase to unpack.
   - **Compress files with gzip** stores a `.gz` version when it is smaller.
   Ferry stores only an encrypted copy of the passphrase and deletes it when the
   job finishes. Compression and encryption require `FERRY_PLATFORM` to match
   the server architecture (normally `linux/amd64`), because the image ships a
   copy of the running Ferry binary as the unpack tool.
7. Press **Start transfer**. The page shows the live state, per-URL download
   progress, push bytes, and a log, refreshed every 2 seconds.
8. Use **Cancel transfer** to stop a queued or running job. Temporary files are
   deleted.
9. When done, copy the image name and the commands for the destination machine.

On the destination machine:

```bash
docker login
docker pull youruser/ferry:job-20261124-153012-a1b2
docker create --name ferry-tmp youruser/ferry:job-20261124-153012-a1b2
docker cp ferry-tmp:/data ./ferry-files
docker rm ferry-tmp
cd ferry-files && sha256sum -c SHA256SUMS
```

If the job used compression or a passphrase, replace the last line with:

```bash
docker run --rm -it -v "$PWD/ferry-files:/work" --entrypoint /data/ferry <image> unpack --dir /work
cd ferry-files && sha256sum -c SHA256SUMS
```

Running the unpack tool inside the image works on macOS, Windows and Linux and
always uses the correct CPU architecture. On a Linux destination you can also
run the copied tool directly:

```bash
cd ferry-files
./ferry unpack
```

`ferry unpack` verifies `SHA256SUMS`/`MD5SUMS`, decrypts `.ferry` files
(prompting for the passphrase), decompresses `.gz` files, and writes the
original filenames. Use `--verify-only` to check without unpacking, or
`--passphrase '...'` for non-interactive use.

The image contains `data/SHA256SUMS`, `data/MD5SUMS`,
`data/FERRY-MANIFEST.json`, and one layer per file.
Compressed files are stored as `<name>.gz`, encrypted files as
`<name>.ferry`, and both as `<name>.gz.ferry`. Working directory is `/data`,
command is `sh`, base image is `busybox:stable`.

### History page

- **Open** — return to a job.
- **Cancel** — stop a queued or running job.
- **Delete image** — remove the tag from Docker Hub, keep the history record.
- **Delete record** — remove the SQLite record. It does **not** delete the tag.
- **Delete all images older than N days** — bulk-delete Docker Hub tags for
  finished jobs. History records stay.

A 404 from Docker Hub during deletion is treated as success ("already
deleted"). A 401/403 means the token lacks **Read, Write, Delete** permission.

---

## Upgrading and rolling back

Download the new release on your Mac, copy it, extract it, and run the same
installer:

```bash
# on the Mac
cd ~/Downloads
scp ferry-v1.0.1-linux-amd64.tar.gz youruser@YOUR_SERVER_IP:/tmp/

# on the server
mkdir -p ~/ferry-v1.0.1
tar -xzf /tmp/ferry-v1.0.1-linux-amd64.tar.gz -C ~/ferry-v1.0.1
cd ~/ferry-v1.0.1
sudo ./deploy/install.sh
```

The installer never overwrites `/etc/ferry/ferry.env` or `/var/lib/ferry`, so
configuration and history are preserved.

To **roll back**, download the previous release and run its `install.sh` the
same way. The binary is replaced; data and configuration stay.

Back up before major upgrades:

```bash
sudo systemctl stop ferry
sudo tar czf ~/ferry-backup-$(date +%F).tar.gz /var/lib/ferry /etc/ferry/ferry.env
sudo systemctl start ferry
```

Copy the backup off the server with `scp`.

---

## Viewing logs and managing the service

```bash
sudo systemctl status ferry
sudo journalctl -u ferry -f
sudo journalctl -u ferry --since "1 hour ago"
sudo systemctl restart ferry
sudo systemctl stop ferry
sudo systemctl start ferry
```

The application log also appears on each job page, so you usually do not need
the system log to diagnose a failed transfer.

---

## Optional: run the unit tests

The tests need no Docker Hub credentials and no Docker daemon. They do need
internet access to download Go modules. They run in a throwaway Go container on
the server:

```bash
cd ~/ferry-v1.0.0
sudo docker run --rm -v "$PWD":/src:ro -w /tmp golang:1.23-alpine sh -c '
  apk add --no-cache ca-certificates git &&
  cp -a /src /work && cd /work &&
  go mod download &&
  go test ./...
'
```

If Docker is not installed on the server, run the same commands on any machine
with Go 1.23 or newer. All tests should end with `ok`.

---

## Manual test checklist

Use a small private `ferry` repository while testing.

1. **Login** — log in; the dashboard appears. Enter a wrong password five times;
   the next attempt is blocked for 10 minutes.
2. **Small upload** — create a transfer, upload a small text file, confirm the
   total size, press Start, and wait for `done`. Copy the image name.
3. **1 GB upload with an interruption** — start a 1 GB upload, set the browser
   to Offline for a few seconds (DevTools → Network), then go back online.
   Progress must resume from the server's received offset, not restart at zero.
4. **URL download** — add `https://example.com/`, Start, and confirm progress in
   the log and the final extracted file.
5. **Blocked internal URL** — add `http://127.0.0.1/` and Start. The job must
   fail with a clear "blocked address" message, and
   `/var/lib/ferry/jobs/<job-id>` must be gone afterwards.
6. **Exceeding the size cap** — set `FERRY_MAX_TOTAL_BYTES=104857600` (100 MiB),
   restart Ferry, and try a larger file. It is rejected immediately with HTTP
   413 and a readable message.
7. **Successful push** — with real Docker Hub credentials, finish a job and
   confirm the image appears in the private Docker Hub repository.
8. **Pull and verify** — on another machine run the commands from the done
   page. `sha256sum -c SHA256SUMS` prints `OK` for every file, and
   `md5sum -c MD5SUMS` does too.
9. **Compress and encrypt** — create a job with a passphrase and compression
   enabled, upload a text file, finish the push, pull it elsewhere, run
   `./ferry unpack`, enter the passphrase, and confirm the original file is
   restored. Try a wrong passphrase; it must fail with a clear error.
10. **Cleanup** — on the server run
    `sudo ls -la /var/lib/ferry/jobs`. The finished job's directory must be gone.
11. **Cancel** — start a large job and press **Cancel transfer**. The job becomes
    `failed` with "cancelled by user" and its directory is removed.
12. **Delete the tag** — on the History page click **Delete image**, confirm the
    tag disappears from Docker Hub, then repeat with **Delete all images older
    than N days**.

---

## Troubleshooting

### The service does not start

```bash
sudo systemctl status ferry
sudo journalctl -u ferry -n 100 --no-pager
```

The first lines usually name the exact problem. Common causes:

- `CHANGE_ME` still present in `/etc/ferry/ferry.env`
- `FERRY_SECRET_KEY` shorter than 32 characters
- `FERRY_LISTEN_ADDR` not in `host:port` form
- missing `DOCKERHUB_USERNAME` or `DOCKERHUB_TOKEN`
- `FERRY_PLATFORM` not `linux/amd64` / `linux/arm64`

Fix the file, then:

```bash
sudo systemctl restart ferry
```

### "permission denied" on `/var/lib/ferry`

The service runs as `ferry`. Check ownership:

```bash
sudo ls -ld /var/lib/ferry
sudo chown -R ferry:ferry /var/lib/ferry
sudo chmod 0750 /var/lib/ferry
```

### Port already in use

```bash
sudo ss -ltnp | grep 8080
```

Change `FERRY_LISTEN_ADDR` in `/etc/ferry/ferry.env` to another free port, open
it in `ufw`, and restart.

### "RBAC: access denied", 401, or 403

- The Docker Hub token must have **Read, Write, and Delete** permission.
- `DOCKERHUB_USERNAME` must be your Docker Hub **username**, not your email.
- The repository named by `DOCKERHUB_REPO` (default `ferry`) must exist and be
  **Private**.
- Do not use your account password as `DOCKERHUB_TOKEN`; create a Personal
  Access Token.
- Regenerate the token, update the env file, and restart.

### Disk full / "not enough free disk space"

Ferry needs 1.5× the job size free. Check:

```bash
df -h
sudo du -sh /var/lib/ferry/*
```

Ferry removes every job directory in every outcome, so the data directory
should stay small unless a job is active. Old images on Docker Hub do not use
server disk. Enable `FERRY_RETENTION_DAYS` to clean up Docker Hub tags.

### "exec format error" or wrong architecture

The image platform comes from `FERRY_PLATFORM` and defaults to `linux/amd64`.
On an ARM destination set:

```dotenv
FERRY_PLATFORM=linux/arm64
```

Restart Ferry and create a new job. Old images keep the platform they were
built with.

### Uploads fail, stall, or return 413

- Ferry sends 8 MiB chunks. Any proxy in front of Ferry must allow at least
  16 MiB request bodies and must not buffer or time out long requests.
- With Caddy, the supplied `Caddyfile.example` needs no body-size change.
- With nginx, set `client_max_body_size 0;` (or at least `16m`) and
  `proxy_request_buffering off;`.
- When Ferry is served over HTTPS, set `FERRY_COOKIE_SECURE=true`. If you set it
  while using plain HTTP, the browser will not send the session cookie and login
  will loop. Set it back to `false` for HTTP-only testing.
- Behind Caddy or another trusted proxy, set `FERRY_TRUST_PROXY=true` so login
  throttling sees the real client IP. Do **not** enable it when Ferry is
  exposed directly.

### GitHub Actions fails during "go mod tidy" or "go get"

The workflow needs internet access to `proxy.golang.org` and `github.com`.
GitHub-hosted runners normally have it. If the failure says a module version is
unknown, check that the pinned versions in `.github/workflows/build.yml` still
exist:

```text
github.com/google/go-containerregistry@v0.20.3
modernc.org/sqlite@v1.29.10
golang.org/x/crypto@v0.31.0
```

### The release has no assets

Assets are uploaded only by the **release** job, which runs for tags starting
with `v`. Make sure the tag is exactly `v1.0.0` (lowercase `v`) and that the
**build** job finished successfully. For non-tag runs use the **Artifacts**
section of the run instead; those expire after 30 days.

### Caddy certificate does not appear

- DNS A/AAAA must point at this server.
- Ports 80 and 443 must be open in `ufw` **and** the cloud firewall.
- No other service (nginx/Apache) may own ports 80/443.
- Check `sudo journalctl -u caddy -n 100 --no-pager`.

### Where are job files kept?

Temporarily in `/var/lib/ferry/jobs/<job-id>`. They are deleted on success,
failure, cancellation, restart recovery, and stale-draft cleanup (drafts
untouched for 24 hours). Only metadata and logs remain in
`/var/lib/ferry/ferry.db`.

---

## Security notes

- Single user. Passwords use bcrypt when `FERRY_PASSWORD_HASH` is set, otherwise
  constant-time comparison.
- Signed, HttpOnly, SameSite=Strict session cookie with a 12-hour expiry.
- Per-session CSRF token plus a custom `X-Requested-With` header for API calls.
- Login throttling: five failures from one IP in ten minutes blocks that IP for
  ten minutes. `X-Forwarded-For` is read only when `FERRY_TRUST_PROXY=true`, and
  only the last hop is trusted.
- Content-Security-Policy allows same-origin scripts/styles only; no CDN, no
  external fonts, no inline scripts.
- URL downloads reject loopback, private, link-local, CGNAT, multicast,
  unspecified and reserved addresses, including IPv4-mapped IPv6 addresses. The
  check runs on the actual connected IP for every redirect hop, which also
  defeats DNS rebinding. Proxy environment variables are ignored.
- Download size is capped while streaming even when `Content-Length` is missing
  or wrong.
- Optional file encryption uses AES-256-GCM in 1 MiB chunks with a key derived
  by scrypt from the job passphrase. The passphrase is stored encrypted at rest
  with `FERRY_SECRET_KEY`, never logged, and deleted when the job finishes.
- The Docker Hub token is never logged and is redacted from error messages.
- systemd hardening: `NoNewPrivileges`, `PrivateTmp`, `ProtectSystem=strict`,
  `ProtectHome`, `ReadWritePaths=/var/lib/ferry`, and a dedicated unprivileged
  user.
- No Docker socket is used or needed anywhere.
FERRY_EOF_4

cat > 'cmd/ferry/main.go' <<'FERRY_EOF_5'
package main

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"golang.org/x/term"

	"ferry/internal/auth"
	"ferry/internal/config"
	"ferry/internal/db"
	"ferry/internal/dockerhub"
	"ferry/internal/downloader"
	"ferry/internal/imagebuild"
	"ferry/internal/jobs"
	"ferry/internal/uploads"
	"ferry/internal/web"
)

// version is injected at build time with -ldflags "-X main.version=...".
var version = "dev"

func main() {
	if len(os.Args) > 1 {
		switch os.Args[1] {
		case "--version", "-version", "version":
			fmt.Printf("ferry %s\n", version)
			return
		case "hash-password":
			if err := hashPassword(); err != nil {
				fmt.Fprintf(os.Stderr, "Could not hash the password: %v\n", err)
				os.Exit(1)
			}
			return
		case "unpack":
			if err := unpackCommand(os.Args[2:]); err != nil {
				fmt.Fprintf(os.Stderr, "Unpack failed: %v\n", err)
				os.Exit(1)
			}
			return
		case "--help", "-help", "help":
			printUsage()
			return
		}
	}
	if err := run(); err != nil {
		fmt.Fprintf(os.Stderr, "\nFerry could not start:\n\n%v\n\n", err)
		os.Exit(1)
	}
}

func printUsage() {
	fmt.Print(`Ferry - pack files into a private Docker Hub image.

Usage:
  ferry                 start the web server (configuration comes from environment variables)
  ferry --version       print the version
  ferry hash-password   read a password from the terminal and print a bcrypt hash
  ferry unpack          verify, decrypt and decompress files inside an image
  ferry help            show this help

The hash-password output is used as FERRY_PASSWORD_HASH in the environment file.
`)
}

func hashPassword() error {
	var password string
	if term.IsTerminal(int(os.Stdin.Fd())) {
		fmt.Fprint(os.Stderr, "New password (typing is hidden): ")
		raw, err := term.ReadPassword(int(os.Stdin.Fd()))
		fmt.Fprintln(os.Stderr)
		if err != nil {
			return err
		}
		password = string(raw)
	} else {
		reader := bufio.NewReader(os.Stdin)
		line, err := reader.ReadString('\n')
		if err != nil && line == "" {
			return err
		}
		password = strings.TrimRight(line, "\r\n")
	}
	if password == "" {
		return errors.New("no password was entered")
	}
	hash, err := auth.HashPassword(password)
	if err != nil {
		return err
	}
	fmt.Println(hash)
	return nil
}

func run() error {
	cfg, err := config.Load()
	if err != nil {
		return err
	}

	logger := slog.New(slog.NewTextHandler(os.Stdout, &slog.HandlerOptions{Level: slog.LevelInfo}))
	slog.SetDefault(logger)

	if err := os.MkdirAll(cfg.DataDir, 0o750); err != nil {
		return fmt.Errorf("create FERRY_DATA_DIR %s: %w", cfg.DataDir, err)
	}
	jobsDir := filepath.Join(cfg.DataDir, "jobs")
	if err := os.MkdirAll(jobsDir, 0o750); err != nil {
		return fmt.Errorf("create jobs directory %s: %w", jobsDir, err)
	}

	store, err := db.Open(filepath.Join(cfg.DataDir, "ferry.db"), cfg.DataDir)
	if err != nil {
		return err
	}
	defer store.Close()

	sessions, err := auth.New(cfg.SecretKey, cfg.Username, cfg.CookieSecure)
	if err != nil {
		return fmt.Errorf("set up sessions: %w", err)
	}
	uploadSvc := uploads.New(store, cfg.DataDir, cfg.MaxTotalBytes)
	dl := downloader.New()
	builder, err := imagebuild.New(cfg.DockerHubUsername, cfg.DockerHubToken, cfg.DockerHubRepo, cfg.Platform)
	if err != nil {
		return err
	}
	hub := dockerhub.New(cfg.DockerHubUsername, cfg.DockerHubToken)
	manager := jobs.New(cfg, store, dl, builder, hub, logger)
	server, err := web.New(cfg, store, sessions, uploadSvc, manager, logger, version)
	if err != nil {
		return err
	}

	manager.Start()
	if err := manager.Recover(context.Background()); err != nil {
		logger.Error("startup recovery finished with errors", "error", err)
	}

	httpServer := &http.Server{
		Addr:              cfg.ListenAddr,
		Handler:           server.Handler(),
		ReadHeaderTimeout: 15 * time.Second,
		IdleTimeout:       120 * time.Second,
		MaxHeaderBytes:    1 << 20,
		// ReadTimeout and WriteTimeout are intentionally unset: multi-gigabyte
		// uploads and long-running downloads must not be killed by them.
	}

	signalCtx, stopSignals := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stopSignals()

	errCh := make(chan error, 1)
	go func() {
		logger.Info("Ferry is running", "addr", cfg.ListenAddr, "data_dir", cfg.DataDir, "platform", cfg.Platform, "version", version)
		errCh <- httpServer.ListenAndServe()
	}()

	var serveErr error
	select {
	case serveErr = <-errCh:
		if !errors.Is(serveErr, http.ErrServerClosed) {
			logger.Error("http server stopped", "error", serveErr)
		}
	case <-signalCtx.Done():
		logger.Info("shutdown signal received; draining requests")
	}

	httpShutdownCtx, cancelHTTP := context.WithTimeout(context.Background(), 25*time.Second)
	if err := httpServer.Shutdown(httpShutdownCtx); err != nil {
		logger.Error("http shutdown", "error", err)
	}
	cancelHTTP()

	logger.Info("stopping the job worker")
	workerShutdownCtx, cancelWorker := context.WithTimeout(context.Background(), 25*time.Second)
	if err := manager.Shutdown(workerShutdownCtx); err != nil {
		logger.Error("worker shutdown", "error", err)
	}
	cancelWorker()
	logger.Info("Ferry stopped")
	if serveErr != nil && !errors.Is(serveErr, http.ErrServerClosed) {
		return fmt.Errorf("HTTP server: %w", serveErr)
	}
	return nil
}
FERRY_EOF_5

cat > 'cmd/ferry/unpack.go' <<'FERRY_EOF_6'
package main

import (
	"bufio"
	"compress/gzip"
	"crypto/md5"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"

	"golang.org/x/term"

	"ferry/internal/securefile"
)

// unpackCommand runs inside the extracted image directory. It verifies the
// checksum files, then decrypts .ferry files and decompresses .gz files.
func unpackCommand(args []string) error {
	fs := flag.NewFlagSet("unpack", flag.ContinueOnError)
	fs.SetOutput(os.Stderr)
	passphrase := fs.String("passphrase", "", "job passphrase (prompted when needed)")
	dir := fs.String("dir", ".", "directory containing the extracted image files")
	verifyOnly := fs.Bool("verify-only", false, "only verify checksums, do not unpack")
	force := fs.Bool("force", false, "overwrite existing output files")
	if err := fs.Parse(args); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			return nil
		}
		return err
	}

	entries, err := os.ReadDir(*dir)
	if err != nil {
		return fmt.Errorf("read directory %s: %w", *dir, err)
	}

	checksumFiles := 0
	verified := 0
	for _, name := range []string{"SHA256SUMS", "MD5SUMS"} {
		path := filepath.Join(*dir, name)
		if _, err := os.Stat(path); err != nil {
			if os.IsNotExist(err) {
				continue
			}
			return err
		}
		checksumFiles++
		n, err := verifyChecksumFile(path, *dir, name)
		verified += n
		if err != nil {
			return err
		}
	}
	if checksumFiles == 0 {
		fmt.Fprintln(os.Stderr, "Warning: no SHA256SUMS or MD5SUMS found; skipping verification.")
	} else {
		fmt.Printf("Verified %d checksum entries.\n", verified)
	}
	if *verifyOnly {
		return nil
	}

	tasks, err := unpackTasks(*dir, entries)
	if err != nil {
		return err
	}
	needsPassphrase := false
	for _, task := range tasks {
		if task.Encrypted {
			needsPassphrase = true
		}
	}
	if needsPassphrase && *passphrase == "" {
		if !term.IsTerminal(int(os.Stdin.Fd())) {
			return errors.New("encrypted files found; pass --passphrase or run interactively")
		}
		fmt.Fprint(os.Stderr, "Passphrase: ")
		raw, err := term.ReadPassword(int(os.Stdin.Fd()))
		fmt.Fprintln(os.Stderr)
		if err != nil {
			return err
		}
		*passphrase = string(raw)
	}

	unpacked := 0
	for _, task := range tasks {
		if strings.ContainsAny(task.Original, "/\\") || task.Original == "" ||
			task.Original == "." || task.Original == ".." {
			return fmt.Errorf("refusing unsafe output name %q", task.Original)
		}
		finalPath := filepath.Join(*dir, task.Original)
		if _, err := os.Stat(finalPath); err == nil && !*force {
			return fmt.Errorf("output file %q already exists; use --force to overwrite", task.Original)
		}
		if err := unpackOne(filepath.Join(*dir, task.Stored), finalPath, *passphrase, *dir, task.Compressed, task.Encrypted); err != nil {
			return fmt.Errorf("unpack %s: %w", task.Stored, err)
		}
		fmt.Printf("Unpacked %s -> %s\n", task.Stored, task.Original)
		unpacked++
	}
	if unpacked == 0 {
		fmt.Println("Nothing to unpack; all files are already in plain form.")
	} else {
		fmt.Printf("Unpacked %d file(s).\n", unpacked)
	}
	return nil
}

func isMetadataFile(name string) bool {
	switch name {
	case "SHA256SUMS", "MD5SUMS", "README-FERRY.txt", "FERRY-MANIFEST.json", "ferry":
		return true
	}
	return strings.HasPrefix(name, ".")
}

type unpackTask struct {
	Stored     string
	Original   string
	Compressed bool
	Encrypted  bool
}

type manifestEntry struct {
	Stored     string `json:"stored"`
	Original   string `json:"original"`
	Compressed bool   `json:"compressed"`
	Encrypted  bool   `json:"encrypted"`
}

// unpackTasks prefers the manifest written by Ferry. It falls back to the
// filename suffixes for images produced by older Ferry versions.
func unpackTasks(dir string, entries []os.DirEntry) ([]unpackTask, error) {
	manifestPath := filepath.Join(dir, "FERRY-MANIFEST.json")
	if data, err := os.ReadFile(manifestPath); err == nil {
		var manifest []manifestEntry
		if err := json.Unmarshal(data, &manifest); err != nil {
			return nil, fmt.Errorf("read FERRY-MANIFEST.json: %w", err)
		}
		tasks := make([]unpackTask, 0, len(manifest))
		for _, entry := range manifest {
			if !entry.Compressed && !entry.Encrypted && entry.Stored == entry.Original {
				continue
			}
			if strings.ContainsAny(entry.Stored, "/\\") || strings.ContainsAny(entry.Original, "/\\") {
				return nil, errors.New("FERRY-MANIFEST.json contains an unsafe filename")
			}
			tasks = append(tasks, unpackTask{
				Stored: entry.Stored, Original: entry.Original,
				Compressed: entry.Compressed, Encrypted: entry.Encrypted,
			})
		}
		return tasks, nil
	} else if !os.IsNotExist(err) {
		return nil, err
	}

	var tasks []unpackTask
	for _, entry := range entries {
		if entry.IsDir() {
			continue
		}
		name := entry.Name()
		if isMetadataFile(name) {
			continue
		}
		output := name
		encrypted := strings.HasSuffix(output, securefile.Suffix)
		if encrypted {
			output = strings.TrimSuffix(output, securefile.Suffix)
		}
		compressed := strings.HasSuffix(output, ".gz")
		if compressed {
			output = strings.TrimSuffix(output, ".gz")
		}
		if output == name {
			continue
		}
		tasks = append(tasks, unpackTask{
			Stored: name, Original: output, Compressed: compressed, Encrypted: encrypted,
		})
	}
	return tasks, nil
}

func unpackOne(srcPath, finalPath, passphrase, dir string, compressed, encrypted bool) error {
	tmp, err := os.CreateTemp(dir, ".ferry-unpack-*")
	if err != nil {
		return err
	}
	tmpName := tmp.Name()
	defer func() {
		_ = tmp.Close()
		_ = os.Remove(tmpName)
	}()

	src, err := os.Open(srcPath)
	if err != nil {
		return err
	}
	defer src.Close()

	var reader io.Reader = src
	if encrypted {
		pr, pw := io.Pipe()
		go func() {
			_, err := securefile.Decrypt(pw, src, passphrase)
			_ = pw.CloseWithError(err)
		}()
		reader = pr
	}
	if compressed {
		gz, err := gzip.NewReader(reader)
		if err != nil {
			return fmt.Errorf("open gzip stream: %w", err)
		}
		defer gz.Close()
		reader = gz
	}
	if _, err := io.Copy(tmp, reader); err != nil {
		return err
	}
	if err := tmp.Sync(); err != nil {
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	if err := os.Chmod(tmpName, 0o644); err != nil {
		return err
	}
	return os.Rename(tmpName, finalPath)
}

func verifyChecksumFile(path, dir, label string) (int, error) {
	f, err := os.Open(path)
	if err != nil {
		return 0, err
	}
	defer f.Close()
	scanner := bufio.NewScanner(f)
	scanner.Buffer(make([]byte, 64*1024), 1024*1024)
	lineNo := 0
	checked := 0
	for scanner.Scan() {
		lineNo++
		line := strings.TrimRight(scanner.Text(), "\r")
		if strings.TrimSpace(line) == "" {
			continue
		}
		sep := strings.Index(line, "  ")
		if sep < 0 {
			return checked, fmt.Errorf("%s line %d is malformed (expected \"hash  filename\")", label, lineNo)
		}
		want := strings.ToLower(strings.TrimSpace(line[:sep]))
		name := strings.TrimPrefix(line[sep+2:], "*")
		if strings.ContainsAny(name, "/\\") || name == "" || name == "." || name == ".." {
			return checked, fmt.Errorf("%s line %d has an unsafe filename", label, lineNo)
		}
		filePath := filepath.Join(dir, name)
		var got string
		if label == "SHA256SUMS" {
			got, err = hashFileHex(filePath, "sha256")
		} else {
			got, err = hashFileHex(filePath, "md5")
		}
		if err != nil {
			return checked, fmt.Errorf("verify %s: %w", name, err)
		}
		if got != want {
			return checked, fmt.Errorf("checksum mismatch for %s: expected %s, got %s", name, want, got)
		}
		checked++
	}
	if err := scanner.Err(); err != nil {
		return checked, err
	}
	return checked, nil
}

func hashFileHex(path, algorithm string) (string, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer f.Close()
	if algorithm == "sha256" {
		d := sha256.New()
		if _, err := io.Copy(d, f); err != nil {
			return "", err
		}
		return hex.EncodeToString(d.Sum(nil)), nil
	}
	d := md5.New()
	if _, err := io.Copy(d, f); err != nil {
		return "", err
	}
	return hex.EncodeToString(d.Sum(nil)), nil
}
FERRY_EOF_6

cat > 'cmd/ferry/unpack_test.go' <<'FERRY_EOF_7'
package main

import (
	"bytes"
	"compress/gzip"
	"crypto/sha256"
	"encoding/hex"
	"os"
	"path/filepath"
	"testing"

	"ferry/internal/securefile"
)

func writeStored(t *testing.T, dir, name string, data []byte) string {
	t.Helper()
	path := filepath.Join(dir, name)
	if err := os.WriteFile(path, data, 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}

func checksumLine(t *testing.T, path, name string) string {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	sum := sha256.Sum256(data)
	return hex.EncodeToString(sum[:]) + "  " + name + "\n"
}

func TestUnpackDecryptsAndDecompresses(t *testing.T) {
	dir := t.TempDir()
	plain := []byte("hello from the ferry image\n")

	// Compressed file.
	var gz bytes.Buffer
	zw := gzip.NewWriter(&gz)
	if _, err := zw.Write(plain); err != nil {
		t.Fatal(err)
	}
	if err := zw.Close(); err != nil {
		t.Fatal(err)
	}
	gzPath := writeStored(t, dir, "notes.txt.gz", gz.Bytes())

	// Encrypted file.
	salt, err := securefile.NewSalt()
	if err != nil {
		t.Fatal(err)
	}
	var enc bytes.Buffer
	if err := securefile.Encrypt(&enc, bytes.NewReader(plain), "correct horse battery staple", salt, int64(len(plain))); err != nil {
		t.Fatal(err)
	}
	encPath := writeStored(t, dir, "secret.txt.ferry", enc.Bytes())

	// Encrypted + compressed file.
	var gz2 bytes.Buffer
	zw2 := gzip.NewWriter(&gz2)
	if _, err := zw2.Write(plain); err != nil {
		t.Fatal(err)
	}
	if err := zw2.Close(); err != nil {
		t.Fatal(err)
	}
	salt2, _ := securefile.NewSalt()
	var enc2 bytes.Buffer
	if err := securefile.Encrypt(&enc2, bytes.NewReader(gz2.Bytes()), "correct horse battery staple", salt2, int64(gz2.Len())); err != nil {
		t.Fatal(err)
	}
	bothPath := writeStored(t, dir, "both.txt.gz.ferry", enc2.Bytes())

	sums := checksumLine(t, gzPath, "notes.txt.gz") +
		checksumLine(t, encPath, "secret.txt.ferry") +
		checksumLine(t, bothPath, "both.txt.gz.ferry")
	writeStored(t, dir, "SHA256SUMS", []byte(sums))

	if err := unpackCommand([]string{"--dir", dir, "--passphrase", "correct horse battery staple"}); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"notes.txt", "secret.txt", "both.txt"} {
		got, err := os.ReadFile(filepath.Join(dir, name))
		if err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		if !bytes.Equal(got, plain) {
			t.Fatalf("%s = %q", name, got)
		}
	}
}

func TestUnpackRejectsBadChecksum(t *testing.T) {
	dir := t.TempDir()
	path := writeStored(t, dir, "file.txt.gz", []byte("not really gzip"))
	writeStored(t, dir, "SHA256SUMS", []byte("deadbeef  file.txt.gz\n"))
	err := unpackCommand([]string{"--dir", dir, "--verify-only"})
	if err == nil {
		t.Fatal("expected a checksum mismatch error")
	}
	_ = path
}

func TestUnpackWrongPassphrase(t *testing.T) {
	dir := t.TempDir()
	salt, _ := securefile.NewSalt()
	var enc bytes.Buffer
	if err := securefile.Encrypt(&enc, bytes.NewReader([]byte("data")), "right passphrase", salt, 4); err != nil {
		t.Fatal(err)
	}
	path := writeStored(t, dir, "data.bin.ferry", enc.Bytes())
	writeStored(t, dir, "SHA256SUMS", []byte(checksumLine(t, path, "data.bin.ferry")))
	if err := unpackCommand([]string{"--dir", dir, "--passphrase", "wrong passphrase"}); err == nil {
		t.Fatal("expected an error with the wrong passphrase")
	}
}

func TestUnpackUsesManifestAndSkipsPlainLookalike(t *testing.T) {
	dir := t.TempDir()
	// A plain file whose name ends in .gz must not be treated as compressed.
	plainLookalike := []byte("this is not gzip data")
	writeStored(t, dir, "notes.gz", plainLookalike)

	// A genuinely compressed file described by the manifest.
	original := []byte("real contents")
	var gz bytes.Buffer
	zw := gzip.NewWriter(&gz)
	if _, err := zw.Write(original); err != nil {
		t.Fatal(err)
	}
	if err := zw.Close(); err != nil {
		t.Fatal(err)
	}
	gzPath := writeStored(t, dir, "stored.bin", gz.Bytes())

	manifest := `[
  {"stored":"notes.gz","original":"notes.gz","compressed":false,"encrypted":false},
  {"stored":"stored.bin","original":"real.txt","compressed":true,"encrypted":false}
]`
	writeStored(t, dir, "FERRY-MANIFEST.json", []byte(manifest))
	writeStored(t, dir, "SHA256SUMS", []byte(checksumLine(t, gzPath, "stored.bin")))

	if err := unpackCommand([]string{"--dir", dir}); err != nil {
		t.Fatal(err)
	}
	got, err := os.ReadFile(filepath.Join(dir, "real.txt"))
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(got, original) {
		t.Fatalf("real.txt = %q", got)
	}
	// The plain lookalike must be untouched.
	got, err = os.ReadFile(filepath.Join(dir, "notes.gz"))
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(got, plainLookalike) {
		t.Fatalf("notes.gz was modified: %q", got)
	}
}

func TestUnpackRenamedPlainFile(t *testing.T) {
	dir := t.TempDir()
	contents := []byte("plain but renamed")
	storedPath := writeStored(t, dir, "renamed-1.bin", contents)
	manifest := `[
  {"stored":"renamed-1.bin","original":"renamed.bin","compressed":false,"encrypted":false}
]`
	writeStored(t, dir, "FERRY-MANIFEST.json", []byte(manifest))
	writeStored(t, dir, "SHA256SUMS", []byte(checksumLine(t, storedPath, "renamed-1.bin")))
	if err := unpackCommand([]string{"--dir", dir}); err != nil {
		t.Fatal(err)
	}
	got, err := os.ReadFile(filepath.Join(dir, "renamed.bin"))
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(got, contents) {
		t.Fatalf("renamed.bin = %q", got)
	}
}
FERRY_EOF_7

cat > 'deploy/Caddyfile.example' <<'FERRY_EOF_8'
# Copy to /etc/caddy/Caddyfile and set your real domain.
# Before using HTTPS, edit /etc/ferry/ferry.env:
#   FERRY_LISTEN_ADDR=127.0.0.1:8080
#   FERRY_COOKIE_SECURE=true
#   FERRY_TRUST_PROXY=true
#   FERRY_DOMAIN=ferry.example.com
# Then: sudo systemctl restart ferry && sudo systemctl reload caddy

ferry.example.com {
	encode zstd gzip
	reverse_proxy 127.0.0.1:8080
}
FERRY_EOF_8

cat > 'deploy/ferry.env.example' <<'FERRY_EOF_9'
# Ferry configuration for a systemd installation.
# After editing, run: sudo systemctl restart ferry

FERRY_USERNAME=CHANGE_ME
FERRY_PASSWORD=CHANGE_ME
# Optional: use a bcrypt hash instead of FERRY_PASSWORD.
# Generate one with: /usr/local/bin/ferry hash-password
# FERRY_PASSWORD_HASH=$2a$10$...
FERRY_SECRET_KEY=CHANGE_ME

# systemd installs the binary directly, so choose an explicit address.
# Behind Caddy on the same machine, use 127.0.0.1:8080.
# Exposed directly, use 0.0.0.0:8080.
FERRY_LISTEN_ADDR=0.0.0.0:8080
FERRY_DATA_DIR=/var/lib/ferry
FERRY_MAX_TOTAL_BYTES=10737418240
FERRY_COOKIE_SECURE=false
FERRY_TRUST_PROXY=false
FERRY_PLATFORM=linux/amd64

DOCKERHUB_USERNAME=CHANGE_ME
DOCKERHUB_TOKEN=CHANGE_ME
DOCKERHUB_REPO=ferry

FERRY_RETENTION_DAYS=0
FERRY_DOMAIN=ferry.example.com
FERRY_EOF_9

cat > 'deploy/ferry.service' <<'FERRY_EOF_10'
[Unit]
Description=Ferry file transfer service
Documentation=https://github.com/your-org/ferry
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=ferry
Group=ferry
EnvironmentFile=/etc/ferry/ferry.env
ExecStart=/usr/local/bin/ferry
WorkingDirectory=/var/lib/ferry
Restart=on-failure
RestartSec=5
TimeoutStopSec=60
LimitNOFILE=65535

# Hardening. Ferry needs write access only to its data directory.
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/lib/ferry
ProtectKernelTunables=true
ProtectControlGroups=true
RestrictSUIDSGID=true

[Install]
WantedBy=multi-user.target
FERRY_EOF_10

cat > 'deploy/install.sh' <<'FERRY_EOF_11'
#!/usr/bin/env bash
# Ferry installer / upgrader for Ubuntu Server 24.04.
# Run from an extracted release package: sudo ./deploy/install.sh
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "ERROR: run this script with sudo: sudo ./deploy/install.sh" >&2
  exit 1
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
BINARY_SOURCE="${PACKAGE_ROOT}/ferry"
ENV_FILE="/etc/ferry/ferry.env"
UNIT_FILE="/etc/systemd/system/ferry.service"

if [[ ! -f "${BINARY_SOURCE}" ]]; then
  echo "ERROR: ferry binary not found at ${BINARY_SOURCE}" >&2
  echo "Extract the whole release archive and run deploy/install.sh from it." >&2
  exit 1
fi
for required in \
  "${SCRIPT_DIR}/ferry.service" \
  "${SCRIPT_DIR}/ferry.env.example" \
  "${SCRIPT_DIR}/Caddyfile.example" \
  "${PACKAGE_ROOT}/README.md"; do
  if [[ ! -f "${required}" ]]; then
    echo "ERROR: package is incomplete, missing ${required}" >&2
    exit 1
  fi
done

# System user and directories. Safe to repeat on upgrade.
if ! getent group ferry >/dev/null 2>&1; then
  groupadd --system ferry
fi
if ! id -u ferry >/dev/null 2>&1; then
  useradd --system --gid ferry --home-dir /var/lib/ferry --shell /usr/sbin/nologin ferry
fi
install -d -o ferry -g ferry -m 0750 /var/lib/ferry
install -d -o root -g ferry -m 0750 /etc/ferry

# Install the binary atomically so an interrupted copy cannot leave a partial
# executable in place.
install -m 0755 -o root -g root "${BINARY_SOURCE}" /usr/local/bin/ferry.new
mv -f /usr/local/bin/ferry.new /usr/local/bin/ferry

# First install only: create the environment file, never overwrite it.
FIRST_INSTALL=0
if [[ ! -f "${ENV_FILE}" ]]; then
  FIRST_INSTALL=1
  if ! command -v openssl >/dev/null 2>&1; then
    echo "ERROR: openssl is required to generate FERRY_SECRET_KEY." >&2
    echo "Install it with: sudo apt-get install -y openssl" >&2
    exit 1
  fi
  install -m 0640 -o root -g ferry "${SCRIPT_DIR}/ferry.env.example" "${ENV_FILE}"
  SECRET="$(openssl rand -hex 32)"
  sed -i "s|^FERRY_SECRET_KEY=.*|FERRY_SECRET_KEY=${SECRET}|" "${ENV_FILE}"
fi
chown root:ferry "${ENV_FILE}"
chmod 0640 "${ENV_FILE}"

# Install/refresh the systemd unit.
install -m 0644 -o root -g root "${SCRIPT_DIR}/ferry.service" "${UNIT_FILE}"
systemctl daemon-reload
systemctl enable ferry >/dev/null

# Check whether the required values have been filled in.
PROBLEMS=()
if grep -q '^FERRY_USERNAME=CHANGE_ME$' "${ENV_FILE}"; then
  PROBLEMS+=("FERRY_USERNAME")
fi
if grep -q '^DOCKERHUB_USERNAME=CHANGE_ME$' "${ENV_FILE}"; then
  PROBLEMS+=("DOCKERHUB_USERNAME")
fi
if grep -q '^DOCKERHUB_TOKEN=CHANGE_ME$' "${ENV_FILE}"; then
  PROBLEMS+=("DOCKERHUB_TOKEN")
fi
if grep -q '^FERRY_SECRET_KEY=CHANGE_ME$' "${ENV_FILE}"; then
  PROBLEMS+=("FERRY_SECRET_KEY")
fi
PASSWORD_OK=0
if grep -Eq '^FERRY_PASSWORD_HASH=\$2[aby]\$' "${ENV_FILE}"; then
  PASSWORD_OK=1
elif ! grep -q '^FERRY_PASSWORD=CHANGE_ME$' "${ENV_FILE}" && \
     ! grep -q '^FERRY_PASSWORD=$' "${ENV_FILE}"; then
  PASSWORD_OK=1
fi
if [[ "${PASSWORD_OK}" -eq 0 ]]; then
  PROBLEMS+=("FERRY_PASSWORD (or FERRY_PASSWORD_HASH)")
fi

if [[ "${#PROBLEMS[@]}" -gt 0 ]]; then
  echo
  echo "======================================================================"
  echo " Ferry is installed, but it is NOT running yet."
  echo " Edit these values first: ${PROBLEMS[*]}"
  echo
  echo "   sudo nano ${ENV_FILE}"
  echo
  echo " Then start it with:"
  echo "   sudo systemctl restart ferry"
  echo "   sudo systemctl status ferry"
  echo "======================================================================"
  if [[ "${FIRST_INSTALL}" -eq 1 ]]; then
    echo "A random FERRY_SECRET_KEY was generated for you."
  fi
  exit 0
fi

systemctl restart ferry
ACTIVE=0
for _ in 1 2 3 4 5 6 7 8 9 10; do
  if systemctl is-active --quiet ferry; then
    ACTIVE=1
    break
  fi
  sleep 1
done
if [[ "${ACTIVE}" -ne 1 ]]; then
  echo
  echo "ERROR: Ferry did not stay running. Recent log lines:" >&2
  systemctl --no-pager --full status ferry || true
  journalctl -u ferry -n 40 --no-pager || true
  echo >&2
  echo "Fix ${ENV_FILE}, then run: sudo systemctl restart ferry" >&2
  exit 1
fi

systemctl --no-pager --full status ferry || true
echo
echo "Installed version: $(/usr/local/bin/ferry --version 2>/dev/null || echo unknown)"

SERVER_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
if [[ -z "${SERVER_IP}" ]]; then
  SERVER_IP="YOUR_SERVER_IP"
fi
LISTEN_ADDR="$(grep -E '^FERRY_LISTEN_ADDR=' "${ENV_FILE}" | tail -1 | cut -d= -f2- || true)"
if [[ "${LISTEN_ADDR}" == 127.0.0.1:* ]]; then
  echo "Ferry is listening on ${LISTEN_ADDR} (behind Caddy)."
  echo "Open https://YOUR_DOMAIN after configuring Caddy."
else
  PORT="${LISTEN_ADDR##*:}"
  if [[ -z "${PORT}" || "${PORT}" == "${LISTEN_ADDR}" ]]; then
    PORT="8080"
  fi
  echo "Ferry should now be available at: http://${SERVER_IP}:${PORT}"
  echo "Open the firewall port: sudo ufw allow ${PORT}/tcp"
fi
if [[ "${FIRST_INSTALL}" -eq 1 ]]; then
  echo "A random FERRY_SECRET_KEY was generated for you."
fi
FERRY_EOF_11

cat > 'go.mod' <<'FERRY_EOF_12'
module ferry

go 1.23.0

require (
	github.com/google/go-containerregistry v0.20.3
	golang.org/x/crypto v0.31.0
	golang.org/x/term v0.27.0
	modernc.org/sqlite v1.29.10
)

require (
	github.com/containerd/stargz-snapshotter/estargz v0.16.3 // indirect
	github.com/docker/cli v27.5.0+incompatible // indirect
	github.com/docker/distribution v2.8.3+incompatible // indirect
	github.com/docker/docker-credential-helpers v0.8.2 // indirect
	github.com/dustin/go-humanize v1.0.1 // indirect
	github.com/google/uuid v1.6.0 // indirect
	github.com/hashicorp/golang-lru/v2 v2.0.7 // indirect
	github.com/klauspost/compress v1.17.11 // indirect
	github.com/mattn/go-isatty v0.0.20 // indirect
	github.com/mitchellh/go-homedir v1.1.0 // indirect
	github.com/ncruces/go-strftime v0.1.9 // indirect
	github.com/opencontainers/go-digest v1.0.0 // indirect
	github.com/opencontainers/image-spec v1.1.0 // indirect
	github.com/pkg/errors v0.9.1 // indirect
	github.com/remyoudompheng/bigfft v0.0.0-20230129092748-24d4a6f8daec // indirect
	github.com/sirupsen/logrus v1.9.3 // indirect
	github.com/vbatts/tar-split v0.11.6 // indirect
	golang.org/x/sync v0.10.0 // indirect
	golang.org/x/sys v0.29.0 // indirect
	modernc.org/gc/v3 v3.0.0-20240107210532-573471604cb6 // indirect
	modernc.org/libc v1.49.3 // indirect
	modernc.org/mathutil v1.6.0 // indirect
	modernc.org/memory v1.8.0 // indirect
	modernc.org/strutil v1.2.0 // indirect
	modernc.org/token v1.1.0 // indirect
)
FERRY_EOF_12

cat > 'go.sum' <<'FERRY_EOF_13'
github.com/containerd/stargz-snapshotter/estargz v0.16.3 h1:7evrXtoh1mSbGj/pfRccTampEyKpjpOnS3CyiV1Ebr8=
github.com/containerd/stargz-snapshotter/estargz v0.16.3/go.mod h1:uyr4BfYfOj3G9WBVE8cOlQmXAbPN9VEQpBBeJIuOipU=
github.com/davecgh/go-spew v1.1.0/go.mod h1:J7Y8YcW2NihsgmVo/mv3lAwl/skON4iLHjSsI+c5H38=
github.com/davecgh/go-spew v1.1.1 h1:vj9j/u1bqnvCEfJOwUhtlOARqs3+rkHYY13jYWTU97c=
github.com/davecgh/go-spew v1.1.1/go.mod h1:J7Y8YcW2NihsgmVo/mv3lAwl/skON4iLHjSsI+c5H38=
github.com/docker/cli v27.5.0+incompatible h1:aMphQkcGtpHixwwhAXJT1rrK/detk2JIvDaFkLctbGM=
github.com/docker/cli v27.5.0+incompatible/go.mod h1:JLrzqnKDaYBop7H2jaqPtU4hHvMKP+vjCwu2uszcLI8=
github.com/docker/distribution v2.8.3+incompatible h1:AtKxIZ36LoNK51+Z6RpzLpddBirtxJnzDrHLEKxTAYk=
github.com/docker/distribution v2.8.3+incompatible/go.mod h1:J2gT2udsDAN96Uj4KfcMRqY0/ypR+oyYUYmja8H+y+w=
github.com/docker/docker-credential-helpers v0.8.2 h1:bX3YxiGzFP5sOXWc3bTPEXdEaZSeVMrFgOr3T+zrFAo=
github.com/docker/docker-credential-helpers v0.8.2/go.mod h1:P3ci7E3lwkZg6XiHdRKft1KckHiO9a2rNtyFbZ/ry9M=
github.com/dustin/go-humanize v1.0.1 h1:GzkhY7T5VNhEkwH0PVJgjz+fX1rhBrR7pRT3mDkpeCY=
github.com/dustin/go-humanize v1.0.1/go.mod h1:Mu1zIs6XwVuF/gI1OepvI0qD18qycQx+mFykh5fBlto=
github.com/google/go-cmp v0.6.0 h1:ofyhxvXcZhMsU5ulbFiLKl/XBFqE1GSq7atu8tAmTRI=
github.com/google/go-cmp v0.6.0/go.mod h1:17dUlkBOakJ0+DkrSSNjCkIjxS6bF9zb3elmeNGIjoY=
github.com/google/go-containerregistry v0.20.3 h1:oNx7IdTI936V8CQRveCjaxOiegWwvM7kqkbXTpyiovI=
github.com/google/go-containerregistry v0.20.3/go.mod h1:w00pIgBRDVUDFM6bq+Qx8lwNWK+cxgCuX1vd3PIBDNI=
github.com/google/pprof v0.0.0-20240409012703-83162a5b38cd h1:gbpYu9NMq8jhDVbvlGkMFWCjLFlqqEZjEmObmhUy6Vo=
github.com/google/pprof v0.0.0-20240409012703-83162a5b38cd/go.mod h1:kf6iHlnVGwgKolg33glAes7Yg/8iWP8ukqeldJSO7jw=
github.com/google/uuid v1.6.0 h1:NIvaJDMOsjHA8n1jAhLSgzrAzy1Hgr+hNrb57e+94F0=
github.com/google/uuid v1.6.0/go.mod h1:TIyPZe4MgqvfeYDBFedMoGGpEw/LqOeaOT+nhxU+yHo=
github.com/hashicorp/golang-lru/v2 v2.0.7 h1:a+bsQ5rvGLjzHuww6tVxozPZFVghXaHOwFs4luLUK2k=
github.com/hashicorp/golang-lru/v2 v2.0.7/go.mod h1:QeFd9opnmA6QUJc5vARoKUSoFhyfM2/ZepoAG6RGpeM=
github.com/klauspost/compress v1.17.11 h1:In6xLpyWOi1+C7tXUUWv2ot1QvBjxevKAaI6IXrJmUc=
github.com/klauspost/compress v1.17.11/go.mod h1:pMDklpSncoRMuLFrf1W9Ss9KT+0rH90U12bZKk7uwG0=
github.com/mattn/go-isatty v0.0.20 h1:xfD0iDuEKnDkl03q4limB+vH+GxLEtL/jb4xVJSWWEY=
github.com/mattn/go-isatty v0.0.20/go.mod h1:W+V8PltTTMOvKvAeJH7IuucS94S2C6jfK/D7dTCTo3Y=
github.com/mitchellh/go-homedir v1.1.0 h1:lukF9ziXFxDFPkA1vsr5zpc1XuPDn/wFntq5mG+4E0Y=
github.com/mitchellh/go-homedir v1.1.0/go.mod h1:SfyaCUpYCn1Vlf4IUYiD9fPX4A5wJrkLzIz1N1q0pr0=
github.com/ncruces/go-strftime v0.1.9 h1:bY0MQC28UADQmHmaF5dgpLmImcShSi2kHU9XLdhx/f4=
github.com/ncruces/go-strftime v0.1.9/go.mod h1:Fwc5htZGVVkseilnfgOVb9mKy6w1naJmn9CehxcKcls=
github.com/opencontainers/go-digest v1.0.0 h1:apOUWs51W5PlhuyGyz9FCeeBIOUDA/6nW8Oi/yOhh5U=
github.com/opencontainers/go-digest v1.0.0/go.mod h1:0JzlMkj0TRzQZfJkVvzbP0HBR3IKzErnv2BNG4W4MAM=
github.com/opencontainers/image-spec v1.1.0 h1:8SG7/vwALn54lVB/0yZ/MMwhFrPYtpEHQb2IpWsCzug=
github.com/opencontainers/image-spec v1.1.0/go.mod h1:W4s4sFTMaBeK1BQLXbG4AdM2szdn85PY75RI83NrTrM=
github.com/pkg/errors v0.9.1 h1:FEBLx1zS214owpjy7qsBeixbURkuhQAwrK5UwLGTwt4=
github.com/pkg/errors v0.9.1/go.mod h1:bwawxfHBFNV+L2hUp1rHADufV3IMtnDRdf1r5NINEl0=
github.com/pmezard/go-difflib v1.0.0 h1:4DBwDE0NGyQoBHbLQYPwSUPoCMWR5BEzIk/f1lZbAQM=
github.com/pmezard/go-difflib v1.0.0/go.mod h1:iKH77koFhYxTK1pcRnkKkqfTogsbg7gZNVY4sRDYZ/4=
github.com/remyoudompheng/bigfft v0.0.0-20230129092748-24d4a6f8daec h1:W09IVJc94icq4NjY3clb7Lk8O1qJ8BdBEF8z0ibU0rE=
github.com/remyoudompheng/bigfft v0.0.0-20230129092748-24d4a6f8daec/go.mod h1:qqbHyh8v60DhA7CoWK5oRCqLrMHRGoxYCSS9EjAz6Eo=
github.com/sirupsen/logrus v1.9.3 h1:dueUQJ1C2q9oE3F7wvmSGAaVtTmUizReu6fjN8uqzbQ=
github.com/sirupsen/logrus v1.9.3/go.mod h1:naHLuLoDiP4jHNo9R0sCBMtWGeIprob74mVsIT4qYEQ=
github.com/stretchr/objx v0.1.0/go.mod h1:HFkY916IF+rwdDfMAkV7OtwuqBVzrE8GR6GFx+wExME=
github.com/stretchr/testify v1.7.0/go.mod h1:6Fq8oRcR53rry900zMqJjRRixrwX3KX962/h/Wwjteg=
github.com/stretchr/testify v1.9.0 h1:HtqpIVDClZ4nwg75+f6Lvsy/wHu+3BoSGCbBAcpTsTg=
github.com/stretchr/testify v1.9.0/go.mod h1:r2ic/lqez/lEtzL7wO/rwa5dbSLXVDPFyf8C91i36aY=
github.com/vbatts/tar-split v0.11.6 h1:4SjTW5+PU11n6fZenf2IPoV8/tz3AaYHMWjf23envGs=
github.com/vbatts/tar-split v0.11.6/go.mod h1:dqKNtesIOr2j2Qv3W/cHjnvk9I8+G7oAkFDFN6TCBEI=
golang.org/x/crypto v0.31.0 h1:ihbySMvVjLAeSH1IbfcRTkD/iNscyz8rGzjF/E5hV6U=
golang.org/x/crypto v0.31.0/go.mod h1:kDsLvtWBEx7MV9tJOj9bnXsPbxwJQ6csT/x4KIN4Ssk=
golang.org/x/mod v0.22.0 h1:D4nJWe9zXqHOmWqj4VMOJhvzj7bEZg4wEYa759z1pH4=
golang.org/x/mod v0.22.0/go.mod h1:6SkKJ3Xj0I0BrPOZoBy3bdMptDDU9oJrpohJ3eWZ1fY=
golang.org/x/sync v0.10.0 h1:3NQrjDixjgGwUOCaF8w2+VYHv0Ve/vGYSbdkTa98gmQ=
golang.org/x/sync v0.10.0/go.mod h1:Czt+wKu1gCyEFDUtn0jG5QVvpJ6rzVqr5aXyt9drQfk=
golang.org/x/sys v0.0.0-20220715151400-c0bba94af5f8/go.mod h1:oPkhp1MJrh7nUepCBck5+mAzfO9JrbApNNgaTdGDITg=
golang.org/x/sys v0.6.0/go.mod h1:oPkhp1MJrh7nUepCBck5+mAzfO9JrbApNNgaTdGDITg=
golang.org/x/sys v0.29.0 h1:TPYlXGxvx1MGTn2GiZDhnjPA9wZzZeGKHHmKhHYvgaU=
golang.org/x/sys v0.29.0/go.mod h1:/VUhepiaJMQUp4+oa/7Zr1D23ma6VTLIYjOOTFZPUcA=
golang.org/x/term v0.27.0 h1:WP60Sv1nlK1T6SupCHbXzSaN0b9wUmsPoRS9b61A23Q=
golang.org/x/term v0.27.0/go.mod h1:iMsnZpn0cago0GOrHO2+Y7u7JPn5AylBrcoWkElMTSM=
golang.org/x/tools v0.29.0 h1:Xx0h3TtM9rzQpQuR4dKLrdglAmCEN5Oi+P74JdhdzXE=
golang.org/x/tools v0.29.0/go.mod h1:KMQVMRsVxU6nHCFXrBPhDB8XncLNLM0lIy/F14RP588=
gopkg.in/check.v1 v0.0.0-20161208181325-20d25e280405/go.mod h1:Co6ibVJAznAaIkqp8huTwlJQCZ016jof/cbN4VW5Yz0=
gopkg.in/yaml.v3 v3.0.0-20200313102051-9f266ea9e77c/go.mod h1:K4uyk7z7BCEPqu6E+C64Yfv1cQ7kz7rIZviUmN+EgEM=
gopkg.in/yaml.v3 v3.0.1 h1:fxVm/GzAzEWqLHuvctI91KS9hhNmmWOoWu0XTYJS7CA=
gopkg.in/yaml.v3 v3.0.1/go.mod h1:K4uyk7z7BCEPqu6E+C64Yfv1cQ7kz7rIZviUmN+EgEM=
gotest.tools/v3 v3.0.3 h1:4AuOwCGf4lLR9u3YOe2awrHygurzhO/HeQ6laiA6Sx0=
gotest.tools/v3 v3.0.3/go.mod h1:Z7Lb0S5l+klDB31fvDQX8ss/FlKDxtlFlw3Oa8Ymbl8=
modernc.org/cc/v4 v4.20.0 h1:45Or8mQfbUqJOG9WaxvlFYOAQO0lQ5RvqBcFCXngjxk=
modernc.org/cc/v4 v4.20.0/go.mod h1:HM7VJTZbUCR3rV8EYBi9wxnJ0ZBRiGE5OeGXNA0IsLQ=
modernc.org/ccgo/v4 v4.16.0 h1:ofwORa6vx2FMm0916/CkZjpFPSR70VwTjUCe2Eg5BnA=
modernc.org/ccgo/v4 v4.16.0/go.mod h1:dkNyWIjFrVIZ68DTo36vHK+6/ShBn4ysU61So6PIqCI=
modernc.org/fileutil v1.3.0 h1:gQ5SIzK3H9kdfai/5x41oQiKValumqNTDXMvKo62HvE=
modernc.org/fileutil v1.3.0/go.mod h1:XatxS8fZi3pS8/hKG2GH/ArUogfxjpEKs3Ku3aK4JyQ=
modernc.org/gc/v2 v2.4.1 h1:9cNzOqPyMJBvrUipmynX0ZohMhcxPtMccYgGOJdOiBw=
modernc.org/gc/v2 v2.4.1/go.mod h1:wzN5dK1AzVGoH6XOzc3YZ+ey/jPgYHLuVckd62P0GYU=
modernc.org/gc/v3 v3.0.0-20240107210532-573471604cb6 h1:5D53IMaUuA5InSeMu9eJtlQXS2NxAhyWQvkKEgXZhHI=
modernc.org/gc/v3 v3.0.0-20240107210532-573471604cb6/go.mod h1:Qz0X07sNOR1jWYCrJMEnbW/X55x206Q7Vt4mz6/wHp4=
modernc.org/libc v1.49.3 h1:j2MRCRdwJI2ls/sGbeSk0t2bypOG/uvPZUsGQFDulqg=
modernc.org/libc v1.49.3/go.mod h1:yMZuGkn7pXbKfoT/M35gFJOAEdSKdxL0q64sF7KqCDo=
modernc.org/mathutil v1.6.0 h1:fRe9+AmYlaej+64JsEEhoWuAYBkOtQiMEU7n/XgfYi4=
modernc.org/mathutil v1.6.0/go.mod h1:Ui5Q9q1TR2gFm0AQRqQUaBWFLAhQpCwNcuhBOSedWPo=
modernc.org/memory v1.8.0 h1:IqGTL6eFMaDZZhEWwcREgeMXYwmW83LYW8cROZYkg+E=
modernc.org/memory v1.8.0/go.mod h1:XPZ936zp5OMKGWPqbD3JShgd/ZoQ7899TUuQqxY+peU=
modernc.org/opt v0.1.3 h1:3XOZf2yznlhC+ibLltsDGzABUGVx8J6pnFMS3E4dcq4=
modernc.org/opt v0.1.3/go.mod h1:WdSiB5evDcignE70guQKxYUl14mgWtbClRi5wmkkTX0=
modernc.org/sortutil v1.2.0 h1:jQiD3PfS2REGJNzNCMMaLSp/wdMNieTbKX920Cqdgqc=
modernc.org/sortutil v1.2.0/go.mod h1:TKU2s7kJMf1AE84OoiGppNHJwvB753OYfNl2WRb++Ss=
modernc.org/sqlite v1.29.10 h1:3u93dz83myFnMilBGCOLbr+HjklS6+5rJLx4q86RDAg=
modernc.org/sqlite v1.29.10/go.mod h1:ItX2a1OVGgNsFh6Dv60JQvGfJfTPHPVpV6DF59akYOA=
modernc.org/strutil v1.2.0 h1:agBi9dp1I+eOnxXeiZawM8F4LawKv4NzGWSaLfyeNZA=
modernc.org/strutil v1.2.0/go.mod h1:/mdcBmfOibveCTBxUl5B5l6W+TTH1FXPLHZE6bTosX0=
modernc.org/token v1.1.0 h1:Xl7Ap9dKaEs5kLoOQeQmPWevfnk/DM5qcLcYlA8ys6Y=
modernc.org/token v1.1.0/go.mod h1:UGzOrNV1mAFSEB63lOFHIpNRUVMvYTc6yu1SMY/XTDM=
FERRY_EOF_13

cat > 'internal/auth/auth.go' <<'FERRY_EOF_14'
// Package auth implements Ferry's signed session cookie and login throttling.
package auth

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"strings"
	"time"

	"golang.org/x/crypto/bcrypt"
)

const (
	CookieName     = "ferry_session"
	SessionTimeout = 12 * time.Hour
	maxCookieSize  = 4096
)

// Session is the signed payload stored in the cookie.
type Session struct {
	Username string `json:"u"`
	IssuedAt int64  `json:"iat"`
	Expires  int64  `json:"exp"`
	CSRF     string `json:"csrf"`
}

// Manager creates and validates signed session cookies.
type Manager struct {
	key          []byte
	username     string
	cookieSecure bool
}

// New returns a session manager. username is the only account allowed to log in.
func New(secret, username string, cookieSecure bool) (*Manager, error) {
	if len(secret) < 32 {
		return nil, errors.New("session secret must be at least 32 bytes")
	}
	if username == "" {
		return nil, errors.New("session username must not be empty")
	}
	return &Manager{
		key:          []byte(secret),
		username:     username,
		cookieSecure: cookieSecure,
	}, nil
}

// NewSession creates a fresh 12-hour session and its signed cookie value.
func (m *Manager) NewSession() (*Session, string, error) {
	csrfBytes := make([]byte, 32)
	if _, err := rand.Read(csrfBytes); err != nil {
		return nil, "", err
	}
	now := time.Now()
	s := &Session{
		Username: m.username,
		IssuedAt: now.Unix(),
		Expires:  now.Add(SessionTimeout).Unix(),
		CSRF:     hex.EncodeToString(csrfBytes),
	}
	token, err := m.sign(s)
	if err != nil {
		return nil, "", err
	}
	return s, token, nil
}

// Parse validates the signature, expiry and username of a cookie value.
func (m *Manager) Parse(value string) (*Session, error) {
	if value == "" || len(value) > maxCookieSize {
		return nil, errors.New("missing or oversized session cookie")
	}
	parts := strings.Split(value, ".")
	if len(parts) != 2 {
		return nil, errors.New("malformed session cookie")
	}
	payload, err := base64.RawURLEncoding.DecodeString(parts[0])
	if err != nil {
		return nil, errors.New("malformed session payload")
	}
	sig, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return nil, errors.New("malformed session signature")
	}
	mac := hmac.New(sha256.New, m.key)
	_, _ = mac.Write([]byte(parts[0]))
	if subtle.ConstantTimeCompare(sig, mac.Sum(nil)) != 1 {
		return nil, errors.New("invalid session signature")
	}
	var s Session
	if err := json.Unmarshal(payload, &s); err != nil {
		return nil, errors.New("invalid session payload")
	}
	if s.Username != m.username {
		return nil, errors.New("session belongs to a different user")
	}
	if s.CSRF == "" || len(s.CSRF) < 32 {
		return nil, errors.New("session is missing a CSRF token")
	}
	if time.Now().Unix() >= s.Expires {
		return nil, errors.New("session expired")
	}
	return &s, nil
}

// FromRequest returns the valid session attached to r, or nil.
func (m *Manager) FromRequest(r *http.Request) *Session {
	c, err := r.Cookie(CookieName)
	if err != nil {
		return nil
	}
	s, err := m.Parse(c.Value)
	if err != nil {
		return nil
	}
	return s
}

// SetCookie writes the session cookie.
func (m *Manager) SetCookie(w http.ResponseWriter, token string) {
	http.SetCookie(w, &http.Cookie{
		Name:     CookieName,
		Value:    token,
		Path:     "/",
		HttpOnly: true,
		Secure:   m.cookieSecure,
		SameSite: http.SameSiteStrictMode,
		MaxAge:   int(SessionTimeout.Seconds()),
		Expires:  time.Now().Add(SessionTimeout),
	})
}

// ClearCookie expires the session cookie.
func (m *Manager) ClearCookie(w http.ResponseWriter) {
	http.SetCookie(w, &http.Cookie{
		Name:     CookieName,
		Value:    "",
		Path:     "/",
		HttpOnly: true,
		Secure:   m.cookieSecure,
		SameSite: http.SameSiteStrictMode,
		MaxAge:   -1,
		Expires:  time.Unix(1, 0),
	})
}

func (m *Manager) sign(s *Session) (string, error) {
	payload, err := json.Marshal(s)
	if err != nil {
		return "", err
	}
	encoded := base64.RawURLEncoding.EncodeToString(payload)
	mac := hmac.New(sha256.New, m.key)
	_, _ = mac.Write([]byte(encoded))
	return encoded + "." + base64.RawURLEncoding.EncodeToString(mac.Sum(nil)), nil
}

// SecureCompare compares two strings without leaking timing information.
func SecureCompare(a, b string) bool {
	return subtle.ConstantTimeCompare([]byte(a), []byte(b)) == 1
}

// HashPassword returns a bcrypt hash suitable for FERRY_PASSWORD_HASH.
func HashPassword(password string) (string, error) {
	if len(password) < 8 {
		return "", errors.New("password must be at least 8 characters")
	}
	if len(password) > 72 {
		return "", errors.New("password must be at most 72 bytes (bcrypt limit)")
	}
	hash, err := bcrypt.GenerateFromPassword([]byte(password), bcrypt.DefaultCost)
	if err != nil {
		return "", fmt.Errorf("hash password: %w", err)
	}
	return string(hash), nil
}

// VerifyPassword checks a login password. When hash is set it is compared with
// bcrypt; otherwise plain is compared in constant time. The error is only for
// malformed hashes and is never shown to the user.
func VerifyPassword(password, hash, plain string) (bool, error) {
	if hash != "" {
		if err := bcrypt.CompareHashAndPassword([]byte(hash), []byte(password)); err != nil {
			if errors.Is(err, bcrypt.ErrMismatchedHashAndPassword) {
				return false, nil
			}
			return false, err
		}
		return true, nil
	}
	return SecureCompare(password, plain), nil
}

// IsBcryptHash reports whether value looks like a bcrypt hash.
func IsBcryptHash(value string) bool {
	return strings.HasPrefix(value, "$2a$") || strings.HasPrefix(value, "$2b$") ||
		strings.HasPrefix(value, "$2y$")
}

// ValidateBcryptHash checks the prefix and the encoded cost/salt so a
// truncated value is rejected at startup instead of breaking every login.
func ValidateBcryptHash(value string) error {
	if !IsBcryptHash(value) {
		return errors.New("must start with $2a$, $2b$ or $2y$")
	}
	if _, err := bcrypt.Cost([]byte(value)); err != nil {
		return fmt.Errorf("is not a valid bcrypt hash: %w", err)
	}
	return nil
}
FERRY_EOF_14

cat > 'internal/auth/auth_test.go' <<'FERRY_EOF_15'
package auth

import "testing"

func TestPasswordHashing(t *testing.T) {
	hash, err := HashPassword("a long enough password")
	if err != nil {
		t.Fatal(err)
	}
	if err := ValidateBcryptHash(hash); err != nil {
		t.Fatalf("generated hash rejected: %v", err)
	}
	ok, err := VerifyPassword("a long enough password", hash, "")
	if err != nil || !ok {
		t.Fatalf("VerifyPassword = %v, %v", ok, err)
	}
	ok, err = VerifyPassword("wrong password", hash, "")
	if err != nil || ok {
		t.Fatalf("wrong password accepted: %v, %v", ok, err)
	}
}

func TestValidateBcryptHashRejectsTruncated(t *testing.T) {
	if err := ValidateBcryptHash("$2a$10$abc"); err == nil {
		t.Fatal("truncated hash accepted")
	}
	if err := ValidateBcryptHash("not-a-hash"); err == nil {
		t.Fatal("plain text accepted as a hash")
	}
}

func TestPlaintextComparison(t *testing.T) {
	ok, err := VerifyPassword("secret", "", "secret")
	if err != nil || !ok {
		t.Fatalf("plaintext match = %v, %v", ok, err)
	}
	ok, _ = VerifyPassword("secret2", "", "secret")
	if ok {
		t.Fatal("plaintext mismatch accepted")
	}
}

func TestHashPasswordLength(t *testing.T) {
	if _, err := HashPassword("short"); err == nil {
		t.Fatal("short password accepted")
	}
}
FERRY_EOF_15

cat > 'internal/auth/limiter.go' <<'FERRY_EOF_16'
package auth

import (
	"sync"
	"time"
)

const (
	maxFailures    = 5
	failureWindow  = 10 * time.Minute
	blockDuration  = 10 * time.Minute
	limiterMaxIdle = time.Hour
)

type loginAttempts struct {
	failures     []time.Time
	blockedUntil time.Time
	lastSeen     time.Time
}

// Limiter blocks an IP after five failed logins in ten minutes for ten minutes.
type Limiter struct {
	mu      sync.Mutex
	entries map[string]*loginAttempts
	now     func() time.Time
}

// NewLimiter creates an empty login limiter.
func NewLimiter() *Limiter {
	return &Limiter{entries: make(map[string]*loginAttempts), now: time.Now}
}

// Blocked reports whether ip is currently blocked and for how much longer.
func (l *Limiter) Blocked(ip string) (bool, time.Duration) {
	l.mu.Lock()
	defer l.mu.Unlock()
	now := l.now()
	e := l.entries[ip]
	if e == nil {
		return false, 0
	}
	if now.After(e.blockedUntil) {
		if e.blockedUntil.IsZero() {
			return false, 0
		}
		// Block expired. Forget the history so the next failure starts fresh.
		delete(l.entries, ip)
		return false, 0
	}
	return true, e.blockedUntil.Sub(now)
}

// Failure records one failed login for ip.
func (l *Limiter) Failure(ip string) {
	l.mu.Lock()
	defer l.mu.Unlock()
	now := l.now()
	e := l.entries[ip]
	if e == nil {
		e = &loginAttempts{}
		l.entries[ip] = e
	}
	e.lastSeen = now
	cutoff := now.Add(-failureWindow)
	kept := e.failures[:0]
	for _, t := range e.failures {
		if t.After(cutoff) {
			kept = append(kept, t)
		}
	}
	e.failures = append(kept, now)
	if len(e.failures) >= maxFailures {
		e.blockedUntil = now.Add(blockDuration)
		e.failures = nil
	}
	l.sweepLocked(now)
}

// Success clears the failure history for ip.
func (l *Limiter) Success(ip string) {
	l.mu.Lock()
	defer l.mu.Unlock()
	delete(l.entries, ip)
}

func (l *Limiter) sweepLocked(now time.Time) {
	if len(l.entries) < 256 {
		return
	}
	for ip, e := range l.entries {
		if now.Sub(e.lastSeen) > limiterMaxIdle && now.After(e.blockedUntil) {
			delete(l.entries, ip)
		}
	}
}
FERRY_EOF_16

cat > 'internal/config/config.go' <<'FERRY_EOF_17'
// Package config loads and validates Ferry's environment configuration.
package config

import (
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"

	v1 "github.com/google/go-containerregistry/pkg/v1"

	"ferry/internal/auth"
)

const (
	defaultPort        = 8080
	defaultMaxBytes    = int64(10737418240) // 10 GiB
	defaultDataDir     = "/data"
	defaultPlatform    = "linux/amd64"
	defaultDockerRepo  = "ferry"
	defaultRetention   = 0
	minSecretKeyLength = 32
)

var (
	usernameRE = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$`)
	repoRE     = regexp.MustCompile(`^[a-z0-9][a-z0-9._-]{0,99}$`)
)

// Config holds every setting Ferry needs. Secrets are never logged.
type Config struct {
	Username      string
	Password      string
	PasswordHash  string
	SecretKey     string
	Port          int
	ListenAddr    string
	MaxTotalBytes int64
	DataDir       string
	CookieSecure  bool
	Platform      string
	TrustProxy    bool

	DockerHubUsername string
	DockerHubToken    string
	DockerHubRepo     string

	RetentionDays int
	Domain        string
}

// Load reads the process environment. It returns one aggregated, actionable
// error when anything required is missing or invalid.
func Load() (*Config, error) {
	var problems []string

	username := strings.TrimSpace(os.Getenv("FERRY_USERNAME"))
	if username == "" {
		problems = append(problems, "FERRY_USERNAME is required (the single login username).")
	} else if !usernameRE.MatchString(username) {
		problems = append(problems, "FERRY_USERNAME may only contain letters, digits, dot, underscore and dash (max 100 characters).")
	}

	password := os.Getenv("FERRY_PASSWORD")
	passwordHash := strings.TrimSpace(os.Getenv("FERRY_PASSWORD_HASH"))
	if passwordHash != "" {
		if err := auth.ValidateBcryptHash(passwordHash); err != nil {
			problems = append(problems, "FERRY_PASSWORD_HASH "+err.Error()+". Generate a new one with: ferry hash-password")
		}
		if password == "CHANGE_ME" {
			password = ""
		}
	} else if password == "" {
		problems = append(problems, "FERRY_PASSWORD or FERRY_PASSWORD_HASH is required.")
	} else if password == "CHANGE_ME" {
		problems = append(problems, "FERRY_PASSWORD is still the placeholder CHANGE_ME; choose a real password or set FERRY_PASSWORD_HASH.")
	}
	if username == "CHANGE_ME" {
		problems = append(problems, "FERRY_USERNAME is still the placeholder CHANGE_ME; choose a real username.")
	}

	secret := os.Getenv("FERRY_SECRET_KEY")
	if len(secret) < minSecretKeyLength {
		problems = append(problems, fmt.Sprintf("FERRY_SECRET_KEY is required and must be at least %d characters. Generate one with: openssl rand -hex 32", minSecretKeyLength))
	}

	port, err := intEnv("FERRY_PORT", defaultPort)
	if err != nil {
		problems = append(problems, err.Error())
	} else if port < 1 || port > 65535 {
		problems = append(problems, "FERRY_PORT must be between 1 and 65535.")
	}

	listenAddr := strings.TrimSpace(os.Getenv("FERRY_LISTEN_ADDR"))
	if listenAddr == "" {
		listenAddr = ":" + strconv.Itoa(port)
	} else if err := validateListenAddr(listenAddr); err != nil {
		problems = append(problems, err.Error())
	}

	maxTotal, err := int64Env("FERRY_MAX_TOTAL_BYTES", defaultMaxBytes)
	if err != nil {
		problems = append(problems, err.Error())
	} else if maxTotal <= 0 {
		problems = append(problems, "FERRY_MAX_TOTAL_BYTES must be greater than zero.")
	}

	dataDir := strings.TrimSpace(os.Getenv("FERRY_DATA_DIR"))
	if dataDir == "" {
		dataDir = defaultDataDir
	}
	if abs, err := filepath.Abs(dataDir); err == nil {
		dataDir = abs
	} else {
		problems = append(problems, fmt.Sprintf("FERRY_DATA_DIR is invalid: %v", err))
	}

	cookieSecure, err := boolEnv("FERRY_COOKIE_SECURE", false)
	if err != nil {
		problems = append(problems, err.Error())
	}

	trustProxy, err := boolEnv("FERRY_TRUST_PROXY", false)
	if err != nil {
		problems = append(problems, err.Error())
	}

	platform := strings.TrimSpace(os.Getenv("FERRY_PLATFORM"))
	if platform == "" {
		platform = defaultPlatform
	}
	if p, err := v1.ParsePlatform(platform); err != nil || p == nil || p.OS == "" || p.Architecture == "" {
		problems = append(problems, "FERRY_PLATFORM must look like linux/amd64 or linux/arm64.")
	}

	hubUser := strings.TrimSpace(os.Getenv("DOCKERHUB_USERNAME"))
	if hubUser == "" {
		problems = append(problems, "DOCKERHUB_USERNAME is required (your Docker Hub username).")
	}

	hubToken := strings.TrimSpace(os.Getenv("DOCKERHUB_TOKEN"))
	if hubToken == "" {
		problems = append(problems, "DOCKERHUB_TOKEN is required (a Docker Hub Personal Access Token with Read, Write and Delete permission).")
	} else if hubToken == "CHANGE_ME" {
		problems = append(problems, "DOCKERHUB_TOKEN is still the placeholder CHANGE_ME; create a Docker Hub access token.")
	}
	if hubUser == "CHANGE_ME" {
		problems = append(problems, "DOCKERHUB_USERNAME is still the placeholder CHANGE_ME; enter your Docker Hub username.")
	}

	hubRepo := strings.TrimSpace(os.Getenv("DOCKERHUB_REPO"))
	if hubRepo == "" {
		hubRepo = defaultDockerRepo
	}
	if !repoRE.MatchString(hubRepo) {
		problems = append(problems, "DOCKERHUB_REPO must be a single lowercase repository name (letters, digits, dot, underscore, dash), for example ferry.")
	}

	retention, err := intEnv("FERRY_RETENTION_DAYS", defaultRetention)
	if err != nil {
		problems = append(problems, err.Error())
	} else if retention < 0 {
		problems = append(problems, "FERRY_RETENTION_DAYS must be 0 (disabled) or a positive number of days.")
	}

	if len(problems) > 0 {
		return nil, errors.New("invalid configuration:\n  - " + strings.Join(problems, "\n  - "))
	}

	return &Config{
		Username:          username,
		Password:          password,
		PasswordHash:      passwordHash,
		SecretKey:         secret,
		Port:              port,
		ListenAddr:        listenAddr,
		MaxTotalBytes:     maxTotal,
		DataDir:           dataDir,
		CookieSecure:      cookieSecure,
		Platform:          platform,
		TrustProxy:        trustProxy,
		DockerHubUsername: hubUser,
		DockerHubToken:    hubToken,
		DockerHubRepo:     hubRepo,
		RetentionDays:     retention,
		Domain:            strings.TrimSpace(os.Getenv("FERRY_DOMAIN")),
	}, nil
}

func validateListenAddr(value string) error {
	host, port, err := net.SplitHostPort(value)
	if err != nil {
		return fmt.Errorf("FERRY_LISTEN_ADDR must look like 0.0.0.0:8080 or 127.0.0.1:8080, got %q.", value)
	}
	_ = host
	n, err := strconv.Atoi(port)
	if err != nil || n < 1 || n > 65535 {
		return fmt.Errorf("FERRY_LISTEN_ADDR has an invalid port %q.", port)
	}
	return nil
}

func intEnv(name string, def int) (int, error) {
	raw := strings.TrimSpace(os.Getenv(name))
	if raw == "" {
		return def, nil
	}
	v, err := strconv.Atoi(raw)
	if err != nil {
		return 0, fmt.Errorf("%s must be a whole number, got %q.", name, raw)
	}
	return v, nil
}

func int64Env(name string, def int64) (int64, error) {
	raw := strings.TrimSpace(os.Getenv(name))
	if raw == "" {
		return def, nil
	}
	v, err := strconv.ParseInt(raw, 10, 64)
	if err != nil {
		return 0, fmt.Errorf("%s must be a whole number of bytes, got %q.", name, raw)
	}
	return v, nil
}

func boolEnv(name string, def bool) (bool, error) {
	raw := strings.TrimSpace(os.Getenv(name))
	if raw == "" {
		return def, nil
	}
	v, err := strconv.ParseBool(raw)
	if err != nil {
		return false, fmt.Errorf("%s must be true or false, got %q.", name, raw)
	}
	return v, nil
}
FERRY_EOF_17

cat > 'internal/db/db.go' <<'FERRY_EOF_18'
// Package db stores Ferry job metadata in SQLite.
package db

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"net/url"
	"path/filepath"
	"strings"
	"sync"
	"time"

	_ "modernc.org/sqlite"
)

// Job states.
const (
	StateDraft       = "draft"
	StateQueued      = "queued"
	StateDownloading = "downloading"
	StateBuilding    = "building"
	StatePushing     = "pushing"
	StateDone        = "done"
	StateFailed      = "failed"
)

const (
	sourceUpload  = "upload"
	sourceURL     = "url"
	statusDone    = "done"
	statusPending = "pending"
	maxLogBytes   = 256 * 1024
)

// IsActive reports whether a state means the worker owns the job.
func IsActive(state string) bool {
	switch state {
	case StateQueued, StateDownloading, StateBuilding, StatePushing:
		return true
	}
	return false
}

// IsTerminal reports whether a job can no longer change state by itself.
func IsTerminal(state string) bool {
	return state == StateDone || state == StateFailed
}

// Job is the metadata retained for every transfer.
type Job struct {
	ID            string
	State         string
	CreatedAt     time.Time
	UpdatedAt     time.Time
	FinishedAt    time.Time
	TotalBytes    int64
	FileCount     int
	Image         string
	Error         string
	Log           string
	ImageDeleted  bool
	Compress      bool
	Encrypted     bool
	HasPassphrase bool
	PassphraseEnc string
}

// File is one finished file in a job, or a pending URL entry.
type File struct {
	ID        int64
	JobID     string
	Name      string
	Size      int64
	SHA256    string
	MD5       string
	Source    string
	URL       string
	Status    string
	CreatedAt time.Time
}

// Upload is an in-progress (or just-completed) chunked upload.
type Upload struct {
	ID               string
	JobID            string
	Filename         string
	OriginalFilename string
	DeclaredSize     int64
	Received         int64
	Completed        bool
	CreatedAt        time.Time
}

// Store wraps the SQLite database. All access goes through one connection,
// which together with WAL and busy_timeout keeps concurrent writes safe.
type Store struct {
	db      *sql.DB
	dataDir string
	writeMu sync.Mutex
}

// Open creates or opens the database and applies the schema.
func Open(path, dataDir string) (*Store, error) {
	u := &url.URL{Scheme: "file", Path: filepath.ToSlash(path)}
	q := u.Query()
	q.Add("_pragma", "busy_timeout(5000)")
	q.Add("_pragma", "journal_mode(WAL)")
	q.Add("_pragma", "synchronous(NORMAL)")
	q.Add("_pragma", "foreign_keys(ON)")
	u.RawQuery = q.Encode()

	sqldb, err := sql.Open("sqlite", u.String())
	if err != nil {
		return nil, fmt.Errorf("open database: %w", err)
	}
	sqldb.SetMaxOpenConns(1)
	sqldb.SetMaxIdleConns(1)

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := sqldb.PingContext(ctx); err != nil {
		_ = sqldb.Close()
		return nil, fmt.Errorf("connect to database: %w", err)
	}
	s := &Store{db: sqldb, dataDir: dataDir}
	if err := s.migrate(ctx); err != nil {
		_ = sqldb.Close()
		return nil, err
	}
	return s, nil
}

func (s *Store) migrate(ctx context.Context) error {
	stmts := []string{
		`CREATE TABLE IF NOT EXISTS jobs (
			id TEXT PRIMARY KEY,
			state TEXT NOT NULL,
			created_at INTEGER NOT NULL,
			updated_at INTEGER NOT NULL,
			finished_at INTEGER NOT NULL DEFAULT 0,
			total_bytes INTEGER NOT NULL DEFAULT 0,
			file_count INTEGER NOT NULL DEFAULT 0,
			image TEXT NOT NULL DEFAULT '',
			error TEXT NOT NULL DEFAULT '',
			log TEXT NOT NULL DEFAULT '',
			image_deleted INTEGER NOT NULL DEFAULT 0,
			compress INTEGER NOT NULL DEFAULT 0,
			encrypted INTEGER NOT NULL DEFAULT 0,
			passphrase_enc TEXT NOT NULL DEFAULT ''
		)`,
		`CREATE INDEX IF NOT EXISTS idx_jobs_state ON jobs(state)`,
		`CREATE INDEX IF NOT EXISTS idx_jobs_created ON jobs(created_at DESC)`,
		`CREATE TABLE IF NOT EXISTS uploads (
			id TEXT PRIMARY KEY,
			job_id TEXT NOT NULL REFERENCES jobs(id) ON DELETE CASCADE,
			filename TEXT NOT NULL,
			original_filename TEXT NOT NULL DEFAULT '',
			declared_size INTEGER NOT NULL,
			received INTEGER NOT NULL DEFAULT 0,
			completed INTEGER NOT NULL DEFAULT 0,
			created_at INTEGER NOT NULL,
			updated_at INTEGER NOT NULL
		)`,
		`CREATE INDEX IF NOT EXISTS idx_uploads_job ON uploads(job_id)`,
		`CREATE TABLE IF NOT EXISTS job_files (
			id INTEGER PRIMARY KEY AUTOINCREMENT,
			job_id TEXT NOT NULL REFERENCES jobs(id) ON DELETE CASCADE,
			name TEXT NOT NULL DEFAULT '',
			size INTEGER NOT NULL DEFAULT 0,
			sha256 TEXT NOT NULL DEFAULT '',
			md5 TEXT NOT NULL DEFAULT '',
			source TEXT NOT NULL,
			url TEXT NOT NULL DEFAULT '',
			status TEXT NOT NULL DEFAULT 'done',
			created_at INTEGER NOT NULL,
			updated_at INTEGER NOT NULL
		)`,
		`CREATE INDEX IF NOT EXISTS idx_job_files_job ON job_files(job_id)`,
		`CREATE UNIQUE INDEX IF NOT EXISTS idx_job_files_done_name
			ON job_files(job_id, name) WHERE status = 'done'`,
	}
	for _, stmt := range stmts {
		if _, err := s.db.ExecContext(ctx, stmt); err != nil {
			return fmt.Errorf("initialize database: %w", err)
		}
	}
	if _, err := s.db.ExecContext(ctx, `PRAGMA busy_timeout = 5000`); err != nil {
		return fmt.Errorf("configure database timeout: %w", err)
	}
	if err := s.ensureColumn(ctx, "job_files", "md5", "TEXT NOT NULL DEFAULT ''"); err != nil {
		return err
	}
	if err := s.ensureColumn(ctx, "jobs", "compress", "INTEGER NOT NULL DEFAULT 0"); err != nil {
		return err
	}
	if err := s.ensureColumn(ctx, "uploads", "original_filename", "TEXT NOT NULL DEFAULT ''"); err != nil {
		return err
	}
	if err := s.ensureColumn(ctx, "jobs", "encrypted", "INTEGER NOT NULL DEFAULT 0"); err != nil {
		return err
	}
	if err := s.ensureColumn(ctx, "jobs", "passphrase_enc", "TEXT NOT NULL DEFAULT ''"); err != nil {
		return err
	}
	return nil
}

// ensureColumn adds a column to an existing table when upgrading an old
// database. It is a no-op when the column already exists.
func (s *Store) ensureColumn(ctx context.Context, table, column, definition string) error {
	rows, err := s.db.QueryContext(ctx, `PRAGMA table_info(`+table+`)`)
	if err != nil {
		return fmt.Errorf("inspect %s table: %w", table, err)
	}
	defer rows.Close()
	found := false
	for rows.Next() {
		var (
			cid       int
			name      string
			ctype     string
			notnull   int
			dfltValue sql.NullString
			pk        int
		)
		if err := rows.Scan(&cid, &name, &ctype, &notnull, &dfltValue, &pk); err != nil {
			return fmt.Errorf("inspect %s table: %w", table, err)
		}
		if name == column {
			found = true
		}
	}
	if err := rows.Err(); err != nil {
		return err
	}
	if found {
		return nil
	}
	if _, err := s.db.ExecContext(ctx, `ALTER TABLE `+table+` ADD COLUMN `+column+` `+definition); err != nil {
		return fmt.Errorf("upgrade %s table: %w", table, err)
	}
	return nil
}

// Close closes the database.
func (s *Store) Close() error {
	return s.db.Close()
}

// DataDir returns the configured data directory.
func (s *Store) DataDir() string { return s.dataDir }

// CreateJob inserts a new draft job.
func (s *Store) CreateJob(ctx context.Context, id string) (*Job, error) {
	now := time.Now().Unix()
	s.writeMu.Lock()
	defer s.writeMu.Unlock()
	if _, err := s.db.ExecContext(ctx,
		`INSERT INTO jobs (id, state, created_at, updated_at) VALUES (?, ?, ?, ?)`,
		id, StateDraft, now, now,
	); err != nil {
		return nil, fmt.Errorf("create job: %w", err)
	}
	return s.getJob(ctx, id)
}

// GetJob loads one job including its log.
func (s *Store) GetJob(ctx context.Context, id string) (*Job, error) {
	return s.getJob(ctx, id)
}

func (s *Store) getJob(ctx context.Context, id string) (*Job, error) {
	row := s.db.QueryRowContext(ctx, `SELECT id, state, created_at, updated_at, finished_at,
		total_bytes, file_count, image, error, log, image_deleted, compress, encrypted, passphrase_enc FROM jobs WHERE id = ?`, id)
	j, err := scanJob(row, true)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return nil, ErrNotFound
		}
		return nil, fmt.Errorf("load job: %w", err)
	}
	return j, nil
}

// ErrNotFound is returned when a job or file does not exist.
var ErrNotFound = errors.New("not found")

// ErrNotDraft means a job stopped being a draft during an operation.
var ErrNotDraft = errors.New("job is no longer a draft")

type rowScanner interface {
	Scan(dest ...any) error
}

func scanJob(row rowScanner, withLog bool) (*Job, error) {
	var (
		j           Job
		created     int64
		updated     int64
		finished    int64
		imageDel    int
		compress    int
		encrypted   int
		logContents string
		passEnc     string
	)
	err := row.Scan(&j.ID, &j.State, &created, &updated, &finished,
		&j.TotalBytes, &j.FileCount, &j.Image, &j.Error, &logContents, &imageDel, &compress, &encrypted, &passEnc)
	if err != nil {
		return nil, err
	}
	j.CreatedAt = time.Unix(created, 0)
	j.UpdatedAt = time.Unix(updated, 0)
	if finished > 0 {
		j.FinishedAt = time.Unix(finished, 0)
	}
	j.ImageDeleted = imageDel != 0
	j.Compress = compress != 0
	j.Encrypted = encrypted != 0
	j.PassphraseEnc = passEnc
	j.HasPassphrase = passEnc != ""
	if withLog {
		j.Log = logContents
	}
	return &j, nil
}

func scanJobNoLog(row rowScanner) (*Job, error) {
	var (
		j         Job
		created   int64
		updated   int64
		finished  int64
		imageDel  int
		compress  int
		encrypted int
		passEnc   string
	)
	err := row.Scan(&j.ID, &j.State, &created, &updated, &finished,
		&j.TotalBytes, &j.FileCount, &j.Image, &j.Error, &imageDel, &compress, &encrypted, &passEnc)
	if err != nil {
		return nil, err
	}
	j.CreatedAt = time.Unix(created, 0)
	j.UpdatedAt = time.Unix(updated, 0)
	if finished > 0 {
		j.FinishedAt = time.Unix(finished, 0)
	}
	j.ImageDeleted = imageDel != 0
	j.Compress = compress != 0
	j.Encrypted = encrypted != 0
	j.PassphraseEnc = passEnc
	j.HasPassphrase = passEnc != ""
	return &j, nil
}

// ListJobs returns the newest jobs without their logs.
func (s *Store) ListJobs(ctx context.Context, limit int) ([]Job, error) {
	if limit <= 0 || limit > 1000 {
		limit = 100
	}
	rows, err := s.db.QueryContext(ctx, `SELECT id, state, created_at, updated_at, finished_at,
		total_bytes, file_count, image, error, image_deleted, compress, encrypted, passphrase_enc FROM jobs
		ORDER BY created_at DESC LIMIT ?`, limit)
	if err != nil {
		return nil, fmt.Errorf("list jobs: %w", err)
	}
	defer rows.Close()
	var out []Job
	for rows.Next() {
		j, err := scanJobNoLog(rows)
		if err != nil {
			return nil, fmt.Errorf("read job: %w", err)
		}
		out = append(out, *j)
	}
	return out, rows.Err()
}

// ListByState returns jobs in a given state.
func (s *Store) ListByState(ctx context.Context, state string) ([]Job, error) {
	rows, err := s.db.QueryContext(ctx, `SELECT id, state, created_at, updated_at, finished_at,
		total_bytes, file_count, image, error, image_deleted, compress, encrypted, passphrase_enc FROM jobs
		WHERE state = ? ORDER BY created_at ASC`, state)
	if err != nil {
		return nil, fmt.Errorf("list jobs: %w", err)
	}
	defer rows.Close()
	var out []Job
	for rows.Next() {
		j, err := scanJobNoLog(rows)
		if err != nil {
			return nil, fmt.Errorf("read job: %w", err)
		}
		out = append(out, *j)
	}
	return out, rows.Err()
}

// ListStaleDrafts returns draft jobs untouched before cutoff.
func (s *Store) ListStaleDrafts(ctx context.Context, cutoff time.Time) ([]Job, error) {
	rows, err := s.db.QueryContext(ctx, `SELECT id, state, created_at, updated_at, finished_at,
		total_bytes, file_count, image, error, image_deleted, compress, encrypted, passphrase_enc FROM jobs
		WHERE state = ? AND updated_at < ?`, StateDraft, cutoff.Unix())
	if err != nil {
		return nil, fmt.Errorf("list stale drafts: %w", err)
	}
	defer rows.Close()
	var out []Job
	for rows.Next() {
		j, err := scanJobNoLog(rows)
		if err != nil {
			return nil, fmt.Errorf("read stale draft: %w", err)
		}
		out = append(out, *j)
	}
	return out, rows.Err()
}

// ListDoneBefore returns done jobs finished before cutoff that still have an image.
func (s *Store) ListDoneBefore(ctx context.Context, cutoff time.Time) ([]Job, error) {
	rows, err := s.db.QueryContext(ctx, `SELECT id, state, created_at, updated_at, finished_at,
		total_bytes, file_count, image, error, image_deleted, compress, encrypted, passphrase_enc FROM jobs
		WHERE state IN (?, ?) AND finished_at > 0 AND finished_at < ? AND image != '' AND image_deleted = 0`,
		StateDone, StateFailed, cutoff.Unix())
	if err != nil {
		return nil, fmt.Errorf("list old images: %w", err)
	}
	defer rows.Close()
	var out []Job
	for rows.Next() {
		j, err := scanJobNoLog(rows)
		if err != nil {
			return nil, fmt.Errorf("read old job: %w", err)
		}
		out = append(out, *j)
	}
	return out, rows.Err()
}

// Transition atomically changes state when the current state matches from.
func (s *Store) Transition(ctx context.Context, id, from, to, errMsg string) (bool, error) {
	now := time.Now().Unix()
	finished := int64(0)
	if to == StateDone || to == StateFailed {
		finished = now
	}
	s.writeMu.Lock()
	defer s.writeMu.Unlock()
	res, err := s.db.ExecContext(ctx, `UPDATE jobs SET state = ?, error = ?, updated_at = ?,
		finished_at = CASE WHEN ? IN (?, ?) THEN ? ELSE 0 END
		WHERE id = ? AND state = ?`,
		to, errMsg, now, to, StateDone, StateFailed, finished, id, from)
	if err != nil {
		return false, fmt.Errorf("update job state: %w", err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return false, err
	}
	if n == 1 && (to == StateDone || to == StateFailed) {
		_, _ = s.db.ExecContext(ctx, `UPDATE jobs SET passphrase_enc = '' WHERE id = ?`, id)
	}
	return n == 1, nil
}

// SetState changes state unconditionally (used by the worker).
func (s *Store) SetState(ctx context.Context, id, to, errMsg string) error {
	now := time.Now().Unix()
	finished := int64(0)
	if to == StateDone || to == StateFailed {
		finished = now
	}
	s.writeMu.Lock()
	defer s.writeMu.Unlock()
	res, err := s.db.ExecContext(ctx, `UPDATE jobs SET state = ?, error = ?, updated_at = ?,
		finished_at = CASE WHEN ? IN (?, ?) THEN ? ELSE 0 END WHERE id = ?`,
		to, errMsg, now, to, StateDone, StateFailed, finished, id)
	if err != nil {
		return fmt.Errorf("update job state: %w", err)
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return ErrNotFound
	}
	if to == StateDone || to == StateFailed {
		_, _ = s.db.ExecContext(ctx, `UPDATE jobs SET passphrase_enc = '' WHERE id = ?`, id)
	}
	return nil
}

// Fail marks a job failed with a human-readable message.
func (s *Store) Fail(ctx context.Context, id, message string) error {
	return s.SetState(ctx, id, StateFailed, message)
}

// Complete marks a job done and records its image.
func (s *Store) Complete(ctx context.Context, id, image string, total int64, count int) error {
	now := time.Now().Unix()
	s.writeMu.Lock()
	defer s.writeMu.Unlock()
	res, err := s.db.ExecContext(ctx, `UPDATE jobs SET state = ?, image = ?, error = '',
		total_bytes = ?, file_count = ?, updated_at = ?, finished_at = ? WHERE id = ?`,
		StateDone, image, total, count, now, now, id)
	if err != nil {
		return fmt.Errorf("finish job: %w", err)
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return ErrNotFound
	}
	_, _ = s.db.ExecContext(ctx, `UPDATE jobs SET passphrase_enc = '' WHERE id = ?`, id)
	return nil
}

// SetImage records the image tag even when the job later fails, so retention
// and the History page can still delete the tag from Docker Hub.
func (s *Store) SetImage(ctx context.Context, id, image string) error {
	s.writeMu.Lock()
	defer s.writeMu.Unlock()
	_, err := s.db.ExecContext(ctx, `UPDATE jobs SET image = ?, updated_at = ? WHERE id = ?`,
		image, time.Now().Unix(), id)
	if err != nil {
		return fmt.Errorf("record image name: %w", err)
	}
	return nil
}

// SetImageDeleted flags that the job's Docker Hub tag was removed.
func (s *Store) SetImageDeleted(ctx context.Context, id string) error {
	s.writeMu.Lock()
	defer s.writeMu.Unlock()
	_, err := s.db.ExecContext(ctx, `UPDATE jobs SET image_deleted = 1, updated_at = ? WHERE id = ?`,
		time.Now().Unix(), id)
	if err != nil {
		return fmt.Errorf("mark image deleted: %w", err)
	}
	return nil
}

// AppendLog appends one timestamped line and caps the stored log size.
func (s *Store) AppendLog(ctx context.Context, id, line string) error {
	if !strings.HasSuffix(line, "\n") {
		line += "\n"
	}
	stamp := time.Now().UTC().Format("2006-01-02 15:04:05")
	s.writeMu.Lock()
	defer s.writeMu.Unlock()
	_, err := s.db.ExecContext(ctx, `UPDATE jobs SET log = substr(log || ?, ?), updated_at = ? WHERE id = ?`,
		stamp+" "+line, -maxLogBytes, time.Now().Unix(), id)
	if err != nil {
		return fmt.Errorf("append job log: %w", err)
	}
	return nil
}

// Touch updates the job's updated_at timestamp.
func (s *Store) Touch(ctx context.Context, id string) error {
	s.writeMu.Lock()
	defer s.writeMu.Unlock()
	_, err := s.db.ExecContext(ctx, `UPDATE jobs SET updated_at = ? WHERE id = ?`,
		time.Now().Unix(), id)
	if err != nil {
		return fmt.Errorf("touch job: %w", err)
	}
	return nil
}

// SetJobOptions stores the optional compression flag and the encrypted
// passphrase for a draft job. The passphrase is never stored in plain text.
func (s *Store) SetJobOptions(ctx context.Context, jobID, passphraseEnc string, compress bool) error {
	flag := 0
	if compress {
		flag = 1
	}
	s.writeMu.Lock()
	defer s.writeMu.Unlock()
	encrypted := 0
	if passphraseEnc != "" {
		encrypted = 1
	}
	res, err := s.db.ExecContext(ctx, `UPDATE jobs SET compress = ?, encrypted = ?, passphrase_enc = ?, updated_at = ?
		WHERE id = ? AND state = ?`, flag, encrypted, passphraseEnc, time.Now().Unix(), jobID, StateDraft)
	if err != nil {
		return fmt.Errorf("save job options: %w", err)
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return ErrNotDraft
	}
	return nil
}

// ClearJobPassphrase removes the stored passphrase once a job is finished.
func (s *Store) ClearJobPassphrase(ctx context.Context, jobID string) error {
	s.writeMu.Lock()
	defer s.writeMu.Unlock()
	_, err := s.db.ExecContext(ctx, `UPDATE jobs SET passphrase_enc = '' WHERE id = ?`, jobID)
	if err != nil {
		return fmt.Errorf("clear job passphrase: %w", err)
	}
	return nil
}

// DeleteStaleDraft atomically removes a draft that is still untouched before
// cutoff. It returns false if the job changed state or was touched meanwhile.
func (s *Store) DeleteStaleDraft(ctx context.Context, id string, cutoff time.Time) (bool, error) {
	s.writeMu.Lock()
	defer s.writeMu.Unlock()
	res, err := s.db.ExecContext(ctx, `DELETE FROM jobs WHERE id = ? AND state = ? AND updated_at < ?`,
		id, StateDraft, cutoff.Unix())
	if err != nil {
		return false, fmt.Errorf("delete stale draft: %w", err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return false, err
	}
	return n == 1, nil
}

// DeleteJob removes a job and all dependent rows.
func (s *Store) DeleteJob(ctx context.Context, id string) error {
	s.writeMu.Lock()
	defer s.writeMu.Unlock()
	_, err := s.db.ExecContext(ctx, `DELETE FROM jobs WHERE id = ?`, id)
	if err != nil {
		return fmt.Errorf("delete job: %w", err)
	}
	return nil
}

// RecalcTotals recomputes the declared total and finished file count.
func (s *Store) RecalcTotals(ctx context.Context, jobID string) (int64, int, error) {
	s.writeMu.Lock()
	defer s.writeMu.Unlock()
	return s.recalcTotalsLocked(ctx, jobID)
}

func (s *Store) recalcTotalsLocked(ctx context.Context, jobID string) (int64, int, error) {
	var pendingUploads int64
	if err := s.db.QueryRowContext(ctx, `SELECT COALESCE(SUM(declared_size), 0)
		FROM uploads WHERE job_id = ? AND completed = 0`, jobID).Scan(&pendingUploads); err != nil {
		return 0, 0, fmt.Errorf("calculate upload total: %w", err)
	}
	var doneBytes int64
	var doneCount int
	if err := s.db.QueryRowContext(ctx, `SELECT COALESCE(SUM(size), 0), COUNT(*)
		FROM job_files WHERE job_id = ? AND status = 'done'`, jobID).Scan(&doneBytes, &doneCount); err != nil {
		return 0, 0, fmt.Errorf("calculate file total: %w", err)
	}
	total := pendingUploads + doneBytes
	if _, err := s.db.ExecContext(ctx, `UPDATE jobs SET total_bytes = ?, file_count = ?, updated_at = ?
		WHERE id = ?`, total, doneCount, time.Now().Unix(), jobID); err != nil {
		return 0, 0, fmt.Errorf("update job totals: %w", err)
	}
	return total, doneCount, nil
}

// DeclaredTotal returns the sum of pending upload declarations plus finished
// file sizes. It is the number enforced against FERRY_MAX_TOTAL_BYTES.
func (s *Store) DeclaredTotal(ctx context.Context, jobID string) (int64, error) {
	var pending int64
	err := s.db.QueryRowContext(ctx, `SELECT COALESCE(SUM(declared_size), 0)
		FROM uploads WHERE job_id = ? AND completed = 0`, jobID).Scan(&pending)
	if err != nil {
		return 0, fmt.Errorf("calculate upload total: %w", err)
	}
	var done int64
	err = s.db.QueryRowContext(ctx, `SELECT COALESCE(SUM(size), 0)
		FROM job_files WHERE job_id = ? AND status = 'done'`, jobID).Scan(&done)
	if err != nil {
		return 0, fmt.Errorf("calculate file total: %w", err)
	}
	return pending + done, nil
}

// CountPendingUploads returns how many uploads are not finalized.
func (s *Store) CountPendingUploads(ctx context.Context, jobID string) (int, error) {
	var n int
	err := s.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM uploads WHERE job_id = ? AND completed = 0`, jobID).Scan(&n)
	if err != nil {
		return 0, err
	}
	return n, nil
}

// CountFiles returns the number of finished files plus pending URL entries.
func (s *Store) CountFiles(ctx context.Context, jobID string) (int, error) {
	var n int
	err := s.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM job_files WHERE job_id = ?`, jobID).Scan(&n)
	if err != nil {
		return 0, err
	}
	return n, nil
}

// CreateUpload inserts a chunked upload reservation.
func (s *Store) CreateUpload(ctx context.Context, u *Upload) error {
	now := time.Now().Unix()
	s.writeMu.Lock()
	defer s.writeMu.Unlock()
	res, err := s.db.ExecContext(ctx, `INSERT INTO uploads
		(id, job_id, filename, original_filename, declared_size, received, completed, created_at, updated_at)
		SELECT ?, ?, ?, ?, ?, 0, 0, ?, ?
		WHERE EXISTS (SELECT 1 FROM jobs WHERE id = ? AND state = ?)`,
		u.ID, u.JobID, u.Filename, u.OriginalFilename, u.DeclaredSize, now, now, u.JobID, StateDraft)
	if err != nil {
		return fmt.Errorf("create upload: %w", err)
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return ErrNotDraft
	}
	u.CreatedAt = time.Unix(now, 0)
	_, _, _ = s.recalcTotalsLocked(ctx, u.JobID)
	return nil
}

// GetUpload loads an upload belonging to jobID.
func (s *Store) GetUpload(ctx context.Context, jobID, uploadID string) (*Upload, error) {
	var (
		u         Upload
		created   int64
		completed int
	)
	err := s.db.QueryRowContext(ctx, `SELECT id, job_id, filename, original_filename, declared_size, received, completed, created_at
		FROM uploads WHERE id = ? AND job_id = ?`, uploadID, jobID).
		Scan(&u.ID, &u.JobID, &u.Filename, &u.OriginalFilename, &u.DeclaredSize, &u.Received, &completed, &created)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, fmt.Errorf("load upload: %w", err)
	}
	u.Completed = completed != 0
	u.CreatedAt = time.Unix(created, 0)
	return &u, nil
}

// ListUploads returns in-progress uploads for a job.
func (s *Store) ListUploads(ctx context.Context, jobID string) ([]Upload, error) {
	rows, err := s.db.QueryContext(ctx, `SELECT id, job_id, filename, original_filename, declared_size, received, completed, created_at
		FROM uploads WHERE job_id = ? AND completed = 0 ORDER BY created_at ASC`, jobID)
	if err != nil {
		return nil, fmt.Errorf("list uploads: %w", err)
	}
	defer rows.Close()
	var out []Upload
	for rows.Next() {
		var (
			u         Upload
			created   int64
			completed int
		)
		if err := rows.Scan(&u.ID, &u.JobID, &u.Filename, &u.OriginalFilename, &u.DeclaredSize, &u.Received, &completed, &created); err != nil {
			return nil, err
		}
		u.Completed = completed != 0
		u.CreatedAt = time.Unix(created, 0)
		out = append(out, u)
	}
	return out, rows.Err()
}

// SetUploadReceived stores the number of bytes durably written.
func (s *Store) SetUploadReceived(ctx context.Context, jobID, uploadID string, received int64) error {
	now := time.Now().Unix()
	s.writeMu.Lock()
	defer s.writeMu.Unlock()
	res, err := s.db.ExecContext(ctx, `UPDATE uploads SET received = ?, updated_at = ?
		WHERE id = ? AND job_id = ? AND completed = 0`, received, now, uploadID, jobID)
	if err != nil {
		return fmt.Errorf("update upload progress: %w", err)
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return ErrNotFound
	}
	if _, err := s.db.ExecContext(ctx, `UPDATE jobs SET updated_at = ? WHERE id = ?`, now, jobID); err != nil {
		return fmt.Errorf("touch job: %w", err)
	}
	return nil
}

// CompleteUpload inserts the finished file and marks the upload complete.
func (s *Store) CompleteUpload(ctx context.Context, jobID, uploadID string, f *File) error {
	now := time.Now().Unix()
	s.writeMu.Lock()
	defer s.writeMu.Unlock()
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("begin upload completion: %w", err)
	}
	defer tx.Rollback()

	res, err := tx.ExecContext(ctx, `UPDATE uploads SET completed = 1, updated_at = ?
		WHERE id = ? AND job_id = ? AND completed = 0`, now, uploadID, jobID)
	if err != nil {
		return fmt.Errorf("complete upload: %w", err)
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return ErrNotFound
	}
	res, err = tx.ExecContext(ctx, `INSERT INTO job_files
		(job_id, name, size, sha256, md5, source, url, status, created_at, updated_at)
		VALUES (?, ?, ?, ?, ?, 'upload', '', 'done', ?, ?)`,
		jobID, f.Name, f.Size, f.SHA256, f.MD5, now, now)
	if err != nil {
		return fmt.Errorf("record finished file: %w", err)
	}
	id, err := res.LastInsertId()
	if err != nil {
		return err
	}
	f.ID = id
	f.JobID = jobID
	f.Source = sourceUpload
	f.Status = statusDone
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("commit upload completion: %w", err)
	}
	_, _, err = s.recalcTotalsLocked(ctx, jobID)
	return err
}

// DeleteUpload removes an unfinished upload reservation.
func (s *Store) DeleteUpload(ctx context.Context, jobID, uploadID string) error {
	s.writeMu.Lock()
	defer s.writeMu.Unlock()
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if _, err := tx.ExecContext(ctx, `DELETE FROM uploads WHERE id = ? AND job_id = ? AND completed = 0`,
		uploadID, jobID); err != nil {
		return fmt.Errorf("delete upload: %w", err)
	}
	if _, err := tx.ExecContext(ctx, `UPDATE jobs SET updated_at = ? WHERE id = ?`,
		time.Now().Unix(), jobID); err != nil {
		return err
	}
	if err := tx.Commit(); err != nil {
		return err
	}
	_, _, err = s.recalcTotalsLocked(ctx, jobID)
	return err
}

// AddURLFile inserts a pending URL entry.
func (s *Store) AddURLFile(ctx context.Context, jobID, rawURL string) (*File, error) {
	now := time.Now().Unix()
	s.writeMu.Lock()
	defer s.writeMu.Unlock()
	res, err := s.db.ExecContext(ctx, `INSERT INTO job_files
		(job_id, name, size, sha256, source, url, status, created_at, updated_at)
		SELECT ?, '', 0, '', 'url', ?, 'pending', ?, ?
		WHERE EXISTS (SELECT 1 FROM jobs WHERE id = ? AND state = ?)`,
		jobID, rawURL, now, now, jobID, StateDraft)
	if err != nil {
		return nil, fmt.Errorf("add URL: %w", err)
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return nil, ErrNotDraft
	}
	id, err := res.LastInsertId()
	if err != nil {
		return nil, err
	}
	if _, err := s.db.ExecContext(ctx, `UPDATE jobs SET updated_at = ? WHERE id = ?`, now, jobID); err != nil {
		return nil, err
	}
	return &File{ID: id, JobID: jobID, Source: sourceURL, URL: rawURL, Status: statusPending, CreatedAt: time.Unix(now, 0)}, nil
}

// ListFiles returns all file rows, including pending URLs.
func (s *Store) ListFiles(ctx context.Context, jobID string) ([]File, error) {
	rows, err := s.db.QueryContext(ctx, `SELECT id, job_id, name, size, sha256, md5, source, url, status, created_at
		FROM job_files WHERE job_id = ? ORDER BY id ASC`, jobID)
	if err != nil {
		return nil, fmt.Errorf("list files: %w", err)
	}
	defer rows.Close()
	return scanFiles(rows)
}

// ListDoneFiles returns only files that exist on disk and can be packed.
func (s *Store) ListDoneFiles(ctx context.Context, jobID string) ([]File, error) {
	rows, err := s.db.QueryContext(ctx, `SELECT id, job_id, name, size, sha256, md5, source, url, status, created_at
		FROM job_files WHERE job_id = ? AND status = 'done' ORDER BY id ASC`, jobID)
	if err != nil {
		return nil, fmt.Errorf("list finished files: %w", err)
	}
	defer rows.Close()
	return scanFiles(rows)
}

// ListPendingURLs returns URL entries not downloaded yet.
func (s *Store) ListPendingURLs(ctx context.Context, jobID string) ([]File, error) {
	rows, err := s.db.QueryContext(ctx, `SELECT id, job_id, name, size, sha256, md5, source, url, status, created_at
		FROM job_files WHERE job_id = ? AND source = 'url' AND status = 'pending' ORDER BY id ASC`, jobID)
	if err != nil {
		return nil, fmt.Errorf("list pending URLs: %w", err)
	}
	defer rows.Close()
	return scanFiles(rows)
}

func scanFiles(rows *sql.Rows) ([]File, error) {
	var out []File
	for rows.Next() {
		var (
			f       File
			created int64
		)
		if err := rows.Scan(&f.ID, &f.JobID, &f.Name, &f.Size, &f.SHA256, &f.MD5, &f.Source,
			&f.URL, &f.Status, &created); err != nil {
			return nil, fmt.Errorf("read file: %w", err)
		}
		f.CreatedAt = time.Unix(created, 0)
		out = append(out, f)
	}
	return out, rows.Err()
}

// GetFile loads one file row.
func (s *Store) GetFile(ctx context.Context, jobID string, fileID int64) (*File, error) {
	var (
		f       File
		created int64
	)
	err := s.db.QueryRowContext(ctx, `SELECT id, job_id, name, size, sha256, md5, source, url, status, created_at
		FROM job_files WHERE id = ? AND job_id = ?`, fileID, jobID).
		Scan(&f.ID, &f.JobID, &f.Name, &f.Size, &f.SHA256, &f.MD5, &f.Source, &f.URL, &f.Status, &created)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, fmt.Errorf("load file: %w", err)
	}
	f.CreatedAt = time.Unix(created, 0)
	return &f, nil
}

// MarkURLDone records a successfully downloaded URL.
func (s *Store) MarkURLDone(ctx context.Context, jobID string, fileID int64, name string, size int64, sha, md5sum string) error {
	now := time.Now().Unix()
	s.writeMu.Lock()
	defer s.writeMu.Unlock()
	res, err := s.db.ExecContext(ctx, `UPDATE job_files SET name = ?, size = ?, sha256 = ?, md5 = ?,
		status = 'done', updated_at = ? WHERE id = ? AND job_id = ? AND source = 'url' AND status = 'pending'`,
		name, size, sha, md5sum, now, fileID, jobID)
	if err != nil {
		return fmt.Errorf("finish URL download: %w", err)
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return ErrNotFound
	}
	_, _, err = s.recalcTotalsLocked(ctx, jobID)
	return err
}

// DeleteFile removes a file row (finished upload or pending URL).
func (s *Store) DeleteFile(ctx context.Context, jobID string, fileID int64) error {
	s.writeMu.Lock()
	defer s.writeMu.Unlock()
	res, err := s.db.ExecContext(ctx, `DELETE FROM job_files WHERE id = ? AND job_id = ?`, fileID, jobID)
	if err != nil {
		return fmt.Errorf("delete file: %w", err)
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return ErrNotFound
	}
	if _, err := s.db.ExecContext(ctx, `UPDATE jobs SET updated_at = ? WHERE id = ?`,
		time.Now().Unix(), jobID); err != nil {
		return err
	}
	_, _, err = s.recalcTotalsLocked(ctx, jobID)
	return err
}

// UsedNames returns every filename currently reserved in a job.
func (s *Store) UsedNames(ctx context.Context, jobID string) (map[string]bool, error) {
	// Names generated by Ferry itself are reserved so a user file cannot
	// overwrite the checksum files, the manifest or the unpack tool.
	used := map[string]bool{
		"SHA256SUMS": true, "MD5SUMS": true,
		"FERRY-MANIFEST.json": true, "README-FERRY.txt": true, "ferry": true,
	}
	rows, err := s.db.QueryContext(ctx, `SELECT name FROM job_files WHERE job_id = ? AND status = 'done'
		UNION SELECT filename FROM uploads WHERE job_id = ? AND completed = 0`, jobID, jobID)
	if err != nil {
		return nil, fmt.Errorf("read names: %w", err)
	}
	defer rows.Close()
	for rows.Next() {
		var name string
		if err := rows.Scan(&name); err != nil {
			return nil, err
		}
		if name != "" {
			used[name] = true
		}
	}
	return used, rows.Err()
}

// JobExists reports whether a job row exists.
func (s *Store) JobExists(ctx context.Context, id string) (bool, error) {
	var n int
	err := s.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM jobs WHERE id = ?`, id).Scan(&n)
	if err != nil {
		return false, err
	}
	return n > 0, nil
}
FERRY_EOF_18

cat > 'internal/db/db_test.go' <<'FERRY_EOF_19'
package db

import (
	"context"
	"path/filepath"
	"testing"
	"time"
)

func TestStoreLifecycle(t *testing.T) {
	dir := t.TempDir()
	store, err := Open(filepath.Join(dir, "ferry.db"), dir)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	ctx := context.Background()

	jobID := "0123456789abcdef0123456789abcdef"
	job, err := store.CreateJob(ctx, jobID)
	if err != nil {
		t.Fatal(err)
	}
	if job.State != StateDraft {
		t.Fatalf("state = %q", job.State)
	}

	upload := &Upload{ID: "aaaabbbbccccddddeeeeffff00001111", JobID: jobID, Filename: "file.bin", DeclaredSize: 5}
	if err := store.CreateUpload(ctx, upload); err != nil {
		t.Fatal(err)
	}
	total, err := store.DeclaredTotal(ctx, jobID)
	if err != nil {
		t.Fatal(err)
	}
	if total != 5 {
		t.Fatalf("declared total = %d, want 5", total)
	}
	if err := store.SetUploadReceived(ctx, jobID, upload.ID, 5); err != nil {
		t.Fatal(err)
	}
	file := &File{Name: "file.bin", Size: 5, SHA256: "abc", Source: "upload", Status: "done"}
	if err := store.CompleteUpload(ctx, jobID, upload.ID, file); err != nil {
		t.Fatal(err)
	}
	total, err = store.DeclaredTotal(ctx, jobID)
	if err != nil {
		t.Fatal(err)
	}
	if total != 5 {
		t.Fatalf("declared total after completion = %d, want 5", total)
	}
	used, err := store.UsedNames(ctx, jobID)
	if err != nil {
		t.Fatal(err)
	}
	if !used["file.bin"] || !used["SHA256SUMS"] {
		t.Fatalf("reserved names missing: %#v", used)
	}
	files, err := store.ListDoneFiles(ctx, jobID)
	if err != nil {
		t.Fatal(err)
	}
	if len(files) != 1 || files[0].Name != "file.bin" {
		t.Fatalf("finished files = %#v", files)
	}

	urlFile, err := store.AddURLFile(ctx, jobID, "https://example.com/file")
	if err != nil {
		t.Fatal(err)
	}
	pending, err := store.ListPendingURLs(ctx, jobID)
	if err != nil {
		t.Fatal(err)
	}
	if len(pending) != 1 {
		t.Fatalf("pending URLs = %d", len(pending))
	}
	if err := store.MarkURLDone(ctx, jobID, urlFile.ID, "file", 4, "def", "abc123"); err != nil {
		t.Fatal(err)
	}
	total, count, err := store.RecalcTotals(ctx, jobID)
	if err != nil {
		t.Fatal(err)
	}
	if total != 9 || count != 2 {
		t.Fatalf("totals = %d/%d, want 9/2", total, count)
	}
	if err := store.Complete(ctx, jobID, "user/ferry:job-1", total, count); err != nil {
		t.Fatal(err)
	}
	old, err := store.ListDoneBefore(ctx, time.Now().Add(time.Hour))
	if err != nil {
		t.Fatal(err)
	}
	if len(old) != 1 {
		t.Fatalf("done-before list = %d", len(old))
	}
	if err := store.SetImageDeleted(ctx, jobID); err != nil {
		t.Fatal(err)
	}
}

func TestDeleteStaleDraft(t *testing.T) {
	dir := t.TempDir()
	store, err := Open(filepath.Join(dir, "ferry.db"), dir)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	ctx := context.Background()
	id := "fedcba9876543210fedcba9876543210"
	if _, err := store.CreateJob(ctx, id); err != nil {
		t.Fatal(err)
	}
	ok, err := store.DeleteStaleDraft(ctx, id, time.Now().Add(time.Minute))
	if err != nil {
		t.Fatal(err)
	}
	if !ok {
		t.Fatal("stale draft was not deleted")
	}
	if _, err := store.GetJob(ctx, id); err != ErrNotFound {
		t.Fatalf("GetJob error = %v, want ErrNotFound", err)
	}
}

func TestJobOptionsAndPassphraseClearing(t *testing.T) {
	dir := t.TempDir()
	store, err := Open(filepath.Join(dir, "ferry.db"), dir)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	ctx := context.Background()
	id := "00112233445566778899aabbccddeeff"
	if _, err := store.CreateJob(ctx, id); err != nil {
		t.Fatal(err)
	}
	if err := store.SetJobOptions(ctx, id, "sealed-value", true); err != nil {
		t.Fatal(err)
	}
	job, err := store.GetJob(ctx, id)
	if err != nil {
		t.Fatal(err)
	}
	if !job.Compress || !job.Encrypted || !job.HasPassphrase || job.PassphraseEnc != "sealed-value" {
		t.Fatalf("job options = %+v", job)
	}
	if _, err := store.Transition(ctx, id, StateDraft, StateQueued, ""); err != nil {
		t.Fatal(err)
	}
	if err := store.SetJobOptions(ctx, id, "other", true); err != ErrNotDraft {
		t.Fatalf("SetJobOptions on queued job = %v, want ErrNotDraft", err)
	}
	if _, err := store.Transition(ctx, id, StateQueued, StateFailed, "cancelled"); err != nil {
		t.Fatal(err)
	}
	job, err = store.GetJob(ctx, id)
	if err != nil {
		t.Fatal(err)
	}
	if job.HasPassphrase || job.PassphraseEnc != "" {
		t.Fatalf("passphrase was not cleared: %+v", job)
	}
	if !job.Encrypted || !job.Compress {
		t.Fatalf("encryption/compression flags were lost: %+v", job)
	}
}
FERRY_EOF_19

cat > 'internal/dockerhub/client.go' <<'FERRY_EOF_20'
// Package dockerhub deletes image tags through the Docker Hub HTTP API.
package dockerhub

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"
)

// These are constants so they are easy to update if the API changes.
const (
	AuthTokenURL    = "https://hub.docker.com/v2/auth/token"
	LoginURL        = "https://hub.docker.com/v2/users/login"
	RepositoriesURL = "https://hub.docker.com/v2/repositories"
)

// Client removes tags from Docker Hub.
type Client struct {
	http     *http.Client
	username string
	token    string
}

// New creates a Docker Hub API client.
func New(username, token string) *Client {
	return &Client{
		http:     &http.Client{Timeout: 30 * time.Second},
		username: username,
		token:    token,
	}
}

type authResponse struct {
	Token       string `json:"token"`
	AccessToken string `json:"access_token"`
}

// DeleteTag removes one tag. A 404 is treated as already deleted, which makes
// retention cleanup idempotent.
func (c *Client) DeleteTag(ctx context.Context, repository, tag string) error {
	if strings.TrimSpace(repository) == "" {
		return errors.New("repository is empty")
	}
	if strings.TrimSpace(tag) == "" {
		return errors.New("tag is empty")
	}
	jwt, err := c.authenticate(ctx)
	if err != nil {
		return err
	}
	endpoint := RepositoriesURL + "/" + escapeRepository(repository) + "/tags/" + url.PathEscape(tag) + "/"
	req, err := http.NewRequestWithContext(ctx, http.MethodDelete, endpoint, nil)
	if err != nil {
		return fmt.Errorf("create tag delete request: %w", err)
	}
	req.Header.Set("Authorization", "Bearer "+jwt)
	req.Header.Set("Accept", "application/json")
	req.Header.Set("User-Agent", "ferry/1.0")
	resp, err := c.http.Do(req)
	if err != nil {
		return fmt.Errorf("delete Docker Hub tag: %w", err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))

	switch {
	case resp.StatusCode == http.StatusNoContent || resp.StatusCode == http.StatusOK:
		return nil
	case resp.StatusCode == http.StatusNotFound:
		return nil
	case resp.StatusCode == http.StatusUnauthorized || resp.StatusCode == http.StatusForbidden:
		return fmt.Errorf("Docker Hub refused the delete (HTTP %d). The access token needs Read, Write and Delete permission for %s",
			resp.StatusCode, repository)
	default:
		return fmt.Errorf("Docker Hub returned HTTP %d while deleting %s:%s: %s",
			resp.StatusCode, repository, tag, compactBody(body))
	}
}

func (c *Client) authenticate(ctx context.Context) (string, error) {
	payload, err := json.Marshal(map[string]string{
		"identifier": c.username,
		"secret":     c.token,
	})
	if err != nil {
		return "", err
	}
	jwt, err1 := c.requestToken(ctx, AuthTokenURL, payload, "authenticate with Docker Hub")
	if err1 == nil {
		return jwt, nil
	}

	loginPayload, err := json.Marshal(map[string]string{
		"username": c.username,
		"password": c.token,
	})
	if err != nil {
		return "", err
	}
	jwt, err2 := c.requestToken(ctx, LoginURL, loginPayload, "log in to Docker Hub")
	if err2 == nil {
		return jwt, nil
	}
	return "", fmt.Errorf("%v; fallback login also failed: %v", err1, err2)
}

func (c *Client) requestToken(ctx context.Context, endpoint string, payload []byte, action string) (string, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, bytes.NewReader(payload))
	if err != nil {
		return "", fmt.Errorf("%s: %w", action, err)
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "application/json")
	req.Header.Set("User-Agent", "ferry/1.0")
	resp, err := c.http.Do(req)
	if err != nil {
		return "", fmt.Errorf("%s: %w", action, err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 64*1024))
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		if resp.StatusCode == http.StatusUnauthorized || resp.StatusCode == http.StatusForbidden {
			return "", fmt.Errorf("%s: Docker Hub rejected the credentials (HTTP %d). Check DOCKERHUB_USERNAME and use a token with Read, Write and Delete permission",
				action, resp.StatusCode)
		}
		return "", fmt.Errorf("%s: HTTP %d: %s", action, resp.StatusCode, compactBody(body))
	}
	var ar authResponse
	if err := json.Unmarshal(body, &ar); err != nil {
		return "", fmt.Errorf("%s: invalid Docker Hub response: %w", action, err)
	}
	token := ar.Token
	if token == "" {
		token = ar.AccessToken
	}
	if token == "" {
		return "", fmt.Errorf("%s: Docker Hub response did not contain a token", action)
	}
	return token, nil
}

func escapeRepository(repository string) string {
	parts := strings.Split(repository, "/")
	for i := range parts {
		parts[i] = url.PathEscape(parts[i])
	}
	return strings.Join(parts, "/")
}

func compactBody(body []byte) string {
	s := strings.TrimSpace(string(body))
	s = strings.ReplaceAll(s, "\n", " ")
	if len(s) > 300 {
		s = s[:300] + "..."
	}
	if s == "" {
		return "(empty response)"
	}
	return s
}

// SplitImage splits "user/repo:tag" into its repository and tag.
func SplitImage(image string) (repository, tag string, err error) {
	image = strings.TrimSpace(image)
	if image == "" {
		return "", "", errors.New("image name is empty")
	}
	lastSlash := strings.LastIndex(image, "/")
	lastColon := strings.LastIndex(image, ":")
	if lastColon <= lastSlash {
		return "", "", fmt.Errorf("image name %q has no tag", image)
	}
	repository = image[:lastColon]
	tag = image[lastColon+1:]
	if repository == "" || tag == "" || strings.Contains(tag, "/") {
		return "", "", fmt.Errorf("image name %q is invalid", image)
	}
	return repository, tag, nil
}
FERRY_EOF_20

cat > 'internal/downloader/downloader.go' <<'FERRY_EOF_21'
package downloader

import (
	"context"
	"crypto/md5"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"math"
	"mime"
	"net"
	"net/http"
	"net/url"
	"os"
	"path"
	"strings"
	"sync/atomic"
	"syscall"
	"time"

	"ferry/internal/safename"
)

const (
	dialTimeout           = 15 * time.Second
	tlsHandshakeTimeout   = 15 * time.Second
	responseHeaderTimeout = 30 * time.Second
	stallTimeout          = 60 * time.Second
	maxRedirects          = 5
	maxHeaderBytes        = 1 << 20
)

// ErrTooLarge means the download exceeded the remaining job quota.
var ErrTooLarge = errors.New("download exceeds the remaining job size limit")

// ErrStalled means no bytes arrived for 60 seconds.
var ErrStalled = errors.New("download stalled: no data received for 60 seconds")

// Result describes a completed download.
type Result struct {
	Filename string
	Size     int64
	SHA256   string
	MD5      string
}

// Client is an SSRF-safe streaming HTTP downloader.
type Client struct {
	http *http.Client
}

// New creates a downloader that does not use environment proxies and checks
// the actual connected IP on every request and redirect.
func New() *Client {
	dialer := &net.Dialer{
		Timeout:   dialTimeout,
		KeepAlive: 30 * time.Second,
		Control: func(network, address string, _ syscall.RawConn) error {
			host, _, err := net.SplitHostPort(address)
			if err != nil {
				return fmt.Errorf("blocked address: cannot parse %q", address)
			}
			ip := net.ParseIP(host)
			if ip == nil {
				return fmt.Errorf("blocked address: cannot parse IP %q", host)
			}
			if IsBlockedIP(ip) {
				return fmt.Errorf("%w (connected address %s)", ErrBlockedAddress, ip.String())
			}
			return nil
		},
	}
	transport := &http.Transport{
		Proxy:                  nil, // never honor HTTP_PROXY / HTTPS_PROXY
		DialContext:            dialer.DialContext,
		TLSHandshakeTimeout:    tlsHandshakeTimeout,
		ResponseHeaderTimeout:  responseHeaderTimeout,
		MaxResponseHeaderBytes: maxHeaderBytes,
		ForceAttemptHTTP2:      true,
		MaxIdleConns:           10,
		IdleConnTimeout:        90 * time.Second,
	}
	client := &http.Client{
		Transport: transport,
		CheckRedirect: func(req *http.Request, via []*http.Request) error {
			if len(via) > maxRedirects {
				return fmt.Errorf("too many redirects (maximum %d)", maxRedirects)
			}
			if req.URL.Scheme != "http" && req.URL.Scheme != "https" {
				return errors.New("redirect to a non-http(s) URL is not allowed")
			}
			if req.URL.User != nil {
				return errors.New("redirect to a URL with credentials is not allowed")
			}
			// The transport dialer validates the resolved IP for this hop.
			return nil
		},
	}
	return &Client{http: client}
}

// Download streams rawURL into destPath. destPath must not exist. The caller
// must remove the destination on error. maxBytes is the remaining total quota.
func (c *Client) Download(ctx context.Context, rawURL, destPath string, maxBytes int64,
	progress func(done, total int64)) (Result, error) {

	u, err := ValidateURL(rawURL)
	if err != nil {
		return Result{}, err
	}
	if maxBytes < 0 {
		return Result{}, ErrTooLarge
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u.String(), nil)
	if err != nil {
		return Result{}, fmt.Errorf("create request: %w", err)
	}
	req.Header.Set("User-Agent", "Ferry/1.0 (self-hosted transfer agent)")
	req.Header.Set("Accept", "*/*")

	resp, err := c.http.Do(req)
	if err != nil {
		return Result{}, friendlyHTTPError(err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return Result{}, fmt.Errorf("server returned HTTP %d %s (only a plain 200 response is accepted)",
			resp.StatusCode, http.StatusText(resp.StatusCode))
	}
	if resp.ContentLength > maxBytes {
		return Result{}, fmt.Errorf("%w: server reports %d bytes but only %d bytes remain",
			ErrTooLarge, resp.ContentLength, maxBytes)
	}
	filename := suggestedFilename(resp, u)

	f, err := os.OpenFile(destPath, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
	if err != nil {
		return Result{}, fmt.Errorf("create download file: %w", err)
	}
	ok := false
	defer func() {
		_ = f.Close()
		if !ok {
			_ = os.Remove(destPath)
		}
	}()

	stall := newStallBody(resp.Body, stallTimeout)
	defer stall.Close()
	hasher := sha256.New()
	md5Hasher := md5.New()
	writer := io.MultiWriter(f, hasher, md5Hasher)
	if progress != nil {
		writer = io.MultiWriter(f, hasher, md5Hasher, &progressWriter{
			onWrite: progress,
			total:   resp.ContentLength,
		})
	}
	limit := maxBytes
	if limit < math.MaxInt64 {
		limit++ // one extra byte lets us detect a too-large body
	}
	copied, err := io.CopyBuffer(writer, io.LimitReader(stall, limit), make([]byte, 256*1024))
	if err != nil {
		if stall.TimedOut() {
			return Result{}, ErrStalled
		}
		return Result{}, friendlyHTTPError(err)
	}
	// Stop the stall timer before fsync; a slow disk must not look like a
	// stalled network connection.
	stall.Stop()
	if copied > maxBytes {
		return Result{}, fmt.Errorf("%w: limit is %d bytes", ErrTooLarge, maxBytes)
	}
	if resp.ContentLength >= 0 && copied != resp.ContentLength {
		return Result{}, fmt.Errorf("download ended early: received %d of %d bytes", copied, resp.ContentLength)
	}
	if err := f.Sync(); err != nil {
		return Result{}, fmt.Errorf("flush download: %w", err)
	}
	if err := f.Close(); err != nil {
		return Result{}, fmt.Errorf("close download: %w", err)
	}
	ok = true
	return Result{
		Filename: filename,
		Size:     copied,
		SHA256:   hex.EncodeToString(hasher.Sum(nil)),
		MD5:      hex.EncodeToString(md5Hasher.Sum(nil)),
	}, nil
}

func friendlyHTTPError(err error) error {
	if errors.Is(err, ErrBlockedAddress) {
		return fmt.Errorf("%w: Ferry refuses loopback, private, link-local, CGNAT and reserved addresses", ErrBlockedAddress)
	}
	if errors.Is(err, context.Canceled) {
		return errors.New("download cancelled")
	}
	if errors.Is(err, context.DeadlineExceeded) {
		return errors.New("download timed out while connecting")
	}
	var netErr net.Error
	if errors.As(err, &netErr) && netErr.Timeout() {
		return fmt.Errorf("network timeout: %w", err)
	}
	return err
}

func suggestedFilename(resp *http.Response, u *url.URL) string {
	candidate := ""
	if cd := resp.Header.Get("Content-Disposition"); cd != "" {
		if _, params, err := mime.ParseMediaType(cd); err == nil {
			candidate = params["filename"]
		}
	}
	if candidate == "" {
		candidate = path.Base(strings.TrimSuffix(u.Path, "/"))
	}
	name := safename.Sanitize(candidate)
	if name == "" {
		name = "download"
	}
	return name
}

type progressWriter struct {
	onWrite func(done, total int64)
	total   int64
	done    int64
}

func (p *progressWriter) Write(b []byte) (int, error) {
	n, err := len(b), error(nil)
	p.done += int64(n)
	p.onWrite(p.done, p.total)
	return n, err
}

type stallBody struct {
	body     io.ReadCloser
	timer    *time.Timer
	timedOut atomic.Bool
}

func newStallBody(body io.ReadCloser, timeout time.Duration) *stallBody {
	s := &stallBody{body: body}
	s.timer = time.AfterFunc(timeout, func() {
		s.timedOut.Store(true)
		_ = s.body.Close()
	})
	return s
}

func (s *stallBody) Read(p []byte) (int, error) {
	n, err := s.body.Read(p)
	if n > 0 {
		s.timer.Reset(stallTimeout)
	}
	if s.timedOut.Load() {
		return n, ErrStalled
	}
	return n, err
}

func (s *stallBody) Close() error {
	s.timer.Stop()
	return s.body.Close()
}

func (s *stallBody) Stop() { s.timer.Stop() }

func (s *stallBody) TimedOut() bool { return s.timedOut.Load() }
FERRY_EOF_21

cat > 'internal/downloader/downloader_test.go' <<'FERRY_EOF_22'
package downloader

import (
	"net"
	"testing"
)

func TestIsBlockedIP(t *testing.T) {
	tests := []struct {
		ip      string
		blocked bool
	}{
		{"127.0.0.1", true},
		{"127.10.20.30", true},
		{"10.1.2.3", true},
		{"172.16.0.1", true},
		{"172.31.255.255", true},
		{"192.168.1.1", true},
		{"169.254.169.254", true},
		{"100.64.0.1", true},
		{"100.127.255.254", true},
		{"0.0.0.0", true},
		{"224.0.0.1", true},
		{"240.0.0.1", true},
		{"255.255.255.255", true},
		{"192.0.2.1", true},
		{"198.51.100.7", true},
		{"203.0.113.9", true},
		{"::1", true},
		{"::", true},
		{"fc00::1", true},
		{"fd12:3456::1", true},
		{"fe80::1", true},
		{"ff02::1", true},
		{"2001:db8::1", true},
		{"2001::1", true},
		{"2002:c0a8:0101::1", true},
		{"64:ff9b::c0a8:101", true},
		{"::ffff:127.0.0.1", true},
		{"::ffff:192.168.0.1", true},
		{"1.1.1.1", false},
		{"8.8.8.8", false},
		{"93.184.216.34", false},
		{"2606:4700:4700::1111", false},
		{"::ffff:8.8.8.8", false},
	}
	for _, tc := range tests {
		ip := net.ParseIP(tc.ip)
		if ip == nil {
			t.Fatalf("test IP %q did not parse", tc.ip)
		}
		if got := IsBlockedIP(ip); got != tc.blocked {
			t.Errorf("IsBlockedIP(%s) = %v, want %v", tc.ip, got, tc.blocked)
		}
	}
}

func TestValidateURL(t *testing.T) {
	good := []string{
		"http://example.com/file.zip",
		"https://example.com/a/b?x=1",
		"HTTPS://example.com/file",
	}
	for _, raw := range good {
		if _, err := ValidateURL(raw); err != nil {
			t.Errorf("ValidateURL(%q) error: %v", raw, err)
		}
	}
	bad := []string{
		"ftp://example.com/file",
		"file:///etc/passwd",
		"javascript:alert(1)",
		"http://user:pass@example.com/file",
		"http:///missing-host",
		"",
	}
	for _, raw := range bad {
		if _, err := ValidateURL(raw); err == nil {
			t.Errorf("ValidateURL(%q) unexpectedly succeeded", raw)
		}
	}
}
FERRY_EOF_22

cat > 'internal/downloader/ssrf.go' <<'FERRY_EOF_23'
package downloader

import (
	"errors"
	"fmt"
	"net"
	"net/netip"
	"net/url"
	"strings"
)

// ErrBlockedAddress is returned when a download would connect to a private,
// loopback, link-local, multicast or otherwise reserved address.
var ErrBlockedAddress = errors.New("blocked address: Ferry only downloads from public internet addresses")

var blockedV4 = mustPrefixes(
	"0.0.0.0/8",
	"10.0.0.0/8",
	"100.64.0.0/10",
	"127.0.0.0/8",
	"169.254.0.0/16",
	"172.16.0.0/12",
	"192.0.0.0/24",
	"192.0.2.0/24",
	"192.88.99.0/24",
	"192.168.0.0/16",
	"198.18.0.0/15",
	"198.51.100.0/24",
	"203.0.113.0/24",
	"224.0.0.0/4",
	"240.0.0.0/4",
)

var blockedV6 = mustPrefixes(
	"::/128",
	"::1/128",
	"::ffff:0:0/96",
	"64:ff9b::/96",
	"64:ff9b:1::/48",
	"100::/64",
	"2001::/32",
	"2001:2::/48",
	"2001:10::/28",
	"2001:20::/28",
	"2001:db8::/32",
	"2002::/16",
	"3fff::/20",
	"5f00::/16",
	"fc00::/7",
	"fe80::/10",
	"fec0::/10",
	"ff00::/8",
)

func mustPrefixes(values ...string) []netip.Prefix {
	out := make([]netip.Prefix, 0, len(values))
	for _, v := range values {
		out = append(out, netip.MustParsePrefix(v))
	}
	return out
}

// IsBlockedIP reports whether an IP must not be dialed by the URL downloader.
func IsBlockedIP(ip net.IP) bool {
	if ip == nil {
		return true
	}
	addr, ok := netip.AddrFromSlice(ip)
	if !ok {
		return true
	}
	// Treat IPv4-mapped IPv6 exactly as the IPv4 address it contains.
	addr = addr.Unmap()
	if !addr.IsValid() || addr.IsUnspecified() || addr.IsLoopback() ||
		addr.IsPrivate() || addr.IsLinkLocalUnicast() || addr.IsLinkLocalMulticast() ||
		addr.IsMulticast() {
		return true
	}
	prefixes := blockedV6
	if addr.Is4() {
		prefixes = blockedV4
	}
	for _, p := range prefixes {
		if p.Contains(addr) {
			return true
		}
	}
	return false
}

// ValidateURL performs syntax and scheme checks. The actual IP check happens
// in the dialer's Control function, after DNS resolution, on every hop.
func ValidateURL(raw string) (*url.URL, error) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return nil, errors.New("URL is empty")
	}
	if len(raw) > 4096 {
		return nil, errors.New("URL is too long (maximum 4096 characters)")
	}
	for _, r := range raw {
		if r < 0x20 || r == 0x7f {
			return nil, errors.New("URL contains control characters")
		}
	}
	u, err := url.Parse(raw)
	if err != nil {
		return nil, fmt.Errorf("invalid URL: %w", err)
	}
	scheme := strings.ToLower(u.Scheme)
	if scheme != "http" && scheme != "https" {
		return nil, errors.New("only http:// and https:// URLs are allowed")
	}
	if u.Host == "" || u.Hostname() == "" {
		return nil, errors.New("URL is missing a hostname")
	}
	if u.User != nil {
		return nil, errors.New("URLs containing a username or password are not allowed")
	}
	u.Scheme = scheme
	return u, nil
}
FERRY_EOF_23

cat > 'internal/imagebuild/builder.go' <<'FERRY_EOF_24'
// Package imagebuild creates an image layer-by-layer and pushes it to Docker Hub.
package imagebuild

import (
	"context"
	"crypto/rand"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/url"
	"os"
	"runtime"
	"strings"
	"syscall"
	"time"

	"github.com/google/go-containerregistry/pkg/authn"
	"github.com/google/go-containerregistry/pkg/name"
	v1 "github.com/google/go-containerregistry/pkg/v1"
	"github.com/google/go-containerregistry/pkg/v1/mutate"
	"github.com/google/go-containerregistry/pkg/v1/remote"
)

const (
	baseImage       = "busybox:stable"
	maxPushAttempts = 3
	pushBackoff     = 5 * time.Second
)

// Options controls optional compression and passphrase encryption for a job.
type Options struct {
	Compress   bool
	Passphrase string
	// OnTag is called with the final image name just before the push starts.
	// The caller can persist it so a crash mid-push still leaves a record for
	// Docker Hub cleanup.
	OnTag func(string)
}

// Builder packs files onto busybox and pushes the result.
type Builder struct {
	platform v1.Platform
	username string
	token    string
	repo     string
}

// New validates the target platform and Docker Hub settings.
func New(username, token, repo, platform string) (*Builder, error) {
	p, err := v1.ParsePlatform(platform)
	if err != nil {
		return nil, fmt.Errorf("invalid FERRY_PLATFORM %q: %w", platform, err)
	}
	if p.OS == "" || p.Architecture == "" {
		return nil, fmt.Errorf("invalid FERRY_PLATFORM %q", platform)
	}
	if username == "" || token == "" || repo == "" {
		return nil, errors.New("Docker Hub username, token and repository are required")
	}
	return &Builder{
		platform: *p,
		username: username,
		token:    token,
		repo:     repo,
	}, nil
}

// BuildAndPush creates the image and pushes it. phase is called with
// "pushing" immediately before bytes start going to the registry. logf must
// never receive the Docker Hub token.
func (b *Builder) BuildAndPush(
	ctx context.Context,
	files []InputFile,
	opts Options,
	logf func(string),
	phase func(string),
	progress func(v1.Update),
) (string, error) {
	if len(files) == 0 {
		return "", errors.New("no files to pack")
	}
	if (opts.Compress || opts.Passphrase != "") &&
		(runtime.GOOS != "linux" || b.platform.OS != "linux" || b.platform.Architecture != runtime.GOARCH) {
		return "", fmt.Errorf("compression and passphrase encryption require Ferry to run on Linux with FERRY_PLATFORM matching its architecture: FERRY_PLATFORM is %s/%s but this Ferry binary runs on %s/%s. On the Linux server set FERRY_PLATFORM=linux/%s, or disable compression/encryption",
			b.platform.OS, b.platform.Architecture, runtime.GOOS, runtime.GOARCH, runtime.GOARCH)
	}
	if logf == nil {
		logf = func(string) {}
	}
	if phase == nil {
		phase = func(string) {}
	}

	tag, err := newTag(time.Now())
	if err != nil {
		return "", err
	}
	displayName := fmt.Sprintf("%s/%s:%s", strings.ToLower(b.username), b.repo, tag)
	ref, err := name.ParseReference(displayName)
	if err != nil {
		return "", fmt.Errorf("build image reference: %w", err)
	}
	auth := &authn.Basic{Username: b.username, Password: b.token}
	remoteCtx := remote.WithContext(ctx)
	remoteAuth := remote.WithAuth(auth)

	logf(fmt.Sprintf("Pulling base image %s for %s/%s", baseImage, b.platform.OS, b.platform.Architecture))
	baseRef, err := name.ParseReference(baseImage)
	if err != nil {
		return "", fmt.Errorf("parse base image: %w", err)
	}
	base, err := remote.Image(baseRef,
		remoteCtx,
		remoteAuth,
		remote.WithPlatform(b.platform),
		remote.WithUserAgent("ferry/1.0"),
	)
	if err != nil {
		return "", redact(fmt.Errorf("pull %s: %w", baseImage, err), b.token)
	}

	prepared := make([]preparedFile, 0, len(files))
	for _, f := range files {
		if err := ctx.Err(); err != nil {
			return "", errors.New("cancelled")
		}
		p, err := prepareFile(ctx, f)
		if err != nil {
			return "", err
		}
		prepared = append(prepared, p)
		if p.Compress || p.Encrypt {
			extras := make([]string, 0, 2)
			if p.Compress {
				extras = append(extras, "compressed")
			}
			if p.Encrypt {
				extras = append(extras, "encrypted")
			}
			logf(fmt.Sprintf("Prepared %s as %s (%s)", p.Name, p.StoredName, strings.Join(extras, ", ")))
		}
	}

	ensureUniqueStoredNames(prepared)
	layers := make([]v1.Layer, 0, len(prepared)+4)
	for _, f := range prepared {
		if err := ctx.Err(); err != nil {
			return "", errors.New("cancelled")
		}
		layer, err := fileLayer(f)
		if err != nil {
			return "", err
		}
		layers = append(layers, layer)
	}
	logf(fmt.Sprintf("Creating SHA256SUMS and MD5SUMS for %d files", len(prepared)))
	sumLayer, err := sumsLayer(prepared)
	if err != nil {
		return "", err
	}
	layers = append(layers, sumLayer)

	manifest, err := manifestLayer(prepared)
	if err != nil {
		return "", err
	}
	layers = append(layers, manifest)

	if opts.Compress || opts.Passphrase != "" {
		// The destination needs a tool that can decrypt and decompress. Ferry
		// itself is a static binary, so ship a copy plus short instructions.
		exe, err := os.Executable()
		if err != nil {
			return "", fmt.Errorf("locate the ferry binary for the image: %w", err)
		}
		logf("Adding the ferry unpack tool and README to the image")
		toolLayer, err := binaryLayer(ctx, exe, "ferry", 0o755)
		if err != nil {
			return "", err
		}
		layers = append(layers, toolLayer)
		readmeLayer, err := textLayer([]tarEntry{
			{name: "README-FERRY.txt", contents: []byte(unpackReadme(opts)), mode: 0o644},
		})
		if err != nil {
			return "", err
		}
		layers = append(layers, readmeLayer)
	}

	img, err := mutate.AppendLayers(base, layers...)
	if err != nil {
		return "", fmt.Errorf("append layers: %w", err)
	}
	img, err = mutate.Config(img, v1.Config{
		WorkingDir: "/data",
		Cmd:        []string{"sh"},
	})
	if err != nil {
		return "", fmt.Errorf("set image config: %w", err)
	}
	img, err = mutate.CreatedAt(img, v1.Time{Time: time.Now().UTC()})
	if err != nil {
		return "", fmt.Errorf("set image creation time: %w", err)
	}

	if opts.OnTag != nil {
		opts.OnTag(displayName)
	}
	phase("pushing")
	var lastErr error
	for attempt := 1; attempt <= maxPushAttempts; attempt++ {
		if err := ctx.Err(); err != nil {
			return displayName, errors.New("push cancelled")
		}
		logf(fmt.Sprintf("Pushing %s (attempt %d of %d)", displayName, attempt, maxPushAttempts))
		// remote.Write closes the progress channel, so every attempt gets a
		// fresh channel and a drain goroutine that runs until that close.
		updates := make(chan v1.Update, 128)
		progressDone := make(chan struct{})
		go func() {
			defer close(progressDone)
			for u := range updates {
				if progress != nil {
					progress(u)
				}
			}
		}()
		err = remote.Write(ref, img,
			remoteCtx,
			remoteAuth,
			remote.WithJobs(2),
			remote.WithProgress(updates),
			remote.WithUserAgent("ferry/1.0"),
		)
		<-progressDone
		if err == nil {
			lastErr = nil
			break
		}
		lastErr = redact(err, b.token)
		if !isRetryablePushError(err) || attempt == maxPushAttempts {
			break
		}
		logf(fmt.Sprintf("Push attempt %d failed (%v); retrying in %s", attempt, lastErr, pushBackoff))
		timer := time.NewTimer(pushBackoff)
		select {
		case <-ctx.Done():
			timer.Stop()
			return displayName, errors.New("push cancelled")
		case <-timer.C:
		}
	}
	if lastErr != nil {
		return displayName, fmt.Errorf("push image: %w", lastErr)
	}

	logf("Verifying that the pushed tag is visible in Docker Hub")
	digest, err := img.Digest()
	if err != nil {
		return displayName, fmt.Errorf("compute image digest: %w", err)
	}
	var desc *v1.Descriptor
	for attempt := 1; attempt <= 3; attempt++ {
		desc, err = remote.Head(ref, remoteCtx, remoteAuth, remote.WithUserAgent("ferry/1.0"))
		if err == nil {
			break
		}
		if attempt < 3 {
			timer := time.NewTimer(2 * time.Second)
			select {
			case <-ctx.Done():
				timer.Stop()
				return displayName, errors.New("push cancelled")
			case <-timer.C:
			}
		}
	}
	if err != nil {
		return displayName, redact(fmt.Errorf("verify pushed tag: %w", err), b.token)
	}
	if desc == nil {
		return displayName, errors.New("verify pushed tag: Docker Hub returned no descriptor")
	}
	if desc.Digest != digest {
		return displayName, fmt.Errorf("verify pushed tag: Docker Hub digest %s does not match built image %s", desc.Digest, digest)
	}
	logf("Push verified: Docker Hub reports the expected manifest digest")
	return displayName, nil
}

type manifestEntry struct {
	Stored     string `json:"stored"`
	Original   string `json:"original"`
	Compressed bool   `json:"compressed"`
	Encrypted  bool   `json:"encrypted"`
}

// manifestLayer records the original name and transforms of every stored file.
// Without it, a plain file whose name ends in .gz or .ferry would be mistaken
// for a packed file during unpacking.
func manifestLayer(files []preparedFile) (v1.Layer, error) {
	entries := make([]manifestEntry, 0, len(files))
	for _, f := range files {
		entries = append(entries, manifestEntry{
			Stored:     f.StoredName,
			Original:   f.Name,
			Compressed: f.Compress,
			Encrypted:  f.Encrypt,
		})
	}
	contents, err := json.MarshalIndent(entries, "", "  ")
	if err != nil {
		return nil, fmt.Errorf("build image manifest: %w", err)
	}
	contents = append(contents, '\n')
	return textLayer([]tarEntry{
		{name: "FERRY-MANIFEST.json", contents: contents, mode: 0o644},
	})
}

func unpackReadme(opts Options) string {
	var b strings.Builder
	b.WriteString("Ferry image\n")
	b.WriteString("===========\n\n")
	b.WriteString("Some files in this image are stored in a packed form:\n")
	if opts.Compress {
		b.WriteString("  *.gz      gzip-compressed files\n")
	}
	if opts.Passphrase != "" {
		b.WriteString("  *.ferry   files encrypted with the job passphrase\n")
	}
	b.WriteString("\nFERRY-MANIFEST.json records the original name and the transforms\n")
	b.WriteString("for every stored file. Keep it next to the files.\n")
	b.WriteString("\nVerify the stored files:\n")
	b.WriteString("  sha256sum -c SHA256SUMS\n")
	b.WriteString("  md5sum -c MD5SUMS\n")
	b.WriteString("\nUnpack everything inside the image (asks for the passphrase when needed):\n")
	b.WriteString("  ./ferry unpack\n")
	b.WriteString("\nFrom the host, run the tool inside the image so the architecture matches:\n")
	b.WriteString("  docker run --rm -it -v \"$PWD:/work\" --entrypoint /data/ferry <image> unpack --dir /work\n")
	b.WriteString("\nNon-interactive unpack:\n")
	b.WriteString("  ./ferry unpack --passphrase 'your passphrase'\n")
	b.WriteString("\nThe unpack command verifies the checksums, decrypts .ferry files,\n")
	b.WriteString("decompresses .gz files, and writes the original filenames here.\n")
	b.WriteString("Use --verify-only to check the checksums without unpacking.\n")
	return b.String()
}

func newTag(now time.Time) (string, error) {
	b := make([]byte, 2)
	if _, err := rand.Read(b); err != nil {
		return "", fmt.Errorf("generate tag: %w", err)
	}
	return fmt.Sprintf("job-%s-%x", now.UTC().Format("20060102-150405"), b), nil
}

func isRetryablePushError(err error) bool {
	if err == nil {
		return false
	}
	if errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) {
		return false
	}
	var netErr net.Error
	if errors.As(err, &netErr) {
		return true
	}
	var urlErr *url.Error
	if errors.As(err, &urlErr) {
		return true
	}
	var opErr *net.OpError
	if errors.As(err, &opErr) {
		return true
	}
	if errors.Is(err, io.EOF) || errors.Is(err, io.ErrUnexpectedEOF) ||
		errors.Is(err, syscall.ECONNRESET) || errors.Is(err, syscall.ECONNREFUSED) ||
		errors.Is(err, syscall.ETIMEDOUT) {
		return true
	}
	msg := strings.ToLower(err.Error())
	for _, marker := range []string{
		"connection reset", "connection refused", "broken pipe", "timeout",
		"tls handshake", "unexpected eof", "temporary failure", "http 502", "http 503", "http 504",
	} {
		if strings.Contains(msg, marker) {
			return true
		}
	}
	return false
}

func redact(err error, secret string) error {
	if err == nil {
		return nil
	}
	msg := err.Error()
	if secret != "" {
		msg = strings.ReplaceAll(msg, secret, "[redacted]")
	}
	return errors.New(msg)
}
FERRY_EOF_24

cat > 'internal/imagebuild/layer.go' <<'FERRY_EOF_25'
package imagebuild

import (
	"archive/tar"
	"compress/gzip"
	"context"
	"crypto/md5"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"os"
	"strings"
	"time"

	v1 "github.com/google/go-containerregistry/pkg/v1"
	"github.com/google/go-containerregistry/pkg/v1/tarball"

	"ferry/internal/safename"
	"ferry/internal/securefile"
)

var fixedModTime = time.Date(2020, 1, 1, 0, 0, 0, 0, time.UTC)

// InputFile is one file to pack into the image.
type InputFile struct {
	Name       string
	Path       string
	Size       int64
	SHA256     string
	MD5        string
	Compress   bool
	Encrypt    bool
	Passphrase string
	Mode       int64
}

// preparedFile describes the bytes as they will be stored in the image after
// optional gzip compression and passphrase encryption.
type preparedFile struct {
	InputFile
	StoredName   string
	StoredSize   int64
	StoredSHA256 string
	StoredMD5    string
	PlainSize    int64
	Compress     bool
	Encrypt      bool
	Salt         []byte
	ctx          context.Context
}

func prepareFile(ctx context.Context, f InputFile) (preparedFile, error) {
	if err := ctx.Err(); err != nil {
		return preparedFile{}, err
	}
	name := safename.Sanitize(f.Name)
	if name == "" || name != f.Name || strings.ContainsAny(name, "/\\") {
		return preparedFile{}, fmt.Errorf("unsafe filename %q", f.Name)
	}
	if f.Size < 0 {
		return preparedFile{}, fmt.Errorf("invalid size for %q", f.Name)
	}
	if safename.Reserved(name) {
		return preparedFile{}, fmt.Errorf("filename %q is reserved by Ferry; rename the file", f.Name)
	}
	p := preparedFile{InputFile: f, PlainSize: f.Size, Encrypt: f.Encrypt, ctx: ctx}
	if p.Encrypt && f.Passphrase == "" {
		return preparedFile{}, fmt.Errorf("file %q needs a passphrase but none was provided", name)
	}

	if f.Compress {
		gzSize, err := gzippedSize(ctx, f.Path)
		if err != nil {
			return preparedFile{}, fmt.Errorf("measure compressed size of %q: %w", name, err)
		}
		// Only keep the compressed form when it is actually smaller.
		if gzSize < f.Size {
			p.Compress = true
			p.PlainSize = gzSize
		}
	}

	if p.Encrypt {
		salt, err := securefile.NewSalt()
		if err != nil {
			return preparedFile{}, err
		}
		p.Salt = salt
		p.StoredSize = securefile.EncryptedSize(p.PlainSize)
	} else {
		p.StoredSize = p.PlainSize
	}

	p.StoredName = name
	if p.Compress {
		p.StoredName += ".gz"
	}
	if p.Encrypt {
		p.StoredName += securefile.Suffix
	}

	if err := ctx.Err(); err != nil {
		return preparedFile{}, err
	}
	switch {
	case p.Encrypt || p.Compress:
		sum, md5sum, err := hashStored(p)
		if err != nil {
			return preparedFile{}, fmt.Errorf("hash stored form of %q: %w", name, err)
		}
		p.StoredSHA256 = sum
		p.StoredMD5 = md5sum
	case f.SHA256 != "" && f.MD5 != "":
		p.StoredSHA256 = f.SHA256
		p.StoredMD5 = f.MD5
	default:
		sum, md5sum, err := hashFile(f.Path)
		if err != nil {
			return preparedFile{}, fmt.Errorf("hash %q: %w", name, err)
		}
		p.StoredSHA256 = sum
		p.StoredMD5 = md5sum
	}
	return p, nil
}

// openStored returns the exact bytes that will be placed in the image. The
// gzip and encryption stages run in goroutines connected by pipes, so a
// multi-gigabyte file is never held in memory or copied to a second file.
func openStored(p preparedFile) (io.ReadCloser, error) {
	ctx := p.ctx
	if ctx == nil {
		ctx = context.Background()
	}
	if !p.Compress && !p.Encrypt {
		f, err := os.Open(p.Path)
		if err != nil {
			return nil, err
		}
		return &contextReadCloser{ctx: ctx, file: f}, nil
	}
	file, err := os.Open(p.Path)
	if err != nil {
		return nil, err
	}
	var src io.Reader = file
	var pipes []*io.PipeReader

	if p.Compress {
		pr, pw := io.Pipe()
		pipes = append(pipes, pr)
		go func() {
			zw, err := gzip.NewWriterLevel(pw, gzip.DefaultCompression)
			if err != nil {
				_ = file.Close()
				_ = pw.CloseWithError(err)
				return
			}
			zw.ModTime = fixedModTime
			zw.OS = 255
			_, copyErr := io.Copy(zw, file)
			closeErr := zw.Close()
			_ = file.Close()
			if copyErr != nil {
				_ = pw.CloseWithError(copyErr)
				return
			}
			_ = pw.CloseWithError(closeErr)
		}()
		src = pr
	}

	if p.Encrypt {
		pr, pw := io.Pipe()
		pipes = append(pipes, pr)
		inner := src
		go func() {
			err := securefile.Encrypt(pw, inner, p.Passphrase, p.Salt, p.PlainSize)
			if c, ok := inner.(io.Closer); ok {
				_ = c.Close()
			}
			_ = pw.CloseWithError(err)
		}()
		src = pr
	}

	return &pipelineReader{
		Reader: &contextReader{ctx: ctx, reader: src},
		pipes:  pipes,
		file:   file,
	}, nil
}

// contextReader aborts a long preparation or layer read when the job is
// cancelled or the server shuts down.
type contextReader struct {
	ctx    context.Context
	reader io.Reader
}

func (c *contextReader) Read(b []byte) (int, error) {
	if err := c.ctx.Err(); err != nil {
		return 0, err
	}
	return c.reader.Read(b)
}

type contextReadCloser struct {
	ctx  context.Context
	file *os.File
}

func (c *contextReadCloser) Read(b []byte) (int, error) {
	if err := c.ctx.Err(); err != nil {
		return 0, err
	}
	return c.file.Read(b)
}

func (c *contextReadCloser) Close() error { return c.file.Close() }

type pipelineReader struct {
	io.Reader
	pipes []*io.PipeReader
	file  *os.File
}

func (p *pipelineReader) Close() error {
	for _, pr := range p.pipes {
		_ = pr.Close()
	}
	if p.file != nil {
		_ = p.file.Close()
	}
	return nil
}

func fileLayer(p preparedFile) (v1.Layer, error) {
	mode := p.Mode
	if mode == 0 {
		mode = 0o644
	}
	path := p.Path
	name := p.StoredName
	size := p.StoredSize
	return tarball.LayerFromOpener(
		func() (io.ReadCloser, error) {
			rc, err := openStored(p)
			if err != nil {
				return nil, fmt.Errorf("open %q for image layer: %w", path, err)
			}
			pr, pw := io.Pipe()
			go func() {
				defer rc.Close()
				err := writeStreamTar(pw, name, mode, size, rc)
				_ = pw.CloseWithError(err)
			}()
			return pr, nil
		},
		tarball.WithCompressionLevel(gzip.BestSpeed),
	)
}

func writeStreamTar(w io.Writer, name string, mode int64, size int64, body io.Reader) error {
	tw := tar.NewWriter(w)
	if err := writeDataDir(tw); err != nil {
		return err
	}
	hdr := &tar.Header{
		Name:     "data/" + name,
		Typeflag: tar.TypeReg,
		Mode:     mode,
		Uid:      0,
		Gid:      0,
		Size:     size,
		ModTime:  fixedModTime,
		Format:   tar.FormatPAX,
	}
	if err := tw.WriteHeader(hdr); err != nil {
		return fmt.Errorf("write tar header for %q: %w", name, err)
	}
	written, err := io.Copy(tw, body)
	if err != nil {
		return fmt.Errorf("copy %q into layer: %w", name, err)
	}
	if written != size {
		return fmt.Errorf("file %q changed size while building (expected %d, read %d)", name, size, written)
	}
	if err := tw.Close(); err != nil {
		return fmt.Errorf("close tar for %q: %w", name, err)
	}
	return nil
}

func writeDataDir(tw *tar.Writer) error {
	return tw.WriteHeader(&tar.Header{
		Name:     "data/",
		Typeflag: tar.TypeDir,
		Mode:     0o755,
		Uid:      0,
		Gid:      0,
		ModTime:  fixedModTime,
		Format:   tar.FormatPAX,
	})
}

// sumsLayer writes SHA256SUMS and MD5SUMS for the stored bytes. The hashes were
// computed while preparing each file, so no extra full read is needed here.
func sumsLayer(files []preparedFile) (v1.Layer, error) {
	var shaBuilder, md5Builder strings.Builder
	for _, f := range files {
		if f.StoredSHA256 == "" || f.StoredMD5 == "" {
			return nil, fmt.Errorf("missing checksum for %q", f.StoredName)
		}
		shaBuilder.WriteString(f.StoredSHA256)
		shaBuilder.WriteString("  ")
		shaBuilder.WriteString(f.StoredName)
		shaBuilder.WriteByte('\n')
		md5Builder.WriteString(f.StoredMD5)
		md5Builder.WriteString("  ")
		md5Builder.WriteString(f.StoredName)
		md5Builder.WriteByte('\n')
	}
	entries := []tarEntry{
		{name: "SHA256SUMS", contents: []byte(shaBuilder.String()), mode: 0o644},
		{name: "MD5SUMS", contents: []byte(md5Builder.String()), mode: 0o644},
	}
	return textLayer(entries)
}

type tarEntry struct {
	name     string
	contents []byte
	mode     int64
}

func textLayer(entries []tarEntry) (v1.Layer, error) {
	return tarball.LayerFromOpener(
		func() (io.ReadCloser, error) {
			pr, pw := io.Pipe()
			go func() {
				_ = pw.CloseWithError(writeEntriesTar(pw, entries))
			}()
			return pr, nil
		},
		tarball.WithCompressionLevel(gzip.BestSpeed),
	)
}

func binaryLayer(ctx context.Context, path, name string, mode int64) (v1.Layer, error) {
	st, err := os.Stat(path)
	if err != nil {
		return nil, fmt.Errorf("read %s: %w", path, err)
	}
	if !st.Mode().IsRegular() {
		return nil, fmt.Errorf("%s is not a regular file", path)
	}
	size := st.Size()
	return tarball.LayerFromOpener(
		func() (io.ReadCloser, error) {
			f, err := os.Open(path)
			if err != nil {
				return nil, err
			}
			pr, pw := io.Pipe()
			go func() {
				defer f.Close()
				_ = pw.CloseWithError(writeStreamTar(pw, name, mode, size, &contextReader{ctx: ctx, reader: f}))
			}()
			return pr, nil
		},
		tarball.WithCompressionLevel(gzip.BestSpeed),
	)
}

func writeEntriesTar(w io.Writer, entries []tarEntry) error {
	tw := tar.NewWriter(w)
	if err := writeDataDir(tw); err != nil {
		return err
	}
	for _, entry := range entries {
		mode := entry.mode
		if mode == 0 {
			mode = 0o644
		}
		if err := tw.WriteHeader(&tar.Header{
			Name:     "data/" + entry.name,
			Typeflag: tar.TypeReg,
			Mode:     mode,
			Uid:      0,
			Gid:      0,
			Size:     int64(len(entry.contents)),
			ModTime:  fixedModTime,
			Format:   tar.FormatPAX,
		}); err != nil {
			return err
		}
		if _, err := tw.Write(entry.contents); err != nil {
			return err
		}
	}
	return tw.Close()
}

func hashStored(p preparedFile) (string, string, error) {
	rc, err := openStored(p)
	if err != nil {
		return "", "", err
	}
	defer rc.Close()
	sha := sha256.New()
	md := md5.New()
	if _, err := io.Copy(io.MultiWriter(sha, md), rc); err != nil {
		return "", "", err
	}
	return hex.EncodeToString(sha.Sum(nil)), hex.EncodeToString(md.Sum(nil)), nil
}

func hashFile(path string) (string, string, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", "", err
	}
	defer f.Close()
	sha := sha256.New()
	md := md5.New()
	if _, err := io.Copy(io.MultiWriter(sha, md), f); err != nil {
		return "", "", err
	}
	return hex.EncodeToString(sha.Sum(nil)), hex.EncodeToString(md.Sum(nil)), nil
}

type countWriter struct{ n int64 }

func (c *countWriter) Write(b []byte) (int, error) {
	c.n += int64(len(b))
	return len(b), nil
}

func gzippedSize(ctx context.Context, path string) (int64, error) {
	f, err := os.Open(path)
	if err != nil {
		return 0, err
	}
	defer f.Close()
	cw := &countWriter{}
	zw, err := gzip.NewWriterLevel(cw, gzip.DefaultCompression)
	if err != nil {
		return 0, err
	}
	zw.ModTime = fixedModTime
	zw.OS = 255
	if _, err := io.Copy(zw, &contextReader{ctx: ctx, reader: f}); err != nil {
		return 0, err
	}
	if err := zw.Close(); err != nil {
		return 0, err
	}
	return cw.n, nil
}

// reservedStoredNames are written by Ferry itself and must not be used by a
// user file, even if the file was uploaded before these names were reserved.
var reservedStoredNames = map[string]bool{
	"ferry": true, "SHA256SUMS": true, "MD5SUMS": true,
	"FERRY-MANIFEST.json": true, "README-FERRY.txt": true,
}

// ensureUniqueStoredNames prevents two inputs from mapping to the same path in
// the image (for example "a" compressed to "a.gz" and a plain file "a.gz").
func ensureUniqueStoredNames(files []preparedFile) {
	used := make(map[string]bool, len(reservedStoredNames)+len(files))
	for name := range reservedStoredNames {
		used[name] = true
	}
	for i := range files {
		name := files[i].StoredName
		if !used[name] {
			used[name] = true
			continue
		}
		files[i].StoredName = uniqueStoredName(name, used)
	}
}

func uniqueStoredName(name string, used map[string]bool) string {
	base := name
	ext := ""
	if strings.HasSuffix(base, securefile.Suffix) {
		base = strings.TrimSuffix(base, securefile.Suffix)
		ext = securefile.Suffix + ext
	}
	if strings.HasSuffix(base, ".gz") {
		base = strings.TrimSuffix(base, ".gz")
		ext = ".gz" + ext
	}
	for i := 1; ; i++ {
		candidate := fmt.Sprintf("%s-%d%s", base, i, ext)
		if !used[candidate] {
			used[candidate] = true
			return candidate
		}
	}
}
FERRY_EOF_25

cat > 'internal/imagebuild/layer_test.go' <<'FERRY_EOF_26'
package imagebuild

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"context"
	"crypto/md5"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"ferry/internal/securefile"
)

func writeTestFile(t *testing.T, dir, name, contents string) (string, string, int64) {
	t.Helper()
	path := filepath.Join(dir, name)
	if err := os.WriteFile(path, []byte(contents), 0o600); err != nil {
		t.Fatal(err)
	}
	sum := sha256.Sum256([]byte(contents))
	return path, hex.EncodeToString(sum[:]), int64(len(contents))
}

func TestFileLayerContents(t *testing.T) {
	dir := t.TempDir()
	path, sum, size := writeTestFile(t, dir, "hello.txt", "hello layer\n")
	prepared, err := prepareFile(context.Background(), InputFile{Name: "hello.txt", Path: path, Size: size, SHA256: sum})
	if err != nil {
		t.Fatal(err)
	}
	layer, err := fileLayer(prepared)
	if err != nil {
		t.Fatal(err)
	}
	rc, err := layer.Uncompressed()
	if err != nil {
		t.Fatal(err)
	}
	defer rc.Close()
	tr := tar.NewReader(rc)

	dirHeader, err := tr.Next()
	if err != nil {
		t.Fatal(err)
	}
	if dirHeader.Name != "data/" || dirHeader.Typeflag != tar.TypeDir || dirHeader.Mode != 0o755 {
		t.Fatalf("bad directory header: %+v", dirHeader)
	}
	if dirHeader.Uid != 0 || dirHeader.Gid != 0 {
		t.Fatalf("directory owner = %d:%d, want 0:0", dirHeader.Uid, dirHeader.Gid)
	}
	if !dirHeader.ModTime.Equal(fixedModTime) {
		t.Fatalf("directory mtime = %v, want %v", dirHeader.ModTime, fixedModTime)
	}

	fileHeader, err := tr.Next()
	if err != nil {
		t.Fatal(err)
	}
	if fileHeader.Name != "data/hello.txt" || fileHeader.Typeflag != tar.TypeReg || fileHeader.Mode != 0o644 {
		t.Fatalf("bad file header: %+v", fileHeader)
	}
	if fileHeader.Uid != 0 || fileHeader.Gid != 0 {
		t.Fatalf("file owner = %d:%d, want 0:0", fileHeader.Uid, fileHeader.Gid)
	}
	if !fileHeader.ModTime.Equal(fixedModTime) {
		t.Fatalf("file mtime = %v, want %v", fileHeader.ModTime, fixedModTime)
	}
	body, err := io.ReadAll(tr)
	if err != nil {
		t.Fatal(err)
	}
	if string(body) != "hello layer\n" {
		t.Fatalf("body = %q", body)
	}
	if _, err := tr.Next(); err != io.EOF {
		t.Fatalf("expected EOF, got %v", err)
	}
}

func TestSumsLayer(t *testing.T) {
	dir := t.TempDir()
	pathA, sumA, sizeA := writeTestFile(t, dir, "a.txt", "alpha")
	pathB, sumB, sizeB := writeTestFile(t, dir, "b.txt", "beta")
	preparedA, err := prepareFile(context.Background(), InputFile{Name: "a.txt", Path: pathA, Size: sizeA, SHA256: sumA})
	if err != nil {
		t.Fatal(err)
	}
	preparedB, err := prepareFile(context.Background(), InputFile{Name: "b.txt", Path: pathB, Size: sizeB, SHA256: sumB})
	if err != nil {
		t.Fatal(err)
	}
	layer, err := sumsLayer([]preparedFile{preparedA, preparedB})
	if err != nil {
		t.Fatal(err)
	}
	rc, err := layer.Uncompressed()
	if err != nil {
		t.Fatal(err)
	}
	defer rc.Close()
	tr := tar.NewReader(rc)
	if _, err := tr.Next(); err != nil { // data/
		t.Fatal(err)
	}
	hdr, err := tr.Next()
	if err != nil {
		t.Fatal(err)
	}
	if hdr.Name != "data/SHA256SUMS" || hdr.Mode != 0o644 {
		t.Fatalf("bad sums header: %+v", hdr)
	}
	body, err := io.ReadAll(tr)
	if err != nil {
		t.Fatal(err)
	}
	want := sumA + "  a.txt\n" + sumB + "  b.txt\n"
	if string(body) != want {
		t.Fatalf("SHA256SUMS = %q, want %q", body, want)
	}

	md5Header, err := tr.Next()
	if err != nil {
		t.Fatal(err)
	}
	if md5Header.Name != "data/MD5SUMS" || md5Header.Mode != 0o644 {
		t.Fatalf("bad MD5SUMS header: %+v", md5Header)
	}
	md5Body, err := io.ReadAll(tr)
	if err != nil {
		t.Fatal(err)
	}
	alpha := md5.Sum([]byte("alpha"))
	beta := md5.Sum([]byte("beta"))
	wantMD5 := hex.EncodeToString(alpha[:]) + "  a.txt\n" + hex.EncodeToString(beta[:]) + "  b.txt\n"
	if string(md5Body) != wantMD5 {
		t.Fatalf("MD5SUMS = %q, want %q", md5Body, wantMD5)
	}
	if _, err := tr.Next(); err != io.EOF {
		t.Fatalf("expected EOF after MD5SUMS, got %v", err)
	}
}

func TestNewTagFormat(t *testing.T) {
	now := time.Date(2026, 11, 24, 15, 30, 12, 0, time.UTC)
	tag, err := newTag(now)
	if err != nil {
		t.Fatal(err)
	}
	if len(tag) != len("job-20261124-153012-")+4 {
		t.Fatalf("tag %q has unexpected length", tag)
	}
	if !strings.HasPrefix(tag, "job-20261124-153012-") {
		t.Fatalf("tag %q does not start with the timestamp", tag)
	}
	if _, err := hex.DecodeString(tag[len("job-20261124-153012-"):]); err != nil {
		t.Fatalf("tag random suffix is not hex: %q", tag)
	}
}

func TestPrepareCompressedFile(t *testing.T) {
	dir := t.TempDir()
	contents := strings.Repeat("compressible data ", 5000)
	path, sum, size := writeTestFile(t, dir, "big.txt", contents)
	p, err := prepareFile(context.Background(), InputFile{Name: "big.txt", Path: path, Size: size, SHA256: sum, Compress: true})
	if err != nil {
		t.Fatal(err)
	}
	if !p.Compress || p.StoredName != "big.txt.gz" {
		t.Fatalf("prepared = %+v", p)
	}
	if p.StoredSize >= size {
		t.Fatalf("compressed size %d is not smaller than %d", p.StoredSize, size)
	}
	rc, err := openStored(p)
	if err != nil {
		t.Fatal(err)
	}
	defer rc.Close()
	gz, err := gzip.NewReader(rc)
	if err != nil {
		t.Fatal(err)
	}
	got, err := io.ReadAll(gz)
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != contents {
		t.Fatal("decompressed contents do not match")
	}
}

func TestPrepareIncompressibleFileStaysPlain(t *testing.T) {
	dir := t.TempDir()
	data := make([]byte, 4096)
	if _, err := rand.Read(data); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(dir, "random.bin")
	if err := os.WriteFile(path, data, 0o600); err != nil {
		t.Fatal(err)
	}
	p, err := prepareFile(context.Background(), InputFile{Name: "random.bin", Path: path, Size: int64(len(data)), Compress: true})
	if err != nil {
		t.Fatal(err)
	}
	if p.Compress || p.StoredName != "random.bin" {
		t.Fatalf("prepared = %+v", p)
	}
}

func TestPrepareEncryptedFile(t *testing.T) {
	dir := t.TempDir()
	path, sum, size := writeTestFile(t, dir, "secret.txt", "top secret contents")
	p, err := prepareFile(context.Background(), InputFile{
		Name: "secret.txt", Path: path, Size: size, SHA256: sum,
		Encrypt: true, Passphrase: "correct horse battery staple",
	})
	if err != nil {
		t.Fatal(err)
	}
	if !p.Encrypt || p.StoredName != "secret.txt.ferry" {
		t.Fatalf("prepared = %+v", p)
	}
	if p.StoredSize != securefile.EncryptedSize(size) {
		t.Fatalf("stored size = %d", p.StoredSize)
	}
	rc, err := openStored(p)
	if err != nil {
		t.Fatal(err)
	}
	defer rc.Close()
	var out bytes.Buffer
	if _, err := securefile.Decrypt(&out, rc, "correct horse battery staple"); err != nil {
		t.Fatal(err)
	}
	if out.String() != "top secret contents" {
		t.Fatalf("decrypted = %q", out.String())
	}
	if p.StoredSHA256 == "" || p.StoredMD5 == "" {
		t.Fatal("stored hashes were not computed")
	}
}

func TestPrepareEncryptedAndCompressed(t *testing.T) {
	dir := t.TempDir()
	contents := strings.Repeat("abc", 10000)
	path, sum, size := writeTestFile(t, dir, "both.txt", contents)
	p, err := prepareFile(context.Background(), InputFile{
		Name: "both.txt", Path: path, Size: size, SHA256: sum,
		Compress: true, Encrypt: true, Passphrase: "long enough passphrase",
	})
	if err != nil {
		t.Fatal(err)
	}
	if !p.Compress || !p.Encrypt || p.StoredName != "both.txt.gz.ferry" {
		t.Fatalf("prepared = %+v", p)
	}
}

func TestStoredNameCollision(t *testing.T) {
	dir := t.TempDir()
	compressible := strings.Repeat("abc", 2000)
	pathA, sumA, sizeA := writeTestFile(t, dir, "a", compressible)
	random := make([]byte, 4096)
	if _, err := rand.Read(random); err != nil {
		t.Fatal(err)
	}
	pathB := filepath.Join(dir, "a.gz")
	if err := os.WriteFile(pathB, random, 0o600); err != nil {
		t.Fatal(err)
	}
	sumB := sha256.Sum256(random)
	sizeB := int64(len(random))
	prepared := make([]preparedFile, 0, 2)
	for _, input := range []InputFile{
		{Name: "a", Path: pathA, Size: sizeA, SHA256: sumA, Compress: true},
		{Name: "a.gz", Path: pathB, Size: sizeB, SHA256: hex.EncodeToString(sumB[:]), Compress: true},
	} {
		p, err := prepareFile(context.Background(), input)
		if err != nil {
			t.Fatal(err)
		}
		prepared = append(prepared, p)
	}
	ensureUniqueStoredNames(prepared)
	if prepared[0].StoredName == prepared[1].StoredName {
		t.Fatalf("stored names collide: %q", prepared[0].StoredName)
	}
	if prepared[0].StoredName != "a.gz" || prepared[1].StoredName != "a-1.gz" {
		t.Fatalf("unexpected stored names: %q, %q", prepared[0].StoredName, prepared[1].StoredName)
	}
}
FERRY_EOF_26

cat > 'internal/jobs/cleanup.go' <<'FERRY_EOF_27'
package jobs

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"time"

	"ferry/internal/db"
	"ferry/internal/dockerhub"
	"ferry/internal/safename"
)

const (
	staleDraftAge = 24 * time.Hour
	cleanupPeriod = time.Hour
)

func (m *Manager) cleanupLoop(ctx context.Context) {
	timer := time.NewTimer(2 * time.Minute)
	defer timer.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-timer.C:
			m.runCleanup(ctx)
			timer.Reset(cleanupPeriod)
		}
	}
}

func (m *Manager) runCleanup(ctx context.Context) {
	if ctx.Err() != nil {
		return
	}
	m.deleteStaleDrafts(ctx)
	m.cleanupOrphans(ctx)
	m.cleanupRetention(ctx)
}

func (m *Manager) deleteStaleDrafts(ctx context.Context) {
	cutoff := time.Now().Add(-staleDraftAge)
	drafts, err := m.store.ListStaleDrafts(ctx, cutoff)
	if err != nil {
		m.logger.Error("list stale drafts", "error", err)
		return
	}
	for _, job := range drafts {
		ok, err := m.store.DeleteStaleDraft(ctx, job.ID, cutoff)
		if err != nil {
			m.logger.Error("delete stale draft", "id", job.ID, "error", err)
			continue
		}
		if !ok {
			continue
		}
		m.removeJobDir(job.ID)
		m.logger.Info("deleted stale draft", "id", job.ID)
	}
}

// cleanupOrphans removes job directories whose database row is gone or whose
// job is finished. Draft and queued jobs keep their files.
func (m *Manager) cleanupOrphans(ctx context.Context) {
	base := filepath.Join(m.cfg.DataDir, "jobs")
	entries, err := os.ReadDir(base)
	if err != nil {
		if !os.IsNotExist(err) {
			m.logger.Error("read jobs directory", "error", err)
		}
		return
	}
	for _, entry := range entries {
		if !entry.IsDir() {
			continue
		}
		id := entry.Name()
		dir, err := safename.JobDir(m.cfg.DataDir, id)
		if err != nil {
			m.logger.Warn("skipping unrecognized entry in jobs directory", "name", id)
			continue
		}
		job, err := m.store.GetJob(ctx, id)
		if errors.Is(err, db.ErrNotFound) {
			if err := os.RemoveAll(dir); err != nil {
				m.logger.Error("remove orphan job directory", "id", id, "error", err)
			}
			continue
		}
		if err != nil {
			m.logger.Error("look up job directory", "id", id, "error", err)
			continue
		}
		if db.IsTerminal(job.State) {
			if err := os.RemoveAll(dir); err != nil {
				m.logger.Error("remove finished job directory", "id", id, "error", err)
			}
		}
	}
}

func (m *Manager) cleanupRetention(ctx context.Context) {
	if m.cfg.RetentionDays <= 0 {
		return
	}
	cutoff := time.Now().AddDate(0, 0, -m.cfg.RetentionDays)
	jobs, err := m.store.ListDoneBefore(ctx, cutoff)
	if err != nil {
		m.logger.Error("list images for retention", "error", err)
		return
	}
	for _, job := range jobs {
		repo, tag, err := dockerhub.SplitImage(job.Image)
		if err == nil {
			err = m.hub.DeleteTag(ctx, repo, tag)
		}
		if err != nil {
			m.logger.Error("retention image delete failed", "id", job.ID, "image", job.Image, "error", err)
			continue
		}
		if err := m.store.SetImageDeleted(ctx, job.ID); err != nil {
			m.logger.Error("mark retention image deleted", "id", job.ID, "error", err)
			continue
		}
		m.appendLog(ctx, job.ID, "Docker Hub image tag deleted by retention policy.")
	}
}
FERRY_EOF_27

cat > 'internal/jobs/disk.go' <<'FERRY_EOF_28'
package jobs

import (
	"fmt"
	"syscall"
)

// FreeDiskBytes returns available bytes for the filesystem containing path.
func FreeDiskBytes(path string) (int64, error) {
	var st syscall.Statfs_t
	if err := syscall.Statfs(path, &st); err != nil {
		return 0, fmt.Errorf("read free disk space: %w", err)
	}
	bsize := int64(st.Bsize)
	avail := int64(st.Bavail)
	if bsize <= 0 || avail < 0 {
		return 0, fmt.Errorf("read free disk space: unexpected filesystem values")
	}
	if avail > (1<<63-1)/bsize {
		return 1<<63 - 1, nil
	}
	return avail * bsize, nil
}

// CheckDiskSpace requires 1.5 times the job size to be free. Layers are
// streamed, so a second full copy is not needed.
func CheckDiskSpace(path string, total int64) error {
	free, err := FreeDiskBytes(path)
	if err != nil {
		return err
	}
	required := float64(total) * 1.5
	if float64(free) < required {
		return fmt.Errorf("not enough free disk space: the job needs about %s free (1.5x its %s size), but only %s is available in %s",
			formatBytes(int64(required)), formatBytes(total), formatBytes(free), path)
	}
	return nil
}

func formatBytes(n int64) string {
	if n < 0 {
		return "0 B"
	}
	const unit = 1024
	if n < unit {
		return fmt.Sprintf("%d B", n)
	}
	div, exp := int64(unit), 0
	for v := n / unit; v >= unit; v /= unit {
		div *= unit
		exp++
	}
	return fmt.Sprintf("%.1f %ciB", float64(n)/float64(div), "KMGTPE"[exp])
}
FERRY_EOF_28

cat > 'internal/jobs/manager.go' <<'FERRY_EOF_29'
package jobs

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"path/filepath"
	"runtime/debug"
	"strings"
	"sync"
	"time"

	v1 "github.com/google/go-containerregistry/pkg/v1"

	"ferry/internal/config"
	"ferry/internal/db"
	"ferry/internal/dockerhub"
	"ferry/internal/downloader"
	"ferry/internal/imagebuild"
	"ferry/internal/safename"
	"ferry/internal/secretbox"
)

// Progress is the live, non-persisted progress shown by the job page.
type Progress struct {
	Text  string
	Done  int64
	Total int64
}

// Manager owns the single job queue and its worker.
type Manager struct {
	cfg     *config.Config
	store   *db.Store
	dl      *downloader.Client
	builder *imagebuild.Builder
	hub     *dockerhub.Client
	logger  *slog.Logger

	ctx    context.Context
	cancel context.CancelFunc
	queue  chan string
	wg     sync.WaitGroup

	mu       sync.Mutex
	progress map[string]Progress
	current  string
	closing  bool

	cancelMu      sync.Mutex
	jobCancels    map[string]context.CancelFunc
	userCancelled map[string]bool
}

// New creates a job manager. Call Start and Recover before serving requests.
func New(cfg *config.Config, store *db.Store, dl *downloader.Client,
	builder *imagebuild.Builder, hub *dockerhub.Client, logger *slog.Logger) *Manager {
	ctx, cancel := context.WithCancel(context.Background())
	return &Manager{
		cfg:           cfg,
		store:         store,
		dl:            dl,
		builder:       builder,
		hub:           hub,
		logger:        logger,
		ctx:           ctx,
		cancel:        cancel,
		queue:         make(chan string, 256),
		progress:      make(map[string]Progress),
		jobCancels:    make(map[string]context.CancelFunc),
		userCancelled: make(map[string]bool),
	}
}

// Start launches the worker and the hourly cleanup loop.
func (m *Manager) Start() {
	m.wg.Add(2)
	go func() {
		defer m.wg.Done()
		m.worker()
	}()
	go func() {
		defer m.wg.Done()
		m.cleanupLoop(m.ctx)
	}()
}

// Recover repairs state left by a previous process, removes orphan
// directories, and re-queues jobs that were queued when the process stopped.
func (m *Manager) Recover(ctx context.Context) error {
	var errs []error
	for _, state := range []string{db.StateDownloading, db.StateBuilding, db.StatePushing} {
		list, err := m.store.ListByState(ctx, state)
		if err != nil {
			errs = append(errs, err)
			continue
		}
		for _, job := range list {
			bg, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			_ = m.store.Fail(bg, job.ID, "interrupted by restart")
			_ = m.store.AppendLog(bg, job.ID, "Interrupted by a Ferry restart; partial files were removed.")
			cancel()
			m.removeJobDir(job.ID)
			m.setProgress(job.ID, Progress{Text: "Failed: interrupted by restart"})
			// A push may have completed before the restart. Delete the tag so it
			// cannot stay in Docker Hub forever without a history record.
			if job.Image != "" {
				m.deleteOrphanTag(job.ID, job.Image)
			}
		}
	}
	queued, err := m.store.ListByState(ctx, db.StateQueued)
	if err != nil {
		errs = append(errs, err)
	} else {
		for _, job := range queued {
			select {
			case m.queue <- job.ID:
			case <-m.ctx.Done():
				return errors.Join(errs...)
			}
		}
	}
	m.cleanupOrphans(ctx)
	return errors.Join(errs...)
}

// SetOptions saves the optional compression flag and passphrase for a draft.
// An empty passphrase keeps the one already saved, so pressing Start twice
// cannot silently remove encryption.
func (m *Manager) SetOptions(ctx context.Context, jobID, passphrase string, compress, clearPassphrase bool) error {
	job, err := m.store.GetJob(ctx, jobID)
	if err != nil {
		return err
	}
	if job.State != db.StateDraft {
		return errors.New("options can only be changed while the job is a draft")
	}
	enc := job.PassphraseEnc
	if clearPassphrase {
		enc = ""
	} else if passphrase != "" {
		if len(passphrase) < 8 {
			return errors.New("the passphrase must be at least 8 characters")
		}
		if len(passphrase) > 1024 {
			return errors.New("the passphrase is too long (maximum 1024 characters)")
		}
		enc, err = secretbox.Seal(m.cfg.SecretKey, passphrase)
		if err != nil {
			return fmt.Errorf("save passphrase: %w", err)
		}
	}
	if err := m.store.SetJobOptions(ctx, jobID, enc, compress); err != nil {
		if errors.Is(err, db.ErrNotDraft) {
			return errors.New("the job started before the options were saved; refresh the page")
		}
		return err
	}
	return nil
}

// StartJob validates a draft and moves it to the queue.
func (m *Manager) StartJob(ctx context.Context, jobID string) error {
	job, err := m.store.GetJob(ctx, jobID)
	if err != nil {
		return err
	}
	if job.State != db.StateDraft {
		return errors.New("this job has already been started")
	}
	pending, err := m.store.CountPendingUploads(ctx, jobID)
	if err != nil {
		return err
	}
	if pending > 0 {
		return fmt.Errorf("%d file upload(s) are still in progress; wait for them to finish before starting", pending)
	}
	entryCount, err := m.store.CountFiles(ctx, jobID)
	if err != nil {
		return err
	}
	if entryCount == 0 {
		return errors.New("add at least one file or download URL before starting")
	}
	total, _, err := m.store.RecalcTotals(ctx, jobID)
	if err != nil {
		return err
	}
	if total > m.cfg.MaxTotalBytes {
		return fmt.Errorf("job size %s exceeds the limit of %s", formatBytes(total), formatBytes(m.cfg.MaxTotalBytes))
	}
	if err := CheckDiskSpace(m.cfg.DataDir, total); err != nil {
		return err
	}
	ok, err := m.store.Transition(ctx, jobID, db.StateDraft, db.StateQueued, "")
	if err != nil {
		return err
	}
	if !ok {
		return errors.New("this job is no longer a draft")
	}
	// Re-check after the atomic transition. A concurrent upload creation either
	// happened before this check (and is caught here) or will fail its own
	// draft-state check in the database.
	if pending, err := m.store.CountPendingUploads(ctx, jobID); err != nil {
		return err
	} else if pending > 0 {
		_, _ = m.store.Transition(ctx, jobID, db.StateQueued, db.StateDraft, "")
		return errors.New("an upload is still in progress; wait for it to finish, then start again")
	}
	m.appendLog(ctx, jobID, "Queued. Waiting for the worker.")
	m.setProgress(jobID, Progress{Text: "Queued", Done: 0, Total: total})
	select {
	case m.queue <- jobID:
		return nil
	case <-m.ctx.Done():
		return errors.New("the server is shutting down; the job is queued and will start after the next restart")
	}
}

// Progress returns a copy of the live progress for a job.
func (m *Manager) Progress(jobID string) Progress {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.progress[jobID]
}

// Current returns the job the worker is processing right now, if any.
func (m *Manager) Current() (string, Progress) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.current == "" {
		return "", Progress{}
	}
	return m.current, m.progress[m.current]
}

// Cancel stops a queued or running transfer. Queued jobs are marked failed
// immediately; running jobs are cancelled through their context and the worker
// cleans up the files.
func (m *Manager) Cancel(ctx context.Context, jobID string) error {
	job, err := m.store.GetJob(ctx, jobID)
	if err != nil {
		return err
	}
	switch job.State {
	case db.StateQueued:
		ok, err := m.store.Transition(ctx, jobID, db.StateQueued, db.StateFailed, "cancelled by user")
		if err != nil {
			return err
		}
		if !ok {
			return errors.New("the transfer already started; try cancelling again")
		}
		m.appendLog(ctx, jobID, "Cancelled before it started.")
		m.setProgress(jobID, Progress{Text: "Cancelled by user"})
		return nil
	case db.StateDownloading, db.StateBuilding, db.StatePushing:
		m.cancelMu.Lock()
		cancel := m.jobCancels[jobID]
		if cancel != nil {
			m.userCancelled[jobID] = true
		}
		m.cancelMu.Unlock()
		if cancel == nil {
			return errors.New("the transfer is starting; try cancelling again in a moment")
		}
		m.appendLog(ctx, jobID, "Cancellation requested. Stopping the current step...")
		m.setProgress(jobID, Progress{Text: "Cancelling..."})
		cancel()
		return nil
	default:
		return errors.New("only queued or running transfers can be cancelled")
	}
}

func (m *Manager) wasUserCancelled(jobID string) bool {
	m.cancelMu.Lock()
	defer m.cancelMu.Unlock()
	return m.userCancelled[jobID]
}

func (m *Manager) registerCancel(jobID string, cancel context.CancelFunc) {
	m.cancelMu.Lock()
	defer m.cancelMu.Unlock()
	m.jobCancels[jobID] = cancel
	delete(m.userCancelled, jobID)
}

func (m *Manager) unregisterCancel(jobID string) {
	m.cancelMu.Lock()
	defer m.cancelMu.Unlock()
	delete(m.jobCancels, jobID)
	delete(m.userCancelled, jobID)
}

// Shutdown stops the worker and waits for its cleanup. The running job is
// marked failed by the worker itself.
func (m *Manager) Shutdown(ctx context.Context) error {
	m.mu.Lock()
	m.closing = true
	m.mu.Unlock()
	m.cancel()
	done := make(chan struct{})
	go func() {
		m.wg.Wait()
		close(done)
	}()
	select {
	case <-done:
		return nil
	case <-ctx.Done():
		return errors.New("background worker did not stop in time")
	}
}

// DeleteImage removes a job's tag from Docker Hub.
func (m *Manager) DeleteImage(ctx context.Context, jobID string) error {
	job, err := m.store.GetJob(ctx, jobID)
	if err != nil {
		return err
	}
	if job.Image == "" {
		return errors.New("this job has no pushed image")
	}
	if job.ImageDeleted {
		return nil
	}
	repo, tag, err := dockerhub.SplitImage(job.Image)
	if err != nil {
		return err
	}
	if err := m.hub.DeleteTag(ctx, repo, tag); err != nil {
		return err
	}
	if err := m.store.SetImageDeleted(ctx, jobID); err != nil {
		return err
	}
	m.appendLog(ctx, jobID, "Docker Hub image tag deleted.")
	return nil
}

// PurgeImages deletes every remaining tag for jobs finished before the cutoff.
func (m *Manager) PurgeImages(ctx context.Context, days int) (int, []string, error) {
	if days < 1 {
		return 0, nil, errors.New("days must be at least 1")
	}
	cutoff := time.Now().AddDate(0, 0, -days)
	jobs, err := m.store.ListDoneBefore(ctx, cutoff)
	if err != nil {
		return 0, nil, err
	}
	deleted := 0
	var failures []string
	for _, job := range jobs {
		repo, tag, err := dockerhub.SplitImage(job.Image)
		if err == nil {
			err = m.hub.DeleteTag(ctx, repo, tag)
		}
		if err != nil {
			failures = append(failures, fmt.Sprintf("%s: %v", job.Image, err))
			continue
		}
		if err := m.store.SetImageDeleted(ctx, job.ID); err != nil {
			failures = append(failures, fmt.Sprintf("%s: %v", job.Image, err))
			continue
		}
		m.appendLog(ctx, job.ID, "Docker Hub image tag deleted by manual purge.")
		deleted++
	}
	return deleted, failures, nil
}

func (m *Manager) setProgress(jobID string, p Progress) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.progress[jobID] = p
}

func (m *Manager) appendLog(ctx context.Context, jobID, message string) {
	if strings.Contains(message, m.cfg.DockerHubToken) {
		message = strings.ReplaceAll(message, m.cfg.DockerHubToken, "[redacted]")
	}
	m.logger.Info("job", "id", jobID, "message", message)
	if err := m.store.AppendLog(ctx, jobID, message); err != nil && ctx.Err() == nil {
		m.logger.Error("append job log", "id", jobID, "error", err)
	}
}

func (m *Manager) failJob(jobID, message string) {
	message = strings.TrimSpace(message)
	if message == "" {
		message = "job failed"
	}
	bg, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := m.store.Fail(bg, jobID, message); err != nil {
		m.logger.Error("mark job failed", "id", jobID, "error", err)
	}
	m.appendLog(bg, jobID, "ERROR: "+message)
	m.setProgress(jobID, Progress{Text: "Failed: " + message})
}

func (m *Manager) deleteOrphanTag(jobID, image string) {
	repo, tag, err := dockerhub.SplitImage(image)
	if err != nil {
		m.logger.Error("cannot parse image for orphan cleanup", "id", jobID, "image", image, "error", err)
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	if err := m.hub.DeleteTag(ctx, repo, tag); err != nil {
		m.logger.Error("orphan image delete failed", "id", jobID, "image", image, "error", err)
		return
	}
	if err := m.store.SetImageDeleted(ctx, jobID); err != nil {
		m.logger.Error("mark orphan image deleted", "id", jobID, "error", err)
	}
}

// cleanupJobDirIfTerminal keeps files for a job that is still queued or
// running (for example when a transient database error aborts the worker) and
// removes them once the job reached a terminal state.
func (m *Manager) cleanupJobDirIfTerminal(jobID string) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	job, err := m.store.GetJob(ctx, jobID)
	if errors.Is(err, db.ErrNotFound) {
		m.removeJobDir(jobID)
		return
	}
	if err != nil {
		m.logger.Error("check job before cleanup", "id", jobID, "error", err)
		return
	}
	if db.IsTerminal(job.State) {
		m.removeJobDir(jobID)
	}
}

func (m *Manager) removeJobDir(jobID string) {
	dir, err := safename.JobDir(m.cfg.DataDir, jobID)
	if err != nil {
		return
	}
	if err := os.RemoveAll(dir); err != nil {
		m.logger.Error("remove job directory", "id", jobID, "error", err)
	}
}

func (m *Manager) worker() {
	for {
		select {
		case <-m.ctx.Done():
			return
		case jobID := <-m.queue:
			if m.ctx.Err() != nil {
				return
			}
			jobCtx, jobCancel := context.WithCancel(m.ctx)
			m.registerCancel(jobID, jobCancel)
			m.process(jobCtx, jobID)
			jobCancel()
			m.unregisterCancel(jobID)
		}
	}
}

func (m *Manager) process(ctx context.Context, jobID string) {
	m.mu.Lock()
	m.current = jobID
	m.mu.Unlock()
	defer func() {
		m.mu.Lock()
		if m.current == jobID {
			m.current = ""
		}
		m.mu.Unlock()
		m.cleanupJobDirIfTerminal(jobID)
	}()
	defer func() {
		if r := recover(); r != nil {
			m.logger.Error("worker panic", "id", jobID, "panic", r, "stack", string(debug.Stack()))
			if ctx.Err() != nil {
				m.failJob(jobID, "interrupted by shutdown")
			} else {
				m.failJob(jobID, "internal error while processing the job; check the server logs")
			}
		}
	}()

	job, err := m.store.GetJob(ctx, jobID)
	if err != nil {
		m.logger.Error("load queued job", "id", jobID, "error", err)
		return
	}
	// Atomic transition: a concurrent cancel marks the job failed instead, and
	// this worker then leaves it alone.
	ok, err := m.store.Transition(ctx, jobID, db.StateQueued, db.StateDownloading, "")
	if err != nil {
		m.logger.Error("start job", "id", jobID, "error", err)
		return
	}
	if !ok {
		return
	}
	m.appendLog(ctx, jobID, "Worker started.")
	m.setProgress(jobID, Progress{Text: "Preparing downloads"})

	if err := m.downloadAll(ctx, jobID); err != nil {
		m.finishError(ctx, jobID, err)
		return
	}
	if ctx.Err() != nil {
		m.finishError(ctx, jobID, errors.New("transfer stopped"))
		return
	}

	if err := m.store.SetState(ctx, jobID, db.StateBuilding, ""); err != nil {
		m.finishError(ctx, jobID, err)
		return
	}
	m.appendLog(ctx, jobID, "Building image layers from disk (streamed; no second copy is created).")
	m.setProgress(jobID, Progress{Text: "Building image"})

	files, err := m.store.ListDoneFiles(ctx, jobID)
	if err != nil {
		m.finishError(ctx, jobID, err)
		return
	}
	if len(files) == 0 {
		m.finishError(ctx, jobID, errors.New("no files are available to pack"))
		return
	}
	inputs := make([]imagebuild.InputFile, 0, len(files))
	jobDir, err := safename.JobDir(m.cfg.DataDir, jobID)
	if err != nil {
		m.finishError(ctx, jobID, err)
		return
	}
	for _, f := range files {
		path, err := jobFilePath(jobDir, f.Name)
		if err != nil {
			m.finishError(ctx, jobID, err)
			return
		}
		inputs = append(inputs, imagebuild.InputFile{
			Name: f.Name, Path: path, Size: f.Size, SHA256: f.SHA256, MD5: f.MD5,
		})
	}

	passphrase := ""
	if job.HasPassphrase {
		passphrase, err = secretbox.Open(m.cfg.SecretKey, job.PassphraseEnc)
		if err != nil {
			m.finishError(ctx, jobID, err)
			return
		}
		m.appendLog(ctx, jobID, "Files will be encrypted with the job passphrase.")
	}
	if job.Compress {
		m.appendLog(ctx, jobID, "Files will be gzip-compressed when that makes them smaller.")
	}
	opts := imagebuild.Options{
		Compress:   job.Compress,
		Passphrase: passphrase,
		OnTag: func(name string) {
			bg, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			defer cancel()
			if err := m.store.SetImage(bg, jobID, name); err != nil {
				m.logger.Error("record image tag before push", "id", jobID, "error", err)
			}
		},
	}
	for i := range inputs {
		inputs[i].Compress = job.Compress
		inputs[i].Encrypt = passphrase != ""
		inputs[i].Passphrase = passphrase
	}

	image, err := m.builder.BuildAndPush(
		ctx,
		inputs,
		opts,
		func(line string) { m.appendLog(ctx, jobID, line) },
		func(phase string) {
			if phase == db.StatePushing {
				if err := m.store.SetState(ctx, jobID, db.StatePushing, ""); err != nil {
					m.logger.Error("set pushing state", "id", jobID, "error", err)
				}
				m.appendLog(ctx, jobID, "Pushing image to Docker Hub.")
				m.setProgress(jobID, Progress{Text: "Pushing image", Done: 0, Total: 0})
			}
		},
		func(u v1.Update) {
			m.setProgress(jobID, Progress{Text: "Pushing image", Done: u.Complete, Total: u.Total})
		},
	)
	passphrase = ""
	if err != nil {
		if image != "" {
			bg, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			if setErr := m.store.SetImage(bg, jobID, image); setErr != nil {
				m.logger.Error("record image after failed push", "id", jobID, "error", setErr)
			} else {
				m.appendLog(bg, jobID, fmt.Sprintf("Recorded image tag %s so it can be deleted from Docker Hub.", image))
			}
			cancel()
		}
		m.finishError(ctx, jobID, err)
		return
	}
	bg, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	total, count, err := m.store.RecalcTotals(bg, jobID)
	if err != nil {
		m.finishError(ctx, jobID, err)
		return
	}
	if err := m.store.Complete(bg, jobID, image, total, count); err != nil {
		_ = m.store.SetImage(bg, jobID, image)
		m.failJob(jobID, "image was pushed but the job record could not be saved: "+err.Error())
		return
	}
	m.appendLog(bg, jobID, fmt.Sprintf("Done. Image: %s", image))
	m.setProgress(jobID, Progress{Text: "Done", Done: total, Total: total})
}

func (m *Manager) downloadAll(ctx context.Context, jobID string) error {
	urls, err := m.store.ListPendingURLs(ctx, jobID)
	if err != nil {
		return err
	}
	if len(urls) == 0 {
		return nil
	}
	jobDir, err := safename.JobDir(m.cfg.DataDir, jobID)
	if err != nil {
		return err
	}
	downloadDir := filepath.Join(jobDir, "downloads")
	if err := os.MkdirAll(downloadDir, 0o750); err != nil {
		return fmt.Errorf("create download directory: %w", err)
	}
	defer os.RemoveAll(downloadDir)

	for _, entry := range urls {
		if err := ctx.Err(); err != nil {
			return errors.New("interrupted by shutdown")
		}
		current, err := m.store.DeclaredTotal(ctx, jobID)
		if err != nil {
			return err
		}
		remaining := m.cfg.MaxTotalBytes - current
		if remaining <= 0 {
			return fmt.Errorf("download %s would exceed the %s job limit",
				entry.URL, formatBytes(m.cfg.MaxTotalBytes))
		}
		// URL sizes are unknown until the download starts, so reserve up to
		// 2 GiB (or the remaining quota, if smaller) before each download.
		need := remaining
		if need > 2<<30 {
			need = 2 << 30
		}
		free, err := FreeDiskBytes(m.cfg.DataDir)
		if err != nil {
			return err
		}
		if free < need {
			return fmt.Errorf("not enough free disk space to download %s: need about %s free, only %s is available in %s",
				entry.URL, formatBytes(need), formatBytes(free), m.cfg.DataDir)
		}
		tempPath := filepath.Join(downloadDir, fmt.Sprintf("%d.part", entry.ID))
		label := fmt.Sprintf("Downloading %s", entry.URL)
		m.appendLog(ctx, jobID, label)
		m.setProgress(jobID, Progress{Text: label})
		res, err := m.dl.Download(ctx, entry.URL, tempPath, remaining,
			func(done, total int64) {
				m.setProgress(jobID, Progress{Text: label, Done: done, Total: total})
			})
		if err != nil {
			_ = os.Remove(tempPath)
			if ctx.Err() != nil {
				return errors.New("interrupted by shutdown")
			}
			return fmt.Errorf("download %s failed: %w", entry.URL, err)
		}
		used, err := m.store.UsedNames(ctx, jobID)
		if err != nil {
			_ = os.Remove(tempPath)
			return err
		}
		suggested := res.Filename
		if suggested == "download" {
			suggested = fmt.Sprintf("download-%d", entry.ID)
		}
		name := safename.Unique(suggested, used)
		finalPath, err := jobFilePath(jobDir, name)
		if err != nil {
			_ = os.Remove(tempPath)
			return err
		}
		if err := os.MkdirAll(filepath.Dir(finalPath), 0o750); err != nil {
			_ = os.Remove(tempPath)
			return fmt.Errorf("create files directory: %w", err)
		}
		if _, err := os.Stat(finalPath); err == nil {
			_ = os.Remove(tempPath)
			return fmt.Errorf("a file named %q already exists in this job", name)
		}
		if err := os.Rename(tempPath, finalPath); err != nil {
			_ = os.Remove(tempPath)
			return fmt.Errorf("save downloaded file: %w", err)
		}
		if err := m.store.MarkURLDone(ctx, jobID, entry.ID, name, res.Size, res.SHA256, res.MD5); err != nil {
			return err
		}
		m.appendLog(ctx, jobID, fmt.Sprintf("Downloaded %s as %q (%s).", entry.URL, name, formatBytes(res.Size)))
	}
	return nil
}

func jobFilePath(jobDir, name string) (string, error) {
	clean := safename.Sanitize(name)
	if clean == "" || clean != name {
		return "", errors.New("unsafe filename in job")
	}
	base := filepath.Join(jobDir, "files")
	p := filepath.Join(base, clean)
	rel, err := filepath.Rel(base, p)
	if err != nil || rel == ".." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) || filepath.IsAbs(rel) {
		return "", errors.New("file path escapes the job directory")
	}
	return p, nil
}

func (m *Manager) finishError(ctx context.Context, jobID string, err error) {
	if ctx.Err() != nil {
		if m.wasUserCancelled(jobID) {
			m.failJob(jobID, "cancelled by user")
			return
		}
		m.failJob(jobID, "interrupted by shutdown")
		return
	}
	msg := err.Error()
	m.failJob(jobID, msg)
}
FERRY_EOF_29

cat > 'internal/safename/safename.go' <<'FERRY_EOF_30'
// Package safename contains the filename and path rules shared by Ferry.
package safename

import (
	"errors"
	"fmt"
	"path"
	"path/filepath"
	"regexp"
	"strings"
	"unicode"
	"unicode/utf8"
)

const MaxNameBytes = 200

var jobIDRE = regexp.MustCompile(`^[a-f0-9]{32}$`)

// reservedNames are written by Ferry itself inside the image.
var reservedNames = map[string]bool{
	"SHA256SUMS": true, "MD5SUMS": true,
	"FERRY-MANIFEST.json": true, "README-FERRY.txt": true, "ferry": true,
}

// Reserved reports whether a filename is generated by Ferry and therefore
// cannot be used for a user file.
func Reserved(name string) bool {
	return reservedNames[Sanitize(name)]
}

// Sanitize turns an untrusted filename into a safe basename. It returns an
// empty string when no usable name remains.
func Sanitize(name string) string {
	name = strings.ReplaceAll(name, "\x00", "")
	name = strings.ReplaceAll(name, "\\", "/")
	name = path.Base(name)
	name = strings.Map(func(r rune) rune {
		if r == utf8.RuneError || unicode.IsControl(r) {
			return '_'
		}
		return r
	}, name)
	name = strings.TrimSpace(name)
	name = strings.TrimRight(name, " .")
	if name == "" || name == "." || name == ".." {
		return ""
	}
	if len(name) > MaxNameBytes {
		b := []byte(name)[:MaxNameBytes]
		for len(b) > 0 && !utf8.Valid(b) {
			b = b[:len(b)-1]
		}
		name = strings.TrimSpace(string(b))
		name = strings.TrimRight(name, " .")
	}
	if name == "" || name == "." || name == ".." {
		return ""
	}
	return name
}

// Unique returns a sanitized name not present in used. Collisions get -1, -2
// and so on before the extension.
func Unique(name string, used map[string]bool) string {
	base := Sanitize(name)
	if base == "" {
		base = "file"
	}
	if !used[base] {
		return base
	}
	ext := path.Ext(base)
	stem := strings.TrimSuffix(base, ext)
	for i := 1; i < 1_000_000; i++ {
		suffix := fmt.Sprintf("-%d", i)
		maxStem := MaxNameBytes - len(suffix) - len(ext)
		var candidate string
		if maxStem > 0 {
			s := stem
			if len(s) > maxStem {
				s = truncateUTF8(s, maxStem)
			}
			candidate = s + suffix + ext
		} else {
			candidate = truncateUTF8(base, MaxNameBytes-len(suffix)) + suffix
		}
		candidate = Sanitize(candidate)
		if candidate != "" && !used[candidate] {
			return candidate
		}
	}
	return Sanitize(fmt.Sprintf("file-%d", len(used)+1))
}

func truncateUTF8(s string, max int) string {
	if max <= 0 {
		return ""
	}
	if len(s) <= max {
		return s
	}
	b := []byte(s)[:max]
	for len(b) > 0 && !utf8.Valid(b) {
		b = b[:len(b)-1]
	}
	return string(b)
}

// JobDir validates jobID and returns <root>/jobs/<jobID>.
func JobDir(root, jobID string) (string, error) {
	if !jobIDRE.MatchString(jobID) {
		return "", errors.New("invalid job id")
	}
	base := filepath.Join(root, "jobs")
	dir := filepath.Join(base, jobID)
	rel, err := filepath.Rel(base, dir)
	if err != nil || rel != jobID || strings.HasPrefix(rel, "..") {
		return "", errors.New("job path escapes the data directory")
	}
	return dir, nil
}
FERRY_EOF_30

cat > 'internal/safename/safename_test.go' <<'FERRY_EOF_31'
package safename

import (
	"strings"
	"testing"
	"unicode/utf8"
)

func TestSanitize(t *testing.T) {
	tests := []struct {
		in   string
		want string
	}{
		{"photo.jpg", "photo.jpg"},
		{"../../etc/passwd", "passwd"},
		{`C:\Users\me\report.pdf`, "report.pdf"},
		{"..", ""},
		{".", ""},
		{"", ""},
		{"\x00evil.txt", "evil.txt"},
		{"a\nb\tc.txt", "a_b_c.txt"},
		{"  spaced.txt  ", "spaced.txt"},
		{"name. ", "name"},
		{"data\\..\\secret", "secret"},
		{"normal name (1).txt", "normal name (1).txt"},
	}
	for _, tc := range tests {
		if got := Sanitize(tc.in); got != tc.want {
			t.Errorf("Sanitize(%q) = %q, want %q", tc.in, got, tc.want)
		}
	}
}

func TestSanitizeByteLimit(t *testing.T) {
	long := strings.Repeat("a", 500)
	got := Sanitize(long)
	if len(got) != MaxNameBytes {
		t.Fatalf("length = %d, want %d", len(got), MaxNameBytes)
	}
	unicodeName := strings.Repeat("é", 150)
	got = Sanitize(unicodeName)
	if len(got) > MaxNameBytes {
		t.Fatalf("unicode name length = %d, want <= %d", len(got), MaxNameBytes)
	}
	if !utf8.ValidString(got) {
		t.Fatalf("Sanitize returned invalid UTF-8: %q", got)
	}
}

func TestUnique(t *testing.T) {
	used := map[string]bool{"a.txt": true, "a-1.txt": true}
	if got := Unique("a.txt", used); got != "a-2.txt" {
		t.Fatalf("Unique = %q, want a-2.txt", got)
	}
	if got := Unique("new.txt", used); got != "new.txt" {
		t.Fatalf("Unique = %q, want new.txt", got)
	}
}

func TestJobDirRejectsTraversal(t *testing.T) {
	if _, err := JobDir("/data", "../etc"); err == nil {
		t.Fatal("expected traversal job id to be rejected")
	}
	got, err := JobDir("/data", "0123456789abcdef0123456789abcdef")
	if err != nil {
		t.Fatal(err)
	}
	if got != "/data/jobs/0123456789abcdef0123456789abcdef" {
		t.Fatalf("JobDir = %q", got)
	}
}

func TestReserved(t *testing.T) {
	for _, name := range []string{"ferry", "SHA256SUMS", "MD5SUMS", "FERRY-MANIFEST.json", "README-FERRY.txt", "../ferry"} {
		if !Reserved(name) {
			t.Errorf("Reserved(%q) = false, want true", name)
		}
	}
	for _, name := range []string{"photo.jpg", "ferry.txt", "sha256sums"} {
		if Reserved(name) {
			t.Errorf("Reserved(%q) = true, want false", name)
		}
	}
}
FERRY_EOF_31

cat > 'internal/secretbox/secretbox.go' <<'FERRY_EOF_32'
// Package secretbox encrypts small secrets (the optional job passphrase) at
// rest with a key derived from FERRY_SECRET_KEY.
package secretbox

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"fmt"
	"strings"
)

const keyContext = "ferry-job-passphrase-v1:"

// Seal encrypts plaintext and returns a base64 string safe for SQLite.
func Seal(secret, plaintext string) (string, error) {
	if secret == "" {
		return "", errors.New("secret key is empty")
	}
	key := sha256.Sum256([]byte(keyContext + secret))
	block, err := aes.NewCipher(key[:])
	if err != nil {
		return "", err
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return "", err
	}
	nonce := make([]byte, gcm.NonceSize())
	if _, err := rand.Read(nonce); err != nil {
		return "", fmt.Errorf("generate nonce: %w", err)
	}
	sealed := gcm.Seal(nonce, nonce, []byte(plaintext), nil)
	return base64.RawURLEncoding.EncodeToString(sealed), nil
}

// Open decrypts a value produced by Seal.
func Open(secret, encoded string) (string, error) {
	if encoded == "" {
		return "", nil
	}
	if secret == "" {
		return "", errors.New("secret key is empty")
	}
	raw, err := base64.RawURLEncoding.DecodeString(strings.TrimSpace(encoded))
	if err != nil {
		return "", errors.New("stored passphrase is corrupted")
	}
	key := sha256.Sum256([]byte(keyContext + secret))
	block, err := aes.NewCipher(key[:])
	if err != nil {
		return "", err
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return "", err
	}
	if len(raw) < gcm.NonceSize() {
		return "", errors.New("stored passphrase is corrupted")
	}
	nonce, ciphertext := raw[:gcm.NonceSize()], raw[gcm.NonceSize():]
	plaintext, err := gcm.Open(nil, nonce, ciphertext, nil)
	if err != nil {
		return "", errors.New("stored passphrase could not be decrypted; FERRY_SECRET_KEY may have changed")
	}
	return string(plaintext), nil
}
FERRY_EOF_32

cat > 'internal/secretbox/secretbox_test.go' <<'FERRY_EOF_33'
package secretbox

import "testing"

func TestSealOpen(t *testing.T) {
	secret := "0123456789abcdef0123456789abcdef"
	encoded, err := Seal(secret, "correct horse battery staple")
	if err != nil {
		t.Fatal(err)
	}
	if encoded == "" || encoded == "correct horse battery staple" {
		t.Fatalf("unexpected encoded value %q", encoded)
	}
	got, err := Open(secret, encoded)
	if err != nil {
		t.Fatal(err)
	}
	if got != "correct horse battery staple" {
		t.Fatalf("Open = %q", got)
	}
}

func TestOpenWrongSecret(t *testing.T) {
	encoded, err := Seal("secret-one", "passphrase")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := Open("secret-two", encoded); err == nil {
		t.Fatal("expected an error with the wrong secret")
	}
}

func TestOpenEmpty(t *testing.T) {
	got, err := Open("secret", "")
	if err != nil || got != "" {
		t.Fatalf("Open empty = %q, %v", got, err)
	}
}
FERRY_EOF_33

cat > 'internal/securefile/securefile.go' <<'FERRY_EOF_34'
// Package securefile implements the optional per-job passphrase encryption
// used before files are packed into an image. It streams data in 1 MiB
// AES-256-GCM chunks so multi-gigabyte files never sit in memory.
package securefile

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"crypto/sha256"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"os"

	"golang.org/x/crypto/scrypt"
)

const (
	// Magic marks an encrypted Ferry file.
	Magic = "FERRYENC"
	// Version is the current on-disk format.
	Version = 1
	// SaltSize is the random scrypt salt length.
	SaltSize = 16
	// Suffix is appended to encrypted files.
	Suffix = ".ferry"

	headerSize = len(Magic) + 1 + SaltSize + 8
	chunkSize  = 1 << 20
	tagSize    = 16
	maxChunk   = chunkSize + tagSize

	scryptN = 1 << 15
	scryptR = 8
	scryptP = 1
	keyLen  = 32
)

// ErrNotEncrypted means the file does not start with the Ferry magic header.
var ErrNotEncrypted = errors.New("file is not encrypted by Ferry")

// ErrWrongPassphrase means the passphrase could not authenticate the data.
var ErrWrongPassphrase = errors.New("wrong passphrase or corrupted encrypted file")

// NewSalt returns a fresh random salt.
func NewSalt() ([]byte, error) {
	salt := make([]byte, SaltSize)
	if _, err := rand.Read(salt); err != nil {
		return nil, fmt.Errorf("generate encryption salt: %w", err)
	}
	return salt, nil
}

// Encrypt writes an encrypted copy of src to dst. plainSize must be the exact
// number of bytes in src; it is authenticated in the header. The same salt and
// input always produce the same output, which lets Ferry hash the stored bytes
// before the layer is streamed.
func Encrypt(dst io.Writer, src io.Reader, passphrase string, salt []byte, plainSize int64) error {
	if passphrase == "" {
		return errors.New("passphrase is empty")
	}
	if len(salt) != SaltSize {
		return fmt.Errorf("salt must be %d bytes", SaltSize)
	}
	if plainSize < 0 {
		return errors.New("plaintext size cannot be negative")
	}
	key, err := deriveKey(passphrase, salt)
	if err != nil {
		return err
	}
	block, err := aes.NewCipher(key)
	if err != nil {
		return fmt.Errorf("initialize encryption: %w", err)
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return fmt.Errorf("initialize encryption: %w", err)
	}

	header := make([]byte, headerSize)
	copy(header, Magic)
	header[len(Magic)] = Version
	copy(header[len(Magic)+1:], salt)
	binary.BigEndian.PutUint64(header[len(Magic)+1+SaltSize:], uint64(plainSize))
	if _, err := dst.Write(header); err != nil {
		return fmt.Errorf("write encryption header: %w", err)
	}

	buf := make([]byte, chunkSize)
	nonce := make([]byte, 12)
	var counter uint32
	var written int64
	for written < plainSize {
		want := int64(chunkSize)
		if remaining := plainSize - written; remaining < want {
			want = remaining
		}
		if _, err := io.ReadFull(src, buf[:want]); err != nil {
			return fmt.Errorf("read plaintext: %w", err)
		}
		binary.BigEndian.PutUint32(nonce[:4], counter)
		sealed := gcm.Seal(nil, nonce, buf[:want], header)
		var length [4]byte
		binary.BigEndian.PutUint32(length[:], uint32(len(sealed)))
		if _, err := dst.Write(length[:]); err != nil {
			return fmt.Errorf("write encrypted chunk: %w", err)
		}
		if _, err := dst.Write(sealed); err != nil {
			return fmt.Errorf("write encrypted chunk: %w", err)
		}
		written += want
		counter++
	}
	return nil
}

// Decrypt streams an encrypted Ferry file from src to dst and returns the
// number of plaintext bytes written.
func Decrypt(dst io.Writer, src io.Reader, passphrase string) (int64, error) {
	if passphrase == "" {
		return 0, errors.New("a passphrase is required to decrypt this file")
	}
	header := make([]byte, headerSize)
	if _, err := io.ReadFull(src, header); err != nil {
		if errors.Is(err, io.EOF) || errors.Is(err, io.ErrUnexpectedEOF) {
			return 0, ErrNotEncrypted
		}
		return 0, fmt.Errorf("read encryption header: %w", err)
	}
	if string(header[:len(Magic)]) != Magic {
		return 0, ErrNotEncrypted
	}
	if header[len(Magic)] != Version {
		return 0, fmt.Errorf("unsupported Ferry encryption version %d", header[len(Magic)])
	}
	salt := header[len(Magic)+1 : len(Magic)+1+SaltSize]
	plainSize := int64(binary.BigEndian.Uint64(header[len(Magic)+1+SaltSize:]))
	if plainSize < 0 {
		return 0, errors.New("invalid encrypted file header")
	}
	key, err := deriveKey(passphrase, salt)
	if err != nil {
		return 0, err
	}
	block, err := aes.NewCipher(key)
	if err != nil {
		return 0, err
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return 0, err
	}

	nonce := make([]byte, 12)
	var counter uint32
	var written int64
	for written < plainSize {
		var length [4]byte
		if _, err := io.ReadFull(src, length[:]); err != nil {
			if errors.Is(err, io.EOF) || errors.Is(err, io.ErrUnexpectedEOF) {
				return written, fmt.Errorf("encrypted file is truncated (expected %d bytes, found %d)", plainSize, written)
			}
			return written, fmt.Errorf("read encrypted chunk: %w", err)
		}
		size := int(binary.BigEndian.Uint32(length[:]))
		if size <= tagSize || size > maxChunk {
			return written, errors.New("encrypted file is corrupted (invalid chunk length)")
		}
		sealed := make([]byte, size)
		if _, err := io.ReadFull(src, sealed); err != nil {
			return written, fmt.Errorf("encrypted file is truncated: %w", err)
		}
		binary.BigEndian.PutUint32(nonce[:4], counter)
		chunk, err := gcm.Open(nil, nonce, sealed, header)
		if err != nil {
			return written, ErrWrongPassphrase
		}
		if written+int64(len(chunk)) > plainSize {
			return written, errors.New("encrypted file is corrupted (more data than declared)")
		}
		if _, err := dst.Write(chunk); err != nil {
			return written, fmt.Errorf("write decrypted data: %w", err)
		}
		written += int64(len(chunk))
		counter++
	}
	if written != plainSize {
		return written, fmt.Errorf("encrypted file is truncated (expected %d bytes, found %d)", plainSize, written)
	}
	return written, nil
}

// IsEncryptedFile reports whether path starts with the Ferry magic header.
func IsEncryptedFile(path string) (bool, error) {
	f, err := os.Open(path)
	if err != nil {
		return false, err
	}
	defer f.Close()
	head := make([]byte, len(Magic))
	n, err := io.ReadFull(f, head)
	if err != nil && !errors.Is(err, io.EOF) && !errors.Is(err, io.ErrUnexpectedEOF) {
		return false, err
	}
	return n == len(Magic) && string(head) == Magic, nil
}

func deriveKey(passphrase string, salt []byte) ([]byte, error) {
	key, err := scrypt.Key([]byte(passphrase), salt, scryptN, scryptR, scryptP, keyLen)
	if err != nil {
		return nil, fmt.Errorf("derive encryption key: %w", err)
	}
	return key, nil
}

// Fingerprint is a short, non-reversible identifier for a passphrase. It is
// only used to confirm that the same passphrase is being retried.
func Fingerprint(passphrase string) string {
	sum := sha256.Sum256([]byte("ferry-passphrase:" + passphrase))
	return fmt.Sprintf("%x", sum[:6])
}

// HeaderSize is the fixed size of the encrypted file header.
const HeaderSize = headerSize

// ChunkSize is the plaintext chunk size used by Encrypt.
const ChunkSize = chunkSize

// EncryptedSize returns the exact stored size for plainSize plaintext bytes.
func EncryptedSize(plainSize int64) int64 {
	if plainSize < 0 {
		return 0
	}
	chunks := plainSize / chunkSize
	if plainSize%chunkSize != 0 {
		chunks++
	}
	return int64(headerSize) + plainSize + chunks*(4+tagSize)
}
FERRY_EOF_34

cat > 'internal/securefile/securefile_test.go' <<'FERRY_EOF_35'
package securefile

import (
	"bytes"
	"crypto/rand"
	"errors"
	"io"
	"os"
	"path/filepath"
	"testing"
)

func TestRoundTrip(t *testing.T) {
	for _, size := range []int{0, 1, 1024, chunkSize - 1, chunkSize, chunkSize + 1, 3*chunkSize + 7} {
		data := make([]byte, size)
		if _, err := rand.Read(data); err != nil {
			t.Fatal(err)
		}
		salt, err := NewSalt()
		if err != nil {
			t.Fatal(err)
		}
		var encrypted bytes.Buffer
		if err := Encrypt(&encrypted, bytes.NewReader(data), "correct horse battery staple", salt, int64(size)); err != nil {
			t.Fatalf("size %d: encrypt: %v", size, err)
		}
		if got, want := int64(encrypted.Len()), EncryptedSize(int64(size)); got != want {
			t.Fatalf("size %d: encrypted length = %d, want %d", size, got, want)
		}
		var decrypted bytes.Buffer
		n, err := Decrypt(&decrypted, bytes.NewReader(encrypted.Bytes()), "correct horse battery staple")
		if err != nil {
			t.Fatalf("size %d: decrypt: %v", size, err)
		}
		if n != int64(size) || !bytes.Equal(decrypted.Bytes(), data) {
			t.Fatalf("size %d: round trip mismatch (n=%d)", size, n)
		}
	}
}

func TestWrongPassphrase(t *testing.T) {
	salt, _ := NewSalt()
	var encrypted bytes.Buffer
	if err := Encrypt(&encrypted, bytes.NewReader([]byte("secret data")), "right", salt, 11); err != nil {
		t.Fatal(err)
	}
	var out bytes.Buffer
	_, err := Decrypt(&out, bytes.NewReader(encrypted.Bytes()), "wrong")
	if !errors.Is(err, ErrWrongPassphrase) {
		t.Fatalf("error = %v, want ErrWrongPassphrase", err)
	}
}

func TestTruncatedFile(t *testing.T) {
	salt, _ := NewSalt()
	data := bytes.Repeat([]byte("x"), 2*chunkSize)
	var encrypted bytes.Buffer
	if err := Encrypt(&encrypted, bytes.NewReader(data), "pass", salt, int64(len(data))); err != nil {
		t.Fatal(err)
	}
	truncated := encrypted.Bytes()[:encrypted.Len()-10]
	var out bytes.Buffer
	if _, err := Decrypt(&out, bytes.NewReader(truncated), "pass"); err == nil {
		t.Fatal("truncated file decrypted without an error")
	}
}

func TestDeterministicWithSameSalt(t *testing.T) {
	salt, _ := NewSalt()
	data := []byte("same input")
	var a, b bytes.Buffer
	if err := Encrypt(&a, bytes.NewReader(data), "pass", salt, int64(len(data))); err != nil {
		t.Fatal(err)
	}
	if err := Encrypt(&b, bytes.NewReader(data), "pass", salt, int64(len(data))); err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(a.Bytes(), b.Bytes()) {
		t.Fatal("same salt and input produced different ciphertext")
	}
}

func TestIsEncryptedFile(t *testing.T) {
	dir := t.TempDir()
	plain := filepath.Join(dir, "plain.txt")
	if err := os.WriteFile(plain, []byte("hello"), 0o600); err != nil {
		t.Fatal(err)
	}
	ok, err := IsEncryptedFile(plain)
	if err != nil || ok {
		t.Fatalf("plain file: ok=%v err=%v", ok, err)
	}
	salt, _ := NewSalt()
	enc := filepath.Join(dir, "secret.txt.ferry")
	f, err := os.Create(enc)
	if err != nil {
		t.Fatal(err)
	}
	if err := Encrypt(f, bytes.NewReader([]byte("hello")), "pass", salt, 5); err != nil {
		t.Fatal(err)
	}
	if err := f.Close(); err != nil {
		t.Fatal(err)
	}
	ok, err = IsEncryptedFile(enc)
	if err != nil || !ok {
		t.Fatalf("encrypted file: ok=%v err=%v", ok, err)
	}
}

func TestDecryptNotEncrypted(t *testing.T) {
	_, err := Decrypt(io.Discard, bytes.NewReader([]byte("plain text, not encrypted")), "pass")
	if !errors.Is(err, ErrNotEncrypted) {
		t.Fatalf("error = %v, want ErrNotEncrypted", err)
	}
}
FERRY_EOF_35

cat > 'internal/uploads/service.go' <<'FERRY_EOF_36'
// Package uploads implements resumable chunked uploads and their quota rules.
package uploads

import (
	"context"
	"crypto/md5"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sync"

	"ferry/internal/db"
	"ferry/internal/safename"
)

// ErrQuota is returned when a file would exceed the job byte cap.
var ErrQuota = errors.New("job size limit exceeded")

// ErrInvalidName is returned for empty or unusable filenames.
var ErrInvalidName = errors.New("invalid filename")

// ErrReservedName is returned for names Ferry uses for its own image files.
var ErrReservedName = errors.New("that filename is reserved by Ferry; rename the file and try again")

// OffsetError reports a resumable upload offset mismatch.
type OffsetError struct {
	Current int64
	Message string
}

func (e *OffsetError) Error() string {
	if e.Message != "" {
		return e.Message
	}
	return fmt.Sprintf("upload offset mismatch: server has %d bytes", e.Current)
}

// Service coordinates upload metadata and temp files.
type Service struct {
	store   *db.Store
	dataDir string
	max     int64
	mu      sync.Mutex
	locks   sync.Map // upload id -> *sync.Mutex
}

// New creates an upload service.
func New(store *db.Store, dataDir string, maxTotal int64) *Service {
	return &Service{store: store, dataDir: dataDir, max: maxTotal}
}

// MaxTotal returns the configured per-job cap.
func (s *Service) MaxTotal() int64 { return s.max }

// CheckQuota verifies that adding add bytes to current stays under max.
func CheckQuota(current, add, max int64) error {
	if add < 0 {
		return errors.New("size cannot be negative")
	}
	if current < 0 {
		current = 0
	}
	if add > max-current {
		return ErrQuota
	}
	return nil
}

// ValidateOffset checks the browser-supplied offset against the bytes already
// received. Resuming is only allowed at exactly the current position.
func ValidateOffset(offset, received, declared int64) error {
	if offset < 0 || offset > declared {
		return &OffsetError{Current: received, Message: "offset is outside the declared file size"}
	}
	if offset != received {
		return &OffsetError{Current: received}
	}
	return nil
}

// Create reserves an upload and creates its empty temporary file.
func (s *Service) Create(ctx context.Context, jobID, filename string, size int64) (*db.Upload, error) {
	if size < 0 {
		return nil, errors.New("file size cannot be negative")
	}
	if size > s.max {
		return nil, ErrQuota
	}
	s.mu.Lock()
	defer s.mu.Unlock()

	job, err := s.store.GetJob(ctx, jobID)
	if err != nil {
		return nil, err
	}
	if job.State != db.StateDraft {
		return nil, errors.New("files can only be added while the job is a draft")
	}
	current, err := s.store.DeclaredTotal(ctx, jobID)
	if err != nil {
		return nil, err
	}
	if err := CheckQuota(current, size, s.max); err != nil {
		return nil, err
	}
	base := safename.Sanitize(filename)
	if base == "" {
		return nil, ErrInvalidName
	}
	if safename.Reserved(base) {
		return nil, ErrReservedName
	}
	used, err := s.store.UsedNames(ctx, jobID)
	if err != nil {
		return nil, err
	}
	name := safename.Unique(base, used)

	id, err := randomID()
	if err != nil {
		return nil, err
	}
	dir, err := safename.JobDir(s.dataDir, jobID)
	if err != nil {
		return nil, err
	}
	uploadDir := filepath.Join(dir, "uploads")
	if err := os.MkdirAll(uploadDir, 0o750); err != nil {
		return nil, fmt.Errorf("create upload directory: %w", err)
	}
	partPath := filepath.Join(uploadDir, id+".part")
	f, err := os.OpenFile(partPath, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
	if err != nil {
		return nil, fmt.Errorf("create upload file: %w", err)
	}
	if err := f.Close(); err != nil {
		_ = os.Remove(partPath)
		return nil, err
	}
	u := &db.Upload{ID: id, JobID: jobID, Filename: name, OriginalFilename: base, DeclaredSize: size}
	if err := s.store.CreateUpload(ctx, u); err != nil {
		_ = os.Remove(partPath)
		if errors.Is(err, db.ErrNotDraft) {
			return nil, errors.New("the job started while the file was being added; refresh the page")
		}
		return nil, err
	}
	return u, nil
}

// Get returns the current upload record.
func (s *Service) Get(ctx context.Context, jobID, uploadID string) (*db.Upload, error) {
	return s.store.GetUpload(ctx, jobID, uploadID)
}

// Append writes a chunk to the temp file. It truncates back to offset when the
// body turns out to be longer than the declared remainder.
func (s *Service) Append(ctx context.Context, jobID, uploadID string, offset int64, body io.Reader) (int64, error) {
	lock := s.uploadLock(uploadID)
	lock.Lock()
	defer lock.Unlock()

	job, err := s.store.GetJob(ctx, jobID)
	if err != nil {
		return 0, err
	}
	if job.State != db.StateDraft {
		return 0, errors.New("uploads are closed because the job has started")
	}
	u, err := s.store.GetUpload(ctx, jobID, uploadID)
	if err != nil {
		return 0, err
	}
	if u.Completed {
		return u.Received, errors.New("upload is already complete")
	}
	dir, err := safename.JobDir(s.dataDir, jobID)
	if err != nil {
		return 0, err
	}
	partPath := filepath.Join(dir, "uploads", uploadID+".part")
	f, err := os.OpenFile(partPath, os.O_WRONLY|os.O_APPEND, 0)
	if err != nil {
		return 0, fmt.Errorf("open upload file: %w", err)
	}
	defer f.Close()

	st, err := f.Stat()
	if err != nil {
		return 0, err
	}
	// The file is the source of truth after a crash between write and DB update.
	if st.Size() != u.Received {
		u.Received = st.Size()
		if err := s.store.SetUploadReceived(ctx, jobID, uploadID, u.Received); err != nil {
			return 0, err
		}
	}
	if err := ValidateOffset(offset, u.Received, u.DeclaredSize); err != nil {
		return u.Received, err
	}
	remaining := u.DeclaredSize - offset
	if remaining < 0 {
		return u.Received, &OffsetError{Current: u.Received}
	}

	limited := io.LimitReader(body, remaining+1)
	written, copyErr := io.Copy(f, limited)
	if copyErr != nil || written > remaining {
		// Discard a partial or oversized chunk so retries start from the same
		// known-good offset.
		_ = f.Truncate(offset)
		if copyErr != nil {
			return u.Received, fmt.Errorf("write upload chunk: %w", copyErr)
		}
		return u.Received, fmt.Errorf("chunk exceeds the remaining %d bytes", remaining)
	}
	if err := f.Sync(); err != nil {
		_ = f.Truncate(offset)
		return u.Received, fmt.Errorf("flush upload chunk: %w", err)
	}
	newReceived := offset + written
	if err := s.store.SetUploadReceived(ctx, jobID, uploadID, newReceived); err != nil {
		return u.Received, err
	}
	return newReceived, nil
}

// Complete verifies the declared size, hashes the file and moves it into place.
func (s *Service) Complete(ctx context.Context, jobID, uploadID string) (*db.File, error) {
	lock := s.uploadLock(uploadID)
	lock.Lock()
	defer lock.Unlock()

	job, err := s.store.GetJob(ctx, jobID)
	if err != nil {
		return nil, err
	}
	if job.State != db.StateDraft {
		return nil, errors.New("uploads are closed because the job has started")
	}
	u, err := s.store.GetUpload(ctx, jobID, uploadID)
	if err != nil {
		return nil, err
	}
	if u.Completed {
		return nil, errors.New("upload is already complete")
	}
	dir, err := safename.JobDir(s.dataDir, jobID)
	if err != nil {
		return nil, err
	}
	partPath := filepath.Join(dir, "uploads", uploadID+".part")
	st, err := os.Stat(partPath)
	if err != nil {
		return nil, fmt.Errorf("open upload file: %w", err)
	}
	if st.Size() != u.DeclaredSize {
		return nil, &OffsetError{Current: st.Size(),
			Message: fmt.Sprintf("upload is incomplete: received %d of %d bytes", st.Size(), u.DeclaredSize)}
	}
	if err := s.store.SetUploadReceived(ctx, jobID, uploadID, st.Size()); err != nil {
		return nil, err
	}
	sum, md5sum, err := hashFile(partPath)
	if err != nil {
		return nil, err
	}
	filesDir := filepath.Join(dir, "files")
	if err := os.MkdirAll(filesDir, 0o750); err != nil {
		return nil, fmt.Errorf("create files directory: %w", err)
	}
	name := safename.Sanitize(u.Filename)
	if name == "" {
		return nil, ErrInvalidName
	}
	if safename.Reserved(name) {
		return nil, ErrReservedName
	}
	finalPath, err := safeChild(filesDir, name)
	if err != nil {
		return nil, err
	}
	if _, err := os.Stat(finalPath); err == nil {
		return nil, fmt.Errorf("a file named %q already exists in this job", name)
	} else if !os.IsNotExist(err) {
		return nil, err
	}
	if err := os.Rename(partPath, finalPath); err != nil {
		return nil, fmt.Errorf("finalize upload: %w", err)
	}
	f := &db.File{JobID: jobID, Name: name, Size: u.DeclaredSize, SHA256: sum, MD5: md5sum, Source: "upload", Status: "done"}
	if err := s.store.CompleteUpload(ctx, jobID, uploadID, f); err != nil {
		// Put the bytes back so the user can retry completing the upload.
		_ = os.Rename(finalPath, partPath)
		return nil, err
	}
	return f, nil
}

// Delete cancels and removes an unfinished upload.
func (s *Service) Delete(ctx context.Context, jobID, uploadID string) error {
	lock := s.uploadLock(uploadID)
	lock.Lock()
	defer lock.Unlock()

	job, err := s.store.GetJob(ctx, jobID)
	if err != nil {
		return err
	}
	if job.State != db.StateDraft {
		return errors.New("files can only be removed while the job is a draft")
	}
	u, err := s.store.GetUpload(ctx, jobID, uploadID)
	if err != nil {
		return err
	}
	if u.Completed {
		return errors.New("upload is already complete")
	}
	dir, err := safename.JobDir(s.dataDir, jobID)
	if err != nil {
		return err
	}
	if err := s.store.DeleteUpload(ctx, jobID, uploadID); err != nil {
		return err
	}
	if err := os.Remove(filepath.Join(dir, "uploads", uploadID+".part")); err != nil && !os.IsNotExist(err) {
		return fmt.Errorf("remove upload file: %w", err)
	}
	return nil
}

// DeleteFile removes a finished upload or a URL entry while the job is a draft.
func (s *Service) DeleteFile(ctx context.Context, jobID string, fileID int64) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	job, err := s.store.GetJob(ctx, jobID)
	if err != nil {
		return err
	}
	if job.State != db.StateDraft {
		return errors.New("files can only be removed while the job is a draft")
	}
	f, err := s.store.GetFile(ctx, jobID, fileID)
	if err != nil {
		return err
	}
	if err := s.store.DeleteFile(ctx, jobID, fileID); err != nil {
		return err
	}
	if f.Status == "done" && f.Name != "" {
		dir, err := safename.JobDir(s.dataDir, jobID)
		if err != nil {
			return err
		}
		path, err := safeChild(filepath.Join(dir, "files"), f.Name)
		if err != nil {
			return err
		}
		if err := os.Remove(path); err != nil && !os.IsNotExist(err) {
			return fmt.Errorf("remove file: %w", err)
		}
	}
	return nil
}

// RemoveJobDir removes all bytes belonging to a job.
func (s *Service) RemoveJobDir(jobID string) error {
	dir, err := safename.JobDir(s.dataDir, jobID)
	if err != nil {
		return err
	}
	if err := os.RemoveAll(dir); err != nil {
		return fmt.Errorf("remove job directory: %w", err)
	}
	return nil
}

func (s *Service) uploadLock(id string) *sync.Mutex {
	v, _ := s.locks.LoadOrStore(id, &sync.Mutex{})
	return v.(*sync.Mutex)
}

func safeChild(base, name string) (string, error) {
	name = safename.Sanitize(name)
	if name == "" {
		return "", ErrInvalidName
	}
	p := filepath.Join(base, filepath.Base(name))
	rel, err := filepath.Rel(base, p)
	if err != nil || rel == ".." || filepath.IsAbs(rel) {
		return "", errors.New("file path escapes the job directory")
	}
	return p, nil
}

// hashFile streams the file once and returns its SHA-256 and MD5 hex digests.
func hashFile(path string) (string, string, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", "", fmt.Errorf("open file for hashing: %w", err)
	}
	defer f.Close()
	sha := sha256.New()
	md := md5.New()
	if _, err := io.Copy(io.MultiWriter(sha, md), f); err != nil {
		return "", "", fmt.Errorf("hash file: %w", err)
	}
	return hex.EncodeToString(sha.Sum(nil)), hex.EncodeToString(md.Sum(nil)), nil
}

func randomID() (string, error) {
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return hex.EncodeToString(b), nil
}
FERRY_EOF_36

cat > 'internal/uploads/service_test.go' <<'FERRY_EOF_37'
package uploads

import (
	"errors"
	"testing"
)

func TestCheckQuota(t *testing.T) {
	if err := CheckQuota(4, 6, 10); err != nil {
		t.Fatalf("exact fit rejected: %v", err)
	}
	if err := CheckQuota(5, 6, 10); !errors.Is(err, ErrQuota) {
		t.Fatalf("over-quota error = %v, want ErrQuota", err)
	}
	if err := CheckQuota(0, 10, 10); err != nil {
		t.Fatalf("full-size file rejected: %v", err)
	}
	if err := CheckQuota(0, -1, 10); err == nil {
		t.Fatal("negative size accepted")
	}
}

func TestValidateOffset(t *testing.T) {
	if err := ValidateOffset(0, 0, 10); err != nil {
		t.Fatalf("fresh offset rejected: %v", err)
	}
	if err := ValidateOffset(10, 10, 10); err != nil {
		t.Fatalf("complete offset rejected: %v", err)
	}
	for _, tc := range []struct {
		offset   int64
		received int64
		declared int64
		current  int64
	}{
		{3, 4, 10, 4},
		{5, 4, 10, 4},
		{-1, 0, 10, 0},
		{11, 10, 10, 10},
	} {
		err := ValidateOffset(tc.offset, tc.received, tc.declared)
		var oe *OffsetError
		if !errors.As(err, &oe) {
			t.Fatalf("ValidateOffset(%d,%d,%d) = %v, want OffsetError", tc.offset, tc.received, tc.declared, err)
		}
		if oe.Current != tc.current {
			t.Fatalf("current = %d, want %d", oe.Current, tc.current)
		}
	}
}
FERRY_EOF_37

cat > 'internal/web/handlers.go' <<'FERRY_EOF_38'
package web

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"strings"
	"time"

	"ferry/internal/auth"
	"ferry/internal/db"
	"ferry/internal/downloader"
	"ferry/internal/jobs"
	"ferry/internal/uploads"
)

type indexView struct {
	User            string
	CSRF            string
	Drafts          []db.Job
	Recent          []db.Job
	Current         *db.Job
	CurrentProgress jobs.Progress
	Error           string
}

func (s *Server) handleIndex(w http.ResponseWriter, r *http.Request, session *auth.Session) {
	all, err := s.store.ListJobs(r.Context(), 100)
	if err != nil {
		s.logger.Error("list jobs for home page", "error", err)
		s.renderPageError(w, http.StatusInternalServerError, "Ferry could not read the job list. Check the server logs.")
		return
	}
	view := indexView{User: session.Username, CSRF: session.CSRF}
	if currentID, progress := s.jobs.Current(); currentID != "" {
		if currentJob, err := s.store.GetJob(r.Context(), currentID); err == nil {
			view.Current = currentJob
			view.CurrentProgress = progress
		}
	}
	for _, job := range all {
		if job.State == db.StateDraft {
			view.Drafts = append(view.Drafts, job)
		} else {
			view.Recent = append(view.Recent, job)
		}
		if len(view.Recent) >= 20 {
			break
		}
	}
	s.render(w, http.StatusOK, "index.html", view)
}

func (s *Server) handleJobPage(w http.ResponseWriter, r *http.Request, session *auth.Session) {
	jobID := r.PathValue("jobID")
	if _, err := s.store.GetJob(r.Context(), jobID); err != nil {
		if errors.Is(err, db.ErrNotFound) {
			s.renderPageError(w, http.StatusNotFound, "That transfer does not exist.")
			return
		}
		s.logger.Error("load job page", "error", err)
		s.renderPageError(w, http.StatusInternalServerError, "Ferry could not load that transfer.")
		return
	}
	s.render(w, http.StatusOK, "job.html", map[string]any{
		"User":          session.Username,
		"CSRF":          session.CSRF,
		"JobID":         jobID,
		"MaxTotalBytes": s.cfg.MaxTotalBytes,
		"MaxTotalText":  formatBytes(s.cfg.MaxTotalBytes),
	})
}

func (s *Server) handleHistory(w http.ResponseWriter, r *http.Request, session *auth.Session) {
	jobs, err := s.store.ListJobs(r.Context(), 500)
	if err != nil {
		s.logger.Error("load history", "error", err)
		s.renderPageError(w, http.StatusInternalServerError, "Ferry could not load the transfer history.")
		return
	}
	s.render(w, http.StatusOK, "history.html", map[string]any{
		"User":          session.Username,
		"CSRF":          session.CSRF,
		"Jobs":          jobs,
		"RetentionDays": s.cfg.RetentionDays,
	})
}

type fileJSON struct {
	ID     int64  `json:"id"`
	Name   string `json:"name"`
	Size   int64  `json:"size"`
	SHA256 string `json:"sha256"`
	MD5    string `json:"md5"`
	Source string `json:"source"`
	URL    string `json:"url"`
	Status string `json:"status"`
}

type uploadJSON struct {
	ID               string `json:"id"`
	Filename         string `json:"filename"`
	OriginalFilename string `json:"original_filename"`
	Size             int64  `json:"size"`
	Received         int64  `json:"received"`
}

type progressJSON struct {
	Text  string `json:"text"`
	Done  int64  `json:"done"`
	Total int64  `json:"total"`
}

type jobJSON struct {
	ID            string       `json:"id"`
	State         string       `json:"state"`
	CreatedAt     string       `json:"created_at"`
	UpdatedAt     string       `json:"updated_at"`
	FinishedAt    string       `json:"finished_at,omitempty"`
	TotalBytes    int64        `json:"total_bytes"`
	MaxTotalBytes int64        `json:"max_total_bytes"`
	FileCount     int          `json:"file_count"`
	Image         string       `json:"image"`
	Error         string       `json:"error"`
	Log           string       `json:"log"`
	ImageDeleted  bool         `json:"image_deleted"`
	Files         []fileJSON   `json:"files"`
	Uploads       []uploadJSON `json:"uploads"`
	Progress      progressJSON `json:"progress"`
	CanStart      bool         `json:"can_start"`
	CanCancel     bool         `json:"can_cancel"`
	IsActive      bool         `json:"is_active"`
	Compress      bool         `json:"compress"`
	Encrypted     bool         `json:"encrypted"`
	HasPassphrase bool         `json:"has_passphrase"`
}

func (s *Server) handleCreateJob(w http.ResponseWriter, r *http.Request, _ *auth.Session) {
	id, err := randomJobID()
	if err != nil {
		s.logger.Error("generate job id", "error", err)
		jsonErrorMsg(w, http.StatusInternalServerError, "Could not create a job id.")
		return
	}
	job, err := s.store.CreateJob(r.Context(), id)
	if err != nil {
		s.logger.Error("create job", "error", err)
		jsonErrorMsg(w, http.StatusInternalServerError, "Could not create the transfer in the database.")
		return
	}
	writeJSON(w, http.StatusCreated, map[string]any{"id": job.ID})
}

func (s *Server) handleGetJob(w http.ResponseWriter, r *http.Request, _ *auth.Session) {
	jobID := r.PathValue("jobID")
	job, err := s.store.GetJob(r.Context(), jobID)
	if err != nil {
		s.jobStoreError(w, err)
		return
	}
	files, err := s.store.ListFiles(r.Context(), jobID)
	if err != nil {
		s.logger.Error("list job files", "error", err)
		jsonErrorMsg(w, http.StatusInternalServerError, "Could not read the file list.")
		return
	}
	pending, err := s.store.ListUploads(r.Context(), jobID)
	if err != nil {
		s.logger.Error("list uploads", "error", err)
		jsonErrorMsg(w, http.StatusInternalServerError, "Could not read upload progress.")
		return
	}
	resp := jobJSON{
		ID:            job.ID,
		State:         job.State,
		CreatedAt:     job.CreatedAt.Format(time.RFC3339),
		UpdatedAt:     job.UpdatedAt.Format(time.RFC3339),
		TotalBytes:    job.TotalBytes,
		MaxTotalBytes: s.cfg.MaxTotalBytes,
		FileCount:     job.FileCount,
		Image:         job.Image,
		Error:         job.Error,
		Log:           job.Log,
		ImageDeleted:  job.ImageDeleted,
		IsActive:      db.IsActive(job.State),
		CanCancel:     db.IsActive(job.State),
		Compress:      job.Compress,
		Encrypted:     job.Encrypted,
		HasPassphrase: job.HasPassphrase,
	}
	if !job.FinishedAt.IsZero() {
		resp.FinishedAt = job.FinishedAt.Format(time.RFC3339)
	}
	for _, f := range files {
		resp.Files = append(resp.Files, fileJSON{
			ID: f.ID, Name: f.Name, Size: f.Size, SHA256: f.SHA256, MD5: f.MD5,
			Source: f.Source, URL: f.URL, Status: f.Status,
		})
	}
	for _, u := range pending {
		resp.Uploads = append(resp.Uploads, uploadJSON{
			ID: u.ID, Filename: u.Filename, OriginalFilename: u.OriginalFilename,
			Size: u.DeclaredSize, Received: u.Received,
		})
	}
	p := s.jobs.Progress(jobID)
	resp.Progress = progressJSON{Text: p.Text, Done: p.Done, Total: p.Total}
	resp.CanStart = job.State == db.StateDraft && len(pending) == 0 && len(files) > 0 && job.TotalBytes <= s.cfg.MaxTotalBytes
	writeJSON(w, http.StatusOK, resp)
}

func (s *Server) handleStartJob(w http.ResponseWriter, r *http.Request, _ *auth.Session) {
	jobID := r.PathValue("jobID")
	var body struct {
		Passphrase      string `json:"passphrase"`
		Compress        bool   `json:"compress"`
		ClearPassphrase bool   `json:"clear_passphrase"`
	}
	if err := decodeOptionalJSON(w, r, &body); err != nil {
		jsonErrorMsg(w, http.StatusBadRequest, err.Error())
		return
	}
	if err := s.jobs.SetOptions(r.Context(), jobID, body.Passphrase, body.Compress, body.ClearPassphrase); err != nil {
		if errors.Is(err, db.ErrNotFound) {
			jsonErrorMsg(w, http.StatusNotFound, "That transfer does not exist.")
			return
		}
		jsonErrorMsg(w, http.StatusBadRequest, err.Error())
		return
	}
	if err := s.jobs.StartJob(r.Context(), jobID); err != nil {
		if errors.Is(err, db.ErrNotFound) {
			jsonErrorMsg(w, http.StatusNotFound, "That transfer does not exist.")
			return
		}
		jsonErrorMsg(w, http.StatusBadRequest, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"state": db.StateQueued})
}

func (s *Server) handleCancelJob(w http.ResponseWriter, r *http.Request, _ *auth.Session) {
	jobID := r.PathValue("jobID")
	if err := s.jobs.Cancel(r.Context(), jobID); err != nil {
		if errors.Is(err, db.ErrNotFound) {
			jsonErrorMsg(w, http.StatusNotFound, "That transfer does not exist.")
			return
		}
		jsonErrorMsg(w, http.StatusBadRequest, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"state": "cancelling"})
}

func (s *Server) handleCreateUpload(w http.ResponseWriter, r *http.Request, _ *auth.Session) {
	var body struct {
		Filename string `json:"filename"`
		Size     int64  `json:"size"`
	}
	if err := decodeJSON(w, r, &body); err != nil {
		jsonErrorMsg(w, http.StatusBadRequest, err.Error())
		return
	}
	jobID := r.PathValue("jobID")
	u, err := s.uploads.Create(r.Context(), jobID, body.Filename, body.Size)
	if err != nil {
		switch {
		case errors.Is(err, db.ErrNotFound):
			jsonErrorMsg(w, http.StatusNotFound, "That transfer does not exist.")
		case errors.Is(err, uploads.ErrQuota):
			jsonErrorMsg(w, http.StatusRequestEntityTooLarge,
				fmt.Sprintf("This file would exceed the job size limit of %s. Remove something or raise FERRY_MAX_TOTAL_BYTES.", formatBytes(s.cfg.MaxTotalBytes)))
		case errors.Is(err, uploads.ErrInvalidName):
			jsonErrorMsg(w, http.StatusBadRequest, "That filename is not usable. Use a normal file name.")
		case errors.Is(err, uploads.ErrReservedName):
			jsonErrorMsg(w, http.StatusBadRequest, err.Error())
		default:
			jsonErrorMsg(w, http.StatusBadRequest, err.Error())
		}
		return
	}
	writeJSON(w, http.StatusCreated, map[string]any{
		"upload_id":         u.ID,
		"filename":          u.Filename,
		"original_filename": u.OriginalFilename,
		"size":              u.DeclaredSize,
	})
}

func (s *Server) handleUploadChunk(w http.ResponseWriter, r *http.Request, _ *auth.Session) {
	jobID := r.PathValue("jobID")
	uploadID := r.PathValue("uploadID")
	offset, err := strconv.ParseInt(r.URL.Query().Get("offset"), 10, 64)
	if err != nil || offset < 0 {
		jsonErrorMsg(w, http.StatusBadRequest, "The offset query parameter must be a non-negative whole number.")
		return
	}
	u, err := s.uploads.Get(r.Context(), jobID, uploadID)
	if err != nil {
		s.jobStoreError(w, err)
		return
	}
	if u.Completed {
		jsonErrorMsg(w, http.StatusConflict, "This upload is already complete.")
		return
	}
	if offset != u.Received {
		writeJSON(w, http.StatusConflict, map[string]any{
			"error":    fmt.Sprintf("Upload offset mismatch. The server has %d bytes; resume from there.", u.Received),
			"received": u.Received,
		})
		return
	}
	remaining := u.DeclaredSize - offset
	if remaining < 0 {
		jsonErrorMsg(w, http.StatusConflict, "The offset is beyond the declared file size.")
		return
	}
	// MaxBytesReader guarantees the handler cannot read more than the
	// remaining declared bytes. The upload service enforces the same cap again.
	r.Body = http.MaxBytesReader(w, r.Body, remaining)
	received, err := s.uploads.Append(r.Context(), jobID, uploadID, offset, r.Body)
	if err != nil {
		var oe *uploads.OffsetError
		if errors.As(err, &oe) {
			writeJSON(w, http.StatusConflict, map[string]any{
				"error":    oe.Error(),
				"received": oe.Current,
			})
			return
		}
		var maxErr *http.MaxBytesError
		if errors.As(err, &maxErr) {
			jsonErrorMsg(w, http.StatusRequestEntityTooLarge, "The chunk is larger than the remaining declared file size.")
			return
		}
		jsonErrorMsg(w, http.StatusBadRequest, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"received": received})
}

func (s *Server) handleGetUpload(w http.ResponseWriter, r *http.Request, _ *auth.Session) {
	u, err := s.uploads.Get(r.Context(), r.PathValue("jobID"), r.PathValue("uploadID"))
	if err != nil {
		s.jobStoreError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"received":  u.Received,
		"size":      u.DeclaredSize,
		"completed": u.Completed,
	})
}

func (s *Server) handleCompleteUpload(w http.ResponseWriter, r *http.Request, _ *auth.Session) {
	jobID := r.PathValue("jobID")
	uploadID := r.PathValue("uploadID")
	f, err := s.uploads.Complete(r.Context(), jobID, uploadID)
	if err != nil {
		var oe *uploads.OffsetError
		if errors.As(err, &oe) {
			writeJSON(w, http.StatusConflict, map[string]any{
				"error":    oe.Error(),
				"received": oe.Current,
			})
			return
		}
		if errors.Is(err, db.ErrNotFound) {
			jsonErrorMsg(w, http.StatusNotFound, "That upload does not exist.")
			return
		}
		jsonErrorMsg(w, http.StatusBadRequest, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"id": f.ID, "name": f.Name, "size": f.Size, "sha256": f.SHA256, "md5": f.MD5,
	})
}

func (s *Server) handleDeleteUpload(w http.ResponseWriter, r *http.Request, _ *auth.Session) {
	if err := s.uploads.Delete(r.Context(), r.PathValue("jobID"), r.PathValue("uploadID")); err != nil {
		if errors.Is(err, db.ErrNotFound) {
			jsonErrorMsg(w, http.StatusNotFound, "That upload does not exist.")
			return
		}
		jsonErrorMsg(w, http.StatusBadRequest, err.Error())
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleAddURL(w http.ResponseWriter, r *http.Request, _ *auth.Session) {
	var body struct {
		URL string `json:"url"`
	}
	if err := decodeJSON(w, r, &body); err != nil {
		jsonErrorMsg(w, http.StatusBadRequest, err.Error())
		return
	}
	if _, err := downloader.ValidateURL(body.URL); err != nil {
		jsonErrorMsg(w, http.StatusBadRequest, err.Error())
		return
	}
	jobID := r.PathValue("jobID")
	job, err := s.store.GetJob(r.Context(), jobID)
	if err != nil {
		s.jobStoreError(w, err)
		return
	}
	if job.State != db.StateDraft {
		jsonErrorMsg(w, http.StatusConflict, "URLs can only be added while the job is a draft.")
		return
	}
	if job.TotalBytes >= s.cfg.MaxTotalBytes {
		jsonErrorMsg(w, http.StatusRequestEntityTooLarge, "The job is already at its size limit.")
		return
	}
	f, err := s.store.AddURLFile(r.Context(), jobID, strings.TrimSpace(body.URL))
	if errors.Is(err, db.ErrNotDraft) {
		jsonErrorMsg(w, http.StatusConflict, "The job started before this URL was added. Refresh the page.")
		return
	}
	if err != nil {
		s.logger.Error("add URL", "error", err)
		jsonErrorMsg(w, http.StatusInternalServerError, "Could not save the URL.")
		return
	}
	writeJSON(w, http.StatusCreated, fileJSON{ID: f.ID, Source: f.Source, URL: f.URL, Status: f.Status})
}

func (s *Server) handleDeleteFile(w http.ResponseWriter, r *http.Request, _ *auth.Session) {
	fileID, err := strconv.ParseInt(r.PathValue("fileID"), 10, 64)
	if err != nil || fileID <= 0 {
		jsonErrorMsg(w, http.StatusBadRequest, "Invalid file id.")
		return
	}
	if err := s.uploads.DeleteFile(r.Context(), r.PathValue("jobID"), fileID); err != nil {
		if errors.Is(err, db.ErrNotFound) {
			jsonErrorMsg(w, http.StatusNotFound, "That file entry does not exist.")
			return
		}
		jsonErrorMsg(w, http.StatusBadRequest, err.Error())
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleDeleteImage(w http.ResponseWriter, r *http.Request, _ *auth.Session) {
	if err := s.jobs.DeleteImage(r.Context(), r.PathValue("jobID")); err != nil {
		if errors.Is(err, db.ErrNotFound) {
			jsonErrorMsg(w, http.StatusNotFound, "That transfer does not exist.")
			return
		}
		jsonErrorMsg(w, http.StatusBadRequest, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"deleted": true})
}

func (s *Server) handleDeleteJob(w http.ResponseWriter, r *http.Request, _ *auth.Session) {
	jobID := r.PathValue("jobID")
	job, err := s.store.GetJob(r.Context(), jobID)
	if err != nil {
		s.jobStoreError(w, err)
		return
	}
	if db.IsActive(job.State) {
		jsonErrorMsg(w, http.StatusConflict, "A queued or running transfer cannot be deleted. Wait for it to finish.")
		return
	}
	if err := s.store.DeleteJob(r.Context(), jobID); err != nil {
		s.logger.Error("delete job record", "error", err)
		jsonErrorMsg(w, http.StatusInternalServerError, "Could not delete the transfer record.")
		return
	}
	if err := s.uploads.RemoveJobDir(jobID); err != nil {
		s.logger.Error("remove deleted job directory", "error", err)
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handlePurgeImages(w http.ResponseWriter, r *http.Request, _ *auth.Session) {
	var body struct {
		Days int `json:"days"`
	}
	if err := decodeJSON(w, r, &body); err != nil {
		jsonErrorMsg(w, http.StatusBadRequest, err.Error())
		return
	}
	if body.Days < 1 {
		jsonErrorMsg(w, http.StatusBadRequest, "Enter a number of days of at least 1.")
		return
	}
	deleted, failures, err := s.jobs.PurgeImages(r.Context(), body.Days)
	if err != nil {
		jsonErrorMsg(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"deleted": deleted, "failures": failures})
}

func (s *Server) jobStoreError(w http.ResponseWriter, err error) {
	if errors.Is(err, db.ErrNotFound) {
		jsonErrorMsg(w, http.StatusNotFound, "That transfer or file does not exist.")
		return
	}
	s.logger.Error("job request", "error", err)
	jsonErrorMsg(w, http.StatusInternalServerError, "Ferry could not complete that request. Check the server logs.")
}

// decodeOptionalJSON accepts an empty body as "no options".
func decodeOptionalJSON(w http.ResponseWriter, r *http.Request, dst any) error {
	r.Body = http.MaxBytesReader(w, r.Body, maxJSONBody)
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()
	if err := dec.Decode(dst); err != nil {
		if errors.Is(err, io.EOF) {
			return nil
		}
		return fmt.Errorf("invalid JSON body: %w", err)
	}
	if err := dec.Decode(&struct{}{}); err != io.EOF {
		return errors.New("invalid JSON body: expected a single object")
	}
	return nil
}

func decodeJSON(w http.ResponseWriter, r *http.Request, dst any) error {
	r.Body = http.MaxBytesReader(w, r.Body, maxJSONBody)
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()
	if err := dec.Decode(dst); err != nil {
		return fmt.Errorf("invalid JSON body: %w", err)
	}
	if err := dec.Decode(&struct{}{}); err != io.EOF {
		return errors.New("invalid JSON body: expected a single object")
	}
	return nil
}

func randomJobID() (string, error) {
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return hex.EncodeToString(b), nil
}
FERRY_EOF_38

cat > 'internal/web/server.go' <<'FERRY_EOF_39'
// Package web serves Ferry's HTML pages and JSON API.
package web

import (
	"bytes"
	"encoding/json"
	"fmt"
	"html/template"
	"io/fs"
	"log/slog"
	"net"
	"net/http"
	"strings"
	"time"

	"ferry/internal/auth"
	"ferry/internal/config"
	"ferry/internal/db"
	"ferry/internal/jobs"
	"ferry/internal/uploads"
	webassets "ferry/web"
)

const maxJSONBody = 64 << 10

// Server holds all HTTP dependencies.
type Server struct {
	cfg     *config.Config
	store   *db.Store
	auth    *auth.Manager
	limiter *auth.Limiter
	uploads *uploads.Service
	jobs    *jobs.Manager
	logger  *slog.Logger

	templates *template.Template
	static    http.Handler
}

// New parses embedded assets and returns a server.
func New(cfg *config.Config, store *db.Store, sessions *auth.Manager,
	uploadSvc *uploads.Service, manager *jobs.Manager, logger *slog.Logger, version string) (*Server, error) {

	funcs := template.FuncMap{
		"version":    func() string { return version },
		"bytes":      formatBytes,
		"time":       formatTime,
		"state":      stateLabel,
		"isActive":   db.IsActive,
		"isTerminal": db.IsTerminal,
	}
	tmpl, err := template.New("ferry").Funcs(funcs).ParseFS(webassets.FS, "templates/*.html")
	if err != nil {
		return nil, fmt.Errorf("parse templates: %w", err)
	}
	staticFS, err := fs.Sub(webassets.FS, "static")
	if err != nil {
		return nil, fmt.Errorf("open static assets: %w", err)
	}
	staticHandler := http.StripPrefix("/static/", http.FileServer(http.FS(staticFS)))
	s := &Server{
		cfg:       cfg,
		store:     store,
		auth:      sessions,
		limiter:   auth.NewLimiter(),
		uploads:   uploadSvc,
		jobs:      manager,
		logger:    logger,
		templates: tmpl,
		static:    staticHandler,
	}
	return s, nil
}

// Handler returns the fully wrapped HTTP handler.
func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /health", s.handleHealth)
	mux.HandleFunc("GET /login", s.handleLoginPage)
	mux.HandleFunc("POST /login", s.handleLoginSubmit)
	mux.HandleFunc("GET /static/", s.handleStatic)
	mux.HandleFunc("POST /logout", s.pageAuth(s.handleLogout))
	mux.HandleFunc("GET /{$}", s.pageAuth(s.handleIndex))
	mux.HandleFunc("GET /jobs/{jobID}", s.pageAuth(s.handleJobPage))
	mux.HandleFunc("GET /history", s.pageAuth(s.handleHistory))

	mux.HandleFunc("POST /api/jobs", s.apiAuth(s.handleCreateJob))
	mux.HandleFunc("GET /api/jobs/{jobID}", s.apiAuth(s.handleGetJob))
	mux.HandleFunc("POST /api/jobs/{jobID}/start", s.apiAuth(s.handleStartJob))
	mux.HandleFunc("POST /api/jobs/{jobID}/cancel", s.apiAuth(s.handleCancelJob))
	mux.HandleFunc("POST /api/jobs/{jobID}/uploads", s.apiAuth(s.handleCreateUpload))
	mux.HandleFunc("PUT /api/jobs/{jobID}/uploads/{uploadID}", s.apiAuth(s.handleUploadChunk))
	mux.HandleFunc("GET /api/jobs/{jobID}/uploads/{uploadID}", s.apiAuth(s.handleGetUpload))
	mux.HandleFunc("POST /api/jobs/{jobID}/uploads/{uploadID}/complete", s.apiAuth(s.handleCompleteUpload))
	mux.HandleFunc("DELETE /api/jobs/{jobID}/uploads/{uploadID}", s.apiAuth(s.handleDeleteUpload))
	mux.HandleFunc("POST /api/jobs/{jobID}/urls", s.apiAuth(s.handleAddURL))
	mux.HandleFunc("DELETE /api/jobs/{jobID}/files/{fileID}", s.apiAuth(s.handleDeleteFile))
	mux.HandleFunc("POST /api/jobs/{jobID}/image-delete", s.apiAuth(s.handleDeleteImage))
	mux.HandleFunc("DELETE /api/jobs/{jobID}", s.apiAuth(s.handleDeleteJob))
	mux.HandleFunc("POST /api/history/purge-images", s.apiAuth(s.handlePurgeImages))

	return s.securityHeaders(s.logRequests(mux))
}

type authedHandler func(http.ResponseWriter, *http.Request, *auth.Session)

func (s *Server) pageAuth(next authedHandler) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		session := s.auth.FromRequest(r)
		if session == nil {
			http.Redirect(w, r, "/login", http.StatusSeeOther)
			return
		}
		w.Header().Set("Cache-Control", "no-store")
		next(w, r, session)
	}
}

func (s *Server) apiAuth(next authedHandler) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		session := s.auth.FromRequest(r)
		if session == nil {
			writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "Your session has expired. Reload the page and log in again."})
			return
		}
		if r.Method != http.MethodGet && r.Method != http.MethodHead {
			header := r.Header.Get("X-Requested-With")
			token := r.Header.Get("X-CSRF-Token")
			if header != "Ferry" || !auth.SecureCompare(token, session.CSRF) {
				writeJSON(w, http.StatusForbidden, map[string]string{"error": "Request rejected by CSRF protection. Reload the page and try again."})
				return
			}
		}
		w.Header().Set("Cache-Control", "no-store")
		next(w, r, session)
	}
}

func (s *Server) handleStatic(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "public, max-age=3600")
	s.static.ServeHTTP(w, r)
}

func (s *Server) securityHeaders(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("X-Frame-Options", "DENY")
		w.Header().Set("Referrer-Policy", "no-referrer")
		w.Header().Set("Content-Security-Policy",
			"default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; "+
				"connect-src 'self'; font-src 'self'; object-src 'none'; base-uri 'none'; "+
				"form-action 'self'; frame-ancestors 'none'")
		next.ServeHTTP(w, r)
	})
}

func (s *Server) logRequests(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		next.ServeHTTP(w, r)
		s.logger.Debug("http request", "method", r.Method, "path", r.URL.Path,
			"remote", clientIP(r, s.cfg.TrustProxy), "duration", time.Since(start).String())
	})
}

func (s *Server) handleHealth(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write([]byte("ok"))
}

func (s *Server) handleLoginPage(w http.ResponseWriter, r *http.Request) {
	if s.auth.FromRequest(r) != nil {
		http.Redirect(w, r, "/", http.StatusSeeOther)
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	s.render(w, http.StatusOK, "login.html", map[string]any{})
}

func (s *Server) handleLoginSubmit(w http.ResponseWriter, r *http.Request) {
	r.Body = http.MaxBytesReader(w, r.Body, maxJSONBody)
	if err := r.ParseForm(); err != nil {
		s.renderLoginError(w, http.StatusBadRequest, "The login form could not be read.", "")
		return
	}
	ip := clientIP(r, s.cfg.TrustProxy)
	if blocked, remaining := s.limiter.Blocked(ip); blocked {
		minutes := int(remaining.Minutes()) + 1
		s.renderLoginError(w, http.StatusTooManyRequests,
			fmt.Sprintf("Too many failed login attempts. Try again in about %d minute(s).", minutes), "")
		return
	}
	username := r.PostFormValue("username")
	password := r.PostFormValue("password")
	userOK := auth.SecureCompare(username, s.cfg.Username)
	passOK, verifyErr := auth.VerifyPassword(password, s.cfg.PasswordHash, s.cfg.Password)
	if verifyErr != nil {
		s.logger.Error("password hash is invalid", "error", verifyErr)
	}
	if !userOK || !passOK {
		s.limiter.Failure(ip)
		s.renderLoginError(w, http.StatusUnauthorized, "Incorrect username or password.", username)
		return
	}
	s.limiter.Success(ip)
	_, token, err := s.auth.NewSession()
	if err != nil {
		s.logger.Error("create session", "error", err)
		s.renderLoginError(w, http.StatusInternalServerError, "Could not create a login session. Try again.", username)
		return
	}
	s.auth.SetCookie(w, token)
	http.Redirect(w, r, "/", http.StatusSeeOther)
}

func (s *Server) renderLoginError(w http.ResponseWriter, status int, message, username string) {
	w.Header().Set("Cache-Control", "no-store")
	s.render(w, status, "login.html", map[string]any{"Error": message, "Username": username})
}

func (s *Server) handleLogout(w http.ResponseWriter, r *http.Request, session *auth.Session) {
	r.Body = http.MaxBytesReader(w, r.Body, maxJSONBody)
	if err := r.ParseForm(); err != nil {
		http.Error(w, "The logout form could not be read.", http.StatusBadRequest)
		return
	}
	if !auth.SecureCompare(r.PostFormValue("_csrf"), session.CSRF) {
		http.Error(w, "Request rejected by CSRF protection.", http.StatusForbidden)
		return
	}
	s.auth.ClearCookie(w)
	http.Redirect(w, r, "/login", http.StatusSeeOther)
}

func (s *Server) render(w http.ResponseWriter, status int, name string, data any) {
	var buf bytes.Buffer
	if err := s.templates.ExecuteTemplate(&buf, name, data); err != nil {
		s.logger.Error("render template", "template", name, "error", err)
		if status == http.StatusOK {
			status = http.StatusInternalServerError
		}
		http.Error(w, "Ferry could not render this page. Check the server logs.", status)
		return
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.WriteHeader(status)
	_, _ = w.Write(buf.Bytes())
}

func (s *Server) renderPageError(w http.ResponseWriter, status int, message string) {
	s.render(w, status, "error.html", map[string]any{
		"Error": message,
		"Title": http.StatusText(status),
	})
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	enc := json.NewEncoder(w)
	enc.SetEscapeHTML(true)
	_ = enc.Encode(v)
}

func jsonErrorMsg(w http.ResponseWriter, status int, message string) {
	writeJSON(w, status, map[string]string{"error": message})
}

func clientIP(r *http.Request, trustProxy bool) string {
	if trustProxy {
		if xff := r.Header.Get("X-Forwarded-For"); xff != "" {
			parts := strings.Split(xff, ",")
			// Caddy appends the real peer to the right. Take the last valid
			// entry so a client-supplied prefix cannot spoof the address.
			for i := len(parts) - 1; i >= 0; i-- {
				candidate := strings.TrimSpace(parts[i])
				if ip := net.ParseIP(candidate); ip != nil {
					return ip.String()
				}
			}
		}
	}
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}
	return host
}

func formatBytes(n int64) string {
	if n < 0 {
		return "0 B"
	}
	const unit = 1024
	if n < unit {
		return fmt.Sprintf("%d B", n)
	}
	div, exp := int64(unit), 0
	for v := n / unit; v >= unit; v /= unit {
		div *= unit
		exp++
	}
	return fmt.Sprintf("%.1f %ciB", float64(n)/float64(div), "KMGTPE"[exp])
}

func formatTime(t time.Time) string {
	if t.IsZero() {
		return "—"
	}
	return t.Local().Format("2006-01-02 15:04")
}

func stateLabel(state string) string {
	if state == "" {
		return "Unknown"
	}
	return strings.ToUpper(state[:1]) + state[1:]
}
FERRY_EOF_39

cat > 'web/embed.go' <<'FERRY_EOF_40'
// Package webassets embeds Ferry's HTML templates and static files.
package webassets

import "embed"

// FS contains templates/*.html and static/*.
//
//go:embed templates/*.html static/*
var FS embed.FS
FERRY_EOF_40

cat > 'web/static/app.js' <<'FERRY_EOF_41'
'use strict';

(() => {
  const page = document.body.dataset.page;
  const csrf = document.querySelector('meta[name="csrf-token"]')?.content || '';
  const CHUNK_SIZE = 8 * 1024 * 1024;

  class ApiError extends Error {
    constructor(message, status, data) {
      super(message);
      this.name = 'ApiError';
      this.status = status;
      this.data = data;
    }
  }

  async function api(url, options = {}) {
    const { json, ...fetchOptions } = options;
    const headers = new Headers(fetchOptions.headers || {});
    headers.set('X-Requested-With', 'Ferry');
    headers.set('X-CSRF-Token', csrf);
    let body = fetchOptions.body;
    if (json !== undefined) {
      headers.set('Content-Type', 'application/json');
      body = JSON.stringify(json);
    }
    let response;
    try {
      response = await fetch(url, {
        ...fetchOptions,
        body,
        headers,
        credentials: 'same-origin',
      });
    } catch {
      throw new ApiError('Could not reach Ferry. Check your connection and try again.', 0, null);
    }
    let data = null;
    const type = response.headers.get('content-type') || '';
    if (type.includes('application/json')) {
      try {
        data = await response.json();
      } catch {
        data = null;
      }
    }
    if (!response.ok) {
      if (response.status === 401) {
        window.location.assign('/login');
      }
      throw new ApiError(
        (data && data.error) || `Request failed (HTTP ${response.status}).`,
        response.status,
        data
      );
    }
    return data;
  }

  function formatBytes(bytes) {
    const n = Number(bytes) || 0;
    if (n < 0) return '0 B';
    const units = ['B', 'KiB', 'MiB', 'GiB', 'TiB', 'PiB'];
    if (n < 1024) return `${n} B`;
    let value = n;
    let unit = 0;
    while (value >= 1024 && unit < units.length - 1) {
      value /= 1024;
      unit += 1;
    }
    return `${value.toFixed(value >= 100 ? 0 : 1)} ${units[unit]}`;
  }

  function sleep(ms) {
    return new Promise((resolve) => window.setTimeout(resolve, ms));
  }

  function showError(message) {
    const el = document.getElementById('page-error');
    if (!el) return;
    el.textContent = message || 'Something went wrong.';
    el.hidden = false;
  }

  function clearError() {
    const el = document.getElementById('page-error');
    if (!el) return;
    el.hidden = true;
    el.textContent = '';
  }

  async function copyText(text, button) {
    let ok = false;
    try {
      await navigator.clipboard.writeText(text);
      ok = true;
    } catch {
      const area = document.createElement('textarea');
      area.value = text;
      area.setAttribute('readonly', '');
      area.className = 'visually-hidden';
      document.body.appendChild(area);
      area.select();
      try {
        ok = document.execCommand('copy');
      } catch {
        ok = false;
      }
      area.remove();
    }
    if (button) {
      const old = button.textContent;
      button.textContent = ok ? 'Copied!' : 'Copy failed';
      window.setTimeout(() => { button.textContent = old; }, 1600);
    }
    if (!ok) showError('Copying to the clipboard was blocked by the browser. Select the text and copy it manually.');
  }

  function setBusy(button, busy) {
    if (!button) return;
    button.disabled = busy;
    button.setAttribute('aria-busy', busy ? 'true' : 'false');
  }

  function bindCancelButtons() {
    document.querySelectorAll('.js-cancel-job').forEach((button) => {
      if (button.dataset.bound === 'true') return;
      button.dataset.bound = 'true';
      button.addEventListener('click', async () => {
        const id = button.dataset.jobId;
        if (!id) return;
        if (!window.confirm('Cancel this transfer? Temporary files will be deleted.')) return;
        clearError();
        setBusy(button, true);
        try {
          await api(`/api/jobs/${encodeURIComponent(id)}/cancel`, { method: 'POST' });
          window.location.reload();
        } catch (err) {
          showError(err.message);
          setBusy(button, false);
        }
      });
    });
  }

  function initIndex() {
    bindCancelButtons();
    const button = document.getElementById('new-transfer');
    if (!button) return;
    button.addEventListener('click', async () => {
      clearError();
      setBusy(button, true);
      try {
        const data = await api('/api/jobs', { method: 'POST' });
        window.location.assign(`/jobs/${encodeURIComponent(data.id)}`);
      } catch (err) {
        showError(err.message);
        setBusy(button, false);
      }
    });
  }

  function initHistory() {
    bindCancelButtons();
    document.querySelectorAll('.js-delete-image').forEach((button) => {
      button.addEventListener('click', async () => {
        const id = button.dataset.jobId;
        if (!id) return;
        if (!window.confirm('Delete this image tag from Docker Hub? The history record will stay.')) return;
        clearError();
        setBusy(button, true);
        try {
          await api(`/api/jobs/${encodeURIComponent(id)}/image-delete`, { method: 'POST' });
          window.location.reload();
        } catch (err) {
          showError(err.message);
          setBusy(button, false);
        }
      });
    });

    document.querySelectorAll('.js-delete-record').forEach((button) => {
      button.addEventListener('click', async () => {
        const id = button.dataset.jobId;
        if (!id) return;
        if (!window.confirm('Delete this history record? Any Docker Hub image tag is NOT deleted by this action.')) return;
        clearError();
        setBusy(button, true);
        try {
          await api(`/api/jobs/${encodeURIComponent(id)}`, { method: 'DELETE' });
          window.location.reload();
        } catch (err) {
          showError(err.message);
          setBusy(button, false);
        }
      });
    });

    const purgeForm = document.getElementById('purge-form');
    if (purgeForm) {
      purgeForm.addEventListener('submit', async (event) => {
        event.preventDefault();
        const daysInput = document.getElementById('purge-days');
        const days = Number.parseInt(daysInput?.value || '', 10);
        if (!Number.isInteger(days) || days < 1) {
          showError('Enter a number of days of at least 1.');
          return;
        }
        if (!window.confirm(`Delete every Docker Hub image older than ${days} day(s)? History records stay.`)) return;
        clearError();
        const button = purgeForm.querySelector('button');
        setBusy(button, true);
        try {
          const result = await api('/api/history/purge-images', { method: 'POST', json: { days } });
          if (result.failures && result.failures.length) {
            showError(`Deleted ${result.deleted} image(s). Some failed:\n${result.failures.join('\n')}`);
            setBusy(button, false);
          } else {
            window.location.reload();
          }
        } catch (err) {
          showError(err.message);
          setBusy(button, false);
        }
      });
    }
  }

  function initJob() {
    const jobId = document.body.dataset.jobId;
    if (!jobId) return;
    const maxBytes = Number(document.body.dataset.maxBytes) || 0;

    const els = {
      state: document.getElementById('job-state'),
      draft: document.getElementById('draft-panel'),
      run: document.getElementById('run-panel'),
      done: document.getElementById('done-panel'),
      failed: document.getElementById('failed-panel'),
      runState: document.getElementById('run-state'),
      progress: document.getElementById('job-progress'),
      percent: document.getElementById('progress-percent'),
      progressText: document.getElementById('progress-text'),
      log: document.getElementById('job-log'),
      doneLog: document.getElementById('done-log'),
      failedLog: document.getElementById('failed-log'),
      failure: document.getElementById('failure-message'),
      image: document.getElementById('image-name'),
      imageDeleted: document.getElementById('image-deleted-note'),
      commands: document.getElementById('pull-commands'),
      copyImage: document.getElementById('copy-image'),
      copyCommands: document.getElementById('copy-commands'),
      totalText: document.getElementById('total-text'),
      totalProgress: document.getElementById('total-progress'),
      uploadList: document.getElementById('upload-list'),
      entryList: document.getElementById('entry-list'),
      start: document.getElementById('start-button'),
      startHint: document.getElementById('start-hint'),
      fileInput: document.getElementById('file-input'),
      dropzone: document.getElementById('dropzone'),
      urlForm: document.getElementById('url-form'),
      urlInput: document.getElementById('url-input'),
      cancel: document.getElementById('cancel-button'),
      passphrase: document.getElementById('passphrase'),
      passphraseConfirm: document.getElementById('passphrase-confirm'),
      clearPassphrase: document.getElementById('clear-passphrase'),
      clearPassphraseRow: document.getElementById('clear-passphrase-row'),
      compress: document.getElementById('compress'),
      optionsState: document.getElementById('options-state'),
      runOptions: document.getElementById('run-options'),
    };

    const base = `/api/jobs/${encodeURIComponent(jobId)}`;
    let latest = null;
    let active = null;
    let uploading = false;
    let polling = false;
    let sameOffsetRetries = 0;
    let pendingResume = null;
    let pollTimer = null;
    let draftSignature = '';
    let optionsInitialized = false;

    els.copyImage?.addEventListener('click', () => copyText((latest && latest.image) || '', els.copyImage));

    els.cancel?.addEventListener('click', async () => {
      if (!window.confirm('Cancel this transfer? Temporary files will be deleted.')) return;
      clearError();
      setBusy(els.cancel, true);
      try {
        await api(`${base}/cancel`, { method: 'POST' });
        await refresh();
      } catch (err) {
        showError(err.message);
        setBusy(els.cancel, false);
      }
    });
    els.copyCommands?.addEventListener('click', () => copyText(els.commands?.textContent || '', els.copyCommands));

    function terminal(state) {
      return state === 'done' || state === 'failed';
    }

    function render(data) {
      if (!data) return;
      latest = data;
      els.state.textContent = data.state;
      els.state.className = `badge badge-${data.state}`;
      els.draft.hidden = data.state !== 'draft';
      els.run.hidden = !['queued', 'downloading', 'building', 'pushing'].includes(data.state);
      els.done.hidden = data.state !== 'done';
      els.failed.hidden = data.state !== 'failed';
      if (data.state === 'draft') renderDraft(data);
      if (data.state !== 'draft' && els.runOptions) {
        const parts = [];
        if (data.compress) parts.push('gzip compression');
        if (data.encrypted) parts.push('passphrase encryption');
        els.runOptions.hidden = parts.length === 0;
        els.runOptions.textContent = parts.length ? `File options: ${parts.join(' + ')}.` : '';
      }
      if (!['queued', 'downloading', 'building', 'pushing'].includes(data.state) && els.run.hidden === false) {
        els.run.hidden = true;
      }
      if (['queued', 'downloading', 'building', 'pushing'].includes(data.state)) {
        renderRun(data);
        if (els.cancel) {
          els.cancel.disabled = !data.can_cancel || data.progress?.text === 'Cancelling...';
        }
      }
      if (data.state === 'done') renderDone(data);
      if (data.state === 'failed') {
        els.failure.textContent = data.error || 'The worker reported an error. Check the log below.';
        setLog(els.failedLog, data.log);
      }
    }

    function renderDraft(data) {
      const total = Number(data.total_bytes) || 0;
      els.totalText.textContent = `${formatBytes(total)} / ${formatBytes(maxBytes)}`;
      els.totalProgress.max = maxBytes || 1;
      els.totalProgress.value = Math.min(total, maxBytes || 1);

      const uploads = data.uploads || [];
      const files = data.files || [];
      const signature = JSON.stringify([
        uploads.map((u) => [u.id, u.received, u.size]),
        files.map((f) => [f.id, f.name, f.size, f.status]),
        active ? [active.id, active.received, active.error || ''] : null,
      ]);
      if (signature !== draftSignature) {
        draftSignature = signature;
        els.uploadList.replaceChildren();
        for (const upload of uploads) {
          if (active && active.id === upload.id) continue;
          els.uploadList.appendChild(serverUploadRow(upload));
        }
        if (active) els.uploadList.appendChild(activeUploadRow(active));

        els.entryList.replaceChildren();
        for (const file of files) {
          els.entryList.appendChild(fileRow(file));
        }
        if (!files.length && !uploads.length && !active) {
          const empty = document.createElement('p');
          empty.className = 'muted';
          empty.textContent = 'No files or URLs added yet.';
          els.entryList.appendChild(empty);
        }
      }

      const pending = uploads.length;
      let hint = 'Ready to start.';
      if (active && active.error) hint = 'The last upload failed. Use Resume or Remove.';
      else if (uploading || active) hint = 'Upload in progress. Start is available when it finishes.';
      else if (pending > 0) hint = `${pending} incomplete upload(s). Resume by choosing the same file again, or remove them.`;
      else if (!files.length) hint = 'Add at least one file or URL.';
      else if (total > maxBytes) hint = 'The job is over the size limit. Remove something before starting.';
      els.startHint.textContent = hint;
      els.start.disabled = uploading || !!active || !data.can_start;
      if (!optionsInitialized && els.compress) {
        els.compress.checked = !!data.compress;
        optionsInitialized = true;
      }
      if (els.clearPassphraseRow) {
        els.clearPassphraseRow.hidden = !data.has_passphrase;
        if (!data.has_passphrase && els.clearPassphrase) els.clearPassphrase.checked = false;
      }
      if (els.optionsState) {
        const saved = [];
        if (data.compress) saved.push('compression on');
        if (data.has_passphrase) saved.push('a passphrase is saved');
        els.optionsState.textContent = saved.length ? `Saved: ${saved.join(', ')}. Leave the passphrase empty to keep it.` : '';
      }
      els.start.setAttribute('aria-busy', uploading ? 'true' : 'false');
    }

    function serverUploadRow(upload) {
      const row = document.createElement('div');
      row.className = 'entry';
      const main = document.createElement('div');
      main.className = 'entry-main';
      const name = document.createElement('div');
      name.className = 'entry-name';
      name.textContent = upload.filename;
      const meta = document.createElement('div');
      meta.className = 'entry-meta';
      meta.textContent = `${formatBytes(upload.received)} of ${formatBytes(upload.size)} received · incomplete`;
      main.append(name, meta);
      const actions = document.createElement('div');
      actions.className = 'entry-actions';
      const resume = document.createElement('button');
      resume.type = 'button';
      resume.className = 'button button-small';
      resume.textContent = 'Resume';
      resume.addEventListener('click', () => {
        pendingResume = upload;
        els.fileInput.click();
      });
      const remove = document.createElement('button');
      remove.type = 'button';
      remove.className = 'button button-small button-quiet';
      remove.textContent = 'Remove';
      remove.addEventListener('click', async () => {
        if (!window.confirm(`Remove the incomplete upload "${upload.filename}"?`)) return;
        setBusy(remove, true);
        try {
          await api(`${base}/uploads/${encodeURIComponent(upload.id)}`, { method: 'DELETE' });
          await refresh();
        } catch (err) {
          showError(err.message);
          setBusy(remove, false);
        }
      });
      actions.append(resume, remove);
      row.append(main, actions);
      return row;
    }

    function activeUploadRow(upload) {
      const row = document.createElement('div');
      row.className = 'entry';
      const main = document.createElement('div');
      main.className = 'entry-main';
      const name = document.createElement('div');
      name.className = 'entry-name';
      name.textContent = upload.filename;
      const meta = document.createElement('div');
      meta.className = 'entry-meta';
      const percent = upload.size > 0 ? Math.min(100, Math.floor((upload.received / upload.size) * 100)) : 100;
      meta.textContent = `${formatBytes(upload.received)} of ${formatBytes(upload.size)} · ${percent}%`;
      const progress = document.createElement('progress');
      progress.max = upload.size || 1;
      progress.value = Math.min(upload.received, upload.size || 1);
      progress.setAttribute('aria-label', `Upload progress for ${upload.filename}`);
      main.append(name, meta, progress);
      if (upload.error) {
        const err = document.createElement('div');
        err.className = 'entry-error';
        err.textContent = upload.error;
        main.appendChild(err);
      }
      const actions = document.createElement('div');
      actions.className = 'entry-actions';
      if (upload.error && upload.file) {
        const resume = document.createElement('button');
        resume.type = 'button';
        resume.className = 'button button-small';
        resume.textContent = 'Resume';
        resume.addEventListener('click', () => resumeUpload(upload));
        actions.appendChild(resume);
      }
      const remove = document.createElement('button');
      remove.type = 'button';
      remove.className = 'button button-small button-quiet';
      remove.textContent = 'Remove';
      remove.disabled = uploading;
      remove.addEventListener('click', async () => {
        if (!window.confirm(`Remove the incomplete upload "${upload.filename}"?`)) return;
        setBusy(remove, true);
        try {
          await api(`${base}/uploads/${encodeURIComponent(upload.id)}`, { method: 'DELETE' });
          active = null;
          await refresh();
        } catch (err) {
          showError(err.message);
          setBusy(remove, false);
        }
      });
      actions.appendChild(remove);
      row.append(main, actions);
      return row;
    }

    function fileRow(file) {
      const row = document.createElement('div');
      row.className = 'entry';
      const main = document.createElement('div');
      main.className = 'entry-main';
      const name = document.createElement('div');
      name.className = 'entry-name';
      name.textContent = file.status === 'done' ? file.name : file.url;
      const meta = document.createElement('div');
      meta.className = 'entry-meta';
      if (file.status === 'done') {
        meta.textContent = `${file.source === 'url' ? 'Downloaded URL' : 'Uploaded file'} · ${formatBytes(file.size)}`;
        if (file.sha256) meta.textContent += ` · sha256 ${file.sha256.slice(0, 16)}…`;
        if (file.md5) meta.textContent += ` · md5 ${file.md5}`;
      } else {
        meta.textContent = 'Download link · downloaded when the transfer starts';
      }
      main.append(name, meta);
      const actions = document.createElement('div');
      actions.className = 'entry-actions';
      const remove = document.createElement('button');
      remove.type = 'button';
      remove.className = 'button button-small button-quiet';
      remove.textContent = 'Remove';
      remove.addEventListener('click', async () => {
        if (!window.confirm('Remove this entry from the transfer?')) return;
        setBusy(remove, true);
        try {
          await api(`${base}/files/${encodeURIComponent(file.id)}`, { method: 'DELETE' });
          await refresh();
        } catch (err) {
          showError(err.message);
          setBusy(remove, false);
        }
      });
      actions.appendChild(remove);
      row.append(main, actions);
      return row;
    }

    function renderRun(data) {
      els.runState.textContent = data.progress?.text || data.state;
      const progress = data.progress || { done: 0, total: 0, text: '' };
      els.progress.removeAttribute('value');
      if (progress.total > 0) {
        els.progress.max = progress.total;
        els.progress.value = Math.min(progress.done || 0, progress.total);
        const pct = Math.min(100, Math.floor(((progress.done || 0) / progress.total) * 100));
        els.percent.textContent = `${pct}% · ${formatBytes(progress.done || 0)} / ${formatBytes(progress.total)}`;
      } else if (progress.done > 0) {
        els.progress.removeAttribute('value');
        els.percent.textContent = formatBytes(progress.done);
      } else {
        els.percent.textContent = '';
      }
      els.progressText.textContent = progress.text || `State: ${data.state}`;
      setLog(els.log, data.log);
    }

    function renderDone(data) {
      els.image.textContent = data.image || '—';
      els.imageDeleted.hidden = !data.image_deleted;
      const image = data.image || '<image>';
      const lines = [
        'docker login',
        `docker pull ${image}`,
        `docker create --name ferry-tmp ${image}`,
        'docker cp ferry-tmp:/data ./ferry-files',
        'docker rm ferry-tmp',
      ];
      if (data.encrypted || data.compress) {
        lines.push(`docker run --rm -it -v "$PWD/ferry-files:/work" --entrypoint /data/ferry ${image} unpack --dir /work`);
      }
      lines.push('cd ferry-files');
      lines.push('sha256sum -c SHA256SUMS');
      els.commands.textContent = lines.join('\n');
      setLog(els.doneLog, data.log);
    }

    function setLog(element, text) {
      if (!element) return;
      const nearBottom = element.scrollTop + element.clientHeight >= element.scrollHeight - 40;
      element.textContent = text && text.trim() ? text : 'Waiting…';
      if (nearBottom) element.scrollTop = element.scrollHeight;
    }

    async function refresh() {
      const data = await api(base, { method: 'GET' });
      render(data);
      return data;
    }

    async function uploadFiles(fileList) {
      if (uploading) return;
      const files = Array.from(fileList || []);
      if (!files.length) return;

      if (pendingResume) {
        const upload = pendingResume;
        pendingResume = null;
        const wanted = upload.original_filename || upload.filename;
        const match = files.find((f) => f.name === wanted && f.size === upload.size);
        if (!match) {
          showError(`Choose the original file "${wanted}" (${formatBytes(upload.size)}) to resume this upload.`);
          return;
        }
        uploading = true;
        active = { ...upload, file: match, error: '' };
        sameOffsetRetries = 0;
        clearError();
        try {
          await continueUpload();
        } catch (err) {
          if (active) active.error = err.message;
          showError(err.message);
        } finally {
          uploading = false;
          await refresh().catch((err) => showError(err.message));
        }
        return;
      }

      uploading = true;
      clearError();
      let projected = Number(latest && latest.total_bytes) || 0;
      try {
        for (const file of files) {
          if (projected + file.size > maxBytes) {
            showError(`"${file.name}" would exceed the ${formatBytes(maxBytes)} job limit.`);
            continue;
          }
          try {
            sameOffsetRetries = 0;
            const created = await startUpload(file);
            projected += Number(created && created.size) || file.size;
          } catch (err) {
            if (active) active.error = err.message;
            showError(err.message);
          }
        }
      } finally {
        uploading = false;
        await refresh().catch((err) => showError(err.message));
      }
    }

    async function startUpload(file) {
      const created = await api(`${base}/uploads`, {
        method: 'POST',
        json: { filename: file.name, size: file.size },
      });
      active = {
        id: created.upload_id,
        filename: created.filename,
        size: file.size,
        received: 0,
        file,
        error: '',
      };
      if (latest) renderDraft(latest);
      await continueUpload();
      return created;
    }

    async function resumeUpload(upload) {
      if (uploading || !upload.file) return;
      uploading = true;
      active = upload;
      active.error = '';
      sameOffsetRetries = 0;
      clearError();
      try {
        await continueUpload();
      } catch (err) {
        active.error = err.message;
        showError(err.message);
      } finally {
        uploading = false;
        await refresh().catch((err) => showError(err.message));
      }
    }

    async function continueUpload() {
      if (!active) return;
      const upload = active;
      let state;
      try {
        state = await api(`${base}/uploads/${encodeURIComponent(upload.id)}`, { method: 'GET' });
      } catch (err) {
        upload.error = err.message;
        throw err;
      }
      if (state.completed) {
        active = null;
        return;
      }
      upload.received = Number(state.received) || 0;
      if (latest) renderDraft(latest);

      while (upload.received < upload.size) {
        const offset = upload.received;
        const end = Math.min(offset + CHUNK_SIZE, upload.size);
        const blob = upload.file.slice(offset, end);
        let result;
        try {
          result = await putChunkWithRetries(upload.id, offset, blob);
        } catch (err) {
          upload.error = err.message;
          throw err;
        }
        if (result.completed) {
          active = null;
          return;
        }
        if (typeof result.received !== 'number') {
          throw new Error('The server did not return upload progress.');
        }
        if (result.received <= offset) {
          sameOffsetRetries += 1;
          if (sameOffsetRetries > 3) {
            throw new Error('The server did not accept the next chunk. Remove this upload and try again.');
          }
        } else {
          sameOffsetRetries = 0;
        }
        upload.received = result.received;
        if (latest) renderDraft(latest);
      }
      sameOffsetRetries = 0;
      await api(`${base}/uploads/${encodeURIComponent(upload.id)}/complete`, { method: 'POST' });
      active = null;
    }

    async function putChunkWithRetries(uploadId, offset, blob) {
      const url = `${base}/uploads/${encodeURIComponent(uploadId)}?offset=${offset}`;
      let delay = 500;
      for (let attempt = 1; attempt <= 5; attempt += 1) {
        try {
          return await api(url, {
            method: 'PUT',
            body: blob,
            headers: { 'Content-Type': 'application/octet-stream' },
          });
        } catch (err) {
          if (err.status === 409) {
            const received = Number(err.data && err.data.received);
            if (Number.isFinite(received) && received >= 0) {
              return { received, conflict: true };
            }
            throw err;
          }
          const permanent = [400, 401, 403, 404, 413].includes(err.status);
          if (permanent || attempt === 5) throw err;
          await sleep(delay);
          delay *= 2;
          try {
            const state = await api(`${base}/uploads/${encodeURIComponent(uploadId)}`, { method: 'GET' });
            if (state.completed) return { received: state.received, completed: true };
          } catch (stateErr) {
            if ([401, 404].includes(stateErr.status)) throw stateErr;
          }
        }
      }
      throw new Error('Chunk upload failed after five attempts.');
    }

    els.fileInput?.addEventListener('change', () => {
      const files = els.fileInput.files;
      if (!files || files.length === 0) {
        pendingResume = null;
        return;
      }
      uploadFiles(files);
      els.fileInput.value = '';
    });
    els.fileInput?.addEventListener('cancel', () => {
      pendingResume = null;
    });

    if (els.dropzone) {
      ['dragenter', 'dragover'].forEach((eventName) => {
        els.dropzone.addEventListener(eventName, (event) => {
          event.preventDefault();
          els.dropzone.classList.add('is-dragging');
        });
      });
      ['dragleave', 'drop'].forEach((eventName) => {
        els.dropzone.addEventListener(eventName, (event) => {
          event.preventDefault();
          els.dropzone.classList.remove('is-dragging');
        });
      });
      els.dropzone.addEventListener('drop', (event) => {
        if (event.dataTransfer && event.dataTransfer.files.length) {
          uploadFiles(event.dataTransfer.files);
        }
      });
      els.dropzone.addEventListener('keydown', (event) => {
        if (event.key === 'Enter' || event.key === ' ') {
          event.preventDefault();
          els.fileInput.click();
        }
      });
    }

    els.urlForm?.addEventListener('submit', async (event) => {
      event.preventDefault();
      const value = (els.urlInput.value || '').trim();
      if (!value) return;
      clearError();
      const button = els.urlForm.querySelector('button');
      setBusy(button, true);
      try {
        await api(`${base}/urls`, { method: 'POST', json: { url: value } });
        els.urlInput.value = '';
        await refresh();
      } catch (err) {
        showError(err.message);
      } finally {
        setBusy(button, false);
      }
    });

    els.start?.addEventListener('click', async () => {
      clearError();
      setBusy(els.start, true);
      try {
        const passphrase = (els.passphrase && els.passphrase.value) || '';
        const confirm = (els.passphraseConfirm && els.passphraseConfirm.value) || '';
        const clearPassphrase = !!(els.clearPassphrase && els.clearPassphrase.checked);
        if (passphrase && passphrase !== confirm) {
          showError('The passphrase and its confirmation do not match.');
          setBusy(els.start, false);
          return;
        }
        const compress = !!(els.compress && els.compress.checked);
        await api(`${base}/start`, {
          method: 'POST',
          json: { passphrase, compress, clear_passphrase: clearPassphrase },
        });
        await refresh();
        startPolling();
      } catch (err) {
        showError(err.message);
        setBusy(els.start, false);
      }
    });

    const ACTIVE_STATES = ['queued', 'downloading', 'building', 'pushing'];

    function startPolling() {
      if (pollTimer) window.clearTimeout(pollTimer);
      pollTimer = window.setTimeout(poll, 2000);
    }

    async function poll() {
      if (polling) return;
      polling = true;
      try {
        const data = await refresh();
        if (!data || !ACTIVE_STATES.includes(data.state)) {
          polling = false;
          return;
        }
      } catch (err) {
        showError(err.message);
      } finally {
        polling = false;
      }
      pollTimer = window.setTimeout(poll, 2000);
    }

    refresh()
      .then((data) => {
        if (data && ACTIVE_STATES.includes(data.state)) startPolling();
      })
      .catch((err) => showError(err.message));

    window.addEventListener('beforeunload', (event) => {
      if (pollTimer) window.clearTimeout(pollTimer);
      if (uploading) {
        event.preventDefault();
        event.returnValue = '';
      }
    });
  }

  if (page === 'index') initIndex();
  if (page === 'history') initHistory();
  if (page === 'job') initJob();
})();
FERRY_EOF_41

cat > 'web/static/style.css' <<'FERRY_EOF_42'
:root {
  --bg: #f5f7fb;
  --surface: #ffffff;
  --surface-soft: #eef2f7;
  --text: #172033;
  --muted: #5b6b80;
  --border: #dbe3ec;
  --border-strong: #c6d0dc;
  --primary: #155eef;
  --primary-hover: #0d4ed1;
  --primary-soft: #e8efff;
  --danger: #c0262d;
  --danger-soft: #fff0f0;
  --warning: #8a5a00;
  --warning-soft: #fff7df;
  --success: #0d7a48;
  --success-soft: #e8f8ef;
  --radius: 14px;
  --radius-small: 9px;
  --shadow: 0 10px 30px rgba(23, 32, 51, 0.07);
  --font: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
  --mono: ui-monospace, SFMono-Regular, Menlo, Consolas, "Liberation Mono", monospace;
}

* { box-sizing: border-box; }
[hidden] { display: none !important; }
html { color-scheme: light; }

body {
  margin: 0;
  background: var(--bg);
  color: var(--text);
  font-family: var(--font);
  font-size: 16px;
  line-height: 1.55;
  -webkit-font-smoothing: antialiased;
}

a { color: var(--primary); text-decoration: none; }
a:hover { text-decoration: underline; }
h1, h2, h3 { line-height: 1.2; margin: 0 0 0.55rem; letter-spacing: -0.015em; }
h1 { font-size: clamp(1.7rem, 3vw, 2.35rem); }
h2 { font-size: 1.3rem; }
h3 { font-size: 1.05rem; margin-top: 1.6rem; }
p { margin: 0.4rem 0 0.9rem; }
code, pre, .mono { font-family: var(--mono); }
code { font-size: 0.92em; background: var(--surface-soft); border-radius: 5px; padding: 0.1rem 0.32rem; }
pre { margin: 0; white-space: pre-wrap; overflow-wrap: anywhere; }
.wrap { overflow-wrap: anywhere; word-break: break-word; }
.muted { color: var(--muted); }
.hint { color: var(--muted); font-size: 0.88rem; margin: 0.55rem 0 0; }

.eyebrow {
  color: var(--primary);
  font-size: 0.76rem;
  font-weight: 750;
  letter-spacing: 0.09em;
  margin: 0 0 0.35rem;
  text-transform: uppercase;
}

.visually-hidden {
  border: 0; clip: rect(0 0 0 0); height: 1px; margin: -1px;
  overflow: hidden; padding: 0; position: absolute; white-space: nowrap; width: 1px;
}

.site-header {
  align-items: center;
  background: rgba(255, 255, 255, 0.94);
  border-bottom: 1px solid var(--border);
  display: flex;
  gap: 1rem;
  justify-content: space-between;
  padding: 0.8rem clamp(1rem, 4vw, 2.5rem);
  position: sticky;
  top: 0;
  z-index: 20;
  backdrop-filter: blur(10px);
}

.brand {
  align-items: center; color: var(--text); display: inline-flex;
  font-size: 1.18rem; font-weight: 800; gap: 0.5rem;
  letter-spacing: -0.02em;
}
.brand:hover { text-decoration: none; }
.brand-large { font-size: 1.6rem; margin-bottom: 1.4rem; }

.brand-mark {
  align-items: center; background: var(--primary); border-radius: 9px;
  color: #fff; display: inline-flex; font-size: 1rem; height: 2rem;
  justify-content: center; width: 2rem;
}
.brand-large .brand-mark { font-size: 1.3rem; height: 2.7rem; width: 2.7rem; }

.site-nav { align-items: center; display: flex; flex-wrap: wrap; gap: 0.8rem; font-size: 0.93rem; }
.user-chip {
  background: var(--surface-soft); border-radius: 999px; color: var(--muted);
  font-size: 0.83rem; font-weight: 650; padding: 0.28rem 0.68rem;
}
.inline-form { display: inline; margin: 0; }

.page {
  margin: 0 auto; max-width: 1080px;
  padding: clamp(1.1rem, 4vw, 2.3rem) clamp(0.9rem, 4vw, 1.5rem) 4rem;
}
.card {
  background: var(--surface); border: 1px solid var(--border);
  border-radius: var(--radius); box-shadow: var(--shadow);
  padding: clamp(1.1rem, 3vw, 1.7rem);
}
.hero {
  align-items: center; display: flex; gap: 2rem;
  justify-content: space-between; margin-bottom: 1.4rem;
}
.hero .lead { color: var(--muted); margin-bottom: 0; max-width: 62ch; }
.hero .button { flex: 0 0 auto; }
.section { margin-top: 2rem; }
.section-heading {
  align-items: baseline; display: flex; flex-wrap: wrap;
  gap: 0.4rem 1rem; justify-content: space-between; margin-bottom: 0.8rem;
}
.section-heading h2 { margin: 0; }
.section-heading p { margin: 0; }

.stack { display: grid; gap: 0.45rem; }
.stack label, .url-form > label { font-size: 0.9rem; font-weight: 650; }

input[type="text"], input[type="password"], input[type="url"], input[type="number"] {
  background: var(--surface); border: 1px solid var(--border-strong);
  border-radius: var(--radius-small); color: var(--text); font: inherit;
  min-width: 0; padding: 0.67rem 0.78rem; width: 100%;
}

input:focus, button:focus-visible, a:focus-visible, .dropzone:focus {
  outline: 3px solid rgba(21, 94, 239, 0.28); outline-offset: 2px;
}

.button {
  align-items: center; background: var(--surface-soft); border: 1px solid transparent;
  border-radius: var(--radius-small); color: var(--text); cursor: pointer;
  display: inline-flex; font: inherit; font-size: 0.9rem; font-weight: 650;
  gap: 0.35rem; justify-content: center; padding: 0.6rem 0.9rem;
  text-decoration: none; transition: background 0.15s ease, border-color 0.15s ease, transform 0.08s ease;
  white-space: nowrap;
}
.button:hover { background: var(--border); text-decoration: none; }
.button:active { transform: translateY(1px); }
.button:disabled { cursor: not-allowed; opacity: 0.55; }
.button-primary { background: var(--primary); color: #fff; }
.button-primary:hover { background: var(--primary-hover); }
.button-danger { background: var(--danger-soft); border-color: #f2c8ca; color: var(--danger); }
.button-danger:hover { background: #ffe0e1; }
.button-quiet { background: transparent; color: var(--muted); }
.button-quiet:hover { background: var(--surface-soft); color: var(--text); }
.button-small { font-size: 0.8rem; padding: 0.4rem 0.65rem; }
.button-large { font-size: 1rem; padding: 0.8rem 1.2rem; }
.button-full { margin-top: 0.4rem; width: 100%; }

.input-row { display: flex; gap: 0.55rem; }
.input-row input { flex: 1 1 auto; }
.url-form { border-top: 1px solid var(--border); margin-top: 1rem; padding-top: 1rem; }
.url-form > label { display: block; margin-bottom: 0.4rem; }

.alert { border-radius: var(--radius-small); margin: 0.8rem 0; padding: 0.72rem 0.85rem; }
.alert-error { background: var(--danger-soft); border: 1px solid #f2c8ca; color: var(--danger); }
.alert-warning { background: var(--warning-soft); border: 1px solid #eeda9d; color: var(--warning); }

.login-page { align-items: center; display: flex; justify-content: center; min-height: 100vh; padding: 1rem; }
.login-card {
  background: var(--surface); border: 1px solid var(--border); border-radius: 20px;
  box-shadow: var(--shadow); max-width: 430px; padding: clamp(1.5rem, 6vw, 2.5rem); width: 100%;
}
.login-card h1 { margin-bottom: 0.2rem; }
.login-card .fine-print { color: var(--muted); font-size: 0.8rem; margin: 1rem 0 0; text-align: center; }

.job-heading {
  align-items: center; display: flex; gap: 1rem;
  justify-content: space-between; margin-bottom: 1rem;
}
.job-heading h1 { font-size: clamp(0.95rem, 2vw, 1.15rem); font-weight: 650; margin: 0; }

.badge {
  border-radius: 999px; display: inline-block; font-size: 0.74rem;
  font-weight: 750; letter-spacing: 0.04em; padding: 0.28rem 0.65rem; text-transform: uppercase;
}
.badge-draft { background: #eef2f7; color: #475569; }
.badge-queued { background: #fff4d6; color: #805600; }
.badge-downloading, .badge-building, .badge-pushing { background: var(--primary-soft); color: var(--primary); }
.badge-done { background: var(--success-soft); color: var(--success); }
.badge-failed { background: var(--danger-soft); color: var(--danger); }

.dropzone {
  align-items: center; background: #fbfcff; border: 2px dashed var(--border-strong);
  border-radius: var(--radius); cursor: pointer; display: flex; flex-direction: column;
  gap: 0.25rem; margin: 1rem 0; padding: 1.7rem 1rem; text-align: center;
  transition: border-color 0.15s ease, background 0.15s ease;
}
.dropzone:hover, .dropzone.is-dragging { background: var(--primary-soft); border-color: var(--primary); }
.dropzone-icon {
  align-items: center; background: var(--primary-soft); border-radius: 999px;
  color: var(--primary); display: inline-flex; font-size: 1.2rem; font-weight: 800;
  height: 2.3rem; justify-content: center; margin-bottom: 0.3rem; width: 2.3rem;
}
.dropzone-title { font-weight: 700; }

.entry-list { display: grid; gap: 0.55rem; }
.entry {
  align-items: center; background: var(--surface); border: 1px solid var(--border);
  border-radius: var(--radius-small); display: flex; gap: 0.8rem;
  justify-content: space-between; padding: 0.65rem 0.8rem;
}
.entry-main { min-width: 0; }
.entry-name { font-weight: 650; overflow-wrap: anywhere; }
.entry-meta { color: var(--muted); font-size: 0.82rem; overflow-wrap: anywhere; }
.entry-actions { display: flex; flex: 0 0 auto; gap: 0.35rem; }
.entry-error { color: var(--danger); font-size: 0.82rem; }
.entry progress { margin-top: 0.35rem; }

.current-card {
  border-color: #c7d7ff;
  margin-bottom: 1.4rem;
}

.options {
  border: 1px solid var(--border);
  border-radius: var(--radius-small);
  margin-top: 1rem;
  padding: 0.7rem 0.85rem;
}

.options summary {
  cursor: pointer;
  font-weight: 650;
}

.options-body {
  display: grid;
  gap: 0.45rem;
  margin-top: 0.7rem;
}

.options-body > label:first-child {
  font-size: 0.9rem;
  font-weight: 650;
}

.checkbox-row {
  align-items: flex-start;
  display: flex;
  font-weight: 500;
  gap: 0.5rem;
}

.checkbox-row input {
  margin-top: 0.28rem;
  width: auto;
}

.quota { background: var(--surface-soft); border-radius: var(--radius-small); margin-top: 1.2rem; padding: 0.8rem; }
.quota-label { display: flex; flex-wrap: wrap; gap: 0.4rem 1rem; justify-content: space-between; margin-bottom: 0.5rem; }
.start-row { align-items: center; display: flex; flex-wrap: wrap; gap: 0.8rem; margin-top: 1rem; }
.start-row .hint { margin: 0; }

progress {
  accent-color: var(--primary); background: var(--border); border: 0;
  border-radius: 999px; display: block; height: 0.65rem; overflow: hidden; width: 100%;
}
progress::-webkit-progress-bar { background: var(--border); border-radius: 999px; }
progress::-webkit-progress-value { background: var(--primary); border-radius: 999px; transition: width 0.3s ease; }
progress::-moz-progress-bar { background: var(--primary); border-radius: 999px; }

.progress-row { align-items: center; display: flex; gap: 0.8rem; justify-content: space-between; margin-bottom: 0.5rem; }
#job-progress { height: 0.9rem; }

.log {
  background: #101828; border-radius: var(--radius-small); color: #d8e2f1;
  font-size: 0.8rem; line-height: 1.55; max-height: 20rem; overflow: auto; padding: 0.85rem;
}
.commands {
  background: #101828; border-radius: var(--radius-small); color: #d8e2f1;
  font-size: 0.82rem; line-height: 1.7; margin: 0.5rem 0 0.7rem; overflow: auto; padding: 0.9rem;
}
.image-name-row {
  align-items: center; background: var(--success-soft); border: 1px solid #bfe8d1;
  border-radius: var(--radius-small); display: flex; flex-wrap: wrap; gap: 0.7rem;
  justify-content: space-between; margin: 1rem 0; padding: 0.8rem;
}
.image-name {
  background: transparent; color: var(--success); font-size: 0.92rem;
  font-weight: 700; padding: 0;
}

.success-mark, .failure-mark {
  align-items: center; border-radius: 999px; display: flex; font-size: 1.3rem;
  font-weight: 800; height: 2.6rem; justify-content: center; margin-bottom: 0.7rem; width: 2.6rem;
}
.success-mark { background: var(--success-soft); color: var(--success); }
.failure-mark { background: var(--danger-soft); color: var(--danger); }

.table-wrap {
  background: var(--surface); border: 1px solid var(--border); border-radius: var(--radius);
  box-shadow: var(--shadow); overflow-x: auto;
}
table { border-collapse: collapse; font-size: 0.9rem; min-width: 760px; width: 100%; }
th, td { border-bottom: 1px solid var(--border); padding: 0.65rem 0.8rem; text-align: left; vertical-align: middle; }
th {
  background: #f8fafc; color: var(--muted); font-size: 0.72rem;
  font-weight: 750; letter-spacing: 0.045em; text-transform: uppercase;
}
tbody tr:last-child td { border-bottom: 0; }
tbody tr:hover { background: #fbfcff; }
.actions-col { text-align: right; }
.actions { display: flex; flex-wrap: wrap; gap: 0.35rem; justify-content: flex-end; }
.tag-note {
  background: var(--warning-soft); border-radius: 999px; color: var(--warning);
  display: inline-block; font-family: var(--font); font-size: 0.68rem;
  font-weight: 700; margin-left: 0.4rem; padding: 0.15rem 0.45rem; text-transform: uppercase;
}
.purge-form { margin-top: 0.6rem; }
.purge-form input { max-width: 7rem; }
.empty-state {
  background: var(--surface); border: 1px dashed var(--border-strong);
  border-radius: var(--radius); color: var(--muted); padding: 2rem 1rem; text-align: center;
}
.notice { color: var(--muted); font-size: 0.88rem; margin-top: 0.6rem; }

.site-footer {
  color: var(--muted);
  font-size: 0.78rem;
  margin: 2rem auto 1.5rem;
  max-width: 1080px;
  padding: 0 1.5rem;
  text-align: center;
}

.login-page .site-footer {
  bottom: 1rem;
  left: 0;
  margin: 0;
  position: fixed;
  right: 0;
}

@media (max-width: 720px) {
  .site-header { align-items: flex-start; flex-direction: column; gap: 0.55rem; position: static; }
  .site-nav { gap: 0.6rem; }
  .hero { align-items: flex-start; flex-direction: column; gap: 1rem; }
  .hero .button { width: 100%; }
  .job-heading { align-items: flex-start; flex-direction: column; }
  .entry { align-items: flex-start; flex-direction: column; }
  .entry-actions { width: 100%; }
  .entry-actions .button { flex: 1; }
  .input-row { flex-direction: column; }
  .purge-form input { max-width: none; }
  .start-row .button { width: 100%; }
  .actions { justify-content: flex-start; }
}

@media (prefers-reduced-motion: reduce) {
  *, *::before, *::after { scroll-behavior: auto !important; transition: none !important; }
}
FERRY_EOF_42

cat > 'web/templates/error.html' <<'FERRY_EOF_43'
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>{{.Title}} · Ferry</title>
  <link rel="stylesheet" href="/static/style.css">
</head>
<body>
  <header class="site-header">
    <a class="brand" href="/">
      <span class="brand-mark" aria-hidden="true">⛴</span>
      <span>Ferry</span>
    </a>
    <nav class="site-nav"><a href="/">Home</a></nav>
  </header>
  <main class="page">
    <section class="card">
      <p class="eyebrow">{{.Title}}</p>
      <h1>Something went wrong</h1>
      <p class="alert alert-error">{{.Error}}</p>
      <p><a class="button" href="/">Back to transfers</a></p>
    </section>
  </main>
  <footer class="site-footer">Ferry {{version}}</footer>
</body>
</html>
FERRY_EOF_43

cat > 'web/templates/history.html' <<'FERRY_EOF_44'
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta name="csrf-token" content="{{.CSRF}}">
  <title>History · Ferry</title>
  <link rel="stylesheet" href="/static/style.css">
</head>
<body data-page="history">
  <header class="site-header">
    <a class="brand" href="/">
      <span class="brand-mark" aria-hidden="true">⛴</span>
      <span>Ferry</span>
    </a>
    <nav class="site-nav">
      <a href="/">New transfer</a>
      <span class="user-chip">{{.User}}</span>
      <form method="post" action="/logout" class="inline-form">
        <input type="hidden" name="_csrf" value="{{.CSRF}}">
        <button type="submit" class="button button-quiet">Log out</button>
      </form>
    </nav>
  </header>

  <main class="page">
    <div class="job-heading">
      <div>
        <p class="eyebrow">All transfers</p>
        <h1>History</h1>
      </div>
    </div>

    <div id="page-error" class="alert alert-error" role="alert" hidden></div>

    <section class="card">
      <div class="section-heading">
        <h2>Docker Hub cleanup</h2>
        <p class="muted">
          {{if .RetentionDays}}Automatic cleanup is enabled for images older than {{.RetentionDays}} days.{{else}}Automatic cleanup is disabled (FERRY_RETENTION_DAYS=0).{{end}}
        </p>
      </div>
      <form id="purge-form" class="input-row purge-form">
        <label for="purge-days" class="visually-hidden">Delete images older than days</label>
        <input id="purge-days" type="number" min="1" step="1" value="30" aria-label="Delete images older than days">
        <button class="button button-danger" type="submit">Delete all images older than N days</button>
      </form>
      <p class="hint">This deletes tags from Docker Hub but keeps the history records.</p>
    </section>

    <section class="section">
      {{if .Jobs}}
      <div class="table-wrap">
        <table>
          <thead>
            <tr>
              <th>Started</th><th>State</th><th>Files</th><th>Size</th><th>Image</th><th class="actions-col">Actions</th>
            </tr>
          </thead>
          <tbody>
            {{range .Jobs}}
            <tr>
              <td>{{time .CreatedAt}}</td>
              <td><span class="badge badge-{{.State}}">{{state .State}}</span></td>
              <td>{{.FileCount}}</td>
              <td>{{bytes .TotalBytes}}</td>
              <td class="mono wrap">
                {{if .Image}}{{.Image}}{{else}}—{{end}}
                {{if .ImageDeleted}}<span class="tag-note">image deleted</span>{{end}}
              </td>
              <td>
                <div class="actions">
                <a class="button button-small" href="/jobs/{{.ID}}">Open</a>
                {{if and .Image (not .ImageDeleted)}}
                <button class="button button-small button-danger js-delete-image" data-job-id="{{.ID}}" type="button">Delete image</button>
                {{end}}
                {{if isActive .State}}
                <button class="button button-small button-danger js-cancel-job" data-job-id="{{.ID}}" type="button">Cancel</button>
                {{else}}
                <button class="button button-small button-quiet js-delete-record" data-job-id="{{.ID}}" type="button">Delete record</button>
                {{end}}
                </div>
              </td>
            </tr>
            {{end}}
          </tbody>
        </table>
      </div>
      {{else}}
      <div class="empty-state">No transfers yet. <a href="/">Create one</a>.</div>
      {{end}}
    </section>
  </main>

  <footer class="site-footer">Ferry {{version}}</footer>

  <script src="/static/app.js" defer></script>
</body>
</html>
FERRY_EOF_44

cat > 'web/templates/index.html' <<'FERRY_EOF_45'
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta name="csrf-token" content="{{.CSRF}}">
  <title>Ferry · New transfer</title>
  <link rel="stylesheet" href="/static/style.css">
</head>
<body data-page="index">
  <header class="site-header">
    <a class="brand" href="/">
      <span class="brand-mark" aria-hidden="true">⛴</span>
      <span>Ferry</span>
    </a>
    <nav class="site-nav">
      <a href="/history">History</a>
      <span class="user-chip">{{.User}}</span>
      <form method="post" action="/logout" class="inline-form">
        <input type="hidden" name="_csrf" value="{{.CSRF}}">
        <button type="submit" class="button button-quiet">Log out</button>
      </form>
    </nav>
  </header>

  <main class="page">
    <section class="hero card">
      <div>
        <p class="eyebrow">Self-hosted transfer</p>
        <h1>Pack files into a private image</h1>
        <p class="lead">Add files or download links, press Start, and Ferry pushes them to your private Docker Hub repository. No Docker daemon is involved.</p>
      </div>
      <button id="new-transfer" class="button button-primary button-large" type="button">New transfer</button>
    </section>

    <div id="page-error" class="alert alert-error" role="alert" hidden></div>

    {{if .Current}}
    <section class="card current-card">
      <div class="section-heading">
        <div>
          <p class="eyebrow">Working now</p>
          <h2 class="mono wrap">{{.Current.ID}}</h2>
        </div>
        <span class="badge badge-{{.Current.State}}">{{state .Current.State}}</span>
      </div>
      <p class="muted">{{if .CurrentProgress.Text}}{{.CurrentProgress.Text}}{{else}}Starting…{{end}}</p>
      {{if gt .CurrentProgress.Total 0}}
      <progress max="{{.CurrentProgress.Total}}" value="{{.CurrentProgress.Done}}" aria-label="Current transfer progress"></progress>
      <p class="hint">{{bytes .CurrentProgress.Done}} / {{bytes .CurrentProgress.Total}}</p>
      {{end}}
      <div class="start-row">
        <a class="button button-primary" href="/jobs/{{.Current.ID}}">Open live view</a>
        <button class="button button-danger js-cancel-job" data-job-id="{{.Current.ID}}" type="button">Cancel transfer</button>
      </div>
    </section>
    {{end}}

    <section class="section">
      <div class="section-heading">
        <h2>Draft transfers</h2>
        <p class="muted">Drafts untouched for 24 hours are deleted automatically.</p>
      </div>
      {{if .Drafts}}
      <div class="table-wrap">
        <table>
          <thead>
            <tr><th>Created</th><th>State</th><th>Entries</th><th>Size</th><th class="actions-col">Actions</th></tr>
          </thead>
          <tbody>
            {{range .Drafts}}
            <tr>
              <td>{{time .CreatedAt}}</td>
              <td><span class="badge badge-draft">{{state .State}}</span></td>
              <td>{{.FileCount}}</td>
              <td>{{bytes .TotalBytes}}</td>
              <td><div class="actions"><a class="button button-small" href="/jobs/{{.ID}}">Open</a></div></td>
            </tr>
            {{end}}
          </tbody>
        </table>
      </div>
      {{else}}
      <div class="empty-state">No drafts. Create one to get started.</div>
      {{end}}
    </section>

    <section class="section">
      <div class="section-heading">
        <h2>Recent transfers</h2>
        <p><a href="/history">See full history</a></p>
      </div>
      {{if .Recent}}
      <div class="table-wrap">
        <table>
          <thead>
            <tr><th>Created</th><th>State</th><th>Files</th><th>Size</th><th>Image</th><th class="actions-col">Actions</th></tr>
          </thead>
          <tbody>
            {{range .Recent}}
            <tr>
              <td>{{time .CreatedAt}}</td>
              <td><span class="badge badge-{{.State}}">{{state .State}}</span></td>
              <td>{{.FileCount}}</td>
              <td>{{bytes .TotalBytes}}</td>
              <td class="mono wrap">{{if .Image}}{{.Image}}{{else}}—{{end}}</td>
              <td><div class="actions"><a class="button button-small" href="/jobs/{{.ID}}">Open</a></div></td>
            </tr>
            {{end}}
          </tbody>
        </table>
      </div>
      {{else}}
      <div class="empty-state">No completed or running transfers yet.</div>
      {{end}}
    </section>
  </main>

  <footer class="site-footer">Ferry {{version}}</footer>

  <script src="/static/app.js" defer></script>
</body>
</html>
FERRY_EOF_45

cat > 'web/templates/job.html' <<'FERRY_EOF_46'
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta name="csrf-token" content="{{.CSRF}}">
  <title>Transfer · Ferry</title>
  <link rel="stylesheet" href="/static/style.css">
</head>
<body data-page="job" data-job-id="{{.JobID}}" data-max-bytes="{{.MaxTotalBytes}}">
  <header class="site-header">
    <a class="brand" href="/">
      <span class="brand-mark" aria-hidden="true">⛴</span>
      <span>Ferry</span>
    </a>
    <nav class="site-nav">
      <a href="/history">History</a>
      <span class="user-chip">{{.User}}</span>
      <form method="post" action="/logout" class="inline-form">
        <input type="hidden" name="_csrf" value="{{.CSRF}}">
        <button type="submit" class="button button-quiet">Log out</button>
      </form>
    </nav>
  </header>

  <main class="page">
    <div class="job-heading">
      <div>
        <p class="eyebrow">Transfer</p>
        <h1 class="mono wrap">{{.JobID}}</h1>
      </div>
      <span id="job-state" class="badge badge-draft" role="status" aria-live="polite">Loading…</span>
    </div>

    <div id="page-error" class="alert alert-error" role="alert" hidden></div>
    <noscript><div class="alert alert-error">JavaScript is required to upload files and show live progress.</div></noscript>

    <section id="draft-panel" class="card" hidden>
      <div class="section-heading">
        <h2>Add content</h2>
        <p class="muted">Files upload in 8 MiB chunks and resume automatically after a dropped connection.</p>
      </div>

      <label id="dropzone" class="dropzone" for="file-input" tabindex="0" role="button" aria-controls="file-input">
        <span class="dropzone-icon" aria-hidden="true">↑</span>
        <span class="dropzone-title">Drop files here or click to choose</span>
        <span class="muted">You can select several files at once.</span>
      </label>
      <input id="file-input" class="visually-hidden" type="file" multiple>

      <div id="upload-list" class="entry-list" aria-live="polite"></div>

      <form id="url-form" class="url-form">
        <label for="url-input">Or add a public download URL</label>
        <div class="input-row">
          <input id="url-input" type="url" placeholder="https://example.com/file.zip" autocomplete="off" spellcheck="false">
          <button class="button" type="submit">Add URL</button>
        </div>
        <p class="hint">Only public http/https addresses are allowed. Ferry blocks private and local network addresses.</p>
      </form>

      <div id="entry-list" class="entry-list"></div>

      <details class="options">
        <summary>Optional: compress and encrypt files</summary>
        <div class="options-body">
          <label for="passphrase">Passphrase</label>
          <input id="passphrase" type="password" autocomplete="new-password" placeholder="Leave empty to keep a saved passphrase">
          <label for="passphrase-confirm">Confirm passphrase</label>
          <input id="passphrase-confirm" type="password" autocomplete="new-password" placeholder="Type it again">
          <p class="hint">When set, every file is encrypted with AES-256-GCM before it is packed. The destination must unpack the image with this passphrase. <strong>There is no recovery if you forget it.</strong> Ferry stores only an encrypted copy of the passphrase and deletes it when the job ends.</p>
          <label class="checkbox-row">
            <input id="compress" type="checkbox">
            <span>Compress files with gzip when it makes them smaller</span>
          </label>
          <label id="clear-passphrase-row" class="checkbox-row" hidden>
            <input id="clear-passphrase" type="checkbox">
            <span>Remove the saved passphrase (do not encrypt this job)</span>
          </label>
          <p id="options-state" class="hint"></p>
        </div>
      </details>

      <div class="quota">
        <div class="quota-label">
          <strong id="total-text">0 B / {{.MaxTotalText}}</strong>
          <span class="muted">Total job size</span>
        </div>
        <progress id="total-progress" max="{{.MaxTotalBytes}}" value="0" aria-label="Total job size"></progress>
      </div>

      <div class="start-row">
        <button id="start-button" class="button button-primary button-large" type="button" disabled aria-describedby="start-hint">Start transfer</button>
        <p id="start-hint" class="hint">Add at least one file or URL.</p>
      </div>
    </section>

    <section id="run-panel" class="card" hidden>
      <div class="section-heading">
        <h2>Working</h2>
        <p class="muted">This page refreshes every 2 seconds. You can leave it and come back later.</p>
      </div>
      <div class="progress-row">
        <strong id="run-state" role="status" aria-live="polite">Queued</strong>
        <span id="progress-percent" class="muted"></span>
      </div>
      <progress id="job-progress" max="100" value="0" aria-label="Transfer progress"></progress>
      <p id="progress-text" class="muted">Waiting for the worker.</p>
      <p id="run-options" class="hint" hidden></p>
      <div class="start-row">
        <button id="cancel-button" class="button button-danger" type="button">Cancel transfer</button>
        <p class="hint">Cancelling stops the current step and deletes all temporary files.</p>
      </div>
      <h3>Log</h3>
      <pre id="job-log" class="log">Waiting…</pre>
    </section>

    <section id="done-panel" class="card" hidden>
      <div class="success-mark" aria-hidden="true">✓</div>
      <h2>Image ready</h2>
      <p>Your files are packed and pushed to your private Docker Hub repository.</p>
      <div class="image-name-row">
        <code id="image-name" class="image-name wrap"></code>
        <button id="copy-image" class="button" type="button">Copy image name</button>
      </div>
      <p id="image-deleted-note" class="alert alert-warning" hidden>The image tag has been deleted from Docker Hub.</p>
      <h3>On the destination machine</h3>
      <pre id="pull-commands" class="commands"></pre>
      <button id="copy-commands" class="button" type="button">Copy commands</button>
      <p class="hint">Run <code>docker login</code> first if that machine is not logged in. The image is private, so the destination must have access to the same Docker Hub account.</p>
      <h3>Log</h3>
      <pre id="done-log" class="log"></pre>
    </section>

    <section id="failed-panel" class="card" hidden>
      <div class="failure-mark" aria-hidden="true">!</div>
      <h2>Transfer failed</h2>
      <p id="failure-message" class="alert alert-error" role="alert"></p>
      <p class="muted">The uploaded and downloaded files have already been deleted from the server. Fix the problem and create a new transfer.</p>
      <h3>Log</h3>
      <pre id="failed-log" class="log"></pre>
    </section>
  </main>

  <footer class="site-footer">Ferry {{version}}</footer>

  <script src="/static/app.js" defer></script>
</body>
</html>
FERRY_EOF_46

cat > 'web/templates/login.html' <<'FERRY_EOF_47'
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Log in · Ferry</title>
  <link rel="stylesheet" href="/static/style.css">
</head>
<body class="login-page">
  <main class="login-card">
    <div class="brand brand-large">
      <span class="brand-mark" aria-hidden="true">⛴</span>
      <span>Ferry</span>
    </div>
    <h1>Log in</h1>
    <p class="muted">Private file transfers through Docker Hub.</p>
    {{if .Error}}<div class="alert alert-error" role="alert">{{.Error}}</div>{{end}}
    <form method="post" action="/login" class="stack">
      <label for="username">Username</label>
      <input id="username" name="username" type="text" value="{{.Username}}" autocomplete="username" required autofocus>
      <label for="password">Password</label>
      <input id="password" name="password" type="password" autocomplete="current-password" required>
      <button class="button button-primary button-full" type="submit">Log in</button>
    </form>
    <p class="fine-print">Single-user self-hosted instance. Sessions last 12 hours.</p>
  </main>
  <footer class="site-footer">Ferry {{version}}</footer>

</body>
</html>
FERRY_EOF_47

chmod 0755 deploy/install.sh

echo "Ferry project created in $(pwd)."
echo "Next: read README.md, then push the files to a private GitHub repository."
