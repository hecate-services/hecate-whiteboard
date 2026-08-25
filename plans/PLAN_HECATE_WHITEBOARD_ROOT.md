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
rather than hidden. See "Basic mesh replication" and "Suggested build
order" below for what was found getting here and what's next
(`join_board` proper, presence, dedup).

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

### Known simplifications carried from the walking-skeleton phase, not yet revisited

- `check_origin: false` on the Endpoint (no fronting domain yet).
- `SECRET_KEY_BASE` falls back to a fixed, publicly-committed dev value
  (see `config/runtime.exs`) — nothing of real value depends on it yet
  (no accounts, no forms), but this needs a real provisioned secret
  before this is anything more than a demo.
- The default board is a single fixed id (`@default_board_id` in
  `board_live.ex`) — no board creation/picker UX. Fine for proving
  drawing; will need real board identity once `join_board` lets a second
  peer target a SPECIFIC board rather than "whatever this host is
  showing."

---

## Nothing is committed anywhere

Not a git repo yet. `git init` is a deliberate next step, not taken as
part of writing this plan, per this workspace's rule to only take
git-initializing/committing actions when explicitly asked.
