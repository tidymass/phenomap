<template>
  <div class="auth-split">
    <div class="auth-visual">
      <DataGlobe class="hologram" />
    </div>

    <div class="auth-form-panel">
      <div class="auth-card">
        <h1 class="page-title">Sign up</h1>

        <form class="auth-form" @submit.prevent="submit">
          <label>
            Display name
            <div class="input-with-icon">
              <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7">
                <circle cx="12" cy="8" r="3.4" />
                <path d="M5 20c0-3.6 3.1-6 7-6s7 2.4 7 6" />
              </svg>
              <input v-model="displayName" type="text" required autocomplete="name" />
            </div>
          </label>

          <label>
            Email
            <div class="input-with-icon">
              <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7">
                <rect x="3" y="5" width="18" height="14" rx="2.5" />
                <path d="m4 7 8 6 8-6" />
              </svg>
              <input v-model="email" type="email" required autocomplete="email" />
            </div>
          </label>

          <label>
            Institution
            <div class="input-with-icon">
              <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7">
                <path d="M12 3 3 8v1h18V8z" />
                <path d="M5 9v9M9 9v9M15 9v9M19 9v9" />
                <path d="M3 20.5h18" />
              </svg>
              <input v-model="institution" type="text" required autocomplete="organization" />
            </div>
          </label>

          <label>
            Country/Region
            <div class="input-with-icon">
              <CountryCombobox v-model="country" with-icon />
            </div>
          </label>

          <label>
            Password
            <div class="input-with-icon">
              <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7">
                <rect x="5" y="11" width="14" height="9" rx="2" />
                <path d="M8 11V7.5a4 4 0 0 1 8 0V11" />
              </svg>
              <input
                v-model="password"
                :type="showPassword ? 'text' : 'password'"
                minlength="9"
                required
                autocomplete="new-password"
                class="has-trailing-btn"
              />
              <button
                type="button"
                class="toggle-visibility"
                :aria-label="showPassword ? 'Hide password' : 'Show password'"
                @click="showPassword = !showPassword"
              >
                <svg v-if="showPassword" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7">
                  <path d="M3 3l18 18" />
                  <path d="M10.6 5.1A10.6 10.6 0 0 1 12 5c6 0 9.5 5.5 9.5 7 0 .6-.6 1.9-1.8 3.3M6.5 6.6C3.9 8.3 2.5 10.7 2.5 12c0 1.5 3.5 7 9.5 7 1.3 0 2.5-.3 3.6-.7" />
                  <path d="M9.9 10a3 3 0 0 0 4.2 4.2" />
                </svg>
                <svg v-else viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7">
                  <path d="M2.5 12S6 5 12 5s9.5 7 9.5 7-3.5 7-9.5 7-9.5-7-9.5-7Z" />
                  <circle cx="12" cy="12" r="3" />
                </svg>
              </button>
            </div>
          </label>
          <p class="password-hint">More than 8 characters, and at least 3 of: uppercase, lowercase, digit, special character.</p>

          <button type="submit" class="submit-btn" :disabled="loading">
            {{ loading ? 'Creating account...' : 'Create account' }}
          </button>

          <p v-if="error" class="notice error">
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
              <circle cx="12" cy="12" r="9" /><path d="M12 8v5M12 16h.01" />
            </svg>
            <span>{{ error }}</span>
          </p>
          <p v-if="message" class="notice success">
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M20 6 9 17l-5-5" /></svg>
            <span>{{ message }}</span>
          </p>
        </form>
        <p class="switch">Already have an account? <router-link to="/login">Sign in</router-link></p>
      </div>
    </div>
  </div>
</template>

<script setup>
import { ref } from 'vue'
import { signUp } from '../auth.js'
import CountryCombobox from '../components/CountryCombobox.vue'
import DataGlobe from '../components/DataGlobe.vue'

const displayName = ref('')
const email = ref('')
const institution = ref('')
const country = ref('')
const password = ref('')
const showPassword = ref(false)
const loading = ref(false)
const error = ref('')
const message = ref('')

async function submit() {
  loading.value = true
  error.value = ''
  message.value = ''
  try {
    if (!country.value) {
      throw new Error('country/region is required')
    }
    const res = await signUp(email.value, password.value, displayName.value, institution.value, country.value)
    message.value = res.message
  } catch (e) {
    error.value = e.message
  } finally {
    loading.value = false
  }
}
</script>

<style scoped>
.auth-split {
  display: flex;
  min-height: calc(100vh - 69px);
}

/* ---------- left: branding panel ---------- */
.auth-visual {
  position: relative;
  overflow: hidden;
  flex: 0 0 42%;
  background:
    radial-gradient(ellipse at 50% 45%, rgba(143, 215, 234, 0.2) 0%, rgba(143, 215, 234, 0) 56%),
    linear-gradient(135deg, #123a55 0%, #245c7e 48%, #174564 100%);
  display: flex;
  align-items: center;
  justify-content: center;
}
.hologram {
  width: min(92%, 720px);
  aspect-ratio: 1 / 1;
  height: auto;
}

/* ---------- right: form panel ---------- */
.auth-form-panel {
  flex: 1;
  display: flex;
  align-items: center;
  justify-content: center;
  background: #f7f8fa;
  padding: 48px 24px;
}
.auth-card {
  width: 100%;
  max-width: 400px;
  background: #fff;
  border: 1px solid #e2e5ea;
  border-radius: 18px;
  padding: 36px 32px;
  box-shadow: 0 24px 48px -24px rgba(17, 24, 60, 0.25);
}
.auth-card .page-title {
  font-size: 24px;
  margin-bottom: 22px;
}

.auth-form {
  display: flex;
  flex-direction: column;
  gap: 16px;
}
.auth-form label {
  display: flex;
  flex-direction: column;
  gap: 7px;
  font-size: 13px;
  font-weight: 600;
  color: #55607a;
}
.password-hint {
  margin: -8px 0 0;
  font-size: 12px;
  line-height: 1.4;
  color: #9aa1c2;
}

.input-with-icon {
  position: relative;
  display: flex;
  align-items: center;
}
.input-with-icon svg {
  position: absolute;
  left: 13px;
  width: 18px;
  height: 18px;
  color: #9aa1c2;
  pointer-events: none;
}
.input-with-icon input {
  width: 100%;
  padding: 11px 14px 11px 40px;
  border-radius: 10px;
  border: 1.5px solid #e2e5ea;
  font-size: 15px;
  color: #1b1f24;
  background: #fbfbfd;
  transition: border-color 0.15s ease, background 0.15s ease;
}
.input-with-icon input.has-trailing-btn {
  padding-right: 42px;
}
.input-with-icon :deep(.country-input) {
  width: 100%;
  padding: 11px 14px 11px 40px;
  border-radius: 10px;
  border: 1.5px solid #e2e5ea;
  font-size: 15px;
  color: #1b1f24;
  background: #fbfbfd;
  transition: border-color 0.15s ease, background 0.15s ease;
}
.toggle-visibility {
  position: absolute;
  right: 6px;
  border: none;
  background: transparent;
  color: #9aa1c2;
  width: 30px;
  height: 30px;
  border-radius: 8px;
  display: flex;
  align-items: center;
  justify-content: center;
  cursor: pointer;
}
.toggle-visibility svg {
  position: static;
  width: 18px;
  height: 18px;
}
.toggle-visibility:hover {
  background: #eef7fa;
  color: #0f7c96;
}
.input-with-icon input:focus,
.input-with-icon :deep(.country-input:focus) {
  outline: none;
  border-color: #0f7c96;
  background: #fff;
}

.submit-btn {
  margin-top: 4px;
  padding: 12px 18px;
  border-radius: 10px;
  border: none;
  background: #0f7c96;
  color: #fff;
  font-weight: 700;
  font-size: 15px;
  cursor: pointer;
  transition: background 0.15s ease;
}
.submit-btn:hover:not(:disabled) {
  background: #0b647a;
}
.submit-btn:disabled {
  background: #9ec7d2;
  cursor: not-allowed;
}

.notice {
  display: flex;
  align-items: flex-start;
  gap: 8px;
  margin: 0;
  font-size: 13.5px;
  line-height: 1.5;
}
.notice svg {
  width: 17px;
  height: 17px;
  flex-shrink: 0;
  margin-top: 1px;
}
.notice.success {
  color: #1a7f37;
}
.notice.error {
  color: #c0392b;
}

.switch {
  text-align: center;
  color: #6b7280;
  font-size: 14px;
  margin-top: 22px;
}

@media (max-width: 860px) {
  .auth-visual {
    display: none;
  }
}
</style>
