"""Sparkplug B topic parser and protobuf payload decoder.

Implements a focused proto2 reader for Eclipse Tahu Payload / Metric so we
do not require protoc or a generated _pb2 module at runtime.
"""

from __future__ import annotations

import struct
from dataclasses import dataclass, field
from typing import Any

SPARKPLUG_NAMESPACE = "spBv1.0"
COMMAND_TYPES = {"NCMD", "DCMD"}
BIRTH_TYPES = {"NBIRTH", "DBIRTH"}
DATA_TYPES = {"NDATA", "DDATA"}
DEATH_TYPES = {"NDEATH", "DDEATH"}
STATE_TYPES = {"STATE"}

DATATYPE_NAMES = {
    0: "Unknown",
    1: "Int8",
    2: "Int16",
    3: "Int32",
    4: "Int64",
    5: "UInt8",
    6: "UInt16",
    7: "UInt32",
    8: "UInt64",
    9: "Float",
    10: "Double",
    11: "Boolean",
    12: "String",
    13: "DateTime",
    14: "Text",
    15: "UUID",
    16: "DataSet",
    17: "Bytes",
    18: "File",
    19: "Template",
}


@dataclass(frozen=True)
class Topic:
    group_id: str
    message_type: str
    edge_node_id: str
    device_id: str | None = None

    @property
    def key(self) -> str:
        if self.device_id:
            return f"{self.group_id}/{self.edge_node_id}/{self.device_id}"
        return f"{self.group_id}/{self.edge_node_id}"

    @property
    def kind(self) -> str:
        t = self.message_type
        if t in BIRTH_TYPES:
            return "birth"
        if t in DATA_TYPES:
            return "data"
        if t in DEATH_TYPES:
            return "death"
        if t in STATE_TYPES:
            return "state"
        if t in COMMAND_TYPES:
            return "cmd"
        return "other"


def parse_topic(topic: str) -> Topic | None:
    parts = [p for p in topic.split("/") if p != ""]
    if len(parts) < 4 or parts[0] != SPARKPLUG_NAMESPACE:
        # STATE messages can be spBv1.0/STATE/<host>
        if len(parts) >= 3 and parts[0] == SPARKPLUG_NAMESPACE and parts[1] == "STATE":
            return Topic(group_id="STATE", message_type="STATE", edge_node_id=parts[2])
        return None
    device = parts[4] if len(parts) >= 5 else None
    return Topic(
        group_id=parts[1],
        message_type=parts[2],
        edge_node_id=parts[3],
        device_id=device,
    )


@dataclass
class Metric:
    name: str | None = None
    alias: int | None = None
    timestamp: int | None = None
    datatype: int | None = None
    is_null: bool = False
    value: Any = None


@dataclass
class Payload:
    timestamp: int | None = None
    seq: int | None = None
    uuid: str | None = None
    metrics: list[Metric] = field(default_factory=list)


class _Reader:
    def __init__(self, data: bytes) -> None:
        self.data = data
        self.i = 0

    def remaining(self) -> int:
        return len(self.data) - self.i

    def eof(self) -> bool:
        return self.i >= len(self.data)

    def varint(self) -> int:
        shift = 0
        result = 0
        while True:
            if self.i >= len(self.data):
                raise ValueError("truncated varint")
            b = self.data[self.i]
            self.i += 1
            result |= (b & 0x7F) << shift
            if not (b & 0x80):
                return result
            shift += 7
            if shift > 70:
                raise ValueError("varint too long")

    def skip(self, wire: int) -> None:
        if wire == 0:
            self.varint()
        elif wire == 1:
            self.i += 8
        elif wire == 2:
            n = self.varint()
            self.i += n
        elif wire == 5:
            self.i += 4
        else:
            raise ValueError(f"unsupported wire type {wire}")

    def bytes(self) -> bytes:
        n = self.varint()
        end = self.i + n
        if end > len(self.data):
            raise ValueError("truncated length-delimited field")
        blob = self.data[self.i : end]
        self.i = end
        return blob

    def string(self) -> str:
        return self.bytes().decode("utf-8", errors="replace")


def decode_payload(raw: bytes) -> Payload:
    r = _Reader(raw)
    payload = Payload()
    while not r.eof():
        tag = r.varint()
        field, wire = tag >> 3, tag & 7
        if field == 1 and wire == 0:
            payload.timestamp = r.varint()
        elif field == 2 and wire == 2:
            payload.metrics.append(_decode_metric(r.bytes()))
        elif field == 3 and wire == 0:
            payload.seq = r.varint()
        elif field == 4 and wire == 2:
            payload.uuid = r.string()
        else:
            r.skip(wire)
    return payload


def _decode_metric(raw: bytes) -> Metric:
    r = _Reader(raw)
    m = Metric()
    int_value = None
    long_value = None
    float_value = None
    double_value = None
    bool_value = None
    string_value = None
    while not r.eof():
        tag = r.varint()
        field, wire = tag >> 3, tag & 7
        if field == 1 and wire == 2:
            m.name = r.string()
        elif field == 2 and wire == 0:
            m.alias = r.varint()
        elif field == 3 and wire == 0:
            m.timestamp = r.varint()
        elif field == 4 and wire == 0:
            m.datatype = r.varint()
        elif field == 7 and wire == 0:
            m.is_null = bool(r.varint())
        elif field == 10 and wire == 0:
            int_value = r.varint()
        elif field == 11 and wire == 0:
            long_value = r.varint()
        elif field == 12 and wire == 5:
            float_value = struct.unpack("<f", r.data[r.i : r.i + 4])[0]
            r.i += 4
        elif field == 13 and wire == 1:
            double_value = struct.unpack("<d", r.data[r.i : r.i + 8])[0]
            r.i += 8
        elif field == 14 and wire == 0:
            bool_value = bool(r.varint())
        elif field == 15 and wire == 2:
            string_value = r.string()
        else:
            r.skip(wire)

    if m.is_null:
        m.value = None
        return m

    dt = m.datatype
    if string_value is not None:
        m.value = string_value
    elif bool_value is not None and dt in (None, 11):
        m.value = bool_value
    elif float_value is not None:
        m.value = float(float_value)
    elif double_value is not None:
        m.value = float(double_value)
    elif long_value is not None:
        m.value = _signed(long_value, 64) if dt in (4,) else long_value
    elif int_value is not None:
        if dt in (1, 2, 3):
            width = {1: 8, 2: 16, 3: 32}[dt]
            m.value = _signed(int_value, width)
        else:
            m.value = int_value
    elif bool_value is not None:
        m.value = bool_value
    return m


def _signed(value: int, bits: int) -> int:
    sign = 1 << (bits - 1)
    mask = (1 << bits) - 1
    value &= mask
    return value - (1 << bits) if value & sign else value
