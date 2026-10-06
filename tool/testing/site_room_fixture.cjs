// Run the website's real routes and SQLite repositories against disposable data.
// Only object storage is in-memory; no production OSS credentials or writes.
const path = require('node:path');
const fs = require('node:fs/promises');
const root = path.resolve(process.argv[2] || '../tsukuyomi-space');
process.env.PORT = process.env.PORT || '4184';
require('./model_protocol_fixture.cjs');
// The upstream router, owner checks and private SQLite sessions remain real.
// Only its external NetEase provider is replaced; no user account is contacted.
require(path.join(root, 'backend/services/netease-music')).createNeteaseMusic = () => ({
  qrKey: async () => 'native-music-fixture',
  qrCheck: async () => ({body: {code: 803}, cookie: 'MUSIC_U=fixture-not-a-user-cookie'}),
  profile: async () => ({id: '101', nickname: 'Native music fixture', avatar: ''}),
  search: async (_cookie, _query, offset) => ({tracks: [{id: String(offset + 1), title: 'Fixture song', artist: 'Fixture artist', album: 'Fixture album', cover: '', source: 'netease'}], total: 40, offset}),
  playlists: async (_cookie, _id, offset) => ({playlists: [{id: '201', title: 'Fixture playlist', count: 40}], more: offset === 0, offset}),
  playlist: async (_cookie, _id, offset) => ({tracks: [{id: String(offset + 1), title: 'Fixture song', artist: 'Fixture artist', source: 'netease'}], total: 40, offset}),
  playback: async () => ({url: 'https://music-fixture.example/audio.mp3', expiresIn: 180, trial: false}),
});
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
