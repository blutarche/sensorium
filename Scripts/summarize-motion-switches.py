#!/usr/bin/env python3
"""Says what happened at each change between the settled and the moving picture
in one run of the stand-in host (`SensoriumBenchHost --canvas ... --packet-log`).

usage: summarize-motion-switches.py <packet-log> [<bench-viewer-json>]

The packet log is one JSON object per line, written by the stand-in: a `config`
line with the two sizes it encodes at, a `packet` line for every encoded frame
(a key frame also carries its sequence parameter set in hex) and a `viewer`
line for each new reading the viewer sent about itself. Every `t` is the host's
monotonic clock in nanoseconds. The frame size of a packet is read from the
sequence parameter set of the key frame it follows, so it is the size the
encoder produced, not the size it was asked for.

The viewer report is the `bench-viewer` JSON line a `SensoriumViewerProbe view`
run prints when it ends. It counts the whole run, so the figures taken from it
are not per switch.

Exits 1 when a check fails, 0 otherwise.
"""
import json
import sys

# The longest the viewer may go without a new picture while the screen moves.
MAXIMUM_PRESENT_GAP_MS = 250.0
# Round trips from settled to moving and back that make a run.
MINIMUM_CYCLES = 5

_PROFILES_WITH_CHROMA_FORMAT = {100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135}
# (SubWidthC, SubHeightC) by chroma_format_idc.
_CHROMA_SUBSAMPLING = {1: (2, 2), 2: (2, 1)}


class _Bits:
    def __init__(self, data):
        self.data = data
        self.position = 0

    def u(self, count):
        value = 0
        for _ in range(count):
            byte = self.data[self.position >> 3]
            value = (value << 1) | ((byte >> (7 - (self.position & 7))) & 1)
            self.position += 1
        return value

    def ue(self):
        zeros = 0
        while self.u(1) == 0:
            zeros += 1
            if zeros > 32:
                raise IndexError("exp-Golomb code too long")
        return (1 << zeros) - 1 + self.u(zeros)

    def se(self):
        value = self.ue()
        return (value + 1) // 2 if value % 2 else -(value // 2)


def sps_size(sps_hex):
    """The picture size (width, height) a hex-encoded H.264 sequence parameter
    set names, or None if it is not a whole one. Only what the hardware encoder
    produces is read: 4:4:4 video and scaling matrices give None."""
    try:
        data = bytes.fromhex(sps_hex)
    except ValueError:
        return None
    if len(data) < 4 or data[0] & 0x1F != 7:
        return None
    rbsp = bytearray()
    zeros = 0
    for byte in data[1:]:
        if zeros >= 2 and byte == 3:
            zeros = 0
            continue
        zeros = zeros + 1 if byte == 0 else 0
        rbsp.append(byte)
    bits = _Bits(bytes(rbsp))
    try:
        profile = bits.u(8)
        bits.u(8)
        bits.u(8)
        bits.ue()
        chroma = 1
        if profile in _PROFILES_WITH_CHROMA_FORMAT:
            chroma = bits.ue()
            if chroma == 3:
                return None
            bits.ue()
            bits.ue()
            bits.u(1)
            if bits.u(1):
                return None
        bits.ue()
        order_type = bits.ue()
        if order_type == 0:
            bits.ue()
        elif order_type == 1:
            bits.u(1)
            bits.se()
            bits.se()
            for _ in range(bits.ue()):
                bits.se()
        bits.ue()
        bits.u(1)
        width_in_macroblocks = bits.ue() + 1
        height_in_map_units = bits.ue() + 1
        frame_macroblocks_only = bits.u(1)
        if not frame_macroblocks_only:
            bits.u(1)
        bits.u(1)
        crop = (0, 0, 0, 0)
        if bits.u(1):
            crop = tuple(bits.ue() for _ in range(4))
    except IndexError:
        return None
    sub_width, sub_height = _CHROMA_SUBSAMPLING.get(chroma, (1, 1))
    field_factor = 2 - frame_macroblocks_only
    width = width_in_macroblocks * 16 - sub_width * (crop[0] + crop[1])
    height = height_in_map_units * 16 * field_factor - sub_height * field_factor * (crop[2] + crop[3])
    return width, height


def parse_log(text):
    log = {"config": [], "packets": [], "viewer": []}
    for line in text.splitlines():
        try:
            record = json.loads(line)
        except ValueError:
            continue
        if not isinstance(record, dict):
            continue
        key = {"config": "config", "packet": "packets", "viewer": "viewer"}.get(record.get("kind"))
        if key:
            log[key].append(record)
    log["packets"].sort(key=lambda packet: packet["seq"])
    return log


def _name(size):
    return "%dx%d" % size


def analyse(log):
    packets = log["packets"]
    config = log["config"][0] if log["config"] else {}
    named = []
    size = None
    for packet in packets:
        if packet.get("sps"):
            size = sps_size(packet["sps"]) or size
        named.append(_name(size) if size else None)
    seen = sorted({name for name in named if name}, key=lambda name: int(name.split("x")[0]) * int(name.split("x")[1]))
    settled = config.get("settled") or (seen[-1] if seen else None)
    moving = config.get("moving") or (seen[0] if len(seen) > 1 else None)

    t0 = packets[0]["t"] if packets else 0
    readings = log["viewer"]
    switches = []
    for index in range(1, len(packets)):
        if named[index] is None or named[index] == named[index - 1]:
            continue
        packet = packets[index]
        after = [reading for reading in readings if reading["t"] > packet["t"]][:2]
        switches.append({
            "index": index,
            "seconds": (packet["t"] - t0) / 1e9,
            "from": named[index - 1],
            "to": named[index],
            "kind": "motion" if named[index] == moving else "settle" if named[index] == settled else "other",
            "is_key_frame": bool(packet["key"]),
            "key_frame_bytes": packet["bytes"],
            "gap_ms": (packet["t"] - packets[index - 1]["t"]) / 1e6,
            "viewer": [(reading["presentedFps"], reading["decodedFps"]) for reading in after],
            "viewer_after_ms": [(reading["t"] - packet["t"]) / 1e6 for reading in after],
        })

    cycles = 0
    episodes = []
    open_motion = None
    for switch in switches:
        if switch["kind"] == "motion":
            open_motion = switch
        elif switch["kind"] == "settle" and open_motion is not None:
            cycles += 1
            first, last = open_motion["index"], switch["index"] - 1
            episodes.append({"first": first, "last": last})
            open_motion = None
    if open_motion is not None:
        episodes.append({"first": open_motion["index"], "last": len(packets) - 1})
    for number, episode in enumerate(episodes):
        first, last = episode["first"], episode["last"]
        seconds = (packets[last]["t"] - packets[first]["t"]) / 1e9
        total = sum(packet["bytes"] for packet in packets[first:last + 1])
        episode["moving_seconds"] = seconds
        episode["moving_bytes"] = total
        episode["moving_bytes_per_second"] = total / seconds if seconds > 0 else None
        episode["moving_packets_per_second"] = (last - first) / seconds if seconds > 0 else None
        following = episodes[number + 1]["first"] if number + 1 < len(episodes) else len(packets)
        end = packets[following]["t"] if following < len(packets) else packets[-1]["t"]
        rest = (end - packets[last]["t"]) / 1e9
        episode["still_seconds"] = rest
        episode["still_bytes"] = sum(packet["bytes"] for packet in packets[last + 1:following])
        episode["still_bytes_per_second"] = episode["still_bytes"] / rest if rest > 0 else None

    return {
        "settled": settled,
        "moving": moving,
        "sizes": seen,
        "switches": switches,
        "episodes": episodes,
        "cycles": cycles,
        "last_size": named[-1] if named else None,
        "packets": len(packets),
        "bytes": sum(packet["bytes"] for packet in packets),
        "key_frames": sum(1 for packet in packets if packet["key"]),
        "seconds": (packets[-1]["t"] - t0) / 1e9 if packets else 0.0,
    }


def verdict(report, viewer):
    """(name, ok, detail) for each check; ok is None when the figure is missing."""
    checks = [
        ("cycles", report["cycles"] >= MINIMUM_CYCLES,
         "%d runs of motion that settled again (need %d)" % (report["cycles"], MINIMUM_CYCLES)),
        ("both sizes sent",
         report["moving"] is not None and {report["settled"], report["moving"]} <= set(report["sizes"]),
         "sequence parameter sets named %s (settled %s, moving %s)" % (
             ", ".join(report["sizes"]) or "nothing", report["settled"], report["moving"])),
        ("ends at the settled size", report["last_size"] == report["settled"],
         "the last packet is %s (settled %s)" % (report["last_size"], report["settled"])),
    ]
    if viewer is not None:
        decoded, presented = viewer.get("decodedFrames"), viewer.get("presentedFrames")
        checks.append(("viewer decoded frames", None if decoded is None else decoded > 0,
                       "%s decoded, against %d packets the host sent" % (decoded, report["packets"])))
        checks.append(("viewer presented frames", None if presented is None else presented > 0,
                       "%s presented, %s dropped" % (presented, viewer.get("droppedFrames"))))
        gap = viewer.get("longestPresentGapDuringMoveMs")
        checks.append(("present gap during motion", None if gap is None else gap <= MAXIMUM_PRESENT_GAP_MS,
                       "longest %s ms inside a stretch of motion (limit %d ms)" % (gap, MAXIMUM_PRESENT_GAP_MS)))
    return checks


def _number(value, spec="%.1f"):
    return "n/a" if value is None else spec % value


def render(report, viewer):
    lines = [
        "settled %s, moving %s; %d packets, %d key frames, %.1f s, %.1f MB"
        % (report["settled"], report["moving"], report["packets"], report["key_frames"], report["seconds"], report["bytes"] / 1e6),
        "",
        " # |     at s | change                 | kind   | key | key frame KiB | host gap ms | viewer presented/decoded fps, next two readings",
    ]
    for number, switch in enumerate(report["switches"], 1):
        readings = "  ".join("%s/%s @+%d ms" % (_number(p), _number(d), after)
                             for (p, d), after in zip(switch["viewer"], switch["viewer_after_ms"])) or "n/a"
        lines.append("%2d | %8.2f | %-9s -> %-9s | %-6s | %-3s | %13.1f | %11.1f | %s" % (
            number, switch["seconds"], switch["from"], switch["to"], switch["kind"],
            "yes" if switch["is_key_frame"] else "NO", switch["key_frame_bytes"] / 1024, switch["gap_ms"], readings))
    lines += ["", " # | moving s | moving MB/s | moving packets/s | rest s | rest KiB sent | rest MB/s"]
    for number, episode in enumerate(report["episodes"], 1):
        lines.append("%2d | %8.2f | %11s | %16s | %6.2f | %13.1f | %s" % (
            number, episode["moving_seconds"],
            _number(None if episode["moving_bytes_per_second"] is None else episode["moving_bytes_per_second"] / 1e6, "%.2f"),
            _number(episode["moving_packets_per_second"]), episode["still_seconds"],
            episode["still_bytes"] / 1024,
            _number(None if episode["still_bytes_per_second"] is None else episode["still_bytes_per_second"] / 1e6, "%.2f")))
    lines.append("")
    for name, ok, detail in verdict(report, viewer):
        lines.append("%s %s: %s" % ("NOTE" if ok is None else "PASS" if ok else "FAIL", name, detail))
    return "\n".join(lines)


def main(argv):
    if len(argv) not in (2, 3):
        print("usage: summarize-motion-switches.py <packet-log> [<bench-viewer-json>]", file=sys.stderr)
        return 2
    with open(argv[1]) as handle:
        report = analyse(parse_log(handle.read()))
    viewer = None
    if len(argv) == 3:
        try:
            with open(argv[2]) as handle:
                viewer = json.load(handle)
        except (OSError, ValueError):
            print("NOTE: no readable viewer report in %s" % argv[2])
    print(render(report, viewer))
    return 1 if any(ok is False for _, ok, _ in verdict(report, viewer)) else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
