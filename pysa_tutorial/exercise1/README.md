# Running Pysa
## Overview
The purpose of this exercise is to get familiar with the various elements which are required to run Pysa: sources and sinks in `.pysa` files, configuration in the `.pyre_configuration` file, and rules in the `taint.config` file.

**Note: Make sure you've done the setup described in the parent directory's `README.md` already**

## What you need to know
### `views.py`
Open `views.py` and notice that there is a Remote Code Execution (RCE) vulnerability in the function, which we want to catch with Pysa. To catch it, Pysa will need to know that `request.GET` contains user controlled data, that `eval` can execute code, and that we want to identify when user controlled data reaches a code execution sink.

### `taint.config`
Open `taint.config` and notice that this is where we write a _rule_ to tell Pysa that RCE is when a _source_ of `UserSpecified` data reaches a `CodeExecution` _sink_.

### `sources_sinks.pysa`
Open `sources_sinks.pysa` and notice that this where we tell Pysa that `request.GET` is a `TaintSource` for `UserSpecified` data and `eval` is a `TaintSink` for `CodeExecution`.

### `.pyre_configuration`
Take a brief peek at the `.pyre_configuration` file. Note that `"source_directories": ["."]` and `"taint_models_path": ["."]` are simply telling Pysa to look in the current directory for code to analyze and `.pysa`/`taint.config` files respectively. `"search_path": ["../../stubs/"]` gives Pyre another place to look to discover stub files for Pysa.

## Instructions

1. In this directory run:

   `pyre analyze`

   It may output some messages saying `During override analysis, can't find model for`, and this is OK.

1. The last portion of the output should be a JSON array, containing a list of _issues_ Pysa found. Confirm that the issue points to the function `views.operate_on_twos` and that the message says it is `Possible RCE`.
