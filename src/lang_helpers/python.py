import sys
import os
import traceback


def handle_exception(exc_type, exc_value, exc_traceback):
    traceback.print_exception(exc_type, exc_value, exc_traceback, file=sys.stderr)
    sys.stderr.real_flush()
    sys.exit(1)


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

sys.excepthook = handle_exception

# replace out/err with our version that waits till real_flush is called
# after a chunk and writes the length of the following content out first
sys.stdout = BufferedIOHelper(sys.stdout)
sys.stderr = BufferedIOHelper(sys.stderr)

