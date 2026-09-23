"""The decision record: one line per environment, derived from its reasons, never written apart."""

from . import values


def lines(environments):
    return [
        f"{values.get_val(entry['environment'])}: {entry['verdict']} — {'; '.join(entry['reasons'])}"
        for entry in environments
    ]
