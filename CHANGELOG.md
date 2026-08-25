# Changelog

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versioning: [SemVer](https://semver.org/).

## [Unreleased]

### Added

- Toolbox side pane: pen (existing), text, and selection tools, plus
  sticky notes in the classic Event Storming palette (orange Domain
  Event, blue Command, yellow Actor, purple Policy, green Read Model,
  pink Hotspot). New shapes (`sticky_placed_v1`, `text_placed_v1`) and
  new shape-agnostic mutations (`shape_moved_v1`, `shape_removed_v1`)
  work uniformly across strokes, stickies, and text via a shared
  `points`/`shape_id` shape on every `board_shapes` row. Sticky/text
  render as DOM elements (native click/drag/text layout); strokes stay
  canvas-drawn with a distance-to-segment hit test for selection.
  Archived all accumulated test boards first, per request.
- Toolbox v2: basic shapes (rectangle/ellipse/triangle, outlined in the
  Pen tool's own ink palette, click-drag-to-size), a collapsible side
  pane (icon-only strip, not fully hidden), a live cursor-following
  ghost preview before a sticky is placed, and Copy/Cut/Paste
  (Ctrl/Cmd+C/X/V) for any selected shape. Copy/paste needed no backend
  changes -- paste re-dispatches the same command a fresh placement
  would use, offset so it never lands on top of the original. Basic
  shapes reuse the existing shape-mutation relay/mesh plumbing
  (`draw_geometry` CMD desk, `geometry_drawn_v1`) and get select/move/
  remove for free through the same kind-agnostic points+shape_id
  machinery stickies and text already use. Sticky notes are now
  A*-ratio (170x120, ISO 216).

- Walking skeleton: `hecate_whiteboard` (hecate_om_service, first Elixir
  implementation of that behaviour in this workspace) + `guide_board_lifecycle`
  CMD app (`initiate_board`, `archive_board`). Boots, joins the mesh,
  serves `/health`, dispatches both commands against a real reckon-db
  store with the business-rule guard enforced.
- Container image + CI (`build-push.yml`, `lint.yml`), deployed to
  `beam00.lab`/`beam01.lab` via macula-demo's pull-based reconciler.
- `host_board` + `draw_stroke` desks, `project_boards` (PRJ) +
  `query_boards` (QRY), and a real Phoenix/LiveView canvas
  (`hecate_whiteboard_web`) — plain HTML5 Canvas + a hand-rolled
  quadratic-curve smoother, not Konva. Redeployed to `beam01.lab` +
  `beam02.lab`.
- Basic mesh replication: `StrokeDrawnV1ToMesh` (CMD) publishes every
  locally-drawn stroke to real macula pubsub; `BoardMeshSubscriber`
  (PRJ) applies incoming remote strokes straight into the read model.
  Verified live and bidirectional between beam01 and beam02.
- `join_board`: mesh-level board discovery + snapshot fetch.
  `QueryBoards.GetBoardSnapshotByIdOverMesh` (client) and
  `QueryBoards.AnswerBoardSnapshotQueries` (host) exchange a snapshot
  over a per-query reply topic, through macula's supervised
  publisher/subscriber pairs. New route `/board/:board_id`. View-only:
  a joined (not locally hosted) board reads as not-`hosted?`, so the
  existing `can_draw?` gating makes it correctly read-only with no
  template change. Writing into a remotely-hosted board is a separate,
  not-yet-built follow-on. Live-verified against beam01/beam02: a board
  minted and hosted on beam01 only was found and rendered correctly
  (read-only) from beam02 cold, via a real mesh query/reply round trip.
  See the plan doc's "`join_board` — DONE 2026-08-25" section for the
  full design.
- Board picker: `/boards` lists every board this node hosts
  (`QueryBoards.ListHostedBoards`, deliberately excluding boards this
  node has only joined/cached, to avoid surfacing a stale one-off
  snapshot) plus a "new board" form that mints and hosts a fresh board
  through the already-existing `initiate_board`/`host_board` desks. The
  main board view's brand/logo now links to `/boards`.
- Board picker is now mesh-aware: an "On other nodes" section fetched
  asynchronously (`QueryBoards.ListBoardsOverMesh`, `AnswerBoardListQueries`)
  so it never blocks the page. Live-verified: beam01's picker correctly
  shows beam02's boards and vice versa.
- `rename_board`: a board's title, previously set once at creation and
  never editable, can now be changed by clicking it in the topbar (only
  when this node is the board's host). New CMD desk
  (`rename_board_v1` -> `board_renamed_v1`), mirrors `archive_board`'s
  shape.
- Write-relay: a joined (not locally hosted) board is now drawable, not
  just viewable. A stroke drawn there is published as a request instead
  of dispatched locally; `AnswerDrawStrokeRequests` (every node)
  dispatches it through the SAME local path a host's own draw already
  uses, and `BoardAggregate`'s existing `:not_hosted` rule makes every
  node except the real host a safe no-op -- no new authority-check
  logic needed. The confirmed stroke comes back through the existing
  replication path, so no reply/ack is needed either. Status dot gets a
  third state (sage, `dot-relay`) distinct from hosted (amber) and
  archived (grey). Live-verified in a real browser: drew on a board
  hosted only on beam01, from beam02, and watched it appear on both.
- Deployed a third peer, `msi00.lab` — the first node off the beam
  fleet, podman Quadlet + `podman auto-update` instead of docker +
  watchtower (see `macula-io/macula-demo`'s
  `infrastructure/msi00.lab/hecate-whiteboard.container`). Live-verified
  as genuinely N-way, not pairwise: `/boards` on msi00 discovered both
  beam01's and beam02's boards in one query window, and a stroke_id
  drawn on msi00 was confirmed present on both. Then repointed msi00 at
  `station-it-milan` (beam01/beam02 both use station-de-frankfurt) and
  re-ran everything, so the proof is of a genuine cross-station hop, not
  three peers fanning out from one shared relay.
- Repointed beam01 (`station-de-falkenstein`) and beam02
  (`station-fi-helsinki`) so all three peers now sit on three distinct
  stations, not two-sharing-frankfurt-plus-milan. Re-verified
  replication and write-relay by stroke_id in both directions with no
  two peers sharing a relay. The topbar now shows which station each
  peer is on (`"beam01 via de-falkenstein"`), read live from
  `MACULA_STATION_SEEDS`.
- Presence and live cursors: mesh-wide, debounced-on-stop (~400ms of
  stillness before a settled position is sent, not a continuous
  stream), rendered as a hard jump plus a brief fading ghost at the old
  position. New `track_presence` app (ETS roster + sweep, no event
  store -- ephemeral by design) and a new `leave_board` CMD desk
  (`guide_board_lifecycle`) for the one presence fact that IS
  event-sourced: a graceful exit. Anonymous per-mount identity, colored
  and labeled with the same "{host} via {station}" string the topbar
  shows. Live-verified locally with real browser automation (two tabs,
  settle/jump/ghost/departure all confirmed), then confirmed the
  previous entry's header-label change was already live on all three
  deployed nodes via watchtower/podman-auto-update.

### Fixed

- Collapsing the toolbox side pane silently broke every subsequent
  canvas click coordinate: the canvas's pixel buffer and inline CSS
  size only ever resynced on a `window` resize event, and the pane's
  own CSS-transitioned width change never fires one, so the canvas kept
  its pre-collapse size/position while the pane visually shrank around
  it. Fixed by resizing right after the pane's 150ms transition settles.
- Static assets (`/assets/app.js`, `app.css`) had no cache-busting --
  no content-hash filename, no `max-age`/`immutable`/`Last-Modified` --
  so a browser could silently keep serving a stale bundle across a
  redeploy indefinitely, with no error and no visible sign anything was
  wrong. A user report right after the toolbox shipped ("text/sticky
  tools do nothing") turned out to be exactly this: their browser had
  already cached the previous bundle. Fixed by baking the git commit
  into the asset URLs (`app.js?v=<sha>`), computed at compile time via
  `HecateWhiteboardWeb.BuildInfo` (no cross-stage Dockerfile ENV
  plumbing needed) and passed in from CI as a Docker build arg.
- Every non-select tool shared the exact same cursor
  (`crosshair`), so switching tools gave no visible feedback --
  confirmed via `getComputedStyle`, part of the same user report above.
  Text/sticky now show a `text` cursor; pen keeps crosshair; select
  keeps the default arrow.
- Placing a sticky note or text label silently did nothing, every
  time, with no visible trace: `textarea.focus()` called synchronously
  inside a `pointerdown` handler didn't stick, because the pointerdown
  event's own default focus handling ran afterward and re-focused
  `<body>` (the canvas isn't focusable), firing the textarea's blur
  before any text could be typed and discarding it as empty. Fixed
  with `e.preventDefault()` on that specific branch.
- The presence/cursors push above broke the container build:
  `Dockerfile`'s staged per-app `COPY apps/<app>/mix.exs` lines were
  never updated for the new `track_presence` app, so `mix deps.compile`
  failed inside the image build and CI's build-and-push job failed
  outright -- ghcr never got a new `:latest`, so beam01/beam02/msi00
  correctly kept running the previous image rather than picking up
  anything broken. Caught by the user testing live ("when i draw on the
  beam01 test board, it doesn't show up on beam02"); the underlying
  mesh replication was actually fine on the still-running previous
  image (confirmed with real browser tabs before touching any code).
  Fixed with one added `COPY` line, verified with a full local `docker
  build`, then re-verified the user's exact scenario against the
  now-correctly-deployed image on all three nodes.
- `HecateWhiteboardWeb.ErrorView` was missing, so Phoenix's own
  naming-convention default for `render_errors` (derived from the
  Endpoint module when unconfigured) pointed at a module that didn't
  exist — any unmatched route crashed to a raw 500 instead of a clean
  404. Added, styled to match the board's chalk-on-slate palette.
- Duplicate strokes on restart: evoq's catchup replay re-delivers a
  host's full local history through the same projection/mesh-emitter
  handlers on every boot, which re-broadcast (and, for a mesh peer,
  re-published) every historical stroke. `ProjectBoards.Store.new_stroke?/1`
  gates both the local projection and `BoardMeshSubscriber` with an
  atomic stroke_id-keyed check-and-set.
- `boards` table rows crashed `ListHostedBoards` with a `KeyError`
  the moment a real board existed: the stored row doesn't carry
  `board_id` in its value, only as the ETS key, same shape
  `GetBoardSnapshotById` already accounted for.
- **A real bug in `evoq` itself**, not this repo: a handler registering
  after `evoq_store_subscription`'s one-time catch-up scan already ran
  never received any of the store's pre-existing history for its event
  type, silently wiping the read model on every restart with real
  accumulated history (the underlying event store was untouched — a
  projection gap, not data loss). Found live via a beam01/beam02
  stroke-count mismatch after a restart. Fixed at the source in
  `reckon-db-org/evoq` and shipped as evoq 1.23.1; this repo's existing
  `{:evoq, "~> 1.23"}` picked it up with no dependency change needed.
  See the plan doc's "evoq catch-up bug — FOUND AND FIXED 2026-08-25"
  section for the full diagnosis and live-fleet re-verification.
