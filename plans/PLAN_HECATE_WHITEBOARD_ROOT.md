# Plan: hecate-whiteboard — Real-Time Multi-User Whiteboard Over Mesh

**Status:** Boards on separate hosts replicate each other's strokes over
real macula pubsub, live-verified bidirectional on `beam01.lab` and
`beam02.lab` (`http://beam0N.lab:8493/`) — draw on one, it appears on
the other within seconds. `host_board` + `draw_stroke` desks,
`project_boards` (PRJ) + `query_boards` (QRY), a real Phoenix/LiveView
canvas (`hecate_whiteboard_web`), and basic mesh replication
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

**What this is NOT yet:** writing. A joining peer can watch a board
live and see its full history, but has no way to draw into it — the
canvas correctly disables itself (`can_draw?` false) rather than
silently creating a second, split-brain local aggregate for someone
else's board_id. Relaying a joining peer's stroke to the actual
hosting peer (mesh RPC into that host's `draw_stroke` desk) is real,
separate, not-yet-designed follow-on work, not an oversight.

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

---

## Nothing is committed anywhere

Stale as of the very first build session; this repo has been a normal
git repo, pushed to `github.com/hecate-services/hecate-whiteboard`,
since 2026-08-25. Left here only so the history of this doc stays
honest about what it originally said.
