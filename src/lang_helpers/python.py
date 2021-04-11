import sys
import os
import struct

from io import TextIOWrapper


class BufferedIOHelper:
    def __init__(self, text_io):
        self.text_io = text_io
        self.buffer = []

    def write(self, s):
        # since we use stdout in binary mode anyway encode the string
        # (need to anyway to get the length in bytes)
        char_len = len(s)
        s = s.encode('utf-8')
        self.buffer.append(s)
        # don't know if this must return length in chars?
        return char_len

    def flush(self):
        # nop
        return

    def real_flush(self):
        # length followed by chunk's output of this stream
        # need to open TextIOWrapper underlying file descriptor in binary mode
        # so we can write the length as unsigned long
        # closefd=False so file descr doesn't get close by ctx manager
        with os.fdopen(self.text_io.fileno(), "wb", closefd=False) as stdio:
            stdio.write(struct.pack('L', sum(len(s) for s in self.buffer)))
            stdio.flush()

            for binary_string in self.buffer:
                stdio.write(binary_string)
            stdio.flush()


# replace out/err with our version that waits till real_flush is called
# after a chunk and writes the length of the following content out first
sys.stdout = BufferedIOHelper(sys.stdout)
sys.stderr = BufferedIOHelper(sys.stderr)

