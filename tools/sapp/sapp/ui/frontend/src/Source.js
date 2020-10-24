/**
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *
 * @format
 * @flow
 */

import React from 'react';
import {Alert, Button, Spin, Tooltip} from 'antd';
import {SelectOutlined} from '@ant-design/icons';
import {useQuery, gql} from '@apollo/client';
import {Controlled as CodeMirror} from 'react-codemirror2';

import './Source.css';
require('codemirror/lib/codemirror.css');
require('codemirror/mode/python/python.js');

function Source(
  props: $ReadOnly<{|path: string, location: string|}>,
): React$Node {
  // Parse location of format `line|column_start|column_end`.
  const split_location = props.location.split('|').map(i => parseInt(i));
  if (split_location.length !== 3) {
    throw new Error(`Invalid Location: ${props.location}`);
  }
  const line = split_location[0] - 1;
  const range = {
    from: {line, ch: split_location[1]},
    to: {line, ch: split_location[2]},
  };

  const SourceQuery = gql`
    query Issue($path: String) {
      file(path: $path) {
        edges {
          node {
            contents
          }
        }
      }
    }
  `;
  const {loading, error, data} = useQuery(SourceQuery, {
    variables: {path: props.path},
  });

  var content = <div />;
  if (error) {
    content = (
      <Alert
        message={`Unable to load ${props.path} (${error.toString()})`}
        type="error"
      />
    );
  } else if (loading) {
    content = (
      <div style={{height: '12em', textAlign: 'center', paddingTop: '5em'}}>
        <Spin tip={`Loading ${props.path}...`} />
      </div>
    );
  } else {
    const value = data.file.edges[0].node.contents;

    // React codemirror is horribly broken so store a reference to underlying
    // JS implementation.
    var editor = null;

    content = (
      <CodeMirror
        value={value}
        options={{lineNumbers: true, readOnly: 'nocursor'}}
        editorDidMount={nativeEditor => {
          editor = nativeEditor;
          if (range === null) {
            return;
          }
          editor.markText(range.from, range.to, {
            className: 'traceSelection',
          });
          editor.scrollIntoView({line, ch: 0});
        }}
      />
    );
  }

  return (
    <>
      <div class="source-menu">
        <Tooltip title="Reset Scroll" placement="bottom">
          <Button
            size="small"
            icon={<SelectOutlined />}
            type="text"
            onClick={() => editor && editor.scrollIntoView({line, ch: 0})}
            disabled={loading || error}
          />
        </Tooltip>
      </div>
      <div class="source">{content}</div>
    </>
  );
}

export default Source;
