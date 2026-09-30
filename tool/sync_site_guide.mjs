// Reproduce the original SitePet data and non-streaming usage-guide prompt.
// Usage: node tool/sync_site_guide.mjs ../tsukuyomi-space
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
const root = path.resolve(process.argv[2] || '../tsukuyomi-space');
const read = name => fs.readFileSync(path.join(root, 'src/frontend', name), 'utf8');
const strip = source => source.replace(/^import[^;]+;\s*/gm, '').replace(/export\s+(?=(?:async\s+)?(?:const|function))/g, '');
const pet = read('components/SitePet.vue').split('<script setup>')[1].split('const frame = ref')[0];
const data = vm.runInNewContext(`(function(){${strip(pet)};return {copy:COPY,guides:GUIDES,sequences:SEQUENCES};})()`, {defineProps: () => ({}), defineEmits: () => () => {}});
const guide = strip(read('services/siteGuideLlm.js'));
data.prompts = vm.runInNewContext(`(function(){${guide};return Object.fromEntries(['zh','ja','en'].map(lang => [lang,guideSystemPrompt(lang,'__SITE_ROUTE__')]));})()`);
fs.writeFileSync('lib/features/site/site_guide_data.dart', `// Generated from original SitePet.vue and siteGuideLlm.js.\nconst siteGuideJson = r'''${JSON.stringify(data)}''';\n`);
for (const [source, target] of [['spritesheet-perf-r2.webp','site-pet-yachiyo-sprites.webp'],['idle.webp','site-pet-yachiyo-idle.webp']]) {
  fs.copyFileSync(path.join(root,'assets/pets/yachiyo',source), path.join('assets/images',target));
}
console.log(`Generated ${data.guides.length} guides, ${Object.keys(data.sequences).length} sprite sequences and three complete language copies/prompts.`);
