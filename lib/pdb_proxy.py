#!/usr/bin/env python3

"""
Run PDB in a pty.

This will allow to inject server commands not exposing them
to a user.
"""

import re
import sys

from proxy_impl import ProxyImpl


class PdbProxy(ProxyImpl):
    """A proxy for the PDB backend."""

    def __init__(self, argv: [str]):
        """ctor."""
        super().__init__("PDB", argv)
        self.prompt = re.compile(rb"[\n\r]\(Pdb\+?\+?\) ")

    def get_prompt(self):
        return self.prompt


if __name__ == '__main__':
    proxy = PdbProxy(sys.argv[1:])
    exitcode = proxy.run()
    sys.exit(exitcode)
