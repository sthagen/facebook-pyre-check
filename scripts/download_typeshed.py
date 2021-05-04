# Copyright (c) Facebook, Inc. and its affiliates.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.

import argparse
import dataclasses
import io
import json
import logging
import pathlib
import shutil
import urllib.request
import zipfile
from typing import List, Optional

LOG: logging.Logger = logging.getLogger(__name__)


@dataclasses.dataclass(frozen=True)
class FileEntry:
    path: str
    # If `data` is None, `path` refers to a directory.
    # Otherwise, `path` refers to a file
    data: Optional[bytes]


@dataclasses.dataclass(frozen=True)
class FileCount:
    kept: int
    dropped: int


@dataclasses.dataclass(frozen=True)
class Statistics:
    stdlib: FileCount
    third_party: FileCount
    third_party_package_count: int


@dataclasses.dataclass(frozen=True)
class TypeshedTrimmingResult:
    entries: List[FileEntry]
    statistics: Statistics


def get_default_typeshed_url() -> str:
    commit_hash = json.loads(
        urllib.request.urlopen(
            "https://api.github.com/repos/python/typeshed/commits/master"
        )
        .read()
        .decode("utf-8")
    )["sha"]
    LOG.info(f"Found typeshed master at commit {commit_hash}")
    return f"https://api.github.com/repos/python/typeshed/zipball/{commit_hash}"


def get_typeshed_url(specified_url: Optional[str] = None) -> str:
    if specified_url is not None:
        return specified_url
    LOG.info("Typeshed URL not specified. Trying to auto-determine it...")
    default_url = get_default_typeshed_url()
    if default_url is None:
        raise RuntimeError(
            "Cannot determine the default typeshed URL. "
            + "Please manually specify one with `--url` argument. "
            + "If the download still fails, please check network connectivity."
        )
    return default_url


def trim_typeshed_zip(zip_file: zipfile.ZipFile) -> TypeshedTrimmingResult:
    result_info = []

    stdlib_kept_count = 0
    stdlib_dropped_count = 0
    third_party_kept_count = 0
    third_party_dropped_count = 0
    third_party_package_count = 0
    for info in zip_file.infolist():
        parts = pathlib.Path(info.filename).parts

        if len(parts) <= 1:
            # Entry for the top-level directory
            result_info.append(info)
        elif parts[1] == "stdlib":
            # Python standard library
            if "@python2" in parts:
                if not info.is_dir():
                    stdlib_dropped_count += 1
            else:
                if not info.is_dir():
                    stdlib_kept_count += 1
                result_info.append(info)

        elif parts[1] == "stubs":
            # Third-party libraries
            if "@python2" in parts:
                if not info.is_dir():
                    third_party_dropped_count += 1
            else:
                if not info.is_dir():
                    third_party_kept_count += 1
                elif len(parts) == 3:
                    # Top-level directory of a third-party stub
                    third_party_package_count += 1
                result_info.append(info)

    return TypeshedTrimmingResult(
        entries=[
            FileEntry(
                # Other scripts expect the toplevel directory name to be
                # `typeshed-master`
                path=str(
                    pathlib.Path("typeshed-master").joinpath(
                        *pathlib.Path(info.filename).parts[1:]
                    )
                ),
                data=None if info.is_dir() else zip_file.read(info),
            )
            for info in result_info
        ],
        statistics=Statistics(
            stdlib=FileCount(kept=stdlib_kept_count, dropped=stdlib_dropped_count),
            third_party=FileCount(
                kept=third_party_kept_count, dropped=third_party_dropped_count
            ),
            third_party_package_count=third_party_package_count,
        ),
    )


def download_typeshed(url: str) -> io.BytesIO:
    downloaded = io.BytesIO()
    with urllib.request.urlopen(url) as response:
        shutil.copyfileobj(response, downloaded)
    return downloaded


def trim_typeshed(downloaded: io.BytesIO) -> TypeshedTrimmingResult:
    with zipfile.ZipFile(downloaded) as zip_file:
        return trim_typeshed_zip(zip_file)


def log_trim_statistics(statistics: Statistics) -> None:
    LOG.info(
        f"Kept {statistics.stdlib.kept} files and dropped "
        + f"{statistics.stdlib.dropped} files from stdlib."
    )
    LOG.info(
        f"Kept {statistics.third_party.kept} files and dropped "
        + f"{statistics.third_party.dropped} files from third-party libraries."
    )
    LOG.info(
        "Total number of third-party packages is "
        + f"{statistics.third_party_package_count}."
    )


def write_output(trim_result: TypeshedTrimmingResult, output: str) -> None:
    with zipfile.ZipFile(output, mode="w") as output_file:
        for entry in trim_result.entries:
            data = entry.data
            if data is not None:
                output_file.writestr(entry.path, data)
            else:
                # Zipfile uses trailing `/` to determine if the file is a directory.
                output_file.writestr(f"{entry.path}/", bytes())


def main() -> None:
    parser = argparse.ArgumentParser(
        description="A script to download and trim typeshed zip file."
    )
    parser.add_argument(
        "-u",
        "--url",
        type=str,
        help=(
            "URL from which typeshed zip file is downloaded. "
            + "If not set, default to the current typeshed mater on github."
        ),
    )
    parser.add_argument(
        "-o",
        "--output",
        required=True,
        type=str,
        help="Where to store the downloaded typeshed zip file.",
    )
    arguments = parser.parse_args()
    logging.basicConfig(
        format="[%(asctime)s][%(levelname)s]: %(message)s", level=logging.INFO
    )

    url = get_typeshed_url(arguments.url)
    downloaded = download_typeshed(url)
    LOG.info(f"{downloaded.getbuffer().nbytes} bytes downloaded from {url}")
    trimmed_typeshed = trim_typeshed(downloaded)
    log_trim_statistics(trimmed_typeshed.statistics)
    write_output(trimmed_typeshed, arguments.output)
    LOG.info(f"Zip file written to {arguments.output}")


if __name__ == "__main__":
    main()
