#!/usr/bin/env python3
"""Synthesises AeroPA's original placeholder sound effects (no samples used).

Output: AeroPA/Resources/Shared/GenericPack/SFX/*.wav
  chime.wav          single cabin chime (two-partial bell, ~1.6 s)
  double_chime.wav   high-low chime pair
  seatbelt.wav       short seatbelt-sign ding
  cabin_ambience.wav seamless 30 s loop: filtered noise + low engine drone
Usage: python3 Tools/generate_sounds.py
"""
import math, os, random, struct, wave

OUT = os.path.join(os.path.dirname(__file__), "..", "AeroPA", "Resources", "Shared", "GenericPack", "SFX")
RATE = 44100

def write(name, samples, rate=RATE):
    os.makedirs(OUT, exist_ok=True)
    peak = max(1e-9, max(abs(s) for s in samples))
    gain = 0.89 / peak
    with wave.open(os.path.join(OUT, name), "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(rate)
        w.writeframes(b"".join(struct.pack("<h", int(max(-1, min(1, s * gain)) * 32767)) for s in samples))

def bell(freq, dur, decay=2.6):
    n = int(RATE * dur)
    out = []
    for i in range(n):
        t = i / RATE
        env = math.exp(-decay * t) * min(1, t / 0.004)
        s = (math.sin(2 * math.pi * freq * t) + 0.35 * math.sin(2 * math.pi * freq * 2.76 * t) * math.exp(-4 * t)
             + 0.15 * math.sin(2 * math.pi * freq * 5.4 * t) * math.exp(-9 * t))
        out.append(s * env)
    return out

def mix(a, b, offset):
    n = max(len(a), offset + len(b))
    out = [0.0] * n
    for i, s in enumerate(a): out[i] += s
    for i, s in enumerate(b): out[offset + i] += s
    return out

def ambience(seconds=30, rate=22050):
    random.seed(7)
    n = int(seconds * rate)
    brown, lp, out = 0.0, 0.0, []
    for i in range(n):
        brown = (brown + random.uniform(-1, 1) * 0.02) * 0.998   # brown noise (airflow rumble)
        lp += 0.08 * (random.uniform(-1, 1) - lp)                 # soft hiss (air conditioning)
        t = i / rate
        drone = 0.05 * math.sin(2 * math.pi * 92 * t) + 0.03 * math.sin(2 * math.pi * 184.5 * t)
        out.append(brown * 1.0 + lp * 0.25 + drone * (0.9 + 0.1 * math.sin(2 * math.pi * 0.07 * t)))
    # Seamless loop: crossfade the last 2 s into the start.
    fade = int(2 * rate)
    head = out[:fade]
    body = out[fade:]
    for i in range(fade):
        x = i / fade
        body[len(body) - fade + i] = body[len(body) - fade + i] * math.cos(x * math.pi / 2) + head[i] * math.sin(x * math.pi / 2)
    return body, rate

if __name__ == "__main__":
    write("chime.wav", bell(988, 1.6))                                   # B5
    write("double_chime.wav", mix(bell(1175, 1.4), bell(880, 1.6), int(0.42 * RATE)))
    write("seatbelt.wav", bell(1319, 0.9, decay=4.0))
    amb, r = ambience()
    write("cabin_ambience.wav", [s * 0.6 for s in amb], rate=r)
    print("Wrote sounds to", os.path.abspath(OUT))
