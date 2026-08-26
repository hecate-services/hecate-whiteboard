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

- Board picker goes live: `GuideBoardLifecycle.BoardLifecycleV1ToMesh` publishes
  `board_initiated_v1`/`board_hosted_v1`/`board_archived_v1`/`board_renamed_v1`
  to the mesh, each on its own topic (matching `StrokeDrawnV1ToMesh`'s own
  precedent, not `ShapeMutatedV1ToMesh`'s shared one — these four are
  distinct kinds of news, not variations of one action, so a future
  consumer that only cares about one shouldn't have to filter the other
  three). `ProjectBoards.BoardLifecycleMeshSubscriber` (four
  `:macula_subscriber` children under one callback module, mirroring
  macula-realm's `Tube.SubscriberStarter`) re-broadcasts them locally;
  `HecateWhiteboardWeb.BoardsLive` accumulates per-board_id status bits
  on top of its existing one-shot `ListBoardsOverMesh` pull (kept as the
  cold-start baseline — mesh pubsub never replays for a subscriber that
  joined late). A remote board seen only as `initiated` (not yet
  `hosted`) renders as a non-clickable "initiated" badge instead of a
  view-only link, since there's nothing to view yet; an `archived`
  remote board drops out of the list entirely, mirroring
  `ListHostedBoards`' own "hosted AND NOT archived" filter. Users no
  longer need to reload `/boards` to see a board a peer just created.

- Board picker badges: a locally-hosted board now shows an amber "hosted
  here" badge (matching the `dot-live` amber used everywhere else for
  "this node is the host"). Replaced the remote-board list's "view
  only" text with a "relay" badge — "view only" had gone stale the
  moment write-relay shipped (a remote board is genuinely drawable,
  just relayed to the host over the mesh), so it was actively
  misleading rather than just imprecise. Each badge carries a `title`
  tooltip spelling out what it actually means.

- Board picker: a prominent "N here" badge (a new moss-green, deliberately
  distinct from `dot-relay`'s sage — presence and drawability are
  different questions) shows on any card, local or remote, that
  currently has at least one peer present. Reuses the existing
  mesh-wide presence roster (`TrackPresence.Roster` already absorbs
  every peer's `cursor_settled_v1` fact regardless of which node hosts
  their board) — no new mesh plumbing needed. Originally shipped as a
  5s poll, then replaced same-day with real push: `Roster` now puts
  `board_id` in the broadcast payload itself
  (`{:cursor_settled, board_id, cursor}` / `{:cursor_left, board_id,
  peer_id}`), not just the PubSub topic, so `BoardsLive` can subscribe
  to every listed board's own `"board:<id>"` topic from one process and
  tell them apart. Subscriptions are diffed against the current
  local+remote board_id set on every state change (mount, remote
  discovery, incoming board-lifecycle event) — subscribe to newly-seen
  boards, unsubscribe from ones that drop out (archived).

- Pan, zoom, and scroll on the board canvas. Every stored/transmitted
  point (strokes, shapes, presence cursors) is now WORLD-space,
  independent of any one viewer's window size or zoom level, via a
  purely client-side camera (pan offset + zoom factor, never persisted
  or transmitted). Old boards need no migration -- before this, a point
  was literally "pixels from the canvas's top-left at draw time",
  indistinguishable from world coordinates recorded under an identity
  camera. Plain scroll pans; ctrl/cmd+scroll zooms toward the cursor
  (matches every other infinite-canvas tool, and what a trackpad pinch
  dispatches on macOS even with no physical Ctrl key). A small
  "100%" indicator (bottom-right) shows current zoom and resets pan+zoom
  to identity on click. Canvas-drawn content (strokes/shapes/selection
  outline) gets the camera applied via `ctx.translate`/`ctx.scale`; DOM
  shapes (stickies/text/ghost preview) get it via a single CSS
  `transform` on their shared parent layer, needing no changes to any
  individual element's own positioning code. Presence cursors
  deliberately do NOT scale with zoom (stay a constant screen size, like
  a map pin) -- computed screen position on every camera change instead.
  Hit-test/selection thresholds and the minimum-drag-size gesture
  threshold are divided by zoom, so they read as a constant SCREEN-pixel
  tolerance rather than becoming impossibly precise when zoomed out or
  overly forgiving when zoomed in.

- Escape cancels whatever's actively being drawn or dragged (an
  in-progress pen stroke, a basic-shape drag, a select-tool move --
  canvas-drawn or a DOM sticky/text) without committing anything to the
  server. The active tool itself is untouched, matching Figma/Excalidraw
  convention. A text/sticky placement's own textarea already had its own
  Escape handler (clears and blurs); this doesn't touch that case.

- Drag-select (marquee): dragging over empty canvas with the Select tool
  active rubber-bands every shape it touches, canvas-drawn and DOM
  (sticky/text) mixed freely, by intersection rather than requiring the
  shape to be fully inside the box. Dragging any one shape in the
  resulting selection moves the whole group together (one `move_shape`
  dispatch per shape -- there's no batch command, and doesn't need to
  be one); Backspace/Delete removes the whole group; Ctrl/Cmd+C/X/V
  copy/cut/paste the whole group as one clipboard entry. Selection
  became a genuine set (`shape_id -> "canvas"|"dom"`) instead of a
  single `selectedShapeId`/`selectedKind` pair, and the two previously
  separate move implementations (canvas shapes via `this.moving` +
  `onCanvasMove`/`onCanvasUp`, DOM shapes via `onShapeDown`'s own
  closure) unified into one `beginMove` that handles any mix of both --
  needed for a marquee that can span both kinds in one drag. Verified
  locally against a real running server with a direct hook-state
  inspection harness (temporary, removed before shipping): marquee
  intersection (including partial-overlap, not just full-containment),
  group move with correct per-shape translated points, group move
  Escape-cancel (zero server dispatches, positions genuinely revert),
  group delete, group copy/paste, and marquee's own Escape-cancel all
  confirmed correct by reading `HANDLE EVENT` counts and payloads
  straight from the server log, not just visually.

- `shape_initiated_v1`/`shape_amended_v1`: collapsed the four separate
  shape-creation event types (`stroke_drawn_v1`, `sticky_placed_v1`,
  `text_placed_v1`, `geometry_drawn_v1`) into one `shape_initiated_v1`,
  and renamed `shape_moved_v1` to `shape_amended_v1` -- same
  `{subject}_{verb_past}_v{N}` shape as `board_initiated_v1`/
  `board_hosted_v1`, applied to shapes instead of boards. Directly
  motivated by the msi00 snapshot bug above: four near-identical event
  types each needing their own per-kind field mapping is exactly the
  shape that let a mapping silently drift out of sync for one kind while
  the others stayed correct. With one event type there is only one place
  to get the mapping right. Each creation desk's `Maybe*` handler now
  builds a `ShapeInitiatedV1` carrying `kind` as data instead of a
  distinct event struct/module; `MaybeMoveShape` builds `ShapeAmendedV1`.
  `GuideBoardLifecycle.ShapeLifecycle.ShapeLifecycleV1ToMesh` replaces
  the two old mesh emitters (`StrokeDrawnV1ToMesh`'s own topic,
  `ShapeMutatedV1ToMesh`'s shared one) with three topics, one per event
  type -- same one-topic-per-fact precedent as `BoardLifecycleV1ToMesh`,
  not `ShapeMutatedV1ToMesh`'s old shared-topic design (there the five
  event types were genuine siblings of "what's drawn changed"; shape
  creation and shape amendment are not siblings of each other).
  `ProjectBoards.ShapeLifecycleToBoardShapes` (local projection) and
  `ProjectBoards.ShapeLifecycleMeshSubscriber` (remote replication)
  replace `StrokeDrawnV1ToBoardShapes`/`ShapeMutatedToBoardShapes`/
  `BoardMeshSubscriber`/`ShapeMeshSubscriber` -- four writers collapsed
  to two, each now doing one generic field extraction instead of a
  per-kind dispatch. `Store`'s version-tracking table is renamed
  `board_shape_versions` (`shape_version`/`note_shape_version`, was
  `board_stroke_versions`) to match. The `stroke_id` field is gone
  entirely, not just deprioritized -- confirmed by grep that nothing
  downstream (JS client, any Elixir module) ever read it as distinct
  from `shape_id`.
  Clean cutover, no dual-read/migration: this is throwaway dev/demo
  infra and nothing is in production, per this workspace's own
  no-backward-compatibility rule. One real consequence -- boards
  currently live on the demo fleet with shapes created under the old
  event types (`stroke_drawn_v1` etc.) will lose those shapes from the
  read model on the next restart/catchup after this deploys, since the
  new projection's `interested_in/0` no longer lists the old event type
  strings. The event LOG itself is untouched (evoq's append-only store
  keeps the old events forever); only the read-model projection stops
  consuming them.

### Fixed

- Escape still did nothing for one more case beyond the earlier fix: the
  sticky tool's own live placement preview (a colored ghost box that
  follows the pointer while the tool is armed, before anything is
  placed) -- reported live ("ESC still doesnt work (sticky note drag
  view remains visible)"). None of `cancelGesture`'s four gesture checks
  (`drawing`/`drawingGeometry`/`moving`/`marquee`) cover it, since it's a
  continuous hover state rather than a one-shot gesture, so with the
  sticky tool armed and nothing actively being dragged, Escape was a
  silent no-op here too -- the same shape of gap as the original fix,
  just a different piece of state. `cancelGesture` now hides the ghost
  as another fallback. The tool stays armed (matches this fix's own
  established "Escape cancels the current thing, not the tool"
  convention): the ghost naturally reappears on the next pointer move,
  same as before Escape was pressed.

- Every pre-existing board (including "Demo Video Board", reported live
  as "empty") came up with no shapes after the `shape_initiated_v1`/
  `shape_amended_v1` consolidation deployed above -- exactly its own
  flagged consequence: those shapes were drawn under the old event
  types, and the new projection's `interested_in/0` doesn't list them.
  Offered a one-off backfill; the user chose a full fleet-wide wipe
  instead, since this is throwaway dev/demo infra with nothing worth
  preserving. `scripts/wipe_fleet_board_data.sh` stops each node,
  deletes only `board_store/` (never `identity/` -- no mesh
  re-enrollment needed afterward), restarts. Run against beam01, beam02,
  and msi00; verified clean.

- The Sticky note tool showed the plain-text I-beam cursor
  (`CURSOR_BY_TOOL.sticky`), same as the Text tool -- reported live
  ("when i click a sticky note tool...i get a text cursor"). The two
  shared "text" on the reasoning that both ultimately open a typeable
  textarea on click, but sticky already has its own dedicated visual (a
  colored ghost box following the pointer, see `updateGhost`/CSS
  `.shape-ghost`) that the Text tool doesn't have -- the I-beam on top
  of that ghost was two conflicting placement cues at once. Sticky now
  uses `crosshair`, matching every other click/drag-to-place tool
  (rectangle/ellipse/triangle/pen); Text keeps the I-beam as its only
  cue, unchanged.

- The `/boards` picker's "N here" presence badge undercounted: a viewer
  who opened a board but hadn't moved their mouse over the canvas yet
  was invisible to it, since `TrackPresence.Roster` only ever gained a
  row for a peer once their JS hook's `cursor:settle` event fired (~400ms
  after a real pointer movement) -- `BoardLive.mount/3` itself never
  registered presence, only read it. Found live ("the number of
  participants in /boards is not correct"). Fixed by having
  `render_board/4` call `Roster.touch/1` immediately on connect, with
  `x`/`y` left `nil` (no real cursor position exists yet). Two call sites
  needed a matching nil-x guard so this doesn't flash a phantom cursor
  marker at a NaN screen position for other viewers: the join-time
  snapshot pushed to a newly-connecting peer, and the `cursor_settled`
  broadcast handler that forwards updates to already-connected peers.
  `Roster.touch/1` itself needed no change -- a join fact with no
  position is just another fact to write/broadcast, same as a real
  settle; the real settle event later overwrites the same row with an
  actual position, no double-count. Verified live: opened a board in one
  tab without touching its canvas at all, confirmed the picker in
  another tab showed "1 here" immediately (previously would have shown
  no badge); moved the cursor and confirmed the count stayed at 1, not
  2; closed the tab and confirmed the badge disappeared.

- Escape genuinely did nothing for the most common case: a shape
  selected (single click, no drag at all) with nothing actively being
  dragged or drawn. `cancelGesture` only ever checked
  `drawing`/`drawingGeometry`/`moving`/`marquee` -- all four require an
  in-progress gesture, so a static selection sitting idle made every
  one a no-op. Caught by a live report ("ESC still doesn't work") after
  my own earlier verification only ever exercised the mid-drag-cancel
  path, never plain select-then-Escape; reproduced first with a real
  click + a real Escape keypress (not synthetic `dispatchEvent`, which
  is all my earlier testing used) before fixing it. `cancelGesture` now
  falls back to clearing the selection when nothing else is active.

- **A real data-loss/corruption bug in `join_board`'s mesh snapshot**,
  found live: msi00's view of a board hosted on beam01 was missing a
  rectangle entirely and showed one sticky with its text, kind, and
  shape_id all silently dropped. Root cause:
  `GetBoardSnapshotByIdOverMesh`'s `normalize_stroke/1` (now
  `normalize_shape/1`) only ever extracted `stroke_id`/`points`/`color`/
  `width` — correct back when a snapshot's `shapes` list held nothing
  but strokes, silently wrong once sticky/text/geometry shapes existed.
  Worse, the redelivery-dedup filter was keyed on that same
  now-always-nil `stroke_id` for non-stroke shapes, so `new_shape?(nil)`
  (formerly `new_stroke?`) only ever let ONE non-stroke shape per
  snapshot through — every other one got silently filtered out as an
  apparent redelivery. Fixed by normalizing every shape kind generically
  and deduping on `shape_id` (which every kind has, a stroke's own
  `shape_id` already equals its `stroke_id`) instead. `Store`'s
  dedup-guard table is renamed `board_shapes_seen`
  (`new_shape?`/`board_shapes_seen_table`, was `board_strokes_seen`) to
  match its now-actual scope, and the same guard was added to
  `ShapeMutatedToBoardShapes`'s and `ShapeMeshSubscriber`'s own
  shape-placement paths, which had the identical unguarded-insert gap
  for the live (non-snapshot) replication path. Regression-tested
  directly against `normalize_shape/1` and the dedup filter, no live
  mesh needed.

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
