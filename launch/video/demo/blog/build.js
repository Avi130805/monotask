import fs from 'node:fs';
import path from 'node:path';

const layout = fs.readFileSync('templates/layout.html', 'utf8');

function toHtml(md) {
  return md
    .split(/\n{2,}/)
    .map((block) => {
      if (block.startsWith('# ')) return `<h1>${block.slice(2)}</h1>`;
      if (block.startsWith('## ')) return `<h2>${block.slice(3)}</h2>`;
      return `<p>${block.replace(/\n/g, ' ')}</p>`;
    })
    .join('\n');
}

function parse(file) {
  const raw = fs.readFileSync(path.join('posts', file), 'utf8');
  const [, front, body] = raw.match(/^---\n([\s\S]*?)\n---\n([\s\S]*)$/);
  const meta = Object.fromEntries(front.split('\n').map((l) => l.split(': ')));
  return { ...meta, slug: file.replace(/\.md$/, ''), html: toHtml(body.trim()) };
}

const posts = fs.readdirSync('posts').filter((f) => f.endsWith('.md')).map(parse)
  .sort((a, b) => b.date.localeCompare(a.date));

fs.mkdirSync('dist', { recursive: true });
for (const p of posts) {
  fs.writeFileSync(`dist/${p.slug}.html`, layout.replace('{{title}}', p.title).replace('{{body}}', p.html));
}
const index = posts.map((p) => `<li><a href="${p.slug}.html">${p.title}</a> <time>${p.date}</time></li>`).join('\n');
fs.writeFileSync('dist/index.html', layout.replace('{{title}}', 'Notes').replace('{{body}}', `<ul>${index}</ul>`));
console.log(`built ${posts.length} posts`);
