![Logo](logo.png)
<!-- Big money NE - https://patorjk.com/software/taag/#p=testall&f=Bulbhead&t=swift-crud&x=none&v=4&h=4&w=80&we=false> -->

A lightweight, exceptionally fast CRUD API server built with Swift, [SwiftNIO](https://github.com/apple/swift-nio) (HTTP), and [Blackbird](https://github.com/marcoarment/Blackbird) (SQLite).

> **Philosophy:** Intentionally frugal with dependencies. No heavy frameworks like Vapor or Hummingbird — we only pull in a lightweight HTTP server and a zero-config ORM, each chosen for high value with minimal overhead.

---

## Performance

The results of the benchmarks in the justfile were observed on a MacBook M4 Pro in production mode:

- **`benchmark-healthz`**: Authenticated GET request to `/healthz` achieves **63+k req/s**.
- **`benchmark-cookie`**: Authenticated GET request to `/api/session` achieves **56+k req/s**.
- **`benchmark-r`**: Authenticated single database read (GET `/api/posts?limit=1`) achieves **56k req/s**.
- **`benchmark-w`**: Authenticated single database write (POST `/api/posts`) achieves **14-26k req/s**.
- **`benchmark-rw`**: Mixed workload (90% reads, 10% writes) achieves **45k req/s total**:
  - Reads: **36k req/s**
  - Writes: **10k req/s**

Comparing the raw req/s (as in no db read/write) speed between languages:

Rust - 85k
Swift - 63k
Go - 45k - 70k
Java - 40k - 80k
Node.js - 15k - 30k
Python - 1k - 4k

> NOTE: DB read/write speed dwarfs language speed; BUT language DB libs are also often majorly under-optimized

## Quickstart

```bash
# Prerequisites
brew install just

# Build
just build

# Run (listens on port 8000 by default)
just run

# Test
just test
```

Server starts on `http://127.0.0.1:8000` by default.

### Configuration

The server is configured via environment variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `PORT` | `8000` | HTTP server port |
| `DB_PATH` | `db.sqlite` | SQLite database file path |
| `DB_DEBUG` | — | Set to `true` or `1` to log every SQL query |
| `AUTH_SECRET` | — | HMAC signing key for the `user_id` cookie. Set in production to prevent cookie forgery |
| `COOKIE_DOMAIN` | — | Parent domain for the session cookie (e.g. `btec.cc`) so `api.*` and `app.*` subdomains share auth. Omit for host-only cookies (local dev) |
| `COOKIE_SECURE` | `true` | Set to `false` or `0` to omit `Secure` on session cookies (local HTTP testing only) |
| `CORS_ALLOWED_ORIGINS` | — | Comma-separated browser origins allowed for credentialed CORS (e.g. `https://app.btec.cc`) |
| `SMTP_HOST` | — | SMTP server hostname (omit to fall back to print-to-stdout) |
| `SMTP_PORT` | `587` | SMTP server port |
| `SMTP_USERNAME` | — | SMTP username |
| `SMTP_PASSWORD` | — | SMTP password |
| `SMTP_FROM` | — | "From" address for outgoing emails |

Example with email sending:

```bash
PORT=9000 SMTP_HOST=smtp.example.com SMTP_USERNAME=user@example.com \
  SMTP_PASSWORD=secret SMTP_FROM=noreply@example.com just run
```

## API Reference

All request and response bodies use `Content-Type: application/json`.  
Auth is handled via a session cookie set on login.

### Authentication & Sessions

#### `POST /api/session/send-code`

Request a one-time login code by email.

**Request body:**
```json
{
  "email": "user@example.com"
}
```

**Responses:**

| Status | Meaning |
|--------|---------|
| `200` | Code sent — either via SMTP or printed to server logs (see [Configuration](#configuration)) |
| `429` | Rate-limited — wait 2 minutes between requests |
| `401` | Invalid email (missing `@`) |

**Notes:**
- New emails get a user record created automatically.
- Existing users get their code hash and attempt count reset.
- By default the code is printed to stdout (`Email send simulated: to=..., code=...`). Set `SMTP_HOST` and related env vars to deliver via email instead.

---

#### `POST /api/session/login`

Exchange a code for a session cookie.

**Request body:**
```json
{
  "email": "user@example.com",
  "code": "00000000"
}
```

**Responses:**

| Status | Meaning |
|--------|---------|
| `200` | Authenticated — `Set-Cookie: user_id=<id>.<sig>` header returned |
| `401` | Invalid email, code, or code expired (>10 min / max 3 attempts) |

**Notes:**
- On success the server sets `user_id=<id>.<sig>` with `Path=/`, `HttpOnly`, and (by default) `Secure` and `SameSite=Lax`. Set `COOKIE_DOMAIN` for cross-subdomain sharing; set `CORS_ALLOWED_ORIGINS` and use credentialed requests from the frontend when the API and app are on different origins.
- Codes expire after 10 minutes.
- After 3 failed attempts the code is invalidated.
- Successful login clears the code hash and attempt data from the user record.
- The cookie is HMAC-signed when `AUTH_SECRET` is configured (see [Configuration](#configuration)). Without it, the cookie is unsigned — suitable only for local dev.

---

#### `POST /api/session/logout`

Clear the session cookie.

**Request headers:** (none required)

**Response:**

| Status | Meaning |
|--------|---------|
| `200` | Cookie cleared — `Set-Cookie: user_id=; Expires=...` |

Returns an expired `user_id` cookie to clear the client-side value.

---

#### `GET /api/session/`

Return the currently authenticated user's profile.

**Cookies:** `user_id=<id>`

**Response:**

| Status | Meaning |
|--------|---------|
| `200` | User object |

```json
{
  "id": 1,
  "createdAt": "2026-05-12T00:00:00Z",
  "codeAttempts": null,
  "codeCreatedAt": null,
  "codeHash": null,
  "email": "user@example.com"
}
```

| Status | Meaning |
|--------|---------|
| `401` | Missing or invalid session cookie |

---

### Posts

All post endpoints require authentication (`user_id` cookie). Post IDs are arbitrary strings (UUIDs recommended).

#### `GET /api/posts`

List the authenticated user's posts, newest first.

**Cookies:** `user_id=<id>`

**Query parameters:**

| Param | Type | Default | Description |
|-------|------|---------|-------------|
| `limit` | int | 10 | Max items (capped at 1000) |
| `after` | ISO-8601 date | — | Return posts with `updatedAt >=` this value (cursor pagination) |

**Response `200`:**
```json
{
  "items": [
    {
      "id": "a1b2c3d4",
      "content": "Hello world",
      "createdAt": "2026-05-12T00:00:00Z",
      "updatedAt": "2026-05-12T00:00:00Z",
      "userId": 1,
      "variant": "note",
      "isDeleted": false
    }
  ],
  "hasMore": false
}
```

`hasMore` is `true` when there are additional pages beyond the returned set. Use the last item's `updatedAt` as the `after` parameter for the next page.

| Status | Meaning |
|--------|---------|
| `401` | Missing or invalid session cookie |

---

#### `POST /api/posts`

Create a new post.

**Cookies:** `user_id=<id>`

**Request body:**
```json
{
  "id": "my-unique-id",
  "content": "Hello world",
  "variant": "note",
  "createdAt": "2026-05-12T00:00:00Z",
  "updatedAt": "2026-05-12T00:00:00Z"
}
```

All fields are optional except `content` and `variant`. If `id` is omitted a UUID is generated. If `createdAt` / `updatedAt` are omitted the current server time is used. Duplicate `id` values perform an upsert.

**Response `201`:**
```json
{ "message": "success" }
```

| Status | Meaning |
|--------|---------|
| `201` | Created (or upserted) |
| `401` | Missing or invalid session cookie |

---

#### `GET /api/posts/:id`

Fetch a single post by ID. Scoped to the authenticated user.

**Cookies:** `user_id=<id>`

**Response `200`:**
```json
{
  "id": "a1b2c3d4",
  "content": "Hello world",
  "createdAt": "2026-05-12T00:00:00Z",
  "updatedAt": "2026-05-12T00:00:00Z",
  "userId": 1,
  "variant": "note"
}
```

| Status | Meaning |
|--------|---------|
| `200` | Post found |
| `404` | Post not found or access denied |
| `401` | Missing or invalid session cookie |

---

#### `PUT /api/posts/:id`

Update a post. The request body must include a `updatedAt` timestamp that is **greater than** the currently stored `updatedAt` — this provides a last-write-wins conflict resolution.

**Cookies:** `user_id=<id>`

**Request body:**
```json
{
  "content": "Updated content",
  "updatedAt": "2026-05-12T01:00:00Z"
}
```

**Response `200`:**
```json
{ "message": "success" }
```

If the supplied `updatedAt` is not newer than the stored value, the update is rejected.

| Status | Meaning |
|--------|---------|
| `200` | Updated |
| `404` | Post not found or supplied `updatedAt` is stale |
| `401` | Missing or invalid session cookie |

---

#### `DELETE /api/posts/:id`

Delete a single post by ID. Scoped to the authenticated user.

**Cookies:** `user_id=<id>`

**Response `200`:**
```json
{ "message": "success" }
```

| Status | Meaning |
|--------|---------|
| `200` | Deleted (even if the post didn't exist) |
| `401` | Missing or invalid session cookie |

---

#### `DELETE /api/posts`

Delete **all** posts belonging to the authenticated user.

**Cookies:** `user_id=<id>`

**Response `200`:**
```json
{ "message": "success" }
```

| Status | Meaning |
|--------|---------|
| `200` | All posts deleted |
| `401` | Missing or invalid session cookie |

---

#### `POST /api/posts/upsert-many`

Bulk upsert multiple posts in a single transaction. Accepts an array of post objects. All updates are scoped to the authenticated user.

**Cookies:** `user_id=<id>`

**Request body:**
```json
[
  {
    "id": "post-1",
    "content": "First",
    "variant": "note",
    "createdAt": "2026-05-12T00:00:00Z",
    "updatedAt": "2026-05-12T00:00:00Z"
  },
  {
    "id": "post-2",
    "content": "Second",
    "variant": "note",
    "createdAt": "2026-05-12T00:00:00Z",
    "updatedAt": "2026-05-12T00:00:00Z"
  }
]
```

**Response `200`:**
```json
{ "message": "success" }
```

| Status | Meaning |
|--------|---------|
| `200` | All posts upserted |
| `401` | Missing or invalid session cookie |

---

### Common status codes

| Code | Meaning |
|------|---------|
| `200` | Success |
| `201` | Created |
| `404` | Not found |
| `429` | Too many requests (rate-limited) |
| `401` | Unauthorized |

---

## Architecture

This app is intentionally frugal with dependencies and only adds them when it's a big win:

- **[SwiftNIO](https://github.com/apple/swift-nio)** — high-performance asynchronous event-driven network application framework.
- **[Blackbird](https://github.com/marcoarment/Blackbird)** — SQLite ORM with zero-config schema migrations.

**File layout:**

```
Sources/swift-crud/
├── main.swift              # App entrypoint: DB setup, server launch
├── Core/
│   ├── Server.swift        # NIO HTTP server lifecycle
│   ├── AccessLogger.swift  # One-line access logs (stdout / LOG_FILE)
│   ├── APIRouter.swift     # Route table (get / post / put / delete)
│   ├── EmailSender.swift   # Email protocol + print fallback + factory
│   ├── SMTPEmailSender.swift # NIO SMTP client (STARTTLS / TLS)
│   ├── Environment.swift   # Env + .env loading
│   ├── Globals.swift       # Module singletons (db, auth secret, cookie/CORS, email)
│   ├── SessionCookie.swift # Set-Cookie assembly for session auth
│   ├── CORS.swift          # Credentialed CORS for allowed frontend origins
│   ├── HTTPLimits.swift    # Request body / content size caps
│   ├── HTTPRequest.swift   # Request type + query parsing + handler typealias
│   └── HTTPResponse.swift  # Response type + JSON helper
├── Security/
│   └── AuthCookie.swift    # HMAC-signed session cookie helpers
├── Handlers/
│   ├── Session.swift       # Auth endpoints (send-code, login, logout, session)
│   ├── Posts.swift         # Post CRUD endpoints
│   └── Health.swift        # GET /healthz
└── Model/
    ├── User.swift          # User Blackbird model
    └── Post.swift          # Post Blackbird model
```

## Contributing

See [`CONTRIBUTING.md`](CONTRIBUTING.md). Security: [`SECURITY.md`](SECURITY.md). Code of conduct: [`CODE_OF_CONDUCT.md`](CODE_OF_CONDUCT.md).

---

## License

MIT — see [`LICENSE`](LICENSE).
