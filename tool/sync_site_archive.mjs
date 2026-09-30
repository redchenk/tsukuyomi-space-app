// Generate native, data-only archives from the adjacent original website.
// Usage: node tool/sync_site_archive.mjs ../tsukuyomi-space
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
const root = path.resolve(process.argv[2] || '../tsukuyomi-space');
const read = file => fs.readFileSync(path.join(root, 'src/frontend', file), 'utf8');
const strip = source => source.replace(/^import[^;]+;\s*/gm, '').replace(/export\s+(?=(?:const|function))/g, '');
function evaluate(file, names, supplied = {}) {
  return vm.runInNewContext(`(function(){${strip(read(file))};return {${names.join(',')}}})()`, supplied);
}
const media = evaluate('data/sourceMediaAssets.js', ['findSourceMedia', 'sourceMediaCount']);
const wikiNames = ['verifiedAt', 'tocEntries', 'infoRows', 'timeline', 'characterGroups', 'characters', 'terms', 'quickEntries', 'spoilerSteps', 'musicGroups', 'music', 'staff', 'cast', 'boxOfficeMilestones', 'derivativeWorks', 'references', 'navigationGroups'];
const wiki = evaluate('data/cosmicKaguyaWiki.js', wikiNames, media);
const entries = evaluate('data/cosmicKaguyaWikiEntries.js', ['allWikiEntries', 'relatedWikiEntries', 'entrySongs'], wiki);
const parser = evaluate('utils/mediaWikiArticle.js', ['parseMediaWikiArticle', 'parseKaguyaMediaWiki'], media);
wiki.entries = entries.allWikiEntries.map(entry => ({
  ...entry,
  related: entries.relatedWikiEntries(entry),
  songs: entries.entrySongs(entry),
  source: entry.sourceArticle ? (entry.sourceArticle === 'kaguya' ? parser.parseKaguyaMediaWiki : parser.parseMediaWikiArticle)(read(`data/wiki-sources/${entry.sourceArticle}.mediawiki`)) : null,
}));
const page = read('pages/WikiPage.vue');
wiki.sectionProse = Object.fromEntries(wiki.tocEntries.map(({id}) => {
  const start = page.indexOf(`<section id="${id}"`);
  const end = page.indexOf('</section>', start);
  const content = page.slice(start, end);
  const prose = [...content.matchAll(/<(p|blockquote)(?:\s[^>]*)?>([\s\S]*?)<\/\1>/g)]
    .filter(match => !match[2].includes('v-for') && !match[2].includes('{{'))
    .map(match => `<${match[1]}>${match[2]}</${match[1]}>`)
    .join('\n')
    .replace(/<button[^>]*openTerm\('([^']+)'[^>]*>([\s\S]*?)<\/button>/g, '<a href="/wiki/terms/$1">$2</a>')
    .replace(/<TsIcon[^>]*\/?>/g, '');
  return [id, prose];
}));
const locales = evaluate('i18n/messages.en.js', ['en']);
const {i18n} = evaluate('i18n/messages.js', ['i18n'], locales);
const realityScript = read('pages/RealityPage.vue').split('<script setup>')[1].split('</script>')[0];
const reality = vm.runInNewContext(`(function(){${strip(realityScript)};return {privacyHeaders:privacyHeaders.value,privacyRows:privacyRows.value,rightsCards:rightsCards.value,noticePrefixes:noticePrefixes.value};})()`, {
  defineProps: () => ({lang: 'zh', t: i18n.zh}), defineEmits: () => () => {}, computed: fn => ({get value() {return fn();}}),
});
reality.copy = Object.fromEntries(Object.entries(i18n.zh).filter(([key]) => key.startsWith('reality')));
// Include the same complete Chinese source/technology attributions as the site.
const template = read('pages/RealityPage.vue').split('<template>')[1];
reality.attributions = [...template.matchAll(/<p v-else-if="!isJa">([\s\S]*?)<\/p>/g)].map(match => match[1].trim());
reality.localized = Object.fromEntries(['ja', 'en'].map(lang => {
  const value = vm.runInNewContext(`(function(){${strip(realityScript)};return {privacyHeaders:privacyHeaders.value,privacyRows:privacyRows.value,rightsCards:rightsCards.value,noticePrefixes:noticePrefixes.value};})()`, {
    defineProps: () => ({lang, t: i18n[lang]}), defineEmits: () => () => {}, computed: fn => ({get value() {return fn();}}),
  });
  value.copy = Object.fromEntries(Object.entries(i18n[lang]).filter(([key]) => key.startsWith('reality')));
  const pattern = lang === 'en' ? /<p v-if="isEnglish">([\s\S]*?)<\/p>/g : /<p v-else>([\s\S]*?)<\/p>/g;
  value.attributions = [...template.matchAll(pattern)].map(match => match[1].trim());
  return [lang, value];
}));
const archive = {wiki, reality, access: Object.fromEntries(['title','heroCopy','access','connecting','loading','sync','welcome'].map(key => [key, i18n.zh[key]])), sourceCommit: fs.readFileSync(path.join(root,'.git/refs/heads/main'),'utf8').trim()};
let assetCount = 0;
const imageRoot = path.join(root, 'assets/images/wiki');
function visit(directory) {
  for (const entry of fs.readdirSync(directory, {withFileTypes:true})) {
    const source = path.join(directory, entry.name);
    if (entry.isDirectory()) visit(source);
    else {
      const relative = path.relative(path.join(root,'assets/images'), source).replaceAll(path.sep,'/');
      fs.copyFileSync(source, path.join('assets/images', relative.replaceAll('/','_')));
      assetCount++;
    }
  }
}
visit(imageRoot);
fs.copyFileSync(path.join(root,'assets/images/support/afdian-redchenk.jpg'),'assets/images/afdian-redchenk.jpg');
const json = JSON.stringify(archive);
if (json.includes("'''")) throw new Error('Dart raw string delimiter in archive');
fs.writeFileSync('lib/features/site/site_archive_data.dart', `// Generated by tool/sync_site_archive.mjs from the original website.\nconst siteArchiveJson = r'''${json}''';\n`);
console.log(`Generated ${wiki.entries.length} complete Wiki entries, ${assetCount} Wiki images and Reality / Access content.`);
