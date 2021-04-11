import sys
import os
import struct

from io import TextIOWrapper


class BufferedIOHelper:
    def __init__(self, text_io):
        self.text_io = text_io
        self.buffer = []

    def write(self, s):
        self.buffer.append(s)
        return len(s)

    def flush(self):
        # nop
        return

    def real_flush(self):
        # length followed by chunk's output of this stream
        # need to open TextIOWrapper underlying file descriptor in binary mode
        # so we can write the length as unsigned long
        # closefd=False so file descr doesn't get close by ctx manager
        with os.fdopen(self.text_io.fileno(), "wb", closefd=False) as stdio:
            stdio.write(struct.pack('L', len(self.buffer)))
            stdio.flush()

        self.text_io.write("".join(self.buffer))
        self.text_io.flush()


# replace out/err with our version that waits till real_flush is called
# after a chunk and writes the length of the following content out first
sys.stdout = BufferedIOHelper(sys.stdout)
sys.stderr = BufferedIOHelper(sys.stderr)

