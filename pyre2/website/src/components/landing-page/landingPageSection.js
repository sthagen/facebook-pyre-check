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
import clsx from 'clsx';
import featureDecorationStyles from './featureDecorationsStyles.module.css';
import {useState} from 'react';

export default component LandingPageSection(
  title: string,
  child: React.Node,
  isFirstSection: boolean = false,
  isLastSection: boolean = false,
  hasBrownBackground: boolean = false,
) {
  const [selectedSource, setSelectedSource] = useState('instagram');

  const backgroundColor = hasBrownBackground
    ? 'var(--color-background)'
    : 'var(--color-text)';
  return (
    <section
      {...stylex.props(
        styles.section,
        isLastSection ? styles.lastSection : null,
        {background: backgroundColor},
      )}>
      {/* Rise decoration (for all except first section) */}
      {!isFirstSection && (
        <div
          className={clsx(
            featureDecorationStyles.featureDecoration,
            featureDecorationStyles.featureDecorationRise,
          )}
          style={{
            color: backgroundColor,
          }}
        />
      )}

      {/* Drop decoration (for all sections) */}
      {!isLastSection && (
        <div
          className={clsx(
            featureDecorationStyles.featureDecoration,
            featureDecorationStyles.featureDecorationDrop,
          )}
          style={{
            color: backgroundColor,
          }}
        />
      )}
      <div className="container">
        <h2
          {...stylex.props(
            styles.sectionTitle,
            hasBrownBackground ? {color: 'var(--color-text)'} : null,
          )}>
          {title}
        </h2>
        {child}
      </div>
    </section>
  );
}

const styles = stylex.create({
  section: {
    flex: 1,
    position: 'relative',
    paddingVertical: 20,
  },
  lastSection: {
    paddingBottom: 30,
  },
  sectionTitle: {
    fontSize: '3rem',
  },
});
