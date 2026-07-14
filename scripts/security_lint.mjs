import { readFileSync, readdirSync } from 'node:fs';
import { join } from 'node:path';

const root = new URL('..', import.meta.url).pathname;
const files = [];
const walk = dir => {
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    if (entry.name === '.git' || entry.name === '_site' || entry.name === 'node_modules') continue;
    const path = join(dir, entry.name);
    if (entry.isDirectory()) walk(path);
    else files.push(path);
  }
};
walk(root);

const errors = [];
const frontend = files.filter(x => /\.(?:html|js)$/i.test(x));
const sql = files.filter(x => /\.sql$/i.test(x));

for (const file of frontend) {
  const source = readFileSync(file, 'utf8');
  if (/service_role|sb_secret_/i.test(source)) errors.push(`${file}: secret/service role key in frontend`);
}

for (const file of sql) {
  const source = readFileSync(file, 'utf8');
  if (/grant\s+execute\s+on\s+function[\s\S]{0,300}\s+to\s+anon\b/i.test(source)) {
    errors.push(`${file}: function execution granted to anon`);
  }
}

const hotfix = join(root, 'phase1_10_security_hotfix.sql');
const hotfixSource = readFileSync(hotfix, 'utf8');
for (const required of [
  "'__unauthorized__'",
  'revoke execute on function',
  'alter default privileges',
  "where n.nspname = 'public' and p.prosecdef",
  "has_function_privilege('anon'"
]) {
  if (!hotfixSource.includes(required)) errors.push(`phase1_10_security_hotfix.sql: missing ${required}`);
}

if (errors.length) {
  console.error(`Security lint failed:\n- ${errors.join('\n- ')}`);
  process.exit(1);
}

console.log(`Security lint passed (${sql.length} SQL files, ${frontend.length} frontend files).`);
