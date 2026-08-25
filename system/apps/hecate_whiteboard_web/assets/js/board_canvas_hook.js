// Dumb renderer: draws whatever shapes the server pushes, and reports
// finished shapes back up. Holds no business logic (whether drawing is
// currently allowed is decided server-side and read once from
// data-can-draw -- see BoardLive's own comment on this).
//
// Two rendering substrates, chosen per shape kind: strokes and basic
// shapes (rectangle/ellipse/triangle) stay on <canvas> (cheap, and
// selection there is a plain bounding-box/segment-distance hit test),
// stickies and text labels are plain DOM elements in the "shapes" layer
// (cheap for selection/drag/editing -- a sticky/text label has exactly
// one anchor point, a native DOM element gives free click targets and
// text layout). "pending" is a pure local scratchpad for whatever's
// currently under the pointer (an in-progress stroke or shape drag, a
// selection outline), cleared the moment the server confirms or the
// gesture ends.
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

// Basic shapes are always outlined (not filled) in the caller's ink
// color, and always defined by the two opposite corners of a bounding
// box -- the same click-drag convention every other drawing tool uses
// for these three, and the shape a rename `shape.kind` uses to derive
// each corner-based reconstruction (see GEOMETRY_KINDS below).
function geometryBox(points) {
  const [a, b] = points;
  return {
    x: Math.min(a.x, b.x),
    y: Math.min(a.y, b.y),
    w: Math.abs(b.x - a.x),
    h: Math.abs(b.y - a.y),
  };
}

function drawRectangle(ctx, shape) {
  const { x, y, w, h } = geometryBox(shape.points);
  ctx.save();
  ctx.strokeStyle = shape.color;
  ctx.lineWidth = 2;
  ctx.strokeRect(x, y, w, h);
  ctx.restore();
}

function drawEllipse(ctx, shape) {
  const { x, y, w, h } = geometryBox(shape.points);
  ctx.save();
  ctx.strokeStyle = shape.color;
  ctx.lineWidth = 2;
  ctx.beginPath();
  ctx.ellipse(x + w / 2, y + h / 2, w / 2, h / 2, 0, 0, Math.PI * 2);
  ctx.stroke();
  ctx.restore();
}

function drawTriangle(ctx, shape) {
  const { x, y, w, h } = geometryBox(shape.points);
  ctx.save();
  ctx.strokeStyle = shape.color;
  ctx.lineWidth = 2;
  ctx.beginPath();
  ctx.moveTo(x + w / 2, y);
  ctx.lineTo(x + w, y + h);
  ctx.lineTo(x, y + h);
  ctx.closePath();
  ctx.stroke();
  ctx.restore();
}

// Single dispatch point for every canvas-rendered shape kind -- used by
// the confirmed-shape layer, the live drag-to-size preview, and the
// live selected-shape-move preview, so all three always agree on what
// each kind looks like.
function drawShape(ctx, shape) {
  switch (shape.kind) {
    case "rectangle":
      return drawRectangle(ctx, shape);
    case "ellipse":
      return drawEllipse(ctx, shape);
    case "triangle":
      return drawTriangle(ctx, shape);
    default:
      return drawStroke(ctx, shape);
  }
}

function boundingBox(points) {
  const xs = points.map((p) => p.x);
  const ys = points.map((p) => p.y);
  return { minX: Math.min(...xs), minY: Math.min(...ys), maxX: Math.max(...xs), maxY: Math.max(...ys) };
}

function pointInBoundingBox(point, points, padding) {
  const box = boundingBox(points);
  return (
    point.x >= box.minX - padding &&
    point.x <= box.maxX + padding &&
    point.y >= box.minY - padding &&
    point.y <= box.maxY + padding
  );
}

// Shortest distance from point p to the segment a-b -- used to hit-test
// a click against a freehand stroke's individual line segments, since a
// stroke has no single rectangle the way a basic shape does.
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
const GEOMETRY_KINDS = ["rectangle", "ellipse", "triangle"];
// Below this, a click-drag reads as an accidental click, not real intent
// to draw a zero-size shape -- mirrors how draw_stroke's own single-point
// "dot" case is the one deliberate exception, not the default.
const MIN_GEOMETRY_SIZE_PX = 4;
// How far a pasted shape is offset from what was copied, so paste never
// lands exactly on top of the original with no visible sign anything
// happened.
const PASTE_OFFSET_PX = 24;

// Distinct per-tool cursors -- a user reported switching tools gave no
// visible feedback at all, and they were right: every non-select tool
// fell back to the same bare "crosshair". Text/sticky share "text"
// since both ultimately open a typeable textarea on click.
const CURSOR_BY_TOOL = {
  pen: "crosshair",
  text: "text",
  sticky: "text",
  select: "default",
  rectangle: "crosshair",
  ellipse: "crosshair",
  triangle: "crosshair",
};

// How long a peer's pointer must sit still before this browser tells the
// server where it settled -- see TrackPresence.Roster's own header for
// why this is a debounce-on-stop, not a continuous stream: a fast-moving
// cursor produces ZERO mesh traffic, only its resting points do.
const CURSOR_SETTLE_MS = 400;

// Camera: every stored/transmitted point (strokes, shapes, cursors) is
// in WORLD space, independent of any one viewer's window size or zoom
// level -- the camera (pan offset + zoom factor) is purely local,
// client-side, never sent anywhere. Before this, a point was literally
// "pixels from the canvas's top-left at draw time" (camera was
// implicitly identity), so old boards need no migration: their stored
// coordinates are indistinguishable from world coordinates recorded
// under an identity camera.
const MIN_ZOOM = 0.1;
const MAX_ZOOM = 4;
// Tuned so one normal mouse-wheel notch (~100 raw deltaY) or a light
// trackpad pinch feels like a deliberate, moderate step -- not a raw
// 1:1 mapping, which would make zoom hypersensitive on precision
// trackpads that report large deltaY values for small gestures.
const ZOOM_WHEEL_SENSITIVITY = 0.0015;

export const BoardCanvas = {
  mounted() {
    this.committed = this.el.querySelector("#board-canvas-committed");
    this.pending = this.el.querySelector("#board-canvas-pending");
    this.shapesLayer = this.el.querySelector("#board-canvas-shapes");
    this.cursorsLayer = this.el.querySelector("#board-canvas-cursors");
    this.emptyState = document.getElementById("board-empty-state");
    this.zoomIndicator = document.getElementById("board-zoom-indicator");
    this.canDraw = this.el.dataset.canDraw === "true";

    // Screen = world * zoom + {x, y}. Local to this tab, never persisted
    // or transmitted -- resets to identity on every mount, same as any
    // infinite-canvas tool's default. See this file's own header for why
    // NOT resetting it silently loses nothing on old boards.
    this.camera = { x: 0, y: 0, zoom: 1 };

    this.activeTool = "pen"; // "pen" | "text" | "select" | "sticky" | "rectangle" | "ellipse" | "triangle"
    this.color = "#f2efe6";
    this.stickyColor = "#f2994a";
    this.width = 3;
    this.points = [];
    this.drawing = false;
    this.drawingGeometry = null; // {kind, start} while a shape tool's drag is in progress
    this.ghostEl = null; // live placement preview while the sticky tool is armed

    this.shapes = []; // every confirmed canvas shape (stroke/rectangle/ellipse/triangle)
    this.domShapes = new Map(); // shape_id -> {el, kind, points, color, text} for stickies/text
    this.selectedShapeId = null;
    this.selectedKind = null; // "canvas" | "dom"
    this.moving = null; // {shapeId, kind, startPoint, originalPoints}
    this.clipboard = null; // {kind, points, color, width?, text?} -- copy/cut/paste

    this.cursors = new Map(); // peer_id -> {el, x, y}
    this.settleTimer = null;

    this.resize();
    window.addEventListener("resize", () => this.resize());

    this.wireInkSwatches();
    this.wireToolButtons();
    this.wireStickySwatches();
    this.wireCollapseToggle();
    this.wireCanvasInteraction();
    this.wireCursorTracking();
    this.wireKeyboardShortcuts();
    this.wireCameraControls();

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
      // No setTransform here -- withCamera/clearCanvas set the full
      // transform themselves on every call, so this canvas's own
      // persistent transform state is never relied on between draws.
    });

    this.redrawCommitted();
  },

  // Resets to a DPR-only transform (undoing whatever any PREVIOUS draw
  // left active) and returns the ratio, so callers can clear in
  // CSS-pixel space before applying the camera themselves -- clearRect
  // respects whatever transform is active when it's called, so clearing
  // under an already-zoomed transform would only clear part of the
  // visible canvas.
  resetTransform(ctx) {
    const ratio = window.devicePixelRatio || 1;
    ctx.setTransform(ratio, 0, 0, ratio, 0, 0);
    return ratio;
  },

  applyCameraTransform(ctx) {
    ctx.translate(this.camera.x, this.camera.y);
    ctx.scale(this.camera.zoom, this.camera.zoom);
  },

  // Every canvas draw goes through here, drawWithCamera, or clearCanvas
  // -- never a raw ctx.clearRect/draw pair -- so the transform is
  // always set fresh, never assumed left over from a previous call.
  withCamera(canvas, drawFn) {
    const ctx = canvas.getContext("2d");
    ctx.save();
    const ratio = this.resetTransform(ctx);
    ctx.clearRect(0, 0, canvas.width / ratio, canvas.height / ratio);
    this.applyCameraTransform(ctx);
    drawFn(ctx);
    ctx.restore();
  },

  // Same transform as withCamera, but does NOT clear first -- for
  // incrementally appending ONE new shape onto committed without
  // redrawing everything already there (renderCanvasShape).
  drawWithCamera(canvas, drawFn) {
    const ctx = canvas.getContext("2d");
    ctx.save();
    this.resetTransform(ctx);
    this.applyCameraTransform(ctx);
    drawFn(ctx);
    ctx.restore();
  },

  clearCanvas(canvas) {
    const ctx = canvas.getContext("2d");
    ctx.save();
    const ratio = this.resetTransform(ctx);
    ctx.clearRect(0, 0, canvas.width / ratio, canvas.height / ratio);
    ctx.restore();
  },

  redrawCommitted() {
    this.withCamera(this.committed, (ctx) => {
      this.shapes.forEach((s) => drawShape(ctx, s));
    });
  },

  toWorld(screenPt) {
    return {
      x: (screenPt.x - this.camera.x) / this.camera.zoom,
      y: (screenPt.y - this.camera.y) / this.camera.zoom,
    };
  },

  toScreen(worldPt) {
    return {
      x: worldPt.x * this.camera.zoom + this.camera.x,
      y: worldPt.y * this.camera.zoom + this.camera.y,
    };
  },

  // The ONE place that applies a changed camera everywhere it matters:
  // the canvas-drawn layer (committed shapes, via redrawCommitted), the
  // pending layer (the selection outline, if anything's selected --
  // drawSelectionOutline is safe to call unconditionally, see its own
  // comment), the DOM shapes layer (a plain CSS transform -- see
  // .shapes-layer's own comment for why individual stickies/text/ghost
  // need no changes of their own), and presence cursors (kept in screen
  // space deliberately, so peer markers/labels stay a constant SIZE
  // regardless of zoom instead of scaling with board content -- see
  // repositionCursors). Does NOT touch an in-progress gesture (a live
  // stroke/geometry-drag/move-drag) -- panning or zooming mid-gesture
  // is not a supported combination, same as every other tool.
  applyCamera() {
    this.shapesLayer.style.transform = `translate(${this.camera.x}px, ${this.camera.y}px) scale(${this.camera.zoom})`;
    this.redrawCommitted();
    this.drawSelectionOutline();
    this.repositionCursors();
    this.updateZoomIndicator();
  },

  updateZoomIndicator() {
    if (this.zoomIndicator) {
      this.zoomIndicator.textContent = Math.round(this.camera.zoom * 100) + "%";
    }
  },

  resetCamera() {
    this.camera = { x: 0, y: 0, zoom: 1 };
    this.applyCamera();
  },

  screenPoint(e) {
    const rect = this.el.getBoundingClientRect();
    return { x: e.clientX - rect.left, y: e.clientY - rect.top };
  },

  panBy(dx, dy) {
    this.camera.x += dx;
    this.camera.y += dy;
    this.applyCamera();
  },

  // Zoom toward a fixed screen point (the cursor) -- the world point
  // currently under the cursor stays under the cursor after the zoom,
  // which is what makes zooming feel anchored rather than like the
  // board is sliding out from under the pointer.
  zoomAt(screenPt, rawDelta) {
    const factor = Math.exp(-rawDelta * ZOOM_WHEEL_SENSITIVITY);
    const newZoom = Math.min(MAX_ZOOM, Math.max(MIN_ZOOM, this.camera.zoom * factor));
    const worldPt = this.toWorld(screenPt);

    this.camera.zoom = newZoom;
    this.camera.x = screenPt.x - worldPt.x * newZoom;
    this.camera.y = screenPt.y - worldPt.y * newZoom;
    this.applyCamera();
  },

  // Plain scroll pans (trackpad two-finger scroll or a mouse wheel);
  // ctrl/cmd+scroll zooms -- same convention as every other
  // infinite-canvas tool, and the one macOS itself uses for pinch-zoom
  // (a trackpad pinch dispatches a wheel event with ctrlKey set, even
  // with no physical Ctrl key involved). Works regardless of canDraw --
  // panning/zooming is a local viewing concern, not a drawing
  // permission, so a read-only joined board is still navigable.
  wireCameraControls() {
    this.el.addEventListener(
      "wheel",
      (e) => {
        e.preventDefault();
        if (e.ctrlKey || e.metaKey) {
          this.zoomAt(this.screenPoint(e), e.deltaY);
        } else {
          this.panBy(-e.deltaX, -e.deltaY);
        }
      },
      { passive: false },
    );

    if (this.zoomIndicator) {
      this.zoomIndicator.addEventListener("click", () => this.resetCamera());
    }
  },

  // Cursor markers deliberately do NOT live inside the zoom-scaled
  // shapes-layer transform -- a peer's dot/label should stay a constant
  // SCREEN size as you zoom, like a map pin, not grow or shrink with
  // board content. So cursors-layer stays untransformed, and each
  // marker's screen position is computed fresh from its stored WORLD
  // position whenever the camera changes.
  repositionCursors() {
    this.cursors.forEach(({ el, x, y }) => {
      const screenPt = this.toScreen({ x, y });
      el.style.setProperty("--cx", screenPt.x + "px");
      el.style.setProperty("--cy", screenPt.y + "px");
    });
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
    document.querySelectorAll(".sticky-row").forEach((btn) => {
      btn.addEventListener("click", () => {
        document.querySelectorAll(".sticky-row").forEach((b) => b.classList.remove("sticky-row-active"));
        btn.classList.add("sticky-row-active");
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

  wireCollapseToggle() {
    const pane = document.getElementById("side-pane");
    const btn = document.getElementById("side-pane-collapse");
    if (!pane || !btn) return;

    btn.addEventListener("click", () => {
      const collapsed = pane.classList.toggle("collapsed");
      btn.title = collapsed ? "Expand toolbox" : "Collapse toolbox";
      // .side-pane's width is CSS-transitioned (150ms) -- only a window
      // resize event normally triggers this.resize(), so without this
      // the canvas's pixel buffer and inline CSS size stay pinned to
      // whatever they were before the toggle while the pane's own box
      // moves, and every click coordinate silently misaligns from what's
      // actually drawn. Waits out the transition rather than resizing
      // mid-animation into a half-collapsed width.
      setTimeout(() => this.resize(), 180);
    });
  },

  setTool(tool) {
    this.activeTool = tool;
    this.deselectShape();
    if (tool !== "sticky") this.hideGhost();

    document.querySelectorAll("[data-tool]").forEach((b) => {
      b.classList.toggle("tool-row-active", b.dataset.tool === tool);
    });
    if (tool !== "sticky") {
      document.querySelectorAll(".sticky-row").forEach((b) => b.classList.remove("sticky-row-active"));
    }

    // Sticky/text DOM elements only intercept clicks in select mode --
    // every other tool needs clicks to fall through to the canvas below
    // so drawing/placing works even where a shape already sits.
    this.shapesLayer.classList.toggle("interactive", tool === "select");
    this.pending.style.cursor = CURSOR_BY_TOOL[tool] || "crosshair";
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
      this.hideGhost();
      this.placeShapeInline(this.activeTool, p);
      return;
    }

    if (GEOMETRY_KINDS.includes(this.activeTool)) {
      this.drawingGeometry = { kind: this.activeTool, start: p };
      return;
    }

    if (this.activeTool === "select") {
      const hit = this.hitTestCanvasShape(p);
      if (hit) {
        this.selectShape(hit.shape_id, "canvas");
        this.moving = { shapeId: hit.shape_id, kind: "canvas", startPoint: p, originalPoints: hit.points };
      } else {
        this.deselectShape();
      }
    }
  },

  onCanvasMove(e) {
    if (this.drawing) {
      this.points.push(this.point(e));
      this.withCamera(this.pending, (ctx) => {
        drawStroke(ctx, { points: this.points, color: this.color, width: this.width });
      });
      return;
    }

    if (this.drawingGeometry) {
      const p = this.point(e);
      this.withCamera(this.pending, (ctx) => {
        drawShape(ctx, { kind: this.drawingGeometry.kind, points: [this.drawingGeometry.start, p], color: this.color });
      });
      return;
    }

    if (this.moving && this.moving.kind === "canvas") {
      const p = this.point(e);
      const dx = p.x - this.moving.startPoint.x;
      const dy = p.y - this.moving.startPoint.y;
      const translated = this.moving.originalPoints.map((pt) => ({ x: pt.x + dx, y: pt.y + dy }));
      this._lastMoveTranslated = translated;

      const shape = this.shapes.find((s) => s.shape_id === this.moving.shapeId);
      this.withCamera(this.pending, (ctx) => {
        drawShape(ctx, { ...shape, points: translated });
      });
      return;
    }

    // Live placement preview -- a ghost of the sticky-to-be, following
    // the pointer so its size/color is never a surprise. See CSS
    // .shape-ghost's own comment for why it's purely decorative.
    if (this.activeTool === "sticky") {
      this.updateGhost(this.point(e));
    }
  },

  onCanvasUp(e) {
    if (this.drawing) {
      this.drawing = false;
      this.clearCanvas(this.pending);

      if (this.points.length > 0) {
        this.pushEvent("stroke", { points: this.points, color: this.color, width: this.width });
      }
      this.points = [];
      return;
    }

    if (this.drawingGeometry) {
      const p = this.point(e);
      this.clearCanvas(this.pending);

      const { kind, start } = this.drawingGeometry;
      this.drawingGeometry = null;

      // Divided by zoom so this reads as a fixed SCREEN-pixel intent
      // threshold regardless of zoom level -- a fixed world-unit
      // threshold would make a deliberate small shape nearly impossible
      // to draw when zoomed out, or trigger on a barely-there jitter
      // when zoomed way in.
      const minSize = MIN_GEOMETRY_SIZE_PX / this.camera.zoom;
      if (Math.abs(p.x - start.x) >= minSize || Math.abs(p.y - start.y) >= minSize) {
        this.pushEvent("draw_geometry", { kind, points: [start, p], color: this.color });
      }
      return;
    }

    if (this.moving && this.moving.kind === "canvas") {
      this.clearCanvas(this.pending);

      const last = this._lastMoveTranslated;
      if (last) {
        this.pushEvent("move_shape", { shape_id: this.moving.shapeId, points: last });
      }
      this.moving = null;
      this._lastMoveTranslated = null;
      this.drawSelectionOutline();
    }
  },

  updateGhost(point) {
    if (!this.ghostEl) {
      this.ghostEl = document.createElement("div");
      this.ghostEl.className = "shape-ghost";
      this.shapesLayer.appendChild(this.ghostEl);
    }
    this.ghostEl.style.setProperty("--sx", point.x + "px");
    this.ghostEl.style.setProperty("--sy", point.y + "px");
    this.ghostEl.style.setProperty("--shape-color", this.stickyColor);
  },

  hideGhost() {
    if (this.ghostEl) {
      this.ghostEl.remove();
      this.ghostEl = null;
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

    this.el.addEventListener("pointerleave", () => {
      clearTimeout(this.settleTimer);
      this.hideGhost();
    });
  },

  wireKeyboardShortcuts() {
    window.addEventListener("keydown", (e) => {
      const inTextInput = e.target.tagName === "TEXTAREA" || e.target.isContentEditable;

      // A text/sticky placement's own textarea has its own Escape
      // handler (clears the value, blurs -- see placeShapeInline), so
      // this deliberately does nothing while one is focused rather than
      // fighting it or double-handling the same keypress.
      if (e.key === "Escape" && !inTextInput) {
        this.cancelGesture();
        return;
      }

      if (this.activeTool === "select" && this.selectedShapeId && !inTextInput) {
        if (e.key === "Backspace" || e.key === "Delete") {
          this.pushEvent("remove_shape", { shape_id: this.selectedShapeId });
          this.deselectShape();
          return;
        }
      }

      const meta = e.ctrlKey || e.metaKey;
      if (!meta || inTextInput) return;

      const key = e.key.toLowerCase();
      if (key === "c") {
        this.copySelectedShape();
      } else if (key === "x") {
        this.copySelectedShape();
        if (this.selectedShapeId) {
          this.pushEvent("remove_shape", { shape_id: this.selectedShapeId });
          this.deselectShape();
        }
      } else if (key === "v") {
        this.pasteClipboard();
      }
    });
  },

  // Aborts whatever's actively being drawn or dragged, WITHOUT
  // committing anything to the server -- the canvas/shape ends up
  // exactly as it was before the gesture started. The active tool
  // itself is untouched (matches Figma/Excalidraw convention: Escape
  // cancels the current stroke, not the tool you're in). A DOM shape
  // (sticky/text) mid-drag is handled separately, inside onShapeDown's
  // own closure -- its move state lives in local variables there, not
  // on `this`, so it needs its own Escape listener rather than this one
  // reaching in.
  cancelGesture() {
    if (this.drawing) {
      this.drawing = false;
      this.points = [];
      this.clearCanvas(this.pending);
      return;
    }

    if (this.drawingGeometry) {
      this.drawingGeometry = null;
      this.clearCanvas(this.pending);
      return;
    }

    if (this.moving && this.moving.kind === "canvas") {
      this.moving = null;
      this._lastMoveTranslated = null;
      this.drawSelectionOutline();
    }
  },

  copySelectedShape() {
    if (!this.selectedShapeId) return;

    if (this.selectedKind === "canvas") {
      const shape = this.shapes.find((s) => s.shape_id === this.selectedShapeId);
      if (shape) {
        this.clipboard = { kind: shape.kind, points: shape.points, color: shape.color, width: shape.width };
      }
    } else if (this.selectedKind === "dom") {
      const entry = this.domShapes.get(this.selectedShapeId);
      if (entry) {
        this.clipboard = { kind: entry.kind, points: entry.points, color: entry.color, text: entry.text };
      }
    }
  },

  // No backend command needed for any of copy/cut/paste -- paste just
  // re-dispatches the same command a fresh placement would use (stroke/
  // place_sticky/place_text/draw_geometry), each of which already mints
  // its own shape_id server-side, so a pasted shape is simply a new
  // shape from the server's point of view.
  pasteClipboard() {
    if (!this.clipboard) return;

    const points = this.clipboard.points.map((p) => ({
      x: p.x + PASTE_OFFSET_PX,
      y: p.y + PASTE_OFFSET_PX,
    }));

    switch (this.clipboard.kind) {
      case "stroke":
        this.pushEvent("stroke", { points, color: this.clipboard.color, width: this.clipboard.width });
        break;

      case "sticky":
        this.pushEvent("place_sticky", {
          x: points[0].x,
          y: points[0].y,
          color: this.clipboard.color,
          text: this.clipboard.text,
        });
        break;

      case "text":
        this.pushEvent("place_text", {
          x: points[0].x,
          y: points[0].y,
          color: this.clipboard.color,
          text: this.clipboard.text,
        });
        break;

      default:
        if (GEOMETRY_KINDS.includes(this.clipboard.kind)) {
          this.pushEvent("draw_geometry", { kind: this.clipboard.kind, points, color: this.clipboard.color });
        }
    }
  },

  // Every caller of point(e) wants a WORLD coordinate -- what gets
  // stored, drawn (via withCamera, which applies the same camera), and
  // hit-tested against. screenPoint(e) is the one place that wants the
  // raw screen position instead (zoomAt, to keep the point under the
  // cursor fixed).
  point(e) {
    const rect = this.pending.getBoundingClientRect();
    return this.toWorld({ x: e.clientX - rect.left, y: e.clientY - rect.top });
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

  // Threshold divided by zoom, same reasoning as onCanvasUp's
  // minSize: point (and every stored shape point) is WORLD space, so a
  // fixed HIT_THRESHOLD_PX would feel impossibly precise when zoomed
  // out and overly forgiving when zoomed in. Dividing keeps the
  // effective SCREEN-pixel tolerance constant across zoom levels.
  hitTestCanvasShape(point) {
    const threshold = HIT_THRESHOLD_PX / this.camera.zoom;
    return this.shapes.find((shape) => {
      if (shape.kind === "stroke") return this.strokeHit(point, shape, threshold);
      return pointInBoundingBox(point, shape.points, threshold);
    });
  },

  strokeHit(point, stroke, threshold) {
    const box = boundingBox(stroke.points);
    if (
      point.x < box.minX - threshold ||
      point.x > box.maxX + threshold ||
      point.y < box.minY - threshold ||
      point.y > box.maxY + threshold
    ) {
      return false;
    }

    for (let i = 0; i < stroke.points.length - 1; i++) {
      if (distanceToSegment(point, stroke.points[i], stroke.points[i + 1]) <= threshold) {
        return true;
      }
    }
    return stroke.points.length === 1 && Math.hypot(point.x - stroke.points[0].x, point.y - stroke.points[0].y) <= threshold;
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

    this.clearCanvas(this.pending);
  },

  // Always clears pending first, whether or not anything is selected --
  // makes this safe to call any time pending needs a refresh (see
  // applyCamera), not just right after a selection changes.
  drawSelectionOutline() {
    this.clearCanvas(this.pending);
    if (this.selectedKind !== "canvas") return;
    const shape = this.shapes.find((s) => s.shape_id === this.selectedShapeId);
    if (!shape) return;

    const box = boundingBox(shape.points);
    this.withCamera(this.pending, (ctx) => {
      ctx.save();
      ctx.strokeStyle = "#d89b4a";
      ctx.lineWidth = 1.5;
      ctx.setLineDash([5, 4]);
      ctx.strokeRect(box.minX - 6, box.minY - 6, box.maxX - box.minX + 12, box.maxY - box.minY + 12);
      ctx.restore();
    });
  },

  updateEmptyState(hasShapes) {
    if (this.emptyState) this.emptyState.style.display = hasShapes ? "none" : "flex";
  },

  // Dispatches by kind: strokes/basic shapes stay on canvas, sticky/text
  // render as DOM elements -- see this file's own header for why.
  renderShape(shape) {
    if (shape.kind === "sticky" || shape.kind === "text") {
      this.renderDomShape(shape);
    } else {
      this.renderCanvasShape(shape);
    }
  },

  renderCanvasShape(shape) {
    this.shapes.push(shape);
    this.drawWithCamera(this.committed, (ctx) => drawShape(ctx, shape));
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

    const cleanup = () => {
      window.removeEventListener("pointermove", onMove);
      window.removeEventListener("pointerup", onUp);
      window.removeEventListener("keydown", onKeydown);
    };

    const onUp = (upEvent) => {
      cleanup();

      const p = this.point(upEvent);
      const dx = p.x - start.x;
      const dy = p.y - start.y;
      if (dx === 0 && dy === 0) return;

      const newPoints = [{ x: originX + dx, y: originY + dy }];
      this.pushEvent("move_shape", { shape_id: shapeId, points: newPoints });
    };

    // This drag's own move state (originX/originY/start) lives in these
    // local variables, not on `this` -- cancelGesture (the global
    // Escape handler) has no way to reach it, so this drag needs its
    // own Escape listener, cleaned up the same way pointerup's is.
    const onKeydown = (keyEvent) => {
      if (keyEvent.key !== "Escape") return;
      cleanup();
      entry.el.style.setProperty("--sx", originX + "px");
      entry.el.style.setProperty("--sy", originY + "px");
    };

    window.addEventListener("pointermove", onMove);
    window.addEventListener("pointerup", onUp);
    window.addEventListener("keydown", onKeydown);
  },

  applyMove(shapeId, points) {
    const idx = this.shapes.findIndex((s) => s.shape_id === shapeId);
    if (idx !== -1) {
      this.shapes[idx] = { ...this.shapes[idx], points };
      this.redrawCommitted();
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

    const idx = this.shapes.findIndex((s) => s.shape_id === shapeId);
    if (idx !== -1) {
      this.shapes.splice(idx, 1);
      this.redrawCommitted();
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
  //
  // x/y arrive as WORLD coordinates (the server/mesh never sees screen
  // space) -- converted to screen here at render time, and stored as
  // world in this.cursors so repositionCursors can re-derive the right
  // screen position whenever THIS viewer's own camera changes, with no
  // extra message from the peer needed.
  updateCursor({ peer_id, x, y, color, label }, instant) {
    const existing = this.cursors.get(peer_id);
    if (existing && !instant) this.spawnGhost(existing);

    const el = existing ? existing.el : this.createCursorEl();
    if (!this.cursorsLayer.contains(el)) this.cursorsLayer.appendChild(el);

    const screenPt = this.toScreen({ x, y });
    el.style.setProperty("--cx", screenPt.x + "px");
    el.style.setProperty("--cy", screenPt.y + "px");
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
  // x/y here are WORLD (see updateCursor's own comment); converted to
  // screen once, at spawn time -- unlike a live cursor marker, a ghost
  // is a short-lived (650ms), untracked, fire-and-forget element, so it
  // does NOT get repositioned if the camera changes while it's fading.
  spawnGhost({ x, y, color, label }) {
    const ghost = this.createCursorEl();
    ghost.classList.add("cursor-ghost");
    const screenPt = this.toScreen({ x, y });
    ghost.style.setProperty("--cx", screenPt.x + "px");
    ghost.style.setProperty("--cy", screenPt.y + "px");
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
