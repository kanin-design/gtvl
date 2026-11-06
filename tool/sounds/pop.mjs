// GTVL's test sound set "Pop": a soft pop when focus moves and a rounder, lower one for OK.
//
// Made with the sound-design skill's kit (~/.claude/skills/sound-design): a sine diving quickly in pitch (the pop),
// a breath of air on its start (the lips parting) and a small room, finished as a UI set (trimmed at both ends,
// matched by event loudness, true peak at most -1.5 dBTP).
//
// Levels follow Android's own tick, so switching between Android's sounds and these keeps the volume. The Shield's
// Effect_Tick.ogg (its sound for focus moves and OK alike) measures -35 LUFS event loudness, and Android plays its
// effects 6 dB down (config_soundEffectVolumeDb): about -41 as heard. The move pop is matched to that, OK 1.5 dB over.
//
//   node tool/sounds/pop.mjs            -> assets/sounds/pop/move.wav and press.wav (mono, 48 kHz, 16-bit)
import path from 'path';
import { fileURLToPath } from 'url';

const LIB = process.env.HOME + '/.claude/skills/sound-design/scripts/lib/';
const { stereo } = await import(LIB + 'dsp.mjs');
const { burst, dive } = await import(LIB + 'kit.mjs');
const { finishUI } = await import(LIB + 'ui.mjs');
const { writeWav } = await import(LIB + 'io.mjs');

const OUT = path.join(path.dirname(fileURLToPath(import.meta.url)), '../../assets/sounds/pop');
const HEARD = -41; // Android's tick as the TV plays it, event loudness (LUFS)

const SET = {
  // Heard on every move, often many a second: short (down 20 dB in about 40 ms) and in the tick's register.
  move: () => {
    const b = stereo(0.4);
    dive(b, 0, { f0: 1050, f1: 620, tp: 0.006, tau: 0.018, harm: 0.1 });
    burst(b, 0, { tau: 0.003, lo: 1500, hi: 7000, gain: 0.05, attack: 0.0005, seed: 3 });
    return finishUI(b, { lufs: HEARD, room: 0.12, wet: 0.05, hp: 200 });
  },
  // OK: a fifth lower, a little longer and fuller.
  press: () => {
    const b = stereo(0.4);
    dive(b, 0, { f0: 800, f1: 440, tp: 0.007, tau: 0.028, harm: 0.14 });
    burst(b, 0, { tau: 0.004, lo: 1200, hi: 6000, gain: 0.06, attack: 0.0005, seed: 5 });
    return finishUI(b, { lufs: HEARD + 1.5, room: 0.14, wet: 0.06, hp: 160 });
  },
};

for (const [name, make] of Object.entries(SET)) {
  const d = make(), file = path.join(OUT, `${name}.wav`);
  writeWav(file, d.buf, { channels: 1, bits: 16 });
  console.log(`${path.relative(process.cwd(), file)}  ${d.seconds.toFixed(3)} s  ${d.lufs.toFixed(1)} LUFS (event)  ${d.tp.toFixed(1)} dBTP${d.note}`);
}
