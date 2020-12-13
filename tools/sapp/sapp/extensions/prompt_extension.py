#!/usr/bin/env python3
# Copyright (c) Facebook, Inc. and its affiliates.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.

# pyre-strict


from typing import List, Optional, Tuple

from IPython.core.interactiveshell import InteractiveShell
from IPython.core.magic import Magics
from IPython.terminal.prompts import Prompts, Token
from prompt_toolkit import Application as CommandLineInterface
from pygments.token import _TokenType

from ..ui.interactive import Interactive


class CustomPrompt(Prompts, Magics):
    def in_prompt_tokens(
        self, cli: Optional[CommandLineInterface] = None
    ) -> List[Tuple[_TokenType, str]]:
        user_ns = self.shell.user_ns
        interactive: Interactive = user_ns[Interactive.SELF_SCOPE_KEY]
        tokens = []

        if interactive._current_run_id > 0:
            tokens.extend(
                [
                    (Token.Punctuation, "[ "),
                    (Token, f"run {interactive._current_run_id} "),
                ]
            )

        if interactive.current_issue_instance_id > 0:
            tokens.append((Token, f"> issue {interactive.current_issue_instance_id} "))
        elif interactive.current_frame_id > 0:
            tokens.append((Token, f"> frame {interactive.current_frame_id} "))

        current_callable = interactive.callable()
        if current_callable:
            tokens.append((Token.Name, f"> {current_callable} "))

        if len(tokens) > 0:
            tokens.append((Token.Punctuation, "]"))

        tokens.append((Token.Prompt, "\n>>> "))

        return tokens


def load_ipython_extension(ipython: InteractiveShell) -> None:
    # pyre-fixme[16]: `InteractiveShell` has no attribute `prompts`.
    ipython.prompts = CustomPrompt(ipython)
