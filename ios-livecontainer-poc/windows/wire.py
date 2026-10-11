"""OBSC/1: big endian, 24 byte header, one complete Annex-B H.264 AU per packet."""
import struct

HEADER = struct.Struct('!4sBBHIIQ')
MAGIC = b'OBSC'
MAX_PAYLOAD = 8 * 1024 * 1024

def packet(payload, sequence, pts_us, key=False):
    if not 0 < len(payload) <= MAX_PAYLOAD:
        raise ValueError('payload size')
    return HEADER.pack(MAGIC, 1, 1, int(key), len(payload), sequence, pts_us) + payload

class PacketParser:
    def __init__(self):
        self.buffer = bytearray()

    def feed(self, data):
        self.buffer.extend(data)
        result = []
        while len(self.buffer) >= HEADER.size:
            magic, version, kind, flags, size, seq, pts = HEADER.unpack_from(self.buffer)
            if magic != MAGIC or version != 1 or kind != 1 or not 0 < size <= MAX_PAYLOAD:
                raise ValueError('invalid OBSC header')
            end = HEADER.size + size
            if len(self.buffer) < end:
                break
            result.append((seq, pts, flags, bytes(self.buffer[HEADER.size:end])))
            del self.buffer[:end]
        return result

class AnnexBParser:
    """Incremental NAL parser. Handles start codes split across arbitrary reads."""
    def __init__(self):
        self.buffer = bytearray()

    @staticmethod
    def starts(b):
        result = []
        i = 0
        while i + 3 <= len(b):
            if b[i:i+4] == b'\x00\x00\x00\x01':
                result.append((i, 4)); i += 4
            elif b[i:i+3] == b'\x00\x00\x01':
                result.append((i, 3)); i += 3
            else:
                i += 1
        return result

    def feed(self, data, final=False):
        self.buffer.extend(data)
        if len(self.buffer) > MAX_PAYLOAD * 2:
            raise ValueError('NAL buffer overflow')
        starts = self.starts(self.buffer)
        result = []
        count = len(starts) if final else max(0, len(starts)-1)
        for i in range(count):
            pos, width = starts[i]
            end = starts[i+1][0] if i+1 < len(starts) else len(self.buffer)
            nal = bytes(self.buffer[pos+width:end])
            if nal:
                result.append(nal)
        if final:
            self.buffer.clear()
        elif starts:
            del self.buffer[:starts[-1][0]]
        return result

class AccessUnits:
    """Requires an AUD before every picture. Encoder is configured aud=1."""
    def __init__(self):
        self.nals = []

    def push(self, nal):
        result = []
        if nal[0] & 31 == 9 and self.nals:
            result = self.flush()
        self.nals.append(nal)
        return result

    def flush(self):
        nals, self.nals = self.nals, []
        if not any(n[0] & 31 in (1, 5) for n in nals):
            return []
        return [(b''.join(b'\x00\x00\x00\x01' + n for n in nals),
                 any(n[0] & 31 == 5 for n in nals))]
