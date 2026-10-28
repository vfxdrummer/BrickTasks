# BrickTasks — Engineering Rules

The rules every change in this repo follows. If a rule needs to change, change it here first, in the same commit as the code.

## 1. Architecture

SwiftUI + MVVM, with a repository between the ViewModels and the network. **Every layer talks to the next through a protocol.**

```
View ─▶ ViewModel ─▶ TaskRepository ─┬─▶ TaskAPI ─────────▶ TaskEndpoints ◀── ThirdParty/OpenAPITaskClient
                     (protocol)      │   (protocol, Domain)   (protocol, Networking)   (generated client + adapter)
                                     └─▶ TaskStore (protocol) ◀── SwiftData implementation
Domain: pure types, rules, and the ports (protocols) the outer layers implement
```

Code lives in a local Swift package, `BrickTasksKit`, with one target per layer, so the compiler enforces the boundaries:

| Target | Owns | Must not |
|---|---|---|
| **Domain** | `WorkTask`, `CalendarDay`, `WallClockTime`, overdue rules, `WarehouseClock`, ports (`TaskAPI`), `APIError` | Import anything but Foundation |
| **Networking** | `TaskEndpoints` port (one method = one HTTP request), `RemoteTaskAPI` (paging, de-duplication, read retries) | Import any third-party module or know HTTP details |
| **ThirdParty/OpenAPITaskClient** | `openapi.yaml`, generated client, `OpenAPITaskEndpoints` adapter, wire→domain `TaskMapper`, `ErrorMapper` | Expose generated types (they're `package`/`internal`), retry, or make policy decisions |
| **Persistence** *(next)* | `TaskStore` port implementation on SwiftData | Make network calls |
| **Data** *(next)* | `TaskRepository`: local copy as source of truth, refresh policy, merging, action reconciliation | Know about SwiftUI or view state |
| **App / Features** *(next)* | Views, `@Observable @MainActor` ViewModels, composition root that wires concrete types | Import networking or third-party modules in ViewModels |

### Rules
- **Third-party code lives in `Sources/ThirdParty/<Name>/`**, in its own target, behind a protocol the app owns. It's the only target allowed to import that dependency. Its imports are `internal`, so its types can't leak. Swapping the library means rewriting one adapter target.
- **Protocols at every boundary.** Each layer depends on a protocol for the next (`TaskRepository`, `TaskAPI`, `TaskEndpoints`, `TaskStore`, `WarehouseClock`, `Connectivity`, `Sleeper`). Concrete types are chosen only in the composition root. Inject everything through initializers; no singletons, no `.shared`.
- **Wire types never leave their adapter.** Generated `Components.Schemas.*` → domain happens in `TaskMapper`, which is unit tested.
- **Time is injected.** Anything that needs "now" or "today" takes a `WarehouseClock`. Never call `Date()` in logic.
- **Swift Concurrency only.** `async/await` with typed `throws(APIError)` at the ports. No Combine, no completion handlers. ViewModels are `@MainActor`. Swift 6 language mode.
- **Adding a dependency** means updating this file with the reason, and putting it under `ThirdParty/`.

## 2. Networking

- **Contract-first.** `Sources/ThirdParty/OpenAPITaskClient/openapi.yaml` is hand-written from api.pdf and checked against the live server. `swift-openapi-generator` generates the client at build time (SPM plugin, nothing checked in). Change the spec first, then the adapter.
- Requests in the spec set `additionalProperties: false`; the server rejects unknown fields and params with 400. Request building is tested with exact-match assertions.
- Responses are tolerant: extra fields are ignored, and `kind`/`status`/action enums are open (`anyOf` a known enum or any string), mapping to `.unknown(String)`.
- **A malformed task fails the whole response** (`.invalidResponse`) instead of being dropped. A silently missing task is worse than an error shown over the cached list.
- Dates: `createdAt`/`appliedAt` have fractional seconds, so the client uses `.iso8601WithFractionalSeconds`. `date`/`time` stay strings on the wire and are parsed into `CalendarDay`/`WallClockTime` by the mapper.
- **Errors → `APIError`:** 400 `.badRequest`, 404 `.notFound`, 409 `.actionNotAllowed`, 429 `.rateLimited(retryAfter:)`, other/5xx `.server` (including non-JSON CDN pages), and transport failures split into `.notConnected` (never sent) vs `.connectionInterrupted` (may have landed).
- The base URL is configuration, injected into `OpenAPITaskEndpoints(baseURL:)`.
- **Pagination** (`RemoteTaskAPI`): `limit=50`, advance by the number of items returned, stop at `total` or on an empty page, de-duplicate by id, cap at 40 pages. An error on any page fails the whole fetch.
- **429:** reads get one retry after `Retry-After` (default 1s, give up if over 5s). Actions are never retried.

## 3. Offline & sync

- **The local store is the source of truth for reads.** Screens render cached data immediately, then refresh.
- **Refreshing a day replaces that day.** After a successful full fetch of date D, any cached task dated D that is missing from the result is refetched by id, or dropped if the server returns 404. Tasks get rescheduled away by other people.
- **Upsert by id, always.** Ids are stable while dates and statuses change, including after `/reset`.
- **Track `lastSyncedAt` per day**, and show it whenever the data might be stale.
- **Actions (complete / reschedule) are online-only.** No offline queue: the brief rules it out. When offline, the buttons are disabled and the screen says why.
- **After any action, refetch the whole work order** (`GET /tasks?workOrderId=`). One complete changes the next task's `allowedActions`, and the action response doesn't include the task.
- **An action that may or may not have landed** (timeout or lost response) is never blindly retried. Refetch the task and show the server's truth. A `409 action_not_allowed` after a retry is reconciled the same way, not shown as a failure.
- **Gate buttons on `allowedActions` from the server.** Don't recompute sequencing rules on the client.

## 4. Domain rules

- `date` + `time` are warehouse wall-clock time with no offset. They're combined into a `dueDate` using the injected `Clock.timeZone`. (Assumption: device timezone = warehouse timezone. This is documented in the README.)
- **Overdue** = `status != .done && dueDate < clock.now`.
- "Today" = the calendar day of `clock.now` in `clock.timeZone`.

## 5. Testing — EVERY LAYER MUST BE WELL TESTED

No layer merges without tests. Use **Swift Testing** (`@Test`, `#expect`) for unit and integration tests, and XCUITest for UI.

| Layer | How | Must cover |
|---|---|---|
| **Domain** | Pure unit tests | Overdue at boundaries (1 minute before and after, end of day, done-but-late), "today" across timezones and DST, unknown enum values |
| **Networking** | Fake `TaskEndpoints` + recording `Sleeper` | Pagination loop, offsets advance by items returned, dedupe, empty-page stop, page cap, 429 retry rules, actions never retried |
| **ThirdParty adapter** | `URLProtocol` stub + real captured fixtures, no real network | Exact URL/query/body for every endpoint, every status → `APIError`, `Retry-After`, CDN HTML errors, transport error split, tolerant decoding |
| **Store** | In-memory store instance | Upsert by id, query by day, a reschedule moves a task between days, persisting `lastSyncedAt` |
| **Repository** | Fake `TaskAPI` + in-memory store | Cache-first read, day replacement/eviction, offline returns cache + stale flag, action → work-order refetch, 409 / timeout reconciliation, no action attempted while offline |
| **ViewModel** | Fake repository, fixed `Clock`, fake `Connectivity` | State transitions (loading → loaded / empty / error), offline banner, button enablement from `allowedActions`, error messages shown to the user, date navigation |
| **UI** | XCUITest with app launched against a stubbed backend (launch argument) | Happy path: list → detail → complete; reschedule; offline shows cache and disables actions |

### Test rules
- Tests never hit the real sandbox. One opt-in smoke test target may, behind an env var, and it's excluded from the default scheme.
- Each fake lives in a shared `TestSupport` folder and records calls, so tests assert on behavior and not just on return values.
- Fixed `Clock` in every test that touches time. A test that depends on the real date is a bug.
- New bug → write a failing test first, then fix it.
- `xcodebuild test` must be green before every commit.

## 6. Code style
- Match the surrounding code. Small types, one responsibility each.
- Name intents after what the operator does (`complete()`, `reschedule(to:)`), not after HTTP (`postAction`).
- Errors shown to operators are plain language and say what to do next. "No connection. Showing tasks from 9:42 AM." beats "URLError -1009".
- Comments explain *why*, never *what*.

## 7. API facts (verified against the live sandbox, 2026-10-28)
Keep this list current; it feeds the README's "surprises" section.
1. The brief and api.pdf list different base URLs. Both are live, with different data. We use `…/c/4w14ybad4z111yo77btq`.
2. No timezone on `date`/`time`, and no `updatedAt`/ETag. Only full refetches detect changes.
3. `POST /actions` returns the action record, not the updated task.
4. No idempotency key. Repeating a complete returns `409 "<kind> is already done"`.
5. Rescheduling has no ordering guard: pack can land before pick, or in the past.
6. `/reset` keeps ids but shifts every date (re-anchors to today).
7. `limit` > 50 is clamped. `limit <= 0` or non-numeric → 400. An offset past the end → empty `items`.
8. Rate limit is enforced (about 30 burst). 429 → `Retry-After: 1`, body `{"error":"rate_limited",…}`.
9. Saturdays have no tasks in the generated data, so empty days are normal and need a clear empty state.
10. `GET /actions` → 405. There's no action history to read back.
11. Tasks can be due at `00:00`, so they're overdue a minute into their own day.
12. Timestamps carry fractional seconds (`…:49.125Z`), and swift-openapi-runtime's default ISO 8601 transcoder rejects them.
