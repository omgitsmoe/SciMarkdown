import sys
import os
import struct


class BufferedIOHelper:
    def __init__(self, text_io):
        self.text_io = text_io
        self.buffer = []

    def write(self, s):
        # since we use stdout in binary mode anyway encode the string
        # (need to anyway to get the length in bytes)
        if type(s) is bytes:
            b = s
        else:
            b = s.encode('utf-8')
        self.buffer.append(b)
        # don't know if this must return length in chars?
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
            stdio.write(struct.pack('L', sum(len(s) for s in self.buffer)))
            stdio.flush()

            for binary_data in self.buffer:
                stdio.write(binary_data)
            stdio.flush()

        self.buffer.clear()


# replace out/err with our version that waits till real_flush is called
# after a chunk and writes the length of the following content out first
sys.stdout = BufferedIOHelper(sys.stdout)
sys.stderr = BufferedIOHelper(sys.stderr)

