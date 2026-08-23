#!/usr/bin/env python3
"""Copy a file with one exact substring replaced, failing loudly if it is not there.

A mutant that silently fails to apply reports SURVIVED against unmodified code, which reads
as a real result. So the assert is the point of this script."""
import sys

src, dst, old, new = sys.argv[1:5]
s = open(src).read()
if old not in s:
    sys.exit("mutation pattern not found in %s -- the mutant never landed" % src)
open(dst, "w").write(s.replace(old, new, 1))
