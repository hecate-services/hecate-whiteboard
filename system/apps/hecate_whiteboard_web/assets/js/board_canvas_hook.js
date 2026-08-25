// Dumb renderer: draws whatever strokes the server pushes, and reports
// finished strokes back up. Holds no business logic (whether drawing is
// currently allowed is decided server-side and read once from
// data-can-draw -- see BoardLive's own comment on this).
//
// Two canvas layers: "committed" only ever receives strokes the server
// has confirmed (the initial snapshot, plus every stroke:append
// broadcast -- including this browser's own, echoed back through the
// same path as everyone else's). "pending" is a pure local scratchpad
// for the stroke currently under the pointer, cleared the moment the
// server confirms it.
function smoothPath(ctx, points) {
  if (points.length < 2) return;
  ctx.beginPath();
  ctx.moveTo(points[0].x, points[0].y);
  for (let i = 1; i < points.length - 1; i++) {
    const p1 = points[i];
    const p2 = points[i + 1];
    const midX = (p1.x + p2.x) / 2;
    const midY = (p1.y + p2.y) / 2;
    ctx.quadraticCurveTo(p1.x, p1.y, midX, midY);
  }
  const last = points[points.length - 1];
  ctx.lineTo(last.x, last.y);
  ctx.stroke();
}

function drawStroke(ctx, stroke) {
  ctx.save();
  ctx.strokeStyle = stroke.color;
  ctx.lineWidth = stroke.width;
  ctx.lineCap = "round";
  ctx.lineJoin = "round";

  if (stroke.points.length === 1) {
    ctx.beginPath();
    ctx.arc(stroke.points[0].x, stroke.points[0].y, stroke.width / 2, 0, Math.PI * 2);
    ctx.fillStyle = stroke.color;
    ctx.fill();
  } else {
    smoothPath(ctx, stroke.points);
  }

  ctx.restore();
}

// How long a peer's pointer must sit still before this browser tells the
// server where it settled -- see TrackPresence.Roster's own header for
// why this is a debounce-on-stop, not a continuous stream: a fast-moving
// cursor produces ZERO mesh traffic, only its resting points do.
const CURSOR_SETTLE_MS = 400;

export const BoardCanvas = {
  mounted() {
    this.committed = this.el.querySelector("#board-canvas-committed");
    this.pending = this.el.querySelector("#board-canvas-pending");
    this.cursorsLayer = this.el.querySelector("#board-canvas-cursors");
    this.emptyState = document.getElementById("board-empty-state");
    this.canDraw = this.el.dataset.canDraw === "true";
    this.color = "#f2efe6";
    this.width = 3;
    this.points = [];
    this.drawing = false;
    this.shapes = []; // every confirmed stroke, kept so a resize can redraw the layer instead of losing it
    this.cursors = new Map(); // peer_id -> {el, x, y}
    this.settleTimer = null;

    this.resize();
    window.addEventListener("resize", () => this.resize());

    this.wireToolbar();
    this.wirePointerEvents();
    this.wireCursorTracking();

    this.handleEvent("shapes:snapshot", ({ shapes }) => {
      shapes.forEach((s) => this.renderCommitted(s));
      this.updateEmptyState(shapes.length > 0);
    });

    this.handleEvent("shapes:append", (stroke) => {
      this.renderCommitted(stroke);
      this.updateEmptyState(true);
    });

    this.handleEvent("cursor:snapshot", ({ cursors }) => {
      cursors.forEach((c) => this.updateCursor(c, /* instant */ true));
    });

    this.handleEvent("cursor:update", (cursor) => this.updateCursor(cursor, false));

    this.handleEvent("cursor:remove", ({ peer_id }) => this.removeCursor(peer_id));
  },

  resize() {
    [this.committed, this.pending].forEach((canvas) => {
      const rect = this.el.getBoundingClientRect();
      const ratio = window.devicePixelRatio || 1;
      canvas.width = rect.width * ratio;
      canvas.height = rect.height * ratio;
      canvas.style.width = rect.width + "px";
      canvas.style.height = rect.height + "px";
      canvas.getContext("2d").setTransform(ratio, 0, 0, ratio, 0, 0);
    });

    const ctx = this.committed.getContext("2d");
    ctx.clearRect(0, 0, this.committed.width, this.committed.height);
    this.shapes.forEach((s) => drawStroke(ctx, s));
  },

  wireToolbar() {
    document.querySelectorAll(".swatch").forEach((btn) => {
      btn.addEventListener("click", () => {
        document.querySelectorAll(".swatch").forEach((b) => b.classList.remove("swatch-active"));
        btn.classList.add("swatch-active");
        this.color = btn.dataset.color;
      });
    });
  },

  wirePointerEvents() {
    if (!this.canDraw) return;
    const canvas = this.pending;

    canvas.style.pointerEvents = "auto";
    canvas.addEventListener("pointerdown", (e) => this.startStroke(e));
    canvas.addEventListener("pointermove", (e) => this.extendStroke(e));
    window.addEventListener("pointerup", () => this.finishStroke());
  },

  // Runs regardless of canDraw -- a view-only peer's cursor is still
  // worth showing to collaborators. Attached to the outer wrap (not
  // `this.pending`, which only accepts pointer events when drawing is
  // allowed -- see wirePointerEvents above): pointermove bubbles up from
  // whichever layer the pointer is actually over, so this still fires
  // either way. See CURSOR_SETTLE_MS's own comment for why this debounces
  // instead of streaming.
  wireCursorTracking() {
    this.el.addEventListener("pointermove", (e) => {
      const p = this.point(e);
      clearTimeout(this.settleTimer);
      this.settleTimer = setTimeout(() => {
        this.pushEvent("cursor:settle", { x: p.x, y: p.y });
      }, CURSOR_SETTLE_MS);
    });

    this.el.addEventListener("pointerleave", () => clearTimeout(this.settleTimer));
  },

  point(e) {
    const rect = this.pending.getBoundingClientRect();
    return { x: e.clientX - rect.left, y: e.clientY - rect.top };
  },

  startStroke(e) {
    this.drawing = true;
    this.points = [this.point(e)];
  },

  extendStroke(e) {
    if (!this.drawing) return;
    this.points.push(this.point(e));

    const ctx = this.pending.getContext("2d");
    ctx.clearRect(0, 0, this.pending.width, this.pending.height);
    drawStroke(ctx, { points: this.points, color: this.color, width: this.width });
  },

  finishStroke() {
    if (!this.drawing) return;
    this.drawing = false;

    const ctx = this.pending.getContext("2d");
    ctx.clearRect(0, 0, this.pending.width, this.pending.height);

    if (this.points.length > 0) {
      this.pushEvent("stroke", { points: this.points, color: this.color, width: this.width });
    }
    this.points = [];
  },

  renderCommitted(stroke) {
    this.shapes.push(stroke);
    drawStroke(this.committed.getContext("2d"), stroke);
  },

  updateEmptyState(hasShapes) {
    if (this.emptyState) this.emptyState.style.display = hasShapes ? "none" : "flex";
  },

  // instant=true (the late-join snapshot only) places a marker with no
  // ghost left behind -- there's no "previous position" to fade from,
  // this peer simply wasn't visible a moment ago.
  updateCursor({ peer_id, x, y, color, label }, instant) {
    const existing = this.cursors.get(peer_id);
    if (existing && !instant) this.spawnGhost(existing);

    const el = existing ? existing.el : this.createCursorEl();
    if (!this.cursorsLayer.contains(el)) this.cursorsLayer.appendChild(el);

    el.style.setProperty("--cx", x + "px");
    el.style.setProperty("--cy", y + "px");
    el.style.setProperty("--peer-color", color);
    el.querySelector(".cursor-label").textContent = label;

    this.cursors.set(peer_id, { el, x, y, color, label });
  },

  removeCursor(peer_id) {
    const existing = this.cursors.get(peer_id);
    if (!existing) return;
    this.spawnGhost(existing);
    existing.el.remove();
    this.cursors.delete(peer_id);
  },

  createCursorEl() {
    const el = document.createElement("div");
    el.className = "cursor-marker";

    const dot = document.createElement("span");
    dot.className = "cursor-dot";
    el.appendChild(dot);

    const tag = document.createElement("span");
    tag.className = "cursor-label";
    el.appendChild(tag);

    return el;
  },

  // The old position, left behind to fade -- see .cursor-ghost's own CSS
  // comment for why this reads as motion without a continuous glide.
  spawnGhost({ x, y, color, label }) {
    const ghost = this.createCursorEl();
    ghost.classList.add("cursor-ghost");
    ghost.style.setProperty("--cx", x + "px");
    ghost.style.setProperty("--cy", y + "px");
    ghost.style.setProperty("--peer-color", color);
    ghost.querySelector(".cursor-label").textContent = label;
    this.cursorsLayer.appendChild(ghost);

    requestAnimationFrame(() => ghost.classList.add("cursor-ghost-fade"));
    setTimeout(() => ghost.remove(), 650);
  },

  destroyed() {
    clearTimeout(this.settleTimer);
  },
};
