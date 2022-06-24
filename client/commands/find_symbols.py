# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.

import ast
import dataclasses
from typing import List, Union

from .language_server_protocol import (
    DocumentSymbolsResponse,
    LspRange,
    Position,
    SymbolKind,
)


@dataclasses.dataclass(frozen=True)
class SymbolInfo:
    name: str
    start_pos: Position
    end_pos: Position
    kind: SymbolKind


def _node_to_symbol(
    node: Union[ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef]
) -> DocumentSymbolsResponse:
    node_is_class_def = isinstance(node, ast.ClassDef)
    symbol_info = SymbolKind.CLASS if node_is_class_def else SymbolKind.FUNCTION

    visitor = _SymbolsCollector(node_is_class_def)
    visitor.generic_visit(node)
    symbol_info = _generate_lsp_symbol_info(node, node.name, symbol_info)
    document_symbols_response = _create_document_symbols_response(
        symbol_info, visitor.symbols
    )
    return document_symbols_response


def _create_document_symbols_response(
    symbol_info: SymbolInfo, children_symbols: List[DocumentSymbolsResponse]
) -> DocumentSymbolsResponse:
    return DocumentSymbolsResponse(
        name=symbol_info.name,
        # TODO(114362484): add docstrings to details
        detail="",
        kind=symbol_info.kind,
        range=LspRange(
            start=symbol_info.start_pos.to_lsp_position(),
            end=symbol_info.end_pos.to_lsp_position(),
        ),
        selection_range=LspRange(
            start=symbol_info.start_pos.to_lsp_position(),
            end=symbol_info.end_pos.to_lsp_position(),
        ),
        children=children_symbols,
    )


def _generate_lsp_symbol_info(node: ast.AST, name: str, kind: SymbolKind) -> SymbolInfo:
    start = Position(line=node.lineno, character=node.col_offset)
    try:
        end_lineno, end_col_offset = (node.end_lineno, node.end_col_offset)
    except AttributeError:
        # Python 3.7's ast does not have these attributes. Degrade grcefully.
        end_lineno, end_col_offset = None, None
    end = None
    if end_lineno is not None and end_col_offset is not None:
        end = Position(line=end_lineno, character=end_col_offset)
    else:
        end = Position(line=node.lineno, character=node.col_offset + len(name))
    return SymbolInfo(name, start, end, kind)


class _SymbolsCollector(ast.NodeVisitor):
    symbols: List[DocumentSymbolsResponse]
    parent_is_class_def: bool

    def __init__(self, parent_is_class_def: bool) -> None:
        super().__init__()
        self.symbols = []
        self.parent_is_class_def = parent_is_class_def

    def visit_FunctionDef(self, node: ast.FunctionDef) -> None:
        self.symbols.append(_node_to_symbol(node))

    def visit_AsyncFunctionDef(self, node: ast.AsyncFunctionDef) -> None:
        self.symbols.append(_node_to_symbol(node))

    def visit_ClassDef(self, node: ast.ClassDef) -> None:
        self.symbols.append(_node_to_symbol(node))

    def visit_Assign(self, node: ast.Assign) -> None:
        if self.parent_is_class_def:
            children_symbol_info = [
                _generate_lsp_symbol_info(
                    current_target, current_target.id, SymbolKind.PROPERTY
                )
                for current_target in node.targets
                if isinstance(current_target, ast.Name)
            ]
            self.symbols.extend(
                [
                    _create_document_symbols_response(symbol, [])
                    for symbol in children_symbol_info
                ]
            )

    def visit_AnnAssign(self, node: ast.AnnAssign) -> None:
        if self.parent_is_class_def:
            if isinstance(node.target, ast.Name):
                symbol_info = _generate_lsp_symbol_info(
                    node.target, node.target.id, SymbolKind.PROPERTY
                )
                self.symbols.append(_create_document_symbols_response(symbol_info, []))


class UnparseableError(Exception):
    pass


# TODO(114362484): 1) Support details filled with docstrings/comments 2) incremental re-parsing via tree-sitter.
def parse_source_and_collect_symbols(source: str) -> List[DocumentSymbolsResponse]:
    try:
        ast_tree = ast.parse(source=source, mode="exec")
    except Exception as e:
        raise UnparseableError(e)
    visitor = _SymbolsCollector(False)
    visitor.visit(ast_tree)
    return visitor.symbols
