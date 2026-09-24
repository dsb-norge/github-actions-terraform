"""Entry point for actions: python3 -I -B <path>/engine/run.py <command> ….

Isolated mode (-I) keeps the runner's PYTHON* variables, the user's site-packages and the working
directory off the import path. The working directory is the caller's checkout: without -I a
caller's own json.py or argparse.py would be imported in place of the standard library. The
engine's directory is put on the path here instead, the one thing it needs.
"""

import sys

if sys.version_info < (3, 12):
    sys.exit("dsb_tf_engine needs Python 3.12 or later on the runner, found " + sys.version.split()[0])

import os  # noqa: E402

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from dsb_tf_engine.__main__ import main  # noqa: E402

sys.exit(main())
