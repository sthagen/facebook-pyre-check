# Copyright (c) Facebook, Inc. and its affiliates.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.

import json
import logging
import os
import platform
import subprocess
import sys
import time
import traceback
from enum import Enum
from typing import Dict, Optional

from .configuration import Configuration  # noqa


LOG: logging.Logger = logging.getLogger(__name__)


class LoggerCategory(Enum):
    PERFORMANCE = "perfpipe_pyre_performance"
    USAGE = "perfpipe_pyre_usage"
    ANNOTATION_COUNTS = "perfpipe_pyre_annotation_counts"
    STRICT_ADOPTION = "perfpipe_pyre_strict_adoption"
    FIXME_COUNTS = "perfpipe_pyre_fixme_counts"
    QUALITY_ANALYZER = "perfpipe_pyre_quality_analyzer"
    QUALITY_ANALYZER_ISSUES = "perfpipe_pyre_quality_analyser_issues"
    BUCK_EVENTS = "perfpipe_pyre_buck_events"


def log(
    category: LoggerCategory,
    logger: str,
    integers: Optional[Dict[str, int]] = None,
    normals: Optional[Dict[str, Optional[str]]] = None,
) -> None:
    try:
        statistics = {
            "int": {**(integers or {}), "time": int(time.time())},
            "normal": {
                **(normals or {}),
                "command_line": " ".join(sys.argv),
                "host": platform.node() or "",
                "platform": platform.system() or "",
                "user": os.getenv("USER", ""),
            },
        }
        statistics = json.dumps(statistics).encode("ascii", "strict")
        subprocess.run([logger, category.value], input=statistics)
    except Exception:
        LOG.warning("Unable to log using `%s`", logger)
        LOG.info(traceback.format_exc())


def log_with_configuration(
    category: LoggerCategory,
    configuration: Configuration,
    integers: Optional[Dict[str, int]] = None,
    normals: Optional[Dict[str, Optional[str]]] = None,
) -> None:
    logger = configuration.logger
    if logger is None:
        return
    log(
        category=category,
        logger=logger,
        integers=integers,
        normals={
            **(normals or {}),
            "version": configuration.get_version_hash_respecting_override()
            or "unversioned",
            "configuration": str(configuration),
        },
    )
