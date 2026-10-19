import js from '@eslint/js';
import globals from 'globals';
import tsParser from '@typescript-eslint/parser';
import tsPlugin from '@typescript-eslint/eslint-plugin';

const commonRules = {
  ...js.configs.recommended.rules,
  // warn on unused vars but ignore names starting with _
  'no-unused-vars': ['warn', {
    vars: 'all',
    args: 'after-used',
    ignoreRestSiblings: true,
    varsIgnorePattern: '^_',
    argsIgnorePattern: '^_'
  }],
  // Additional helpful rules
  'no-console': 'off',
  'no-unused-expressions': 'warn',
  'prefer-const': 'warn'
};

export default [
  {
    ignores: [
      'node_modules/**',
      'dist/**',
      'public/**',
      'coverage/**',
      'package-lock.json',
      '.vscode/**',
      '.env',
      '.idea/**',
      'mcp/**'
    ]
  },
  // JavaScript files (CommonJS)
  {
    files: ['**/*.js'],
    languageOptions: {
      ecmaVersion: 2022,
      sourceType: 'commonjs',
      globals: {
        ...globals.node,
        ...globals.es2021
      }
    },
    rules: {
      ...commonRules,
      'no-undef': 'error'
    }
  },

  // TypeScript files
  {
    files: ['**/*.ts', '**/*.tsx'],
    ignores: ['**/*.d.ts'],
    languageOptions: {
      ecmaVersion: 2022,
      sourceType: 'module',
      parser: tsParser,
      parserOptions: {
        ecmaVersion: 2022,
        sourceType: 'module'
      },
      globals: {
        ...globals.node,
        ...globals.es2021
      }
    },
    plugins: {
      '@typescript-eslint': tsPlugin
    },
    rules: {
      // Turn off JS-only rules that conflict with TypeScript
      'no-undef': 'off',
      'no-unused-vars': 'off',
      // Use TypeScript-aware no-unused-vars
      '@typescript-eslint/no-unused-vars': ['warn', { args: 'after-used', varsIgnorePattern: '^_', argsIgnorePattern: '^_' }],
      // Merge common rules
      ...commonRules
    }
  },

  // TypeScript declaration files - disable unused vars checking
  {
    files: ['**/*.d.ts'],
    languageOptions: {
      parser: tsParser
    },
    rules: {
      'no-unused-vars': 'off',
      '@typescript-eslint/no-unused-vars': 'off'
    }
  }
];