#!/bin/bash

# Copyright (c) 2018-present, Facebook, Inc.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.

set -e

# global constants
PACKAGE_NAME="pyre-check"
PACKAGE_VERSION=
AUTHOR='Facebook'
AUTHOR_EMAIL='pyre@fb.com'
MAINTAINER='Facebook'
MAINTAINER_EMAIL='pyre@fb.com'
URL='https://pyre-check.org/'
DOWNLOAD_URL='https://github.com/facebook/pyre-check'
# https://www.python.org/dev/peps/pep-0008/#package-and-module-names
MODULE_NAME="pyre_check"

RUNTIME_DEPENDENCIES="'typeshed', 'pywatchman', 'psutil', 'libcst', 'pyre_extensions'"

# helpers
die() {
  printf '\n%s: %s; exiting.\n' "$(basename "$0")" "$*" >&2
  exit 1
}
error_trap () {
  die "Command '${BASH_COMMAND}' failed at ${BASH_SOURCE[0]}:${BASH_LINENO[0]}"

}

trap error_trap ERR

# Compatibility settings with MacOS.
if [[ "${MACHTYPE}" = *apple* ]]; then
  READLINK=greadlink
  HAS_PIP_GREATER_THAN_1_5=no
  WHEEL_DISTRIBUTION_PLATFORM=macosx_10_11_x86_64
else
  READLINK=readlink
  HAS_PIP_GREATER_THAN_1_5=yes
  WHEEL_DISTRIBUTION_PLATFORM=manylinux1_x86_64
fi

# Parse arguments.
while [[ $# -gt 0 ]]; do
  case "${1}" in
    "--bundle-typeshed")
      shift 1
      if [[ -n "$1" && -d "$1" ]]; then
        echo "Selected typeshed location for bundling: ${1}"
        BUNDLE_TYPESHED="${1}"
        RUNTIME_DEPENDENCIES="'pywatchman', 'psutil', 'libcst', 'pyre_extensions'"

        # Attempt a basic validation of the provided directory.
        if [[ ! -d "${BUNDLE_TYPESHED}/stdlib" ]]; then
          echo
          echo 'The provided typeshed directory is not in the expected format:'
          echo '  it does not contain a "stdlib" subdirectory.'
          die 'Invalid typeshed directory'
        fi
      else
        die "Not a valid location to bundle typeshed from: '${1}'"
      fi
      ;;
    "--version")
      shift 1
      if [[ -z "${1}" ]]; then
        die 'Version number is missing from commandline'
      fi
      if ! [[ "${1}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        die "Version number '${1}' is not in the expected format"
      fi
      PACKAGE_VERSION="${1}"
      ;;
    *)
      echo "Unrecognized parameter: ${1}"
      ;;
  esac
  shift
done

# Check preconditions.
[[ -z "${PACKAGE_VERSION}" ]] && die 'Package version not provided, please use --version'

# Create build tree.
SCRIPTS_DIRECTORY="$(dirname "$("${READLINK}" -f "$0")")"
STUBS_DIRECTORY="$(dirname "${SCRIPTS_DIRECTORY}")/stubs"

# sapp directory is either beside or inside pyre-check directory
SAPP_DIRECTORY="${SCRIPTS_DIRECTORY}/../tools/sapp/"
if [[ ! -d "${SAPP_DIRECTORY}" ]]; then
  SAPP_DIRECTORY="${SCRIPTS_DIRECTORY}/../../sapp/"
fi



cd "${SCRIPTS_DIRECTORY}/"
BUILD_ROOT="$(mktemp -d)"
cd "${BUILD_ROOT}"
echo "Using build root: ${BUILD_ROOT}"

# Copy source files. We can't use longopts here because MacOS mkdir doesn't support --parents.
mkdir "${MODULE_NAME}"
# setup.py sdist will refuse to work for directories without a `__init__.py`.
touch "${MODULE_NAME}/__init__.py"
mkdir -p "${MODULE_NAME}/client"
mkdir -p "${MODULE_NAME}/tools/upgrade"
touch "${MODULE_NAME}/tools/__init__.py"
touch "${MODULE_NAME}/tools/upgrade/__init__.py"
# i.e. copy all *.py files from all directories, except "tests"
rsync -avm --filter='- tests/' --filter='+ */' --filter='-! *.py' "${SCRIPTS_DIRECTORY}/../client/" "${BUILD_ROOT}/${MODULE_NAME}/client"
rsync -avm --filter='- tests/' --filter='+ */' --filter='-! *.py' "${SCRIPTS_DIRECTORY}/../tools/upgrade/" "${BUILD_ROOT}/${MODULE_NAME}/tools/upgrade"

PYRE_ROOT="$(dirname "${SCRIPTS_DIRECTORY}")"
# Copy all .pysa stubs as well.
rsync -avm --filter='+ */' --filter='-! *.pysa' "${PYRE_ROOT}/stubs/taint" "${BUILD_ROOT}/"
rsync -avm --filter='+ */' --filter='-! *.pysa' "${PYRE_ROOT}/stubs/third_party_taint" "${BUILD_ROOT}/"
cp "${PYRE_ROOT}/stubs/taint/taint.config" "${BUILD_ROOT}/taint/taint.config"

# copy *.py and requirements.txt files from sapp, exclude everything else
rsync -avm --filter='- tests/' --filter='+ */' --filter='+ *.py' \
  --filter='+ *requirements.json' --filter='- *' "${SAPP_DIRECTORY}" \
  "${BUILD_ROOT}/${MODULE_NAME}/tools/sapp"

# Patch version number.
sed -i -e "/__version__/s/= \".*\"/= \"${PACKAGE_VERSION}\"/" "${BUILD_ROOT}/${MODULE_NAME}/client/version.py"

# Copy binary files.
BINARY_FILE="${SCRIPTS_DIRECTORY}/../_build/default/main.exe"
if [[ ! -f "${BINARY_FILE}" ]]; then
  echo "The binary file ${BINARY_FILE} does not exist."
  echo "Have you run 'make' in the toplevel directory?"
  exit 1
fi
mkdir -p "${BUILD_ROOT}/bin"
cp "${BINARY_FILE}" "${BUILD_ROOT}/bin/pyre.bin"

# Copy misc files.
cp "${SCRIPTS_DIRECTORY}/../README.md" \
   "${SCRIPTS_DIRECTORY}/../LICENSE" \
   "${BUILD_ROOT}/"

# Optional bundling of typeshed.
if [[ -n "${BUNDLE_TYPESHED}" ]]; then
  mkdir -p "${BUILD_ROOT}/typeshed/"
  rsync --recursive --copy-links --prune-empty-dirs --verbose \
        --chmod="+w" --include="stdlib/***" --include="third_party/***" --exclude="*" \
        "${BUNDLE_TYPESHED}/" "${BUILD_ROOT}/typeshed/"
fi

mkdir -p "${BUILD_ROOT}/stubs/"
rsync --recursive --copy-links --prune-empty-dirs --verbose \
      --chmod="+w" --include="django/***" --include="lxml/***" --exclude="*" \
      "${STUBS_DIRECTORY}/" "${BUILD_ROOT}/stubs/"


# Create setup.py file.
cat > "${BUILD_ROOT}/setup.py" <<HEREDOC
import glob
import json
import os
import sys
from pathlib import Path
from setuptools import setup, find_packages

if sys.version_info < (3, 5):
    sys.exit('Error: ${PACKAGE_NAME} only runs on Python 3.5 and above.')

def get_all_stubs(root: str):
    if not os.path.isdir(root):
        return []
    result = []
    for absolute_directory, _, _ in os.walk(root):
        relative_directory, files = get_data_files(
            directory=absolute_directory, extension_glob="*.pyi"
        )
        if not files:
            continue
        target = os.path.join("lib", "pyre_check", relative_directory)
        result.append((target, files))
    return result

def get_data_files(directory: str, extension_glob: str):
  # We need to relativize data_files, see https://github.com/pypa/wheel/issues/92.
  relative_directory = os.path.relpath(os.path.abspath(directory), os.getcwd())
  return (
      relative_directory,
      glob.glob(os.path.join(relative_directory, extension_glob)),
  )

def find_taint_stubs():
    _, taint_stubs = get_data_files(
        directory=os.path.join(os.getcwd(), "taint"), extension_glob="*"
    )
    _, third_party_taint_stubs = get_data_files(
        directory=os.path.join(os.getcwd(), "third_party_taint"), extension_glob="*"
    )
    taint_stubs += third_party_taint_stubs
    if not taint_stubs:
        return []
    return [(os.path.join("lib", "pyre_check", "taint"), taint_stubs)]


with open('README.md') as f:
    long_description = f.read()


setup(
    name='${PACKAGE_NAME}',
    version='${PACKAGE_VERSION}',
    description='A performant type checker for Python',
    long_description=long_description,
    long_description_content_type='text/markdown',

    url='${URL}',
    download_url='${DOWNLOAD_URL}',
    author='${AUTHOR}',
    author_email='${AUTHOR_EMAIL}',
    maintainer='${MAINTAINER}',
    maintainer_email='${MAINTAINER_EMAIL}',
    license='MIT',

    classifiers=[
        'Development Status :: 3 - Alpha',
        'Environment :: Console',
        'Intended Audience :: Developers',
        'License :: OSI Approved :: MIT License',
        'Operating System :: MacOS',
        'Operating System :: POSIX :: Linux',
        'Programming Language :: Python',
        'Programming Language :: Python :: 3',
        'Programming Language :: Python :: 3.5',
        'Programming Language :: Python :: 3.6',
        'Topic :: Software Development',
    ],
    keywords='typechecker development',

    packages=find_packages(exclude=['tests', 'pyre-check']),
    data_files=[('bin', ['bin/pyre.bin'])]
    + get_all_stubs(root=Path.cwd() / "typeshed")
    + get_all_stubs(root=Path.cwd() / "stubs/django")
    + get_all_stubs(root=Path.cwd() / "stubs/lxml")
    + find_taint_stubs(),
    python_requires='>=3.5',
    install_requires=[${RUNTIME_DEPENDENCIES}],
    extras_require={
      "sapp": ["click", "click-log", "ipython==7.6.1", "munch", "pygments", "SQLAlchemy", "ujson~=1.35", "xxhash~=1.3.0", "prompt-toolkit~=2.0.9"]
    },
    entry_points={
        'console_scripts': [
            'pyre = ${MODULE_NAME}.client.pyre:main',
            'pyre-upgrade = ${MODULE_NAME}.tools.upgrade.upgrade:main',
            'sapp = pyre_check.tools.sapp.sapp.cli:cli [sapp]',
        ],
    }
)
HEREDOC

export PACKAGE_VERSION
python3 setup.py sdist
mkdir -p "${SCRIPTS_DIRECTORY}/dist"

source_distribution_file="$(find "${BUILD_ROOT}/dist/" -type f | grep pyre-check)"
source_distribution_destination="$(basename "${source_distribution_file}")"
source_distribution_destination="${source_distribution_destination/%.tar.gz/.tar.gz}"

# Test descriptions before building:
# https://github.com/pypa/readme_renderer
if [[ "${HAS_PIP_GREATER_THAN_1_5}" == 'yes' ]]; then
  twine check "${BUILD_ROOT}/dist/*"
fi

# Create setup.cfg file.
cat > "${BUILD_ROOT}/setup.cfg" <<HEREDOC
[metadata]
license_file = LICENSE
HEREDOC


# Build.
python3 setup.py bdist_wheel


# Move artifact outside the build directory.
files_count="$(find "${BUILD_ROOT}/dist/" -type f | wc -l | tr -d ' ')"
[[ "${files_count}" == '2' ]] || \
  die "${files_count} files created in ${BUILD_ROOT}/dist, but two were expected"
wheel_source_file="$(find "${BUILD_ROOT}/dist/" -type f | grep any)"
wheel_destination="$(basename "${wheel_source_file}")"
wheel_destination="${wheel_destination/%-any.whl/-${WHEEL_DISTRIBUTION_PLATFORM}.whl}"
mv "${wheel_source_file}" "${SCRIPTS_DIRECTORY}/dist/${wheel_destination}"
mv "${source_distribution_file}" "${SCRIPTS_DIRECTORY}/dist/${source_distribution_destination}"


# Cleanup.
cd "${SCRIPTS_DIRECTORY}"
rm -rf "${BUILD_ROOT}"


printf '\nAll done.'
printf '\n Build artifact available at:\n  %s\n' "${SCRIPTS_DIRECTORY}/dist/${wheel_destination}"
printf '\n Source distribution available at:\n   %s\n' "${SCRIPTS_DIRECTORY}/dist/${source_distribution_destination}"
exit 0
