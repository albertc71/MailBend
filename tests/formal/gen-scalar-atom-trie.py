#!/usr/bin/env python3
"""Reproduce the positive-pattern suffix of scalar-atom-proofs.bend.

Bend's negative refinement for the default branch of a Char literal match
can leave a Boolean bit merely unequal to False, without reducing it to True.
An exhaustive trie of positive constructors gives the kernel the actual bit.
The trie splits the least-significant bit first, following Base.Word layout.
It has only five distinguished leaves: JSON's quote, backslash, LF, CR, TAB.
Every other leaf fixes a prefix differing from all five, leaving its suffix
unconstrained. No Char or arithmetic premise is added, and J.esc_char itself
is unchanged. The emitted proof is checked against that production function;
this generator is not trusted by the proof kernel.

With no arguments print only the generated suffix. With --check compare it
byte-for-byte to the existing suffix, without changing any source file.
"""
from __future__ import annotations

import argparse
from pathlib import Path

SPECIAL = (ord('"'), ord('\\'), ord('\n'), ord('\r'), ord('\t'))
MARKER = "# Explicit positive bit cases avoid the compiler's negative literal-pattern\n"


def leaves(bits: tuple[bool, ...], values: tuple[int, ...]):
    if not values or len(bits) == 32:
        yield bits, bool(values)
        return
    for bit in (False, True):
        yield from leaves(
            (*bits, bit),
            tuple(v for v in values if bool((v >> len(bits)) & 1) == bit),
        )


def pattern(bits: tuple[bool, ...]) -> str:
    tail = 'WNil{}' if len(bits) == 32 else 'tail'
    for bit in reversed(bits):
        tail = 'WCon{' + ('True{}' if bit else 'False{}') + ', ' + tail + '}'
    return 'Chr{U32{' + tail + '}}'


def render() -> str:
    out = MARKER + '''# refinement: each fallback path differs from all five special characters.
def atom_exact(+c: Char)
  -> {utf8_weight(J.esc_char(c)) == U32.to_nat(C.utf8_len(J.esc_char(c))) : Nat}:
  match c:
'''
    for bits, special in leaves((), SPECIAL):
        out += '    case ' + pattern(bits) + ':\n'
        if special:
            out += '      {==}\n'
        else:
            out += ('      +u = Char.to_u32(c)\n'
                    '      atom_exact.if(U32.is_lt(u, 32), u, c)\n')
    return out


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    generated = render()
    if args.check:
        source = Path(__file__).with_name('scalar-atom-proofs.bend').read_text()
        if MARKER not in source or source[source.index(MARKER):] != generated:
            raise SystemExit('scalar atom positive-pattern trie differs from generator')
        print('scalar atom positive-pattern trie matches generator')
    else:
        print(generated, end='')


if __name__ == '__main__':
    main()
