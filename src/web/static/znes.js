// The page's half of the emulator: a canvas, an audio device, a keyboard and
// a gamepad. Everything about *being an emulator* is on the other side of the
// wasm boundary, in the same `App` the desktop build runs; this file is the
// browser's answer to `SdlPlatform`, and it is deliberately about as clever.
//
// Three things here are not obvious, and each is explained where it happens:
//
//   - views into wasm memory go stale when the module allocates
//     (`refreshViews`),
//   - the browser's frame rate is not the console's, so frames are paced by
//     the clock rather than by `requestAnimationFrame` (`loop`), and
//   - the audio queue's depth has to come back from the audio thread
//     (`onAudioReport`).

// These five are facts about the console and the app, not choices made here.
// The canvas and the audio device are both set up before the module finishes
// loading, so they cannot simply be read out of it -- instead `checkAgainstModule`
// asks the module for each one at startup and refuses to run on a mismatch.
// Their exports are `znesScreenWidth` and friends.
const SCREEN_WIDTH = 256;
const SCREEN_HEIGHT = 240;
const PLAYER_COUNT = 2;
const SAMPLE_RATE = 44100;
const NES_FPS = 60.0988;

const FRAME_MS = 1000 / NES_FPS;

// Whole-pixel magnification. The canvas is sized in device pixels to match,
// so nothing is ever resampled. This one really is the page's own choice.
const SCALE = 3;

// Longest run the clock may ask for in one animation frame. A tab that was
// in the background comes back with an arbitrarily large gap, and running it
// out would be a freeze; the time is dropped instead.
const MAX_FRAMES_PER_TURN = 4;

// `interface.Overlay.Placement`, in declaration order.
const PLACEMENT = ["top_left", "bottom_left", "center"];

// `SdlPlatform`'s overlay metrics, in the console's own 256x240 coordinates,
// so that both platforms lay text out the same way.
//
// `FONT_SIZE` is where the two part company. On the desktop the same number is
// a character *width*, because SDL's debug font is a bitmap whose glyphs
// advance by exactly their size. Here it is the size asked of whatever
// monospace face the browser has, and those advance by around 0.6 of it -- so
// a width has to be measured rather than counted from it. See `drawBlock`.
const FONT_SIZE = 8;
const LINE_HEIGHT = 10;
const MARGIN = 6;

const canvas = document.getElementById("screen");
const picker = document.getElementById("picker");
const loadButton = document.getElementById("load");
const context = canvas.getContext("2d", { alpha: false });

// The video is written at the console's resolution and blown up on the way to
// the canvas, so that the overlay text on top of it can use the canvas's full
// resolution instead of the console's.
const backing = new OffscreenCanvas(SCREEN_WIDTH, SCREEN_HEIGHT);
const backingContext = backing.getContext("2d", { alpha: false });

const decoder = new TextDecoder();
const encoder = new TextEncoder();

let wasm = null;

// --- Views into wasm memory ----------------------------------------------

// Typed arrays over the module's memory are detached the moment it grows, and
// it grows whenever the emulator allocates -- loading a ROM, parsing a movie.
// So the buffer they were built over is remembered, and they are rebuilt as
// soon as it is replaced. Every call that can allocate is followed by a
// `refreshViews`, and so is every frame, which costs nothing when nothing has
// changed.
let viewedBuffer = null;
let framebuffer = null;
let frame = null;

function refreshViews() {
  if (wasm === null || viewedBuffer === wasm.memory.buffer) return;
  viewedBuffer = wasm.memory.buffer;
  framebuffer = new Uint8ClampedArray(
    viewedBuffer,
    wasm.znesFramebuffer(),
    SCREEN_WIDTH * SCREEN_HEIGHT * 4,
  );
  frame = new ImageData(framebuffer, SCREEN_WIDTH, SCREEN_HEIGHT);
}

// Reads a UTF-8 string out of the module. Takes a fresh view every time
// rather than a cached one, because this is called from inside wasm calls,
// where a `refreshViews` has not had its turn yet.
function readString(pointer, length) {
  return decoder.decode(new Uint8Array(wasm.memory.buffer, pointer, length));
}

// --- Battery saves -------------------------------------------------------

// Prefix for save keys in `localStorage`, so nothing else the origin stores
// can be mistaken for one.
const SAVE_PREFIX = "znes.sav:";

// Where the save as it stood when a cartridge was loaded is kept. A separate
// prefix rather than a suffix, so a ROM whose own name ends in `.bak` cannot
// land on another game's backup.
const BACKUP_PREFIX = "znes.sav.bak:";

// `localStorage` holds strings, and a cartridge's RAM is arbitrary bytes, so
// each save is stored base64-encoded. `btoa`/`atob` want one character per
// byte, which is what these two conversions are for.
function bytesToBase64(bytes) {
  let text = "";
  // In chunks, because spreading 32768 arguments into `String.fromCharCode`
  // overflows the argument limit in some engines.
  for (let i = 0; i < bytes.length; i += 4096) {
    text += String.fromCharCode(...bytes.subarray(i, i + 4096));
  }
  return btoa(text);
}

function base64ToBytes(text) {
  const raw = atob(text);
  const bytes = new Uint8Array(raw.length);
  for (let i = 0; i < raw.length; i++) bytes[i] = raw.charCodeAt(i);
  return bytes;
}

// How many bytes a stored save holds, without decoding it: four characters
// carry three bytes, so the length follows from the string's own length and
// its padding. Negative for anything this file did not write.
function base64ByteLength(text) {
  if (text.length === 0 || text.length % 4 !== 0) return -1;
  const padding = text.endsWith("==") ? 2 : text.endsWith("=") ? 1 : 0;
  return (text.length / 4) * 3 - padding;
}

// The slot names as they stood when the module began a walk. Taken once so a
// slot moving part-way through cannot make the walk skip or repeat another.
let slotSnapshot = [];

function slotNames() {
  const names = [];
  try {
    for (let i = 0; i < localStorage.length; i++) {
      const key = localStorage.key(i);
      // `BACKUP_PREFIX` is not a prefix of `SAVE_PREFIX` -- they part at the
      // separator -- so the backups stay out of the walk.
      if (key !== null && key.startsWith(SAVE_PREFIX)) {
        names.push(key.slice(SAVE_PREFIX.length));
      }
    }
  } catch {
    // Storage can be disabled outright (private browsing, a blocked origin).
    // Then there are simply no saves.
    return [];
  }
  return names;
}

// --- Audio ---------------------------------------------------------------

let audio = null;
let node = null;

// Samples handed to the worklet since the last clear, and the worklet's own
// running total of samples played. Their difference is the queue depth the
// emulator steers on -- see `audio-worklet.js` for why totals and not a
// fill level.
let written = 0;
let consumed = 0;

// Brings up the audio graph, or gives up and leaves the emulator silent.
//
// Failing here must not stop the emulator: a browser that will not give us
// an audio device at this sample rate is still perfectly able to run a game,
// and `queueAudio` and friends already do nothing while `node` is null.
async function startAudio() {
  try {
    audio = new AudioContext({ sampleRate: SAMPLE_RATE, latencyHint: "interactive" });
    await audio.audioWorklet.addModule("./audio-worklet.js");
    node = new AudioWorkletNode(audio, "znes", { numberOfInputs: 0, outputChannelCount: [1] });
    node.port.onmessage = onAudioReport;
    node.connect(audio.destination);
  } catch (error) {
    console.error("znes: no audio:", error);
    audio = null;
    node = null;
  }
}

function onAudioReport({ data }) {
  consumed = data;
}

// Starts the audio device, and does not come back until it is really
// running.
//
// The browser will not start one until the user has done something, so the
// first gesture that reaches us resumes it. Loading a ROM is itself a
// gesture, which is why nothing is ever heard too late.
//
// Waiting for the device rather than just asking it to start is what keeps
// the emulator from getting ahead of it. A suspended device consumes
// nothing, so every frame that runs before it wakes up leaves another
// frame's worth of samples in the queue -- and since the resampling
// correction is capped at 1%, an extra tenth of a second of latency picked
// up here takes several seconds of play to drain back off.
async function resumeAudio() {
  if (audio === null || audio.state === "running") return;
  try {
    await audio.resume();
  } catch (error) {
    console.error("znes: cannot start audio:", error);
  }
}

// --- Input ---------------------------------------------------------------

// Bit positions in `input.Buttons`, which is also `Controller.Button`'s
// order, which is the order the console's shift register reports.
const BUTTONS = { a: 0, b: 1, select: 2, start: 3, up: 4, down: 5, left: 6, right: 7 };

// Player 1's keyboard, matching the desktop build's. Player 2 has none: two
// people cannot comfortably share one keyboard's modifier keys.
const KEYS = {
  KeyZ: "a",
  KeyX: "b",
  ShiftRight: "select",
  Enter: "start",
  ArrowUp: "up",
  ArrowDown: "down",
  ArrowLeft: "left",
  ArrowRight: "right",
};

let keyboardMask = 0;

// How far a stick has to leave centre before it counts as a direction, on
// the Gamepad API's -1..1 scale. Sticks rest noisily and the console's d-pad
// has no in-between, so the threshold sits well past the slack of a worn
// stick.
const STICK_THRESHOLD = 0.25;

// A gamepad's buttons, in NES terms. The console's B sits left of its A, so
// they go on the west/south and east/north halves of the face -- the layout
// every other emulator defaults to, and the one `SdlPlatform.padButtons`
// uses.
function padMask(pad) {
  const pressed = (i) => pad.buttons.length > i && pad.buttons[i].pressed;
  const axis = (i) => (pad.axes.length > i ? pad.axes[i] : 0);
  let mask = 0;
  const set = (name, held) => {
    if (held) mask |= 1 << BUTTONS[name];
  };
  set("a", pressed(1) || pressed(3));
  set("b", pressed(0) || pressed(2));
  set("select", pressed(8));
  set("start", pressed(9));
  set("up", pressed(12) || axis(1) <= -STICK_THRESHOLD);
  set("down", pressed(13) || axis(1) >= STICK_THRESHOLD);
  set("left", pressed(14) || axis(0) <= -STICK_THRESHOLD);
  set("right", pressed(15) || axis(0) >= STICK_THRESHOLD);
  return mask;
}

// Where the light gun is pointing, in the console's own pixels. Kept up to
// date by the pointer handlers and pushed in once per frame, like everything
// else here.
//
// The trigger survives the pointer leaving the canvas: squeezing while
// pointed away from the screen is how a player deliberately misses, and
// games rely on being able to tell that from a shot at something black.
const gun = { x: 0, y: 0, onScreen: false, trigger: false };

// Maps a pointer event onto the canvas's own 256x240 grid. The canvas may be
// any size on the page, so this goes through its laid-out rectangle rather
// than through the backing store's dimensions.
function aimAt(event) {
  const rect = canvas.getBoundingClientRect();
  if (rect.width === 0 || rect.height === 0) return;
  const x = Math.floor(((event.clientX - rect.left) / rect.width) * SCREEN_WIDTH);
  const y = Math.floor(((event.clientY - rect.top) / rect.height) * SCREEN_HEIGHT);
  gun.onScreen = x >= 0 && x < SCREEN_WIDTH && y >= 0 && y < SCREEN_HEIGHT;
  if (gun.onScreen) {
    gun.x = x;
    gun.y = y;
  }
}

// Pushes both ports' buttons in, keyboard and gamepads combined, plus the
// gun. The keyboard is player 1 and each gamepad takes the next port, and a
// pad never takes the keyboard away from player 1.
function pushInput() {
  const pads = navigator.getGamepads().filter((pad) => pad !== null);
  for (let player = 0; player < PLAYER_COUNT; player++) {
    const fromPad = player < pads.length ? padMask(pads[player]) : 0;
    wasm.znesSetButtons(player, player === 0 ? keyboardMask | fromPad : fromPad);
  }
  wasm.znesSetGun(gun.x, gun.y, gun.onScreen, gun.trigger);
}

// --- Files ---------------------------------------------------------------

// Hands a file to the emulator: name first, contents straight after, in one
// buffer the module reserved for us.
async function open(file) {
  const bytes = new Uint8Array(await file.arrayBuffer());
  const name = encoder.encode(file.name);

  // Before the module is touched at all, and deliberately so. Opening the
  // file primes the audio queue, which is only worth doing against a device
  // that has started -- and this is the last point where waiting is free,
  // since every `await` below here is a chance for a frame to run and grow
  // the memory that the views below are taken over.
  await resumeAudio();

  const pointer = wasm.znesReserve(name.length + bytes.length);
  if (pointer === 0) {
    console.error("znes: not enough memory for", file.name);
    return;
  }
  // After the reserve, because reserving may have grown -- and so replaced --
  // the memory this view is taken over.
  const staging = new Uint8Array(wasm.memory.buffer, pointer, name.length + bytes.length);
  staging.set(name, 0);
  staging.set(bytes, name.length);

  wasm.znesOpen(name.length, bytes.length);
  refreshViews();
}

// --- Drawing -------------------------------------------------------------

let shownTitle = "";

function draw() {
  backingContext.putImageData(frame, 0, 0);
  context.imageSmoothingEnabled = false;
  context.drawImage(backing, 0, 0, canvas.width, canvas.height);
  drawOverlays();

  const title = readString(wasm.znesTitlePtr(), wasm.znesTitleLen());
  if (title !== shownTitle) {
    shownTitle = title;
    document.title = title;
  }
}

// Draws this frame's overlays, decoding the blocks `WebPlatform` packed:
//
//     block := placement:u8, line_count:u8, line*
//     line  := byte_length:u16le, utf8_bytes
function drawOverlays() {
  const length = wasm.znesOverlayLen();
  if (length === 0) return;
  const bytes = new Uint8Array(wasm.memory.buffer, wasm.znesOverlayPtr(), length);

  context.font = `${FONT_SIZE * SCALE}px monospace`;
  context.textBaseline = "top";

  let at = 0;
  while (at < length) {
    const placement = PLACEMENT[bytes[at++]];
    const lineCount = bytes[at++];
    const lines = [];
    for (let i = 0; i < lineCount; i++) {
      const lineLength = bytes[at] | (bytes[at + 1] << 8);
      at += 2;
      lines.push(decoder.decode(bytes.subarray(at, at + lineLength)));
      at += lineLength;
    }
    drawBlock(lines, placement);
  }
}

// The same layout `SdlPlatform.drawOverlay` uses, in the same coordinates,
// scaled up on the way out. Including the drop shadow: the text has to stay
// readable over whatever the game happens to be drawing underneath it.
function drawBlock(lines, placement) {
  const blockHeight = lines.length * LINE_HEIGHT;
  let y =
    placement === "top_left"
      ? MARGIN
      : placement === "bottom_left"
        ? SCREEN_HEIGHT - MARGIN - blockHeight
        : (SCREEN_HEIGHT - blockHeight) / 2;

  for (const line of lines) {
    // Measured, not counted: see `FONT_SIZE`. Counting characters overstates
    // the width by about two thirds, and half of that error is how far left
    // of centre a centred line lands.
    //
    // In device pixels, since that is what `measureText` answers in.
    const left =
      placement === "center"
        ? (SCREEN_WIDTH * SCALE - context.measureText(line).width) / 2
        : MARGIN * SCALE;
    const top = y * SCALE;
    context.fillStyle = "#000";
    context.fillText(line, left + SCALE, top + SCALE);
    context.fillStyle = "#fff";
    context.fillText(line, left, top);
    y += LINE_HEIGHT;
  }
}

// --- The loop ------------------------------------------------------------

// Real time owed to the console, in milliseconds.
let owed = 0;
let previous = 0;

// One animation frame's worth of work.
//
// `requestAnimationFrame` runs at the *display's* rate, which is 60 Hz, or
// 120 on a machine that can manage it, and is never the console's 60.0988.
// So the callback is used only as a chance to act, and how much to run is
// worked out from the clock: usually one frame, occasionally none or two.
// Pacing the console by the display instead would run it 0.16% slow on a
// 60 Hz panel and twice as fast on a 120 Hz one.
//
// The audio device's clock is a third rate again, and the drift between it
// and this one is what `App`'s resampling feedback exists to absorb.
function loop(now) {
  requestAnimationFrame(loop);

  owed += Math.min(now - previous, MAX_FRAMES_PER_TURN * FRAME_MS);
  previous = now;

  pushInput();

  let ran = 0;
  while (owed >= FRAME_MS && ran < MAX_FRAMES_PER_TURN) {
    wasm.znesTick();
    owed -= FRAME_MS;
    ran++;
  }
  // Whatever is still owed after hitting the cap is a debt this machine has
  // shown it cannot pay, and carrying it forward would only mean running the
  // cap out again next turn, for as long as things stay slow. Better to lose
  // the time and stay responsive.
  if (ran === MAX_FRAMES_PER_TURN) owed = 0;

  // Nothing new to show: leave the canvas alone rather than repaint the same
  // picture at the display's rate.
  if (ran === 0) return;

  refreshViews();
  draw();
}

// --- Startup -------------------------------------------------------------

const imports = {
  znes: {
    report(pointer, length) {
      console.error(readString(pointer, length));
    },

    queueAudio(pointer, length) {
      if (node === null) return;
      // Copied out of wasm memory and handed over, not shared: the module
      // will overwrite these bytes on the next frame.
      const samples = new Float32Array(wasm.memory.buffer, pointer, length).slice();
      written += length;
      node.port.postMessage(samples, [samples.buffer]);
    },

    clearAudio() {
      if (node === null) return;
      written = 0;
      consumed = 0;
      node.port.postMessage("clear");
    },

    queuedAudioSamples() {
      // The worklet's report is up to one report interval old, so this can
      // read a little high; the feedback it feeds has a two-second time
      // constant and does not care. It can also read negative for the moment
      // after a clear, before the worklet has acknowledged it.
      return Math.max(0, written - consumed);
    },

    saveCount() {
      slotSnapshot = slotNames();
      return slotSnapshot.length;
    },

    saveNameAt(index, pointer, length) {
      const name = slotSnapshot[index];
      if (name === undefined) return 0;
      const bytes = encoder.encode(name);
      if (bytes.length > length) return 0;
      new Uint8Array(wasm.memory.buffer, pointer, bytes.length).set(bytes);
      return bytes.length;
    },

    saveRead(namePointer, nameLength, intoPointer, intoLength) {
      let stored;
      try {
        stored = localStorage.getItem(SAVE_PREFIX + readString(namePointer, nameLength));
      } catch {
        return 0;
      }
      if (stored === null) return 0;

      const total = base64ByteLength(stored);
      if (total <= 0) return 0;

      const wanted = Math.min(total, intoLength);
      if (wanted > 0) {
        // The walk asks for a header and nothing else, and base64 carries
        // three bytes per four characters, so the leading bytes decode
        // without touching the rest of a 32 KiB save.
        const chars = Math.min(Math.ceil(wanted / 3) * 4, stored.length);
        let bytes;
        try {
          bytes = base64ToBytes(stored.slice(0, chars));
        } catch {
          return 0;
        }
        if (bytes.length < wanted) return 0;
        new Uint8Array(wasm.memory.buffer, intoPointer, wanted).set(bytes.subarray(0, wanted));
      }
      // The slot's whole length, not the part copied: the module decides
      // whether a save fits from this, and a truncated answer would look like
      // a save of exactly the size it asked for.
      return total;
    },

    saveWrite(namePointer, nameLength, pointer, length) {
      const key = SAVE_PREFIX + readString(namePointer, nameLength);
      const bytes = new Uint8Array(wasm.memory.buffer, pointer, length);
      try {
        localStorage.setItem(key, bytesToBase64(bytes));
      } catch (error) {
        // Over quota, or storage disabled. Nothing the player can do about it
        // from here, and this runs at most once a second, so it is logged
        // rather than shown.
        console.warn("znes: cannot save:", error);
      }
    },

    saveRename(fromPointer, fromLength, toPointer, toLength) {
      const from = SAVE_PREFIX + readString(fromPointer, fromLength);
      const to = SAVE_PREFIX + readString(toPointer, toLength);
      if (from === to) return;
      try {
        const stored = localStorage.getItem(from);
        if (stored === null) return;
        // Written before the old key goes, so a failure here leaves the save
        // where it was rather than nowhere at all.
        localStorage.setItem(to, stored);
        localStorage.removeItem(from);
      } catch (error) {
        console.warn("znes: cannot move save:", error);
      }
    },

    saveKeepGeneration(namePointer, nameLength) {
      const name = readString(namePointer, nameLength);
      try {
        const stored = localStorage.getItem(SAVE_PREFIX + name);
        if (stored === null) return;
        localStorage.setItem(BACKUP_PREFIX + name, stored);
      } catch {
        // A backup that cannot be written is no reason to refuse the load.
      }
    },
  },
};

// Confirms the constants above still match the module's. Each of them is a
// value this file needs before the module has finished loading -- to size a
// canvas, to open an audio device -- so they are written down twice by
// necessity. Checking beats hoping: a mismatch is otherwise silent, and shows
// up as a stretched picture or audio that drifts out over minutes.
function checkAgainstModule() {
  const expected = [
    ["screen width", SCREEN_WIDTH, wasm.znesScreenWidth()],
    ["screen height", SCREEN_HEIGHT, wasm.znesScreenHeight()],
    ["player count", PLAYER_COUNT, wasm.znesPlayerCount()],
    ["sample rate", SAMPLE_RATE, wasm.znesSampleRate()],
    // A float, so compared to the precision it is written down at here.
    ["frame rate", NES_FPS, Math.round(wasm.znesFrameRate() * 1e4) / 1e4],
  ];
  const wrong = expected.filter(([, page, module]) => page !== module);
  for (const [name, page, module] of wrong) {
    console.error(`znes.js has ${name} ${page}, the module has ${module}`);
  }
  return wrong.length === 0;
}

async function main() {
  await startAudio();

  const { instance } = await WebAssembly.instantiateStreaming(fetch("./znes.wasm"), imports);
  wasm = instance.exports;
  if (!checkAgainstModule()) return;
  if (!wasm.znesInit()) return;
  refreshViews();

  addEventListener("keydown", (event) => {
    if (event.repeat) return;
    resumeAudio();
    if (event.code === "KeyR") {
      wasm.znesPressConsoleButton(event.shiftKey);
      return;
    }
    // Ctrl/Cmd, so that it stays clear of KeyZ's day job as the A button.
    // Nothing on a cartridge says whether it wants a Zapper.
    if (event.code === "KeyZ" && (event.ctrlKey || event.metaKey)) {
      wasm.znesCyclePeripherals();
      event.preventDefault();
      return;
    }
    const button = KEYS[event.code];
    if (button === undefined) return;
    keyboardMask |= 1 << BUTTONS[button];
    event.preventDefault();
  });

  addEventListener("keyup", (event) => {
    const button = KEYS[event.code];
    if (button === undefined) return;
    keyboardMask &= ~(1 << BUTTONS[button]);
    event.preventDefault();
  });

  // The gun. Pointer events rather than mouse ones, so a touchscreen aims
  // too, and the release is watched on the window so that letting go outside
  // the canvas still counts.
  canvas.addEventListener("pointermove", aimAt);
  canvas.addEventListener("pointerdown", (event) => {
    resumeAudio();
    aimAt(event);
    gun.trigger = true;
    event.preventDefault();
  });
  addEventListener("pointerup", () => {
    gun.trigger = false;
  });
  canvas.addEventListener("pointerleave", () => {
    gun.onScreen = false;
  });

  // Dropping a file is the main way in; clicking opens a picker, which is the
  // only way in on a machine with no files to drag from.
  addEventListener("dragover", (event) => {
    event.preventDefault();
    document.body.classList.add("dragging");
  });
  addEventListener("dragleave", () => document.body.classList.remove("dragging"));
  addEventListener("drop", (event) => {
    event.preventDefault();
    document.body.classList.remove("dragging");
    const file = event.dataTransfer.files[0];
    if (file !== undefined) open(file);
  });

  // A button rather than the canvas itself: a canvas that opened a file
  // dialog every time it was clicked would be unusable to play on.
  loadButton.addEventListener("click", () => {
    resumeAudio();
    picker.click();
  });
  picker.addEventListener("change", () => {
    if (picker.files[0] !== undefined) open(picker.files[0]);
    // Cleared so that picking the same file twice still counts as a change,
    // which is how a ROM gets reloaded after being edited.
    picker.value = "";
  });

  previous = performance.now();
  requestAnimationFrame(loop);
}

main();
