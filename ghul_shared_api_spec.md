# GHUL Shared Upload API (shared.ghul.run) – Minimal Spec (agreed so far)

Date: 2025-12-12 (CET)

This is the **current, minimal, working design** we agreed on to get uploads running safely and simply.
Client is **Bash (curl)**, server is **Python CGI (nginx + fcgiwrap)** over **HTTPS :443**.

---

## Goals

- **Session-based** uploads (multi-step).
- **Anti-fake baseline**: server validates **sequence** + **timestamp logic** (first rule: filename timestamp must match session run timestamp).
- **No server-side rewriting of JSON content**. Server only **verifies** and **stores**.
- **Flat storage** (no deep directories), with deterministic naming that the Web UI can fetch directly.

---

## Client-side identity files

Client maintains two local JSON files:

### 1) Machine identity (host/rig)
`~/.ghul_id.json` (example)
```json
{
  "host_id": "4eb2e09d47921441",
  "hostname": "sharkoon"
}
```

### 2) Anonymous share user identity
`~/.ghul_user_id.json` (example)
```json
{
  "user_id": "asdfgh"
}
```

Notes:
- `user_id` is **anonymous** by default (no registration required).
- User can copy this file to another machine to upload multiple rigs under the same anonymous user.
- If user later registers, they upload this JSON to bind that anonymous user to an account (future feature).

---

## Run timestamp rule (critical)

When a `--share` run starts, the client **must choose ONE run timestamp** and ensure **all uploaded files belong to that run**.

### Canonical run stamp format
`run_stamp = "YYYY-MM-DD-HH-MM"` (local or UTC; must be consistent within GHUL)

Example:
`2025-12-11-13-07`

### Filename rule (baseline validation)
Any file uploaded for this session must have an original filename starting with:
`<run_stamp>-`

Example:
`2025-12-11-13-07-sharkoon.json`  
`2025-12-11-13-07-sharkoon-sensors.jsonl`

The server will **reject** uploads if the filename does not start with `run_stamp-`.

---

## Client flags (share modes)

Client-side flags (planned in `shared.sh`):

- `--share`  
  Enables upload logic. Without it: “No share, no upload.”

- `--share --hellfire`  
  After benchmark upload, also upload Hellfire outputs.

- `--share --hellfire --insane`  
  Hellfire runs with extreme settings (longer duration, higher res, minimal cooldown). Expect thermal shutdown to trigger on weak systems.

Server receives these flags as booleans and stores them with the session.

---

## API Endpoints (current minimal set)

All endpoints are under: `https://shared.ghul.run`

### 1) `POST /handshake`
Creates a new upload session.

#### Request (JSON)
```json
{
  "user_id": "asdfgh",
  "host_id": "4eb2e09d47921441",
  "hostname": "sharkoon",
  "run_stamp": "2025-12-11-13-07",
  "share": true,
  "hellfire": false,
  "insane": false,
  "ghul_version": "0.3"
}
```

Notes:
- `run_stamp` is **required**.
- `insane=true` implies `hellfire=true` (otherwise reject).
- `ghul_version` is optional now; should be stored for later sanity checks.

#### Response (JSON)
```json
{
  "status": "ok",
  "session_id": "Sxxxxxxxxxxxx",
  "next_step": "ram"
}
```

Server behavior:
- Creates a session row in SQLite.
- Sets `expected_step = "ram"`, `status="active"`.

---

### 2) `POST /step`
Notifies the server that a phase finished and moves the session forward.

#### Request (JSON)
```json
{
  "session_id": "Sxxxxxxxxxxxx",
  "step": "ram",
  "timestamp": 1765454826
}
```

Rules:
- Steps must be **in the expected order**.
- `timestamp` must be **non-decreasing** compared to the last recorded timestamp for the session.

#### Response
```json
{ "status": "ok", "next_step": "cpu" }
```

#### Step order (for --full)
`ram → cpu → gpu → cooler → benchmark → finalize`

For `--share` only (later option):
- either keep same sequence but upload only `benchmark` artifacts,
- or allow a reduced sequence (to be decided later).

---

### 3) `POST /upload`
Uploads one file (multipart).

#### Request (multipart/form-data)
Fields:
- `session_id`: the session id
- `file`: the file to upload (must have a filename starting with `<run_stamp>-`)

Example curl:
```bash
curl -sS https://shared.ghul.run/upload \
  -F "session_id=Sxxxxxxxxxxxx" \
  -F "file=@/path/to/2025-12-11-13-07-sharkoon.json"
```

Server validation:
- Session exists and is `active`
- Session has `share=true`
- Uploaded original filename starts with `<run_stamp>-`

Server storage:
- Stored filename becomes:
  `user_id__host_id__<original_filename>`
- Stored directory:
  `/var/www/ghul.run/htdocs/GHULbenchmark/`

Response:
```json
{ "status": "ok", "stored_as": "asdfgh__4eb2e09d47921441__2025-12-11-13-07-sharkoon.json" }
```

---

## Storage layout (agreed)

All uploads go here (flat):
`/var/www/ghul.run/htdocs/GHULbenchmark/`

Stored file naming:
`<user_id>__<host_id>__<original_filename>`

This allows the Web UI to fetch by prefix without nested folders.

Examples:
- `asdfgh__4eb2e09d47921441__2025-12-11-13-07-sharkoon.json`
- `asdfgh__4eb2e09d47921441__2025-12-11-13-07-sharkoon-sensors.jsonl`

---

## SQLite schema (agreed minimal)

DB path (server):
`/var/www/shared-api/sessions.sqlite3`

### Table: `sessions`
Minimal columns:

- `session_id TEXT PRIMARY KEY`
- `user_id TEXT NOT NULL`
- `host_id TEXT NOT NULL`
- `hostname TEXT NOT NULL`
- `run_stamp TEXT NOT NULL`
- `ghul_version TEXT` (optional but recommended)
- `created_at INTEGER NOT NULL` (epoch)
- `last_activity INTEGER NOT NULL` (epoch)
- `last_ts INTEGER NOT NULL` (epoch; last step timestamp seen)
- `expected_step TEXT NOT NULL`
- `share INTEGER NOT NULL` (0/1)
- `hellfire INTEGER NOT NULL` (0/1)
- `insane INTEGER NOT NULL` (0/1)
- `status TEXT NOT NULL` (active/complete/aborted)

Recommended indexes:
- `INDEX(user_id)`
- `INDEX(host_id)`
- `INDEX(status)`

---

## Minimal validation rules (MVP)

1) **Filename timestamp check (hard rule)**  
`orig_filename.startswith(run_stamp + "-")`

2) **Step order check (hard rule)**  
`step == expected_step`

3) **Timestamp monotonic (hard rule)**  
`timestamp >= last_ts`

4) **Share gating (hard rule)**  
If `share != 1`, reject `/upload`.

---

## Next planned additions (later, not required for MVP)

- `/finalize` endpoint to mark session complete and return a public result URL.
- Per-file SHA256 on client and server-side verification.
- Nonce reuse prevention.
- Sensor sanity checks (e.g. impossible hotspot temps).
- Trusted/Certified user registration, email validation, badges.
- Retention policy (per host): first/best/newest (e.g. 5 total).
- Web UI: fetch JSON/JSONL directly and render graphs client-side (SVG).

---

## Notes for development workflow

- When developing the CGI script, **deploy atomically** to avoid transient 502 during edits:
  - write to `index.py.new`, then `mv index.py.new index.py`, then `chmod +x`.
- `index.py` must be executable and owned/readable by `www-data`.
