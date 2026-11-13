// Provider selection by the name the admin picked (`examConversions/{jobId}.model.provider`, K9). There is no
// default: an unknown or missing name is an error the pipeline treats as "wait for an admin".

import { PROVIDERS } from '../schema.js';
import { createClaudeProvider } from './claude.js';
import { createGeminiProvider } from './gemini.js';

export { PROVIDER_CONFIG } from './config.js';
export { ProviderError } from './common.js';

const FACTORIES = Object.freeze({ claude: createClaudeProvider, gemini: createGeminiProvider });

/** A provider client for `name` ('claude' | 'gemini'); `options` go to its factory (tests inject `client`). */
export function createProvider(name, options = {}) {
  if (!PROVIDERS.includes(name)) throw new Error(`Unknown AI provider ${JSON.stringify(name)}`);
  return FACTORIES[name](options);
}

/** A memoised `getProvider(name)` for the live wiring: one client per provider per function instance. */
export function liveProviders(options = {}) {
  const cache = new Map();
  return (name) => {
    if (!cache.has(name)) cache.set(name, createProvider(name, options[name] ?? {}));
    return cache.get(name);
  };
}
