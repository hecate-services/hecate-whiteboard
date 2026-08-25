# Changelog

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versioning: [SemVer](https://semver.org/).

## [Unreleased]

### Added

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
  not-yet-built follow-on. See the plan doc's "`join_board` — DONE
  2026-08-25" section for the full design and what's still unverified.

### Fixed

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
