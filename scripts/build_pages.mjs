import { copyFileSync, cpSync, existsSync, mkdirSync, readdirSync, rmSync } from 'node:fs';
import { join } from 'node:path';

const root = new URL('..', import.meta.url).pathname;
const out = join(root, '_site');
rmSync(out, { recursive: true, force: true });
mkdirSync(out, { recursive: true });

const publicFile = name => /^(?:index|404)\.html$/.test(name)
  || /^(?:favicon|og-image)\.svg$/.test(name)
  || /^phase[\w.-]+\.(?:js|css)$/.test(name)
  || /^(?:service-library)\.(?:js|css)$/.test(name);

for (const name of readdirSync(root)) {
  if (publicFile(name)) copyFileSync(join(root, name), join(out, name));
}

for (const directory of ['assets']) {
  const source = join(root, directory);
  if (existsSync(source)) cpSync(source, join(out, directory), { recursive: true });
}

const published = readdirSync(out).sort();
if (!published.includes('index.html')) throw new Error('index.html was not included in the Pages artifact');
if (published.some(name => /\.(?:sql|md)$/i.test(name))) throw new Error('Internal SQL/Markdown leaked into Pages artifact');
console.log(`Pages artifact ready: ${published.join(', ')}`);
