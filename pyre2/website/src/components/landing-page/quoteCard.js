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

export default component QuoteCard(
  quote: string,
  author: string,
  project: string,
) {
  return (
    <div {...stylex.props(styles.quoteCard)}>
      <p {...stylex.props(styles.quoteText)}>{quote}</p>
      <div {...stylex.props(styles.quoteAuthor)}>
        <strong>{author}</strong>
        <span>{project}</span>
      </div>
    </div>
  );
}

const styles = stylex.create({
  quoteCard: {
    padding: '2rem',
    borderRadius: '8px',
    boxShadow: '0 2px 8px rgba(0, 0, 0, 0.1)',
  },
  quoteText: {
    fontSize: '1.1rem',
    lineHeight: '1.6',
    marginBottom: '1.5rem',
    fontStyle: 'italic',
  },
  quoteAuthor: {
    display: 'flex',
    flexDirection: 'column',
    gap: '0.25rem',
  },
});
