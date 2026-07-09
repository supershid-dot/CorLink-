// ─── UI Chrome Localization (EN / Dhivehi) ─────────────────────────
// Deliberately scoped to the highest-traffic chrome only — nav links,
// the dashboard, and top-level action buttons — not a full app-wide
// translation pass. Everything else (Requests tabs/filters, modal
// forms, admin screens) stays English; user-authored content (subject/
// body text) was already independently localizable via the existing
// per-field Divehi toggle (RichEditor.langToggleHtml) and is untouched
// here — this only affects the app's own static labels.
const I18N = (() => {
  const STORAGE_KEY = 'corlink:ui-lang';

  const STRINGS = {
    nav_dashboard:       { en: 'Dashboard',                     dv: 'ޑޭޝްބޯޑް' },
    nav_requests:        { en: 'Requests',                      dv: 'ރިކުއެސްޓް' },
    nav_letters:         { en: 'Prisoner Letters',              dv: 'ޤައިދީންގެ ސިޓީ' },
    nav_letters_short:   { en: 'Letters',                       dv: 'ސިޓީ' },
    nav_admin:           { en: 'Admin',                         dv: 'އެޑްމިން' },
    nav_administration:  { en: 'Administration',                dv: 'އެޑްމިނިސްޓްރޭޝަން' },
    nav_home:            { en: 'Home',                          dv: 'ހޯމް' },
    sign_out:            { en: 'Sign Out',                      dv: 'ލޮގްއައުޓް' },
    notifications:       { en: 'Notifications',                 dv: 'ނޮޓިފިކޭޝަން' },
    mark_all_read:       { en: 'Mark all read',                 dv: 'ހުރިހާ ކިޔުނުކަމަށް ފާހަގަކުރޭ' },
    search_placeholder:  { en: 'Search by reference number or subject…', dv: 'ރެފަރެންސް ނަންބަރު ނުވަތަ މައުޟޫޢުން ހޯދާ…' },
    search_tooltip:      { en: 'Search',                        dv: 'ހޯދާ' },
    ui_lang_toggle:      { en: 'Interface language',             dv: 'ބަހުގެ ބައި' },
    greeting_morning:    { en: 'Good morning',                  dv: 'ހެނދުނުގެ ސަލާމް' },
    greeting_afternoon:  { en: 'Good afternoon',                dv: 'މެންދުރުފަހުގެ ސަލާމް' },
    greeting_evening:    { en: 'Good evening',                  dv: 'ހަވީރުގެ ސަލާމް' },
    dash_subtitle:       { en: "Here's what's happening with your correspondence today.", dv: 'މިއަދު ސިޓީއާބެހޭ ކަންތައްތައް.' },
    new_request:         { en: 'New Request',                   dv: 'އައު ރިކުއެސްޓް' },
    stat_inbox:          { en: 'Inbox',                         dv: 'އިންބޮކްސް' },
    stat_sent:           { en: 'Sent Requests',                 dv: 'ފޮނުވި ރިކުއެސްޓް' },
    stat_overdue:        { en: 'Overdue',                       dv: 'ސުންގަޑި ފަހަނައަޅާފައި' },
    stat_letters:        { en: 'Prisoner Letters',              dv: 'ޤައިދީންގެ ސިޓީ' },
    panel_action_needed: { en: 'Action Needed',                 dv: 'ފިޔަވަޅު އަޅަންޖެހޭ' },
    panel_workload:      { en: 'My Workload & Efficiency',      dv: 'މަސައްކަތާއި ހަރަދު' },
    panel_deadlines:     { en: 'Upcoming Deadlines',            dv: 'ކުރިއަށް ހުރި ސުންގަޑިތައް' },
  };

  function getLang() {
    try {
      return localStorage.getItem(STORAGE_KEY) === 'dv' ? 'dv' : 'en';
    } catch (err) {
      return 'en';
    }
  }

  function setLang(lang) {
    try {
      localStorage.setItem(STORAGE_KEY, lang === 'dv' ? 'dv' : 'en');
    } catch (err) {
      // Private browsing / quota — the toggle just won't persist across
      // reloads, which is a minor degradation, not worth surfacing.
    }
  }

  return {
    t(key) {
      const entry = STRINGS[key];
      if (!entry) return key;
      return entry[getLang()] || entry.en;
    },
    getLang,
    setLang,
    isDivehi() {
      return getLang() === 'dv';
    },
    // ' field-divehi' (leading space, ready for class-attr interpolation)
    // when the current UI language is Divehi, '' otherwise — same
    // shape as RichEditor.dvClass() for user content, applied here to
    // this library's own static chrome strings instead.
    cls() {
      return this.isDivehi() ? ' field-divehi' : '';
    },
  };
})();
