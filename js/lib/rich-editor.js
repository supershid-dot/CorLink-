// ─── Rich Text Editor ──────────────────────────────────────────
// A small, dependency-free rich text editor (contenteditable +
// execCommand) plus a matching HTML sanitizer, used for request/
// response/internal-request bodies (js/data/requests-api.js,
// js/data/internal-requests-api.js, and the views that render them).
//
// No CDN dependency on purpose: this app is a static site with no
// build step, and a rich-text library would need one more script tag
// to trust. Read-time sanitization is the real security boundary —
// any authenticated session can POST raw HTML directly via the
// Supabase REST API, bypassing this editor entirely, so RLS controls
// which rows a user can write, never what HTML goes into a TEXT
// column. RichEditor.sanitize() must run on every body before it's
// ever assigned to .innerHTML, both when rendering (views) and before
// writing (data layer) — see requests-api.js for the write-time calls.

const RichEditor = (() => {
  // Tight allowlist — only what the toolbar below can actually produce.
  const ALLOWED_TAGS = new Set([
    'P', 'BR', 'DIV', 'B', 'STRONG', 'I', 'EM', 'U', 'S', 'STRIKE', 'SPAN',
    'OL', 'UL', 'LI', 'TABLE', 'THEAD', 'TBODY', 'TR', 'TD', 'TH',
  ]);
  // Chrome's execCommand (in styleWithCSS mode, enabled below) emits
  // longhand properties for some commands — font-style for italic,
  // text-decoration-line for underline/strikethrough — rather than the
  // shorthand text-decoration; both forms are allowed since browsers
  // differ here (verified against real execCommand output, not guessed).
  const ALLOWED_STYLE_PROPS = new Set([
    'color', 'background-color', 'text-align',
    'font-size', 'font-weight', 'font-style',
    'text-decoration', 'text-decoration-line',
  ]);
  // Letters/digits/#/./,/%/()/whitespace/hyphen only — rejects
  // javascript:, quotes, braces, semicolons in the VALUE (property
  // names are matched against a fixed allowlist above, not this regex,
  // so this only needs to bound legitimate CSS values like "#1a7a6e",
  // "rgb(26, 122, 110)", "18px", "bold", "center"). This charset alone
  // does NOT reject url(...)/expression(...) — both are just letters
  // and parens — so those are checked explicitly below. Neither is
  // actually live on any property this allowlist grants today (url()
  // isn't valid CSS on color/font-size/text-align/etc, and CSS
  // expression() was removed after IE7), but reject them outright
  // rather than depending on that staying true as the allowlist grows.
  const SAFE_STYLE_VALUE = /^[a-z0-9#.,%()\s-]+$/i;
  const UNSAFE_VALUE_SUBSTRING = /url\(|expression\(/i;

  function sanitizeStyle(styleText) {
    const kept = [];
    (styleText || '').split(';').forEach(decl => {
      const idx = decl.indexOf(':');
      if (idx === -1) return;
      const prop = decl.slice(0, idx).trim().toLowerCase();
      const val = decl.slice(idx + 1).trim();
      if (!ALLOWED_STYLE_PROPS.has(prop) || !val) return;
      if (!SAFE_STYLE_VALUE.test(val) || UNSAFE_VALUE_SUBSTRING.test(val)) return;
      kept.push(`${prop}: ${val}`);
    });
    return kept.join('; ');
  }

  // Parses into a real (inert) DOM tree via <template> — browsers never
  // execute scripts or fetch resources for template.content, and this
  // lets the browser's own battle-tested HTML parser normalize any
  // string-level obfuscation before we ever look at tag names. Then
  // rebuilds a NEW tree by allowlist, rather than mutating/stripping
  // the parsed one in place — every element in the output was
  // explicitly created here (createElement + setAttribute), so nothing
  // reaches the final innerHTML string that this function didn't
  // itself construct attribute-by-attribute.
  function cleanNode(node) {
    if (node.nodeType === Node.TEXT_NODE) {
      return document.createTextNode(node.textContent);
    }
    if (node.nodeType !== Node.ELEMENT_NODE) return null;

    const children = Array.from(node.childNodes).map(cleanNode).filter(Boolean);
    const tag = node.tagName;

    if (!ALLOWED_TAGS.has(tag)) {
      // Not on the allowlist — drop the wrapper, keep its sanitized
      // content (e.g. a stray <script>alert(1)</script> becomes the
      // inert text "alert(1)", never an executable element).
      const frag = document.createDocumentFragment();
      children.forEach(c => frag.appendChild(c));
      return frag;
    }

    const el = document.createElement(tag.toLowerCase());
    // styleWithCSS mode (enabled below) doesn't always wrap a selection
    // in a fresh span/div — e.g. centering a fully-selected table cell
    // puts style="text-align:center" directly on the <td>. Copying the
    // sanitized style attribute for every allowed tag (not just
    // span/div) avoids silently losing formatting depending on exactly
    // which element execCommand happened to target; sanitizeStyle's own
    // property/value allowlist is what keeps this safe regardless of tag.
    const style = sanitizeStyle(node.getAttribute('style'));
    if (style) el.setAttribute('style', style);
    // No other attribute is ever copied for any tag — this is a strict
    // allowlist, not a blocklist, so onerror/onclick/href/src etc. can
    // never reach the output regardless of tag.
    children.forEach(c => el.appendChild(c));
    return el;
  }

  function sanitize(html) {
    const template = document.createElement('template');
    template.innerHTML = html || '';
    const out = document.createElement('div');
    Array.from(template.content.childNodes).forEach(node => {
      const cleaned = cleanNode(node);
      if (cleaned) out.appendChild(cleaned);
    });
    return out.innerHTML;
  }

  function insertTable(body) {
    const rows = 3, cols = 3;
    let html = '<table><tbody>';
    for (let r = 0; r < rows; r++) {
      html += '<tr>' + '<td>&nbsp;</td>'.repeat(cols) + '</tr>';
    }
    html += '</tbody></table><p><br></p>';
    document.execCommand('insertHTML', false, html);
  }

  function toolbarHtml() {
    return `
      <div class="rich-editor-toolbar" role="toolbar">
        <button type="button" data-cmd="bold" title="Bold"><i class="ti ti-bold"></i></button>
        <button type="button" data-cmd="italic" title="Italic"><i class="ti ti-italic"></i></button>
        <button type="button" data-cmd="underline" title="Underline"><i class="ti ti-underline"></i></button>
        <button type="button" data-cmd="strikeThrough" title="Strikethrough"><i class="ti ti-strikethrough"></i></button>
        <span class="rich-editor-sep"></span>
        <select data-cmd="fontSize" title="Font size">
          <option value="2">Small</option>
          <option value="3" selected>Normal</option>
          <option value="5">Large</option>
          <option value="7">Huge</option>
        </select>
        <label class="rich-editor-color" title="Text color">
          <i class="ti ti-letter-case"></i>
          <input type="color" data-cmd="foreColor" value="#111827" />
        </label>
        <label class="rich-editor-color" title="Highlight">
          <i class="ti ti-highlight"></i>
          <input type="color" data-cmd="hiliteColor" value="#fff59d" />
        </label>
        <span class="rich-editor-sep"></span>
        <button type="button" data-cmd="justifyLeft" title="Align left"><i class="ti ti-align-left"></i></button>
        <button type="button" data-cmd="justifyCenter" title="Align center"><i class="ti ti-align-center"></i></button>
        <button type="button" data-cmd="justifyRight" title="Align right"><i class="ti ti-align-right"></i></button>
        <span class="rich-editor-sep"></span>
        <button type="button" data-cmd="insertUnorderedList" title="Bulleted list"><i class="ti ti-list"></i></button>
        <button type="button" data-cmd="insertOrderedList" title="Numbered list"><i class="ti ti-list-numbers"></i></button>
        <span class="rich-editor-sep"></span>
        <button type="button" data-action="table" title="Insert table"><i class="ti ti-table"></i></button>
      </div>
    `;
  }

  return {
    sanitize,

    create(containerEl, { language = 'en' } = {}) {
      containerEl.innerHTML = `
        <div class="rich-editor">
          ${toolbarHtml()}
          <div class="rich-editor-body${language === 'dv' ? ' field-divehi' : ''}" contenteditable="true"></div>
        </div>
      `;
      const root = containerEl.querySelector('.rich-editor');
      const toolbar = root.querySelector('.rich-editor-toolbar');
      const body = root.querySelector('.rich-editor-body');

      // Makes foreColor/hiliteColor/fontSize emit inline style="" (span)
      // instead of legacy <font> tags — without this, color/highlight
      // would visually work in the live editor but vanish entirely on
      // save, since <font> isn't in the sanitizer's tag allowlist and
      // colors aren't re-derivable from anything else in the markup.
      document.execCommand('styleWithCSS', false, true);

      toolbar.querySelectorAll('button[data-cmd]').forEach(btn => {
        btn.addEventListener('click', (e) => {
          e.preventDefault();
          body.focus();
          document.execCommand(btn.dataset.cmd, false, null);
        });
      });
      toolbar.querySelector('select[data-cmd="fontSize"]').addEventListener('change', (e) => {
        body.focus();
        document.execCommand('fontSize', false, e.target.value);
      });
      toolbar.querySelector('input[data-cmd="foreColor"]').addEventListener('input', (e) => {
        body.focus();
        document.execCommand('foreColor', false, e.target.value);
      });
      toolbar.querySelector('input[data-cmd="hiliteColor"]').addEventListener('input', (e) => {
        body.focus();
        document.execCommand('hiliteColor', false, e.target.value);
      });
      toolbar.querySelector('[data-action="table"]').addEventListener('click', (e) => {
        e.preventDefault();
        body.focus();
        insertTable(body);
      });

      return {
        getHTML() { return sanitize(body.innerHTML); },
        // Defensively sanitizes even though this app's own write path
        // already does too — a contenteditable body is a live,
        // rendered element, not an inert template, so anything
        // assigned here that bypassed write-time sanitization (a
        // direct REST insert, say) would otherwise execute immediately.
        setHTML(html) { body.innerHTML = sanitize(html); },
        setLanguage(lang) { body.classList.toggle('field-divehi', lang === 'dv'); },
        focus() { body.focus(); },
        destroy() { containerEl.innerHTML = ''; },
      };
    },

    // A segmented EN/Dhivehi pill, replacing a plain <select> for the
    // language choice everywhere it appears (compose/reply forms,
    // comment modals). Ships a hidden input under `name` so existing
    // `new FormData(form).get(name)` submit handlers don't need to
    // change at all — only the control surface changed.
    langToggleHtml(name = 'language', current = 'en') {
      return `
        <div class="lang-toggle" data-lang-toggle="${name}">
          <input type="hidden" name="${name}" value="${current}" />
          <button type="button" class="lang-toggle-btn${current === 'en' ? ' lang-toggle-btn--active' : ''}" data-value="en">EN</button>
          <button type="button" class="lang-toggle-btn${current === 'dv' ? ' lang-toggle-btn--active' : ''}" data-value="dv">ދިވެހި</button>
        </div>
      `;
    },

    // Wires the langToggleHtml(name, ...) instance found within
    // `container` matching `name` — a form can hold more than one
    // independent toggle (e.g. Subject and Message each get their own),
    // so this targets one by its `name` rather than grabbing the first
    // [data-lang-toggle] in the container. onChange(lang) fires on every
    // click — callers use it to flip .field-divehi on plain inputs/
    // textareas and/or call a RichEditor instance's own setLanguage().
    bindLangToggle(container, name, onChange) {
      const toggle = container.querySelector(`[data-lang-toggle="${name}"]`);
      if (!toggle) return;
      const hidden = toggle.querySelector('input[type="hidden"]');
      toggle.querySelectorAll('.lang-toggle-btn').forEach(btn => {
        btn.addEventListener('click', () => {
          const value = btn.dataset.value;
          hidden.value = value;
          toggle.querySelectorAll('.lang-toggle-btn').forEach(b => b.classList.toggle('lang-toggle-btn--active', b === btn));
          onChange(value);
        });
      });
    },
  };
})();
