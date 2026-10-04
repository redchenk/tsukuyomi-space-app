/// Allows isolated parallel fixtures without sharing another task's database.
const siteFixtureOrigin = String.fromEnvironment(
  'SITE_FIXTURE_ORIGIN',
  defaultValue: 'http://127.0.0.1:4184',
);
