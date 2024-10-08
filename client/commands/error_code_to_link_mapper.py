# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.

# pyre-strict

from __future__ import annotations

error_code_to_fragment: dict[int, str] = {
    0: "0-unused-ignore",
    2: "2-missing-parameter-annotation",
    3: "3-missing-return-annotation",
    4: "4-missing-attribute-annotation",
    5: "5-missing-global-annotation",
    6: "6-incompatible-parameter-type",
    7: "7-incompatible-return-type",
    8: "8-incompatible-attribute-type",
    9: "9-incompatible-variable-type",
    10: "10-unbound-name",
    11: "1131-undefined-or-invalid-type",
    12: "12-incompatible-awaitable-type",
    13: "13-uninitialized-attribute",
    14: "1415-behavioral-subtyping",
    15: "1415-behavioral-subtyping",
    16: "16-missing-attributes",
    17: "17-incompatible-constructor-annotation",
    18: "1821-undefined-name-undefined-import",
    21: "1821-undefined-name-undefined-import",
    19: "19-too-many-argument",
    20: "20-missing-argument",
    22: "22-redundant-cast",
    23: "23-unable-to-unpack",
    24: "24-invalid-type-parameters",
    26: "26-typed-dictionary-access-with-non-literal",
    27: "27-typed-dictionary-key-not-found",
    28: "28-unexpected-keyword",
    29: "29-call-error",
    30: "3036-terminating-analysis,-mutually-recursive-type-variables",
    36: "3036-terminating-analysis,-mutually-recursive-type-variables",
    31: "31-invalid-type",
    32: "32-invalid-argument",
    33: "33-prohibited-any",
    34: "34-invalid-type-variable",
    35: "35-illegal-annotation-target",
    39: "39-invalid-inheritance",
    40: "40-invalid-override",
    41: "41-invalid-assignment",
    42: "42-missing-overload-implementation",
    43: "43-incompatible-overload-implementation",
    45: "45-invalid-class-instantiation",
    46: "46-invalid-type-variance",
    47: "47-invalid-method-signature",
    48: "48-invalid-exception",
    49: "49-unsafe-cast",
    51: "51-unused-local-mode",
    52: "52-private-protocol-property",
    53: "53-missing-annotation-for-captured-variables",
    54: "54-invalid-typeddict-operation",
    55: "55-typeddict-initialization-error",
    56: "56-invalid-decoration",
    57: "57-incompatible-async-generator-return-type",
    58: "58-unsupported-operand",
    59: "59-duplicate-type-variables",
    60: "60-unable-to-concatenate-tuple",
    61: "61-uninitialized-local",
    62: "62-non-literal-string",
}
