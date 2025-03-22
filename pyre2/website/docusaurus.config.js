/**
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *
 * @format
 */

const {fbContent} = require('docusaurus-plugin-internaldocs-fb/internal');
const webpack = require('webpack');
const MonacoWebpackPlugin = require('monaco-editor-webpack-plugin');
const StylexPlugin = require('@stylexjs/webpack-plugin');

function getNavBarItems() {
  return [
    // TODO (T217317240) remove this check when we are ready to publish docs to public
    process.env.INTERNAL_STATIC_DOCS
      ? {
          to: 'en/docs/fb/',
          activeBasePath: 'en/docs/fb',
          label: 'Docs',
          position: 'left',
        }
      : null,
    {
      to: 'en/docs/learn-python-typing/',
      activeBasePath: 'en/docs/learn-python-typing',
      label: 'Learn Python Typing',
      position: 'left',
    },
    {
      to: 'try/',
      activeBasePath: 'try',
      label: 'Try',
      position: 'left',
    },
    // Please keep GitHub link to the right for consistency.
    {
      href: 'https://github.com/facebook/pyrefly',
      'aria-label': 'GitHub',
      position: 'right',
      className: 'navbar__icon github__link',
    },
  ].filter(x => x != null);
}

/** @type {import('@docusaurus/types').DocusaurusConfig} */
module.exports = {
  title: 'Pyrefly',
  tagline: 'A Static Type Checker for Python',
  url: 'https://pyrefly.org',
  baseUrl: process.env.DOCUSAURUS_BASE_URL || '/',
  onBrokenLinks: 'throw',
  onBrokenMarkdownLinks: 'warn',
  favicon: 'img/favicon.png',
  organizationName: 'facebook', // Usually your GitHub org/user name.
  projectName: 'Pyre', // Usually your repo name.
  trailingSlash: true,
  markdown: {
    mermaid: true,
  },
  themes: ['@docusaurus/theme-mermaid'],
  plugins: [
    function polyfillNodeBuiltinsForFlowJS(context, options) {
      return {
        name: 'polyfillNodeBuiltinsForFlowJS',
        configureWebpack() {
          return {resolve: {fallback: {fs: false, constants: false}}};
        },
      };
    },
    function enableSomeEnvVarsAsBuildTimeConstants() {
      return {
        name: 'enableSomeEnvVarsAsBuildTimeConstants',
        configureWebpack() {
          return {
            plugins: [
              new webpack.EnvironmentPlugin({
                INTERNAL_STATIC_DOCS: process.env.INTERNAL_STATIC_DOCS || false,
              }),
            ],
          };
        },
      };
    },
    function enableMonacoEditorPlugin() {
      return {
        name: 'enableMonacoEditorPlugin',
        configureWebpack() {
          return {
            // https://stackoverflow.com/questions/69265357/monaco-editor-worker
            plugins: [new MonacoWebpackPlugin()],
          };
        },
      };
    },
    function enableStyleX(context, options) {
      return {
        name: 'stylex-docusaurus',
        injectHtmlTags() {
          return {
            headTags: [
              {
                tagName: 'link',
                attributes: {
                  rel: 'stylesheet',
                  href: context.baseUrl + 'stylex.css',
                },
              },
            ],
          };
        },

        configureWebpack(config, isServer, utils) {
          const dev = config.mode === 'development';

          return {
            plugins: [
              new StylexPlugin({
                dev,
                genConditionalClasses: true,
                treeshakeCompensation: true,
                unstable_moduleResolution: {
                  type: 'commonJS',
                  rootDir: context.siteDir,
                },
                filename: 'stylex.css',
              }),
            ],
          };
        },
      };
    },
  ],
  themeConfig: {
    prism: {
      theme: require('prism-react-renderer').themes.github,
    },
    colorMode: {
      defaultMode: 'light',
      disableSwitch: true,
      respectPrefersColorScheme: false,
    },
    navbar: {
      title: 'Pyrefly',
      items: getNavBarItems(),
    },
    footer: {
      style: 'dark',
      links: [
        {
          title: 'Community',
          items: [
            {
              label: 'Discord',
              href: 'https://discord.gg/Cf7mFQtW7W',
            },
          ],
        },
        {
          title: 'More',
          items: [
            {
              label: 'Github',
              href: 'https://github.com/facebook/pyrefly',
            },
          ],
        },
        {
          title: 'Legal',
          // Please do not remove the privacy and terms, it's a legal requirement.
          items: [
            {
              label: 'Privacy',
              href: 'https://opensource.facebook.com/legal/privacy/',
            },
            {
              label: 'Terms',
              href: 'https://opensource.facebook.com/legal/terms/',
            },
            {
              label: 'Data Policy',
              href: 'https://opensource.facebook.com/legal/data-policy/',
            },
            {
              label: 'Cookie Policy',
              href: 'https://opensource.facebook.com/legal/cookie-policy/',
            },
          ],
        },
      ],
      logo: {
        alt: 'Facebook Open Source Logo',
        src: 'img/oss_logo.png',
        href: 'https://opensource.facebook.com',
      },
      // Please do not remove the credits, help to publicize Docusaurus :)
      copyright: `Copyright © ${new Date().getFullYear()} Meta Platforms, Inc. Built with Docusaurus.`,
    },
  },
  customFields: {
    fbRepoName: 'fbsource',
  },
  presets: [
    [
      require.resolve('docusaurus-plugin-internaldocs-fb/docusaurus-preset'),
      {
        docs: {
          routeBasePath: 'en/docs',
          sidebarPath: false, // TODO (T217317240): add back sidebar when we are ready to publish docs
          editUrl: fbContent({
            internal:
              'https://www.internalfb.com/code/fbsource/fbcode/tools/pyre/pyre2/website/',
            external: 'https://github.com/facebook/pyrefly/edit/main/website/',
          }),
        },
        staticDocsProject: 'Pyrefly',
        theme: {
          customCss: require.resolve('./src/css/custom.css'),
        },
        enableEditor: true,
        gtag: process.env.INTERNAL_STATIC_DOCS
          ? undefined
          : {trackingID: 'G-GSX14JC495', anonymizeIP: true},
      },
    ],
  ],
};
