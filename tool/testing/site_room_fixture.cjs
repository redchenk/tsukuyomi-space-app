// Run the website's real routes and SQLite repositories against disposable data.
// Only object storage is in-memory; no production OSS credentials or writes.
const path = require('node:path');
const root = path.resolve(process.argv[2] || '../tsukuyomi-space');
process.env.PORT = process.env.PORT || '4184';
require(path.join(root, 'tests/e2e-server.cjs'));
const storage = require(path.join(root, 'backend/services/object-storage.js'));
const objects = new Map();
storage.isConfigured = () => true;
storage.putObject = async ({buffer, mimeType, id}) => {
  const key = `native-fixture/${id}`;
  objects.set(key, {buffer:Buffer.from(buffer), type:mimeType, contentType:mimeType});
  return {key, url:`/assets/fixture/${id}`, provider:'fixture'};
};
storage.getObject = async key => objects.get(key);
storage.deleteObject = async key => objects.delete(key);
