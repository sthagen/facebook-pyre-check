/**
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *
 * @format
 */

import * as React from 'react';
import Link from '@docusaurus/Link';

import type FlowJsServices from './flow-services';
import styles from './TryPyre2.module.css';

component DocsLink(kind: 'option' | 'lint', id: string) {
  let href;
  if (kind === 'lint') {
    href = `/en/docs/linting/rule-reference/#toc-${id}`;
  } else {
    const fragment = id.toLowerCase().replace(/[^a-z]/g, '-');
    href = `/en/docs/config/options/#toc-${fragment}`;
  }
  return <Link to={href}>[docs]</Link>;
}

component TryPyre2ConfigRows(
  name: string,
  schema: FlowJsConfigSchema,
  config: {[string]: mixed},
  setConfig: ({[string]: mixed}) => void,
) {
  return (
    <>
      {schema.length > 0 ? (
        <tr>
          <td colSpan={2}>
            <h3>{name}</h3>
          </td>
        </tr>
      ) : null}
      {schema.map(item => (
        <tr key={item.key}>
          <td className={styles.tryEditorConfigInputCell}>
            {item.type === 'enum' ? (
              <select
                value={config[item.key]}
                onChange={(event: SyntheticInputEvent<>) => {
                  setConfig({
                    ...config,
                    [item.key]: event.target.value,
                  });
                }}>
                {item.choices.map(choice => (
                  <option key={choice} value={choice}>
                    {choice}
                  </option>
                ))}
              </select>
            ) : (
              <input
                type="checkbox"
                id={item.key}
                checked={config[item.key]}
                onChange={(event: SyntheticInputEvent<>) => {
                  setConfig({
                    ...config,
                    [item.key]: event.target.checked,
                  });
                }}
              />
            )}
          </td>
          <td className={styles.tryEditorConfigLabelCell}>
            <label htmlFor={item.key}>
              <div className={styles.tryEditorConfigLabel}>{item.key}</div>
              {item.desc != null ? (
                <div>
                  {item.desc}
                  <DocsLink id={item.key} kind={item.kind} />
                </div>
              ) : null}
            </label>
          </td>
        </tr>
      ))}
    </>
  );
}

export default component TryPyre2ConfigEditor(
  flowService: ?FlowJsServices,
  setConfig: ({[string]: mixed}) => void,
) {
  if (flowService == null) {
    return 'Loading Flow configuration schema';
  }
  if (flowService?.schema == null) {
    return 'Configuration is not supported on this version of Flow.';
  }
  const [optionsSchema, lintsSchema] = flowService.schema.reduce<
    [FlowJsConfigSchema, FlowJsConfigSchema],
  >(
    ([optionsSchema, lintsSchema], config) => {
      if (config.kind === 'lint') {
        return [optionsSchema, lintsSchema.concat(config)];
      } else {
        return [optionsSchema.concat(config), lintsSchema];
      }
    },
    [[], []],
  );
  return (
    <table>
      <tbody>
        <TryPyre2ConfigRows
          name="Options"
          schema={optionsSchema}
          config={flowService.config}
          setConfig={setConfig}
        />
        <TryPyre2ConfigRows
          name="Lints"
          schema={lintsSchema}
          config={flowService.config}
          setConfig={setConfig}
        />
      </tbody>
    </table>
  );
}
