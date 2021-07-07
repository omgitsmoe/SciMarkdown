import sys
import os
import traceback


class BufferedIOHelper:
    def __init__(self, text_io):
        self.text_io = text_io
        # set newline mode on text_io so that newlines don't get translated
        text_io.reconfigure(newline='')
        self.buffer = []

    def write(self, s):
        self.buffer.append(s)
        # don't know if this must return length in runes or bytes?
        return len(s)

    def flush(self):
        # nop
        return

    def real_flush(self):
        text_io = self.text_io
        # length + ';' followed by chunk's output of this stream
        write_len = sum(len(s.encode('utf-8')) for s in self.buffer)
        text_io.write(f"{write_len};")
        text_io.flush()

        for data in self.buffer:
            text_io.write(data)
        text_io.flush()

        self.buffer.clear()


# replace out/err with our version that waits till real_flush is called
# after a chunk and writes the length of the following content out first
sys.stdout = BufferedIOHelper(sys.stdout)
sys.stderr = BufferedIOHelper(sys.stderr)

try:

