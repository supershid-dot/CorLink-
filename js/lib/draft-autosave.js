// ─── Draft Autosave ────────────────────────────────────────────────
// Mitigates the app's 30-minute session-timeout inactivity logout
// silently discarding an in-progress compose/response/reply — every
// form's session-loseable state (subject, message body, deadline, a
// couple of plain selects) autosaves to localStorage on a debounce and
// restores itself the next time that exact form (same formKey) is
// opened, with a dismissible "Discard" action. Purely a client-side
// convenience: failures here (quota exceeded, private browsing) must
// never break the actual form, so every localStorage call is wrapped.
//
// Deliberately does NOT persist file inputs (attachments) — a File
// object/handle can't survive a page reload, and there's nothing
// meaningful to restore for it.
const DraftAutosave = {
  _prefix: 'corlink:draft:',

  _key(formKey) {
    return this._prefix + formKey;
  },

  save(formKey, fields) {
    try {
      localStorage.setItem(this._key(formKey), JSON.stringify(fields));
    } catch (err) {
      // Quota exceeded / private browsing / disabled storage — autosave
      // is best-effort, never worth surfacing to the user.
    }
  },

  load(formKey) {
    try {
      const raw = localStorage.getItem(this._key(formKey));
      return raw ? JSON.parse(raw) : null;
    } catch (err) {
      return null;
    }
  },

  clear(formKey) {
    try {
      localStorage.removeItem(this._key(formKey));
    } catch (err) {
      // Nothing meaningful to do if this fails — worst case a stale
      // draft lingers and gets overwritten on the next autosave anyway.
    }
  },

  // Generic bind: `read()` snapshots current form/editor state,
  // `apply(fields)` writes a snapshot back onto the form/editor,
  // `isEmpty(fields)` decides whether a saved snapshot is worth
  // offering to restore (an empty draft shouldn't show a restore banner).
  bind(form, formKey, { read, apply, isEmpty }) {
    const saved = this.load(formKey);
    if (saved && !isEmpty(saved)) {
      apply(saved);
      const hint = document.createElement('div');
      hint.className = 'field-hint draft-restored-hint';
      hint.innerHTML = `<i class="ti ti-history"></i> Restored an unsaved draft from this device. <button type="button" class="btn btn-secondary btn-xs" data-discard-draft>Discard</button>`;
      form.prepend(hint);
      hint.querySelector('[data-discard-draft]').addEventListener('click', () => {
        this.clear(formKey);
        apply({});
        hint.remove();
      });
    }

    let timer = null;
    const scheduleSave = () => {
      clearTimeout(timer);
      timer = setTimeout(() => this.save(formKey, read()), 800);
    };
    form.addEventListener('input', scheduleSave);
    form.addEventListener('change', scheduleSave);
  },

  // Convenience wrapper for this app's own modal-form shape: one
  // RichEditor instance, an allowlist of plain field names to persist,
  // and any RichEditor.langToggleHtml() instances present (by `name`,
  // with the exact same onChange the form wired up already — restoring
  // the language also has to re-flip .field-divehi/editor.setLanguage(),
  // not just the hidden input's value).
  autoSaveForm(form, formKey, editor, { bodyField = 'body', fieldNames = [], langToggles = [] } = {}) {
    const read = () => {
      const fields = { [bodyField]: editor.getHTML() };
      fieldNames.forEach(name => {
        const el = form.elements[name];
        if (el) fields[name] = el.value;
      });
      langToggles.forEach(({ name }) => {
        const el = form.elements[name];
        if (el) fields[name] = el.value;
      });
      return fields;
    };

    const apply = (saved) => {
      editor.setHTML(saved[bodyField] || '');
      fieldNames.forEach(name => {
        const el = form.elements[name];
        if (el && saved[name] !== undefined) el.value = saved[name];
      });
      langToggles.forEach(({ name, onChange }) => {
        const lang = saved[name] || 'en';
        RichEditor.setLangToggle(form, name, lang);
        onChange(lang);
      });
    };

    const isEmpty = (saved) => !saved[bodyField] || saved[bodyField] === '<p><br></p>';

    this.bind(form, formKey, { read, apply, isEmpty });
  },
};
