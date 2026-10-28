# BrickTasks

A native iOS app (SwiftUI, iOS 17+) that warehouse operators use to work through the day's pick → pack → ship tasks. It shows today's tasks, flags overdue work at a glance, completes or reschedules tasks, and keeps working from a saved copy when the wifi drops.

**Run it:** open `BrickTasks.xcodeproj` in Xcode 16 or newer, choose an iPhone simulator, and press ⌘R. Xcode asks once to **Trust & Enable** the `OpenAPIGenerator` build plugin, which generates the API client from the spec at build time. The app talks to the sandbox in `App/Composition/AppConfig.swift`.

**Test it:** ⌘U runs everything: 150 package tests on iOS and 10 UI tests (plus the demo-recording test, which is skipped unless asked for). From the command line:

```bash
xcodebuild test -project BrickTasks.xcodeproj -scheme BrickTasks -destination 'platform=iOS Simulator,name=iPhone 15 Pro' -skipPackagePluginValidation
```

```bash
cd BrickTasksKit && swift test
```

The second command runs the package tests on macOS in about a second.

**Demo:** `demo.mp4` (53s), included in the zip: complete → reschedule → customer filter → offline relaunch → an unloaded day offline. It's recorded on the app's built-in simulated server with the clock pinned to 12:00, so it's repeatable. `UITests/DemoRecordingUITests.swift` drives it (run it with `TEST_RUNNER_BRICK_DEMO=1`).

**Sandbox reset:** ⋯ menu → *Reset sandbox data*.

---

## 1. Architecture

### How the code is organized

SwiftUI + MVVM, with a repository between the ViewModels and the network. Every layer talks to the next through a protocol. Each layer is its own target in a local Swift package (`BrickTasksKit`), so the compiler enforces the boundaries rather than a convention.

```
View<VM> ─▶ ViewModel ─▶ TaskRepository ─┬─▶ TaskRemoteDataSource ◀── Networking ─▶ TaskEndpoints ◀── ThirdParty/OpenAPITaskClient
                                         ├─▶ TaskLocalDataSource  ◀── Persistence (SwiftData)
                                         └─▶ SandboxReset (optional)
```

| Target | Owns |
|---|---|
| `Domain` | `Models/` (`WorkTask`, `CalendarDay`, `WallClockTime`, and the overdue rule); `Ports/`, the protocols outer layers implement (`TaskRemoteDataSource`, `TaskLocalDataSource`, `Connectivity`, `SandboxReset`); `Time/` (`WarehouseClock`) |
| `Networking` | `TaskEndpoints` (one method = one HTTP request) and `PagingTaskRemoteDataSource`: paging, de-duplication, the 429 retry for reads |
| `ThirdParty/OpenAPITaskClient` | `openapi.yaml`, the generated client, and an adapter that maps wire types and errors to the domain. The only target that imports a third-party package |
| `Persistence` | `SwiftDataTaskStore`, an actor with its own `ModelContext` |
| `Repository` | `OfflineFirstTaskRepository`: the local copy is the source of truth; refresh, day replacement, action reconciliation, change feed |
| `Features` | ViewModel protocols and `@Observable @MainActor` implementations. No SwiftUI import, so they test on macOS |
| `TaskSimulator` | An in-memory server that enforces the real API's rules, with scriptable failures. Used by tests and `-uiTesting` launches, never by the live app |
| `App` (Xcode target) | SwiftUI views (generic over the ViewModel protocols), the composition root, and `NWPathMonitor` connectivity |

The full rule set (what each layer may and may not do, plus the testing matrix) is in [ENGINEERING.md](ENGINEERING.md).

### Trade-offs

- **A contract-first client, generated from a spec I wrote.** The vendor publishes no spec, so I wrote `openapi.yaml` from api.pdf and corrected it against the live server. That's more upfront work than three hand-written `Codable` structs. In return, the contract is explicit and reviewable in one file, request bodies forbid extra fields (the server 400s on them), and the generator stays confined to one swappable adapter.
- **The local store is the source of truth for reads.** Screens render the saved copy immediately, then refresh. That gives offline reads for free, and every screen updates through the same change feed when anything changes.
- **Refreshing a day replaces that day.** Tasks missing from a fresh fetch are dropped from that day. They were rescheduled away or deleted, and they reappear when their new day loads. The alternative, refetching each one by id, costs a request per task against a 10 req/s limit.
- **Actions are never retried or queued.** The API has no idempotency key, so a retry after a lost response could double-apply. Instead, the app refetches the work order and lets the server's state decide what happened (see *Surprises*).
- **ViewModel tests run against the real repository**, with the network faked by `TaskSimulator`. A fake repository would have to re-implement reconciliation to be meaningful. Faking at the network edge tests what the operator actually sees, and the suite still runs in under a second.
- **A malformed task fails the whole response** instead of being skipped. On the floor, a list that is silently missing a task is worse than an error shown over the saved list.

### Cut for time

- **Overdue work from earlier days isn't surfaced on Today.** Yesterday's unfinished tasks are only visible if you go back a day. A "carried over" section from `GET /tasks?status=pending` would be the next thing I'd build.
- **No background refresh while the app is open.** Data refreshes on open, on pull-to-refresh, on changing day, after every action, and when connectivity comes back. Office edits made while you're looking at a screen appear on the next of those.
- **Midnight rollover:** a list opened before midnight keeps its day; it's titled "Yesterday" after midnight rather than jumping to the new day.
- No pruning of old days from the store, no iPad or landscape layout, no localization, and accessibility limited to VoiceOver labels on rows and Dynamic Type from system fonts.
- No logging or analytics.

### Assumptions where the reference was silent

1. **Base URL.** The brief and api.pdf give different sandbox URLs, and both are live with different data. I used api.pdf's, since it's "the whole contract". It's one constant in `AppConfig.swift`.
2. **Timezone.** `date` and `time` are the warehouse's wall-clock time, and the device is in the warehouse's timezone. "Today" is the device's calendar day.
3. **Overdue** means not done and `now > due`, compared by the minute: a task due at 10:00 becomes overdue at 10:01. A done task is never overdue. A status the app doesn't recognise counts as *not done*, so the task stays visible.
4. **Unknown values are tolerated.** A new `kind`, `status` or action decodes as "unknown" instead of failing the page. Unknown actions never enable a button.
5. **A 409 on an action when the task is already in the requested state counts as success**, shown as "Already marked done". That's either the office getting there first or our own earlier request whose response was lost.
6. **A task missing from its day's list** was rescheduled away or deleted. A 404 on a list means the sandbox URL has expired.
7. **`Retry-After` is in whole seconds** (observed: `1`).
8. **Customers are identified by name**, because there's no customer id.
9. **Everyone sees every task.** There's no assignee or operator identity in the API.

### Surprises, and how I handled them

All of these were verified with curl against the sandbox. The full list is in ENGINEERING.md §7.

| Surprise | Handling |
|---|---|
| No timezone on `date`/`time` | Kept as `CalendarDay` and `WallClockTime`, not `Date`. Combined with an injected warehouse timezone only when comparing against "now" |
| `POST /actions` returns the action record, not the task, and completing one step changes what the next step allows | Refetch the whole work order after every action |
| No idempotency key; repeating a complete returns `409 "pick is already done"` | Never retry. On a dropped connection, refetch and report *applied*, *not applied (try again)*, or *couldn't confirm (refresh first)* |
| No `updatedAt`, ETag or delta endpoint, and offset paging shifts while the office edits | De-duplicate by id, advance by the number of items returned, stop on an empty page. Refresh a whole day at a time |
| Timestamps have fractional seconds (`…:49.125Z`); the generator's default date decoder rejects them | Configured `.iso8601WithFractionalSeconds`, with a test that fails without it |
| Reschedule accepts any day, including the past, and doesn't keep the step order | The UI offers today onward; the server stays the authority on order |
| `/reset` keeps ids but re-dates everything | Reset wipes the local store |
| Tasks due at `00:00`, and Saturdays with no tasks | Tests for midnight overdue; a clear empty state for empty days |
| The brief says tasks carry "instructions and information for Operators", but the API has no such field | Nothing to show. Listed under API changes below |

---

## 2. Data model and API changes

**On the device:** one SwiftData row per task (`TaskRecord`, with enums stored as their wire strings so unknown values survive), plus a per-day `DaySyncRecord` holding `syncedAt`. That's what drives "Showing tasks saved at 9:42".

**What I'd add to the API, most important first:**

1. **Operator instructions on the task:** `instructions`, the location or bin, and the items with quantities. The brief describes them, and operators can't do the work without them.
2. **An `Idempotency-Key` header on `POST /actions`.** Then a retry after a lost response is safe, and the app could offer "Try again" instead of "refresh first".
3. **Return the updated work order** (or at least the task) from `POST /actions`. That saves a round trip on bad wifi and removes the window where the next step looks blocked.
4. **Optimistic concurrency:** a `version` or `updatedAt` on each task, sent back with `If-Match`. Today an operator can complete a task the office rescheduled a second ago, and nobody finds out.
5. **Delta sync:** `GET /tasks?updatedSince=` with tombstones for deleted or moved tasks, plus cursor pagination instead of offsets. That makes refresh cheap enough to run every minute and stable while data changes.
6. **Explicit time:** a `dueAt` with an offset, or a warehouse object carrying an IANA timezone. Then "overdue" means the same thing on every device.
7. **Customer and work-order context:** a `customer.id` and a `customerId` filter (the customer view is limited to one day today because of this), and `workOrder.totalSteps`.
8. **Assignment:** `assigneeId` plus authentication, so an operator sees their own work.
9. **Action history** (`GET /actions?taskId=` currently returns 405), and a server-side warning when a reschedule puts a step before the one it depends on.

---

## 3. Product decisions

I assumed one phone per operator, held one-handed (sometimes gloved) in an aisle with wifi that drops out. Operators work through the day in time order and can't afford a wrong tap.

- **Today first, in time order.** To-do tasks come first and done tasks sit dimmed underneath. Each row leads with a large due time, so the list reads like a schedule.
- **Overdue at a glance, three ways.** The time turns red, the row gets an OVERDUE badge, and the header shows a count ("5 overdue"). It's recalculated every 30 seconds, so tasks turn overdue as you watch. VoiceOver reads "overdue" in the row label.
- **Blocked steps say why.** Rows show "Waiting on earlier step". In the detail view, Complete is disabled with the reason ("Complete pack first.") and Reschedule stays available. Buttons follow the server's `allowedActions` rather than client-side rules.
- **The detail view shows the whole work order**, across days, with each step's status. You can tap a step to jump to it.
- **Complete asks first.** It can't be undone (the API has no reopen action), so a confirmation guards against bumps and gloves. The buttons are large (50pt) and sit at the bottom, in thumb reach.
- **Reschedule offers today onward and suggests the next day.** Moving work into the past would only make it overdue. The sheet notes that the due time stays the same.
- **Offline is a state, not an error.** The banner shows when the data was saved. Every screen still works from the saved copy. Complete and Reschedule are disabled with "You're offline. Connect to make changes.". Nothing is queued, as the brief asks. When connectivity returns, the app refreshes on its own.
- **When the network drops mid-action, the app tells the truth:** "Marked done", "didn't go through, try again", or "couldn't confirm, refresh before trying again". It never guesses, and it never retries blindly.
- **No dead ends.** Empty days, failed loads, deleted tasks and expired sandboxes each get a plain-language message and a way forward (Try again, pull to refresh, Back to today, Show all customers).
- **Customer filter (extra).** Operators often work one brand's orders, and supervisors ask "where's Halcyon at?". Choosing a customer groups the day's tasks by work order with "1 of 3 done today". It filters the saved day, so it works offline. The selection stays when you change day.
- **Reset in the ⋯ menu (extra).** Sandbox only, behind a confirmation, so reviewers can replay the flows.

---

## How I used AI

I built this with Claude Code. I made the decisions and set the rules, and the AI did most of the typing.

- **Exploration:** it probed the sandbox with curl (edge cases, 409s, rate limits, reset) and recorded the findings that became the Surprises table.
- **Guardrails:** I set the architecture and the rules: MVVM with a repository, protocols at every boundary, third-party code isolated under `ThirdParty/`, and every layer tested. They live in `ENGINEERING.md`, which the AI worked against and updated alongside the code.
- **Implementation:** it wrote the OpenAPI spec, the layers, the tests and the UI. It drove the simulator to check behavior, and recorded the demo.
- **Review:** the tests caught real mistakes along the way, including the fractional-seconds decoding failure, a race where actions briefly showed as enabled while offline, and an iOS-only stream bug in a test helper. It also deliberately broke the code to confirm the tests catch it.
- **Product:** I chose the extras (the customer filter and in-app reset) and the scope cuts.
