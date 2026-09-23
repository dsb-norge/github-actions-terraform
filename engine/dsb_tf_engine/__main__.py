"""Command line: python3 -B -m dsb_tf_engine decide --input <file> --output <file>.

Exit codes: 0 decided, 2 the caller's configuration is invalid (messages on stderr and in the
output document's `errors`), 1 anything else. Nothing is written to stdout.
"""

import argparse
import json
import sys

from . import decide, model

EXIT_OK, EXIT_CRASH, EXIT_INVALID = 0, 1, 2


def _parse(argv):
    parser = argparse.ArgumentParser(prog="dsb_tf_engine")
    commands = parser.add_subparsers(dest="command", required=True)
    decide_parser = commands.add_parser("decide", help="decide the run from an input document")
    decide_parser.add_argument("--input", required=True, help="path of the input document")
    decide_parser.add_argument("--output", required=True, help="path to write the output document to")
    return parser.parse_args(argv)


def main(argv=None):
    args = _parse(sys.argv[1:] if argv is None else argv)
    try:
        with open(args.input, encoding="utf-8") as handle:
            document = json.load(handle)
        output = decide.decide(document)
    except (OSError, ValueError, model.DocumentError) as error:
        print(f"dsb_tf_engine: cannot decide: {error}", file=sys.stderr)
        return EXIT_CRASH

    with open(args.output, "w", encoding="utf-8") as handle:
        json.dump(output, handle, sort_keys=True, ensure_ascii=False)
        handle.write("\n")
    for message in output["errors"]:
        print(message, file=sys.stderr)
    return EXIT_INVALID if output["errors"] else EXIT_OK


if __name__ == "__main__":
    sys.exit(main())
