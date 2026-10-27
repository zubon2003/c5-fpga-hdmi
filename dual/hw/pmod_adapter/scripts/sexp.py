"""Minimal S-expression reader/writer for KiCad files."""
import re

_tok = re.compile(r'\s*(?:(\()|(\))|("(?:[^"\\]|\\.)*")|([^\s()"]+))')


class Sym(str):
    """Unquoted atom."""


def parse(text):
    stack = [[]]
    pos = 0
    n = len(text)
    while pos < n:
        m = _tok.match(text, pos)
        if not m:
            if text[pos:].strip() == "":
                break
            raise ValueError("parse error at %d" % pos)
        pos = m.end()
        lp, rp, st, at = m.groups()
        if lp:
            stack.append([])
        elif rp:
            t = stack.pop()
            stack[-1].append(t)
        elif st is not None:
            stack[-1].append(bytes(st[1:-1], "utf-8").decode("unicode_escape") if False else st[1:-1].replace('\\"', '"').replace("\\\\", "\\"))
        elif at is not None:
            stack[-1].append(Sym(at))
    return stack[0]


def dump(x, indent=0):
    if isinstance(x, list):
        if not x:
            return "()"
        simple = all(not isinstance(e, list) for e in x)
        if simple:
            return "(" + " ".join(dump(e) for e in x) + ")"
        out = "(" + dump(x[0])
        for e in x[1:]:
            if isinstance(e, list):
                out += "\n" + "  " * (indent + 1) + dump(e, indent + 1)
            else:
                out += " " + dump(e)
        return out + ")"
    if isinstance(x, Sym):
        return str(x)
    if isinstance(x, bool):
        return "yes" if x else "no"
    if isinstance(x, (int, float)):
        s = ("%.4f" % x).rstrip("0").rstrip(".")
        return s if s not in ("-0", "") else "0"
    s = str(x).replace("\\", "\\\\").replace('"', '\\"')
    return '"' + s + '"'


def find_symbol(lib_path, name):
    tree = parse(open(lib_path, encoding="utf-8").read())[0]
    for e in tree:
        if isinstance(e, list) and e and e[0] == "symbol" and e[1] == name:
            return e
    raise KeyError(name)
