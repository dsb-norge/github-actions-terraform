"""The decision engine of the terraform CI/CD workflow: one JSON document in, one out.

Spec: docs/Decision-engine.md. Standard library only; the core never reads the network, the
clock or the process environment.
"""

SCHEMA_VERSION = 1
