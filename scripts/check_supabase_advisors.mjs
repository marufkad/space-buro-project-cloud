const token = process.env.SUPABASE_ACCESS_TOKEN;
const projectRef = process.env.SUPABASE_PROJECT_REF;

if (!token || !projectRef) {
  console.error('SUPABASE_ACCESS_TOKEN and SUPABASE_PROJECT_REF are required.');
  process.exit(2);
}

const response = await fetch(`https://api.supabase.com/v1/projects/${projectRef}/advisors/security`, {
  headers: { Authorization: `Bearer ${token}`, Accept: 'application/json' }
});

if (!response.ok) {
  console.error(`Supabase advisors request failed: ${response.status} ${await response.text()}`);
  process.exit(2);
}

const payload = await response.json();
const rows = Array.isArray(payload) ? payload : payload.lints || payload.advisors || payload.data || [];
const blocking = rows.filter(row => {
  const level = String(row.level || row.severity || '').toUpperCase();
  const text = JSON.stringify(row);
  return ['ERROR', 'WARN', 'WARNING'].includes(level)
    && /public can execute security definer|security definer function.*public|function.*executable.*anon/i.test(text);
});

if (blocking.length) {
  console.error('Blocking Supabase security advisors:');
  for (const row of blocking) console.error(JSON.stringify(row));
  process.exit(1);
}

console.log(`Supabase security advisors passed (${rows.length} findings checked).`);
