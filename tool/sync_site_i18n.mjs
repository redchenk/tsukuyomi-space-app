// Copy every original locale key into native data. Does not modify the website.
// Usage: node tool/sync_site_i18n.mjs ../tsukuyomi-space
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import crypto from 'node:crypto';

const root = path.resolve(process.argv[2] || '../tsukuyomi-space');
const read = name => fs.readFileSync(path.join(root, 'src/frontend/i18n', name), 'utf8');
const strip = source => source.replace(/^import[^;]+;\s*/gm, '').replace(/export\s+(?=const)/g, '');
const { en } = vm.runInNewContext(`(function(){${strip(read('messages.en.js'))};return {en};})()`, {}, {timeout: 1000});
const { i18n } = vm.runInNewContext(`(function(){${strip(read('messages.js'))};return {i18n};})()`, {en}, {timeout: 1000});
const navigation = fs.readFileSync(path.join(root, 'src/frontend/services/siteNavigation.js'), 'utf8');
const navigationCopy = vm.runInNewContext(`(function(){${navigation.slice(0,navigation.indexOf('const aliases'))};return copy;})()`, {}, {timeout:1000});
const pet = fs.readFileSync(path.join(root, 'src/frontend/components/SitePet.vue'), 'utf8');
const petStart = pet.indexOf('const COPY ='), petEnd = pet.indexOf('\n\nconst frame',petStart);
const petData = vm.runInNewContext(`(function(){${pet.slice(petStart,petEnd)};return {COPY,GUIDES};})()`, {}, {timeout:1000});
function flatten(value, prefix = '', target = {}) {
  if (typeof value === 'string') target[prefix] = value;
  else for (const [key,item] of Object.entries(value)) flatten(item, prefix ? `${prefix}.${key}` : key, target);
  return target;
}
const extras = {};
const interfaceCopy = JSON.parse(fs.readFileSync(path.join(root, 'src/frontend/i18n/interface-catalog.json'), 'utf8'));
const nativeCopy = JSON.parse(fs.readFileSync('tool/native_ui_copy.json','utf8'));
const growth = fs.readFileSync(path.join(root, 'src/frontend/pages/GrowthPage.vue'), 'utf8');
const growthCopy = growth.slice(growth.indexOf('const copy ='), growth.indexOf('const localizedLevelTitles ='));
const growthLevels = growth.slice(growth.indexOf('const localizedLevelTitles ='), growth.indexOf('const levelTitle ='));
const growthLabels = growth.slice(growth.indexOf('function taskText('), growth.indexOf('function setState('));
for (const language of ['zh','ja','en']) {
  const growthData = vm.runInNewContext(`(function(){${growthCopy};${growthLevels};${growthLabels};return {copy,levels:localizedLevelTitles[props.lang],tasks:Object.fromEntries(['checkin','daily_share','daily_article_publish','daily_plaza_engage','daily_pixel_engage','daily_gallery_upload','daily_kaguya_run'].map(key=>[key,taskText({key})])),events:Object.fromEntries(['checkin','daily_chat','daily_share','daily_article_publish','daily_plaza_engage','daily_pixel_engage','daily_gallery_upload','daily_kaguya_run','referral_joined','referral_invite','article_view','article_like','article_bookmark','article_history'].map(key=>[key,eventText({key})]))};})()`, {props:{lang:language},computed:fn=>fn()}, {timeout:1000});
  extras[language] = {
    ...flatten(navigationCopy[language], 'navigation'),
    ...flatten(petData.COPY[language], 'guide'),
    ...Object.fromEntries(petData.GUIDES.flatMap(item => item[language].map((value,index) => [`guide.pages.${item.key}.${index}`,value]))),
    ...flatten(growthData.copy, 'growth'),
    ...flatten(growthData.levels, 'growth.levels'),
    ...flatten(growthData.tasks, 'growth.tasks'),
    ...flatten(growthData.events, 'growth.events'),
  };
  for (const [source, locales] of Object.entries(interfaceCopy)) {
    const key = `sourceUi.${crypto.createHash('sha1').update(source).digest('hex').slice(0,12)}`;
    extras[language][key] = language === 'zh' ? source : (locales[language] || source);
  }
  for (const [zh,ja,en] of nativeCopy) {
    const key = `nativeUi.${crypto.createHash('sha1').update(zh).digest('hex').slice(0,12)}`;
    extras[language][key] = ({zh,ja,en})[language].replaceAll('\\n','\n');
  }
  extras[language].nativeMcpEndpoint = {zh:'MCP 端点',ja:'MCP エンドポイント',en:'MCP endpoint'}[language];
  extras[language].nativeMcpTransport = {zh:'MCP 连接方式',ja:'MCP 接続方式',en:'MCP transport'}[language];
  extras[language].nativeMcpRest = {zh:'REST 桥接',ja:'REST ブリッジ',en:'REST bridge'}[language];
  extras[language].nativeMcpHint = {zh:'支持 REST 桥接和 Streamable HTTP，自动完成 MCP 握手。搜索和当前图片理解按白名单调用；工具结果仅作为参考资料。',ja:'REST ブリッジと Streamable HTTP に対応し、MCP の接続処理を自動で行います。検索と添付画像の理解は許可リストに従います。ツールの結果は参考情報です。',en:'Supports REST bridges and Streamable HTTP with automatic MCP initialization. Search and current image understanding follow the allowlist; tool results are reference material.'}[language];
  extras[language].nativeEditorCharacters = {zh:'{count} 字符 · 草稿自动保存在当前站点与账号下',ja:'{count}文字 · 下書きは現在のサイトとアカウントに自動保存されます',en:'{count} characters · Drafts save automatically for this site and account'}[language];
  extras[language].nativeEditorPreviewSync = {zh:'预览与发布后的文章使用同一套排版。',ja:'プレビューと公開後の記事は同じ書式を使用します。',en:'The preview uses the same typography as the published article.'}[language];
  extras[language].nativeEditorPreviewEmpty = {zh:'写下内容，这里会显示文章效果。',ja:'本文を書くと、ここに記事のプレビューが表示されます。',en:'Start writing to see your article here.'}[language];
  extras[language].nativeAuthResendSeconds = {zh:'{count}s 后重发',ja:'{count}秒後に再送',en:'Resend in {count}s'}[language];
  extras[language].nativeLive2DAudienceQueue = {zh:'{count} 条留言等待回应',ja:'{count}件のメッセージが返答待ち',en:'{count} messages waiting for a response'}[language];
  extras[language].nativeAssetPagination = {zh:'{total} 项 · 第 {page} / {pages} 页',ja:'{total}件 · {page} / {pages}ページ',en:'{total} items · Page {page} / {pages}'}[language];
}
const literal = value => JSON.stringify(value).replaceAll('$', '\\$');
let output = '// Generated by tool/sync_site_i18n.mjs. All keys from source messages.js/messages.en.js.\n';
output += 'const nativeSiteMessages = <String, Map<String, String>>{\n';
for (const language of ['zh', 'ja', 'en']) {
  const messages = i18n[language];
  if (!messages || Object.values(messages).some(value => typeof value !== 'string')) throw new Error(`Unsupported ${language} messages`);
  output += `  ${literal(language)}: {\n`;
  for (const [key,value] of Object.entries(messages)) output += `    ${literal(key)}: ${literal(value)},\n`;
  output += '  },\n';
}
output += '};\n';
output += 'const nativeSiteSupplementalMessages = <String, Map<String, String>>{\n';
for (const language of ['zh','ja','en']) {
  output += `  ${literal(language)}: {\n`;
  for (const [key,value] of Object.entries(extras[language])) output += `    ${literal(key)}: ${literal(value)},\n`;
  output += '  },\n';
}
output += '};\n';
fs.writeFileSync('lib/core/site_i18n_messages.dart', output);
console.log(Object.fromEntries(Object.entries(i18n).map(([lang,messages]) => [lang,Object.keys(messages).length])));
console.log('Navigation / guide keys:', Object.keys(extras.zh).length);
