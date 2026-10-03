// Run the website's real routes and SQLite repositories against disposable data.
// Only object storage is in-memory; no production OSS credentials or writes.
const path = require('node:path');
const fs = require('node:fs/promises');
const root = path.resolve(process.argv[2] || '../tsukuyomi-space');
process.env.PORT = process.env.PORT || '4184';
require('./model_protocol_fixture.cjs');
require(path.join(root, 'tests/e2e-server.cjs'));
const storage = require(path.join(root, 'backend/services/object-storage.js'));
const objects = new Map();
storage.isConfigured = () => true;
storage.putObject = async ({buffer, filePath, mimeType, id}) => {
  const key = `native-fixture/${id}`;
  const bytes = buffer == null ? await fs.readFile(filePath) : Buffer.from(buffer);
  objects.set(key, {buffer:bytes, type:mimeType, contentType:mimeType});
  return {key, url:`/assets/fixture/${id}`, provider:'fixture'};
};
storage.getObject = async key => objects.get(key);
storage.deleteObject = async key => objects.delete(key);
