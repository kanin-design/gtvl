// GTVL's sound themes beside Pop: Wood, Glass, Drop, Click and Chime. Each is one instrument playing two sounds: "move"
// (focus moved with the D-pad, often many times a second while a direction is held) and "press" (OK).
//
//   wood   a soft felt mallet on a small wooden bar, marimba-like. Move: one short, muted note (A5). Press: a fifth lower
//          (D5), a softer stroke that rings a little longer: lower and rounder.
//   glass  a light fingernail tap on a glass: stemware modes (1 : 2.05 : 3.41 : 5.0), each a slowly beating pair, held in
//          the hand so it rings short. Move: a tiny high tink (a small glass, D7). Press: a fuller ping an octave lower (D6).
//   drop   a water droplet: the drop's tick on the surface and the Minnaert bubble it pinches off (f0 = 3.26 / radius),
//          rising in pitch as it floats up, the "bloop". Move: a small high droplet (2.6 mm). Press: a bigger, lower one
//          (5 mm). It rises where Pop falls.
//   click  a crisp, quiet mechanical switch (a premium keyboard, a camera dial): a cluster of micro-contacts through the
//          part's broad resonances, mostly noise, no ring. Move: a light tick. Press: a firmer two-part click, the
//          actuation then the bottom-out with the mass behind it.
//   chime  clean, soft sine tones, modern and minimal. Move: a short pure blip (D6). Press: two notes rising a fourth, A5
//          to D6, landing on the move's note.
//
// Made with the sound-design skill (~/.claude/skills/sound-design): candidates.mjs's felt mallet, phys.mjs's strike and
// contact, kit.mjs's burst, and decaying sines for the bubble and the chime. Every file is finished as a UI set the way Pop
// is (lib/ui.mjs: a small room, trimmed at both ends, matched by event loudness, true peak at most -1.5 dBTP).
//
// Levels follow Android's own tick, so switching between Android's sounds and these keeps the volume. The Shield's
// Effect_Tick.ogg (its sound for focus moves and OK alike) measures -35 LUFS event loudness, and Android plays its
// effects 6 dB down (config_soundEffectVolumeDb): about -41 as heard. Every move is matched to that, every press 1.5 dB
// over, as Pop's are. Moves fall 20 dB in 60 ms or less and are gone by about 150 ms, since they repeat fast; presses may
// ring to about 250 ms. Energy sits between about 300 Hz and 5 kHz (a TV's speakers or a soundbar), with soft onsets
// everywhere except the click's mechanical edge.
//
//   node tool/sounds/themes.mjs              -> assets/sounds/<theme>/move.wav and press.wav (mono, 48 kHz, 16-bit)
//   node tool/sounds/themes.mjs glass drop   -> only those themes
import path from 'path';
import { fileURLToPath } from 'url';

const LIB = process.env.HOME + '/.claude/skills/sound-design/scripts/lib/';
const { SR, TAU, midiHz, stereo } = await import(LIB + 'dsp.mjs');
const { strike, contact } = await import(LIB + 'phys.mjs');
const { burst } = await import(LIB + 'kit.mjs');
const { mallet } = await import(LIB + 'candidates.mjs');
const { finishUI } = await import(LIB + 'ui.mjs');
const { writeWav } = await import(LIB + 'io.mjs');

const OUT = path.join(path.dirname(fileURLToPath(import.meta.url)), '../../assets/sounds');
const HEARD = -41; // Android's tick as the TV plays it, event loudness (LUFS)
const MOVE = { lufs: HEARD, room: 0.1, wet: 0.04 }, PRESS = { lufs: HEARD + 1.5, room: 0.14, wet: 0.06 };

// one decaying sine into b at t s: a raised-cosine onset `att` s long, then exp(-t / tau). glide: the frequency at time s
// as a factor of f (a bubble's rise), so the phase follows it
function tone(b, t, f, { a = 1, tau, att = 0.003, glide }) {
  const i0 = Math.round(t * SR), n = Math.min(b.L.length - i0, Math.ceil((att + tau * 9.2) * SR));
  let ph = 0;
  for (let i = 0; i < n; i++) {
    const s = i / SR, on = s < att ? 0.5 - 0.5 * Math.cos(Math.PI * s / att) : 1;
    ph += f * (glide ? glide(s) : 1) / SR;
    const v = Math.sin(TAU * ph) * a * on * Math.exp(-s / tau);
    b.L[i0 + i] += v; b.R[i0 + i] += v;
  }
}

// ---------------------------------------------------------------------------------------------------------------- wood
// candidates.mjs's mallet: the bar's fundamental with a felt onset (1–3 ms, no click), the marimba's tuned partials two
// octaves and more up (1 : 4 : 10), the bar's own modes in wood (an object, not an oscillator) and the felt's breath.
// ring: the fundamental's decay (s): a muted note at 0.02 falls 20 dB in ~46 ms. Under it the knock of felt on wood
// (phys.mjs contact: a damped smear of broad resonances, no ring), about 20 dB down: what makes it a bar, not a tone
function wood(midi, { knock = 0.8, ...o }) {
  const b = stereo(o.ring * 12 + 0.2), f = midiHz(midi);
  mallet(b, 0, midi, { mat: 'wood', ...o });
  contact(b, 0, { size: 0.7, hardness: 0.35, body: 0, ring: 0, direct: 0, n: 8, q: [3, 8], tau: 0.004, grains: 1, pitch: f / 880 * 0.75, gain: knock, width: 0, seed: o.seed + 10 });
  return b;
}

// ---------------------------------------------------------------------------------------------------------------- glass
// a fingernail on a drinking glass: stemware's modes (phys.mjs wineglass: 1, 2.05, 3.41, 5.0), each a pair 0.18 % apart (a
// round object's modes beat slowly), struck through strike()'s modal resonators. Held in the hand, every mode rings about
// the same number of cycles (q = π·f·τ: ~180 on the tink, ~200 on the ping; glass reads from about 190 up, wood below
// 130), so τ falls as 1/f and the highs go first. The nail's contact (0.2–0.3 ms) is what rolls off the top modes (a half-sine that long is -6 dB near 4 kHz);
// a faint tick of the nail rides on top.
const GLASS = [[1, 1], [2.05, 0.3], [3.41, 0.12], [5.0, 0.05]];
function glass(f0, { ring, nail = 0.00025, amps = GLASS.map(g => g[1]), tick = 0.1, seed = 1 }) {
  const b = stereo(ring * 10 + 0.2), partials = [];
  GLASS.forEach(([r], k) => { const f = f0 * r, tau = ring / r; partials.push({ f, tau, a: amps[k] }, { f: f * 1.0018, tau, a: amps[k] * 0.45 }); });
  strike(b, 0, { partials, ct: nail, hardness: 0.5, width: 0, seed });
  let pk = 0; for (const v of b.L) pk = Math.max(pk, Math.abs(v));
  burst(b, 0, { tau: 0.0003, lo: 2500, hi: 7000, gain: tick * pk, attack: 0.0001, seed: seed + 1, width: 0 });
  return b;
}

// ---------------------------------------------------------------------------------------------------------------- drop
// a droplet: the drop's tiny tick on the surface, then the bubble it entrains (Minnaert, van den Doel): f0 = 3.26 / r, a
// damped sine whose pitch rises as the bubble floats up. A real bubble's damping is d = 0.043·f + 0.0014·f^1.5 per second
// (a 2.6 mm bubble: τ ≈ 9 ms); `ring` stretches it so the rise is heard as a bloop rather than a click. The rise starts
// as van den Doel's f0·(1 + σ·t) and levels off `rise` above f0 (time constant tr), so the faint tail doesn't whistle up.
// A 1 ms onset keeps it soft.
function drop({ r, ring = 1.8, rise, tr, tick = 0.12, seed = 1 }) {
  const f0 = 3.26 / r, tau = ring / (0.043 * f0 + 0.0014 * Math.pow(f0, 1.5)), b = stereo(tau * 10 + 0.1);
  burst(b, 0, { tau: 0.0004, lo: 1500, hi: 6000, gain: tick, attack: 0.0002, seed, width: 0 });
  tone(b, 0.0008, f0, { tau, att: 0.001, glide: s => 1 + rise * (1 - Math.exp(-s / tr)) });
  return b;
}

// ---------------------------------------------------------------------------------------------------------------- click
// phys.mjs's contact: a small hard contact is mostly noise (a real switch measures flatness ~0.35), a cluster of
// micro-contacts through the part's broad resonances, falling 20 dB in ~10 ms, with a little thump of the mass behind it.
// No ring (a bell-like ring reads as a tiny chime, not a switch). pitch and a 2-octave spread move the resonances down
// from a laptop key's ~6 kHz to about 0.8–3.5 kHz, the speaker's band, and little unfiltered noise (direct) leaves the
// edge crisp without hiss above it: 85 % of the energy sits under 4.3 kHz (so its flatness, measured to 12 kHz, reads
// 0.04–0.09 rather than a full-band switch's 0.35).
const click = parts => { const b = stereo(0.3); for (const [t, o] of parts) contact(b, t, { ring: 0, width: 0, ...o }); return b; };

// ---------------------------------------------------------------------------------------------------------------- chime
// pure sines: a soft 4 ms onset, an exponential fall, nothing else
const chime = notes => { const b = stereo(0.5); for (const [t, m, a, tau] of notes) tone(b, t, midiHz(m), { a, tau, att: 0.004 }); return b; };

const THEMES = {
  wood: {
    move: () => finishUI(wood(81, { ring: 0.02, hard: 0.4, seed: 1 }), { ...MOVE, hp: 200, lp: 6000 }),
    press: () => finishUI(wood(74, { ring: 0.045, hard: 0.2, seed: 2 }), { ...PRESS, hp: 160, lp: 3500 }),
  },
  glass: {
    move: () => finishUI(glass(midiHz(98), { ring: 0.024, amps: [1, 0.36, 0.14, 0.06], tick: 0.18, seed: 3 }), { ...MOVE, hp: 300, lp: 7000 }),
    press: () => finishUI(glass(midiHz(86), { ring: 0.055, amps: [1, 0.35, 0.16, 0.07], nail: 0.0002, tick: 0.12, seed: 4 }), { ...PRESS, hp: 250, lp: 7000 }),
  },
  drop: {
    move: () => finishUI(drop({ r: 0.0026, ring: 1.8, rise: 0.45, tr: 0.01, seed: 5 }), { ...MOVE, hp: 250, lp: 6000 }),
    press: () => finishUI(drop({ r: 0.005, ring: 1.6, rise: 0.5, tr: 0.018, tick: 0.1, seed: 6 }), { ...PRESS, hp: 200, lp: 6000 }),
  },
  click: {
    move: () => finishUI(click([[0, { size: 0.42, hardness: 0.85, body: 0.04, bodyF: 320, grains: 2, smear: 0.002, pitch: 0.45, spread: 2, direct: 0.03, seed: 7 }]]), { ...MOVE, hp: 250, lp: 5000 }),
    press: () => finishUI(click([
      [0, { size: 0.45, hardness: 0.85, body: 0.03, bodyF: 320, grains: 2, smear: 0.002, pitch: 0.5, spread: 2, direct: 0.03, gain: 0.8, seed: 8 }],
      [0.028, { size: 0.6, hardness: 0.75, body: 0.18, bodyF: 300, grains: 3, smear: 0.005, pitch: 0.42, spread: 2, direct: 0.02, seed: 9 }],
    ]), { ...PRESS, hp: 200, lp: 5000 }),
  },
  chime: {
    move: () => finishUI(chime([[0, 86, 1, 0.02]]), { ...MOVE, hp: 300 }),
    press: () => finishUI(chime([[0, 81, 1, 0.026], [0.07, 86, 0.9, 0.034]]), { ...PRESS, hp: 300 }),
  },
};

const only = process.argv.slice(2);
for (const bad of only.filter(id => !THEMES[id])) throw new Error(`no theme "${bad}" (${Object.keys(THEMES).join(', ')})`);
for (const [id, set] of Object.entries(THEMES)) {
  if (only.length && !only.includes(id)) continue;
  for (const [name, make] of Object.entries(set)) {
    const d = make(), file = path.join(OUT, id, `${name}.wav`);
    writeWav(file, d.buf, { channels: 1, bits: 16 });
    console.log(`${path.relative(process.cwd(), file).padEnd(30)} ${d.seconds.toFixed(3)} s  ${d.lufs.toFixed(1)} LUFS (event)  ${d.tp.toFixed(1)} dBTP${d.note}`);
  }
}
