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
- A **private GitHub repository** containing this project, and the release
  archive (`ferry-v1.0.0-linux-amd64.tar.gz`, or `arm64` for ARM servers)
  downloaded from that repository's **Releases** page.
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
- `api.github.com` and `release-assets.githubusercontent.com` — checking for
  and downloading newer releases (`ferry check-update`, `ferry self-update`)
- any public site you paste as a download URL

Inbound, you only need the web port (8080), plus 80/443 if you enable Caddy.

---

## Project layout

```text
cmd/ferry/            entrypoint, --version, check-update, hash-password, unpack, shutdown
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
internal/update/      GitHub release check and cached update status
internal/web/         HTML handlers, JSON API, CSRF and security headers
web/templates/        embedded HTML templates
web/static/           embedded CSS and vanilla JavaScript
deploy/               systemd unit, installer, env example, Caddy example
.github/workflows/    GitHub Actions build/release workflow
```

Dependencies are pinned in `go.mod` and `go.sum`. The CI workflow downloads
them, verifies they are tidy, and builds a static binary.

---

## Step 1 — Create the private Docker Hub repository and token

1. Log in at <https://hub.docker.com>.
2. **Repositories → Create repository**.
3. Name: **`ferry`**. Visibility: **Private**. Create.
4. Avatar → **Account settings** → **Security** → **New access token**.
5. Name it `ferry-vps`, select **Read, Write, Delete**, create it.
6. Copy the token immediately (Docker Hub shows it once).

Keep the token somewhere safe for now. You will paste it into
`/etc/ferry/ferry.env` as `DOCKERHUB_TOKEN` in Step 4, after the installer has
created that file.

Do **not** use your Docker Hub account password as the token.

---

## Step 2 — Copy the archive to the server

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

## Step 3 — Run the installer

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

## Step 4 — Edit the configuration

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
- Optional: set `GITHUB_TOKEN` to a fine-grained GitHub token with **read-only
  access to this repository**. `ferry check-update` and the "newer release"
  banner on the home page use it. A public repository works without a token; a
  private one needs this token.
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

## Step 5 — Start Ferry

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

Check the version, updates, and health:

```bash
/usr/local/bin/ferry --version
/usr/local/bin/ferry check-update
curl http://127.0.0.1:8080/health
```

Expected:

```text
ferry v1.0.0
Ferry v1.0.0 is up to date (latest release: v1.0.0).
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

## Step 6 — Optional automatic HTTPS with Caddy

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

1. Log in. The home page shows the **current job** whenever a transfer is
   queued or running, even if you closed the browser and came back later. Open
   it to see the live state again.
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
   deleted. Use **Cancel & clean up** to stop the job *and* remove its history
   record. On a finished job, **Delete this transfer** removes the record; it
   does not delete the Docker Hub tag.
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
- **Cancel & delete** — stop a queued or running job and remove its record.
- **Delete image** — remove the tag from Docker Hub, keep the history record.
- **Delete record** — remove the SQLite record. It does **not** delete the tag.
- **Delete all images older than N days** — bulk-delete Docker Hub tags for
  finished jobs. History records stay.

A 404 from Docker Hub during deletion is treated as success ("already
deleted"). A 401/403 means the token lacks **Read, Write, Delete** permission.

---

## Upgrading and rolling back

Check whether a newer release exists:

```bash
ferry check-update
```

It exits `0` when you are current, `1` when a newer release exists, and `2` when
the check itself failed.

### Update in place (recommended)

On the server, run:

```bash
sudo ferry self-update
```

This downloads the release archive for the server's architecture, verifies the
published SHA-256 checksum, replaces `/usr/local/bin/ferry` atomically, and
restarts the `ferry` service. A restart interrupts an active transfer, so wait
for it to finish or use `--no-restart`. Use `--force` to reinstall the latest
release. If the release repository is private, pass the token in the
environment: `sudo GITHUB_TOKEN=... ferry self-update`.

The installed build must already contain the `self-update` command. If it does
not, do one manual update first; later updates can use `sudo ferry self-update`.

### Manual update

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
12. **Reopen and clean up** — start a large job, close the browser tab, and open
    Ferry again. The home page must still show the running (or queued) transfer
    with its live progress. Press **Cancel & clean up**: the job stops, its
    record disappears, and `/var/lib/ferry/jobs/<job-id>` is gone.
13. **Delete the tag** — on the History page click **Delete image**, confirm the
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

### `ferry check-update` fails or reports 404

If the release repository is private, GitHub's API needs a token. Create a
fine-grained token with read-only access to the repository, add it to
`/etc/ferry/ferry.env` as `GITHUB_TOKEN=...`, and restart Ferry. A `401` means
the token is invalid or expired; a `403` mentioning the rate limit means too
many unauthenticated requests were made.

### `ferry self-update` fails

Run it with `sudo`: it must be able to replace `/usr/local/bin/ferry` and
restart the service. "no asset named ..." means the release has no build for
this machine's architecture. A checksum mismatch means the download was
corrupted or the release is incomplete; retry, and if it keeps failing, update
manually.

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
