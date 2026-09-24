"""GitHub Actions I/O for the adapters: log groups, annotations, verbatim text, step outputs.

Adapter-side only; the decision core never imports it. Everything a caller's configuration can
put into the log goes through `verbatim` or `annotation`, so it is shown, never executed as a
workflow command.
"""

import secrets


def _token():
    return secrets.token_hex(16)


def escape_data(text):
    """Escape a workflow command's message as the runner requires: %, CR and LF."""
    return text.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")


def escape_property(text):
    """Escape a workflow command's property value: the data escapes plus ':' and ','."""
    return escape_data(text).replace(":", "%3A").replace(",", "%2C")


class Log:
    """Workflow commands and plain lines, written to one stream (the step's stdout)."""

    def __init__(self, stream, title):
        self.stream = stream
        self.title = title

    def line(self, text=""):
        self.stream.write(text + "\n")

    def group(self, name, text):
        """A collapsed log group holding `text` shown verbatim."""
        self.line(f"::group::{self.title}: {name}")
        self.verbatim(text)
        self.line("::endgroup::")

    def verbatim(self, text):
        """Text between stop-commands markers: a line that looks like a workflow command is shown."""
        token = _token()
        self.line(f"::stop-commands::{token}")
        for line in text.splitlines():
            self.line(line)
        self.line(f"::{token}::")

    def error(self, message):
        """One error annotation; a newline in the message cannot split it or start a command."""
        self.line(f"::error title={escape_property(self.title)}::{escape_data(message)}")


def append_output(path, name, value):
    """Append a multi-line step output under a random 128-bit delimiter, as GitHub recommends."""
    delimiter = f"EOF_{_token()}"
    with open(path, "a", encoding="utf-8") as handle:
        handle.write(f"{name}<<{delimiter}\n{value}\n{delimiter}\n")
