#!/usr/bin/env python3
"""
music-analyzer.py — Kombinierte MIDI+MP3 Analyse mit Thinking
Pipeline: MIDI/MP3 → Music21 (Notation) + FluidSynth (Audio) → Qwen2.5-Omni + Qwen3
"""

import asyncio
import base64
import json
import subprocess
import sys
import tempfile
from pathlib import Path

import httpx

AGENT_URL  = "http://127.0.0.1:8100/v1/chat/completions"  # Qwen3-14B Thinking
AUDIO_URL  = "http://127.0.0.1:8101/v1/chat/completions"  # Qwen2.5-Omni Audio
SOUNDFONT  = "/usr/share/soundfonts/FluidR3_GM.sf2"
TIMEOUT    = 120.0


# ── MIDI Analyse (symbolisch via music21) ────────────────────────────────────

def analyze_midi_symbolic(midi_path: Path) -> dict:
    """Extrahiert Notation, Harmonik, Struktur aus MIDI via music21."""
    try:
        import music21 as m21
        score = m21.converter.parse(str(midi_path))
        analysis = {}

        # Tonart
        try:
            key = score.analyze("key")
            analysis["key"] = f"{key.tonic.name} {key.mode}"
            analysis["key_confidence"] = round(key.correlationCoefficient, 3)
        except Exception:
            analysis["key"] = "unbekannt"

        # Tempo
        tempos = [t.number for t in score.flat.getElementsByClass(m21.tempo.MetronomeMark)]
        analysis["tempos_bpm"] = tempos if tempos else ["unbekannt"]

        # Taktart
        ts = score.flat.getElementsByClass(m21.meter.TimeSignature)
        analysis["time_signatures"] = list({str(t) for t in ts})

        # Instrumente / Parts
        parts = []
        for p in score.parts:
            name = p.partName or p.id or "Part"
            note_count = len(p.flat.notes)
            parts.append({"name": name, "notes": note_count})
        analysis["parts"] = parts

        # Akkord-Progression (erste 20 Akkorde)
        try:
            chords = score.chordify()
            chord_list = []
            for c in chords.flat.getElementsByClass(m21.chord.Chord)[:20]:
                chord_list.append(c.pitches[0].name if c.pitches else "?")
            analysis["chord_progression_sample"] = chord_list
        except Exception:
            analysis["chord_progression_sample"] = []

        # Grundlegende Statistiken
        all_notes = score.flat.notes
        analysis["total_notes"] = len(all_notes)
        analysis["duration_seconds"] = round(float(score.duration.quarterLength) * 0.5, 1)

        return analysis

    except Exception as e:
        return {"error": str(e)}


def midi_to_audio(midi_path: Path, out_path: Path) -> bool:
    """Konvertiert MIDI zu WAV via FluidSynth."""
    sf = SOUNDFONT
    if not Path(sf).exists():
        for candidate in [
            "/usr/share/soundfonts/FluidR3_GM.sf2",
            "/usr/share/sounds/sf2/FluidR3_GM.sf2",
            "/usr/share/soundfonts/GeneralUser_GS.sf2",
        ]:
            if Path(candidate).exists():
                sf = candidate
                break
        else:
            return False

    result = subprocess.run(
        ["fluidsynth", "-ni", sf, str(midi_path), "-F", str(out_path), "-r", "22050"],
        capture_output=True, timeout=60
    )
    return result.returncode == 0 and out_path.exists()


# ── Audio Analyse via Qwen2.5-Omni ──────────────────────────────────────────

async def analyze_audio_with_llm(audio_path: Path, context: str = "") -> str:
    """Sendet Audio an Qwen2.5-Omni für musikalische Analyse."""
    audio_b64 = base64.b64encode(audio_path.read_bytes()).decode()
    suffix = audio_path.suffix.lower().lstrip(".")
    data_uri = f"data:audio/{suffix};base64,{audio_b64}"

    prompt = (
        "Analysiere dieses Musikstück detailliert:\n"
        "- Genre und Stil\n"
        "- Stimmung und Emotionen\n"
        "- Rhythmus und Tempo\n"
        "- Instrumentierung (was hörst du?)\n"
        "- Struktur (Intro, Verse, Chorus, etc.)\n"
        "- Auffällige musikalische Merkmale\n"
    )
    if context:
        prompt += f"\nZusatzkontext (MIDI-Analyse): {context}"

    messages = [{"role": "user", "content": [
        {"type": "audio_url", "audio_url": {"url": data_uri}},
        {"type": "text", "text": prompt},
    ]}]

    async with httpx.AsyncClient(timeout=TIMEOUT) as client:
        resp = await client.post(AUDIO_URL, json={
            "model": "audio",
            "messages": messages,
            "max_tokens": 1024,
            "chat_template_kwargs": {"enable_thinking": True},
        })
        resp.raise_for_status()
        return resp.json()["choices"][0]["message"]["content"]


# ── Synthese + Thinking via Qwen3 ────────────────────────────────────────────

async def synthesize_analysis(symbolic: dict, audio_analysis: str, filename: str) -> str:
    """Kombiniert beide Analysen zu einer Gesamtanalyse mit Qwen3-Thinking."""
    symbolic_text = json.dumps(symbolic, ensure_ascii=False, indent=2)

    prompt = f"""Du bist ein Musik-Analytiker. Analysiere '{filename}' umfassend.

## Symbolische MIDI-Analyse (Notation/Struktur):
{symbolic_text}

## Audio-Analyse (Klang/Interpretation):
{audio_analysis}

Erstelle eine vollständige musikalische Analyse mit:
1. **Gesamtbewertung** — Was für ein Stück ist das?
2. **Harmonik** — Tonart, Akkordfolgen, Modulationen
3. **Rhythmus & Metrum** — Takt, Tempo, rhythmische Patterns
4. **Klangbild** — Instrumentierung, Dynamik, Textur
5. **Form & Struktur** — Aufbau des Stücks
6. **Emotionale Wirkung** — Stimmung, Charakter
7. **Stilistische Einordnung** — Genre, Epoche, Einflüsse"""

    async with httpx.AsyncClient(timeout=TIMEOUT) as client:
        resp = await client.post(AGENT_URL, json={
            "model": "agent",
            "messages": [{"role": "user", "content": prompt}],
            "max_tokens": 2048,
        })
        resp.raise_for_status()
        return resp.json()["choices"][0]["message"]["content"]


# ── Hauptpipeline ────────────────────────────────────────────────────────────

async def analyze_music_file(file_path: str) -> str:
    path = Path(file_path)
    if not path.exists():
        return f"Fehler: Datei nicht gefunden: {file_path}"

    suffix = path.suffix.lower()
    symbolic = {}
    audio_path = path

    with tempfile.TemporaryDirectory() as tmpdir:
        tmp = Path(tmpdir)

        if suffix in (".mid", ".midi"):
            print(f"[analyzer] MIDI erkannt: {path.name}")
            print("[analyzer] Symbolische Analyse via music21...")
            symbolic = analyze_midi_symbolic(path)
            print(f"[analyzer] Tonart: {symbolic.get('key','?')}, "
                  f"Noten: {symbolic.get('total_notes','?')}")

            print("[analyzer] Rendere MIDI zu Audio via FluidSynth...")
            wav_path = tmp / "rendered.wav"
            if midi_to_audio(path, wav_path):
                audio_path = wav_path
                print(f"[analyzer] Audio gerendert: {wav_path.stat().st_size // 1024} KB")
            else:
                print("[analyzer] WARN: FluidSynth fehlgeschlagen — nur symbolische Analyse")
                audio_path = None

        elif suffix in (".mp3", ".wav", ".flac", ".ogg", ".m4a"):
            print(f"[analyzer] Audio erkannt: {path.name}")
        else:
            return f"Fehler: Unbekanntes Format '{suffix}'. Unterstützt: .mid .midi .mp3 .wav .flac"

        audio_analysis = ""
        if audio_path and audio_path.exists():
            print("[analyzer] Audio-Analyse via Qwen2.5-Omni...")
            try:
                context = json.dumps(symbolic, ensure_ascii=False) if symbolic else ""
                audio_analysis = await analyze_audio_with_llm(audio_path, context)
                print("[analyzer] Audio-Analyse abgeschlossen.")
            except Exception as e:
                print(f"[analyzer] WARN: Audio-LLM nicht verfügbar: {e}")
                audio_analysis = "(Audio-LLM nicht erreichbar)"

        print("[analyzer] Synthese via Qwen3 (mit Thinking)...")
        result = await synthesize_analysis(symbolic, audio_analysis, path.name)
        return result


def main():
    if len(sys.argv) < 2:
        print("Usage: music-analyzer.py <datei.mid|datei.mp3>")
        print("Beispiele:")
        print("  music-analyzer.py song.mid")
        print("  music-analyzer.py recording.mp3")
        sys.exit(1)

    file_path = sys.argv[1]
    result = asyncio.run(analyze_music_file(file_path))
    print("\n" + "="*60)
    print(result)


if __name__ == "__main__":
    main()
