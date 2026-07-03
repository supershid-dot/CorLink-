// ─── Change Password View ─────────────────────────────────────
// Shown when the user's password has expired (90-day policy).

const ChangePasswordView = {
  render(container, params = {}) {
    const isExpired = params.expired === 'true';

    container.innerHTML = `
      <div class="login-bg">
        <button class="icon-btn login-theme-toggle" id="theme-toggle-btn" data-theme-toggle title="Switch to dark theme" aria-label="Switch to dark theme">
          <i class="ti ti-moon" data-theme-icon></i>
        </button>
        <div class="login-card">
          <div class="login-brand">
            <img src="assets/logo.png" alt="${APP_NAME} logo" class="login-logo-img" />
          </div>

          ${isExpired
            ? `<div class="alert alert-warning">
                 <i class="ti ti-alert-triangle"></i>
                 Your password has expired and must be changed before you can continue.
               </div>`
            : ''}

          <div class="login-section-title">
            <i class="ti ti-key"></i> Set New Password
          </div>

          <form id="change-pw-form" class="login-form" novalidate>
            <div class="field-group">
              <label class="field-label" for="current-password">Current Password</label>
              <div class="field-input-wrap">
                <i class="ti ti-lock field-icon"></i>
                <input id="current-password" type="password" class="field-input"
                  autocomplete="current-password" placeholder="Current password" required />
              </div>
            </div>

            <div class="field-group">
              <label class="field-label" for="new-password">New Password</label>
              <div class="field-input-wrap">
                <i class="ti ti-lock-open field-icon"></i>
                <input id="new-password" type="password" class="field-input"
                  autocomplete="new-password" placeholder="New password" required />
              </div>
              <div class="field-hint">
                Min. 10 characters with uppercase, lowercase, number, and special character.
              </div>
            </div>

            <div class="field-group">
              <label class="field-label" for="confirm-password">Confirm New Password</label>
              <div class="field-input-wrap">
                <i class="ti ti-lock-check field-icon"></i>
                <input id="confirm-password" type="password" class="field-input"
                  autocomplete="new-password" placeholder="Repeat new password" required />
              </div>
            </div>

            <div id="pw-requirements" class="pw-requirements">
              <div class="pw-req" id="req-length">
                <i class="ti ti-circle"></i> At least 10 characters
              </div>
              <div class="pw-req" id="req-upper">
                <i class="ti ti-circle"></i> Uppercase letter (A–Z)
              </div>
              <div class="pw-req" id="req-lower">
                <i class="ti ti-circle"></i> Lowercase letter (a–z)
              </div>
              <div class="pw-req" id="req-number">
                <i class="ti ti-circle"></i> Number (0–9)
              </div>
              <div class="pw-req" id="req-special">
                <i class="ti ti-circle"></i> Special character (!@#$…)
              </div>
            </div>

            <div id="change-pw-error" class="alert alert-error hidden" role="alert"></div>
            <div id="change-pw-success" class="alert alert-success hidden" role="status"></div>

            <button type="submit" class="btn btn-primary btn-full" id="change-pw-btn">
              <span id="change-pw-btn-text">Update Password</span>
              <span id="change-pw-spinner" class="spinner hidden"></span>
            </button>
          </form>
        </div>
      </div>
    `;
  },

  bind() {
    Theme.bindToggleButtons();

    const newPwInput  = document.getElementById('new-password');
    const confirmInput = document.getElementById('confirm-password');
    const form        = document.getElementById('change-pw-form');
    const errorEl     = document.getElementById('change-pw-error');
    const successEl   = document.getElementById('change-pw-success');

    // Live password requirements checker
    newPwInput.addEventListener('input', () => {
      this._checkRequirements(newPwInput.value);
    });

    form.addEventListener('submit', async (e) => {
      e.preventDefault();
      await this._handleSubmit(errorEl, successEl);
    });
  },

  _checkRequirements(pw) {
    const checks = {
      'req-length':  pw.length >= 10,
      'req-upper':   /[A-Z]/.test(pw),
      'req-lower':   /[a-z]/.test(pw),
      'req-number':  /[0-9]/.test(pw),
      'req-special': /[^A-Za-z0-9]/.test(pw),
    };
    for (const [id, met] of Object.entries(checks)) {
      const el = document.getElementById(id);
      if (!el) continue;
      el.classList.toggle('req-met', met);
      el.querySelector('i').className = met ? 'ti ti-circle-check' : 'ti ti-circle';
    }
    return Object.values(checks).every(Boolean);
  },

  validatePassword(pw) {
    if (pw.length < 10)           return 'Password must be at least 10 characters.';
    if (!/[A-Z]/.test(pw))        return 'Password must include at least one uppercase letter.';
    if (!/[a-z]/.test(pw))        return 'Password must include at least one lowercase letter.';
    if (!/[0-9]/.test(pw))        return 'Password must include at least one number.';
    if (!/[^A-Za-z0-9]/.test(pw)) return 'Password must include at least one special character.';
    return null;
  },

  async _handleSubmit(errorEl, successEl) {
    const currentPw = document.getElementById('current-password').value;
    const newPw     = document.getElementById('new-password').value;
    const confirmPw = document.getElementById('confirm-password').value;

    errorEl.classList.add('hidden');
    successEl.classList.add('hidden');

    const validationError = this.validatePassword(newPw);
    if (validationError) {
      errorEl.textContent = validationError;
      errorEl.classList.remove('hidden');
      return;
    }

    if (newPw !== confirmPw) {
      errorEl.textContent = 'Passwords do not match.';
      errorEl.classList.remove('hidden');
      return;
    }

    if (newPw === currentPw) {
      errorEl.textContent = 'New password must be different from your current password.';
      errorEl.classList.remove('hidden');
      return;
    }

    const btn  = document.getElementById('change-pw-btn');
    const text = document.getElementById('change-pw-btn-text');
    const spin = document.getElementById('change-pw-spinner');

    btn.disabled = true;
    text.textContent = 'Updating…';
    spin.classList.remove('hidden');

    try {
      const db = getSupabase();
      const { error } = await db.auth.updateUser({ password: newPw });

      if (error) {
        errorEl.textContent = error.message || 'Failed to update password. Please try again.';
        errorEl.classList.remove('hidden');
      } else {
        // Update password_expires_at in users table
        const { data: session } = await db.auth.getSession();
        if (session?.session) {
          await db.from('users')
            .update({
              password_changed_at: new Date().toISOString(),
              password_expires_at: new Date(
                Date.now() + PASSWORD_EXPIRY_DAYS * 86_400_000
              ).toISOString(),
            })
            .eq('id', session.session.user.id);
        }

        successEl.textContent = 'Password updated successfully. Redirecting…';
        successEl.classList.remove('hidden');
        setTimeout(() => Router.navigate('dashboard'), 1500);
      }
    } catch (err) {
      console.error('Password change error:', err);
      errorEl.textContent = 'An unexpected error occurred. Please try again.';
      errorEl.classList.remove('hidden');
    } finally {
      btn.disabled = false;
      text.textContent = 'Update Password';
      spin.classList.add('hidden');
    }
  },
};
