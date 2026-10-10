// Minimal in-memory Cloud Storage JSON API (objects list / get / patch) for testing
// scripts/revoke-download-tokens.mjs through the real @google-cloud/storage client.
//
// It follows the documented GCS semantics the script relies on, which the Firebase Storage
// emulator does not model: PATCH merges custom metadata and a `null` value deletes the key,
// `ifGenerationMatch` / `ifMetagenerationMatch` answer 412, and every PATCH bumps metageneration.

import { createServer } from 'node:http';

export async function startFakeGcs() {
  /** bucket -> name -> { name, bucket, generation, metageneration, contentType, metadata? } */
  const buckets = new Map();
  /** "METHOD name" -> statuses to answer with before handling the request normally. */
  const injectedFailures = new Map();
  const requests = [];
  let generationCounter = 1_700_000_000_000_000;

  const objectsOf = (bucket) => {
    if (!buckets.has(bucket)) {
      buckets.set(bucket, new Map());
    }
    return buckets.get(bucket);
  };

  const sendJson = (response, status, body) => {
    response.writeHead(status, { 'content-type': 'application/json' });
    response.end(JSON.stringify(body));
  };
  const sendError = (response, status, message) => sendJson(response, status, {
    error: { code: status, message, errors: [{ message, reason: String(status) }] },
  });

  const server = createServer(async (request, response) => {
    let body = '';
    for await (const chunk of request) {
      body += chunk;
    }
    const url = new URL(request.url, 'http://fake');
    const path = url.pathname.replace(/^\/storage\/v1/, '');
    const match = /^\/b\/([^/]+)\/o(?:\/(.+))?$/.exec(path);
    if (!match) {
      sendError(response, 404, `Unknown path ${url.pathname}`);
      return;
    }
    const bucket = decodeURIComponent(match[1]);
    const name = match[2] === undefined ? undefined : decodeURIComponent(match[2]);
    requests.push({ method: request.method, bucket, name, query: Object.fromEntries(url.searchParams), body: body ? JSON.parse(body) : undefined });

    const failureKey = `${request.method} ${name ?? ''}`;
    const pending = injectedFailures.get(failureKey);
    if (pending?.length) {
      sendError(response, pending.shift(), 'Injected failure');
      return;
    }

    const objects = objectsOf(bucket);
    if (request.method === 'GET' && name === undefined) {
      const prefix = url.searchParams.get('prefix') ?? '';
      const pageSize = Math.min(Number(url.searchParams.get('maxResults') ?? 1000), 2); // Small pages exercise pagination.
      const start = Number(url.searchParams.get('pageToken') ?? 0);
      const matching = [...objects.values()].filter((object) => object.name.startsWith(prefix)).sort((a, b) => a.name.localeCompare(b.name));
      const page = matching.slice(start, start + pageSize);
      const nextPageToken = start + pageSize < matching.length ? String(start + pageSize) : undefined;
      sendJson(response, 200, { kind: 'storage#objects', items: page, nextPageToken });
      return;
    }

    const object = objects.get(name);
    if (!object) {
      sendError(response, 404, `No such object: ${bucket}/${name}`);
      return;
    }
    if (request.method === 'GET') {
      sendJson(response, 200, object);
      return;
    }
    if (request.method === 'PATCH') {
      const ifGeneration = url.searchParams.get('ifGenerationMatch');
      const ifMetageneration = url.searchParams.get('ifMetagenerationMatch');
      if ((ifGeneration !== null && ifGeneration !== object.generation)
        || (ifMetageneration !== null && ifMetageneration !== object.metageneration)) {
        sendError(response, 412, 'At least one of the pre-conditions you specified did not hold.');
        return;
      }
      const patch = body ? JSON.parse(body) : {};
      if (patch.metadata !== undefined) {
        const merged = { ...object.metadata };
        for (const [key, value] of Object.entries(patch.metadata ?? {})) {
          if (value === null) {
            delete merged[key];
          } else {
            merged[key] = String(value);
          }
        }
        if (patch.metadata === null || Object.keys(merged).length === 0) {
          delete object.metadata;
        } else {
          object.metadata = merged;
        }
      }
      object.metageneration = String(Number(object.metageneration) + 1);
      sendJson(response, 200, object);
      return;
    }
    sendError(response, 405, `${request.method} not supported`);
  });

  await new Promise((resolve) => {
    server.listen(0, '127.0.0.1', resolve);
  });

  return {
    url: `http://127.0.0.1:${server.address().port}`,
    requests,
    /** Adds an object; `tokens` (array) become `firebaseStorageDownloadTokens`. */
    put(bucket, name, { tokens = [], metadata = {} } = {}) {
      generationCounter += 1;
      const allMetadata = { ...metadata };
      if (tokens.length > 0) {
        allMetadata.firebaseStorageDownloadTokens = tokens.join(',');
      }
      const object = { kind: 'storage#object', name, bucket, generation: String(generationCounter), metageneration: '1', contentType: 'image/jpeg' };
      if (Object.keys(allMetadata).length > 0) {
        object.metadata = allMetadata;
      }
      objectsOf(bucket).set(name, object);
      return object;
    },
    get(bucket, name) {
      return objectsOf(bucket).get(name);
    },
    delete(bucket, name) {
      objectsOf(bucket).delete(name);
    },
    failNext(method, name, ...statuses) {
      injectedFailures.set(`${method} ${name}`, statuses);
    },
    reset() {
      buckets.clear();
      injectedFailures.clear();
      requests.length = 0;
    },
    close() {
      return new Promise((resolve) => {
        server.close(resolve);
        server.closeAllConnections();
      });
    },
  };
}
