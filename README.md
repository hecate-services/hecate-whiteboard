# hecate-whiteboard

Real-time, multi-user whiteboard over mesh. Comparable to Miro, except
there is no central "whiteboard.com" server: a host runs this on their
own node (laptop, home box, lab machine), and collaborators dial into
that specific host over [macula](https://github.com/macula-io/macula) and
draw with them in real time. If the host goes offline, the board goes
with it -- the deliberate trade for not needing anyone's server. See
[`plans/PLAN_HECATE_WHITEBOARD_ROOT.md`](plans/PLAN_HECATE_WHITEBOARD_ROOT.md)
for the full design.

## Status

Walking skeleton. `guide_board_lifecycle` can `initiate_board` and
`archive_board` -- boot, mesh join, health, and the CQRS wiring are
proven end to end, nothing else yet. Drawing, presence, and the LiveView
canvas are later phases; see the plan doc's suggested build order.

## Architecture

Elixir/Phoenix umbrella under `system/`, mirroring `macula-realm`'s own
`guide_{x}_lifecycle` / `project_{x}` / `query_{x}` app split:

| App | Department | Owns |
|---|---|---|
| `hecate_whiteboard` | -- | `hecate_om_service` implementation: mesh join, identity, health |
| `guide_board_lifecycle` | CMD | The `board` aggregate: `initiate_board`, `archive_board` (more desks to come) |

`hecate_om`, `evoq`, and `macula` are ordinary hex dependencies, called
directly (`:hecate_om.boot/1`, `:evoq_router.dispatch/1`) -- no wrapper
modules, per this workspace's house style.

## Running locally

```bash
cd system
mix deps.get
mix compile
HECATE_DATA_DIR=/tmp/hecate-whiteboard-dev mix run ../scripts/smoke_test.exs
```

The smoke test dispatches `initiate_board` then `archive_board` against a
real local `reckon-db` store and asserts the business-rule guard (a
second archive is rejected). No mesh secrets required for this -- boots
with dev-safe defaults (see `config/runtime.exs`).

```bash
mix test              # pure unit tests, no live dispatch
mix format --check-formatted
```

## Deployment

Container image: `ghcr.io/hecate-services/hecate-whiteboard`. Built and
pushed by `.github/workflows/build-push.yml` on every push to `main`.
Deployed to the beam fleet (`beam01.lab`, `beam02.lab`) via
`macula-io/macula-demo`'s pull-based reconciler -- see that repo's
`infrastructure/DEPLOY_BEAM.md` and this repo's own plan doc for why
those two nodes.
