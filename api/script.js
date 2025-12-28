/* Auto-update default highscoreable ID when the user toggles the highscoreable type */
const htype_select = document.getElementById("htype");
const hid_input  = document.getElementById("hid");
let hPristine = true;
if (htype_select && hid_input) {
  hid_input.addEventListener("input", () => {
    hPristine = false;
  });

  htype_select.addEventListener("change", () => {
    if (hPristine) {
      hid_input.value = htype_select.selectedOptions[0].dataset.default;
    }
  });
}

/* Change demo analysis view when the user toggles the select menu */
const analysis_select  = document.getElementById("demo-analysis-view");
const analysis_views = document.querySelectorAll("#demo-analysis-content [data-view]");
if (analysis_select && analysis_views) {
  function updateAnalysisView() {
    for (const view of analysis_views) {
      view.hidden = view.dataset.view !== analysis_select.value;
    }
  }
  analysis_select.addEventListener("change", updateAnalysisView);
  document.addEventListener("DOMContentLoaded", () => { analysis_select.value = 0; });
}

/* Kohina chiptune radio stream */
const partyButton = document.getElementById("partyButton");
const kohinaAudio = document.getElementById("kohina");

function playRadio() {
  kohinaAudio.play();
}

function stopRadio() {
  kohinaAudio.pause();
  kohinaAudio.currentTime = 0;
}

/**
 *                                FLOATING MOLES
 *                                --------------
 * Displays moving floaters on the page's background bouncing on the borders.
 * Floaters change their icon after bouncing on the border.
 * Clicking on a floater spawns 3 more in all opposite diagonal directions.
 */

const initialMoles = 16;
const dim = 16;
const files = ["moleBruh.png", "moleCool.png", "moleGasm.png", "moleSwole.png"]
const images = [];
const w = window.innerWidth;
const h = window.innerHeight;

let running = false;
let frame = null;

/* Extract a uniformly random sample from an array */
function sample(arr) {
  return arr[Math.floor(Math.random() * arr.length)];
}

/* Create a new floater on the screen with respect to another reference floater */
function create(ref, rx = 0, ry = 0) {
  const img = document.createElement("img");
  let name, x, y, dx, dy;
  if (ref) {
    name = ref.src;
    x    = ref.x;
    y    = ref.y;
    dx   = ref.dx * rx;
    dy   = ref.dy * ry;
  } else {
    name = 'img/emoji/' + sample(files);
    x    = Math.floor(Math.random() * (w - dim));
    y    = Math.floor(Math.random() * (h - dim));
    dx   = Math.floor((Math.random() * 1 + 1)) * (Math.random() < 0.5 ? -1 : 1);
    dy   = Math.floor((Math.random() * 1 + 1)) * (Math.random() < 0.5 ? -1 : 1);
  }
  const obj = { src: name, el: img, x: x, y: y, dx: dx, dy: dy };
  img.src = name;
  img.width = dim;
  img.height = dim;
  img.className = "floater";
  img.addEventListener("click", () => { create(obj, -1, 1); create(obj, 1, -1); create(obj, -1, -1); });
  document.body.appendChild(img);
  images.push(obj);
}

/* Start animating floaters */
function start() {
  for(let i = 0; i < initialMoles; i++) create();
  frame = requestAnimationFrame(animate);
}

/* Stop animating floaters */
function stop() {
  cancelAnimationFrame(frame);
  reset();
}

/* Show floaters on screen */
function show() {
  images.forEach(obj => { obj.el.style.display = "block"; });
}

/* Hide floaters off screen */
function hide() {
  images.forEach(obj => { obj.el.style.display = "none";  });
}

/* Remove all floaters */
function reset() {
  images.some((obj) => { obj.el.remove() });
  images.length = 0;
}

/* Change the icon of a given floater */
function change(obj) {
  obj.el.src = 'img/emoji/' + sample(files);
}

/* Toggle floaters and radio */
function toggle() {
  running = !running;
  if (running) {
    partyButton.setAttribute("src", "octicon/square-circle.svg")
    show();
    start();
    playRadio();
  } else {
    partyButton.setAttribute("src", "octicon/play.svg")
    hide();
    stop();
    stopRadio();
  }
}

/* Move a given floater and bounce it on the screen's borders */
function move(obj) {
  if (obj.x + dim >= w || obj.x <= 0) {
    obj.dx = -obj.dx;
    change(obj);
  }
  if (obj.y + dim >= h || obj.y <= 0) {
    obj.dy = -obj.dy;
    change(obj);
  }
  obj.x += obj.dx;
  obj.y += obj.dy;
  obj.el.style.left = obj.x + "px";
  obj.el.style.top = obj.y + "px";
}

/* Move all floaters and animate a new frame */
function animate() {
  if (!running) return;
  images.forEach(obj => move(obj));
  requestAnimationFrame(animate);
}

/* Button controls */
partyButton.addEventListener("click", toggle);