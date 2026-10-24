#!/usr/bin/env python3
"""Bounded exhaustive state verification of the search-pagination contract.

This is a finite executable model, not a proof of the Python/Bend programs or
of every mailbox. The production read-plan theorems live in LAWS/PROOF.bend.

Source correspondence:
- src/search-cursor.bend read/parsed bind folder, rendered query, UIDVALIDITY.
- SC.eligible/below use a strict positive UID < before predicate.
- src/tools.bend search_page sorts descending and takes limit, advances by
  the last selected UID, and emits no token if no further matches exist.
- search_headers checks the FETCH incarnation; removals between SEARCH and
  FETCH may hide selected messages but must not change the next boundary.

Enumerated space: every initial subset of UIDs 1..3; every query
match subset of those IDs plus arrival UID 4 at every following page; limits
1, 2, 3 independently at each page; and every FETCH-survivor subset of each
selected page. Folder/query/UIDVALIDITY each have two values, and all seven
mismatch combinations must refuse. Each FETCH also tests unchanged/changed
UIDVALIDITY. Max UID is covered separately.

Assumptions: one UID names one message while UIDVALIDITY is unchanged; new
arrivals have greater UIDs; callers follow emitted cursors until terminal;
servers return unique valid UIDs; a 'stable match' is present and matches at
every searched page and survives every FETCH where it was selected. Query
flag changes may cause a previously passed UID to match later: the contract
does not promise to revisit it. Fetches use the selected UIDs only.

Run normally for exhaustive properties and a required failing mutation.
--broken-boundary runs the <= mutation and must exit nonzero with a repeated
UID counterexample. No network, mail content or credentials are involved.
"""
from dataclasses import dataclass
from itertools import combinations, product
import argparse


@dataclass(frozen=True)
class Cursor:
    folder: str
    query: str
    validity: int
    before: int


IDENTITY = ("INBOX", "UNSEEN", 7)


def subsets(values):
    values = sorted(values)
    return [frozenset(c) for n in range(len(values) + 1) for c in combinations(values, n)]


def page(matches, limit, cursor=None, identity=IDENTITY, broken=False):
    if cursor is not None and (cursor.folder, cursor.query, cursor.validity) != identity:
        raise ValueError("cursor identity mismatch")
    eligible = sorted((u for u in matches if cursor is None or
                       (0 < u <= cursor.before if broken else 0 < u < cursor.before)), reverse=True)
    selected = tuple(eligible[:limit])
    next_cursor = Cursor(*identity, selected[-1]) if len(eligible) > limit else None
    return selected, next_cursor


def fetch(selected, survivors, expected_validity, current_validity):
    if current_validity != expected_validity:
        raise ValueError("FETCH identity mismatch")
    return frozenset(selected).intersection(survivors)


def verify(broken=False):
    transitions = 0
    identities = list(product(("INBOX", "Archive"), ("UNSEEN", "ALL"), (7, 8)))
    cursor = Cursor(*IDENTITY, 3)
    for identity in identities:
        try:
            page({1, 2}, 1, cursor, identity, broken)
        except ValueError:
            assert identity != IDENTITY
        else:
            assert identity == IDENTITY, "identity mismatch was accepted"

    def walk(initial, current, cursor, selected_before, returned, stable, depth):
        nonlocal transitions
        assert depth <= 3, "continuation failed to terminate within the UID space"
        for limit in (1, 2, 3):
            selected, following = page(current, limit, cursor, broken=broken)
            transitions += 1
            assert not selected_before.intersection(selected), (
                f"repeated UID: previously selected {sorted(selected_before)}, page {selected}, "
                f"boundary {cursor}")
            if following is not None and cursor is not None:
                assert following.before < cursor.before, "boundary did not decrease"
            for survivors in subsets(selected):
                for fetch_validity in (7, 8):
                    try:
                        fetched = fetch(selected, survivors, 7, fetch_validity)
                    except ValueError:
                        assert fetch_validity != 7
                    else:
                        assert fetch_validity == 7 and fetched == survivors
                # A selected UID absent from FETCH is no longer stable. The
                # boundary remains based on selection, never FETCH survivors.
                still_stable = stable.intersection(current).difference(set(selected) - survivors)
                now_returned = returned.union(survivors)
                if following is None:
                    assert still_stable <= now_returned, "stable matches dropped at terminal page"
                else:
                    for later in subsets(initial | {4}):
                        walk(initial, later, following, selected_before.union(selected),
                             now_returned, still_stable, depth + 1)

    for initial in subsets({1, 2, 3}):
        walk(initial, initial, None, frozenset(), frozenset(), initial, 0)
    selected, cursor = page({1, 4294967295}, 1, broken=broken)
    assert selected == (4294967295,)
    selected, cursor = page({1, 4294967295}, 1, cursor, broken=broken)
    assert selected == (1,) and cursor is None, "maximum UID wrapped or repeated"
    return transitions


def main():
    if not __debug__:
        raise SystemExit("State verification requires assertions; run Python without -O")
    args = argparse.ArgumentParser(description=__doc__)
    args.add_argument("--broken-boundary", action="store_true")
    options = args.parse_args()
    if options.broken_boundary:
        verify(broken=True)
    else:
        count = verify()
        print(f"PASS bounded exhaustive search model: {count} page transitions; 8 identities")
        try:
            verify(broken=True)
        except AssertionError as error:
            print(f"PASS required broken-boundary counterexample: {error}")
        else:
            raise AssertionError("broken <= boundary unexpectedly passed")


if __name__ == "__main__":
    main()
