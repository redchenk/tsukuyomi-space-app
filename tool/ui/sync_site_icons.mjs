import fs from 'node:fs';
import vm from 'node:vm';
// Run against the reviewed website checkout; paths are the website's TsIcon API.
const source = fs.readFileSync(process.argv[2], 'utf8');
const start = source.indexOf('const iconPaths = ');
const end = source.indexOf('const paths = ', start);
if (start < 0 || end < 0) throw new Error('TsIcon source shape changed');
const paths = vm.runInNewContext(`${source.slice(start, end)}; iconPaths`, {}, {timeout: 1000});
const names = ['home','moon','plaza','book','crown','image','palette','gamepad','download','bot','compass','external','sparkles','rss','user','bell','menu','search','x','languages','sun','arrowLeft','arrowRight','settings','badge','github','lock','mail','keyRound','eye','eyeOff'];
const output = ['// Generated from website TsIcon.vue. Run tool/ui/sync_site_icons.mjs to update.', 'const siteIconSvg = <String, String>{'];
for (const name of names) {
  if (!paths[name]) throw new Error(`Missing icon ${name}`);
  const content = paths[name].map(([tag, attrs]) => `<${tag} ${Object.entries(attrs).map(([k,v]) => `${k}="${v}"`).join(' ')}/>`).join('');
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="#000" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">${content}</svg>`;
  output.push(`  '${name}': '${svg.replaceAll("'", "\\'")}',`);
}
output.push('};','');
fs.writeFileSync('lib/features/site/site_icon_data.dart',output.join('\n'));
