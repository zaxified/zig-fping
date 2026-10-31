// fping-watch front end: polls /api/state and renders it. No framework, no
// build step; every user-supplied string goes through textContent.
"use strict";

const REFRESH_MS = 15000;
const BEAT_PX = 9; // beat width + gap, see .beat in style.css
let state = null;

// What the list shows, kept in the URL fragment so a filtered view can be
// bookmarked or sent: #open=3,5&tags=dns,ipv6&q=google&sort=loss&rev=1.
// The 1.0 form, #3,5, still opens targets 3 and 5.
const SORTS = {
  status: "Problems first",
  name: "Name",
  loss: "Packet loss (24 h)",
  jitter: "Jitter (24 h)",
  avg: "Average latency (24 h)",
  max: "Worst latency (24 h)",
};
function parseView() {
  const hash = location.hash.slice(1);
  const p = new URLSearchParams(/^[\d,]+$/.test(hash) ? `open=${hash}` : hash);
  const list = (key) => (p.get(key) || "").split(",").filter(Boolean);
  return {
    open: new Set(list("open").map(Number)), // ids of expanded targets
    tags: new Set(list("tags")), // a target must have every one
    q: p.get("q") || "",
    sort: p.get("sort") in SORTS ? p.get("sort") : "status",
    rev: p.get("rev") === "1",
  };
}
const view = parseView();

function saveView() {
  const p = new URLSearchParams();
  if (view.open.size) p.set("open", [...view.open].join(","));
  if (view.tags.size) p.set("tags", [...view.tags].join(","));
  if (view.q) p.set("q", view.q);
  if (view.sort !== "status") p.set("sort", view.sort);
  if (view.rev) p.set("rev", "1");
  const hash = p.toString().replaceAll("%2C", ",");
  history.replaceState(null, "", hash ? `#${hash}` : location.pathname + location.search);
}

// The tag editor of one target, kept across re-renders (a new cycle redraws
// the list while someone types).
let editing = null; // { id, value }

const splitTags = (text) => text.split(/[\s,]+/).filter(Boolean);

const $ = (sel, root = document) => root.querySelector(sel);
const el = (tag, cls, text) => {
  const e = document.createElement(tag);
  if (cls) e.className = cls;
  if (text !== undefined) e.textContent = text;
  return e;
};
const svgEl = (tag, attrs) => {
  const e = document.createElementNS("http://www.w3.org/2000/svg", tag);
  for (const [k, v] of Object.entries(attrs)) e.setAttribute(k, v);
  return e;
};

const STATUS = {
  up: ["UP", "var(--up)"],
  degraded: ["LOSS", "var(--warn)"],
  down: ["DOWN", "var(--down)"],
  acked: ["ACK", "var(--ack)"],
  paused: ["PAUSED", "var(--paused)"],
  pending: ["PENDING", "var(--paused)"],
};
const statusOf = (t) => (t.status === "down" && t.acked ? "acked" : t.status);

const beatColor = (loss) =>
  loss === null ? "" : loss === 0 ? "var(--up)" : loss < 100 ? "var(--warn)" : "var(--down)";

const ms = (v) =>
  v === null || v === undefined ? "–" : v < 1 ? `${v.toFixed(2)} ms` : v < 10 ? `${v.toFixed(1)} ms` : `${Math.round(v)} ms`;
const mean = (a) => (a.length ? a.reduce((x, y) => x + y, 0) / a.length : null);
// Nearest-rank percentile.
const percentile = (a, p) => {
  if (!a.length) return null;
  const sorted = [...a].sort((x, y) => x - y);
  return sorted[Math.min(sorted.length - 1, Math.ceil((p / 100) * sorted.length) - 1)];
};
// One cycle, for the beat strip and the chart tooltip. A demo marks the
// sample data (everything before demo_from).
const isSample = (t, at) => t.sample && at < state.demo_from;
const describe = (t, i, at) =>
  (isSample(t, at) ? "sample data · " : "") +
  (t.loss[i] === null
    ? `${time(at)} · no data`
    : `${time(at)} · ${ms(t.rtt[i])}` + (t.jitter[i] === null ? "" : ` ± ${ms(t.jitter[i])}`) + ` · ${t.loss[i]} % loss`);
const time = (unix) => new Date(unix * 1000).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });

function summarize(t) {
  const rtts = t.rtt.filter((v) => v !== null);
  const losses = t.loss.filter((v) => v !== null);
  const jitters = t.jitter.filter((v) => v !== null);
  const up = losses.filter((v) => v < 100).length;
  let last = null, lastJitter = null;
  for (let i = t.rtt.length - 1; i >= 0; i--) {
    if (t.loss[i] === null) continue;
    last = t.rtt[i];
    lastJitter = t.jitter[i];
    break;
  }
  return {
    samples: losses.length,
    uptime: losses.length ? (100 * up) / losses.length : null,
    avg: mean(rtts),
    min: rtts.length ? Math.min(...rtts) : null,
    max: rtts.length ? Math.max(...rtts) : null,
    p95: percentile(rtts, 95),
    jitter: mean(jitters),
    loss: mean(losses),
    last,
    lastJitter,
  };
}

// ----- API -------------------------------------------------------------------

let etag = null;

async function load() {
  try {
    // "no-cache": the browser revalidates with If-None-Match, and the server
    // answers 304 until the next cycle; nothing new means nothing to redraw.
    const res = await fetch("api/state", { cache: "no-cache" });
    if (!res.ok) throw new Error(res.statusText);
    const tag = res.headers.get("etag");
    if (tag === null || tag !== etag) {
      state = await res.json();
      etag = tag;
      render();
    }
    $("#updated").textContent = `Updated ${new Date().toLocaleTimeString()}`;
  } catch (err) {
    $("#updated").textContent = `Cannot reach the server (${err.message}), retrying…`;
  }
}

// A read-only demo shows every control, so it looks like the real thing;
// using one explains instead of failing (the server refuses anyway).
const DEMO_NOTE = "This is a read-only demo: changes are disabled. Install fping-watch to manage your own targets.";

async function call(method, path, body) {
  if (state.read_only) throw new Error(DEMO_NOTE);
  const res = await fetch(path, {
    method,
    headers: { "content-type": "application/json" },
    body: body ? JSON.stringify(body) : "{}",
  });
  const data = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(data.error || res.statusText);
  await load();
  return data;
}

// ----- rendering ---------------------------------------------------------------

function render() {
  $("#mode").hidden = !state.read_only;

  // The summary counts every target: the filter narrows the list, not the
  // overall health.
  const counts = {};
  for (const t of state.targets) counts[statusOf(t)] = (counts[statusOf(t)] || 0) + 1;
  const summary = $("#summary");
  summary.replaceChildren();
  for (const key of ["up", "degraded", "down", "acked", "paused", "pending"]) {
    if (!counts[key]) continue;
    const pill = el("span", "pill", `${counts[key]} ${STATUS[key][0].toLowerCase()}`);
    pill.style.setProperty("--c", STATUS[key][1]);
    summary.append(pill);
  }

  const stats = new Map(state.targets.map((t) => [t.id, summarize(t)]));
  const shown = sortTargets(state.targets.filter(matches), stats);
  renderToolbar(shown.length);

  // A re-render while the tag editor has the focus gives it back.
  const active = document.activeElement;
  const refocus = active && active.classList.contains("tag-input") ? [active.selectionStart, active.selectionEnd] : null;

  // Swapping the list collapses the page for a moment, and the browser clamps
  // the scroll position to the shorter page: a reader scrolled down would land
  // at the top. Expanded details are filled in the same task (their chart
  // needs the attached width) and the position is put back before any paint.
  const y = window.scrollY;
  const list = $("#targets");
  const expand = [];
  list.replaceChildren(...shown.map((t) => renderTarget(t, stats.get(t.id), expand)));
  if (state.targets.length === 0) list.append(el("p", "empty", "No targets yet."));
  else if (shown.length === 0) {
    const p = el("p", "empty", "No target matches the filter. ");
    const clear = el("button", "link", "Show all");
    clear.type = "button";
    clear.addEventListener("click", clearFilter);
    p.append(clear);
    list.append(p);
  }
  for (const show of expand) show();
  if (refocus) {
    const input = $(".tag-input", list);
    if (input) {
      input.focus({ preventScroll: true });
      input.setSelectionRange(...refocus);
    }
  }
  if (window.scrollY !== y) window.scrollTo(0, y);
}

// ----- filter and order ----------------------------------------------------------

const filtered = () => view.tags.size > 0 || view.q !== "";

// Every selected tag, and every word of the search somewhere in the name, the
// host or a tag.
function matches(t) {
  for (const tag of view.tags) if (!t.tags.includes(tag)) return false;
  const hay = [t.name, t.host, ...t.tags].map((s) => s.toLowerCase());
  return splitTags(view.q.toLowerCase()).every((w) => hay.some((h) => h.includes(w)));
}

// Problems first: DOWN, LOSS, ACK, PENDING, UP, PAUSED.
const RANK = { down: 0, degraded: 1, acked: 2, pending: 3, up: 4, paused: 5 };
const byName = (a, b) => a.name.localeCompare(b.name, undefined, { numeric: true, sensitivity: "base" });

// Each order has a natural direction (problems first, A to Z, the worst
// figure first); `rev` turns it around. Targets without data go last either
// way, and ties keep name order.
function sortTargets(list, stats) {
  const dir = view.rev ? -1 : 1;
  const metric = { loss: "loss", jitter: "jitter", avg: "avg", max: "max" }[view.sort];
  const cmp = {
    status: (a, b) => RANK[statusOf(a)] - RANK[statusOf(b)],
    name: () => 0,
  }[view.sort];
  return list.sort((a, b) => {
    let d = 0;
    if (metric) {
      const x = stats.get(a.id)[metric], y = stats.get(b.id)[metric];
      if (x === null || y === null) d = (x === null) - (y === null);
      else d = dir * (y - x);
    } else d = dir * cmp(a, b);
    return d || (view.sort === "name" ? dir : 1) * byName(a, b);
  });
}

function setView(change) {
  change();
  saveView();
  if (state) render();
}

function clearFilter() {
  setView(() => {
    view.tags.clear();
    view.q = "";
    $("#find").value = "";
  });
}

// The tag chips (every tag in use, plus a selected one no target has any
// more, so it can be unselected), the order button and the match count.
function renderToolbar(count) {
  const all = new Set(state.targets.flatMap((t) => t.tags));
  for (const tag of view.tags) all.add(tag);
  const bar = $("#tagbar");
  bar.replaceChildren();
  for (const tag of [...all].sort((a, b) => a.localeCompare(b, undefined, { numeric: true }))) {
    const chip = el("button", "chip", tag);
    chip.type = "button";
    chip.setAttribute("aria-pressed", String(view.tags.has(tag)));
    chip.title = view.tags.has(tag) ? "Stop filtering by this tag" : "Show only targets with this tag";
    chip.addEventListener("click", () => setView(() => (view.tags.has(tag) ? view.tags.delete(tag) : view.tags.add(tag))));
    bar.append(chip);
  }
  bar.hidden = all.size === 0;

  const order = $("#order");
  const [fwd, back] = {
    status: ["problems first", "OK first"],
    name: ["A to Z", "Z to A"],
  }[view.sort] || ["highest first", "lowest first"];
  order.textContent = view.rev ? "↑" : "↓";
  order.title = `Order: ${view.rev ? back : fwd} (click: ${view.rev ? fwd : back})`;
  order.setAttribute("aria-label", order.title);

  const note = $("#shown");
  note.replaceChildren();
  if (filtered()) {
    note.append(`${count} of ${state.targets.length} shown `);
    const clear = el("button", "link", "clear");
    clear.type = "button";
    clear.addEventListener("click", clearFilter);
    note.append(clear);
  }
}

// expand collects the detail renderers of expanded targets; render() calls
// them once the row is in the page.
function renderTarget(t, s, expand) {
  const node = $("#row").content.firstElementChild.cloneNode(true);
  const [label, color] = STATUS[statusOf(t)];

  const badge = $(".badge", node);
  badge.textContent = label;
  badge.style.setProperty("--c", color);
  $(".name", node).textContent = t.name;
  $(".host", node).textContent = t.host;
  const tags = $(".tags", node);
  for (const tag of t.tags) tags.append(el("span", view.tags.has(tag) ? "rtag on" : "rtag", tag));
  tags.hidden = t.tags.length === 0;
  $(".uptime", node).textContent = s.uptime === null ? "–" : `${s.uptime.toFixed(s.uptime === 100 ? 0 : 2)} %`;
  $(".latency", node).textContent = t.paused ? "–" : ms(s.last);
  renderBeats($(".beats", node), t);

  const head = $(".head", node);
  const detail = $(".detail", node);
  const toggle = (show) => {
    detail.hidden = !show;
    head.setAttribute("aria-expanded", String(show));
    if (show) renderDetail(detail, t, s);
  };
  head.addEventListener("click", () => {
    if (view.open.has(t.id)) view.open.delete(t.id);
    else view.open.add(t.id);
    saveView();
    toggle(view.open.has(t.id));
  });
  if (view.open.has(t.id)) expand.push(() => toggle(true));
  return node;
}

function renderBeats(box, t) {
  // As many recent cycles as fit; refit on resize via render().
  const width = box.clientWidth || Math.min(window.innerWidth - 80, 540);
  const n = Math.max(10, Math.min(90, Math.floor(width / BEAT_PX)));
  box.replaceChildren();
  for (let i = t.loss.length - n; i < t.loss.length; i++) {
    const b = el("span", "beat");
    const c = beatColor(t.loss[i]);
    if (c) b.style.setProperty("--c", c);
    const at = state.end - (t.loss.length - 1 - i) * state.cycle_s;
    b.title = describe(t, i, at);
    box.append(b);
  }
}

function renderDetail(detail, t, s) {
  renderChart($(".chart", detail), t);

  const stats = $(".stats", detail);
  stats.replaceChildren();
  const stat = (name, value) => {
    const d = el("div", null, name);
    d.prepend(el("b", null, value));
    stats.append(d);
  };
  stat("current", s.lastJitter === null ? ms(s.last) : `${ms(s.last)} ± ${ms(s.lastJitter)}`);
  stat("average (24 h)", ms(s.avg));
  stat("95th percentile (24 h)", ms(s.p95));
  stat("jitter (24 h)", ms(s.jitter));
  stat("best / worst", `${ms(s.min)} / ${ms(s.max)}`);
  stat("packet loss (24 h)", s.loss === null ? "–" : `${s.loss.toFixed(2)} %`);
  stat("uptime (24 h)", s.uptime === null ? "–" : `${s.uptime.toFixed(2)} %`);
  if (t.acked) stat("acknowledged", `clears after ${state.ack_clear_after - t.ok_streak} more good cycles`);
  if (t.error) stat("last error", t.error);

  const actions = $(".actions", detail);
  actions.replaceChildren();
  const note = el("span", "note");
  if (editing && editing.id === t.id) return renderTagEditor(actions, note, t);
  const action = (text, hint, fn, cls) => {
    const b = el("button", cls, text);
    b.type = "button";
    b.title = hint;
    b.addEventListener("click", async () => {
      b.disabled = true;
      note.textContent = "";
      try {
        if ((await fn()) === false) b.disabled = false; // confirm() cancelled
      } catch (err) {
        note.textContent = err.message;
        b.disabled = false;
      }
    });
    actions.append(b);
  };
  const base = `api/targets/${t.id}`;
  if (t.paused) action("Resume", "Start probing this target again", () => call("POST", `${base}/resume`));
  else action("Pause", "Stop probing this target, e.g. during maintenance; the history is kept", () => call("POST", `${base}/pause`));
  if (t.status === "down" && !t.acked)
    action("Acknowledge", `Mark this outage as known: the target shows ACK instead of DOWN until ${state.ack_clear_after} cycles in a row are not DOWN`, () => call("POST", `${base}/ack`));
  if (t.acked) action("Remove acknowledgement", "Show this target as DOWN again", () => call("POST", `${base}/unack`));
  action("Edit tags", "Labels to filter the list by, e.g. a site, a customer or a service", () => {
    editing = { id: t.id, value: t.tags.join(" ") };
    renderDetail(detail, t, s);
    $(".tag-input", detail).focus();
  });
  action("Remove", "Stop monitoring this target and delete its history",
    () => (state.read_only || confirm(`Remove ${t.name}?`)) && call("DELETE", base).then(() => view.open.delete(t.id)), "danger");
  actions.append(note);
}

// The tag editor in place of the actions; `editing` keeps the typed value
// across re-renders.
function renderTagEditor(actions, note, t) {
  const input = el("input", "tag-input");
  input.value = editing.value;
  input.placeholder = "Tags, separated by spaces";
  input.setAttribute("aria-label", `Tags of ${t.name}`);
  input.maxLength = 300;
  input.addEventListener("input", () => (editing.value = input.value));
  const close = () => {
    editing = null;
    render();
  };
  const save = async () => {
    note.textContent = "";
    try {
      await call("POST", `api/targets/${t.id}/tags`, { tags: splitTags(input.value) });
      close();
    } catch (err) {
      note.textContent = err.message;
    }
  };
  input.addEventListener("keydown", (ev) => {
    if (ev.key === "Enter") save();
    if (ev.key === "Escape") close();
  });
  const button = (text, fn) => {
    const b = el("button", null, text);
    b.type = "button";
    b.addEventListener("click", fn);
    return b;
  };
  actions.append(input, button("Save", save), button("Cancel", close), note);
}

function renderChart(box, t) {
  const W = Math.max(300, box.clientWidth || 600);
  const H = 180, L = 44, R = 8, T = 10, B = 34, LOSS_H = 6;
  const n = t.rtt.length;
  const x = (i) => L + (i * (W - L - R)) / (n - 1);
  const values = t.rtt.map((v, i) => (v === null ? null : v + (t.jitter[i] || 0))).filter((v) => v !== null);
  const top = niceCeil(Math.max(1, ...values) * 1.1);
  const y = (v) => T + (H - T - B) * (1 - v / top);

  const svg = svgEl("svg", { viewBox: `0 0 ${W} ${H}`, role: "img", "aria-label": `Latency of ${t.name}, last 24 hours` });
  for (const f of [0, 0.5, 1]) {
    svg.append(svgEl("line", { class: "grid", x1: L, x2: W - R, y1: y(top * f), y2: y(top * f) }));
    const label = svgEl("text", { class: "axis", x: L - 6, y: y(top * f) + 4, "text-anchor": "end" });
    label.textContent = f === 0 ? "0" : `${+(top * f).toFixed(1)} ms`;
    svg.append(label);
  }
  // A demo: shade the sample data, so nobody takes it for a real record.
  const real = n - 1 - (state.end - state.demo_from) / state.cycle_s;
  if (t.sample && real > 0) {
    svg.append(svgEl("rect", { class: "sample", x: L, y: T, width: Math.min(x(real), W - R) - L, height: H - T - B }));
    const label = svgEl("text", { class: "axis", x: L + 6, y: T + 12 });
    label.textContent = "sample data";
    svg.append(label);
    if (x(real) + 34 < W - R) { // the live part is narrow in the first minutes
      const live = svgEl("text", { class: "axis", x: x(real) + 6, y: T + 12 });
      live.textContent = "live";
      svg.append(live);
    }
  }
  const perHour = 3600 / state.cycle_s;
  for (let i = n - 1; i >= 0; i -= 6 * perHour) {
    const label = svgEl("text", { class: "axis", x: x(i), y: H - 8, "text-anchor": i === n - 1 ? "end" : "middle" });
    label.textContent = time(state.end - (n - 1 - i) * state.cycle_s);
    svg.append(label);
  }

  // Latency: one path per run of consecutive samples, so gaps stay gaps; the
  // band around the line is ± the cycle's jitter.
  let line = "", area = "", band = "", run = [];
  const pt = (i, v) => `${x(i).toFixed(1)},${y(Math.max(0, v)).toFixed(1)}`;
  const flush = () => {
    if (run.length) {
      line += "M" + run.map(([i, v]) => pt(i, v)).join("L");
      area += `M${pt(run[0][0], 0)}` + run.map(([i, v]) => `L${pt(i, v)}`).join("") + `L${pt(run[run.length - 1][0], 0)}Z`;
      const j = (i) => t.jitter[i] || 0;
      band += "M" + run.map(([i, v]) => pt(i, v + j(i))).join("L") +
        "L" + run.slice().reverse().map(([i, v]) => pt(i, v - j(i))).join("L") + "Z";
    }
    run = [];
  };
  t.rtt.forEach((v, i) => (v === null ? flush() : run.push([i, v])));
  flush();
  svg.append(svgEl("path", { class: "area", d: area }), svgEl("path", { class: "band", d: band }), svgEl("path", { class: "rtt", d: line }));

  // Loss: a strip under the chart, orange for partial and red for total loss.
  const w = Math.max(1.5, (W - L - R) / n);
  t.loss.forEach((v, i) => {
    if (!v) return;
    svg.append(svgEl("rect", { class: v < 100 ? "partial" : "loss", x: x(i) - w / 2, y: H - B + 4, width: w, height: LOSS_H }));
  });

  const cursor = svgEl("line", { class: "cursor", y1: T, y2: H - B, visibility: "hidden" });
  svg.append(cursor);
  const tip = el("div", "tip");
  tip.hidden = true;
  svg.addEventListener("mousemove", (ev) => {
    const r = svg.getBoundingClientRect();
    const px = ((ev.clientX - r.left) / r.width) * W;
    const i = Math.round(((px - L) / (W - L - R)) * (n - 1));
    if (i < 0 || i >= n) return;
    cursor.setAttribute("x1", x(i));
    cursor.setAttribute("x2", x(i));
    cursor.setAttribute("visibility", "visible");
    tip.textContent = describe(t, i, state.end - (n - 1 - i) * state.cycle_s);
    tip.hidden = false;
    const left = (x(i) / W) * r.width;
    tip.style.left = `${Math.min(left + 8, r.width - tip.offsetWidth)}px`;
  });
  svg.addEventListener("mouseleave", () => {
    cursor.setAttribute("visibility", "hidden");
    tip.hidden = true;
  });
  box.replaceChildren(svg, tip);
}

function niceCeil(v) {
  const p = 10 ** Math.floor(Math.log10(v));
  for (const m of [1, 2, 2.5, 5, 10]) if (m * p >= v) return m * p;
  return 10 * p;
}

// ----- startup -------------------------------------------------------------------

$("#add").addEventListener("submit", async (ev) => {
  ev.preventDefault();
  const form = ev.target;
  $("#add-error").textContent = "";
  try {
    await call("POST", "api/targets", { name: form.name.value.trim(), host: form.host.value.trim(), tags: splitTags(form.tags.value) });
    form.reset();
  } catch (err) {
    $("#add-error").textContent = err.message;
    $("#add-error").classList.toggle("demo", state.read_only);
  }
});

// Only a new width changes the layout. A mobile browser resizes the height
// whenever its toolbar slides in or out during scrolling; re-rendering on that
// would fight the scroll.
const find = $("#find");
const sort = $("#sort");
const syncControls = () => {
  find.value = view.q;
  sort.value = view.sort;
};
find.addEventListener("input", () => setView(() => (view.q = find.value.trim())));
for (const [key, label] of Object.entries(SORTS)) sort.append(new Option(label, key));
syncControls();
sort.addEventListener("change", () => setView(() => (view.sort = sort.value)));
$("#order").addEventListener("click", () => setView(() => (view.rev = !view.rev)));
// A bookmark or a pasted link that differs only in the fragment does not
// reload the page.
window.addEventListener("hashchange", () => {
  Object.assign(view, parseView());
  syncControls();
  if (state) render();
});

let resizeTimer, renderedWidth = window.innerWidth;
window.addEventListener("resize", () => {
  clearTimeout(resizeTimer);
  resizeTimer = setTimeout(() => {
    if (!state || window.innerWidth === renderedWidth) return;
    renderedWidth = window.innerWidth;
    render();
  }, 150);
});

// A background tab does not poll; it catches up when shown again.
load();
setInterval(() => document.hidden || load(), REFRESH_MS);
document.addEventListener("visibilitychange", () => document.hidden || load());
