from __future__ import annotations

import json
import sys
from dataclasses import asdict, dataclass
from typing import Any, Optional


class PipeClosedError(BrokenPipeError):
    pass


@dataclass
class PartialPayload:
    partial_id: str
    start_seconds: float
    end_seconds: float
    source_text: str


@dataclass
class SegmentPayload:
    segment_id: str
    start_seconds: float
    end_seconds: float
    source_text: str
    translated_text: str


@dataclass
class WorkerEvent:
    type: str
    message: Optional[str] = None
    progress: Optional[float] = None
    partial: Optional[PartialPayload] = None
    segment: Optional[SegmentPayload] = None

    def to_json(self) -> str:
        payload = asdict(self)
        if self.partial is None:
            payload.pop("partial")
        if self.segment is None:
            payload.pop("segment")
        return json.dumps(payload, ensure_ascii=False)


def emit_event(event_type: str, **kwargs: Any) -> None:
    partial = kwargs.get("partial")
    if isinstance(partial, dict):
        kwargs["partial"] = PartialPayload(**partial)
    segment = kwargs.get("segment")
    if isinstance(segment, dict):
        kwargs["segment"] = SegmentPayload(**segment)
    event = WorkerEvent(type=event_type, **kwargs)
    try:
        sys.stdout.write(event.to_json() + "\n")
        sys.stdout.flush()
    except BrokenPipeError as exc:
        raise PipeClosedError() from exc
