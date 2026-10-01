// Budget decoded work separately from repeated SSE/JSON protocol envelopes.
const agentMaxFileBytes = 1024 * 1024;
const agentMaxActionChars = 2 * 1024 * 1024;
const agentMaxModelBytes = 8 * 1024 * 1024;
const agentMaxJsonBytes = 16 * 1024 * 1024;
const agentMaxStreamBytes = 64 * 1024 * 1024;
