"""
Wyoming event handler — buffers audio chunks then calls HailoWhisperCore.
"""
import logging
from typing import Optional

from wyoming.asr import Transcribe, Transcript
from wyoming.audio import AudioChunk, AudioStart, AudioStop
from wyoming.event import Event
from wyoming.info import AsrModel, AsrProgram, Attribution, Describe, Info
from wyoming.server import AsyncEventHandler

from .core import HailoWhisperCore

_LOGGER = logging.getLogger(__name__)


def _make_info(model_name: str) -> Info:
    """Build the Wyoming Info descriptor for the loaded model."""
    # Derive a human-readable label from the model name (e.g. "small.en" → "Whisper small (English)")
    size = model_name.split(".")[0].capitalize()
    lang_suffix = " (English)" if model_name.endswith(".en") else ""
    return Info(
        asr=[
            AsrProgram(
                name="wyoming-hailo-whisper",
                description="Whisper STT accelerated by Hailo NPU",
                attribution=Attribution(name="hailo-ai", url="https://hailo.ai"),
                installed=True,
                version="1.0.0",
                models=[
                    AsrModel(
                        name=model_name,
                        description=f"Whisper {size}{lang_suffix}, encoder on Hailo NPU",
                        attribution=Attribution(name="OpenAI", url="https://openai.com"),
                        installed=True,
                        languages=["en"] if model_name.endswith(".en") else [],
                        version="1.0.0",
                    )
                ],
            )
        ]
    )


class HailoWhisperEventHandler(AsyncEventHandler):
    """
    Handles one Wyoming STT session per connection.
    Collects audio chunks then transcribes with Hailo on AudioStop.
    """

    def __init__(self, *args, core: HailoWhisperCore, **kwargs):
        super().__init__(*args, **kwargs)
        self.core = core
        self._info = _make_info(core.model_name)
        self._audio_buffer: Optional[bytearray] = None
        self._in_utterance: bool = False

    async def handle_event(self, event: Event) -> bool:
        # ── Info request ──────────────────────────────────────────────────────
        if Describe.is_type(event.type):
            await self.write_event(self._info.event())
            return True

        # ── Audio start ───────────────────────────────────────────────────────
        if AudioStart.is_type(event.type):
            self._audio_buffer = bytearray()
            self._in_utterance = True
            _LOGGER.debug("AudioStart received — buffering audio")
            return True

        # ── Audio chunk ───────────────────────────────────────────────────────
        if AudioChunk.is_type(event.type) and self._in_utterance:
            chunk = AudioChunk.from_event(event)
            self._audio_buffer.extend(chunk.audio)
            return True

        # ── Audio stop — run inference ────────────────────────────────────────
        if AudioStop.is_type(event.type) and self._in_utterance:
            self._in_utterance = False
            audio_bytes = bytes(self._audio_buffer)
            self._audio_buffer = None

            _LOGGER.info(
                "AudioStop received — transcribing %d bytes (%.1f s)",
                len(audio_bytes),
                len(audio_bytes) / (16000 * 2),  # 16kHz PCM-16
            )

            try:
                text = await self._transcribe_async(audio_bytes)
            except Exception:
                _LOGGER.exception("Transcription failed")
                text = ""

            _LOGGER.info("Transcript: %r", text)
            await self.write_event(Transcript(text=text).event())
            return True

        # ── Transcribe request (alternative trigger) ──────────────────────────
        if Transcribe.is_type(event.type):
            _LOGGER.debug("Transcribe event received (ignored — using audio stream)")
            return True

        return True

    async def _transcribe_async(self, audio_bytes: bytes) -> str:
        """Run transcription in a thread so the event loop stays unblocked."""
        import asyncio
        loop = asyncio.get_event_loop()
        return await loop.run_in_executor(None, self.core.transcribe, audio_bytes)
