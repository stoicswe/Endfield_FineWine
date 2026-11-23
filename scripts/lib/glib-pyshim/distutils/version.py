# What GLib 2.78's gdbus-codegen needs from distutils, which newer Pythons no longer have:
# version strings that compare part by part, numbers as numbers.
import re


class LooseVersion:
    _parts = re.compile(r"(\d+|[a-z]+|\.)", re.IGNORECASE)

    def __init__(self, text=""):
        self.vstring = str(text)
        self.version = [int(p) if p.isdigit() else p for p in self._parts.split(self.vstring) if p and p != "."]

    def _key(self, other):
        if not isinstance(other, LooseVersion):
            other = LooseVersion(other)
        return other.version

    def _cmp(self, other):
        mine, theirs = self.version, self._key(other)
        for a, b in zip(mine, theirs):
            if a == b:
                continue
            if isinstance(a, int) != isinstance(b, int):
                a, b = str(a), str(b)
            return -1 if a < b else 1
        return (len(mine) > len(theirs)) - (len(mine) < len(theirs))

    def __eq__(self, other): return self._cmp(other) == 0
    def __lt__(self, other): return self._cmp(other) < 0
    def __le__(self, other): return self._cmp(other) <= 0
    def __gt__(self, other): return self._cmp(other) > 0
    def __ge__(self, other): return self._cmp(other) >= 0
    def __str__(self): return self.vstring
    def __repr__(self): return "LooseVersion('%s')" % self.vstring
