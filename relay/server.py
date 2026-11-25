"""Run the Calci development relay from the project root."""
import asyncio
import base64
import hmac
import json
import logging
import os
import re
from pathlib import Path
import ssl

from websockets.asyncio.client import connect
from websockets.asyncio.server import serve
from websockets.exceptions import ConnectionClosed, InvalidStatus

ROOT = Path(__file__).resolve().parents[1]
LOCAL = ROOT / ".calci-local"
PCM_RATE = 24000
MAX_AUDIO_BYTES = PCM_RATE * 2 * 90
MIN_AUDIO_BYTES = PCM_RATE * 2 // 10
OPENAI_URL = "wss://api.openai.com/v1/realtime?intent=transcription"
SESSION_UPDATE = {
    "type": "session.update",
    "session": {
        "type": "transcription",
        "audio": {
            "input": {
                "format": {"type": "audio/pcm", "rate": PCM_RATE},
                "transcription": {
                    "model": "gpt-live-transcribe",
                    "languages": ["zh-cn", "en"],
                    "delay": "low",
                },
                "turn_detection": None,
            }
        },
    },
}


def log_upstream_error(stage, event):
    """Keep actionable API diagnostics without recording audio or credentials."""
    details = event.get("error", {})
    message = re.sub(r"sk-[A-Za-z0-9_-]+", "[redacted]", str(details.get("message", "")))
    logging.warning("OpenAI %s: %s", stage, json.dumps({
        "model": SESSION_UPDATE["session"]["audio"]["input"]["transcription"]["model"],
        "event_id": event.get("event_id"),
        "code": details.get("code"),
        "type": details.get("type"),
        "param": details.get("param"),
        "message": message[:2000],
    }, ensure_ascii=False))


def load_api_key():
    key = os.environ.get("OPENAI_API_KEY", "").strip()
    if not key:
        for line in (ROOT / ".env.local").read_text().splitlines():
            name, _, value = line.partition("=")
            if name.strip().removeprefix("export ") == "OPENAI_API_KEY":
                key = value.strip().strip("'\"")
                break
    if not key.startswith("sk-") or any(char.isspace() for char in key):
        raise SystemExit("Calci API key is unavailable.")
    return key


async def forward_audio(phone, upstream):
    total = 0
    async for message in phone:
        if message == "commit":
            logging.info("Phone committed audio: bytes=%d seconds=%.2f", total, total / (PCM_RATE * 2))
            if total < MIN_AUDIO_BYTES:
                await phone.send(json.dumps({"type": "final", "text": ""}))
                await phone.close()
                return
            await upstream.send('{"type":"input_audio_buffer.commit"}')
            return
        if not isinstance(message, bytes) or len(message) % 2:
            raise ValueError("invalid audio frame")
        total += len(message)
        if total == len(message):
            logging.info("First phone audio frame received")
        if total > MAX_AUDIO_BYTES:
            raise ValueError("audio duration limit reached")
        await upstream.send(json.dumps({
            "type": "input_audio_buffer.append",
            "audio": base64.b64encode(message).decode("ascii"),
        }))


async def forward_transcript(phone, upstream):
    async for message in upstream:
        event = json.loads(message)
        kind = event["type"]
        if kind == "conversation.item.input_audio_transcription.delta":
            await phone.send(json.dumps({"type": "delta", "text": event["delta"]}))
        elif kind == "conversation.item.input_audio_transcription.completed":
            logging.info("OpenAI final transcript received: characters=%d", len(event["transcript"]))
            await phone.send(json.dumps({"type": "final", "text": event["transcript"]}))
            return
        elif kind in ("error", "conversation.item.input_audio_transcription.failed"):
            log_upstream_error("transcription", event)
            raise ValueError("transcription failed")


async def transcribe(phone, key):
    async with connect(OPENAI_URL, additional_headers={"Authorization": f"Bearer {key}"},
                       open_timeout=10, close_timeout=1, proxy=None) as upstream:
        await upstream.send(json.dumps(SESSION_UPDATE))
        async with asyncio.timeout(10):
            async for message in upstream:
                event = json.loads(message)
                if event["type"] == "session.updated":
                    logging.info("OpenAI transcription session ready")
                    break
                if event["type"] == "error":
                    log_upstream_error("session configuration", event)
                    raise ValueError("session configuration rejected")
            else:
                raise ValueError("session closed during configuration")
        sender = asyncio.create_task(forward_audio(phone, upstream))
        receiver = asyncio.create_task(forward_transcript(phone, upstream))
        try:
            done, _ = await asyncio.wait({sender, receiver}, return_when=asyncio.FIRST_COMPLETED)
            for task in done:
                task.result()
            if receiver not in done and phone.close_code is None:
                await asyncio.wait_for(receiver, timeout=15)
        finally:
            for task in (sender, receiver):
                task.cancel()
            await asyncio.gather(sender, receiver, return_exceptions=True)


async def main():
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    key = load_api_key()
    token = (LOCAL / "relay-token").read_text().strip()
    tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    tls.load_cert_chain(LOCAL / "relay-cert.pem", LOCAL / "relay-key.pem")

    async def handle(phone):
        logging.info("Phone connection received")
        supplied = phone.request.headers.get("Authorization", "")
        if phone.request.path != "/transcribe" or not hmac.compare_digest(
            supplied.encode(), f"Bearer {token}".encode()
        ):
            logging.warning("Phone authentication or path rejected")
            await phone.close(1008, "Unauthorized")
            return
        try:
            async with asyncio.timeout(120):
                await transcribe(phone, key)
        except ConnectionClosed:
            return
        except InvalidStatus as error:
            logging.warning("OpenAI connection rejected: HTTP %s", error.response.status_code)
            await phone.close(1011, "Transcription unavailable")
        except (OSError, TimeoutError, ValueError):
            logging.warning("Transcription session ended with an error")
            await phone.close(1011, "Transcription unavailable")

    async with serve(handle, None, 8765, ssl=tls, max_size=8192, close_timeout=1) as server:
        print("Calci relay listening on port 8765", flush=True)
        await server.serve_forever()


if __name__ == "__main__":
    asyncio.run(main())
