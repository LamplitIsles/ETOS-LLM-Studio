// Exercise the generated renderer with a small DOM and Markdown fixture.
// This checks node lifetime, not WebKit's networking or layout.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');

class Element {
  constructor(tag, src = '') {
    this.tag = tag;
    this.src = src;
    this.dataset = {};
    this.handlers = {};
    this.parent = null;
  }
  getAttribute(name) { return name === 'src' ? this.src : null; }
  addEventListener(name, fn) { this.handlers[name] = fn; }
  replaceWith(node) {
    const siblings = this.parent.nodes;
    const index = siblings.indexOf(this);
    if (node.parent) {
      const old = node.parent.nodes;
      old.splice(old.indexOf(node), 1);
    }
    siblings[index] = node;
    node.parent = this.parent;
    this.parent = null;
  }
}
class Fragment {
  constructor(nodes = []) { this.nodes = nodes; nodes.forEach(n => n.parent = this); }
  querySelectorAll(selector) {
    if (selector === '[data-cfl-source]') return this.nodes.filter(n => n.dataset.cflSource);
    if (selector === 'img[src^="cfl-image:"]') return this.nodes.filter(n => n.tag === 'img' && n.src.startsWith('cfl-image:'));
    return [];
  }
  replaceChildren(fragment) {
    this.nodes = fragment.nodes;
    this.nodes.forEach(n => n.parent = this);
    fragment.nodes = [];
  }
  getBoundingClientRect() { return { height: 1 }; }
  get scrollHeight() { return 1; }
}
const container = new Fragment();
global.window = {
  marked: { parse(raw, options) {
    const token = { type: 'image', href: raw.split('|')[0] };
    options.walkTokens(token);
    return token.href;
  } },
  katex: {}, renderMathInElement() {}, addEventListener() {}
};
global.document = {
  getElementById() { return container; },
  documentElement: { style: { setProperty() {} } },
  createElement(tag) {
    if (tag === 'template') return {
      set innerHTML(source) { this.content = new Fragment([new Element('img', source)]); }
    };
    return new Element(tag);
  }
};
vm.runInThisContext(fs.readFileSync(process.argv[2], 'utf8'));
const render = content => window.__etApplyPayload({ content, availableWidth: 300 });
render('work/a.png|first');
const original = container.nodes[0];
render('work/a.png|more streamed text');
assert.equal(container.nodes[0], original, 'streaming should retain an image element');
original.handlers.error();
const failed = container.nodes[0];
assert.equal(failed.tag, 'button');
render('work/a.png|even more text');
assert.equal(container.nodes[0], failed, 'streaming should preserve the retry state');
failed.handlers.click();
assert.equal(container.nodes[0], original, 'retry should restore the image');
render('work/b.png|changed target');
assert.notEqual(container.nodes[0], original, 'a new target must get a new image');
console.log('CFL Markdown Web image checks passed');
