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

export const BoardCanvas = {
  mounted() {
    this.committed = this.el.querySelector("#board-canvas-committed");
    this.pending = this.el.querySelector("#board-canvas-pending");
    this.emptyState = document.getElementById("board-empty-state");
    this.canDraw = this.el.dataset.canDraw === "true";
    this.color = "#f2efe6";
    this.width = 3;
    this.points = [];
    this.drawing = false;
    this.shapes = []; // every confirmed stroke, kept so a resize can redraw the layer instead of losing it

    this.resize();
    window.addEventListener("resize", () => this.resize());

    this.wireToolbar();
    this.wirePointerEvents();

    this.handleEvent("shapes:snapshot", ({ shapes }) => {
      shapes.forEach((s) => this.renderCommitted(s));
      this.updateEmptyState(shapes.length > 0);
    });

    this.handleEvent("shapes:append", (stroke) => {
      this.renderCommitted(stroke);
      this.updateEmptyState(true);
    });
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
};
