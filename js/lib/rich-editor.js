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
  // BLOCKQUOTE is what Chrome's indent command wraps non-list blocks in.
  const ALLOWED_TAGS = new Set([
    'P', 'BR', 'DIV', 'B', 'STRONG', 'I', 'EM', 'U', 'S', 'STRIKE', 'SPAN',
    'OL', 'UL', 'LI', 'BLOCKQUOTE',
    'TABLE', 'THEAD', 'TBODY', 'TR', 'TD', 'TH',
  ]);
  // Chrome's execCommand (in styleWithCSS mode, enabled below) emits
  // longhand properties for some commands — font-style for italic,
  // text-decoration-line for underline/strikethrough — rather than the
  // shorthand text-decoration; both forms are allowed since browsers
  // differ here (verified against real execCommand output, not guessed).
  // The margin/padding entries are what indent/outdent emit (Chrome
  // writes "margin: 0 0 0 40px" on the blockquote wrapper, and the
  // direction-flipped margin-right in RTL blocks).
  const ALLOWED_STYLE_PROPS = new Set([
    'color', 'background-color', 'text-align',
    'font-size', 'font-weight', 'font-style',
    'text-decoration', 'text-decoration-line',
    'margin', 'margin-left', 'margin-right',
    'padding-left', 'padding-right',
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
  // Box properties get a stricter shape than the general charset:
  // 1-4 non-negative lengths, each ≤3 integer digits. Without this, a
  // body written straight through the REST API (the threat model in
  // the header comment) could carry margin: -9999px and overlap its
  // rendered content over neighbouring messages' headers — not script
  // execution, but effective spoofing in the display context.
  const BOX_PROPS = new Set(['margin', 'margin-left', 'margin-right', 'padding-left', 'padding-right']);
  // Whitespace REQUIRED between components — with it merely optional,
  // "99999px" sneaks through as two adjacent repetitions ("999"+"99px").
  const SAFE_BOX_VALUE = /^\d{1,3}(?:\.\d+)?(?:px|em|rem|%)?(?:\s+\d{1,3}(?:\.\d+)?(?:px|em|rem|%)?){0,3}$/i;

  function sanitizeStyle(styleText) {
    const kept = [];
    (styleText || '').split(';').forEach(decl => {
      const idx = decl.indexOf(':');
      if (idx === -1) return;
      const prop = decl.slice(0, idx).trim().toLowerCase();
      const val = decl.slice(idx + 1).trim();
      if (!ALLOWED_STYLE_PROPS.has(prop) || !val) return;
      if (!SAFE_STYLE_VALUE.test(val) || UNSAFE_VALUE_SUBSTRING.test(val)) return;
      if (BOX_PROPS.has(prop) && !SAFE_BOX_VALUE.test(val)) return;
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

  const GRID_MAX = 8;

  function toolbarHtml() {
    const gridCells = Array.from({ length: GRID_MAX * GRID_MAX }, (_, i) =>
      `<span class="rich-editor-grid-cell" data-row="${Math.floor(i / GRID_MAX) + 1}" data-col="${(i % GRID_MAX) + 1}"></span>`
    ).join('');
    return `
      <div class="rich-editor-toolbar" role="toolbar">
        <button type="button" data-cmd="undo" title="Undo"><i class="ti ti-arrow-back-up"></i></button>
        <button type="button" data-cmd="redo" title="Redo"><i class="ti ti-arrow-forward-up"></i></button>
        <span class="rich-editor-sep"></span>
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
        <button type="button" data-cmd="removeFormat" title="Clear formatting"><i class="ti ti-clear-formatting"></i></button>
        <span class="rich-editor-sep"></span>
        <button type="button" data-cmd="justifyLeft" title="Align left"><i class="ti ti-align-left"></i></button>
        <button type="button" data-cmd="justifyCenter" title="Align center"><i class="ti ti-align-center"></i></button>
        <button type="button" data-cmd="justifyRight" title="Align right"><i class="ti ti-align-right"></i></button>
        <button type="button" data-cmd="justifyFull" title="Justify"><i class="ti ti-align-justified"></i></button>
        <span class="rich-editor-sep"></span>
        <button type="button" data-cmd="insertUnorderedList" title="Bulleted list"><i class="ti ti-list"></i></button>
        <button type="button" data-cmd="insertOrderedList" title="Numbered list"><i class="ti ti-list-numbers"></i></button>
        <button type="button" data-cmd="outdent" title="Decrease indent"><i class="ti ti-indent-decrease"></i></button>
        <button type="button" data-cmd="indent" title="Increase indent"><i class="ti ti-indent-increase"></i></button>
        <span class="rich-editor-sep"></span>
        <div class="rich-editor-table-wrap">
          <button type="button" data-action="table-menu" title="Table"><i class="ti ti-table"></i></button>
          <div class="rich-editor-table-menu hidden">
            <div class="rich-editor-menu-label">Insert table</div>
            <div class="rich-editor-grid">${gridCells}</div>
            <div class="rich-editor-grid-size">1 × 1</div>
            <div class="rich-editor-menu-divider"></div>
            <button type="button" data-table-op="row-above"><i class="ti ti-row-insert-top"></i> Insert row above</button>
            <button type="button" data-table-op="row-below"><i class="ti ti-row-insert-bottom"></i> Insert row below</button>
            <button type="button" data-table-op="col-left"><i class="ti ti-column-insert-left"></i> Insert column left</button>
            <button type="button" data-table-op="col-right"><i class="ti ti-column-insert-right"></i> Insert column right</button>
            <div class="rich-editor-menu-divider"></div>
            <button type="button" data-table-op="del-row"><i class="ti ti-row-remove"></i> Delete row</button>
            <button type="button" data-table-op="del-col"><i class="ti ti-column-remove"></i> Delete column</button>
            <button type="button" data-table-op="del-table"><i class="ti ti-table-off"></i> Delete table</button>
          </div>
        </div>
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
      const tableMenu = root.querySelector('.rich-editor-table-menu');

      // ── Selection preservation ───────────────────────────────────
      // Interacting with toolbar controls that take real focus — the
      // native color picker dialog especially — can collapse or drop
      // the contenteditable selection before the command runs, so
      // "highlight selected text" silently highlighted nothing. Track
      // the last selection seen inside the body and restore it before
      // every command instead of trusting focus() to bring it back.
      // The two document-level listeners below tear themselves down the
      // first time they fire after the editor's DOM is gone — callers
      // close modals by wiping innerHTML rather than calling destroy(),
      // which would otherwise leak one selectionchange + one click
      // listener (each pinning the whole detached editor tree) per
      // compose/reply form ever opened in the SPA session.
      let savedRange = null;
      const onSelectionChange = () => {
        if (!body.isConnected) { teardown(); return; }
        const sel = document.getSelection();
        if (sel.rangeCount > 0 && body.contains(sel.anchorNode)) {
          savedRange = sel.getRangeAt(0).cloneRange();
        }
      };
      document.addEventListener('selectionchange', onSelectionChange);

      function restoreSelection() {
        body.focus();
        const sel = document.getSelection();
        if (savedRange && body.contains(savedRange.commonAncestorContainer)) {
          sel.removeAllRanges();
          sel.addRange(savedRange);
        } else {
          // Never focused/selected yet — put the caret at the end so
          // commands like table-insert still have a valid target.
          const range = document.createRange();
          range.selectNodeContents(body);
          range.collapse(false);
          sel.removeAllRanges();
          sel.addRange(range);
        }
      }

      function exec(cmd, value = null) {
        restoreSelection();
        // styleWithCSS is document-global mutable state (another editor
        // instance or browser quirk can reset it) — re-assert it every
        // time so foreColor/hiliteColor/fontSize keep emitting inline
        // style spans instead of legacy <font> tags, which the
        // sanitizer would strip on save.
        document.execCommand('styleWithCSS', false, true);
        document.execCommand(cmd, false, value);
        onSelectionChange();
      }

      // ── Table helpers ────────────────────────────────────────────
      function selectionCell() {
        let node = null;
        const sel = document.getSelection();
        if (sel.rangeCount > 0 && body.contains(sel.anchorNode)) {
          node = sel.anchorNode;
        } else if (savedRange && body.contains(savedRange.commonAncestorContainer)) {
          node = savedRange.commonAncestorContainer;
        }
        if (!node) return null;
        const el = node.nodeType === Node.ELEMENT_NODE ? node : node.parentElement;
        const cell = el && el.closest('td, th');
        return cell && body.contains(cell) ? cell : null;
      }

      function placeCaret(el, atEnd = false) {
        const range = document.createRange();
        range.selectNodeContents(el);
        range.collapse(!atEnd);
        const sel = document.getSelection();
        sel.removeAllRanges();
        sel.addRange(range);
        onSelectionChange();
      }

      function makeCell(refCell) {
        const cell = document.createElement(refCell && refCell.tagName === 'TH' ? 'th' : 'td');
        cell.innerHTML = '&nbsp;';
        return cell;
      }

      function insertRow(cell, below) {
        const row = cell.closest('tr');
        const newRow = document.createElement('tr');
        Array.from(row.children).forEach(c => newRow.appendChild(makeCell(c)));
        row.parentElement.insertBefore(newRow, below ? row.nextSibling : row);
        placeCaret(newRow.firstElementChild);
      }

      // Only THIS table's rows — querySelectorAll('tr') also matches
      // rows of tables nested inside a cell, so a column op on the
      // outer table would silently add/remove cells in every inner
      // table too.
      function ownRows(table) {
        return Array.from(table.querySelectorAll('tr')).filter(tr => tr.closest('table') === table);
      }

      function insertColumn(cell, right) {
        const row = cell.closest('tr');
        const table = cell.closest('table');
        const idx = Array.prototype.indexOf.call(row.children, cell);
        ownRows(table).forEach(tr => {
          const ref = tr.children[Math.min(idx, tr.children.length - 1)];
          const fresh = makeCell(ref);
          if (right) tr.insertBefore(fresh, ref ? ref.nextSibling : null);
          else tr.insertBefore(fresh, ref || null);
        });
        placeCaret(row.children[right ? idx + 1 : idx]);
      }

      function deleteRow(cell) {
        const row = cell.closest('tr');
        const table = cell.closest('table');
        row.remove();
        if (ownRows(table).length === 0) table.remove();
        else placeCaret(table.querySelector('td, th'));
      }

      function deleteColumn(cell) {
        const row = cell.closest('tr');
        const table = cell.closest('table');
        const idx = Array.prototype.indexOf.call(row.children, cell);
        ownRows(table).forEach(tr => {
          if (tr.children[idx]) tr.children[idx].remove();
        });
        if (!ownRows(table).some(tr => tr.children.length > 0)) table.remove();
        else placeCaret(table.querySelector('td, th'));
      }

      function insertTable(rows, cols) {
        let html = '<table><tbody>';
        for (let r = 0; r < rows; r++) {
          html += '<tr>' + '<td>&nbsp;</td>'.repeat(cols) + '</tr>';
        }
        html += '</tbody></table><p><br></p>';
        exec('insertHTML', html);
      }

      // ── Toolbar wiring ───────────────────────────────────────────
      toolbar.querySelectorAll('button[data-cmd]').forEach(btn => {
        // mousedown + preventDefault keeps the click from moving focus
        // (and collapsing the selection) in the first place; the
        // command then runs against the still-live selection.
        btn.addEventListener('mousedown', (e) => e.preventDefault());
        btn.addEventListener('click', (e) => {
          e.preventDefault();
          exec(btn.dataset.cmd);
        });
      });
      toolbar.querySelector('select[data-cmd="fontSize"]').addEventListener('change', (e) => {
        exec('fontSize', e.target.value);
      });
      toolbar.querySelector('input[data-cmd="foreColor"]').addEventListener('input', (e) => {
        exec('foreColor', e.target.value);
      });
      toolbar.querySelector('input[data-cmd="hiliteColor"]').addEventListener('input', (e) => {
        exec('hiliteColor', e.target.value);
      });

      // ── Table menu ───────────────────────────────────────────────
      const menuBtn = toolbar.querySelector('[data-action="table-menu"]');
      const grid = tableMenu.querySelector('.rich-editor-grid');
      const gridSize = tableMenu.querySelector('.rich-editor-grid-size');

      menuBtn.addEventListener('mousedown', (e) => e.preventDefault());
      menuBtn.addEventListener('click', (e) => {
        e.preventDefault();
        const opening = tableMenu.classList.contains('hidden');
        tableMenu.classList.toggle('hidden');
        if (opening) {
          const inTable = !!selectionCell();
          tableMenu.querySelectorAll('[data-table-op]').forEach(op => { op.disabled = !inTable; });
        }
      });
      const onDocClick = (e) => {
        if (!body.isConnected) { teardown(); return; }
        if (!root.contains(e.target)) tableMenu.classList.add('hidden');
      };
      document.addEventListener('click', onDocClick);

      function teardown() {
        document.removeEventListener('selectionchange', onSelectionChange);
        document.removeEventListener('click', onDocClick);
      }

      grid.querySelectorAll('.rich-editor-grid-cell').forEach(cellEl => {
        cellEl.addEventListener('mouseenter', () => {
          const rows = +cellEl.dataset.row, cols = +cellEl.dataset.col;
          gridSize.textContent = `${rows} × ${cols}`;
          grid.querySelectorAll('.rich-editor-grid-cell').forEach(c => {
            c.classList.toggle('rich-editor-grid-cell--on', +c.dataset.row <= rows && +c.dataset.col <= cols);
          });
        });
        cellEl.addEventListener('click', () => {
          tableMenu.classList.add('hidden');
          insertTable(+cellEl.dataset.row, +cellEl.dataset.col);
        });
      });

      tableMenu.querySelectorAll('[data-table-op]').forEach(opBtn => {
        opBtn.addEventListener('mousedown', (e) => e.preventDefault());
        opBtn.addEventListener('click', () => {
          tableMenu.classList.add('hidden');
          const cell = selectionCell();
          if (!cell) return;
          body.focus();
          switch (opBtn.dataset.tableOp) {
            case 'row-above': insertRow(cell, false); break;
            case 'row-below': insertRow(cell, true); break;
            case 'col-left':  insertColumn(cell, false); break;
            case 'col-right': insertColumn(cell, true); break;
            case 'del-row':   deleteRow(cell); break;
            case 'del-col':   deleteColumn(cell); break;
            case 'del-table': { const t = cell.closest('table'); t.remove(); break; }
          }
        });
      });

      // Word-style Tab navigation between table cells; tabbing past the
      // last cell appends a fresh row, same as Word/Sheets.
      body.addEventListener('keydown', (e) => {
        if (e.key !== 'Tab') return;
        const cell = selectionCell();
        if (!cell) return;
        e.preventDefault();
        const table = cell.closest('table');
        const cells = Array.from(table.querySelectorAll('td, th'));
        const i = cells.indexOf(cell);
        let target = e.shiftKey ? cells[i - 1] : cells[i + 1];
        if (!target && !e.shiftKey) {
          insertRow(cell, true);
          return; // insertRow already placed the caret in the new row
        }
        if (target) placeCaret(target, true);
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
        destroy() {
          teardown();
          containerEl.innerHTML = '';
        },
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

    // ── Thaana / Divehi auto-detection ─────────────────────────────
    // U+0780–U+07BF is the Thaana block. Text render sites use
    // isDivehi(text, lang) so Divehi content aligns right BY DEFAULT
    // even when the row predates the language toggle or the author
    // never clicked it — the stored language wins when set to 'dv',
    // detection covers everything else.
    containsThaana(text) {
      return /[ހ-޿]/.test(text || '');
    },

    isDivehi(textOrHtml, lang) {
      if (lang === 'dv') return true;
      return this.containsThaana(String(textOrHtml || '').replace(/<[^>]+>/g, ''));
    },

    // ' field-divehi' (leading space, ready for class-attr interpolation)
    // when the text should render RTL, '' otherwise.
    dvClass(textOrHtml, lang) {
      return this.isDivehi(textOrHtml, lang) ? ' field-divehi' : '';
    },

    // Programmatically flips a langToggleHtml() instance (hidden input +
    // active pill) without simulating a click.
    setLangToggle(container, name, lang) {
      const toggle = container.querySelector(`[data-lang-toggle="${name}"]`);
      if (!toggle) return;
      toggle.querySelector('input[type="hidden"]').value = lang;
      toggle.querySelectorAll('.lang-toggle-btn').forEach(b => b.classList.toggle('lang-toggle-btn--active', b.dataset.value === lang));
    },

    // Auto-syncs a toggle from what the user actually types: Thaana in
    // the field flips it to Divehi (RTL, Faruma), clearing back to
    // Latin flips it to English — no manual toggle click needed. The
    // pill stays clickable as a manual override; it just re-syncs on
    // the next keystroke that changes the script.
    bindAutoDetect(inputEl, container, name, onChange) {
      inputEl.addEventListener('input', () => {
        const lang = this.containsThaana(inputEl.value) ? 'dv' : 'en';
        const hidden = container.querySelector(`[data-lang-toggle="${name}"] input[type="hidden"]`);
        if (hidden && hidden.value !== lang) {
          this.setLangToggle(container, name, lang);
          onChange(lang);
        }
      });
    },
  };
})();
