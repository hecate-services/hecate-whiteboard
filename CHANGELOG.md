# Changelog

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versioning: [SemVer](https://semver.org/).

## [Unreleased]

### Added

- Archive/Unarchive buttons on `/boards`, wiring up a desk pair
  (`archive_board`/`unarchive_board`, the death/rebirth ends of the
  board lifecycle) that was fully built -- command, event, aggregate
  guard, projection, mesh emitter/subscriber, even a
  `board_lifecycle_mesh_subscriber` topic and a client-side
  `BoardStatus.archived()` bit already consumed by
  `AnswerBoardSnapshotQueries` and `board_live.ex`'s own read-only
  rendering -- but never exposed through any UI. `unarchive_board` is
  the new half, mirroring `archive_board` exactly (command/event/
  handler/aggregate guard `not_archived`/projection clears the bit via
  `evoq_bit_flags.unset/2`/mesh topic). A new `ListArchivedBoards` query
  (NOT a broadened filter on the existing `ListHostedBoards`) surfaces a
  node's own archived boards for the Unarchive button -- kept as a
  separate desk specifically so an archived board can never become
  mesh-discoverable again just because the LOCAL picker also wants to
  list it: `ListHostedBoards.call/0` is also what
  `AnswerBoardListQueries` answers "what do you host" queries from other
  nodes with, and broadening its filter would have silently un-hidden
  every archived board fleet-wide.
  - The remote-board picker's own accumulator needed a real fix, not
    just an addition: `merge_remote_fact/4` used to DELETE a board from
    its map entirely on `board_archived_v1` ("no un-archiving path to
    reconcile against later," true until this commit) -- now that
    `board_unarchived_v1` exists, deleting would have lost title/owner/
    host, so a later unarchive fact would have reappeared blank. Fixed
    to keep the entry and just track the bit like every other status
    transition; `remote_boards/1` now filters archived ones out of the
    rendered list instead, which correctly lets an unarchive fact bring
    the board back with its full info intact.
  - Archive/unarchive is host-only (`MaybeArchiveBoard`/
    `MaybeUnarchiveBoard` have no `relay/1`, unlike the shape-mutation
    desks), matching that the buttons only ever render in the "hosted
    here" list.
  - **A real race found live while testing this**: `handle_event`'s
    success branch used to re-query `ListHostedBoards`/`ListArchivedBoards`
    immediately after `dispatch/1` returned `{:ok, ...}` -- but that
    return only confirms the event was WRITTEN, not that
    `BoardLifecycleToBoards` (a separate async projection) has already
    applied it to the ETS read model. Reproduced consistently: the
    archive genuinely succeeded server-side every time (confirmed via a
    second click correctly hitting the aggregate's `:already_archived`
    guard), but the board never visibly moved lists. Fixed by removing
    the eager re-query entirely and relying on the projection's own
    `{:board_updated, ...}` PubSub broadcast (already fired on
    "board:<id>" after every ETS write, previously unconsumed by this
    LiveView) via a new `handle_info({:board_updated, _}, socket)` that
    re-derives both lists at the point they're actually safe to read.
    That in turn needed `sync_presence_subscriptions/1` to track
    `archived_boards`' ids too, not just `boards` -- without it, the
    FIRST archive un-subscribed from the board's own topic (no longer in
    the "current" set) and every SUBSEQUENT transition silently stopped
    arriving.
  - Verified live: archived a board, confirmed it moved to a new
    "Archived" section immediately (no reload) with the read-only
    badge; unarchived it, confirmed it moved back immediately; repeated
    the cycle twice more to confirm the subscription fix holds across
    repeated transitions, not just the first one.

- Arrow tool, with live-reference attachment: dragging from/to an
  existing shape snaps that endpoint to the shape's EDGE (the point on
  its bounding box closest to the other end, so the arrow visually
  touches rather than overlaps -- requested live, "lines and arrows
  should snap to the boxes... a freestanding line/arrow rarely is
  meaningful"), and every viewer resolves the CURRENT position of both
  endpoints on every redraw, not fixed points frozen at creation.
  Moving or resizing a shape that ten arrows point at costs nothing
  extra -- no new event, no stored relationship to update, the arrow
  itself is never re-emitted. Endpoints not snapped to anything are
  ordinary freestanding points, same as any other geometry shape's
  corners.
  - Schema: `shape_initiated_v1` grows two optional fields,
    `from_shape_id`/`to_shape_id`, alongside `points` (which still
    carries the two endpoints as of creation time -- now a FALLBACK,
    used whenever a referenced shape_id can't be resolved: removed, a
    freestanding endpoint, or a client that hasn't loaded it yet).
    Unvalidated against any existing shape server-side, same trust
    boundary `points` itself already has -- resolving the live position
    from an id is entirely a client rendering concern, the same
    "computed live, nothing stored as a relationship" trick `frame`'s
    containment already uses. `draw_geometry` carries the two ids
    through unchanged everywhere a shape's other optional fields
    (width/text) already flow: the command, the local projection, the
    mesh emitter/subscriber pair, and join_board's mesh-snapshot
    normalizer -- the same set of touch points the msi00-inconsistency
    bug (below) already established as needing to move together.
  - Rendering: a new `resolvedPoints(shape)` hook method is the ONE
    place that turns a stored `from_shape_id`/`to_shape_id` into real
    coordinates -- `clipToBox` walks a ray from the target shape's
    center toward the other endpoint and stops at the box edge. Every
    site that previously read a canvas shape's `points` directly now
    goes through it: `redrawCommitted`/`renderCanvasShape` (drawing),
    `hitTestCanvasShape` (selection -- an arrow now hit-tests via
    segment distance like a stroke, not the box-fill test rectangle/
    ellipse/triangle/frame use, since a thin diagonal line's own
    bounding box is mostly empty space), and `shapesWithinRect`
    (marquee-select and a frame's own "what's inside me" grab). A
    connected DOM shape (sticky/text) moving also needed
    `applyMove`'s DOM branch to gain a `redrawCommitted()` call it
    never previously needed, since a moved sticky isn't itself on the
    canvas but an arrow pointing at it lives there. `shapes:snapshot`
    now does one full `redrawCommitted()` after the whole batch loads,
    since an arrow can land in that list before the shape it
    references (snapshot order isn't creation order) and its first
    single-shape paint would otherwise resolve against a still-partial
    picture.
  - No cascade-delete: removing a shape an arrow points to leaves the
    arrow rendering at its stored fallback (creation-time) position,
    not the shape's last position before removal -- simple, well-
    defined, and avoids the event traffic a "keep it fresh" fallback
    would cost. Re-pointing an existing arrow's endpoint to a
    different shape after creation isn't in this cut, only
    creation-time snapping.
  - Verified live: two rectangles connected end-to-end with the
    arrowhead landing exactly on each edge; moved one rectangle and
    confirmed the arrow followed with zero extra events (checked the
    server log); reloaded and confirmed the connection survives a
    fresh snapshot load regardless of shape order; selected the arrow
    by clicking near its LIVE (not stale) line; deleted it cleanly;
    drew a freestanding arrow with both endpoints on empty canvas;
    confirmed Escape cancels an in-progress arrow drag; confirmed no
    resize handles appear on an arrow; connected an arrow to a sticky
    note (the DOM-shape/canvas-shape bounding-box unification) and
    confirmed it followed the sticky when moved.

- Resize handles for the four "two opposite corners" shape kinds
  (rectangle/ellipse/triangle/frame -- the same set as `GEOMETRY_KINDS`,
  a stroke has no single meaningful resize since its points are a whole
  freehand path, not a box). Requested live alongside the arrow tool
  ("the user should be able to resize elements"); built first since it's
  self-contained and directly benefits the just-shipped Frame tool.
  Architecturally identical to a move -- `move_shape` already replaces a
  shape's `points` wholesale, so resize dispatches that exact same
  command with `[fixedCorner, draggedPoint]`; zero backend changes
  needed, confirmed via `applyMove`'s existing kind-agnostic handler.
  Only appears for a single selected geometry shape (what would one
  handle mean for N shapes at once?); four small squares at the corners,
  sized in world units scaled by 1/zoom so they stay a constant screen
  size, same reasoning as `repositionCursors`' own cursor markers.
  Dragging one respects snap-to-grid via the same `snapPoint` every
  other placement uses, and Escape cancels an in-progress resize back to
  the shape's pre-drag bounds, matching `cancelGesture`'s existing
  `moving`/`marquee` cancellation pattern. Verified live: resized a
  rectangle and a frame, confirmed the new bounds persist after reload,
  confirmed a corner lands exactly on a grid dot with Snap on, confirmed
  Escape mid-drag reverts cleanly, and confirmed sticky/text (DOM
  shapes) show no handles when selected.

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

- Snap-to-grid toggle (bottom-right, next to the zoom indicator, off by
  default like the camera itself -- local to the tab, never persisted or
  transmitted). Grid is 28px, matching `.canvas-wrap`'s own visible
  dot-grid spacing exactly. Applies to sticky/text placement and
  geometry (rectangle/ellipse/triangle) corners -- both while dragging
  (the live preview already shows the snapped result, not just the
  final commit) and at drop. Deliberately does NOT touch the Pen tool:
  forcing every point of a freehand stroke onto a 28px grid would turn
  it into a staircase. Moving an existing shape (or a marquee-selected
  group) snaps too, but by adjusting the DRAG DELTA once against a
  single reference point rather than snapping every point independently
  -- verified live: a 168x84 rectangle kept its exact dimensions after a
  snapped move, and a marquee group stays exactly as spaced as it
  started, just aligned to the grid as a whole. First of three
  requested Event Storming features (frame/grouping-container and
  shape-attached arrows are next -- both depend on the two architecture
  calls made alongside this: live spatial-query containment, and
  live-reference arrow attachment).

- Frame tool -- second of three requested Event Storming features, and
  what a swim lane turns out to be: not its own bespoke shape kind, but
  a generic grouping container used flexibly (a full-height frame is a
  vertical lane, a full-width one horizontal, no separate lane
  implementation needed at all). Backend needed exactly one line: added
  to `draw_geometry_v1`'s existing kind allowlist -- `frame` is still
  just a kind plus two corner points to the server, which has no notion
  of "container" whatsoever; every bit of grouping logic lives
  client-side. Click-drag to size, like rectangle/ellipse/triangle (no
  post-creation resize in this first cut, matching how those three
  already work); renders dashed, in a fixed neutral color rather than
  the ink palette, with a fixed "Frame" label (not yet user-editable --
  renaming is a natural follow-on, matching the board-title
  click-to-rename affordance).

  Containment is the live spatial query settled on earlier: reuses
  `shapesWithinRect` verbatim -- the exact same check marquee-select
  already does, since "what's inside this frame" and "what did a
  marquee just rubber-band" are the same question. Computed once, at
  the start of a frame drag, not kept live for the rest of it --
  membership doesn't flicker as the frame passes over other shapes
  mid-move. Beyond that one computation, `beginMove` needed no
  frame-specific code: a frame's contents just ride along as ordinary
  selected items, which also means deleting or copying a
  frame-plus-contents selection already works, for free, through the
  existing group-selection mechanics.

  Two more fixes needed alongside the frame itself, for shapes to
  correctly coexist with a container around them:
  - `redrawCommitted` now always paints every frame FIRST regardless of
    creation order, so a frame drawn after shapes already exist inside
    it (or a shape drawn into one later) still sits visually behind
    them -- a container, not content.
  - `hitTestCanvasShape` now checks every non-frame shape before any
    frame -- a frame's own bounding box legitimately overlaps
    everything inside it, so without this, clicking a shape inside a
    frame would incorrectly hit the frame instead.

  Verified live: a sticky and a rectangle both render on top of a
  frame drawn behind them; dragging the frame from empty space inside
  it moves the frame and everything within its bounds together, with
  each shape's own position relative to the others preserved exactly
  (confirmed both shapes' dispatched points shifted by the identical
  delta); clicking directly on a shape inside a frame selects that
  shape alone, not the frame.

### Changed

- Escape now switches to the Select tool whenever the active tool isn't
  already Select, on top of cancelling whatever's active -- a single
  universal rule replacing the previous "stay armed" design (kept
  originally for rapid multi-sticky placement, matching a stated-but-
  only-partially-true "Figma/Excalidraw convention": both actually DO
  return to their move/select tool on Escape once nothing is mid-drag).
  Asked directly why not just switch tools; the rapid-placement
  reasoning didn't hold up against how stickies actually get placed in
  bulk here (select one, copy, paste N times -- not re-arming the
  sticky tool per note). `cancelGesture` simplifies as a result: the
  dedicated ghost-preview branch from the fix above is gone, since
  `setTool` already calls `hideGhost()` for any non-sticky tool, so
  switching to Select clears a still-armed sticky's ghost for free.
  `moving`/`marquee` cancel is unaffected (both only ever happen with
  Select already active, so the tool-switch is a no-op there, and
  critically DOESN'T re-clear the just-restored selection --
  `setTool` unconditionally clears selection, which would otherwise
  turn "cancel a drag" into "cancel a drag AND deselect"). Verified
  live: a mid-drag cancel still leaves the group selected (dashed
  outline, position reverted) with Select untouched; a mid-stroke Pen
  cancel and a dismissed sticky ghost both now land in Select instead
  of staying armed.

- Toolbox order: Select moved to the top, above Pen. Asked directly
  ("shouldn't the Select tool be at the top?") -- matches Figma/
  Excalidraw's own toolbar convention (the pointer tool leads), and
  lines up with Select's growing role as the tool Escape always lands
  you back in (see the entry above). Pen stays the default active tool
  on a fresh board load; only the listed order changed, not which tool
  starts armed.

### Fixed

- Default board (`/` with no board_id) collided across fleet nodes.
  `@default_board_id` was one hardcoded literal shared by every node;
  `find_or_host_default_board/0` falls back to hosting its own copy
  locally whenever the mesh lookup for that id doesn't resolve in time,
  so beam01, beam02 and msi00 each ended up with a genuinely different
  board answering to the SAME board_id -- found live ("check all nodes
  + msi...the state of boards is messed up") after visiting `/boards`
  on all three: beam01 and msi00 both showed "Untitled board", beam02
  showed "Demo Video Board", all three under
  `board-01a038649f9470078c0e2afaaaaea200`. `ListBoardsOverMesh.merge/1`
  dedups by board_id ("first answer wins"), so a merged cross-node list
  silently dropped two of the three every time. Fixed by deriving the id
  from `Node.self()` (hashed with md5 to keep the required
  `<prefix>-<32 hex>` reckon_gater_stream_id shape) instead of one fixed
  literal -- still stable across restarts (Node.self() doesn't change
  for a given deployed node), just no longer shared across nodes. The
  three boards that had already collided under the old literal id are
  now orphaned under that old id (still in the event store, just
  unreachable via `/`) rather than migrated; all three held only
  trivial placeholder content (1 stroke, default title) so nothing of
  value was lost.

- Toolbox clicks (tools, ink swatches, sticky-color swatches) could go
  silently dead in an already-open tab -- reported live ("it seems i
  cannot select the frame tool"). Root cause: `wireToolButtons`/
  `wireInkSwatches`/`wireStickySwatches` attached a `click` listener
  directly to each `[data-tool]`/`.swatch`/`.sticky-row` button, once,
  in the canvas hook's `mounted()`. Those buttons live in the side pane,
  OUTSIDE the hook's own `phx-update="ignore"` region, so they're
  ordinary LiveView-diffed DOM -- any diff that replaces rather than
  patches a button node (a toolbox reorder, a brand-new tool like Frame
  appearing for the first time, a socket reconnecting to newer server
  code than what the tab's hook was mounted against) leaves the new
  node with no listener at all, since `mounted()` already ran and never
  fires again. Reproduced against beam01 directly: the deployed Frame
  button worked perfectly for a fresh page load, which is what made
  this one hard to catch by re-testing -- the bug only bites a tab that
  was already open across the exact toolbox-changing deploy, exactly
  the kind of long-lived session this project's demo boards actually
  see. Fixed by delegating all three to a single `click` listener on
  `document` that resolves the target via `closest(...)` on each event,
  so wiring no longer depends on which button nodes existed at mount
  time. Since `BoardsLive` reaches a board via `push_navigate` (no full
  page reload, so `destroyed()`/`mounted()` can cycle repeatedly on one
  document), the three delegated listeners are also removed in
  `destroyed()` to avoid stacking a duplicate set on every board visit.

- Repeated Ctrl/Cmd+V stacked every paste on top of the SAME spot
  instead of cascading -- `pasteOne` always read the clipboard's
  original, never-updated points, so every paste offset by the same
  fixed 24px from what was COPIED, not from the LAST paste. Asked live
  ("shouldn't paste respect a little offset?") after exactly this
  stacking was visible, from the app's actual bulk-placement workflow
  (select one sticky, copy it, paste N times). Fixed by having
  `pasteClipboard` reassign `this.clipboard` to each `pasteOne`'s own
  offset points afterward, so the NEXT paste of the same clipboard
  cascades from there. `copySelection`/cutting still rebuild the
  clipboard from scratch, so copying something new correctly resets the
  cascade back to the original position -- verified live: 3 consecutive
  pastes landed at +24/+48/+72px in a staircase, then a fresh copy+paste
  of the original landed back at +24px, not +96px.

- `QueryBoards.ListBoardsOverMesh`'s remote-board discovery, called once
  at `/boards` mount, failed fast and PERMANENTLY on `mesh_unavailable`
  -- unlike every other mesh integration point in this app (the various
  `*Starter` GenServers), it never retried. A picker page that happened
  to connect during the few-second window right after a node restart
  (mesh not rejoined yet) got stuck showing "No boards found on other
  nodes" for its entire lifetime, since nothing ever asked again. Found
  live right after the fleet-wide wipe above restarted every node.
  `BoardsLive` now retries every 5s (matching the `*Starter`s' own
  interval) on a `mesh_unavailable` failure specifically, via
  `Process.send_after/3` + re-triggering the same `start_async`; other
  failure kinds still fail once, unretried, since retrying an unrelated
  error forever would risk masking a real bug. The retry keeps
  `remote_boards_loading?` true throughout, so the page reads "Checking
  the mesh…" the whole time rather than flashing an empty state that
  then silently refills. `ListBoardsOverMesh.call/1` itself is
  unchanged (still fails fast) -- every other query module in this app
  makes the same choice and leaves retry policy to the caller, so this
  keeps that convention intact rather than quietly changing what
  `call/1` means for every caller. Verified locally: local dev never
  has a mesh pool, so it's a standing reproduction of the exact race --
  confirmed the retry firing every 5s in the server log and the page
  reading "Checking the mesh…" indefinitely instead of the old
  permanent empty state.

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
