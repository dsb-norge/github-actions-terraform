"""Command line of the engine.

  decide --input <file> --output <file>   the pure decision: document in, document out; writes
                                          nothing to stdout
  create-matrix --inputs-file <file>      the create-tf-vars-matrix step: the adapter builds the
                                          document from the workflow's inputs and the runner's
                                          environment, decides and publishes the matrix

Actions run it as `python3 -I -B engine/run.py <command> …`. Exit codes, for both: 0 success,
2 the caller's configuration is invalid, 1 anything else.
"""

import argparse
import json
import os
import sys

from . import adapter, decide, model

EXIT_OK, EXIT_CRASH, EXIT_INVALID = 0, 1, 2


class _Parser(argparse.ArgumentParser):
    """An argument parser whose usage errors exit 1.

    argparse exits 2 on a usage error, which is this command's code for an invalid caller
    configuration; a shim that misuses the command would then read an output document that was
    never written, and report its own fault as the caller's.
    """

    def error(self, message):
        self.print_usage(sys.stderr)
        self.exit(EXIT_CRASH, f"{self.prog}: error: {message}\n")


def _parse(argv):
    parser = _Parser(prog="dsb_tf_engine")
    commands = parser.add_subparsers(dest="command", required=True)
    decide_parser = commands.add_parser("decide", help="decide the run from an input document")
    decide_parser.add_argument("--input", required=True, help="path of the input document")
    decide_parser.add_argument("--output", required=True, help="path to write the output document to")
    matrix_parser = commands.add_parser("create-matrix", help="the create-tf-vars-matrix step, on a runner")
    matrix_parser.add_argument("--inputs-file", required=True, help="path of the file holding toJSON(inputs)")
    return parser.parse_args(argv)


def main(argv=None):
    """Run the command line; argv defaults to sys.argv[1:], as argparse reads it."""
    args = _parse(argv)
    if args.command == "create-matrix":
        return adapter.run(args.inputs_file, os.environ, sys.stdout, adapter.Tools(), os.path.isdir)
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
