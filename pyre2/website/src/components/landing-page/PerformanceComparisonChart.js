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
import PerformanceComparisonButton from './PerformanceComparisonButton';
import ProgressBar from './ProgressBar';
import {
  Project,
  TypeChecker,
  type ProjectValue,
  type TypeCheckerValue,
} from './PerformanceComparisonTypes';

export default component PerformanceComparisonChart(project: ProjectValue) {
  const data = getData(project);

  // Calculate the maximum duration for scaling
  const maxDuration = Math.max(...data.map(item => item.durationInSeconds));

  return (
    <div key={project}>
      {data.map((typechecker, index) => (
        <div
          {...stylex.props(
            styles.barContainer,
            index !== data.length - 1 ? {marginBottom: 20} : null,
          )}
          key={index}>
          <span {...stylex.props(styles.typecheckerName)}>
            <strong>{typechecker.typechecker}</strong>
          </span>
          <div {...stylex.props(styles.progressBarContainer)}>
            <ProgressBar
              durationInSeconds={typechecker.durationInSeconds}
              maxDurationInSeconds={maxDuration}
            />
          </div>
          <span {...stylex.props(styles.duration)}>
            <strong>{`${typechecker.durationInSeconds}s`}</strong>
          </span>
        </div>
      ))}
    </div>
  );
}

const styles = stylex.create({
  barContainer: {
    flex: 1,
    display: 'flex',
    flexDirection: 'row',
  },
  typecheckerName: {
    display: 'inline-block',
    fontSize: 20,
    width: 150,
  },
  progressBarContainer: {
    flexGrow: 1,
    marginRight: 20,
  },
  duration: {
    marginLeft: 'auto',
  },
});

function getData(project: ProjectValue) {
  const filteredData = performanceComparsionChartData
    .filter(data => data.project === project)
    .map(data => data.data);

  if (filteredData.length === 0) {
    throw new Error(`No data found for project ${project}`);
  }

  return filteredData[0];
}

const performanceComparsionChartData = [
  {
    project: Project.PYTORCH,
    data: [
      {typechecker: TypeChecker.PYREFLY, durationInSeconds: 0.5},
      {typechecker: TypeChecker.MYPY, durationInSeconds: 8},
      {typechecker: TypeChecker.PYRIGHT, durationInSeconds: 5},
      {typechecker: TypeChecker.PYTYPE, durationInSeconds: 12},
      {typechecker: TypeChecker.PYRE1, durationInSeconds: 15},
    ],
  },
  {
    project: Project.INSTAGRAM,
    data: [
      {typechecker: TypeChecker.PYREFLY, durationInSeconds: 2},
      {typechecker: TypeChecker.MYPY, durationInSeconds: 50},
      {typechecker: TypeChecker.PYRIGHT, durationInSeconds: 20},
      {typechecker: TypeChecker.PYTYPE, durationInSeconds: 40},
      {typechecker: TypeChecker.PYRE1, durationInSeconds: 40},
    ],
  },
  {
    project: Project.EXAMPLE,
    data: [
      {typechecker: TypeChecker.PYREFLY, durationInSeconds: 2},
      {typechecker: TypeChecker.MYPY, durationInSeconds: 10},
      {typechecker: TypeChecker.PYRIGHT, durationInSeconds: 5},
      {typechecker: TypeChecker.PYTYPE, durationInSeconds: 12},
      {typechecker: TypeChecker.PYRE1, durationInSeconds: 12},
    ],
  },
];
