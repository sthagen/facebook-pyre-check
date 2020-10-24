/**
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

const {fbInternalOnly} = require("internaldocs-fb-helpers");

module.exports = {
  documentation: {
    "Pyre": [
      ...fbInternalOnly(["fb/getting-started"]),
      "getting-started",
      "installation",
      "configuration",
      "types-in-python",
      ...fbInternalOnly(["fb/increasing-type-coverage"]),
      "errors",
      "querying-pyre"
    ],
    "Pysa": [
      ...fbInternalOnly(["fb/pysa-basics-internal"]),
      "pysa-basics",
      ...fbInternalOnly(["fb/pysa-running-internal"]),
      ...fbInternalOnly(["fb/pysa-running-opensource-internal"]),
      ...fbInternalOnly(["fb/pysa-shipping-rules-models-internal"]),
      "pysa-running",
      "pysa-features",
      "pysa-advanced",
      ...fbInternalOnly(["fb/pysa-model-generators-internal"]),
      "pysa-model-generators",
      "pysa-model-dsl",
      "pysa-tips",
      ...fbInternalOnly(["fb/pysa-on-fbcode-internal"]),
      "pysa-coverage",
      ...fbInternalOnly(["fb/sapp-cli-internal"]),
      ...fbInternalOnly(["fb/sapp-ui-internal"]),
      "static-analysis-post-processor",
      ...fbInternalOnly(["fb/pysa-additional-resources-internal"]),
      "pysa-additional-resources"
    ]
  },
  ...fbInternalOnly(() => require('./fb/sidebars.js'))
}
