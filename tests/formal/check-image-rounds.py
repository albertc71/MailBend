#!/usr/bin/env python3
"""Exhaust the bounded image-round controller, independently of transport IO.

Production admission is checked by Bend's existing proofs and e2e fixtures.
This model checks round selection and ordered replay, including exact-zero
byte exhaustion with a round already in flight.
"""
import itertools


def survey(parts, batch):
    kept, attempts, remaining, index, sessions, physical = 0, 0, 4, 0, 0, 0
    fates = []
    fetched_after_count = False
    while index < len(parts):
        width = min(4 - kept, 8 - attempts) if remaining else 0
        if width == 0:
            reason = "count" if kept == 4 or attempts == 8 else "bytes"
            fates.extend([reason] * (len(parts) - index))
            break
        width = min(width if batch else 1, len(parts) - index)
        sessions += 1
        physical += width
        for value in parts[index:index + width]:
            fetched_after_count |= kept == 4
            if kept == 4 or attempts == 8:
                fates.append("count")
            elif remaining == 0:
                fates.append("bytes")
            else:
                attempts += 1
                if value < 0:
                    fates.append("rejected")
                elif value > remaining:
                    fates.append("bytes")
                else:
                    kept += 1
                    remaining -= value
                    fates.append("used")
        index += width
    return fates, kept, attempts, sessions, physical, fetched_after_count


def check():
    maximum, extra, cases = 0, False, 0
    for parts in itertools.product((-1, 1, 4, 5), repeat=9):
        sequential, batched = survey(parts, False), survey(parts, True)
        assert batched[:3] == sequential[:3], (parts, sequential, batched)
        assert batched[3] <= 5 and batched[4] <= 8 and not batched[5], (parts, batched)
        maximum = max(maximum, batched[3])
        extra |= batched[4] > sequential[4]
        cases += 1
    assert maximum == 5 and extra
    assert survey((1,) * 9, True)[3:5] == (1, 4)
    assert survey((4,) + (1,) * 8, True)[3:5] == (1, 4)
    print(f"image rounds: {cases} bounded traces match sequential fates; maximum five sessions")


if __name__ == "__main__":
    check()
