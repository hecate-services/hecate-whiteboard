# Plan: hecate-whiteboard — Real-Time Multi-User Whiteboard Over Mesh

**Status:** Live on THREE nodes across THREE real, genuinely distinct
stations — `beam01.lab` (docker+watchtower, station-de-falkenstein),
`beam02.lab` (docker+watchtower, station-fi-helsinki), `msi00.lab`
(podman Quadlet, station-it-milan). Boards replicate, cross-node join
and discovery work, and a joining peer can draw (write-relay) — all
confirmed live with no two peers sharing a relay. `host_board` +
`draw_stroke` desks,
`project_boards` (PRJ) + `query_boards` (QRY), a real Phoenix/LiveView
canvas (`hecate_whiteboard_web`), and mesh replication
(`StrokeDrawnV1ToMesh` + `BoardMeshSubscriber`) are all built, tested,
and deployed. Visual design: a chalk-on-slate canvas (warm charcoal,
chalk-white ink, one amber accent), host/peer status made visible
rather than hidden.

**2026-08-25, later same day, after a computer crash broke the session:**
picked back up per the memory this plan doc left behind. Five more
things landed: `HecateWhiteboardWeb.ErrorView` (any 404 was crashing to
a raw 500 -- Phoenix derives that view by naming convention when
`render_errors` isn't configured, and it never existed), the
stroke_id-keyed dedup this doc already called out as the obvious fix
for the catchup-replay gap, `join_board` itself (mesh-level discovery +
snapshot fetch, view-only), a board picker (`/boards`), and -- found
while live-verifying the picker deploy -- **a real bug in evoq itself**,
fixed at the source and shipped as evoq 1.23.1. See "join_board — DONE
2026-08-25", "Board picker — DONE 2026-08-25", and "evoq catch-up bug —
FOUND AND FIXED 2026-08-25" below for the real shape of what shipped,
and each section's own verification notes for the actual fleet tests.

**Previously (walking skeleton), for reference:** Repo:
`github.com/hecate-services/hecate-whiteboard` (public). CI green
(`build-push.yml`, `lint.yml`), image published to
`ghcr.io/hecate-services/hecate-whiteboard:latest`. Deployed to
`beam01.lab` + `beam02.lab` via `macula-io/macula-demo`'s pull-based
reconciler (commit `857aaad`, retargeted from an original beam00 pick
after finding beam00's own `hecate-reconcile.timer` stuck since
2026-08-24 — separate pre-existing issue, not fixed here). Secret
enrollment (`HECATE_REALM`) is the one step done out of band, see that
repo's `infrastructure/scripts/enroll-hecate-whiteboard-secret.sh`. All three
risks in "Risks / open verification items" below are resolved; see that
section for what was actually found. Next: `host_board` + a bare LiveView
page per the "Suggested build order" section.
**Created:** 2026-08-25

---

## Read this first

- There is no prior build to summarize here — this is the design itself,
  not a record of one. Read the whole doc before writing code.
- **The one-line goal:** this exists so a person can host a live shared
  canvas on their own machine and have others draw on it with them, with
  no server anyone has to trust or pay for standing between them.
- This is the **first true peer-to-peer application** on this stack — no
  managed backend, no relay company, the host's own node *is* the whole
  service. Treat the decisions below as setting precedent for what
  "sovereignty" looks like in a shipped product, not as an internal
  implementation detail. See `user_commons_intent` / the strategic anchor
  in project memory for why that framing matters to the user.

## What it is

Comparable to Miro: an infinite 2D canvas, multiple people drawing and
moving shapes on it simultaneously, live cursors, join mid-session.
Different from Miro in the one way that matters: there is no central
"whiteboard.com" server. A user hosts a board on their own node (laptop,
home box, lab machine); collaborators dial into that specific host over
macula and draw with them in real time. If the host goes offline, the
board goes with it — that is the deliberate trade for not needing anyone's
server.

---

## Architecture decisions (locked in this session)

### Single authority per board, not CRDT

The hosting peer's node is the one order-of-truth for its board — an evoq
aggregate, one writer. This sidesteps needing a full CRDT merge algorithm:
there is already exactly one sequencer (whoever is hosting), the same
trick centralized tools like Figma use, just decentralized to whichever
peer opened the board.

### Presence is not event-sourced

Presence (who's currently connected, live cursors) is ephemeral session
state, not durable business history, and does not belong in the event
store. It lives in its own small non-ES component, `track_presence`: a
per-board ETS roster (`{peer_id, last_heartbeat}`), a periodic sweep that
ages out silent peers, and presence-changed broadcasts sent as **mesh
pubsub only** — an integration fact, never written to the event log.
Graceful exits are the one exception worth an audit trail: an explicit
`leave_board` command still emits `peer_departed_v1` into the event store,
because "who was in this session and when" is a real business fact when
someone chose to leave; a silent timeout is not.

### Late-join snapshot, not full replay

The host is already running the board live, so its current shape state
already exists as an in-memory read model, updated synchronously before
each event is broadcast — a join reads that model, it never replays event
history. The race to guard against: a stroke landing in the gap between
"snapshot taken" and "subscribed to live updates." Fix: the client
subscribes to the board's pubsub topic *before* requesting the snapshot,
buffers whatever arrives during that round trip, and the snapshot response
carries `as_of_version` (evoq's own aggregate stream version — no separate
counter needed). On receipt, the client drops any buffered event with
`version <= as_of_version` and replays the rest in order. Standard
subscribe-first-then-snapshot pattern.

### Canvas tooling: Konva.js + perfect-freehand, not tldraw/excalidraw

Both tldraw and excalidraw are React apps with their own built-in
sync/CRDT engine — pulling either in means a second UI framework inside a
Phoenix app *and* a competing sync layer fighting the version-number
reconciliation above. Instead: **Konva.js** (vanilla-JS 2D canvas, its own
shape/layer/pan-zoom model) driven by a Phoenix LiveView JS hook, with
**perfect-freehand** (small, framework-agnostic, same author as tldraw)
just for turning raw pointer samples into smooth tapered ink. Three Konva
layers: confirmed shapes (server-acked), pending shapes (local optimistic,
not yet acked), and cursors (fed straight from `track_presence`).

### Deployment shape: one Elixir/Phoenix umbrella, symmetric peer

Everyone who wants to host *or* join runs the same app — "join" is the
local LiveView dialing a remote host over mesh instead of running its own
`guide_board_lifecycle`. No separate relay/viewer tier for v1 (see
"Deferred" below). LiveView is why this is Elixir/Phoenix rather than
hecate-tube's plain-Erlang/cowboy shape — the canvas hook needs it.
`hecate_om`, `evoq`, and `macula` all come in as ordinary hex deps of the
domain app, called directly (`:hecate_om.foo()`, `:evoq_router.dispatch/1`,
`:macula.publish/3`) per the workspace's no-Elixir-wrapper rule —
"vendoring" just means a `mix.exs` dependency, nothing bespoke.

---

## Precedent — verified, not assumed

Checked directly against the actual repos before writing this plan, not
recalled from memory:

- **`guide_{subject}_lifecycle` / `project_{subject}` / `query_{subject}`
  as separate umbrella apps, in Elixir, already exists**:
  `macula-realm/system/apps/{guide_realm_lifecycle,project_realm,
  project_realm_identities,query_realm,query_realm_identities,
  macula_realm,macula_realm_web}` — same naming convention this plan
  uses, same domain-app/web-app split, already running in production.
  This is the direct structural precedent, more relevant than
  `reckon_traders_of_macao`'s `trom`/`trom_web` (which uses the same
  domain/web umbrella *shape* but not this naming convention).
- **evoq-from-Elixir is proven**: `macula-realm/system/mix.exs` and
  several other Elixir umbrellas in this workspace already depend on
  `evoq` directly. Not a risk.
- **A hecate-services daemon carrying its own operator-facing UI has
  precedent**: hecate-tube (Erlang, plain cowboy forms) already does
  this, despite hecate-om's own README describing Layer 2 services as
  headless ("Always-on, containerised, system-class workloads") with UI
  reserved for Layer 3/4 (`hecate-daemon` and its plugins). hecate-tube
  already bent that line once; hecate-whiteboard bends it further
  (LiveView instead of plain forms) but isn't structurally new — the
  precedent is "a service can talk directly to a human," not just
  headlessly to other services.
- **`hecate_om` has never been consumed from Elixir anywhere in this
  workspace** — grepped every `mix.exs` in the workspace, zero hits.
  Every existing hecate-om consumer is a plain Erlang OTP release. This
  is a genuinely first integration, not a proven path — see "Risks"
  below. `hecate_om` 0.15.0 is the current version (`hecate-om/src/
  hecate_om.app.src`); check hex.pm for what's actually published before
  pinning, per the hecate-tube plan's own hard-won lesson that local
  `.app.src` version numbers and what's published on hex.pm can diverge.

### Hard-won facts carried over from `hecate-tube/plans/PLAN_HECATE_TUBE_ROOT.md`

Don't re-derive these; they're general evoq/tooling facts, not
tube-specific:

- **Event shape on the wire**: `evoq_projection:project/4` receives
  `#{event_type, event_id, stream_id, version, data, tags, timestamp,
  epoch_us}` — your event's own fields are nested under `data`, not
  top-level. Every projection here (`stroke_drawn_v1_to_board_shapes` etc.)
  must unwrap `data` first, and must tolerate both atom and binary map
  keys surviving the store round trip.
- **Stream id convention**: `reckon_gater_stream_id:new(Prefix)` mints a
  fresh id, format `<prefix>-<32 lowercase hex>` — mint it inside the
  command constructor (`initiate_board_v1:new/1`), don't hand-roll a
  human-readable id. Prefix here: `board`.
- **`evoq_dispatcher` does not exist** in the pinned evoq version despite
  older code in this workspace calling it — use `evoq_router:dispatch/1,2`.
- Even though the host's own aggregate process holds current board state
  live in memory, queries still go through a proper PRJ→ETS read model
  (`project_boards`), never read the aggregate directly — keeps write and
  read sides decoupled per this workspace's stated CQRS principle, and
  matches hecate-tube's actual proven shape (`project_tube_store`).
- **`evoq_event_handler` is the real, verified projection/PM behaviour —
  `evoq_projection`'s documented `interested_in/init/project` shape
  (`init/1 -> {ok, State, ReadModel}`) was never actually exercised
  anywhere, including in hecate-tube.** Confirmed 2026-08-25 by reading
  `evoq_event_handler.erl` and `evoq_event_router.erl` directly after a
  boot crash (`FunctionClauseError` in `handle_init/4`). The real
  contract: `interested_in/0 -> [binary()]`, `init(Config) -> {ok, State}
  | {error, Reason}` (2-tuple, no ReadModel threaded through — just call
  your ETS table's known name directly inside the handler), and
  `handle_event(EventType, Event, Metadata, State) -> {ok, NewState} |
  {error, Reason}` — note `EventType` arrives as its own argument, but
  `Event` is still the full wrapped store record (`event_type, data,
  stream_id, version, ...`), confirmed via
  `evoq_event_router:route_event_internal/3` reading
  `maps:get(event_type, Event)` off the SAME map it later passes whole
  into `handle_event/4` — so the `data` unwrap is still required, just
  one argument later than the `evoq_projection` docs implied.

---

## Vertical slices

**Division:** `hecate-whiteboard`

### CMD — `guide_board_lifecycle`

```
initiate_board/   initiate_board_v1    -> board_initiated_v1   (birth desk: identity only, no mesh presence yet)
host_board/       host_board_v1        -> board_hosted_v1      (opens the board for live mesh connections)
draw_stroke/      draw_stroke_v1       -> stroke_drawn_v1
move_shape/       move_shape_v1        -> shape_moved_v1
remove_shape/     remove_shape_v1      -> shape_removed_v1
join_board/       join_board_v1        -> peer_admitted_v1     (also returns the snapshot as the RPC reply)
leave_board/      leave_board_v1       -> peer_departed_v1
archive_board/    archive_board_v1     -> board_archived_v1
```

`join_board`'s handler does double duty: validate admission, emit
`peer_admitted_v1`, then call into `query_boards` for the current
projection and return `{peer_admitted_v1, snapshot}` as the RPC reply.
Synchronous local call, same host — no process manager needed for this
one, it isn't a cross-division reaction.

### PRJ — `project_boards`

```
board_initiated_v1_to_boards
board_hosted_v1_to_boards
stroke_drawn_v1_to_board_shapes
shape_moved_v1_to_board_shapes
shape_removed_v1_to_board_shapes
board_archived_v1_to_boards
```

### QRY — `query_boards`

```
get_board_snapshot_by_id/   -> {shapes, as_of_version}
list_hosted_boards/         -> boards this node is currently hosting
```

### Support — `track_presence` (own app, not CMD/PRJ/QRY, no event store)

ETS roster per board, heartbeat sweep, presence-changed pubsub broadcasts.
Not event-sourced — see "Presence is not event-sourced" above for why.

### Umbrella layout

```
apps/
  guide_board_lifecycle/   CMD
  project_boards/          PRJ
  query_boards/             QRY
  track_presence/           support
  hecate_whiteboard/        domain glue: hecate_om_service impl, mesh boot wiring
  hecate_whiteboard_web/    Phoenix web app: LiveView + the Konva/perfect-freehand hook
```

---

## Risks / open verification items — RESOLVED 2026-08-25

1. **`hecate_om_service` from Elixir: works, confirmed live.**
   `HecateWhiteboard.Service` implements it directly
   (`system/apps/hecate_whiteboard/lib/hecate_whiteboard/service.ex`);
   `:hecate_om.boot/1` boots, auto-starts reckon-db + the evoq
   subscription, and serves `/health` correctly, in both a local `mix
   run` dev boot and the compiled `mix release` (`bin/hecate_whiteboard
   start`), and inside the actual container image. Two real bugs found
   and fixed along the way, both mine, both interop traps worth carrying
   forward to any future Elixir hecate_om consumer:
   - `HecateWhiteboard.Service.data_dir/0` and `config/runtime.exs`'s
     `identity_key_path` independently computed the data dir with
     *different* defaults (one `/var/lib/...`, one `/tmp/...`) — two
     sources of truth for the same env var, only one of which was
     dev-writable. Fixed by making both read `HECATE_DATA_DIR` with the
     same default.
   - **`data_dir/0`'s spec says `string()`, which in Erlang means a
     charlist, not an Elixir binary.** Returning an Elixir binary
     survives `filename:join/2` (returns a binary fine) but then crashes
     deep inside `ra`'s directory setup: `dets:open_file/2` rejects a
     binary `file` option outright with `{badarg, ...}`. Confirmed
     directly against this OTP: `dets:open_file(x, [{file, <<"...">>}])`
     raises, `dets:open_file(x, [{file, "..."}])` works. Fixed with
     `String.to_charlist/1` on every file-path-shaped `hecate_om` config
     value (`data_dir/0`, `identity_key_path`, `service_cert_path`,
     `station_socket`). **Any future Elixir service implementing
     `hecate_om_service` will hit this exact trap on `store_id/0` +
     `data_dir/0` unless it already knows this.**
2. **No Elixir scaffold generator: confirmed, worked around by hand.**
   Assembled via plain `mix new --umbrella` + `mix new --sup` per app,
   mirroring `hecate-mpong-bot`'s proven CMD-app shape and hecate-tube's
   actual (post-storm) `initiate_channel` desk triad. Not a blocker in
   practice — see `system/` for the result.
3. **LiveView-vs-mesh-lifecycle: still open, deferred on purpose.** Not
   reached yet — this walking skeleton has no LiveView/web app at all
   (see "Suggested build order" step 3 onward). Still the first real
   design question once `host_board` + the canvas UI start.

### New facts found during the build, not anticipated above

- **`mix release` for an umbrella needs an explicit `releases:` block**
  naming which child apps to include (`applications: [app: :permanent,
  ...]`) — plain `mix release` refuses with a clear error otherwise. See
  `system/mix.exs`.
- **The `[:erts]` copy race is real, not Erlang-specific.** `mix release`
  assembling `erts` via a parallel `Task` intermittently fails with
  `could not change mode for .../bin/erl: no such file or directory`.
  Reproduced locally on the very first `mix release` attempt.
  `ELIXIR_ERL_OPTIONS="+S 1" mix release` fixes it — same workaround
  `macula-realm`'s own Dockerfile already carries for the identical bug,
  confirmed independently here.
- **This workspace's committed-lockfile ban applies in full, and it
  breaks a naive Dockerfile.** `COPY mix.exs mix.lock ./` fails CI
  outright (`mix.lock` doesn't exist in the checkout, by design). The
  fix is to not copy it at all and resolve deps fresh every build — not
  specific to this repo, applies to every Elixir Dockerfile in this
  workspace.
- **A non-root container user fighting a bind-mounted `/data` is real
  friction, not a hypothetical.** Tried a `useradd --create-home app` +
  `USER app` runtime stage first; hit `{error, enoent}` from
  `filelib:ensure_path` on an unwritable bind mount. Matched
  hecate-tube's own Containerfile instead (root, no non-root user) — no
  UID-alignment problem to solve for a service with no untrusted input to
  sandbox against.
- **`network_mode: host` correctly resolves the container's Erlang
  distribution name to the actual host's hostname** (`hecate_whiteboard
  @host00.lab`, not a random container id) — confirmed locally with
  `RELEASE_NODE`/`RELEASE_DISTRIBUTION=name` set. Matters because those
  are mix release's own env var names, not hecate-tube's Erlang/relx ones
  (`HECATE_NODE_NAME`/`HECATE_COOKIE`) — copying the Erlang service's
  compose env vars verbatim would have silently done nothing.
- **hex.pm lag is real, not just a documented risk.** `hecate_om` 0.15.0
  exists in the local working tree's `.app.src` but was never published;
  hex.pm's actual latest is 0.14.2. Pinned to `~> 0.14.2`. (0.15.0 adds
  `read_model_id/0` for a barrel_docdb-backed read model — relevant to
  `project_boards`/`query_boards` later, not to this skeleton.)
- **Local dev Docker daemon needed explicit `--pids-limit -1 --memory
  2g`** to boot the release at all (`Cannot fork` otherwise) — a sandbox/
  daemon-config artifact of this particular dev machine, not something
  the beam fleet's own docker+watchtower setup is expected to need (not
  present in hecate-tube's compose either).

## Deferred, not decided against

- **Zero-install joining** (a public relay Phoenix app bridging
  browser↔mesh for people without their own node, mirroring the
  hecate-tube/macula-realm split) — explicitly deferred in favor of the
  same-app peer model for v1, not ruled out as a later addition.
- **Shape richness beyond stroke/generic shape** (sticky notes, text,
  images, groups/frames) — the CMD desk list above is deliberately just
  enough for a walking skeleton (draw, move, remove); a real event-storm
  pass will very likely expand `guide_board_lifecycle`'s desks the same
  way hecate-tube's did once a full spec landed.
- **Board discovery** (how a collaborator learns a board exists / gets
  invited) is unaddressed — `join_board` assumes the joining peer already
  has the host's address and board id somehow. Needs a decision (out-of-band
  link/QR vs. mesh-level discovery) before "join" is fully usable.

---

## Suggested build order (walking skeleton first, per this workspace's own convention)

Mirroring how hecate-tube's Phase 0 worked: prove the mechanism
end-to-end on the thinnest possible slice before building out the rest.

1. Scaffold the umbrella by hand (`mix new --umbrella`), stub
   `hecate_whiteboard`'s `hecate_om_service` callbacks, confirm it boots
   and joins the mesh, confirm `/health` responds. Resolves risk #1 and
   #2 above before anything else is built.
2. `initiate_board` + `archive_board` only — the walking skeleton per
   this workspace's convention (birth + death, nothing in between yet).
   Verify via a live boot smoke test (per the hecate-tube plan's reusable
   recipe), not just eunit/exunit — wiring bugs don't show up in unit
   tests here, they showed up twice in hecate-tube's own Phase 0.
3. **DONE 2026-08-25.** `host_board` + a real LiveView page. Konva was
   dropped in favor of plain HTML5 Canvas + a hand-rolled quadratic-curve
   smoother (no npm dependency) — Konva's object model (layers, shape
   dragging) isn't needed until `move_shape`/`remove_shape` exist; adding
   it now would have been exactly the kind of premature dependency this
   workspace's own style avoids. Proved the mesh-boot-to-browser path.
4. **DONE 2026-08-25.** `draw_stroke` end to end: one browser, one
   stroke, host aggregate, `project_boards` projection, back out to the
   same browser over Phoenix.PubSub (LOCAL pubsub, not yet mesh pubsub —
   that distinction matters for step 5). Verified with multiple strokes,
   multiple colors, and persistence across a page reload via
   `query_boards`' snapshot desk. Full detail, including two real bugs
   found (evoq_event_handler's actual contract vs. evoq_projection's
   unexercised documented one; the release's `applications:` list not
   auto-including new umbrella apps), in `CHANGELOG.md` and the commit
   message for `be2da6d`.
5. `join_board` + the snapshot/reconciliation protocol, second browser
   as a second peer. This is where risk #3 (LiveView-vs-mesh lifecycle)
   has to get resolved for real — and where local Phoenix.PubSub (used
   for step 4, same-host reactivity) has to become real mesh pubsub for
   a second peer on a different node to see live strokes at all.
6. `move_shape` / `remove_shape` / `leave_board`, `track_presence`
   (cursors), rest of the desk list.

### Basic mesh replication — DONE 2026-08-25 (a lighter version of step 5)

Not the full `join_board` + snapshot-reconciliation protocol yet -- a
simpler first cut, since both beam01 and beam02 already independently
host the SAME fixed default board_id. Each host now republishes every
LOCALLY-drawn stroke to a fixed mesh pubsub topic
(`io.macula/whiteboard-commons/whiteboard/stroke_drawn_v1`, board_id in
the payload not the topic) via `guide_board_lifecycle`'s
`StrokeDrawnV1ToMesh`, and subscribes to the same topic via
`project_boards`' `BoardMeshSubscriber`, which writes incoming remote
strokes straight into the ETS read model (never through the local
aggregate -- that asymmetry is what keeps it loop-free without an
origin tag). **Verified live and bidirectional**: a stroke drawn on
beam01 appears on beam02 within seconds and vice versa, in the correct
color, over real macula pubsub.

Three real bugs found and fixed getting there, all live-diagnosed on
the actual fleet (local dev sandbox couldn't reach the mesh at all —
see the risk-verification note below):

1. **Payload keys arrive as atoms, not `{text, _}`-tagged.** macula
   10.1.1 does the same "atomize if this VM already knows the atom"
   decoding for plain pubsub that `reference_macula_rpc_stream_args_atom_keys`
   only documented for RPC/stream args before this — that memory (and
   the older `erlang_macula_sdk_payload_keys` it superseded) is updated.
   Fixed by tolerating both shapes, not picking one.
2. **Cold-boot race on `HecateWhiteboardWeb.PubSub`.** The umbrella's
   real boot order (from actual `mix.exs` deps, not `releases()` list
   order) has `project_boards` always start before
   `hecate_whiteboard_web` — a mesh event arriving in the gap crashed on
   "unknown registry". Fixed by moving PubSub ownership to
   `project_boards` (the writer side), as its own first child.
3. **evoq's catchup replay re-publishes local history on every
   restart** — not fixed, documented as a known gap in
   `StrokeDrawnV1ToMesh`'s own header (same root cause as
   `BoardMeshSubscriber`'s pre-existing "no dedup" note: a
   stroke_id-keyed dedup on the receiving side would fix both).

### Known simplifications carried from the walking-skeleton phase

- `check_origin: false` on the Endpoint (no fronting domain yet).
- `SECRET_KEY_BASE` falls back to a fixed, publicly-committed dev value
  (see `config/runtime.exs`) — nothing of real value depends on it yet
  (no accounts, no forms), but this needs a real provisioned secret
  before this is anything more than a demo.
- The default board (visited at `/`) is still a single fixed id
  (`@default_board_id` in `board_live.ex`) — no board creation/picker
  UX. `join_board` (below) now lets a second peer target a SPECIFIC
  *other* board_id via `/board/:board_id`, but there's still no UI to
  mint a fresh one or discover what board_ids exist.

### `join_board` — DONE 2026-08-25 (discovery + snapshot, view-only)

Not the single-authority join this doc originally sketched under
"Late-join snapshot, not full replay" (client subscribes, buffers,
snapshot carries `as_of_version`, client filters the buffer) — the
default board already broke that model by being symmetric gossip
between two simultaneous "hosts" of the same id (see "Basic mesh
replication" above), so `join_board` needed a discovery step that
design never had to solve: **how does a joining peer learn WHICH host
serves a given board_id at all?** Asked the user rather than guessing
at a flagship-app UX decision; picked **mesh-level discovery** over an
out-of-band host link.

**Shape that shipped**, all in `query_boards`:

- `QueryBoards.GetBoardSnapshotByIdOverMesh` (client): publishes a
  `board_snapshot_query_v1` fact naming a fresh per-call reply topic,
  subscribed to *before* publishing (so a fast responder can't answer
  before anyone's listening — same subscribe-first principle this doc
  always had, just applied to the query round trip instead of a stroke
  buffer). One round trip, not "discover a host, then RPC it" — the
  reply already carries the full snapshot.
- `QueryBoards.AnswerBoardSnapshotQueries` (host): permanently
  subscribed to that same topic on every node. Answers only if
  `GetBoardSnapshotById` finds a *local* `boards` row (a pure
  mesh-replica peer never gets one — `BoardMeshSubscriber` only ever
  writes into `board_shapes`, never `boards`, so the existing read
  model shape already tells "I host this" from "I've just seen its
  strokes go by" apart, no new flag needed) AND that row's
  hosted+not-archived bits say so (the exact same bits `BoardLive`
  already reads for `can_draw?`).
- Both directions go through macula's *supervised* pairs
  (`macula_publisher`/`macula_subscriber` via `QueryBoards.MeshPublisher`
  / `QueryBoards.OneShotMeshReply`), never a raw `macula:publish/4` or
  `macula:subscribe/5` call — told directly by the user mid-session, not
  a preference this doc had recorded before.
- A successful reply is materialized into `project_boards`' own ETS
  tables through the same `Store.new_stroke?/1` dedup gate the two
  existing writers use, with the **hosted bit deliberately cleared** —
  this node isn't the aggregate authority for a board it joined, so
  `BoardLive`'s existing `can_draw? = hosted? and not archived?` makes a
  joined board correctly read-only with zero template changes.
- `as_of_version` is real now (`GetBoardSnapshotById`'s third field,
  backed by `Store.note_stroke_version/2`, fed from the wrapped event's
  own top-level `version` — see "Event shape on the wire" above) but
  isn't consumed by any buffering logic yet, because there's no
  buffering logic left to consume it: `BoardMeshSubscriber` is a single
  always-on global subscriber (not spun up per-join), so it's *already*
  passively dedup-applying every board's live strokes the instant they
  hit the mesh, whether or not a local LiveView is watching that
  board_id yet. Combined with the snapshot materializing through the
  identical dedup gate, whichever arrives first (a live broadcast vs.
  the snapshot reply) wins and the other is a no-op — the race
  `as_of_version` was designed to resolve is already resolved by
  construction. It's carried on the wire and stored per board in case a
  future increment needs to reason about "how far has this board's
  history genuinely advanced," not dead weight, just not load-bearing
  for correctness today.
- Route: `/board/:board_id` (kept `/` behaving exactly as before — the
  fixed default, auto-hosted). A board nobody on the mesh answers for
  (timeout, `@default_timeout_ms` 3s) redirects to `/` rather than
  stranding the visitor on a dead page.

**Writing from a joined board — DONE 2026-08-25, same day.** Was
view-only at first (see above); user asked "I cannot draw on a remote
whiteboard?" and the write-relay got built same session. `MaybeDrawStroke.
relay/1` publishes the raw draw params (board_id, points, color, width)
instead of dispatching locally, to a fixed `draw_stroke_request_v1`
topic every node listens on (`AnswerDrawStrokeRequests`). The responder
does nothing clever: it calls `MaybeDrawStroke.dispatch/1`, the SAME
function a local draw already uses, and lets `BoardAggregate`'s
existing `:not_hosted` business rule do the authority check for free —
on every node except the real host, dispatching against a board this
node never hosted (or never even initiated) returns
`{:error, :not_hosted}`, silently dropped. On the real host it succeeds
exactly like a local draw, and the confirmed stroke comes back to the
relaying peer through the ALREADY-existing `stroke_drawn_v1` ->
`StrokeDrawnV1ToMesh` -> `BoardMeshSubscriber` path it already watches
to view the board — no reply/ack mechanism needed at all.

`can_draw?` broadened to `not archived?` (drawing works whether or not
this node hosts the board); a new, separate `can_rename?` stays
`hosted? and not archived?` so broadening draw permission didn't
silently also enable renaming a board this node doesn't own. Status
dot gets a third state (`dot-relay`, sage, distinct from amber
`dot-live`) so a relay-drawable board still visibly isn't "the one true
server" the way a hosted one is — same host/peer honesty this app has
had since session 1.

Added the one test that was missing and turned out to be load-bearing:
`draw_stroke`'s `:not_hosted` rejection had never been tested despite
being the exact mechanism the whole relay design depends on for safety.

**Live-verified in a real browser**: opened the beam01-only "Join test
board" from beam02 (view-only before this), confirmed the status dot
was sage not amber, drew a stroke on beam02's canvas, then opened the
SAME board on beam01 in a second tab and confirmed the identical stroke
was there too — the relay genuinely reached the real host, not just a
local-only optimistic draw.

### Third peer: msi00.lab — DONE 2026-08-25, same day

User asked whether every mesh-broadcast mechanism built today (basic
replication, `join_board`, the board-list picker, write-relay) would
actually hold with more than two participants, then asked to deploy a
third peer to prove it rather than just reason about it. Every one of
those mechanisms was ALREADY designed broadcast-first, not pairwise —
a query collects replies from whoever answers, a relay dispatches
everywhere and lets the aggregate's own rule filter to one, stroke
replication is a shared topic with no notion of "the other peer" at
all — so the claim was that node count should not matter. Untested
until now.

**Deployment shape is genuinely different from beam01/beam02**, not
just a third copy of the same thing: msi00.lab runs podman + Quadlet
units + `podman auto-update` (registry polling), not docker + compose +
watchtower + the pull-based git reconciler the beam fleet uses — see
`macula-io/macula-demo`'s own `infrastructure/msi00.lab/
hecate-whiteboard.container` for the unit, mirroring that node's
existing `hecate-dronex.container`/`hecate-embedder.container`
conventions (own disk at `/home`, no `/bulk0`, no `:Z` — Arch, no
SELinux — every env var explicit, conservative `CPUQuota`/`MemoryMax`
since this is somebody's workstation and not a fleet box). Installed
via the `hecate-reconciler.service` already running on that node
(watches `~/.hecate/gitops/` locally, symlinks into
`~/.config/containers/systemd/`) — confirmed with the user as the
intended path for new msi00 services, since the workspace-level note
calling that mechanism "temporarily obsolete, do not build on it" was
written before dronex started actually using it.

`HECATE_REALM` had to be the byte-identical value beam01/beam02 already
hold, or this peer would boot fine and just never find their boards —
propagated node-to-node (beam01 → msi00) via a generalized
`scripts/enroll-hecate-whiteboard-secret.sh --from-node` mode in
macula-demo, SSH-to-SSH, never transiting the workstation that
triggered it. Found and fixed two real bugs getting a clean boot:

1. The secret script's own hex-format validation assumed lowercase-only
   (matching `enroll-dronex-secret.sh`'s convention for a DIFFERENT
   realm), but the actual deployed `HECATE_REALM` on beam01/beam02 uses
   uppercase hex. Fixed to accept both cases, preserving whatever case
   arrives verbatim rather than normalizing it.
2. Podman does not auto-create a bind-mount source directory the way
   `docker compose` does — first boot failed with
   `statfs: no such file or directory` until `~/.hecate/hecate-whiteboard`
   existed on the host first.

**Live-verified as genuinely 3-way, not just "a third node exists"**:
opened `/boards` on msi00 cold and it correctly listed BOTH beam01's
and beam02's boards under "on other nodes" in the same ~1.5s query
window the 2-node version already used — the multi-reply collector
needed no change at all to handle a second remote answerer. Drew a
stroke on msi00's own default board and confirmed the exact stroke_id
landed in BOTH beam01's and beam02's read models (not just an
increased count, which today's earlier catch-up-replay history made an
unreliable signal on its own); drew the reverse direction (beam01 →
msi00) and confirmed msi00 received it too. Every mechanism proven
broadcast-safe today was actually only ever tested pairwise before
this — this is the first real N-way confirmation, N=3.

**Then asked and confirmed a sharper question**: msi00's first cut
pointed at the SAME station as beam01/beam02 (frankfurt), for
simplicity — meaning every message in that first round still fanned
out from one shared relay, and the whole "3-node" proof above didn't
actually show discovery/replication survive a real cross-station hop.
Repointed msi00 at `station-it-milan` (the same one `hecate-dronex`
already leads with from that node, so no new station enters the
topology) and re-ran everything: `/boards` discovery still found both
beam boards through the Milan relay, and a stroke_id drawn on msi00
was confirmed present on both beam01 AND beam02 (and the reverse,
beam02 → msi00) with the two ends now genuinely routing through
different stations rather than a shared one. This is the version of
the claim actually worth trusting.

**Verification status: live-verified end to end, 2026-08-25.** Unit
tests cover `AnswerBoardSnapshotQueries`'s gating logic and the
mesh-unavailable short-circuit; a local boot confirmed the two
locally-provable paths (`/` still works; `/board/:known-local-id`
finds it locally; `/board/:unknown-id` redirects cleanly with no mesh
up). Then, against the real fleet: minted a fresh board_id via
`bin/hecate_whiteboard rpc` on beam01 ONLY (`initiate_board` +
`host_board`, title "Join test board"), never touched on beam02, then
visited `/board/<that-id>` on beam02 cold. Confirmed via both nodes'
logs (`[GetBoardSnapshotByIdOverMesh] query ...` on beam02 at
13:18:31.192, `[AnswerBoardSnapshotQueries] reply ...` on beam01 at
13:18:31.210 — an 18ms round trip) and the rendered page: beam02 shows
the correct title from a board it never locally created, with
`data-can-draw="false"` (view-only, correctly not the authority),
while the SAME board_id on beam01 itself still shows
`data-can-draw="true"`.

### Board picker — DONE 2026-08-25

User asked "is there a way to select a board?" -- there wasn't (URL-only,
no create UX). `QueryBoards.ListHostedBoards` reads `project_boards`'
`boards` table, filtered to hosted+not-archived (same bits `can_draw?`
already reads) -- deliberately does NOT also list boards this node has
merely joined/cached via mesh, since a stale one-off join snapshot in
that list would mislead more than help. `HecateWhiteboardWeb.BoardsLive`
at `/boards` renders them as cards plus a "new board" form that mints +
hosts a fresh board through the ALREADY-EXISTING `initiate_board`/
`host_board` desks (`MaybeInitiateBoard.dispatch/1` already minted fresh
ids; it just had no UI wired to it). The main board view's brand/logo now
links to `/boards`.

Found and fixed a real bug before shipping: the `boards` table's stored
row doesn't carry `board_id` in its VALUE (only the ETS key does -- same
shape `GetBoardSnapshotById` already accounts for). The first cut of
`ListHostedBoards` discarded the key and crashed `KeyError` the instant a
real board existed. The test written first didn't catch it either (it
also put `board_id` in the value, matching the bug's wrong assumption
rather than the real shape) -- rewritten to match reality, confirmed red
without the fix, green with it before trusting the green.

Verified against a local boot: empty state renders, a board created
through the real dispatch chain shows up on `/boards`, and the topbar
link round-trips.

### evoq catch-up bug — FOUND AND FIXED 2026-08-25

Deploying the board picker surfaced something much bigger than the
picker itself. beam01 restarted for the deploy and came back showing "No
boards hosted here yet" / 0 strokes on a board that had strokes drawn on
it earlier the SAME session. beam02 (hadn't restarted since the
`join_board` deploy) still showed 2 strokes on the same-shaped board --
clean before/after proof this was restart-triggered, not a picker bug.

Root cause, confirmed by reading `evoq_store_subscription.erl` directly:
evoq's one-time catch-up replay runs synchronously as part of
`hecate_om:boot/1`, before ANY sibling umbrella app -- the one that
actually owns the projection handlers -- has booted. It scans real
history with **zero handlers registered**, and the module's own "new
event type registered ... already covered by `$all`" branch was a no-op
that never backfilled what catch-up had already scanned-and-discarded.
Not hecate-whiteboard-specific: this hits any evoq consumer shaped like
this workspace's own CMD/PRJ/QRY vertical-slice convention (separate
umbrella apps booting in sequence), so it likely also silently affected
other real evoq consumers in this workspace on any restart with real
accumulated history, before the fix.

Asked the user how to handle it given the size of the detour (fix now vs.
log-and-stop) -- user chose fix now. Fixed at the source in the real
`reckon-db-org/evoq` repo: `evoq_store_subscription`'s
`{new_event_type, EventType}` handler now backfills that one type's
history instead of doing nothing, filtered so already-covered handlers
see no redundant delivery, reusing the subscription's own running `seq`
counter so no version collisions. Shipped as **evoq 1.23.1** (patch, no
public API change) -- 110 eunit tests (4 new) green, dialyzer/elvis/ex_doc
all clean, no new findings. User published to hex.pm.

**Live-verified the fix, not just the mechanism.** Triggered a manual
hecate-whiteboard rebuild (`gh workflow run build-push.yml` -- no code
change needed, `{:evoq, "~> 1.23"}` already covered 1.23.1 and this repo
never commits `mix.lock`), confirmed the build log resolved `evoq
1.23.1`, watched watchtower roll it to both nodes. beam01's restart is
the textbook confirmation: boot log shows the ORIGINAL failure signature
(`handlers=0` for all 14 events during catch-up) immediately followed by
the fix firing per type (`Backfill board_store/stroke_drawn_v1: matched
3 of 14 scanned`, etc., seq advancing cleanly 0→3→6→13→14) -- read model
came back fully intact (3 strokes, both boards) instead of empty. beam02
confirmed unaffected too (2 strokes, exactly matching pre-restart).
`join_board` regression-checked working afterward.

### Board picker went mesh-aware, plus `rename_board` — DONE 2026-08-25

User feedback after using the deployed app: "beams don't see each
other" and "can't change the title of an existing board." Investigated
the first before assuming it was real -- dispatched a stroke on beam01
via RPC, confirmed it appeared on beam02 within seconds (and the
reverse), so live drawing replication was never broken. The actual
issue: `/boards` only ever listed boards THIS node hosts, so beam01's
and beam02's picker pages showed disjoint lists with no indication
there was more elsewhere.

Fixed with a second query/reply pair, same supervised
macula_publisher/macula_subscriber shape as `join_board`:
`QueryBoards.AnswerBoardListQueries` answers on every node (no
authority gating -- "what do I host" is always safe to say, unlike
`join_board`'s single-authority question), and
`QueryBoards.ListBoardsOverMesh` collects replies for a fixed 1.5s
window instead of stopping at the first one (a new
`QueryBoards.ManyShotMeshReply` subscriber variant forwards every
message rather than stopping after one). Merged results dedup by
board_id (the default board is legitimately multi-hosted under
symmetric-gossip replication) and tag each board with which host
answered. Fetched via LiveView's `start_async/3` so the page never
blocks -- local boards render immediately, mesh results fill in a
moment later.

`rename_board` (CMD desk, mirrors `archive_board`'s shape exactly:
`rename_board_v1` -> `board_renamed_v1`, gated the same way --
`:not_initiated` / `:archived`) makes the topbar title clickable
(only when this node hosts the board) into an inline-editable input.

**Live-verified both, together, in a real browser** (not just curl):
opened `/boards` on beam01 and beam02 side by side, confirmed each
correctly showed the other's boards tagged "view only." Renamed a
board on beam02 (one the browser testing itself had created earlier,
titled "Untitled board" by the create form's own empty-title default
-- a second, confusingly-identical "Untitled board" sitting right next
to the real default board, which is exactly the kind of mess
`rename_board` exists to let someone clean up) to "beam02 test board"
by clicking the title, typing, and pressing Enter -- confirmed it
persisted across a reload AND propagated to beam01's mesh-discovered
list within the same 1.5s query window, no manual refresh needed
beyond the normal page load.

### All three peers on distinct stations, header shows which — DONE 2026-08-25

beam01 and beam02 had both stayed on `station-de-frankfurt` since the
walking-skeleton phase; only msi00 had been deliberately repointed
(see "Then asked and confirmed a sharper question" above). Repointed
beam01 to `station-de-falkenstein` and beam02 to `station-fi-helsinki`
in `macula-io/macula-demo` (`infrastructure/beam0{1,2}.lab/
hecate-whiteboard-config.env`), after confirming via `dig AAAA` that
all three candidate stations (falkenstein, helsinki, milan) resolve to
three distinct IPv6 addresses -- this workspace has a documented
history of a station hostname silently repointing to a different box,
so the check was made, not assumed. Pushed, triggered
`hecate-reconcile.service` on both beam nodes rather than waiting for
the 2-minute timer, confirmed each container recreated with the new
`MACULA_STATION_SEEDS` via `printenv` inside the container.

**Live-verified both directions, by stroke_id, across all three now
genuinely distinct stations:** dispatched a stroke directly on beam01
(Falkenstein) via RPC, captured the aggregate-assigned stroke_id
(command-supplied stroke_ids are overridden server-side, learned mid
this verification), and found that exact id in beam02's (Helsinki)
and msi00's (Milan) `ProjectBoards.Store` ETS tables within 3s.
Reversed it: called `MaybeDrawStroke.relay/1` from msi00 against
beam01's hosted board, then confirmed the resulting stroke_id landed
on both beam02 and back on msi00 itself. No two peers shared a relay
for either direction of this test.

The topbar's host label (`{@host_label}`, `board_live.html.heex`) now
reads `"{host} via {station}"` (e.g. `"beam01 via de-falkenstein"`)
instead of the bare host. `host_label/0` in `board_live.ex` reads
`MACULA_STATION_SEEDS` from the OS environment at render time (the same
var the container is already configured with, nothing new to
provision) and extracts the short station name with a regex
(`station-([a-z0-9-]+)\.macula\.io`); falls back to the bare host if
the env var is unset (local dev, no mesh). `boards_live.ex` has its
own separate `host_label/0` used only as the `owner` attribution string
on newly-created boards -- deliberately left alone, unrelated to this
display and changing it would alter stored board data for no reason
the user asked for.

### Presence and live cursors — DONE 2026-08-25

The last piece this doc's own "Architecture decisions" section scoped
but never built. Followed the locked-in design exactly (see "Presence
is not event-sourced" above): a new support app, `track_presence`, not
CMD/PRJ/QRY, no event store involvement for the ephemeral part.

**Scope, decided with the user before writing any code** (two
AskUserQuestion rounds -- this was genuinely a fork with real bandwidth
implications, not a call to make alone): cursors are mesh-wide, not
scoped to a single node's viewers, and a moving cursor is
debounced-on-stop (~400ms of stillness before this browser tells the
server where it settled) rather than streamed continuously -- a
fast-moving pointer produces zero mesh traffic, only its resting points
do. Visually, a settle is a hard jump to the new position with the old
marker left behind as a ~550ms fading ghost (`.cursor-ghost` /
`.cursor-ghost-fade` in app.css), so motion between two rests doesn't
read as dead without implying the renderer knows the path the real
pointer took.

**`TrackPresence.Roster`**: ETS `{board_id, peer_id} -> %{x, y, color,
label, last_seen}`. `touch/1` (local origin) writes + broadcasts
locally (`HecateWhiteboardWeb.PubSub`, same `"board:" <> board_id`
topic shapes already use) + publishes to mesh; `absorb_remote/1` (mesh
origin) writes + broadcasts locally only -- same asymmetry
BoardMeshSubscriber uses for strokes, and for the same reason: it's
what keeps this loop-free. `TrackPresence.Sweep` ages out rows
untouched for >20s every 5s, independently on every node, so an
ungraceful disconnect (network drop, crash) needs no cross-node
coordination to self-heal.

**`leave_board`** (new CMD desk, `guide_board_lifecycle`): the one
presence fact that IS event-sourced, per the original design decision.
Mirrors `rename_board`'s command/event/handler shape and `draw_stroke`'s
write-relay shape (dispatch locally if hosted, else relay over mesh to
whoever actually hosts the board) -- but deliberately has NO archived
guard, unlike every other desk: leaving doesn't mutate board content,
so it stays valid even on an archived board. `PeerDepartedV1ToMesh`
republishes it so every peer clears that cursor immediately instead of
waiting out Sweep's timeout. Called from `BoardLive.terminate/2`,
guarded on `connected?(socket)` -- terminate/2 also fires for the
disconnected static-render pass every mount does first, which never
touched presence at all.

Identity is anonymous and ephemeral, matching "presence is ephemeral
session state" -- a random peer_id per LiveView mount (a refresh is a
new peer, not a reconnect), a deterministic peer_id-hash color, and the
label reuses `host_label()` (the same "{host} via {station}" string the
topbar now shows, see the section above), so a cursor's tag tells you
which physical peer it's coming from for free.

**Live-verified locally first** (`mix phx.server`, real browser
automation, two tabs on the same board): moved the pointer in tab 2,
confirmed tab 1 rendered a labeled cursor at the settled position after
the debounce; moved again and caught both the new marker and the old
one's fade-out ghost in the same screenshot; closed tab 2 and confirmed
the cursor disappeared via the graceful-leave path. **Then confirmed
the header-label change (previous section) was already live on all
three deployed nodes** without a separate redeploy step -- watchtower
had already rolled beam01/beam02 to that commit's image before this
session got to checking (`curl .../` on each showed "beam01 via
de-falkenstein", "beam02 via fi-helsinki", "msi00 via it-milan"
respectively), confirming task ordering doesn't have to block on manual
redeploy checks when watchtower/podman-auto-update are already doing
their job.

**Then a real deploy bug, caught by the user testing live**: "when i
draw on the beam01 test board, it doesn't show up on beam02." The
presence/cursors push had broken the container build --
`system/Dockerfile`'s staged `COPY apps/<app>/mix.exs` lines (kept
deliberately separate from `COPY apps` itself, so the dependency-only
layer survives lib/ changes) were never updated for the new
`track_presence` app, so `mix deps.compile` failed inside the image
build with "Cannot compile dependency :track_presence because it isn't
available" -- CI's build-and-push job failed outright, ghcr never got a
new `:latest`, and watchtower/podman-auto-update correctly found
nothing to pull. What the user was actually looking at was the
STILL-RUNNING previous image (confirmed via `docker inspect`'s image
digest and `docker logs` showing no recent restart). Live-tested
drawing on that previous image via real browser tabs on beam01 and
beam02 and it replicated fine in ~2-3s, which is what pointed at "never
shipped" rather than "shipped and broken."

Fixed with one added `COPY` line, verified with a full local `docker
build` before pushing again (this time actually building past the
point the previous attempt failed). Confirmed the fix landed
correctly: CI green, all three nodes independently picked up the new
image within about 90 seconds of the push with no manual trigger
needed this time, `docker logs`/`podman logs` on each showed both new
mesh subscribers (`CursorMeshSubscriberStarter`,
`PeerDepartedMeshSubscriberStarter`) starting cleanly with no errors.
**Then re-ran the exact scenario the user reported**, live, in real
browser tabs against the NOW-CORRECT deployed image: drew on beam01,
watched it appear on beam02 within a few seconds; separately confirmed
mesh-wide cursor presence the same way (hovered on beam01, watched a
cursor labeled "beam01 via de-falkenstein" appear and track movement
on beam02's tab). One early screenshot right after a fresh tab
navigation looked like a stroke had failed to replicate at all
(neither side showed it) -- turned out to be a stale first-mount
snapshot race with the browser automation tool's own screenshot timing,
not a real gap; redrawing and re-checking a few seconds later showed it
had landed correctly on both sides all along.

### Toolbox side pane: text, selection, sticky notes — DONE 2026-08-25

Also archived every accumulated test board (`archive_board`, already
built) across all three nodes first, per the user's own request to
clear them before building this -- the default board has a genuinely
separate local history per node (each one self-hosts it independently,
see the "multi-hosted symmetric gossip" note elsewhere in this doc), so
archiving it needed one dispatch per node, not one dispatch that
somehow propagates.

Two real design forks here were the user's call, not mine, asked via
AskUserQuestion before writing code: archive vs. hard-wipe for the test
boards (archive won, reversible, keeps this app's own
event-store-immutable principle intact), and how far selection should
reach in this pass (select+move+delete won, not select-only or
select+delete -- the fuller scope, roughly double the backend of the
minimal option).

**New shapes: sticky notes and text labels**, alongside the existing
freehand stroke. Four new CMD desks in `guide_board_lifecycle`
(`place_sticky`, `place_text`, `move_shape`, `remove_shape`), each
mirroring `draw_stroke`'s write-relay shape (dispatch locally if
hosted, relay over mesh otherwise) -- except the relay/mesh-replication
PLUMBING is shared across all four (`AnswerShapeMutationRequests` one
topic, `ShapeMutatedV1ToMesh`/`ShapeMeshSubscriber` one topic each),
not duplicated four times like `draw_stroke`'s own topic-per-command
precedent -- these four are genuine siblings of one "shape mutation"
concern, unlike `draw_stroke` vs `rename_board`, which aren't.
`move_shape` works identically across every shape kind because every
`board_shapes` row now carries `points` uniformly (a stroke's many
points, or a sticky/text's single anchor wrapped in a one-element
list) plus a shared `shape_id` (a stroke's own `shape_id` equals its
`stroke_id`) -- see `ProjectBoards.Store.move_shape/3`'s own header.
`remove_shape` has no archived guard exception the way `leave_board`
does; placing/moving/removing content is a mutation like drawing ink,
so it uses the exact same hosted/not-archived guard `draw_stroke` does.

**Rendering is a deliberate hybrid**: strokes stay on `<canvas>`
(unchanged, already proven), stickies and text render as plain DOM
elements in a new `#board-canvas-shapes` layer -- a native DOM element
gives free click targets, drag, and text layout for something with
exactly one anchor point, which canvas hit-testing would have made
harder for no benefit. Selection has to bridge both substrates: a
sticky/text click is a normal DOM `pointerdown` on its own element; a
stroke click is a distance-to-nearest-segment hit test against
`this.shapes`' stored points, inside a cheap bounding-box pre-filter.
Both converge on the same `move_shape`/`remove_shape` commands either
way.

**Sticky note colors are the classic Event Storming legend**: orange
(Domain Event), blue (Command), yellow (Actor), purple (Policy), green
(Read Model), pink (Hotspot) -- six swatches, each also a tool
selector (clicking one both picks the color and switches to the sticky
tool, same one-click-does-both convention the existing ink swatches
already used for the pen tool).

**Sticky/text placement uses a real local-then-confirmed pattern**,
matching strokes: clicking places a local, uncommitted `<textarea>`
sized/colored like the eventual shape; typing and blurring (or Enter)
dispatches the real command only if non-empty, and the confirmed shape
renders moments later via the normal broadcast path, same as a
just-drawn stroke's own round trip.

**A real, load-bearing bug found and fixed during live verification**:
placing a sticky or text label silently did nothing, every time, with
no visible trace and no console error. Root cause: calling
`textarea.focus()` synchronously inside a `pointerdown` handler doesn't
reliably "stick" -- the pointerdown event's own default focus handling
runs AFTER the handler returns, and since the canvas itself isn't
focusable, that default action re-focuses `<body>`, firing the
textarea's `blur` handler before a single character could be typed;
`commit()` then saw an empty value and silently discarded the element.
Fixed with `e.preventDefault()` on the pointerdown for the text/sticky
branch specifically (not needed for the pen or select branches, which
have no synchronous-focus step to protect). Found by direct DOM/JS
diagnosis after browser-automation clicks kept producing no visible
effect -- narrowed it down by dispatching raw `PointerEvent`s via
`javascript_tool` (bypassing whatever the click-simulation layer itself
does differently for a plain click vs. a real drag, which turned out to
be a red herring, not the actual cause) and confirming the element WAS
being created and removed within the same synchronous call stack.

**Live-verified locally** (`mix phx.server`, direct `PointerEvent`
dispatch to sidestep the browser-automation tool's own click-dispatch
unreliability in this session, confirmed the app's real listeners
behave identically to genuine input either way): placed a sticky note
and a text label, confirmed both rendered correctly; selected each via
the select tool, dragged both to new positions, confirmed the move
round-tripped through the server (checked 400ms after release, past
the full push/broadcast/push_event cycle, not just the local optimistic
frame); deleted both via the Delete key; separately selected, moved,
and deleted a hand-drawn STROKE through the same select tool, proving
the canvas-hit-test path (not just the DOM path) works too. Then a full
local `docker build` to confirm the image actually builds (the
previous feature's own lesson, applied immediately rather than trusting
CI to catch it first).

**Known simplification, not fixed this pass**: the topbar's stroke
count only ever increments (on `stroke_drawn_v1`), never decrements on
`shape_removed_v1` -- cosmetic only, the read model itself is correct,
just the displayed count can overstate what is currently on the board
after a delete.

### Stale-asset cache bug — FOUND AND FIXED 2026-08-25, same day

User report right after the toolbox shipped: "i can't seem to be able
to type text (no dashed target box, cursor doesnt change)" / "postits
don't draw ... can i type text in a postit?" This looked at first like
the toolbox itself was still broken, but a careful re-verification
(after discovering and working around an unrelated coordinate-scaling
mismatch in this session's own browser-automation tool -- screenshots
report 1568px width, the real viewport is 1900px CSS px, and clicking
at a screenshot-space coordinate without converting it lands somewhere
else entirely; ref-based element clicking sidesteps this cleanly)
showed the shipped code working correctly end-to-end: tool switch,
placement, typing, all fine.

That mismatch pointed at the real cause: `curl -I` on the deployed
`/assets/app.js` showed `Cache-Control: public` with no `max-age`, no
`immutable`, no `Last-Modified` -- this repo's plain esbuild output (no
`mix phx.digest`, no content-hashed filename, per its own Dockerfile
comment on why not) gives the browser no reliable freshness signal at
all. A browser's heuristic caching can and does serve a stale bundle
indefinitely across a redeploy, completely silently -- no error, no
console warning, the page just keeps running yesterday's JS forever
under an unchanged URL. The user's report landed right after this
session announced the toolbox as "live," which fits: their browser had
almost certainly already fetched `/assets/app.js` once before that
point and never refetched it.

Fixed by baking the git commit SHA into the asset URLs themselves
(`/assets/app.js?v=<sha>`), so every deploy is a genuinely new URL and
a stale cache can never survive one. `HecateWhiteboardWeb.BuildInfo`
reads `GIT_SHA` via a module attribute (compile-time, not a runtime
`System.get_env/2` call), so the value survives into the release with
no cross-stage ENV plumbing between the Dockerfile's build and runtime
stages -- it's baked into the compiled `.beam` bytecode during the
build stage, where `ARG GIT_SHA` / `ENV GIT_SHA` are declared right
before `mix compile`, late enough that it doesn't bust the
`deps.get`/`deps.compile` cache layers on every commit. CI now passes
`build-args: GIT_SHA=${{ github.sha }}` to `docker/build-push-action`.

Also fixed the *actually* real (if smaller) usability gap the report
surfaced: every non-select tool used the exact same `cursor: crosshair`
value, so switching tools gave no visible feedback at all -- confirmed
via `getComputedStyle`, not assumed. Text and sticky now show `text`
(both ultimately open a typeable textarea); pen keeps crosshair; select
keeps the default arrow.

Verified the whole fix locally first: full `docker build --build-arg
GIT_SHA=testsha1234567890 --load`, ran the resulting image (hit the
same `--pids-limit -1 --memory 2g` local-Docker-daemon requirement this
doc already documented for hecate-whiteboard's own release boot), and
confirmed via `curl` that the rendered HTML actually carried
`app.js?v=testsha12345` / `app.css?v=testsha12345` before pushing.

### Toolbox v2: basic shapes, copy/paste, collapse, ghost preview — DONE 2026-08-25

A follow-up request against the shipped toolbox, seven items, "ultrathink"
against all of them before writing code rather than taking each in
isolation. Kept `TOOLS` as the section label (the user retracted the
`DRAW` rename mid-turn -- "hadn't seen it", not a real preference against
it), renamed `STICKY NOTES` to `EVENT STORMING`.

**Design calls made without asking**, stated up front rather than as
four separate questions: copy/paste needed zero backend changes (paste
just re-dispatches the same command a fresh placement would use --
`draw_stroke`/`place_sticky`/`place_text`/`draw_geometry` -- each of
which already mints its own `shape_id` server-side, so a paste is
indistinguishable from a new shape to the server); collapse shrinks to
an icon-only strip, not fully hidden, so tools stay one click away;
basic shapes are click-drag-to-size like every other drawing tool,
outlined (not filled) in the Pen tool's own ink palette rather than a
third color picker; "show the sticky while dragging" got read as two
things and both got addressed -- a live cursor-following ghost preview
before a sticky is placed (there was previously zero feedback until the
click), and confirming an *already-placed* sticky visibly follows the
cursor during a select-tool drag (this was already true, just verified).

**Basic shapes** (`draw_geometry` CMD desk, `geometry_drawn_v1`,
rectangle/ellipse/triangle): shares `guide_board_lifecycle`'s existing
shape-mutation relay/mesh plumbing (`AnswerShapeMutationRequests`/
`ShapeMutatedV1ToMesh`) rather than a dedicated pair -- a basic shape is
a sibling of "place a sticky"/"place a text label", not a separate
feature. `points` is always the two opposite bounding-box corners; move/
remove/select all work on it for free through the existing
kind-agnostic points+shape_id machinery, no new backend needed for
those three at all.

**Client rendering stays the deliberate hybrid**: strokes and basic
shapes on `<canvas>` (a generic `drawShape` dispatcher by kind, shared
by the confirmed layer, the live drag-to-size preview, and the live
selected-shape-move preview, so all three can never visually disagree),
sticky/text as DOM elements. Hit-testing for basic shapes is plain
bounding-box containment (with the same padding threshold strokes use)
-- deliberately simpler than a stroke's segment-distance test, since a
rectangle/ellipse/triangle's own outline isn't the useful click target,
its visual footprint is.

**Sticky notes are now A\*-ratio** (ISO 216, 170x120 against
sqrt(2)'s 1.414:1 -- close enough nobody will measure it), fixed height
with `overflow-y: auto` instead of the old `min-height`, so long text
scrolls inside the note instead of growing it off-ratio.

**A real bug found and fixed live, not assumed away**: collapsing the
side pane silently broke every click coordinate on the canvas, because
`resize()` (which syncs the canvas's pixel buffer and inline CSS size
to its on-screen box) only ever ran on a `window` resize event -- the
pane's own CSS-transitioned width change never fires one, so the
canvas kept its pre-collapse size/position while the pane visually
shrank around it. First noticed as a badly squished rectangle mid-test;
root-caused by checking `getBoundingClientRect()` against
`window.innerWidth` rather than assumed. Fixed with a `resize()` call
timed to land just after the pane's own 150ms CSS transition finishes.

**Verified locally** (`mix phx.server`, this session's now-established
technique of driving interaction via direct `PointerEvent`/
`KeyboardEvent` dispatch rather than the browser-automation tool's own
click simulation, which has been unreliable all session): collapse/
expand, all three basic shapes drawn and geometrically correct, the
sticky ghost preview tracking the cursor with the right color and
ratio, select+drag on a basic shape (not just a sticky, proving the
canvas hit-test path independently of the DOM path), and copy(Ctrl+C)/
paste(Ctrl+V) producing a real offset duplicate round-tripped through
the server. One more real methodology finding along the way: a
JS-called `.blur()` on a JS-focused `<textarea>` doesn't reliably
dispatch a real `blur` event in this specific automation environment
(confirmed by manually dispatching a `FocusEvent("blur")` on the same
element immediately after, which committed correctly every time) --
narrowed down to be specific to programmatic focus/blur round-trips
with no genuine trusted input anywhere in the chain, not something a
real user's actual click or Enter key press would ever hit, since both
trigger a real, trusted focus transition that every browser fires
`blur`/`focus` for natively. Full local `docker build` before pushing,
same discipline the last two fixes established.

---

### Board picker goes live: board-lifecycle mesh notifications — DONE 2026-08-25

Prompted by a real live-fleet report: a board created on beam01 didn't
show up on beam02 or msi00. Investigation (fresh RPC call to
`QueryBoards.ListBoardsOverMesh.call()` from beam02, then a real browser
reload on both beam02 and msi00) confirmed the mesh-level discovery
mechanism was correct — the board WAS found, on both peers, the moment
they actually queried. The real gap: `HecateWhiteboardWeb.BoardsLive`
only ever calls `ListBoardsOverMesh.call()` once, in `mount/3`. An
already-open `/boards` tab has no way to learn about a board that came
into existence after it loaded. Diagnosis, not a fix, led directly to
this feature.

**Design decision, revisited mid-build.** The first draft mirrored
`ShapeMutatedV1ToMesh`'s shared-topic plumbing verbatim: one topic,
`interested_in` listing all four event types, dispatch on an embedded
`event_type` field. Challenged directly ("why a shared topic??") before
the receiving side was built. On reflection the two cases aren't alike:
`sticky_placed_v1`/`text_placed_v1`/`shape_moved_v1`/`shape_removed_v1`/
`geometry_drawn_v1` are genuine variations of one concern ("what's drawn
on this board changed") with exactly one consumer that needs all of them
uniformly (the shape read-model projection). `board_initiated_v1`/
`board_hosted_v1`/`board_archived_v1`/`board_renamed_v1` are not
variations of one action — "created", "became permanently read-only",
and "renamed" are distinct kinds of news, and a future consumer (an
archive audit log, say) might reasonably want only one of them without
filtering the rest. Switched to one topic per event type, which turned
out to already have a precedent in this exact workspace:
`draw_stroke`/`stroke_drawn_v1` never shared a topic with anything, and
`macula-realm/system/apps/tube/lib/tube/subscriber_starter.ex`
(`Tube.SubscriberStarter`) is the literal prior art for "several fixed
topics, one shared callback module, one `DynamicSupervisor`" — copied
that shape rather than inventing a new one.

**What shipped:**

- `GuideBoardLifecycle.BoardLifecycleV1ToMesh` (new, CMD side): one
  `:evoq_event_handler`, `interested_in` lists all four event types, a
  `@topics` map picks the topic per event type
  (`io.macula/whiteboard-commons/whiteboard/board_{initiated,hosted,archived,renamed}_v1`).
  Fact shape: `%{board_id, title, owner, host}` — `title`/`owner` are
  `nil` on whichever event type doesn't carry them (only
  `board_initiated_v1` carries `owner`; only `board_initiated_v1`/
  `board_renamed_v1` carry `title`), which the receiving side treats as
  "no update", never "clear this field". Wired into
  `GuideBoardLifecycle.Supervisor` as one more `handler(...)` entry,
  same as every other event-to-mesh emitter here.
- `ProjectBoards.BoardLifecycleMeshSubscriber` + `..._Starter` (new, PRJ
  side): the starter loops over four topics starting one
  `:macula_subscriber` child per topic under the existing
  `ProjectBoards.MeshSubscriberSupervisor`, all sharing the one
  subscriber module — mirrors `Tube.SubscriberStarter` exactly, not
  `BoardMeshSubscriberStarter`'s single-topic shape. The subscriber
  itself does NOT touch the `boards` ETS table or `ProjectBoards.Store`
  — this is the picker's "on other nodes" section talking about OTHER
  hosts' boards, a transient concern of one LiveView, not a local read
  model. It just normalizes the payload (same atom-vs-`{text, _}`
  tolerance as every other mesh subscriber here, tested for both shapes)
  and rebroadcasts locally as `Phoenix.PubSub.broadcast(HecateWhiteboardWeb.PubSub,
  "boards:remote", {:remote_board_event, event_type, fact})`.
- `HecateWhiteboardWeb.BoardsLive`: subscribes to `"boards:remote"` on
  connected mount, in addition to (not instead of) the existing
  `start_async(:discover_remote_boards, ...)` pull — the pull seeds the
  baseline (every board it finds is by construction hosted somewhere, so
  seeded with the `hosted` bit set via `GuideBoardLifecycle.BoardStatus`/
  `:evoq_bit_flags`), the push keeps it current. New
  `handle_info({:remote_board_event, event_type, fact}, socket)`
  accumulates status bits per `board_id` into a `remote_board_facts` map
  assign (mirroring `ProjectBoards.BoardLifecycleToBoards`'s own
  accumulation logic and bit values: `initiated=1`, `hosted=4`), OR-ing
  in whichever bit the event_type corresponds to and only overwriting
  `title`/`owner` when the incoming fact actually carries one. A board
  already in `@boards` (hosted by THIS node) is skipped outright — its
  own lifecycle already flows through `ListHostedBoards`, and a node's
  own mesh publish loops back through its own subscription, so without
  this guard a locally-hosted board would double-list itself. An
  `board_archived_v1` fact deletes the `board_id` from the accumulator
  entirely, mirroring `ListHostedBoards`' own "hosted AND NOT archived"
  filter — no un-archive path exists to reconcile against later.
  `remote_boards/1` is the template-facing sorted view; a `nil` title
  (possible if a `hosted`/`renamed` fact arrives before the `initiated`
  fact that actually carries the title — four separate topics means no
  cross-topic ordering guarantee, unlike a single shared mailbox) falls
  back to rendering the `board_id` rather than blank.
- Template: a remote board with the `hosted` bit set renders exactly as
  before (clickable, "view only"). A remote board seen only as
  `initiated` (not yet `hosted`) renders as a new `.board-card-pending`
  block — same visual weight, dashed border instead of solid, not a
  link, with an "initiated" badge chip — since there's genuinely nothing
  to open yet. This directly matches the follow-up ask ("only make it
  available for open when the owner opens it... decorate with an
  'initiated'/'hosted' badge").

**Verified:** `mix compile`, `mix test` (all pre-existing suites still
green, 3 new tests for `BoardLifecycleMeshSubscriber` covering
atom-keyed payloads, `{:text, _}`-tagged payloads, and topic filtering —
same regression shape as `BoardMeshSubscriberTest`), `mix format
--check-formatted`, full local `docker build`. Pushed, CI green
(build-and-push + lint-and-test), watchtower rolled beam01 (19:29:39
UTC) and beam02 (19:30:10 UTC), `podman-auto-update` rolled msi00 in the
same window. **Live-fleet verified with real browser tabs, no reload
anywhere:** with msi00's `/boards` already open, created "Live Mesh Push
Test" on beam01 — it appeared on msi00's untouched tab within a couple
seconds, correctly rendered as a clickable "view only" hosted card, not
stuck on the "initiated" badge, confirming `board_initiated_v1` and
`board_hosted_v1` both arrived on their separate topics and merged
correctly. A fresh load of beam02's `/boards` also showed it via the
pull baseline. This closes the "board not showing up on beam02/msi00"
report that prompted this whole feature.

### Board picker badges: fix stale "view only", add "hosted here" — DONE 2026-08-25

Follow-up report, same session: opened a locally-hosted board on beam01
fine, but noticed remote boards on other nodes' pickers still said
"view only". That text predates write-relay (a joined board has been
genuinely drawable, relayed to the host, since the write-relay feature
shipped earlier this session) — it was never updated, so it was now
actively wrong, not just imprecise. `board_live.ex`'s own `status_hint`
already had the correct wording ("Draws relay to the host over the
mesh") for the board VIEW; only the picker's card text was stale.

Replaced "view only" with a `relay` badge chip (reusing the
`.board-card-badge` styling from the initiated/hosted split above), and
added a matching amber `hosted here` badge on locally-hosted boards for
symmetry — both carry a `title` tooltip spelling out what they mean.
`.board-card-badge-hosted` (amber text/border via `--amber`/
`--amber-soft`) distinguishes it from the neutral-grey badges used for
`relay`/`initiated`.

**Verified:** `mix compile`, `mix test`, `mix format --check-formatted`,
full local `docker build`, pushed (`1981d15`), CI green, all three nodes
rolled (beam01 19:42:44 UTC, beam02 19:43:10 UTC, msi00 19:45:07 UTC via
its next `podman-auto-update.timer` cycle). Live-verified in a real
browser: msi00's picker shows `RELAY` badges on beam01's three remote
boards; beam01's own picker shows `HOSTED HERE` badges (amber) on the
same three boards from its own side.

### Board picker: "N here" presence badge — DONE 2026-08-25

Follow-up, same session: user asked for a prominent badge showing
whether a board is currently open somewhere, then half-answered their
own question noting remote peers can already edit via relay anyway --
so what actually matters isn't "did the host specifically open it" but
"is anyone here right now" (a live-collab signal), regardless of which
node they connected through. Confirmed `TrackPresence.Roster` already
receives EVERY peer's `cursor_settled_v1` mesh-wide (not board- or
host-scoped), so `Roster.list_for_board/1` answers this correctly from
any node for any board, local or remote, with zero new mesh plumbing --
just a lookup.

Picked a genuinely distinct color rather than reusing green: `--sage`
already means "drawable via relay" (`dot-relay`) and `--amber` already
means "this is the one true server" (`dot-live`) in this design
system's own stated vocabulary. A third "green = someone's here" badge
would collide with `dot-relay`'s existing meaning if it reused sage, so
added `--moss` (a more saturated, distinctly different green) instead.
Filled/bordered chip (not just outlined) per the "prominent" ask,
showing an actual count ("2 here") rather than a bare dot, and worded
"here" specifically to avoid colliding with "live"'s already-claimed
meaning (hosted, not present) in this codebase.

Implementation: `BoardsLive` polls every 5s (`@presence_poll_ms`) rather
than subscribing per-board_id -- presence already has its own ~20s
staleness window, so sub-second freshness isn't the bar, and the
board_id list itself keeps changing as remote boards are discovered, so
a fixed set of topic subscriptions doesn't fit cleanly. Badge shows on
both locally-hosted and remote-relay cards (not on a pending/initiated
card -- nothing to be present on there).

**Verified:** `mix compile`, `mix test`, `mix format --check-formatted`,
full local `docker build`, pushed (`eaf15b6`), CI green, all three nodes
rolled (beam01 20:01:43 UTC, beam02 20:01:10 UTC, msi00 22:05:25 CEST via
its timer). Live-verified in a real browser, no reload: opened
"LinkedIn Demo" on beam01 in one tab (moved the cursor to trigger a real
settle), and the already-open `/boards` tab picked up a moss-green
"1 HERE" badge on its next poll tick with no reload. Closed that tab;
the badge disappeared on the picker's own next poll tick, confirming
`terminate/2`'s `Roster.remove` fires promptly on disconnect.

---

## Nothing is committed anywhere

Stale as of the very first build session; this repo has been a normal
git repo, pushed to `github.com/hecate-services/hecate-whiteboard`,
since 2026-08-25. Left here only so the history of this doc stays
honest about what it originally said.
