#!/usr/bin/env node
// publish.mjs - create the GitHub repo, push, and publish a release with the skill zip.
// Transport: curl.exe (Node fetch is unreliable on some Windows network stacks).
// Auth: GH_TOKEN env var only. Never printed, never written to disk, never put in a git remote URL.
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const TOKEN = process.env.GH_TOKEN || '';
if (!TOKEN) { console.error('GH_TOKEN is not set.'); process.exit(1); }

const NAME = 'dsh-windows-shell-setup';
const DESCRIPTION = 'Agent skill: give DeepSeek Harness a real bash executor on Windows (PortableGit + PowerShell 7), no admin, fully revertible.';
const TOPICS = ['dsh', 'deepseek-harness', 'agent-skills', 'agent-skill', 'windows', 'git-bash', 'bash', 'powershell', 'portablegit', 'shell'];
const TAG = process.env.RELEASE_TAG || 'v1.0.0';
const ASSET = process.env.RELEASE_ASSET || 'E:/DSH/dist/dsh-windows-shell-setup-20261110.zip';
const REPO_DIR = path.dirname(new URL(import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, '$1'));

function curl(args) {
  return execFileSync('curl.exe', ['-sS', '--max-time', '60', ...args], { encoding: 'utf8', maxBuffer: 32 * 1024 * 1024 });
}
function api(method, endpoint, body) {
  const args = ['-X', method, '-H', 'Authorization: Bearer ' + TOKEN, '-H', 'User-Agent: dsh-agent', '-H', 'Accept: application/vnd.github+json', '-w', '\n%{http_code}'];
  if (body !== undefined) {
    const tmp = path.join(os.tmpdir(), 'gh-body-' + Date.now() + '.json');
    fs.writeFileSync(tmp, JSON.stringify(body));
    args.push('-H', 'Content-Type: application/json', '--data-binary', '@' + tmp);
    try { const raw = curl([...args, 'https://api.github.com' + endpoint]); fs.unlinkSync(tmp); return parse(raw, method + ' ' + endpoint); }
    catch (e) { try { fs.unlinkSync(tmp); } catch {} throw e; }
  }
  return parse(curl([...args, 'https://api.github.com' + endpoint]), method + ' ' + endpoint);
}
function parse(raw, label) {
  const idx = raw.lastIndexOf('\n');
  const code = parseInt(raw.slice(idx + 1).trim(), 10);
  const text = raw.slice(0, idx).trim();
  if (code < 200 || code >= 300) throw new Error(label + ' -> HTTP ' + code + ' ' + text.slice(0, 300));
  return text ? JSON.parse(text) : null;
}

const me = api('GET', '/user');
const OWNER = me.login;
console.log('authenticated as ' + OWNER);

let repo = null;
try { repo = api('GET', '/repos/' + OWNER + '/' + NAME); console.log('repo exists: ' + repo.full_name); }
catch {
  repo = api('POST', '/user/repos', { name: NAME, description: DESCRIPTION, private: false, has_issues: true, has_wiki: false, auto_init: false });
  console.log('repo created: ' + repo.full_name);
}
api('PUT', '/repos/' + OWNER + '/' + NAME + '/topics', { names: TOPICS });
console.log('topics set');

const git = (args) => execFileSync('git', args, { cwd: REPO_DIR, stdio: 'inherit', env: { ...process.env, GIT_TERMINAL_PROMPT: '0' } });
try { git(['remote', 'remove', 'origin']); } catch {}
git(['remote', 'add', 'origin', 'https://github.com/' + OWNER + '/' + NAME + '.git']);
git(['push', '-u', 'origin', 'HEAD:main', '--force']);
console.log('pushed to main');

let release = null;
try { release = api('GET', '/repos/' + OWNER + '/' + NAME + '/releases/tags/' + TAG); console.log('release exists: ' + TAG); }
catch {
  release = api('POST', '/repos/' + OWNER + '/' + NAME + '/releases', {
    tag_name: TAG, name: TAG, body: fs.readFileSync(path.join(REPO_DIR, 'RELEASE_NOTES.md'), 'utf8'), draft: false, prerelease: false,
  });
  console.log('release created: ' + TAG);
}

if (fs.existsSync(ASSET)) {
  const assetName = path.basename(ASSET);
  const prev = (release.assets || []).find((a) => a.name === assetName);
  if (prev) { api('DELETE', '/repos/' + OWNER + '/' + NAME + '/releases/assets/' + prev.id); console.log('replaced old asset'); }
  const raw = curl(['-X', 'POST', '-H', 'Authorization: Bearer ' + TOKEN, '-H', 'User-Agent: dsh-agent',
    '-H', 'Content-Type: application/zip', '--data-binary', '@' + ASSET,
    '-w', '\n%{http_code}',
    'https://uploads.github.com/repos/' + OWNER + '/' + NAME + '/releases/' + release.id + '/assets?name=' + encodeURIComponent(assetName)]);
  const uploaded = parse(raw, 'asset upload');
  console.log('asset uploaded: ' + uploaded.name + ' (' + uploaded.size + ' bytes)');
} else console.log('WARN: asset missing at ' + ASSET);

console.log('');
console.log('repo:    https://github.com/' + OWNER + '/' + NAME);
console.log('release: https://github.com/' + OWNER + '/' + NAME + '/releases/tag/' + TAG);
