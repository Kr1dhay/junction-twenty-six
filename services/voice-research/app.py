"""Standalone CPU worker. The Next.js backend is the only intended caller."""
import asyncio
import hmac
import json
import os
from datetime import datetime, timezone
from typing import Literal

from fastapi import FastAPI, Request, HTTPException, Depends
from pydantic import BaseModel, ConfigDict, Field, ValidationError, field_validator
from starlette.concurrency import run_in_threadpool

from core import DenseVoiceModel, decode_sample, mfcc_features

app = FastAPI(docs_url=None, redoc_url=None, openapi_url=None)
capacity = asyncio.Semaphore(1)
model = None
# The explicit local hackathon mode accepts only the pinned demo artifact. It
# does not assert upstream licensing, clinical validation or regulatory approval.
hackathon_demo = os.environ.get("VOICE_RESEARCH_HACKATHON_DEMO") == "true"
if hackathon_demo or os.environ.get("VOICE_RESEARCH_APPROVED") == "true":
    try:
        model = DenseVoiceModel.load(os.environ["VOICE_RESEARCH_MODEL_PATH"], os.environ["VOICE_RESEARCH_MODEL_SHA256"],
                                     allow_unlicensed_demo=hackathon_demo)
    except (OSError, ValueError, KeyError, TypeError):
        model = None  # Fail closed. Never invent a prediction or print artifact contents.


def authorize(request: Request):
    token = os.environ.get("VOICE_RESEARCH_TOKEN", "")
    if len(token) < 32:
        raise HTTPException(503, "Research service is not configured")
    if not hmac.compare_digest(request.headers.get("authorization", "").encode("utf-8"), ("Bearer " + token).encode("utf-8")):
        raise HTTPException(401, "Device authorization required")


class SampleRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")
    consent: Literal[True]
    task: Literal["sustained_a"]
    capture_mode: Literal["measurement"]
    audio_base64: str = Field(max_length=700 * 1024)

    @field_validator("consent", mode="before")
    @classmethod
    def consent_is_boolean(cls, value):
        if value is not True:
            raise ValueError("Explicit consent required")
        return value


@app.get("/health", dependencies=[Depends(authorize)])
def health():
    if model is None:
        raise HTTPException(503, "No approved research model")
    return {"ready": True, "research_only": True, "model_id": model.model_id, "model_version": model.version}


def evaluate(encoded):
    samples, duration, adequate = decode_sample(encoded)
    outcome = "inconclusive"
    if adequate:
        outcome = model.predict(mfcc_features(samples, model.target_frames))
    return {"outcome": outcome, "assessed_at": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
            "model_id": model.model_id, "model_version": model.version,
            "sample_duration_seconds": duration, "research_only": True}


@app.post("/assess", dependencies=[Depends(authorize)])
async def assess(request: Request):
    if model is None:
        raise HTTPException(503, "No approved research model")
    body = bytearray()
    async for chunk in request.stream():
        body.extend(chunk)
        if len(body) > 720 * 1024:
            raise HTTPException(413, "Recording too large")
    try:
        sample = SampleRequest.model_validate(json.loads(body))
    except (ValueError, ValidationError):
        raise HTTPException(400, "Invalid consented voice sample") from None
    try:
        await asyncio.wait_for(capacity.acquire(), timeout=1)
    except TimeoutError:
        raise HTTPException(429, "Research worker is busy") from None
    try:
        return await run_in_threadpool(evaluate, sample.audio_base64)
    except (ValueError, EOFError):
        raise HTTPException(400, "Invalid voice recording") from None
    except Exception:
        raise HTTPException(503, "Research analysis unavailable") from None
    finally:
        capacity.release()
