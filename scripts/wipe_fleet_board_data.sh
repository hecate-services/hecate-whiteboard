#!/bin/sh
# One-off, user-requested full reset of hecate-whiteboard's board data
# across all three demo-fleet nodes (beam01, beam02, msi00). Wipes ONLY
# board_store/ (the evoq/reckon-db event log + everything the read
# models derive from it) -- identity/ (this node's mesh/realm identity)
# is left untouched on every node, so no re-enrollment is needed
# afterward. Irreversible: every board's full event history is gone for
# good, not just the read-model projection. Requested explicitly by the
# user after the shape_initiated_v1/shape_amended_v1 event consolidation
# left pre-existing boards' shapes unreadable by the new projection --
# rather than backfill one board, wipe everything and start clean, since
# this fleet is throwaway dev/demo infra with nothing worth preserving.
#
# beam01/beam02 (docker): board_store/ on the host bind mount is owned
# by root (the container's own user), so a plain `rm -rf` as the ssh
# user (rl, docker-group member but not root) can't touch it. Rather
# than requiring host sudo, a throwaway alpine container mounts the same
# host directory and deletes it AS root from inside -- stays within
# rl's existing docker-group permissions, no sudo anywhere in this
# script.
#
# msi00 (podman, rootless): board_store/ is already owned by rl
# directly, so a plain rm works; stopped/started via systemctl --user
# since the Quadlet unit is what actually owns this container's
# lifecycle (Restart=always would otherwise fight a bare `podman stop`).
set -eu

echo "=== beam01.lab ==="
ssh rl@beam01.lab '
  set -eu
  docker stop hecate-whiteboard
  docker run --rm -v /bulk0/hecate-whiteboard:/data alpine rm -rf /data/board_store
  docker start hecate-whiteboard
  echo "beam01: board_store wiped, container restarted"
'

echo "=== beam02.lab ==="
ssh rl@beam02.lab '
  set -eu
  docker stop hecate-whiteboard
  docker run --rm -v /bulk0/hecate-whiteboard:/data alpine rm -rf /data/board_store
  docker start hecate-whiteboard
  echo "beam02: board_store wiped, container restarted"
'

echo "=== msi00.lab ==="
ssh rl@msi00.lab '
  set -eu
  systemctl --user stop hecate-whiteboard.service
  rm -rf ~/.hecate/hecate-whiteboard/board_store
  systemctl --user start hecate-whiteboard.service
  echo "msi00: board_store wiped, service restarted"
'

echo "=== done ==="
