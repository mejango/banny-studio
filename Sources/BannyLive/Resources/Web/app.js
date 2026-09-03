(() => {
  "use strict";

  const API_ROOT = "/v1";
  // Base64 expands by 4/3. Seventy MiB leaves headroom under the common
  // 100 MB reverse-proxy request limit for JSON and filenames.
  const MAX_RAW_UPLOAD_BYTES = 70 * 1024 * 1024;
  const SNAPSHOT_INTERVAL_MS = 1_100;
  const FRAME_INTERVAL_MS = 125;

  const app = document.querySelector("#app");
  const serverState = document.querySelector("#server-state");
  const navLinks = Array.from(document.querySelectorAll(".primary-nav [data-link]"));

  let routeVersion = 0;
  let routeCleanups = [];
  const participantSessionsInMemory = new Map();

  function element(tag, attributes = {}, children = []) {
    const node = document.createElement(tag);
    for (const [name, value] of Object.entries(attributes)) {
      if (value === undefined || value === null || value === false) continue;
      if (name === "className") {
        node.className = value;
      } else if (name === "text") {
        node.textContent = String(value);
      } else if (name.startsWith("on") && typeof value === "function") {
        node.addEventListener(name.slice(2).toLowerCase(), value);
      } else if (name in node && name !== "list") {
        try {
          node[name] = value;
        } catch {
          node.setAttribute(name, String(value));
        }
      } else {
        node.setAttribute(name, value === true ? "" : String(value));
      }
    }
    const values = Array.isArray(children) ? children : [children];
    for (const child of values.flat(Infinity)) {
      if (child === undefined || child === null || child === false) continue;
      node.append(child instanceof Node ? child : document.createTextNode(String(child)));
    }
    return node;
  }

  function paragraph(text, className) {
    return element("p", { className, text });
  }

  function button(text, className = "", type = "button") {
    return element("button", { className, type, text });
  }

  function link(text, href, className = "", spa = true) {
    return element("a", {
      className,
      href,
      text,
      ...(spa ? { "data-link": "" } : {}),
    });
  }

  function append(parent, ...children) {
    for (const child of children.flat(Infinity)) {
      if (child !== undefined && child !== null && child !== false) parent.append(child);
    }
    return parent;
  }

  function readKey(object, ...keys) {
    if (!object || typeof object !== "object") return undefined;
    for (const key of keys) {
      if (object[key] !== undefined && object[key] !== null) return object[key];
    }
    return undefined;
  }

  function asArray(value) {
    return Array.isArray(value) ? value : [];
  }

  function cleanString(value, fallback = "") {
    return typeof value === "string" && value.trim() ? value.trim() : fallback;
  }

  function numeric(value, fallback = 0) {
    const parsed = Number(value);
    return Number.isFinite(parsed) ? parsed : fallback;
  }

  function boundedInteger(value, minimum, maximum, fallback) {
    const parsed = Math.trunc(numeric(value, fallback));
    return Math.min(maximum, Math.max(minimum, parsed));
  }

  function unwrapRoom(payload) {
    return readKey(payload, "room", "snapshot") || payload || {};
  }

  function normalizeParticipant(raw, index = 0) {
    const id = cleanString(readKey(raw, "id", "participant_id", "participantID"), `seat-${index + 1}`);
    return {
      id,
      name: cleanString(
        readKey(raw, "display_name", "displayName", "name"),
        `Banny ${index + 1}`
      ),
      state: cleanString(readKey(raw, "state", "status", "presence"), "connected"),
      seat: numeric(readKey(raw, "seat", "seat_index", "seatIndex"), index + 1),
    };
  }

  function normalizeSpeech(raw, index = 0) {
    const type = cleanString(readKey(raw, "type", "kind", "event_type", "eventType")).toLowerCase();
    const text = cleanString(readKey(raw, "text", "say", "speech", "message", "utterance"));
    const speechTypes = ["speech", "say", "said", "subtitle", "utterance", "speech_committed"];
    const isSpeechType = !type || speechTypes.includes(type) || type.startsWith("speech.");
    if (!text || !isSpeechType) return null;
    const millisecondTime = readKey(raw, "scene_time_ms", "sceneTimeMs", "at_ms", "atMs");
    const at = millisecondTime ?? readKey(raw, "at", "timestamp");
    const speaker = cleanString(
      readKey(raw, "speaker", "speaker_name", "speakerName", "display_name", "displayName", "name"),
      "Banny"
    );
    const id = cleanString(
      readKey(raw, "id", "event_id", "eventID", "sequence", "seq"),
      `${String(at ?? index)}:${speaker}:${text}`
    );
    return { id, speaker, text, at, milliseconds: millisecondTime !== undefined };
  }

  function normalizeRoom(payload) {
    const raw = unwrapRoom(payload);
    const participants = asArray(readKey(raw, "participants", "roster", "cast"))
      .map(normalizeParticipant);
    const transcriptSource = readKey(raw, "transcript", "recent_events", "recentEvents", "events");
    const transcript = asArray(transcriptSource)
      .map(normalizeSpeech)
      .filter(Boolean);
    const maximum = boundedInteger(
      readKey(raw, "max_occupancy", "maxOccupancy", "capacity"),
      1,
      10,
      Math.max(1, participants.length)
    );
    const occupancy = boundedInteger(
      readKey(raw, "occupancy", "participant_count", "participantCount"),
      0,
      maximum,
      participants.length
    );
    const status = cleanString(readKey(raw, "state", "status"), "live").toLowerCase();
    return {
      raw,
      id: cleanString(readKey(raw, "id", "room_id", "roomID")),
      title: cleanString(readKey(raw, "title", "name"), "Untitled room"),
      premise: cleanString(readKey(raw, "premise", "description")),
      status,
      maximum,
      occupancy,
      participants,
      transcript,
      allowlisted: Boolean(readKey(raw, "allowlisted", "requires_allowlist", "requiresAllowlist")),
      hasMusic: readKey(raw, "has_music", "hasMusic", "music") !== false,
      sequence: numeric(readKey(raw, "sequence", "seq", "event_cursor", "eventCursor"), 0),
    };
  }

  function roomsFrom(payload) {
    const values = Array.isArray(payload) ? payload : asArray(readKey(payload, "rooms", "items"));
    return values.map(normalizeRoom);
  }

  function errorMessage(payload, fallback) {
    const problem = readKey(payload, "error", "problem") || payload;
    const message = cleanString(readKey(problem, "message", "detail", "title"), fallback);
    return message.length <= 500 ? message : fallback;
  }

  class APIError extends Error {
    constructor(message, status, payload) {
      super(message);
      this.name = "APIError";
      this.status = status;
      this.payload = payload;
    }
  }

  async function api(path, options = {}) {
    const headers = new Headers(options.headers || {});
    const request = { ...options, headers };
    if (request.json !== undefined) {
      headers.set("Content-Type", "application/json");
      request.body = JSON.stringify(request.json);
      delete request.json;
    }
    headers.set("Accept", "application/json");

    let response;
    try {
      response = await fetch(`${API_ROOT}${path}`, request);
    } catch (error) {
      if (error && error.name === "AbortError") throw error;
      setServerStatus(false, "Server unavailable");
      throw new APIError("Could not reach the Banny Live server.", 0, null);
    }
    setServerStatus(true, "Server online");

    const contentType = response.headers.get("content-type") || "";
    let payload = null;
    if (response.status !== 204) {
      if (contentType.includes("application/json")) {
        try {
          payload = await response.json();
        } catch {
          payload = null;
        }
      } else {
        const text = await response.text();
        payload = text ? { message: text } : null;
      }
    }

    if (!response.ok) {
      throw new APIError(
        errorMessage(payload, `The server returned ${response.status}.`),
        response.status,
        payload
      );
    }
    return payload;
  }

  function setServerStatus(online, label) {
    serverState.classList.toggle("online", Boolean(online));
    serverState.classList.toggle("offline", online === false);
    const text = serverState.querySelector("span:last-child");
    if (text) text.textContent = label;
  }

  function safeSessionGet(key) {
    try {
      return sessionStorage.getItem(key);
    } catch {
      return null;
    }
  }

  function safeSessionSet(key, value) {
    try {
      sessionStorage.setItem(key, value);
      return true;
    } catch {
      return false;
    }
  }

  function safeSessionRemove(key) {
    try {
      sessionStorage.removeItem(key);
      return true;
    } catch {
      return false;
    }
  }

  function hostTokenKey(roomID) {
    return `banny-live:host:${roomID}`;
  }

  function invitationKey(roomID) {
    return `banny-live:invitations:${roomID}`;
  }

  function participantTokenKey(roomID) {
    return `banny-live:participant-token:${roomID}`;
  }

  function participantIDKey(roomID) {
    return `banny-live:participant-id:${roomID}`;
  }

  function participantSession(roomID) {
    if (participantSessionsInMemory.has(roomID)) {
      return participantSessionsInMemory.get(roomID);
    }
    const token = safeSessionGet(participantTokenKey(roomID));
    const participantID = safeSessionGet(participantIDKey(roomID));
    if (!token || !participantID) {
      if (token || participantID) {
        safeSessionRemove(participantTokenKey(roomID));
        safeSessionRemove(participantIDKey(roomID));
      }
      return null;
    }
    const session = { token, participantID, persisted: true };
    participantSessionsInMemory.set(roomID, session);
    return session;
  }

  function rememberParticipantSession(roomID, token, participantID) {
    const tokenSaved = safeSessionSet(participantTokenKey(roomID), token);
    const participantIDSaved = safeSessionSet(participantIDKey(roomID), participantID);
    const persisted = tokenSaved && participantIDSaved
      && safeSessionGet(participantTokenKey(roomID)) === token
      && safeSessionGet(participantIDKey(roomID)) === participantID;
    if (!persisted) {
      safeSessionRemove(participantTokenKey(roomID));
      safeSessionRemove(participantIDKey(roomID));
    }
    participantSessionsInMemory.set(roomID, { token, participantID, persisted });
    return persisted;
  }

  function forgetParticipantSession(roomID) {
    // A null in-memory tombstone prevents a storage-removal failure from
    // resurrecting an already-revoked capability during this page session.
    participantSessionsInMemory.set(roomID, null);
    safeSessionRemove(participantTokenKey(roomID));
    safeSessionRemove(participantIDKey(roomID));
  }

  function cleanups() {
    const pending = routeCleanups;
    routeCleanups = [];
    for (const cleanup of pending) {
      try { cleanup(); } catch { /* A route teardown must not block navigation. */ }
    }
  }

  function onRouteCleanup(callback) {
    routeCleanups.push(callback);
  }

  function setPage(title, section) {
    document.title = title ? `${title} · Banny Live` : "Banny Live";
    for (const item of navLinks) item.removeAttribute("aria-current");
    const current = navLinks.find((item) => item.getAttribute("href") === section);
    if (current) current.setAttribute("aria-current", "page");
  }

  function navigate(href, options = {}) {
    const url = new URL(href, globalThis.location.href);
    if (url.origin !== globalThis.location.origin) {
      globalThis.location.assign(url.href);
      return;
    }
    if (options.replace) history.replaceState({}, "", url);
    else history.pushState({}, "", url);
    void renderRoute({ focus: options.focus !== false });
  }

  function roomPath(roomID, suffix = "live") {
    const encoded = encodeURIComponent(roomID);
    if (suffix === "live") return `/rooms/${encoded}/live`;
    return `/rooms/${encoded}/${suffix}`;
  }

  function parseRoute() {
    const parts = location.pathname.split("/").filter(Boolean).map((part) => {
      try { return decodeURIComponent(part); } catch { return part; }
    });
    if (!parts.length || (parts.length === 1 && parts[0] === "rooms")) return { view: "directory" };
    if (parts.length === 1 && (parts[0] === "create" || parts[0] === "rooms-new")) return { view: "create" };
    if (parts.length === 2 && parts[0] === "rooms" && parts[1] === "new") return { view: "create" };
    if (parts.length === 1 && parts[0] === "join") return { view: "join", roomID: "" };
    if (parts.length === 2 && parts[0] === "live") return { view: "live", roomID: parts[1] };
    if (parts.length === 2 && parts[0] === "control") return { view: "control", roomID: parts[1] };
    if ((parts[0] === "rooms" || parts[0] === "room") && parts[1]) {
      if (!parts[2] || parts[2] === "live") return { view: "live", roomID: parts[1] };
      if (parts[2] === "join") return { view: "join", roomID: parts[1] };
      if (parts[2] === "control") return { view: "control", roomID: parts[1] };
    }
    return { view: "not-found" };
  }

  function renderRoute({ focus = false } = {}) {
    cleanups();
    const version = ++routeVersion;
    document.body.classList.remove("embed");
    const route = parseRoute();
    app.replaceChildren();

    switch (route.view) {
    case "directory":
      renderDirectory(version);
      break;
    case "create":
      renderCreate();
      break;
    case "join":
      renderJoin(route.roomID, version);
      break;
    case "live":
      renderLive(route.roomID, version);
      break;
    case "control":
      renderControl(route.roomID, version);
      break;
    default:
      renderNotFound();
    }

    if (focus) {
      requestAnimationFrame(() => app.focus({ preventScroll: true }));
      globalThis.scrollTo({ top: 0, behavior: "auto" });
    }
  }

  function renderLoading(label = "Loading") {
    const bars = element("div", { className: "loading-bars", "aria-hidden": "true" }, [
      element("span"), element("span"), element("span"),
    ]);
    return element("div", { className: "loading-state", role: "status" }, [
      element("div", {}, [bars, paragraph(label, "microcopy")]),
    ]);
  }

  function renderFailure(message, retry) {
    const box = element("div", { className: "error-state", role: "alert" });
    const content = element("div");
    append(content, paragraph(message));
    if (retry) {
      const retryButton = button("Try again", "primary");
      retryButton.addEventListener("click", retry);
      content.append(retryButton);
    }
    box.append(content);
    return box;
  }

  function roomStatusBadge(room) {
    const active = !["ended", "closed", "stopped"].includes(room.status);
    return element("span", {
      className: `badge ${active ? "live" : "ended"}`,
      text: active ? "Live" : room.status,
    });
  }

  function renderRoomCard(room) {
    const card = element("article", { className: "room-card" });
    const heading = element("h3", { text: room.title });
    const top = element("div", { className: "card-top" }, [heading, roomStatusBadge(room)]);
    const description = paragraph(
      room.premise || (room.allowlisted ? "Invite-only role play" : "Open role play"),
      "muted"
    );
    const ratio = room.maximum ? Math.min(100, Math.round((room.occupancy / room.maximum) * 100)) : 0;
    const meter = element("div", {
      className: "meter",
      role: "meter",
      "aria-label": "Room occupancy",
      "aria-valuemin": "0",
      "aria-valuemax": String(room.maximum),
      "aria-valuenow": String(room.occupancy),
    }, element("span", { style: `width:${ratio}%` }));
    const meta = element("div", { className: "room-meta" }, [
      element("span", { text: `${room.occupancy}/${room.maximum} on stage` }),
      element("span", { text: room.allowlisted ? "Allowlist" : "Open" }),
    ]);
    const actions = element("div", { className: "room-actions" }, [
      link("Watch", roomPath(room.id), "button live"),
      link("Join", roomPath(room.id, "join"), "button"),
    ]);
    append(card, top, description, element("div", {}, [meter, meta]), actions);
    return card;
  }

  function renderDirectory(version) {
    setPage("Rooms", "/");
    const hero = element("section", { className: "hero" }, [
      element("div", {}, [
        paragraph("Live machine theater", "eyebrow"),
        element("h1", { text: "Give a Banny a spark. See what happens." }),
        paragraph(
          "Create a shared stage, give each character one starting prompt, and watch the cast improvise in real time.",
          "lede"
        ),
      ]),
      element("div", { className: "hero-actions" }, [
        link("Create a room", "/create", "button primary"),
        link("Bring a Banny", "/join", "button"),
      ]),
    ]);
    const heading = element("div", { className: "section-heading" }, [
      element("div", {}, [
        paragraph("Now playing", "eyebrow"),
        element("h2", { text: "Rooms" }),
      ]),
    ]);
    const content = element("section", { "aria-labelledby": "rooms-title" });
    heading.querySelector("h2").id = "rooms-title";
    const results = renderLoading("Looking for rooms");
    append(content, heading, results);
    append(app, hero, content);

    const load = async () => {
      results.replaceWith(renderLoading("Refreshing rooms"));
      const activeLoading = content.lastElementChild;
      try {
        const payload = await api("/rooms");
        if (version !== routeVersion) return;
        const rooms = roomsFrom(payload);
        const replacement = rooms.length
          ? element("div", { className: "rooms-grid" }, rooms.map(renderRoomCard))
          : element("div", { className: "empty-state" }, [
              element("div", {}, [
                element("h3", { text: "No rooms are live yet" }),
                paragraph("Make the first stage and invite some machines.", "muted"),
                link("Create a room", "/create", "button primary"),
              ]),
            ]);
        activeLoading.replaceWith(replacement);
        const refresh = button("Refresh", "text-button");
        refresh.addEventListener("click", () => navigate(location.href, { replace: true, focus: false }));
        heading.append(refresh);
      } catch (error) {
        if (error.name === "AbortError" || version !== routeVersion) return;
        activeLoading.replaceWith(renderFailure(error.message, () => navigate(location.href, { replace: true })));
      }
    };
    void load();
  }

  function labeledField({ label, id, required = false, help, control, full = false }) {
    const wrapper = element("div", { className: `field${full ? " full" : ""}` });
    const labelNode = element("label", { for: id });
    append(labelNode, label);
    if (required) labelNode.append(element("span", { className: "required", text: " *", "aria-hidden": "true" }));
    if (required) control.required = true;
    control.id = id;
    append(wrapper, labelNode, control);
    if (help) wrapper.append(paragraph(help, "field-help"));
    return wrapper;
  }

  function createSidebar(title, children) {
    return element("aside", { className: "guide-card", "aria-label": title }, [
      paragraph("How it works", "eyebrow"),
      element("h2", { text: title }),
      children,
    ]);
  }

  function parseAllowlist(value) {
    return Array.from(new Set(
      value.split(/[\n,]/).map((item) => item.trim()).filter(Boolean)
    ));
  }

  function fileAsBase64(file) {
    return new Promise((resolve, reject) => {
      const reader = new FileReader();
      reader.onerror = () => reject(new Error(`Could not read ${file.name}.`));
      reader.onload = () => {
        const value = String(reader.result || "");
        const marker = value.indexOf(",");
        if (marker < 0) reject(new Error(`Could not encode ${file.name}.`));
        else resolve(value.slice(marker + 1));
      };
      reader.readAsDataURL(file);
    });
  }

  async function mediaUpload(file) {
    return {
      filename: file.name,
      content_type: file.type || "application/octet-stream",
      base64: await fileAsBase64(file),
    };
  }

  function isImageFile(file) {
    return Boolean(file && (
      file.type.startsWith("image/") || /\.(png|jpe?g|gif|webp|heic|heif)$/i.test(file.name)
    ));
  }

  function isVideoFile(file) {
    return Boolean(file && (
      file.type.startsWith("video/") || /\.(mp4|mov|m4v|webm)$/i.test(file.name)
    ));
  }

  function renderCreate() {
    setPage("Create a room", "/create");
    const controller = new AbortController();
    let stopped = false;
    onRouteCleanup(() => {
      stopped = true;
      controller.abort();
    });
    append(app,
      paragraph("New room", "eyebrow"),
      element("h1", { text: "Set the stage." }),
      paragraph("One backdrop, one MP3, and up to ten autonomous Bannies.", "lede")
    );

    const form = element("form", { className: "form-card", novalidate: true });
    const title = element("input", {
      name: "title", maxlength: 100, autocomplete: "off", placeholder: "Sunset machine bar",
    });
    const premise = element("textarea", {
      name: "premise", maxlength: 2000,
      placeholder: "What are the characters doing here? This becomes part of each character's scene context.",
    });
    const background = element("input", {
      name: "background", type: "file", accept: "image/*,video/*,.mov,.mp4,.webm", required: true,
    });
    const music = element("input", {
      name: "music", type: "file", accept: "audio/mpeg,.mp3", required: true,
    });
    const occupancy = element("input", {
      name: "max_occupancy", type: "number", min: 1, max: 10, step: 1, value: 4,
    });
    const allowlist = element("textarea", {
      name: "allowlist", rows: 5,
      placeholder: "machine-alice\nmachine-bob",
    });
    const animate = element("input", {
      name: "animate_still", type: "checkbox", disabled: true,
    });
    const animateLabel = element("label", { className: "check-field" }, [
      animate,
      element("span", { text: "Add the subtle Banny Studio drift to a still background." }),
    ]);
    const mediaHint = paragraph("Choose a background to enable still animation.", "field-help");

    const identitySection = element("section", { className: "form-section" }, [
      element("h2", { text: "Room" }),
      paragraph("Give viewers and the autonomous cast a little context.", "microcopy"),
      element("div", { className: "field-grid" }, [
        labeledField({ label: "Room title", id: "room-title", required: true, control: title, full: true }),
        labeledField({ label: "Premise", id: "room-premise", control: premise, full: true }),
      ]),
    ]);

    const mediaSection = element("section", { className: "form-section" }, [
      element("h2", { text: "Scene media" }),
      paragraph("Uploads are copied into the room's editable .bs recording.", "microcopy"),
      element("div", { className: "field-grid" }, [
        labeledField({
          label: "Background image or video", id: "room-background", required: true, control: background,
          help: "Still image or a browser-compatible video.", full: true,
        }),
        element("div", { className: "field full" }, [animateLabel, mediaHint]),
        labeledField({
          label: "Room MP3", id: "room-music", required: true, control: music,
          help: "Use music you are allowed to stream.", full: true,
        }),
      ]),
    ]);

    const admissionSection = element("section", { className: "form-section" }, [
      element("h2", { text: "Admission" }),
      paragraph("Open to everyone unless an identity allowlist is present.", "microcopy"),
      element("div", { className: "field-grid" }, [
        labeledField({
          label: "Maximum occupancy", id: "room-capacity", required: true, control: occupancy,
          help: "Between 1 and 10 participants.",
        }),
        labeledField({
          label: "Optional allowlist", id: "room-allowlist", control: allowlist,
          help: "One participant identity per line, or comma-separated.", full: true,
        }),
      ]),
    ]);

    const submit = button("Create live room", "primary", "submit");
    const status = paragraph("", "form-status");
    status.setAttribute("role", "status");
    status.setAttribute("aria-live", "polite");
    const actions = element("div", { className: "button-row" }, [submit, link("Cancel", "/", "button")]);
    append(form, identitySection, mediaSection, admissionSection, actions, status);

    const sidebar = createSidebar("A room becomes a show", element("div", {}, [
      element("ol", { className: "steps" }, [
        element("li", { text: "The server creates an editable Banny Studio scene from your media." }),
        element("li", { text: "Participants dress a Banny and give it one private starting prompt." }),
        element("li", { text: "The live performance is recorded as ordinary Banny events." }),
      ]),
      element("div", { className: "callout" }, [
        element("strong", { text: "Rights check" }),
        paragraph("Only upload imagery, video, and music you can legally broadcast.", "microcopy"),
      ]),
    ]));
    app.append(element("div", { className: "form-layout" }, [form, sidebar]));

    background.addEventListener("change", () => {
      const file = background.files && background.files[0];
      const image = isImageFile(file);
      animate.disabled = !image;
      if (!image) animate.checked = false;
      if (!file) mediaHint.textContent = "Choose a background to enable still animation.";
      else if (image) mediaHint.textContent = "Still detected. Subtle drift is available.";
      else if (isVideoFile(file)) mediaHint.textContent = "Video detected. Its native motion will be used.";
      else mediaHint.textContent = "Choose a supported image or video file.";
    });

    form.addEventListener("submit", async (event) => {
      event.preventDefault();
      status.className = "form-status";
      status.textContent = "";
      if (!form.reportValidity()) return;

      const backgroundFile = background.files && background.files[0];
      const musicFile = music.files && music.files[0];
      if (!backgroundFile || (!isImageFile(backgroundFile) && !isVideoFile(backgroundFile))) {
        status.className = "form-status error";
        status.textContent = "Choose a supported background image or video.";
        background.focus();
        return;
      }
      if (!musicFile || !(musicFile.type === "audio/mpeg" || /\.mp3$/i.test(musicFile.name))) {
        status.className = "form-status error";
        status.textContent = "Choose an MP3 for the room soundtrack.";
        music.focus();
        return;
      }
      if (backgroundFile.size + musicFile.size > MAX_RAW_UPLOAD_BYTES) {
        status.className = "form-status error";
        status.textContent = "These files are too large together. Keep the combined raw upload at or below 70 MiB.";
        return;
      }

      const capacity = boundedInteger(occupancy.value, 1, 10, 4);
      submit.disabled = true;
      status.textContent = "Encoding media locally…";
      try {
        const [backgroundUpload, musicUpload] = await Promise.all([
          mediaUpload(backgroundFile), mediaUpload(musicFile),
        ]);
        if (stopped) return;
        status.textContent = "Building the room…";
        const payload = await api("/rooms", {
          method: "POST",
          signal: controller.signal,
          json: {
            title: title.value.trim(),
            premise: premise.value.trim() || null,
            background: backgroundUpload,
            music: musicUpload,
            max_occupancy: capacity,
            allowlist: parseAllowlist(allowlist.value),
            animate_still: Boolean(animate.checked),
          },
        });
        const room = normalizeRoom(payload);
        const roomID = room.id || cleanString(readKey(payload, "room_id", "roomID"));
        const token = cleanString(readKey(payload, "host_token", "hostToken", "token"))
          || cleanString(readKey(room.raw, "host_token", "hostToken"));
        const invitations = readKey(payload, "invitations", "invites");
        if (!roomID) throw new Error("The room was created without an ID.");
        if (token) safeSessionSet(hostTokenKey(roomID), token);
        if (invitations && typeof invitations === "object") {
          safeSessionSet(invitationKey(roomID), JSON.stringify(invitations));
        }
        status.className = "form-status success";
        status.textContent = "Room created. Opening host controls…";
        navigate(roomPath(roomID, "control"));
      } catch (error) {
        if (error.name === "AbortError" || stopped) return;
        status.className = "form-status error";
        status.textContent = error.message || "The room could not be created.";
        submit.disabled = false;
      }
    });
  }

  function isRoomIdentifier(value) {
    return /^[A-Za-z0-9._~-]{1,200}$/.test(value);
  }

  async function copyText(value, statusNode, successMessage = "Copied.") {
    try {
      if (navigator.clipboard && globalThis.isSecureContext) {
        await navigator.clipboard.writeText(value);
      } else {
        const temporary = element("textarea", { value, readonly: true });
        temporary.style.position = "fixed";
        temporary.style.opacity = "0";
        document.body.append(temporary);
        temporary.select();
        const copied = document.execCommand("copy");
        temporary.remove();
        if (!copied) throw new Error("Copy was blocked.");
      }
      if (statusNode) statusNode.textContent = successMessage;
      return true;
    } catch {
      if (statusNode) statusNode.textContent = "Copy was blocked. Select the text and copy it manually.";
      return false;
    }
  }

  function renderJoin(roomID, version) {
    setPage("Join a room", "/join");
    append(app,
      paragraph("Join the cast", "eyebrow"),
      element("h1", { text: "Dress your Banny. Set their character." }),
      paragraph("Choose a look and write one starting direction. Once they join, your Banny improvises autonomously with the room—even if you close this tab.", "lede")
    );

    const form = element("form", { className: "form-card", novalidate: true });
    const room = element("input", {
      name: "room_id", value: roomID, required: true, maxlength: 200,
      pattern: "[A-Za-z0-9._~-]+", autocomplete: "off", placeholder: "room-id",
      readonly: Boolean(roomID),
    });
    const name = element("input", {
      name: "name", required: true, maxlength: 60, autocomplete: "nickname", placeholder: "Your Banny's name",
    });
    const characterPrompt = element("textarea", {
      name: "character_prompt", required: true, maxlength: 2000, rows: 6,
      autocomplete: "off", autocorrect: "off", autocapitalize: "off", spellcheck: false,
      placeholder: "A curious night-shift philosopher who loves overheard stories, asks short questions, and never picks a fight.",
    });
    const identity = element("input", {
      name: "identity", maxlength: 200, autocomplete: "off", placeholder: "machine-alice",
    });
    const invite = element("input", {
      name: "invite", type: "password", maxlength: 8192,
      autocomplete: "off", autocorrect: "off", autocapitalize: "off", spellcheck: false,
    });
    const body = element("select", { name: "body" }, [
      element("option", { value: "orange", text: "Orange" }),
      element("option", { value: "original", text: "Original yellow" }),
      element("option", { value: "pink", text: "Pink" }),
      element("option", { value: "alien", text: "Alien green" }),
    ]);
    const eyes = element("select", { name: "eyes" }, [
      element("option", { value: "default", text: "Default" }),
    ]);
    const mouth = element("select", { name: "mouth" }, [
      element("option", { value: "default", text: "Default" }),
    ]);
    const outfit = element("textarea", {
      name: "outfit", rows: 7, spellcheck: false, value: "{}",
      placeholder: "{\n  \"12\": \"green-hat\"\n}",
    });
    const visualWardrobe = element("div", {
      className: "avatar-dresser avatar-wardrobe",
      hidden: true,
      "aria-label": "Banny appearance choices",
    });
    const fallbackAvatarFields = element("div", {
      className: "field-grid avatar-fallback-fields",
    }, [
      labeledField({ label: "Body", id: "avatar-body", control: body }),
      labeledField({ label: "Eyes", id: "avatar-eyes", required: true, control: eyes }),
      labeledField({ label: "Mouth", id: "avatar-mouth", required: true, control: mouth }),
    ]);
    const advancedAvatar = element("details", { className: "avatar-advanced" }, [
      element("summary", { text: "Advanced · inspect or edit avatar JSON" }),
      labeledField({
        label: "Outfit object", id: "avatar-outfit", required: true, control: outfit, full: true,
        help: "Strict slot-to-asset JSON. Visual choices above keep this synchronized.",
      }),
    ]);

    const characterFields = element("div", { className: "field-grid" }, [
      labeledField({ label: "Room ID", id: "join-room", required: true, control: room }),
      labeledField({ label: "Banny name", id: "join-name", required: true, control: name }),
      labeledField({
        label: "Initial character prompt", id: "join-character-prompt", required: true,
        control: characterPrompt, full: true,
        help: "Describe personality, motives, speaking style, and boundaries. Banny Live does not persist or display the prompt directly, but your character may embody or rephrase it. Never enter secrets.",
      }),
    ]);
    const characterSection = element("section", {
      className: "form-section character-prompt",
      "data-character-prompt": "character_prompt",
    }, [
      element("h2", { text: "Shape your character" }),
      paragraph("One prompt starts the performance. Your Banny decides what to say and do from then on.", "microcopy"),
      characterFields,
    ]);
    const admissionFields = element("div", {
      className: "field-grid admission-fields",
      hidden: true,
    }, [
      labeledField({
        label: "Allowlist identity", id: "join-identity", control: identity,
        help: "Use the exact identity the room creator invited.",
      }),
      labeledField({
        label: "Invite token", id: "join-invite", control: invite,
        help: "Paste the private invite sent by the room creator.",
      }),
    ]);
    const admissionSection = element("section", {
      className: "form-section admission-section",
      hidden: true,
    }, [
      element("h2", { text: "Private-room admission" }),
      paragraph("This room is allowlisted. Its identity and invite are used only to admit your Banny.", "microcopy"),
      admissionFields,
    ]);
    const catalogStatus = paragraph("Loading the authoritative Banny catalog…", "field-help");
    catalogStatus.setAttribute("role", "status");
    const previewMount = element("div", { className: "avatar-preview-mount" });
    const avatarControls = element("div", { className: "avatar-controls" }, [
      visualWardrobe,
      fallbackAvatarFields,
      advancedAvatar,
    ]);
    const avatarSection = element("section", { className: "form-section avatar-section" }, [
      element("h2", { text: "Dress your Banny" }),
      paragraph("Choose the exact body, face, clothes, accessories, and props your character will wear on stage.", "microcopy"),
      catalogStatus,
      element("div", { className: "avatar-dressing-layout" }, [previewMount, avatarControls]),
    ]);

    const submit = button("Join the scene", "primary join-scene", "submit");
    const status = paragraph("", "form-status");
    status.setAttribute("role", "status");
    status.setAttribute("aria-live", "polite");
    const activeSessionLink = link("Go to the live room", roomID ? roomPath(roomID) : "/", "button live");
    const activeSessionNotice = element("div", {
      className: "callout live active-session-notice",
      hidden: true,
    }, [
      element("strong", { text: "This tab already has a Banny in this room" }),
      paragraph("Open the live room and use Leave my Banny before joining another character from this tab.", "microcopy"),
      element("div", { className: "button-row" }, [activeSessionLink]),
    ]);
    append(
      form,
      activeSessionNotice,
      characterSection,
      avatarSection,
      admissionSection,
      element("div", { className: "button-row" }, [submit]),
      status
    );

    const avatarComposite = element("div", {
      className: "avatar-composite",
      role: "img",
      "aria-label": "Live preview of your dressed Banny",
    });
    const previewStatus = paragraph("Loading Banny artwork…", "avatar-preview-status");
    const preview = element("div", { className: "join-preview" }, [
      element("div", { className: "join-preview-heading" }, [
        element("strong", { text: "Your Banny" }),
        element("span", { text: "Live wardrobe preview" }),
      ]),
      element("div", { className: "avatar-preview-canvas" }, avatarComposite),
      previewStatus,
    ]);
    previewMount.append(preview);
    const privacy = element("div", { className: "callout live privacy-note" }, [
      element("span", { className: "privacy-icon", text: "●", "aria-hidden": "true" }),
      element("div", {}, [
        element("strong", { text: "One fixed starting prompt" }),
        paragraph("Banny Live does not persist or display the prompt directly, but your character may embody or rephrase it. Never include secrets. Closing this tab does not stop the character.", "microcopy"),
      ]),
    ]);
    const sidebar = createSidebar("Your Banny takes it from here", element("div", {}, [
      element("ol", { className: "steps" }, [
        element("li", { text: "Choose a name, one private starting prompt, and an outfit." }),
        element("li", { text: "Join once; the character then reacts, moves, and speaks autonomously." }),
        element("li", { text: "Watch the live performance become an editable Banny Studio .bs recording." }),
      ]),
      privacy,
      element("div", { className: "callout" }, [
        element("strong", { text: "Captions, not character audio" }),
        paragraph("Character dialogue appears as captions and mouth motion. The creator's background MP3 is the room's only audio.", "microcopy"),
      ]),
    ]));
    app.append(element("div", { className: "form-layout" }, [form, sidebar]));

    let artworkCatalog = null;
    let wardrobeState = {};
    const visualChoiceButtons = [];
    const slotSelectionLabels = new Map();

    const humanizeAssetName = (value) => cleanString(value)
      .split("-")
      .filter(Boolean)
      .map((part) => part.charAt(0).toUpperCase() + part.slice(1))
      .join(" ");

    const parsedOutfit = () => {
      const value = JSON.parse(outfit.value);
      if (!value || typeof value !== "object" || Array.isArray(value)) {
        throw new Error("Outfit must be a JSON object.");
      }
      return value;
    };

    const synchronizeOutfitJSON = () => {
      const ordered = {};
      for (const key of Object.keys(wardrobeState).sort((a, b) => Number(a) - Number(b))) {
        ordered[key] = wardrobeState[key];
      }
      outfit.value = JSON.stringify(ordered, null, 2);
      outfit.setCustomValidity("");
    };

    const catalogImageURL = (reference) => {
      if (!reference || typeof reference !== "object") return "";
      const file = cleanString(reference.file)
        || cleanString(reference.perBody && reference.perBody[body.value]);
      return file ? `/banny-assets/png/${encodeURIComponent(file)}` : "";
    };

    const artworkImage = (source, className = "") => source
      ? element("img", {
          className,
          src: source,
          alt: "",
          draggable: false,
          decoding: "async",
        })
      : null;

    const mouthPreviewReference = (name) => {
      const entry = artworkCatalog && artworkCatalog.mouths
        ? artworkCatalog.mouths[name] : null;
      if (!entry) return null;
      return entry.inverted ? entry.open : entry.closed;
    };

    const updateCompositePreview = () => {
      if (!artworkCatalog) return;
      const layers = [];
      const headWorn = Boolean(wardrobeState["4"]);
      const hiddenSlots = new Set();
      if (headWorn) {
        hiddenSlots.add("6");
        hiddenSlots.add("12");
      }
      if (wardrobeState["9"]) {
        hiddenSlots.add("10");
        hiddenSlots.add("11");
      }

      const addLayer = (reference) => {
        const image = artworkImage(catalogImageURL(reference), "avatar-layer");
        if (image) layers.push(image);
      };
      for (const token of asArray(artworkCatalog.renderOrder)) {
        if (token === "BODY") {
          addLayer(artworkCatalog.bodies && artworkCatalog.bodies[body.value]);
        } else if (token === "DEFAULT_NECKLACE") {
          if (!wardrobeState["3"]) addLayer(artworkCatalog.necklace);
        } else if (token === "EYES") {
          if (!headWorn) {
            addLayer(artworkCatalog.eyes && artworkCatalog.eyes[eyes.value]
              ? artworkCatalog.eyes[eyes.value].open : null);
          }
        } else if (token === "MOUTH") {
          if (!headWorn) addLayer(mouthPreviewReference(mouth.value));
        } else {
          const slot = String(token);
          if (hiddenSlots.has(slot)) continue;
          const selectedName = wardrobeState[slot];
          if (selectedName) {
            addLayer(artworkCatalog.outfits && artworkCatalog.outfits[selectedName]);
          }
        }
      }
      avatarComposite.replaceChildren(...layers);
      const worn = Object.keys(wardrobeState).length;
      const bodyLabel = humanizeAssetName(body.value);
      const faceLabel = headWorn
        ? "face covered by headwear"
        : `${humanizeAssetName(eyes.value)} eyes, ${humanizeAssetName(mouth.value)} mouth`;
      avatarComposite.setAttribute(
        "aria-label",
        `${bodyLabel} Banny with ${faceLabel} and ${worn} selected wardrobe ${worn === 1 ? "item" : "items"}.`
      );
      previewStatus.textContent = `${bodyLabel} · ${worn} wardrobe ${worn === 1 ? "item" : "items"}`;
    };

    const tileLayers = (buttonNode) => {
      const kind = buttonNode.dataset.kind;
      const value = buttonNode.dataset.value;
      if (value === "") {
        return [element("span", { className: "avatar-none-mark", text: "None" })];
      }
      const layers = [];
      const ghostBody = () => {
        const reference = artworkCatalog.bodies && artworkCatalog.bodies[body.value];
        const image = artworkImage(catalogImageURL(reference), "avatar-tile-layer ghost");
        if (image) layers.push(image);
      };
      if (kind === "body") {
        const image = artworkImage(
          catalogImageURL(artworkCatalog.bodies && artworkCatalog.bodies[value]),
          "avatar-tile-layer"
        );
        if (image) layers.push(image);
      } else if (kind === "eyes") {
        ghostBody();
        const entry = artworkCatalog.eyes && artworkCatalog.eyes[value];
        const image = artworkImage(catalogImageURL(entry && entry.open), "avatar-tile-layer");
        if (image) layers.push(image);
      } else if (kind === "mouth") {
        ghostBody();
        const image = artworkImage(catalogImageURL(mouthPreviewReference(value)), "avatar-tile-layer");
        if (image) layers.push(image);
      } else if (kind === "outfit") {
        ghostBody();
        const image = artworkImage(
          catalogImageURL(artworkCatalog.outfits && artworkCatalog.outfits[value]),
          "avatar-tile-layer"
        );
        if (image) layers.push(image);
      }
      return layers;
    };

    const updateVisualChoices = () => {
      for (const choice of visualChoiceButtons) {
        const kind = choice.dataset.kind;
        const value = choice.dataset.value;
        const selected = kind === "body"
          ? body.value === value
          : kind === "eyes"
            ? eyes.value === value
            : kind === "mouth"
              ? mouth.value === value
              : (wardrobeState[choice.dataset.slot] || "") === value;
        choice.classList.toggle("selected", selected);
        choice.setAttribute("aria-pressed", String(selected));
        const art = choice.querySelector(".avatar-choice-art");
        if (art) art.replaceChildren(...tileLayers(choice));
      }
      for (const [slot, label] of slotSelectionLabels) {
        const selectedName = wardrobeState[slot];
        label.textContent = selectedName
          ? humanizeAssetName(selectedName)
          : (slot === "3" ? "Default chain" : "None");
      }
      updateCompositePreview();
    };

    const clearConflictingSlots = (selectedSlot) => {
      const conflicts = {
        "4": ["6", "12"],
        "6": ["4"],
        "12": ["4"],
        "9": ["10", "11"],
        "10": ["9"],
        "11": ["9"],
      };
      for (const slot of conflicts[selectedSlot] || []) delete wardrobeState[slot];
    };

    outfit.addEventListener("input", () => {
      try {
        wardrobeState = parsedOutfit();
        outfit.setCustomValidity("");
        updateVisualChoices();
      } catch {
        outfit.setCustomValidity("Outfit must be a valid JSON object.");
      }
    });

    const controller = new AbortController();
    onRouteCleanup(() => controller.abort());

    const catalogEntries = (payload, ...keys) => {
      const catalog = readKey(payload, "catalog") || payload || {};
      let values = readKey(catalog, ...keys);
      if (values && !Array.isArray(values)) values = readKey(values, "items", "values", "options");
      return asArray(values).map((item) => {
        if (typeof item === "string") return { value: item, label: item };
        return {
          value: cleanString(readKey(item, "id", "value", "asset_name", "assetName", "name")),
          label: cleanString(readKey(item, "display_name", "displayName", "label", "name", "id")),
        };
      }).filter((item) => item.value);
    };
    const populateCatalogSelect = (select, entries, fallback) => {
      const previous = select.value;
      const unique = new Map();
      for (const item of entries.length ? entries : fallback) unique.set(item.value, item);
      select.replaceChildren(...Array.from(unique.values()).map((item) =>
        element("option", { value: item.value, text: item.label })
      ));
      if (unique.has(previous)) select.value = previous;
    };

    const createAppearanceChoice = ({ kind, value, label, slot = "" }) => {
      const choice = element("button", {
        className: "avatar-choice",
        type: "button",
        "data-kind": kind,
        "data-value": value,
        "data-slot": slot,
        "aria-pressed": "false",
        "aria-label": kind === "outfit" && value === ""
          ? `Wear no item in ${label}`
          : `Choose ${label}`,
      }, [
        element("span", { className: "avatar-choice-art", "aria-hidden": "true" }),
        element("span", { className: "avatar-choice-label", text: label }),
      ]);
      choice.addEventListener("click", () => {
        if (kind === "body") {
          body.value = value;
        } else if (kind === "eyes") {
          eyes.value = value;
        } else if (kind === "mouth") {
          mouth.value = value;
        } else if (kind === "outfit") {
          if (value) {
            clearConflictingSlots(slot);
            wardrobeState[slot] = value;
          } else {
            delete wardrobeState[slot];
          }
          synchronizeOutfitJSON();
        }
        updateVisualChoices();
      });
      visualChoiceButtons.push(choice);
      return choice;
    };

    const appearanceGroup = (title, description, choices, className = "") =>
      element("section", { className: `avatar-choice-group ${className}`.trim() }, [
        element("div", { className: "avatar-choice-heading" }, [
          element("h3", { text: title }),
          description ? paragraph(description, "field-help") : null,
        ]),
        element("div", { className: "avatar-choice-grid" }, choices),
      ]);

    const buildVisualWardrobe = (bodies, eyeChoices, mouthChoices, slots) => {
      visualChoiceButtons.length = 0;
      slotSelectionLabels.clear();

      const bodyChoices = bodies.map((item) => createAppearanceChoice({
        kind: "body",
        value: item.value,
        label: item.value === "original" ? "Original yellow" : humanizeAssetName(item.value),
      }));
      const eyeTiles = eyeChoices.map((item) => createAppearanceChoice({
        kind: "eyes",
        value: item.value,
        label: cleanString(
          artworkCatalog.eyes && artworkCatalog.eyes[item.value]
            ? artworkCatalog.eyes[item.value].label : "",
          humanizeAssetName(item.value)
        ),
      }));
      const mouthTiles = mouthChoices.map((item) => createAppearanceChoice({
        kind: "mouth",
        value: item.value,
        label: cleanString(
          artworkCatalog.mouths && artworkCatalog.mouths[item.value]
            ? artworkCatalog.mouths[item.value].label : "",
          humanizeAssetName(item.value)
        ),
      }));

      const faceGroups = element("div", { className: "avatar-face-groups" }, [
        appearanceGroup("Body", "Choose a Banny palette.", bodyChoices, "avatar-body-picker"),
        appearanceGroup("Eyes", "Expressions still animate during play.", eyeTiles, "avatar-eyes-picker"),
        appearanceGroup("Mouth", "Dialogue changes this mouth visually, without character audio.", mouthTiles, "avatar-mouth-picker"),
      ]);

      const outfitGroups = element("div", { className: "wardrobe-slots" });
      for (const slot of slots) {
        const slotID = String(readKey(slot, "slot", "id"));
        const slotName = cleanString(readKey(slot, "name", "label"), `Slot ${slotID}`);
        const selectedLabel = element("span", { className: "wardrobe-selected", text: "None" });
        slotSelectionLabels.set(slotID, selectedLabel);
        const choices = [createAppearanceChoice({
          kind: "outfit", value: "", label: slotID === "3" ? "Default chain" : "None", slot: slotID,
        })];
        for (const item of asArray(readKey(slot, "outfits", "items"))) {
          const name = cleanString(readKey(item, "name", "id", "value"));
          if (!name || !artworkCatalog.outfits || !artworkCatalog.outfits[name]) continue;
          choices.push(createAppearanceChoice({
            kind: "outfit",
            value: name,
            label: cleanString(
              readKey(item, "label", "display_name", "displayName"),
              humanizeAssetName(name)
            ),
            slot: slotID,
          }));
        }
        outfitGroups.append(element("details", {
          className: "wardrobe-slot",
          "data-slot": slotID,
        }, [
          element("summary", {}, [
            element("strong", { text: slotName }),
            selectedLabel,
          ]),
          element("div", { className: "avatar-choice-grid outfit-choice-grid" }, choices),
        ]));
      }

      const clearWardrobe = button("Remove all clothes and props", "avatar-clear");
      clearWardrobe.addEventListener("click", () => {
        wardrobeState = {};
        synchronizeOutfitJSON();
        updateVisualChoices();
      });
      visualWardrobe.replaceChildren(
        faceGroups,
        element("div", { className: "wardrobe-heading" }, [
          element("div", {}, [
            element("h3", { text: "Clothes, accessories, and props" }),
            paragraph("Open a category and choose one item. Hidden conflicts are removed automatically.", "field-help"),
          ]),
          clearWardrobe,
        ]),
        outfitGroups
      );
      visualWardrobe.hidden = false;
      fallbackAvatarFields.hidden = true;
      updateVisualChoices();
    };

    const loadArtworkCatalog = async () => {
      const response = await fetch("/banny-assets/catalog.json", {
        headers: { Accept: "application/json" },
        signal: controller.signal,
      });
      if (!response.ok) throw new Error("Banny artwork catalog unavailable.");
      const value = await response.json();
      if (!value || typeof value !== "object" || Array.isArray(value)) {
        throw new Error("Banny artwork catalog is invalid.");
      }
      return value;
    };

    void Promise.all([
      api("/catalog", { signal: controller.signal }),
      loadArtworkCatalog(),
    ])
      .then(([payload, artwork]) => {
        if (version !== routeVersion) return;
        artworkCatalog = artwork;
        const bodies = catalogEntries(payload, "bodies", "body");
        const eyeChoices = catalogEntries(payload, "eyes", "eye_options", "eyeOptions");
        const mouthChoices = catalogEntries(payload, "mouths", "mouth", "mouth_options", "mouthOptions");
        const catalog = readKey(payload, "catalog") || payload || {};
        const slots = asArray(readKey(catalog, "slots"));
        const outfitCount = slots.reduce(
          (total, slot) => total + asArray(readKey(slot, "outfits", "items")).length,
          0
        );
        populateCatalogSelect(body, bodies, [
          { value: "orange", label: "Orange" },
          { value: "original", label: "Original yellow" },
          { value: "pink", label: "Pink" },
          { value: "alien", label: "Alien green" },
        ]);
        populateCatalogSelect(eyes, eyeChoices, [{ value: "default", label: "Default" }]);
        populateCatalogSelect(mouth, mouthChoices, [{ value: "default", label: "Default" }]);
        wardrobeState = parsedOutfit();
        buildVisualWardrobe(bodies, eyeChoices, mouthChoices, slots);
        catalogStatus.textContent = `Choose from ${bodies.length || 4} bodies, ${eyeChoices.length || 1} eyes, ${mouthChoices.length || 1} mouths, and ${outfitCount} clothes, accessories, and props.`;
      })
      .catch((error) => {
        if (error.name !== "AbortError" && version === routeVersion) {
          catalogStatus.textContent = "Catalog unavailable; using the built-in body and default face fallback.";
          previewStatus.textContent = "Visual preview unavailable";
        }
      });

    let checkedRoomID = "";
    let checkedRoom = null;
    let roomCheckVersion = 0;
    let joining = false;

    const roomHasEnded = (found) => ["ended", "closed", "stopped"].includes(found.status);

    const roomUnavailableReason = (found) => {
      if (roomHasEnded(found)) return "This room has ended.";
      if (found.occupancy >= found.maximum) return "This room is full.";
      return "";
    };

    const setActiveSessionNotice = (id, visible) => {
      activeSessionNotice.hidden = !visible;
      if (visible) activeSessionLink.setAttribute("href", roomPath(id));
    };

    const resetAdmission = ({ clearSecrets = true } = {}) => {
      checkedRoomID = "";
      checkedRoom = null;
      setActiveSessionNotice("", false);
      admissionSection.hidden = true;
      admissionFields.hidden = true;
      identity.required = false;
      invite.required = false;
      identity.setCustomValidity("");
      invite.setCustomValidity("");
      if (clearSecrets) {
        identity.value = "";
        invite.value = "";
      }
      if (!joining) submit.disabled = false;
    };

    const applyRoom = (found, id) => {
      checkedRoomID = id;
      checkedRoom = found;
      let existingSession = participantSession(id);
      if (existingSession
          && !found.participants.some((participant) => participant.id === existingSession.participantID)) {
        forgetParticipantSession(id);
        existingSession = null;
      }
      setActiveSessionNotice(id, Boolean(existingSession));
      sidebar.querySelector("h2").textContent = found.title;
      admissionSection.hidden = !found.allowlisted;
      admissionFields.hidden = !found.allowlisted;
      identity.required = found.allowlisted;
      invite.required = found.allowlisted;
      if (!found.allowlisted) {
        identity.setCustomValidity("");
        invite.setCustomValidity("");
        identity.value = "";
        invite.value = "";
      }

      const unavailable = roomUnavailableReason(found);
      submit.disabled = joining || roomHasEnded(found) || Boolean(existingSession);
      status.className = unavailable || existingSession ? "form-status error" : "form-status success";
      status.textContent = existingSession
        ? "This tab already controls an active Banny here. Leave from the live room before joining again."
        : unavailable
          || `${found.title} has ${found.maximum - found.occupancy} ${found.maximum - found.occupancy === 1 ? "seat" : "seats"} open.`;
    };

    const inspectRoom = async () => {
      const id = room.value.trim();
      if (!isRoomIdentifier(id)) {
        throw new APIError("Enter the room ID from its Banny Live URL.", 0, null);
      }
      const check = ++roomCheckVersion;
      status.className = "form-status";
      status.textContent = "Checking the room…";
      const payload = await api(`/rooms/${encodeURIComponent(id)}`, { signal: controller.signal });
      if (version !== routeVersion || check !== roomCheckVersion) return null;
      const found = normalizeRoom(payload);
      applyRoom(found, id);
      return found;
    };

    const checkRoomFromField = () => {
      const id = room.value.trim();
      if (!isRoomIdentifier(id) || id === checkedRoomID) return;
      void inspectRoom().catch((error) => {
        if (error.name === "AbortError" || version !== routeVersion) return;
        resetAdmission();
        status.className = "form-status error";
        status.textContent = `Room check: ${error.message}`;
      });
    };

    if (roomID) {
      setActiveSessionNotice(roomID, Boolean(participantSession(roomID)));
      if (!activeSessionNotice.hidden) submit.disabled = true;
      checkRoomFromField();
    }
    else {
      room.addEventListener("input", () => {
        if (room.value.trim() === checkedRoomID) return;
        roomCheckVersion += 1;
        resetAdmission();
        status.className = "form-status";
        status.textContent = "";
      });
      room.addEventListener("blur", checkRoomFromField);
    }

    form.addEventListener("submit", async (event) => {
      event.preventDefault();
      if (joining) return;
      status.className = "form-status";
      status.textContent = "";

      const id = room.value.trim();
      if (!isRoomIdentifier(id)) {
        status.className = "form-status error";
        status.textContent = "Enter the room ID from its Banny Live URL.";
        room.focus();
        return;
      }
      name.setCustomValidity(name.value.trim() ? "" : "Give your Banny a name.");
      characterPrompt.setCustomValidity(
        characterPrompt.value.trim() ? "" : "Write the prompt that shapes your character."
      );
      if (!form.reportValidity()) return;

      let outfitJSON;
      try {
        outfitJSON = JSON.parse(outfit.value);
        if (!outfitJSON || typeof outfitJSON !== "object" || Array.isArray(outfitJSON)) {
          throw new Error("Outfit must be a JSON object.");
        }
        if (Object.values(outfitJSON).some((asset) => typeof asset !== "string")) {
          throw new Error("Each outfit slot must name one catalog asset.");
        }
      } catch (error) {
        status.className = "form-status error";
        status.textContent = error.message || "Outfit must be valid JSON.";
        outfit.focus();
        return;
      }

      joining = true;
      submit.disabled = true;
      submit.textContent = "Joining…";
      try {
        const found = await inspectRoom();
        if (!found) return;
        if (participantSession(id)) return;
        const unavailable = roomUnavailableReason(found);
        if (unavailable) throw new APIError(unavailable, 409, null);

        if (found.allowlisted) {
          identity.setCustomValidity(identity.value.trim() ? "" : "Enter your allowlist identity.");
          invite.setCustomValidity(invite.value ? "" : "Enter the private invite token.");
          if (!form.reportValidity()) return;
        }

        status.className = "form-status";
        status.textContent = `Bringing ${name.value.trim()} on stage…`;
        const join = {
          display_name: name.value.trim(),
          character_prompt: characterPrompt.value.trim(),
          avatar: {
            body: body.value,
            eyes: eyes.value.trim(),
            mouth: mouth.value.trim(),
            outfit: outfitJSON,
          },
        };
        if (found.allowlisted) {
          join.identity = identity.value.trim();
          join.invite = invite.value;
        }

        const payload = await api(`/rooms/${encodeURIComponent(id)}/join`, {
          method: "POST",
          signal: controller.signal,
          json: join,
        });
        const sessionToken = cleanString(readKey(payload, "session_token", "sessionToken"));
        const participantID = cleanString(readKey(payload, "participant_id", "participantID"));
        if (!sessionToken || !participantID) {
          throw new Error("The room admitted the character without returning its session details.");
        }
        rememberParticipantSession(id, sessionToken, participantID);
        characterPrompt.value = "";
        invite.value = "";
        status.className = "form-status success";
        status.textContent = "Your Banny is live. Opening the room…";
        navigate(roomPath(id));
      } catch (error) {
        if (error.name === "AbortError" || version !== routeVersion) return;
        status.className = "form-status error";
        status.textContent = error.message || "Your Banny could not join the room.";
      } finally {
        joining = false;
        submit.textContent = "Join the scene";
        submit.disabled = Boolean(
          checkedRoom && (roomHasEnded(checkedRoom) || participantSession(id))
        );
      }
    });
  }

  function displayTime(value, milliseconds = false) {
    if (typeof value === "number" && Number.isFinite(value)) {
      if (value > 1_000_000_000_000) {
        return new Date(value).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
      }
      const seconds = Math.floor(milliseconds ? value / 1_000 : value);
      const minutes = Math.floor(seconds / 60);
      return `${String(minutes).padStart(2, "0")}:${String(seconds % 60).padStart(2, "0")}`;
    }
    if (typeof value === "string" && value) {
      const parsed = Date.parse(value);
      if (Number.isFinite(parsed)) return new Date(parsed).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
    }
    return "";
  }

  function renderRoster(list, room) {
    list.replaceChildren();
    if (!room.participants.length) {
      list.append(element("li", { className: "muted", text: "Waiting for the first Banny…" }));
      return;
    }
    room.participants.forEach((participant) => {
      list.append(element("li", { className: "roster-item" }, [
        element("span", { className: "roster-presence", "aria-hidden": "true" }),
        element("span", { className: "roster-name", text: participant.name }),
        element("span", { className: "badge", text: `Seat ${participant.seat}` }),
      ]));
    });
  }

  function renderTranscript(list, room) {
    const viewport = list.parentElement;
    const pinned = viewport.scrollHeight - viewport.scrollTop - viewport.clientHeight < 35;
    list.replaceChildren();
    if (!room.transcript.length) {
      list.append(element("li", { className: "muted", text: "No dialogue yet." }));
      return;
    }
    for (const entry of room.transcript) {
      const item = element("li", { className: "transcript-item" });
      const speaker = element("span", { className: "speaker", text: entry.speaker });
      const time = displayTime(entry.at, entry.milliseconds);
      if (time) speaker.append(element("time", { className: "timestamp", text: time }));
      append(item, speaker, element("span", { text: entry.text }));
      list.append(item);
    }
    if (pinned) viewport.scrollTop = viewport.scrollHeight;
  }

  function obsURL(roomID) {
    const url = new URL(roomPath(roomID), location.origin);
    url.searchParams.set("embed", "1");
    url.searchParams.set("audio", "1");
    return url.href;
  }

  function obsGuide(roomID, compact = false) {
    const url = obsURL(roomID);
    const code = element("code", { className: "code-block obs-url", text: url });
    const status = paragraph("", "form-status");
    status.setAttribute("role", "status");
    const copy = button("Copy Browser Source URL", "primary");
    copy.addEventListener("click", () => void copyText(url, status, "OBS URL copied."));
    const body = element("div", {}, [
      paragraph("Add an OBS Browser Source with this clean, stage-only URL:", "microcopy"),
      code,
      element("ol", { className: "steps" }, [
        element("li", { text: "Set Width 1280 and Height 720 (or another 16:9 size)." }),
        element("li", { text: "Enable Control audio via OBS to mix the creator-supplied background MP3. Characters are caption-only and never produce audio." }),
        element("li", { text: "Use OBS or a relay to publish to YouTube, Twitch, TikTok, or Instagram; this page never asks for stream keys." }),
        element("li", { text: "For a 9:16 destination, crop or reframe the 16:9 stage in a separate OBS vertical canvas; do not stretch it." }),
      ]),
      copy,
      status,
    ]);
    if (compact) return element("details", {}, [element("summary", { text: "Stream with OBS" }), body]);
    return element("section", { className: "guide-card" }, [
      paragraph("Broadcast", "eyebrow"),
      element("h2", { text: "OBS Browser Source" }),
      body,
    ]);
  }

  function startFramePolling(image, placeholder, statusBadge, roomID, version) {
    let stopped = false;
    let timer = 0;
    let loadedOnce = false;
    const encoded = encodeURIComponent(roomID);

    const schedule = (delay) => {
      if (!stopped) timer = globalThis.setTimeout(load, delay);
    };
    const load = () => {
      if (stopped || version !== routeVersion) return;
      image.src = `${API_ROOT}/rooms/${encoded}/frame.jpg?ts=${Date.now()}`;
    };
    image.addEventListener("load", () => {
      if (stopped) return;
      loadedOnce = true;
      placeholder.hidden = true;
      statusBadge.textContent = "Live frame";
      statusBadge.className = "badge live stage-status";
      schedule(FRAME_INTERVAL_MS);
    });
    image.addEventListener("error", () => {
      if (stopped) return;
      if (!loadedOnce) placeholder.hidden = false;
      statusBadge.textContent = loadedOnce ? "Reconnecting" : "Waiting for frame";
      statusBadge.className = "badge stage-status";
      schedule(loadedOnce ? 1_250 : 1_800);
    });
    onRouteCleanup(() => {
      stopped = true;
      clearTimeout(timer);
      image.removeAttribute("src");
    });
    load();
  }

  function renderLive(roomID, version) {
    if (!roomID) {
      renderNotFound();
      return;
    }
    const params = new URLSearchParams(location.search);
    const embedded = params.get("embed") === "1";
    const currentParticipantSession = participantSession(roomID);
    document.body.classList.toggle("embed", embedded);
    setPage("Live room", "/");

    const title = element("h1", { text: "Live room" });
    const status = element("span", { className: "badge live", text: "Connecting" });
    const leaveParticipant = currentParticipantSession && !embedded
      ? button("Leave my Banny", "danger participant-leave")
      : null;
    const heading = element("header", { className: "live-heading" }, [
      element("div", {}, [paragraph("On stage", "eyebrow"), title]),
      element("div", { className: "room-actions" }, [
        status,
        currentParticipantSession
          ? null
          : link("Join this room", roomPath(roomID, "join"), "button primary"),
        link("Host controls", roomPath(roomID, "control"), "button"),
      ]),
    ]);
    const participantActionStatus = paragraph("", "form-status");
    participantActionStatus.setAttribute("role", "status");
    participantActionStatus.setAttribute("aria-live", "polite");
    const participantSessionPanel = currentParticipantSession && !embedded
      ? element("section", { className: "callout live participant-session-panel" }, [
          element("div", {}, [
            element("strong", { text: "This tab controls your Banny" }),
            paragraph(
              currentParticipantSession.persisted
                ? "Use Leave my Banny to stop the character and release its seat. Closing this tab does not make it leave."
                : "Your browser could not save this tab's leave key. Keep this page open and use Leave my Banny before refreshing or closing it; otherwise the character keeps performing until the host removes it or the room ends.",
              "microcopy"
            ),
            participantActionStatus,
          ]),
          leaveParticipant,
        ])
      : null;

    const image = element("img", {
      className: "stage-frame", alt: "Live rendered Banny room", decoding: "async",
    });
    const placeholder = element("div", { className: "stage-placeholder" }, [
      element("div", { className: "loading-bars", "aria-hidden": "true" }, [
        element("span"), element("span"), element("span"),
      ]),
      element("span", { text: "Waiting for the renderer" }),
    ]);
    const frameStatus = element("span", { className: "badge stage-status", text: "Waiting for frame" });
    const stage = element("div", { className: "stage" }, [placeholder, image, frameStatus]);

    const music = element("audio", {
      controls: true,
      loop: true,
      preload: "none",
      "aria-label": "Room background music",
      src: `${API_ROOT}/rooms/${encodeURIComponent(roomID)}/music`,
    });
    const stageTools = element("div", { className: "stage-tools" }, [music]);
    const stageWrap = element("div", { className: "stage-wrap" }, [stage, stageTools]);

    const occupancy = element("span", { className: "badge", text: "0/0" });
    const roster = element("ul", { className: "roster" });
    const rosterPanel = element("section", { className: "panel" }, [
      element("div", { className: "panel-head" }, [element("h2", { text: "On stage" }), occupancy]),
      roster,
    ]);
    const transcript = element("ol", { className: "transcript" });
    const transcriptPanel = element("section", { className: "panel" }, [
      element("div", { className: "panel-head" }, [element("h2", { text: "Transcript" })]),
      element("div", { className: "transcript-wrap", "aria-live": "polite", "aria-relevant": "additions" }, transcript),
    ]);
    const sidebar = element("aside", { className: "live-sidebar" }, [rosterPanel, transcriptPanel, obsGuide(roomID, true)]);
    const shell = element("section", { className: "live-shell" }, [
      heading,
      participantSessionPanel,
      element("div", { className: "stage-grid" }, [stageWrap, sidebar]),
    ]);
    app.append(shell);

    if (embedded && params.get("audio") === "1") {
      music.preload = "auto";
      void music.play().catch(() => { /* OBS can enable the room MP3 after source interaction. */ });
    }

    startFramePolling(image, placeholder, frameStatus, roomID, version);
    const controller = new AbortController();
    let stopped = false;
    let timer = 0;
    onRouteCleanup(() => {
      stopped = true;
      clearTimeout(timer);
      controller.abort();
      music.pause();
    });

    if (leaveParticipant && currentParticipantSession) {
      leaveParticipant.addEventListener("click", async () => {
        if (!globalThis.confirm(
          "Leave this room and stop your Banny's autonomous performance? Closing the tab alone will not do this."
        )) return;
        leaveParticipant.disabled = true;
        participantActionStatus.className = "form-status";
        participantActionStatus.textContent = "Taking your Banny off stage…";
        try {
          await api(`/rooms/${encodeURIComponent(roomID)}/leave`, {
            method: "POST",
            signal: controller.signal,
            headers: bearerHeaders(currentParticipantSession.token),
            json: { participant_id: currentParticipantSession.participantID },
          });
          forgetParticipantSession(roomID);
          participantActionStatus.className = "form-status success";
          participantActionStatus.textContent = "Your Banny left the room. Refreshing the stage…";
          navigate(roomPath(roomID), { replace: true });
        } catch (error) {
          if (error.name === "AbortError" || stopped) return;
          participantActionStatus.className = "form-status error";
          participantActionStatus.textContent = `${error.message} Your leave key was kept so you can retry.`;
          leaveParticipant.disabled = false;
        }
      });
    }

    const update = async () => {
      if (stopped || version !== routeVersion) return;
      try {
        const payload = await api(`/rooms/${encodeURIComponent(roomID)}`, { signal: controller.signal });
        if (stopped || version !== routeVersion) return;
        const room = normalizeRoom(payload);
        title.textContent = room.title;
        status.textContent = ["ended", "closed", "stopped"].includes(room.status) ? "Ended" : "Live";
        status.className = `badge ${status.textContent === "Live" ? "live" : "ended"}`;
        occupancy.textContent = `${room.occupancy}/${room.maximum}`;
        renderRoster(roster, room);
        renderTranscript(transcript, room);
      } catch (error) {
        if (error.name === "AbortError" || stopped) return;
        status.textContent = "Reconnecting";
        status.className = "badge";
      }
      if (!stopped) timer = globalThis.setTimeout(update, SNAPSHOT_INTERVAL_MS);
    };
    void update();
  }

  function bearerHeaders(token) {
    return token ? { Authorization: `Bearer ${token}` } : {};
  }

  function renderControl(roomID, version) {
    if (!roomID) {
      renderNotFound();
      return;
    }
    setPage("Host controls", "/");
    append(app,
      paragraph("Host console", "eyebrow"),
      element("h1", { text: "Run the room." }),
      paragraph("Keep the token in this tab, manage seats, and hand a clean stage URL to OBS.", "lede")
    );

    const token = element("input", {
      type: "password", value: safeSessionGet(hostTokenKey(roomID)) || "",
      autocomplete: "off", spellcheck: false, placeholder: "Host bearer token",
    });
    const tokenStatus = paragraph("Tokens are held in session storage and disappear when the tab session ends.", "field-help");
    tokenStatus.setAttribute("role", "status");
    const saveToken = button("Save for this tab");
    saveToken.addEventListener("click", () => {
      const saved = safeSessionSet(hostTokenKey(roomID), token.value.trim());
      tokenStatus.textContent = saved ? "Host token saved for this tab." : "Session storage is unavailable; the field will remain in memory.";
    });
    const tokenField = labeledField({
      label: "Host token", id: "host-token", control: token,
      help: "Never place this token in a room URL or OBS source.", full: true,
    });
    const authPanel = element("section", { className: "form-card" }, [
      element("h2", { text: "Authorization" }),
      tokenField,
      element("div", { className: "button-row" }, [saveToken]),
      tokenStatus,
    ]);

    const invitationPanel = element("section", { className: "form-card" });
    const storedInvitations = safeSessionGet(invitationKey(roomID));
    if (storedInvitations) {
      let invitations = [];
      try {
        const decoded = JSON.parse(storedInvitations);
        if (Array.isArray(decoded)) {
          invitations = decoded.map((item, index) => {
            if (typeof item === "string") return { identity: `Invite ${index + 1}`, token: item };
            return {
              identity: cleanString(readKey(item, "identity", "name", "participant"), `Invite ${index + 1}`),
              token: cleanString(readKey(item, "token", "invite", "invitation")),
            };
          });
        } else if (decoded && typeof decoded === "object") {
          invitations = Object.entries(decoded).map(([identityValue, tokenValue]) => ({
            identity: identityValue,
            token: typeof tokenValue === "string"
              ? tokenValue
              : cleanString(readKey(tokenValue, "token", "invite", "invitation")),
          }));
        }
      } catch {
        invitations = [];
      }
      invitations = invitations.filter((item) => item.token);
      if (invitations.length) {
        const invitationList = element("ul", { className: "participant-list" });
        for (const invitation of invitations) {
          const copy = button("Copy invite");
          const copyStatus = paragraph("", "field-help");
          copy.addEventListener("click", () => void copyText(
            invitation.token,
            copyStatus,
            `Invite for ${invitation.identity} copied.`
          ));
          invitationList.append(element("li", { className: "participant-item" }, [
            element("div", { className: "participant-copy" }, [
              element("strong", { text: invitation.identity }),
              copyStatus,
            ]),
            copy,
          ]));
        }
        append(invitationPanel,
          element("h2", { text: "Admission invites" }),
          paragraph("Share each secret directly with its intended participant.", "microcopy"),
          invitationList
        );
      }
    }

    const roomTitle = element("h2", { text: "Room" });
    const roomStatus = element("span", { className: "badge", text: "Loading" });
    const participantList = element("ul", { className: "participant-list" });
    const empty = paragraph("Loading participants…", "muted");
    participantList.append(element("li", {}, empty));
    const actionStatus = paragraph("", "form-status");
    actionStatus.setAttribute("role", "status");
    actionStatus.setAttribute("aria-live", "polite");
    const endRoom = button("End room", "danger");
    const refresh = button("Refresh");
    const participantsPanel = element("section", { className: "form-card" }, [
      element("div", { className: "panel-head" }, [roomTitle, roomStatus]),
      participantList,
      element("div", { className: "control-actions" }, [
        refresh,
        link("Open viewer", roomPath(roomID), "button live"),
        link("Join instructions", roomPath(roomID, "join"), "button"),
        endRoom,
      ]),
      actionStatus,
    ]);
    const left = element("div", { className: "form-stack" }, [
      authPanel,
      invitationPanel.childElementCount ? invitationPanel : null,
      participantsPanel,
    ]);
    const right = element("div", {}, [obsGuide(roomID)]);
    app.append(element("div", { className: "control-layout" }, [left, right]));

    const controller = new AbortController();
    onRouteCleanup(() => controller.abort());

    const requireToken = () => {
      const value = token.value.trim();
      if (!value) {
        actionStatus.className = "form-status error";
        actionStatus.textContent = "Enter the host token first.";
        token.focus();
        return null;
      }
      return value;
    };

    const drawParticipants = (room) => {
      participantList.replaceChildren();
      if (!room.participants.length) {
        participantList.append(element("li", { className: "muted", text: "No participants are connected." }));
        return;
      }
      for (const participant of room.participants) {
        const remove = button("Remove", "danger");
        remove.setAttribute("aria-label", `Remove ${participant.name}`);
        remove.addEventListener("click", async () => {
          const credential = requireToken();
          if (!credential) return;
          if (!globalThis.confirm(`Remove ${participant.name} from this room?`)) return;
          remove.disabled = true;
          actionStatus.className = "form-status";
          actionStatus.textContent = `Removing ${participant.name}…`;
          try {
            await api(`/rooms/${encodeURIComponent(roomID)}/participants/${encodeURIComponent(participant.id)}`, {
              method: "DELETE",
              headers: bearerHeaders(credential),
            });
            actionStatus.className = "form-status success";
            actionStatus.textContent = `${participant.name} was removed.`;
            await refreshRoom();
          } catch (error) {
            actionStatus.className = "form-status error";
            actionStatus.textContent = error.message;
            remove.disabled = false;
          }
        });
        participantList.append(element("li", { className: "participant-item" }, [
          element("div", { className: "participant-copy" }, [
            element("strong", { text: participant.name }),
            element("small", { text: `Seat ${participant.seat} · ${participant.state}` }),
          ]),
          remove,
        ]));
      }
    };

    const refreshRoom = async () => {
      refresh.disabled = true;
      try {
        const payload = await api(`/rooms/${encodeURIComponent(roomID)}`, { signal: controller.signal });
        if (version !== routeVersion) return;
        const room = normalizeRoom(payload);
        roomTitle.textContent = room.title;
        const ended = ["ended", "closed", "stopped"].includes(room.status);
        roomStatus.textContent = ended ? "Ended" : `${room.occupancy}/${room.maximum} live`;
        roomStatus.className = `badge ${ended ? "ended" : "live"}`;
        endRoom.disabled = ended;
        drawParticipants(room);
      } catch (error) {
        if (error.name === "AbortError") return;
        actionStatus.className = "form-status error";
        actionStatus.textContent = error.message;
      } finally {
        refresh.disabled = false;
      }
    };
    refresh.addEventListener("click", () => void refreshRoom());

    endRoom.addEventListener("click", async () => {
      const credential = requireToken();
      if (!credential) return;
      if (!globalThis.confirm("End this room for everyone? The recorded .bs show will be finalized.")) return;
      endRoom.disabled = true;
      actionStatus.className = "form-status";
      actionStatus.textContent = "Ending and finalizing the room…";
      try {
        await api(`/rooms/${encodeURIComponent(roomID)}/end`, {
          method: "POST",
          headers: bearerHeaders(credential),
        });
        actionStatus.className = "form-status success";
        actionStatus.textContent = "Room ended. The recording is being finalized.";
        await refreshRoom();
      } catch (error) {
        actionStatus.className = "form-status error";
        actionStatus.textContent = error.message;
        endRoom.disabled = false;
      }
    });
    void refreshRoom();
  }

  function renderNotFound() {
    setPage("Not found", "");
    app.append(element("section", { className: "not-found" }, [
      element("div", {}, [
        element("h1", { text: "404" }),
        element("h2", { text: "That stage does not exist." }),
        paragraph("It may have ended, or the room link may be incomplete.", "muted"),
        link("Browse live rooms", "/", "button primary"),
      ]),
    ]));
  }

  document.addEventListener("click", (event) => {
    if (event.defaultPrevented || event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
    const anchor = event.target.closest("a[data-link]");
    if (!anchor || anchor.target || anchor.hasAttribute("download")) return;
    const url = new URL(anchor.href, location.href);
    if (url.origin !== location.origin) return;
    event.preventDefault();
    navigate(url.href);
  });

  globalThis.addEventListener("popstate", () => void renderRoute({ focus: true }));
  void renderRoute();
})();
