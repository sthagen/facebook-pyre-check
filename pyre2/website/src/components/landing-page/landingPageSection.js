/**
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *
 * @format
 */

import * as React from 'react';
import * as stylex from '@stylexjs/stylex';
import {useState} from 'react';

export default component LandingPageSection(
  title: string,
  child: React.Node,
  isLastSection: boolean = false,
) {
  const [selectedSource, setSelectedSource] = useState('instagram');

  return (
    <section
      {...stylex.props(
        styles.section,
        isLastSection ? styles.lastSection : null,
      )}>
      <div className="container">
        <h2 {...stylex.props(styles.sectionTitle)}>{title}</h2>
        {child}
      </div>
    </section>
  );
}

const styles = stylex.create({
  section: {
    flex: 1,
    marginTop: 20,
  },
  lastSection: {
    marginBottom: 30,
  },
  sectionTitle: {
    fontSize: '3rem',
  },
});
