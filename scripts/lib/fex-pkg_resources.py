"""Minimal stand-in for setuptools' pkg_resources, which FEX's build scripts import only to
compare version numbers. Newer Pythons no longer ship it."""
import re


class _Version(tuple):
    pass


def parse_version(text):
    return _Version(int(part) for part in re.findall(r"\d+", str(text))[:4])
