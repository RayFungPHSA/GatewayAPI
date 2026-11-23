#!/usr/bin/env node
// Generate the read-only tool manifest from the official HPE Storage Fleet
// OpenAPI description. Only HTTP GET operations are emitted; mutating methods
// (POST, PUT, PATCH, DELETE) are intentionally excluded.
//
// Official API guide:
// https://developer.greenlake.hpe.com/docs/greenlake/services/storage-fleet/public/openapi/storage-fleet-public-v1alpha1/storage-fleet-api
//
// Usage:
//   node scripts/generate-readonly-manifest.mjs <path-to-storage-fleet-api.json>

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const specPath = process.argv[2];
if (!specPath) {
  console.error('Usage: node scripts/generate-readonly-manifest.mjs <path-to-storage-fleet-api.json>');
  process.exit(2);
}

const scriptDir = path.dirname(fileURLToPath(import.meta.url));
const outputPath = path.resolve(scriptDir, '..', 'src', 'greenlake-readonly-tools.json');
const spec = JSON.parse(fs.readFileSync(specPath, 'utf8'));

function deref(ref) {
  if (!ref || !ref.startsWith('#/')) return null;
  let value = spec;
  for (const part of ref.slice(2).split('/')) {
    value = value?.[part.replace(/~1/g, '/').replace(/~0/g, '~')];
    if (value == null) return null;
  }
  return value;
}

function resolveParameter(parameter) {
  if (!parameter?.$ref) return parameter || {};
  const resolved = deref(parameter.$ref);
  if (!resolved) throw new Error(`Cannot resolve parameter ${parameter.$ref}`);
  return resolved;
}

function resolveSchema(schema, depth = 0) {
  if (!schema || depth > 8) return {};
  if (schema.$ref) {
    const resolved = deref(schema.$ref);
    if (!resolved) throw new Error(`Cannot resolve schema ${schema.$ref}`);
    return resolveSchema(resolved, depth + 1);
  }
  if (schema.allOf?.length === 1) return resolveSchema(schema.allOf[0], depth + 1);
  return schema;
}

function snakeCase(value) {
  return String(value || '')
    .replace(/([a-z0-9])([A-Z])/g, '$1_$2')
    .replace(/([A-Z])([A-Z][a-z])/g, '$1_$2')
    .replace(/[^A-Za-z0-9]+/g, '_')
    .replace(/^_+|_+$/g, '')
    .toLowerCase();
}

const endpoints = [];
const seenNames = new Set();

for (const [requestPath, item] of Object.entries(spec.paths || {})) {
  const pathParameters = item.parameters || [];
  for (const [method, operation] of Object.entries(item)) {
    if (method !== 'get' || !operation || typeof operation !== 'object') continue;
    if (!operation.operationId) throw new Error(`GET ${requestPath} has no operationId`);

    const name = `greenlake_${snakeCase(operation.operationId)}`;
    if (seenNames.has(name)) throw new Error(`Duplicate generated tool name: ${name}`);
    seenNames.add(name);

    const parameters = [...pathParameters, ...(operation.parameters || [])]
      .map(resolveParameter)
      .filter((parameter, index, all) =>
        all.findIndex((other) =>
          other.name === parameter.name &&
          (other.in || 'query') === (parameter.in || 'query')
        ) === index
      )
      .map((parameter) => {
        if (!parameter.name) throw new Error(`GET ${requestPath} has an unnamed parameter`);
        const schema = resolveSchema(parameter.schema);
        return {
          name: parameter.name,
          in: parameter.in || 'query',
          required: parameter.required === true || parameter.in === 'path',
          type: schema.type || (schema.enum ? 'string' : 'string'),
          enum: Array.isArray(schema.enum) ? schema.enum : undefined,
          description: String(parameter.description || schema.description || '').trim(),
        };
      });

    const shapeKeys = new Set();
    for (const parameter of parameters) {
      if (shapeKeys.has(parameter.name)) {
        throw new Error(`GET ${requestPath} has duplicate argument name: ${parameter.name}`);
      }
      shapeKeys.add(parameter.name);
    }

    endpoints.push({
      name,
      tag: (operation.tags || [])[0] || 'untagged',
      description: String(operation.description || operation.summary || operation.operationId).trim(),
      path: requestPath,
      parameters,
    });
  }
}

endpoints.sort((a, b) => a.path.localeCompare(b.path) || a.name.localeCompare(b.name));

const manifest = {
  generatedAt: new Date().toISOString(),
  source: {
    title: spec.info?.title || 'HPE Greenlake For Storage Fleet REST APIs',
    version: spec.info?.version || 'unknown',
    openapi: spec.openapi || 'unknown',
    url: 'https://developer.greenlake.hpe.com/docs/greenlake/services/storage-fleet/public/openapi/storage-fleet-public-v1alpha1/storage-fleet-api',
  },
  note: 'Generated read-only GET operations only. Regenerate from the official OpenAPI description; do not edit by hand.',
  endpoints,
};

fs.writeFileSync(outputPath, JSON.stringify(manifest, null, 2) + '\n', 'utf8');
console.log(`Wrote ${endpoints.length} GET tools to ${outputPath}`);
