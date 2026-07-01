// ─── Login View ───────────────────────────────────────────────

const LoginView = {
  render(container, params = {}) {
    const timeoutMsg = params.timeout
      ? `<div class="alert alert-info">
           <i class="ti ti-clock"></i>
           Your session expired due to inactivity. Please sign in again.
         </div>`
      : '';

    container.innerHTML = `
      <div class="login-bg">
        <div class="login-card">
          <div class="login-brand">
            <img src="assets/logo.jpg" alt="${APP_NAME} logo" class="login-logo-img" />
          </div>

          ${timeoutMsg}

          <form id="login-form" class="login-form" novalidate>
            <div class="field-group">
              <label class="field-label" for="service-number">Service Number</label>
              <div class="field-input-wrap">
                <i class="ti ti-id-badge field-icon"></i>
                <input
                  id="service-number"
                  name="serviceNumber"
                  type="text"
                  class="field-input"
                  placeholder="e.g. MCS-001"
                  autocomplete="username"
                  autocapitalize="characters"
                  spellcheck="false"
                  required
                  maxlength="30"
                />
              </div>
            </div>

            <div class="field-group">
              <label class="field-label" for="password">Password</label>
              <div class="field-input-wrap">
                <i class="ti ti-lock field-icon"></i>
                <input
                  id="password"
                  name="password"
                  type="password"
                  class="field-input"
                  placeholder="Enter your password"
                  autocomplete="current-password"
                  required
                />
                <button type="button" class="field-toggle-pw" id="toggle-pw" aria-label="Show password">
                  <i class="ti ti-eye" id="toggle-pw-icon"></i>
                </button>
              </div>
            </div>

            <div id="login-error" class="alert alert-error hidden" role="alert" aria-live="polite"></div>

            <button type="submit" class="btn btn-primary btn-full" id="login-btn">
              <span id="login-btn-text">Sign In</span>
              <span id="login-btn-spinner" class="spinner hidden" aria-hidden="true"></span>
            </button>
          </form>

          <div class="login-footer">
            <p>Maldives Correctional Service</p>
            <p class="login-footer-sub">Contact your administrator for access</p>
          </div>
        </div>
      </div>
    `;
  },

  bind(params = {}) {
    const form       = document.getElementById('login-form');
    const snInput    = document.getElementById('service-number');
    const pwInput    = document.getElementById('password');
    const errorEl    = document.getElementById('login-error');
    const btnText    = document.getElementById('login-btn-text');
    const btnSpinner = document.getElementById('login-btn-spinner');
    const togglePw   = document.getElementById('toggle-pw');
    const toggleIcon = document.getElementById('toggle-pw-icon');

    // Password visibility toggle
    togglePw.addEventListener('click', () => {
      const isPassword = pwInput.type === 'password';
      pwInput.type = isPassword ? 'text' : 'password';
      toggleIcon.className = isPassword ? 'ti ti-eye-off' : 'ti ti-eye';
      togglePw.setAttribute('aria-label', isPassword ? 'Hide password' : 'Show password');
    });

    // Clear error on input
    [snInput, pwInput].forEach(el => {
      el.addEventListener('input', () => {
        errorEl.classList.add('hidden');
        errorEl.textContent = '';
        el.classList.remove('input-error');
      });
    });

    form.addEventListener('submit', async (e) => {
      e.preventDefault();
      await this._handleSubmit(snInput, pwInput, errorEl, btnText, btnSpinner);
    });

    // Focus service number on load
    snInput.focus();
  },

  async _handleSubmit(snInput, pwInput, errorEl, btnText, btnSpinner) {
    const serviceNumber = snInput.value.trim();
    const password      = pwInput.value;

    // Basic validation
    if (!serviceNumber) {
      this._showError(errorEl, snInput, 'Please enter your service number.');
      return;
    }
    if (!password) {
      this._showError(errorEl, pwInput, 'Please enter your password.');
      return;
    }

    this._setLoading(true, btnText, btnSpinner);

    try {
      const result = await Auth.signIn(serviceNumber, password);

      if (result.error) {
        this._setLoading(false, btnText, btnSpinner);

        if (result.error.type === 'locked') {
          snInput.value = '';
          pwInput.value = '';
          snInput.focus();
        } else {
          pwInput.value = '';
          pwInput.focus();
        }

        this._showError(errorEl, null, result.error.message);
        return;
      }

      // Success
      if (result.passwordExpired) {
        Router.navigate('change-password', { expired: 'true' });
        return;
      }

      Router.navigate('dashboard');

    } catch (err) {
      console.error('Login error:', err);
      this._setLoading(false, btnText, btnSpinner);
      this._showError(errorEl, null, 'An unexpected error occurred. Please try again.');
    }
  },

  _showError(errorEl, inputEl, message) {
    errorEl.textContent = message;
    errorEl.classList.remove('hidden');
    if (inputEl) inputEl.classList.add('input-error');
  },

  _setLoading(isLoading, btnText, btnSpinner) {
    const btn = document.getElementById('login-btn');
    if (isLoading) {
      btnText.textContent = 'Signing in…';
      btnSpinner.classList.remove('hidden');
      btn.disabled = true;
    } else {
      btnText.textContent = 'Sign In';
      btnSpinner.classList.add('hidden');
      btn.disabled = false;
    }
  },
};
