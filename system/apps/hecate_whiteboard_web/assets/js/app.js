import { Socket } from "phoenix";
import { LiveSocket } from "phoenix_live_view";
import { BoardCanvas } from "./board_canvas_hook.js";

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content");

const liveSocket = new LiveSocket("/live", Socket, {
  params: { _csrf_token: csrfToken },
  hooks: { BoardCanvas },
});

liveSocket.connect();
window.liveSocket = liveSocket;
