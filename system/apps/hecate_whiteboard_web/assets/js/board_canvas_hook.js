// Dumb renderer: draws whatever shapes the server pushes, and reports
// finished shapes back up. Holds no business logic (whether drawing is
// currently allowed is decided server-side and read once from
// data-can-draw -- see BoardLive's own comment on this).
//
// Two rendering substrates, chosen per shape kind: strokes stay on
// <canvas> (cheap for freehand ink, already proven), stickies and text
// labels are plain DOM elements in the "shapes" layer (cheap for
// selection/drag/editing, which canvas hit-testing would make much
// harder for no benefit -- a sticky/text label has exactly one anchor
// point, a native DOM element already gives free click targets and
// text layout). "pending" is a pure local scratchpad for whatever's
// currently under the pointer (an in-progress stroke, a selection
// outline), cleared the moment the server confirms or the gesture ends.
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

function boundingBox(points) {
  const xs = points.map((p) => p.x);
  const ys = points.map((p) => p.y);
  return { minX: Math.min(...xs), minY: Math.min(...ys), maxX: Math.max(...xs), maxY: Math.max(...ys) };
}

// Shortest distance from point p to the segment a-b -- used to hit-test
// a click against a freehand stroke's individual line segments, since a
// stroke has no single rectangle the way a sticky/text label does.
function distanceToSegment(p, a, b) {
  const dx = b.x - a.x;
  const dy = b.y - a.y;
  const lengthSq = dx * dx + dy * dy;
  const t = lengthSq === 0 ? 0 : Math.max(0, Math.min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSq));
  const closestX = a.x + t * dx;
  const closestY = a.y + t * dy;
  return Math.hypot(p.x - closestX, p.y - closestY);
}

const HIT_THRESHOLD_PX = 10;

// How long a peer's pointer must sit still before this browser tells the
// server where it settled -- see TrackPresence.Roster's own header for
// why this is a debounce-on-stop, not a continuous stream: a fast-moving
// cursor produces ZERO mesh traffic, only its resting points do.
const CURSOR_SETTLE_MS = 400;

export const BoardCanvas = {
  mounted() {
    this.committed = this.el.querySelector("#board-canvas-committed");
    this.pending = this.el.querySelector("#board-canvas-pending");
    this.shapesLayer = this.el.querySelector("#board-canvas-shapes");
    this.cursorsLayer = this.el.querySelector("#board-canvas-cursors");
    this.emptyState = document.getElementById("board-empty-state");
    this.canDraw = this.el.dataset.canDraw === "true";

    this.activeTool = "pen"; // "pen" | "text" | "select" | "sticky"
    this.color = "#f2efe6";
    this.stickyColor = "#f2994a";
    this.width = 3;
    this.points = [];
    this.drawing = false;

    this.shapes = []; // every confirmed STROKE, kept so a resize can redraw the canvas layer
    this.domShapes = new Map(); // shape_id -> {el, kind, points, color, text} for stickies/text
    this.selectedShapeId = null;
    this.selectedKind = null; // "stroke" | "dom"
    this.moving = null; // {shapeId, kind, startPoint, originalPoints, el?}

    this.cursors = new Map(); // peer_id -> {el, x, y}
    this.settleTimer = null;

    this.resize();
    window.addEventListener("resize", () => this.resize());

    this.wireInkSwatches();
    this.wireToolButtons();
    this.wireStickySwatches();
    this.wireCanvasInteraction();
    this.wireCursorTracking();
    this.wireDeleteKey();

    this.handleEvent("shapes:snapshot", ({ shapes }) => {
      shapes.forEach((s) => this.renderShape(s));
      this.updateEmptyState(shapes.length > 0);
    });

    this.handleEvent("shapes:append", (stroke) => {
      this.renderShape({ ...stroke, kind: "stroke" });
      this.updateEmptyState(true);
    });

    this.handleEvent("shape_placed", (shape) => {
      this.renderShape(shape);
      this.updateEmptyState(true);
    });

    this.handleEvent("shape_moved", ({ shape_id, points }) => this.applyMove(shape_id, points));

    this.handleEvent("shape_removed", ({ shape_id }) => this.applyRemove(shape_id));

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

  wireInkSwatches() {
    document.querySelectorAll(".swatch").forEach((btn) => {
      btn.addEventListener("click", () => {
        document.querySelectorAll(".swatch").forEach((b) => b.classList.remove("swatch-active"));
        btn.classList.add("swatch-active");
        this.color = btn.dataset.color;
        this.setTool("pen");
      });
    });
  },

  wireStickySwatches() {
    document.querySelectorAll(".sticky-swatch").forEach((btn) => {
      btn.addEventListener("click", () => {
        document
          .querySelectorAll(".sticky-swatch")
          .forEach((b) => b.classList.remove("sticky-swatch-active"));
        btn.classList.add("sticky-swatch-active");
        this.stickyColor = btn.dataset.stickyColor;
        this.setTool("sticky");
      });
    });
  },

  wireToolButtons() {
    document.querySelectorAll("[data-tool]").forEach((btn) => {
      btn.addEventListener("click", () => this.setTool(btn.dataset.tool));
    });
  },

  setTool(tool) {
    this.activeTool = tool;
    this.deselectShape();

    document.querySelectorAll("[data-tool]").forEach((b) => {
      b.classList.toggle("tool-active", b.dataset.tool === tool);
    });
    if (tool !== "sticky") {
      document
        .querySelectorAll(".sticky-swatch")
        .forEach((b) => b.classList.remove("sticky-swatch-active"));
    }

    // Sticky/text DOM elements only intercept clicks in select mode --
    // every other tool needs clicks to fall through to the canvas below
    // so drawing/placing works even where a shape already sits.
    this.shapesLayer.classList.toggle("interactive", tool === "select");
    this.pending.style.cursor = tool === "select" ? "default" : "crosshair";
  },

  wireCanvasInteraction() {
    if (!this.canDraw) return;
    const canvas = this.pending;
    canvas.style.pointerEvents = "auto";

    canvas.addEventListener("pointerdown", (e) => this.onCanvasDown(e));
    canvas.addEventListener("pointermove", (e) => this.onCanvasMove(e));
    window.addEventListener("pointerup", (e) => this.onCanvasUp(e));
  },

  onCanvasDown(e) {
    const p = this.point(e);

    if (this.activeTool === "pen") {
      this.drawing = true;
      this.points = [p];
      return;
    }

    if (this.activeTool === "text" || this.activeTool === "sticky") {
      // Without this, the pointerdown's own default focus handling runs
      // AFTER this handler returns and steals focus back to <body> (the
      // canvas itself isn't focusable), firing the textarea's blur
      // before a single character is typed -- commit() then sees an
      // empty value and silently discards it. Confirmed live: the
      // textarea was being created and removed within the same event
      // dispatch, every time, with no visible trace.
      e.preventDefault();
      this.placeShapeInline(this.activeTool, p);
      return;
    }

    if (this.activeTool === "select") {
      const hit = this.hitTestStroke(p);
      if (hit) {
        this.selectShape(hit.shape_id, "stroke");
        this.moving = { shapeId: hit.shape_id, kind: "stroke", startPoint: p, originalPoints: hit.points };
      } else {
        this.deselectShape();
      }
    }
  },

  onCanvasMove(e) {
    if (this.drawing) {
      this.points.push(this.point(e));
      const ctx = this.pending.getContext("2d");
      ctx.clearRect(0, 0, this.pending.width, this.pending.height);
      drawStroke(ctx, { points: this.points, color: this.color, width: this.width });
      return;
    }

    if (this.moving && this.moving.kind === "stroke") {
      const p = this.point(e);
      const dx = p.x - this.moving.startPoint.x;
      const dy = p.y - this.moving.startPoint.y;
      const translated = this.moving.originalPoints.map((pt) => ({ x: pt.x + dx, y: pt.y + dy }));
      this._lastMoveTranslated = translated;

      const ctx = this.pending.getContext("2d");
      ctx.clearRect(0, 0, this.pending.width, this.pending.height);
      const shape = this.shapes.find((s) => s.shape_id === this.moving.shapeId);
      drawStroke(ctx, { points: translated, color: shape.color, width: shape.width });
    }
  },

  onCanvasUp() {
    if (this.drawing) {
      this.drawing = false;
      const ctx = this.pending.getContext("2d");
      ctx.clearRect(0, 0, this.pending.width, this.pending.height);

      if (this.points.length > 0) {
        this.pushEvent("stroke", { points: this.points, color: this.color, width: this.width });
      }
      this.points = [];
      return;
    }

    if (this.moving && this.moving.kind === "stroke") {
      const ctx = this.pending.getContext("2d");
      ctx.clearRect(0, 0, this.pending.width, this.pending.height);

      const last = this._lastMoveTranslated;
      if (last) {
        this.pushEvent("move_shape", { shape_id: this.moving.shapeId, points: last });
      }
      this.moving = null;
      this._lastMoveTranslated = null;
      this.drawSelectionOutline();
    }
  },

  // Runs regardless of canDraw -- a view-only peer's cursor is still
  // worth showing to collaborators. Attached to the outer wrap (not
  // `this.pending`, which only accepts pointer events when drawing is
  // allowed -- see wireCanvasInteraction above): pointermove bubbles up
  // from whichever layer the pointer is actually over, so this still
  // fires either way. See CURSOR_SETTLE_MS's own comment for why this
  // debounces instead of streaming.
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

  wireDeleteKey() {
    window.addEventListener("keydown", (e) => {
      if (this.activeTool !== "select" || !this.selectedShapeId) return;
      if (e.key !== "Backspace" && e.key !== "Delete") return;
      if (e.target.tagName === "TEXTAREA" || e.target.isContentEditable) return;

      this.pushEvent("remove_shape", { shape_id: this.selectedShapeId });
      this.deselectShape();
    });
  },

  point(e) {
    const rect = this.pending.getBoundingClientRect();
    return { x: e.clientX - rect.left, y: e.clientY - rect.top };
  },

  // Shared placement flow for sticky/text: a local, not-yet-confirmed
  // <textarea> at the click point, styled to preview the eventual shape.
  // Blur/Enter with non-empty text dispatches the real command; the
  // confirmed shape renders moments later via the normal shapes:snapshot/
  // shape_placed broadcast path, same "pending scratchpad, then
  // server-confirmed" pattern strokes already use.
  placeShapeInline(kind, point) {
    const existing = this.el.querySelector(".shape-pending");
    if (existing) existing.remove();

    const textarea = document.createElement("textarea");
    textarea.className = kind === "sticky" ? "shape-sticky shape-pending shape-editing" : "shape-text shape-pending shape-editing";
    textarea.style.setProperty("--sx", point.x + "px");
    textarea.style.setProperty("--sy", point.y + "px");
    textarea.style.setProperty("--shape-color", kind === "sticky" ? this.stickyColor : this.color);
    textarea.style.border = "none";
    textarea.style.resize = "none";
    textarea.style.font = "inherit";
    textarea.style.background = kind === "sticky" ? "var(--shape-color)" : "transparent";
    textarea.style.color = kind === "sticky" ? "var(--slate-deep)" : "var(--shape-color)";
    textarea.placeholder = kind === "sticky" ? "Note..." : "Text...";

    this.shapesLayer.appendChild(textarea);
    textarea.focus();

    const commit = () => {
      const text = textarea.value.trim();
      textarea.remove();
      if (!text) return;

      if (kind === "sticky") {
        this.pushEvent("place_sticky", { x: point.x, y: point.y, color: this.stickyColor, text });
      } else {
        this.pushEvent("place_text", { x: point.x, y: point.y, color: this.color, text });
      }
    };

    textarea.addEventListener("blur", commit);
    textarea.addEventListener("keydown", (e) => {
      if (e.key === "Enter" && !e.shiftKey) {
        e.preventDefault();
        textarea.blur();
      }
      if (e.key === "Escape") {
        textarea.value = "";
        textarea.blur();
      }
    });
  },

  hitTestStroke(point) {
    return this.shapes.find((stroke) => {
      const box = boundingBox(stroke.points);
      if (
        point.x < box.minX - HIT_THRESHOLD_PX ||
        point.x > box.maxX + HIT_THRESHOLD_PX ||
        point.y < box.minY - HIT_THRESHOLD_PX ||
        point.y > box.maxY + HIT_THRESHOLD_PX
      ) {
        return false;
      }

      for (let i = 0; i < stroke.points.length - 1; i++) {
        if (distanceToSegment(point, stroke.points[i], stroke.points[i + 1]) <= HIT_THRESHOLD_PX) {
          return true;
        }
      }
      return stroke.points.length === 1 && Math.hypot(point.x - stroke.points[0].x, point.y - stroke.points[0].y) <= HIT_THRESHOLD_PX;
    });
  },

  selectShape(shapeId, kind) {
    this.deselectShape();
    this.selectedShapeId = shapeId;
    this.selectedKind = kind;

    if (kind === "dom") {
      const entry = this.domShapes.get(shapeId);
      if (entry) entry.el.classList.add("shape-selected");
    } else {
      this.drawSelectionOutline();
    }
  },

  deselectShape() {
    if (this.selectedKind === "dom" && this.selectedShapeId) {
      const entry = this.domShapes.get(this.selectedShapeId);
      if (entry) entry.el.classList.remove("shape-selected");
    }
    this.selectedShapeId = null;
    this.selectedKind = null;

    const ctx = this.pending.getContext("2d");
    ctx.clearRect(0, 0, this.pending.width, this.pending.height);
  },

  drawSelectionOutline() {
    if (this.selectedKind !== "stroke") return;
    const shape = this.shapes.find((s) => s.shape_id === this.selectedShapeId);
    if (!shape) return;

    const box = boundingBox(shape.points);
    const ctx = this.pending.getContext("2d");
    ctx.clearRect(0, 0, this.pending.width, this.pending.height);
    ctx.save();
    ctx.strokeStyle = "#d89b4a";
    ctx.lineWidth = 1.5;
    ctx.setLineDash([5, 4]);
    ctx.strokeRect(box.minX - 6, box.minY - 6, box.maxX - box.minX + 12, box.maxY - box.minY + 12);
    ctx.restore();
  },

  updateEmptyState(hasShapes) {
    if (this.emptyState) this.emptyState.style.display = hasShapes ? "none" : "flex";
  },

  // Dispatches by kind: strokes stay on canvas (unchanged path), sticky/
  // text render as DOM elements -- see this file's own header for why.
  renderShape(shape) {
    if (shape.kind === "sticky" || shape.kind === "text") {
      this.renderDomShape(shape);
    } else {
      this.renderStroke(shape);
    }
  },

  renderStroke(stroke) {
    this.shapes.push(stroke);
    drawStroke(this.committed.getContext("2d"), stroke);
  },

  renderDomShape(shape) {
    const point = shape.points[0];
    let entry = this.domShapes.get(shape.shape_id);

    if (!entry) {
      const el = document.createElement("div");
      el.className = shape.kind === "sticky" ? "shape-sticky" : "shape-text";
      this.shapesLayer.appendChild(el);

      el.addEventListener("pointerdown", (e) => this.onShapeDown(e, shape.shape_id));

      entry = { el, kind: shape.kind };
      this.domShapes.set(shape.shape_id, entry);
    }

    entry.points = shape.points;
    entry.color = shape.color;
    entry.text = shape.text;

    entry.el.style.setProperty("--sx", point.x + "px");
    entry.el.style.setProperty("--sy", point.y + "px");
    entry.el.style.setProperty("--shape-color", shape.color);
    entry.el.textContent = shape.text;
  },

  onShapeDown(e, shapeId) {
    if (this.activeTool !== "select") return;
    e.stopPropagation();

    const entry = this.domShapes.get(shapeId);
    if (!entry) return;

    this.selectShape(shapeId, "dom");

    const start = this.point(e);
    const originX = parseFloat(entry.el.style.getPropertyValue("--sx"));
    const originY = parseFloat(entry.el.style.getPropertyValue("--sy"));

    const onMove = (moveEvent) => {
      const p = this.point(moveEvent);
      const dx = p.x - start.x;
      const dy = p.y - start.y;
      entry.el.style.setProperty("--sx", originX + dx + "px");
      entry.el.style.setProperty("--sy", originY + dy + "px");
    };

    const onUp = (upEvent) => {
      window.removeEventListener("pointermove", onMove);
      window.removeEventListener("pointerup", onUp);

      const p = this.point(upEvent);
      const dx = p.x - start.x;
      const dy = p.y - start.y;
      if (dx === 0 && dy === 0) return;

      const newPoints = [{ x: originX + dx, y: originY + dy }];
      this.pushEvent("move_shape", { shape_id: shapeId, points: newPoints });
    };

    window.addEventListener("pointermove", onMove);
    window.addEventListener("pointerup", onUp);
  },

  applyMove(shapeId, points) {
    const strokeIdx = this.shapes.findIndex((s) => s.shape_id === shapeId);
    if (strokeIdx !== -1) {
      this.shapes[strokeIdx] = { ...this.shapes[strokeIdx], points };
      const ctx = this.committed.getContext("2d");
      ctx.clearRect(0, 0, this.committed.width, this.committed.height);
      this.shapes.forEach((s) => drawStroke(ctx, s));
      if (this.selectedShapeId === shapeId) this.drawSelectionOutline();
      return;
    }

    const entry = this.domShapes.get(shapeId);
    if (entry) {
      entry.points = points;
      entry.el.style.setProperty("--sx", points[0].x + "px");
      entry.el.style.setProperty("--sy", points[0].y + "px");
    }
  },

  applyRemove(shapeId) {
    if (this.selectedShapeId === shapeId) this.deselectShape();

    const strokeIdx = this.shapes.findIndex((s) => s.shape_id === shapeId);
    if (strokeIdx !== -1) {
      this.shapes.splice(strokeIdx, 1);
      const ctx = this.committed.getContext("2d");
      ctx.clearRect(0, 0, this.committed.width, this.committed.height);
      this.shapes.forEach((s) => drawStroke(ctx, s));
      return;
    }

    const entry = this.domShapes.get(shapeId);
    if (entry) {
      entry.el.remove();
      this.domShapes.delete(shapeId);
    }
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
