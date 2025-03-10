# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.

# pyre-strict

"""
This module represents a very high level API for
all the processing that will be done by the Pyre server when a
'pyre query' command is invoked on the command line.

Queries can either operate with or without a long-standing Pyre daemon: the
modules daemon_query.py and no_daemon_query.py are responsible
for handling the low-level details of how those queries are executed.
"""

import json
import logging

from .. import (
    command_arguments,
    daemon_socket,
    frontend_configuration,
    identifiers,
    log,
)
from ..language_server import connections
from . import commands, daemon_query, no_daemon_query

LOG: logging.Logger = logging.getLogger(__name__)


HELP_MESSAGE: str = """
Possible queries:
  - attributes(class_name)
    Returns a list of attributes, including functions, for a class.
  - batch(query1(arg), query2(arg))
    Runs a batch of queries and returns a map of responses. List of given queries
    may include any combination of other valid queries except for `batch` itself.
  - callees(function)
    Calls from a given function.
  - callees_with_location(function)
    Calls from a given function, including the locations at which they are called.
  - defines(module_or_class_name)
    Returns a JSON with the signature of all defines for given module or class.
  - dump_call_graph()
    Returns a comprehensive JSON of caller -> list of callees.
  - global_leaks(function1, ...): analyzes the given function(s) and emits errors when
    global variables are mutated.
  - inline_decorators(qualified_function_name, decorators_to_skip=[decorator1, ...])
    Returns the function definition after inlining decorators.
    Allows skipping certain decorators when inlining.
  - less_or_equal(T1, T2)
    Returns whether T1 is a subtype of T2.
  - model_query(path, 'model_query_name')
    Returns in JSON a list of all models generated from the query with the name
    `model_query_name` in the directory `path`.
  - path_of_module(module)
    Gives an absolute path for `module`.
  - save_server_state('path')
    Saves Pyre's serialized state into `path`.
  - superclasses(class_name1, class_name2, ...)
    Returns a mapping of class_name to the list of superclasses for `class_name`.
    If no class name is provided, return the mapping for all classes Pyre knows about.
  - type(expression)
    Evaluates the type of `expression`.
  - types(path='path') or types('path1', 'path2', ...)
    Returns a map from each given path to a list of all types for that path.
  - validate_taint_models('optional path')
    Validates models and returns errors.
    Defaults to model path in configuration if no parameter is passed in.
"""


def _print_help_message() -> None:
    log.stdout.write(HELP_MESSAGE)


def run_query(
    configuration: frontend_configuration.Base, query_text: str
) -> commands.ExitCode:
    socket_path = daemon_socket.get_socket_path(
        configuration.get_project_identifier(),
        flavor=identifiers.PyreFlavor.CLASSIC,
    )
    try:
        if query_text == "help":
            _print_help_message()
            return commands.ExitCode.SUCCESS

        response = daemon_query.execute_query(socket_path, query_text)
        log.stdout.write(json.dumps(response.payload))
        return commands.ExitCode.SUCCESS
    except connections.ConnectionFailure:
        LOG.warning(
            "A running Pyre server is required for queries to be responded. "
            "Please run `pyre` first to set up a server."
        )
        return commands.ExitCode.SERVER_NOT_FOUND


def run(
    configuration: frontend_configuration.Base,
    query_arguments: command_arguments.QueryArguments,
) -> commands.ExitCode:
    if query_arguments.no_daemon:
        response = no_daemon_query.execute_query(
            configuration,
            query_arguments,
        )
        if response is not None:
            log.stdout.write(json.dumps(response.payload))
            return commands.ExitCode.SUCCESS
        else:
            return commands.ExitCode.FAILURE
    else:
        return run_query(configuration, query_arguments.query)
