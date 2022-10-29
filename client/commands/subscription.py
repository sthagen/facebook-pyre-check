# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.

"""
TODO(T132414938) Add a module-level docstring
"""


import dataclasses
import json
from typing import List, Union

from .. import error

from . import incremental


@dataclasses.dataclass(frozen=True)
class TypeErrors:
    errors: List[error.Error] = dataclasses.field(default_factory=list)


def _parse_type_error_subscription(response: object) -> TypeErrors:
    return TypeErrors(
        errors=incremental.parse_type_error_response_json(["TypeErrors", response])
    )


@dataclasses.dataclass(frozen=True)
class StatusUpdate:
    kind: str


def _parse_status_update_subscription(response: object) -> StatusUpdate:
    if not isinstance(response, list) or len(response) == 0:
        raise incremental.InvalidServerResponse(
            f"Status update subscription must be a nonempty list. Got {response}"
        )
    kind = response[0]
    if not isinstance(kind, str):
        raise incremental.InvalidServerResponse(
            f"Response kind of a status update must be a string. Got {response}"
        )
    return StatusUpdate(kind=kind)


@dataclasses.dataclass(frozen=True)
class Error:
    message: str


def _parse_error_subscription(response: object) -> Error:
    if not isinstance(response, str):
        raise incremental.InvalidServerResponse(
            f"Response kind of an error must be a string. Got {response}"
        )
    return Error(message=response)


Body = Union[TypeErrors, StatusUpdate, Error]


@dataclasses.dataclass(frozen=True)
class Response:
    body: Body

    @staticmethod
    def parse(response: str) -> "Response":
        try:
            response_json = json.loads(response)
            # The response JSON is expected to have the following forms:
            # `{"name": "foo", "body": ["TypeErrors", [error_json, ...]]}`
            # `{"name": "foo", "body": ["StatusUpdate", ["message_kind", ...]]}`
            # `{"name": "foo", "body": ["Error", "error message"]}`
            # The legacy subscription protocol includes a subscription name - we have
            # since moved away from requiring a name associated with a subscription, as
            # there aren't practical ways to set up multiple subscriptions on the same connection,
            # and a connection serves as a unique identifier for a subscription.

            # For backwards compatibility, we allow the "name" field to be in the response, but do not
            # parse it on the client.
            if isinstance(response_json, dict):
                body = response_json.get("body", None)
                if body is not None and isinstance(body, list) and len(body) > 1:
                    tag = body[0]
                    if tag == "TypeErrors":
                        return Response(body=_parse_type_error_subscription(body[1]))
                    elif tag == "StatusUpdate":
                        return Response(body=_parse_status_update_subscription(body[1]))
                    elif tag == "Error":
                        return Response(body=_parse_error_subscription(body[1]))
            raise incremental.InvalidServerResponse(
                f"Unexpected JSON subscription from server: {response_json}"
            )
        except json.JSONDecodeError as decode_error:
            message = f"Cannot parse subscription as JSON: {decode_error}"
            raise incremental.InvalidServerResponse(message) from decode_error

    @staticmethod
    def parse_code_navigation_response(response: str) -> "Response":
        # The response JSON has the form ["ResponseKind", response_body_json]
        try:
            response_json = json.loads(response)
            if not isinstance(response_json, list) or len(response_json) != 2:
                raise incremental.InvalidServerResponse(
                    f"Unexpected JSON subscription from code navigation server: {response_json}"
                )
            tag, body = response_json
            if tag == "ServerStatus":
                return Response(body=_parse_status_update_subscription(body))
            elif tag == "TypeErrors":
                return Response(body=_parse_type_error_subscription(body))
            elif tag == "Error":
                return Response(body=_parse_error_subscription(body))
            raise incremental.InvalidServerResponse(
                f"Invalid tag from code navigation server response: {tag}"
            )

        except json.JSONDecodeError as decode_error:
            message = f"Cannot parse subscription as JSON: {decode_error}"
            raise incremental.InvalidServerResponse(message) from decode_error
