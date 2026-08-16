<template>
  <div class="account-page">
    <template v-if="authState.user">
      <div class="account-shell">
        <aside class="account-sidebar" aria-label="Account summary">
          <div class="identity-block">
            <div class="identity-avatar" aria-hidden="true">{{ initials }}</div>
            <div class="identity-text">
              <h2 class="identity-name">{{ authState.user.display_name }}</h2>
              <p class="identity-email">{{ authState.user.email }}</p>
            </div>
          </div>

          <div class="status-grid" aria-label="Account status">
            <div>
              <span>Email status</span>
              <strong :class="authState.user.email_verified ? 'status-verified' : 'status-unverified'">
                {{ authState.user.email_verified ? 'Verified' : 'Unverified' }}
              </strong>
            </div>
            <div>
              <span>Access role</span>
              <strong>{{ authState.user.role }}</strong>
            </div>
            <div>
              <span>Institution</span>
              <strong>{{ authState.user.institution || '-' }}</strong>
            </div>
            <div>
              <span>Country/Region</span>
              <strong>{{ authState.user.country || '-' }}</strong>
            </div>
            <div>
              <span>Member since</span>
              <strong>{{ memberSince }}</strong>
            </div>
          </div>

          <nav class="settings-nav">
            <button
              v-for="tab in tabs"
              :key="tab.id"
              type="button"
              class="nav-item"
              :class="{ active: activeTab === tab.id, danger: tab.id === 'danger' }"
              @click="activeTab = tab.id"
            >
              <span class="nav-icon" v-html="tab.icon"></span>
              <span>
                <span class="nav-label">{{ tab.label }}</span>
                <span class="nav-hint">{{ tab.hint }}</span>
              </span>
            </button>
          </nav>
        </aside>

        <main class="settings-content">
          <header class="content-head">
            <h1>Account Settings</h1>
          </header>

          <section v-show="activeTab === 'profile'" class="settings-panel" aria-labelledby="panel-profile-title">
            <div class="panel-head">
              <div>
                <h2 id="panel-profile-title">Research identity</h2>
              </div>
              <span class="panel-code">ACC-01</span>
            </div>
            <p class="panel-copy">Update the name and institution associated with analyses, downloads, and platform records.</p>

            <form class="settings-form" @submit.prevent="submitProfile">
              <label>
                <span>Display name</span>
                <input v-model="profileForm.displayName" type="text" required autocomplete="name" />
              </label>
              <label>
                <span>Institution</span>
                <input v-model="profileForm.institution" type="text" required autocomplete="organization" />
              </label>
              <label>
                <span>Country/Region</span>
                <CountryCombobox v-model="profileForm.country" />
              </label>

              <p v-if="profileError" class="notice error">{{ profileError }}</p>
              <p v-if="profileSuccess" class="notice success">{{ profileSuccess }}</p>

              <button type="submit" class="btn-primary" :disabled="profileSaving">
                {{ profileSaving ? 'Saving...' : 'Save changes' }}
              </button>
            </form>
          </section>

          <section v-show="activeTab === 'email'" class="settings-panel" aria-labelledby="panel-email-title">
            <div class="panel-head">
              <div>
                <h2 id="panel-email-title">Sign-in email</h2>
              </div>
              <span class="panel-code">ACC-02</span>
            </div>
            <p class="panel-copy">
              Your current sign-in email is <strong>{{ authState.user.email }}</strong>. We'll send a confirmation
              link to the new address; the change only takes effect once you confirm it.
            </p>

            <form class="settings-form" @submit.prevent="submitEmail">
              <label>
                <span>New email</span>
                <input v-model="newEmail" type="email" required autocomplete="email" placeholder="you@example.com" />
              </label>
              <label>
                <span>Current password</span>
                <input v-model="emailPassword" type="password" required autocomplete="current-password" />
              </label>

              <p v-if="emailError" class="notice error">{{ emailError }}</p>
              <p v-if="emailSuccess" class="notice success">{{ emailSuccess }}</p>

              <button type="submit" class="btn-primary" :disabled="emailSaving || !newEmail || !emailPassword">
                {{ emailSaving ? 'Updating...' : 'Update email' }}
              </button>
            </form>
          </section>

          <section v-show="activeTab === 'password'" class="settings-panel" aria-labelledby="panel-password-title">
            <div class="panel-head">
              <div>
                <h2 id="panel-password-title">Password policy</h2>
              </div>
              <span class="panel-code">ACC-03</span>
            </div>
            <p class="panel-copy">Change your password and invalidate sessions on other signed-in devices.</p>

            <form class="settings-form" @submit.prevent="submitPassword">
              <label>
                <span>Current password</span>
                <input v-model="currentPassword" type="password" required autocomplete="current-password" />
              </label>
              <label>
                <span>New password</span>
                <input v-model="newPassword" type="password" required autocomplete="new-password" minlength="9" />
              </label>
              <p class="password-hint">More than 8 characters, and at least 3 of: uppercase, lowercase, digit, special character.</p>
              <label>
                <span>Confirm new password</span>
                <input v-model="confirmPassword" type="password" required autocomplete="new-password" />
              </label>

              <p v-if="passwordError" class="notice error">{{ passwordError }}</p>
              <p v-if="passwordSuccess" class="notice success">{{ passwordSuccess }}</p>

              <button
                type="submit"
                class="btn-primary"
                :disabled="passwordSaving || !currentPassword || !newPassword || !confirmPassword"
              >
                {{ passwordSaving ? 'Updating...' : 'Update password' }}
              </button>
            </form>
          </section>

          <section v-show="activeTab === 'danger'" class="settings-panel danger-panel" aria-labelledby="panel-danger-title">
            <div class="panel-head">
              <div>
                <h2 id="panel-danger-title">Delete account</h2>
              </div>
              <span class="panel-code danger-code">ACC-04</span>
            </div>
            <p class="panel-copy">
              We'll send a confirmation link to your email; the account is only deleted once you click it. This
              can't be undone.
            </p>

            <form class="settings-form" @submit.prevent="submitDeleteAccount">
              <label>
                <span>Current password</span>
                <input
                  v-model="deletePassword"
                  type="password"
                  autocomplete="current-password"
                  placeholder="Enter your login password"
                  required
                />
              </label>

              <p v-if="deleteError" class="notice error">{{ deleteError }}</p>
              <p v-if="deleteSuccess" class="notice success">{{ deleteMessage }}</p>

              <button type="submit" class="btn-danger" :disabled="deleting || !deletePassword">
                {{ deleting ? 'Deleting...' : 'Delete account' }}
              </button>
            </form>
          </section>
        </main>
      </div>
    </template>

    <section v-else class="signed-out-state">
      <div>
        <p class="eyebrow">Account</p>
        <h1>You're Not Signed In</h1>
        <p>Sign in to view your PhenoMAP account details.</p>
        <router-link to="/login">Sign In</router-link>
      </div>
    </section>
  </div>
</template>

<script setup>
import { computed, onMounted, reactive, ref } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { authState, changePassword, deleteAccount, refreshCurrentUser, updateEmail, updateProfile } from '../auth.js'
import CountryCombobox from '../components/CountryCombobox.vue'

const route = useRoute()
const router = useRouter()

const icons = {
  profile:
    '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7"><circle cx="12" cy="8" r="3.4"/><path d="M5 20c0-3.6 3.1-6 7-6s7 2.4 7 6"/></svg>',
  email:
    '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7"><rect x="3" y="5" width="18" height="14" rx="2.5"/><path d="m4 7 8 6 8-6"/></svg>',
  password:
    '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7"><rect x="5" y="11" width="14" height="9" rx="2"/><path d="M8 11V7.5a4 4 0 0 1 8 0V11"/></svg>',
  danger:
    '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7"><path d="M12 3 2 20h20L12 3Z"/><path d="M12 10v4M12 17h.01"/></svg>',
}

const tabs = [
  { id: 'profile', label: 'Profile', hint: 'Name & institution', icon: icons.profile },
  { id: 'email', label: 'Email', hint: 'Sign-in address', icon: icons.email },
  { id: 'password', label: 'Password', hint: 'Login credentials', icon: icons.password },
  { id: 'danger', label: 'Danger Zone', hint: 'Delete account', icon: icons.danger },
]

const activeTab = ref('profile')

const initials = computed(() => {
  const name = authState.user?.display_name || authState.user?.email || ''
  return name
    .split(/\s+/)
    .filter(Boolean)
    .map((part) => part[0])
    .slice(0, 2)
    .join('')
    .toUpperCase() || '?'
})

const memberSince = computed(() => {
  const raw = authState.user?.created_at
  if (!raw) return '-'
  // The backend stores SQLite's `datetime('now')` format
  // ("YYYY-MM-DD HH:MM:SS", UTC) -- make it parseable as ISO-8601.
  const iso = raw.includes('T') ? raw : `${raw.replace(' ', 'T')}Z`
  const date = new Date(iso)
  if (Number.isNaN(date.getTime())) return '-'
  return date.toLocaleDateString(undefined, { year: 'numeric', month: 'long', day: 'numeric' })
})

// ---------- edit profile ----------
const profileForm = reactive({
  displayName: authState.user?.display_name || '',
  institution: authState.user?.institution || '',
  country: authState.user?.country || '',
})
const profileSaving = ref(false)
const profileError = ref('')
const profileSuccess = ref('')

async function submitProfile() {
  profileSaving.value = true
  profileError.value = ''
  profileSuccess.value = ''
  try {
    await updateProfile(profileForm.displayName.trim(), profileForm.institution.trim(), profileForm.country.trim())
    profileSuccess.value = 'Profile updated.'
  } catch (e) {
    profileError.value = e.message
  } finally {
    profileSaving.value = false
  }
}

// ---------- change email ----------
const newEmail = ref('')
const emailPassword = ref('')
const emailSaving = ref(false)
const emailError = ref('')
const emailSuccess = ref('')

async function submitEmail() {
  emailSaving.value = true
  emailError.value = ''
  emailSuccess.value = ''
  try {
    const res = await updateEmail(newEmail.value.trim(), emailPassword.value)
    emailSuccess.value = res.message
    newEmail.value = ''
    emailPassword.value = ''
  } catch (e) {
    emailError.value = e.message
  } finally {
    emailSaving.value = false
  }
}

// Landing back here after clicking the confirmation link emailed to the
// new address (see handleConfirmEmailChange on the backend).
onMounted(async () => {
  const status = route.query.email_changed
  if (status === undefined) return

  activeTab.value = 'email'
  if (status === '1') {
    await refreshCurrentUser()
    emailSuccess.value = 'Your email address has been updated.'
  } else {
    emailError.value = 'That confirmation link is invalid or has expired. Please request the change again.'
  }
  router.replace({ path: '/account' })
})

// ---------- change password ----------
const currentPassword = ref('')
const newPassword = ref('')
const confirmPassword = ref('')
const passwordSaving = ref(false)
const passwordError = ref('')
const passwordSuccess = ref('')

async function submitPassword() {
  passwordError.value = ''
  passwordSuccess.value = ''
  if (newPassword.value !== confirmPassword.value) {
    passwordError.value = 'New passwords do not match.'
    return
  }
  passwordSaving.value = true
  try {
    await changePassword(currentPassword.value, newPassword.value)
    passwordSuccess.value = 'Password changed. Other devices have been signed out.'
    currentPassword.value = ''
    newPassword.value = ''
    confirmPassword.value = ''
  } catch (e) {
    passwordError.value = e.message
  } finally {
    passwordSaving.value = false
  }
}

// ---------- delete account ----------
const deletePassword = ref('')
const deleting = ref(false)
const deleteError = ref('')
const deleteSuccess = ref(false)
const deleteMessage = ref('')

async function submitDeleteAccount() {
  deleting.value = true
  deleteError.value = ''
  deleteSuccess.value = false
  try {
    const res = await deleteAccount(deletePassword.value)
    deletePassword.value = ''
    deleteSuccess.value = true
    deleteMessage.value = res.message
  } catch (e) {
    deleteError.value = e.message
  } finally {
    deleting.value = false
  }
}
</script>

<style scoped>
.account-page {
  min-height: calc(100vh - 69px);
  overflow-x: hidden;
  background: #f7f8fa;
  color: #17202e;
}

.eyebrow {
  display: inline-block;
  margin: 0;
  color: #8fd7ea;
  background: rgba(34, 211, 238, 0.12);
  border: 1px solid rgba(34, 211, 238, 0.3);
  border-radius: 999px;
  padding: 5px 14px;
  font-size: 12.5px;
  font-weight: 800;
  letter-spacing: 0.08em;
  text-transform: uppercase;
}

.account-shell {
  width: calc(100% - 80px);
  max-width: 1200px;
  margin: 38px auto 88px;
  padding: 0;
  display: grid;
  grid-template-columns: 330px minmax(0, 1fr);
  align-items: stretch;
  background: #ffffff;
  border: 1px solid #e3ebef;
  border-radius: 0;
  box-shadow: none;
  overflow: visible;
}

/* ---------- left rail ---------- */
.account-sidebar {
  min-width: 0;
  background: #f8fbfc;
  border-right: 1px solid #e3ebef;
}
.identity-block {
  display: grid;
  grid-template-columns: 56px minmax(0, 1fr);
  gap: 16px;
  align-items: center;
  padding: 24px;
  border-bottom: 1px solid #e3ebef;
}
.identity-avatar {
  width: 56px;
  height: 56px;
  display: grid;
  place-items: center;
  border-radius: 8px;
  background: #0f7c96;
  color: #f8fbff;
  font-size: 20px;
  font-weight: 850;
  letter-spacing: 0;
  box-shadow: none;
}
.identity-name {
  margin: 0;
  color: #132033;
  font-size: 20px;
  font-weight: 850;
  line-height: 1.2;
  overflow-wrap: anywhere;
}
.identity-email {
  margin: 4px 0 0;
  color: #5f6b7d;
  font-size: 13.5px;
  font-weight: 600;
  overflow-wrap: anywhere;
}

.status-grid {
  display: grid;
  grid-template-columns: 1fr;
  border-bottom: 1px solid #e3ebef;
}
.status-grid div {
  display: grid;
  grid-template-columns: 128px minmax(0, 1fr);
  gap: 18px;
  padding: 14px 24px;
  border-top: 1px solid #e9eff2;
}
.status-grid div:first-child {
  border-top: 0;
}
.status-grid span {
  color: #778397;
  font-size: 11px;
  font-weight: 800;
  text-transform: uppercase;
  letter-spacing: 0;
}
.status-grid strong {
  min-width: 0;
  color: #26364b;
  font-size: 14px;
  font-weight: 760;
  line-height: 1.35;
  overflow-wrap: anywhere;
}
.status-grid .status-verified {
  color: #168557;
}
.status-grid .status-unverified {
  color: #a64b15;
}

.settings-nav {
  padding: 16px;
  display: flex;
  flex-direction: column;
  gap: 2px;
  text-align: left;
}
.nav-item {
  display: flex;
  align-items: center;
  gap: 12px;
  min-height: 58px;
  padding: 11px 12px;
  border: none;
  border-left: 3px solid transparent;
  border-radius: 0;
  background: transparent;
  color: #46566d;
  cursor: pointer;
  text-align: left;
  transition: background 0.14s ease, border-color 0.14s ease, color 0.14s ease;
}
.nav-item:hover {
  background: #eef8fa;
}
.nav-item.active {
  border-left-color: #0f7c96;
  background: #e9f7f9;
  color: #0f7c96;
}
.nav-item.danger.active {
  border-left-color: #b42318;
  background: #fbefee;
  color: #b42318;
}
.nav-icon {
  flex-shrink: 0;
  width: 20px;
  height: 20px;
  display: grid;
  place-items: center;
}
.nav-icon :deep(svg) {
  width: 19px;
  height: 19px;
}
.nav-label {
  display: block;
  font-size: 14px;
  font-weight: 800;
}
.nav-hint {
  display: block;
  font-size: 11.5px;
  font-weight: 600;
  color: #8290a4;
  margin-top: 2px;
}
.nav-item.active .nav-hint {
  color: #4d7f8a;
}
.nav-item.danger.active .nav-hint {
  color: #c97e78;
}

/* ---------- settings content ---------- */
.settings-content {
  min-width: 0;
  padding: 38px 46px 52px;
}
.content-head {
  margin-bottom: 0;
  padding-bottom: 22px;
  border-bottom: 1px solid #e3ebef;
}
.content-head h1 {
  margin: 0;
  color: #101827;
  font-size: clamp(30px, 2.4vw, 38px);
  font-weight: 850;
  line-height: 1.15;
  letter-spacing: 0;
}
.settings-panel {
  background: transparent;
  border: 0;
  border-radius: 0;
  box-shadow: none;
  padding: 0;
}
.danger-panel {
  border-color: transparent;
}
.panel-head {
  display: flex;
  align-items: flex-start;
  justify-content: space-between;
  gap: 18px;
  padding: 30px 0 22px;
  border-bottom: 1px solid #e5eaee;
  background: transparent;
}
.settings-panel h2 {
  margin: 0;
  color: #152238;
  font-size: 24px;
  font-weight: 800;
  letter-spacing: 0;
}
.danger-panel h2 {
  color: #7f1d1d;
}
.panel-code {
  flex: 0 0 auto;
  padding: 5px 8px;
  border-radius: 0;
  background: #eef4f7;
  color: #536172;
  font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace;
  font-size: 12px;
  font-weight: 800;
}
.danger-code {
  background: #fbefee;
  color: #b42318;
}
.panel-copy {
  max-width: none;
  margin: 0;
  padding: 28px 0 0;
  color: #5c6b7f;
  font-size: 15.5px;
  font-weight: 600;
  line-height: 1.6;
}
.panel-copy strong {
  color: #20334a;
}

.settings-form {
  display: grid;
  gap: 18px;
  max-width: 720px;
  padding: 30px 0 0;
}
.settings-form label {
  display: grid;
  gap: 8px;
  color: #40516a;
  font-size: 13px;
  font-weight: 800;
}
.settings-form label > span {
  display: flex;
  align-items: center;
  min-height: 18px;
}
.settings-form input {
  width: 100%;
  min-height: 44px;
  padding: 11px 12px;
  border: 1px solid #d8e5ea;
  border-radius: 8px;
  background: #fbfdfe;
  color: #17202e;
  font: inherit;
  font-size: 15px;
  font-weight: 600;
  transition: border-color 0.16s ease, box-shadow 0.16s ease, background 0.16s ease;
}
.settings-form :deep(.country-input) {
  width: 100%;
  min-height: 44px;
  padding: 11px 12px;
  border: 1px solid #d8e5ea;
  border-radius: 8px;
  background: #fbfdfe;
  color: #17202e;
  font: inherit;
  font-size: 15px;
  font-weight: 600;
  transition: border-color 0.16s ease, box-shadow 0.16s ease, background 0.16s ease;
}
.settings-form input:focus,
.settings-form :deep(.country-input:focus) {
  outline: none;
  border-color: #0f7c96;
  background: #ffffff;
  box-shadow: 0 0 0 3px rgba(15, 124, 150, 0.12);
}
.danger-panel input:focus,
.danger-panel :deep(.country-input:focus) {
  border-color: #b42318;
  box-shadow: 0 0 0 3px rgba(180, 35, 24, 0.1);
}
.password-hint {
  margin: -8px 0 0;
  font-size: 12px;
  line-height: 1.4;
  color: #738198;
}

.btn-primary,
.btn-danger {
  width: fit-content;
  min-height: 42px;
  padding: 0 20px;
  border-radius: 6px;
  font-size: 15px;
  font-weight: 850;
  cursor: pointer;
  transition: background 0.16s ease, border-color 0.16s ease;
}
.btn-primary {
  border: 1px solid #0f7c96;
  background: #0f7c96;
  color: #ffffff;
}
.btn-primary:hover:not(:disabled) {
  border-color: #245c7e;
  background: #245c7e;
}
.btn-primary:disabled {
  border-color: #a8c6cf;
  background: #a8c6cf;
  cursor: not-allowed;
}
.btn-danger {
  border: 1px solid #b42318;
  background: #b42318;
  color: #ffffff;
}
.btn-danger:hover:not(:disabled) {
  border-color: #8f1d15;
  background: #8f1d15;
}
.btn-danger:disabled {
  border-color: #e5b8b3;
  background: #e5b8b3;
  cursor: not-allowed;
}

.notice {
  margin: 0;
  padding: 10px 12px;
  border-radius: 8px;
  font-size: 14px;
  font-weight: 700;
  line-height: 1.5;
}
.notice.error {
  background: #fff3f1;
  color: #b42318;
}
.notice.success {
  background: #edf8f2;
  color: #1a7f37;
}

/* ---------- signed-out state ---------- */
.signed-out-state {
  min-height: calc(100vh - 69px);
  display: grid;
  place-items: center;
  padding: 48px 24px;
  background:
    radial-gradient(circle at 16% 18%, rgba(143, 215, 234, 0.3), transparent 28%),
    radial-gradient(circle at 82% 18%, rgba(79, 181, 155, 0.18), transparent 30%),
    linear-gradient(135deg, #1d5876 0%, #2d7895 52%, #245f7d 100%);
}
.signed-out-state h1 {
  max-width: 760px;
  margin: 14px 0 10px;
  color: #ffffff;
  font-size: clamp(32px, 4vw, 42px);
  font-weight: 850;
  line-height: 1.05;
}
.signed-out-state p:not(.eyebrow) {
  margin: 0;
  color: #d8e7ef;
  font-size: 16px;
  line-height: 1.65;
  font-weight: 600;
}
.signed-out-state > div {
  width: min(560px, 100%);
  padding: 0;
  background: transparent;
  border: 0;
  border-radius: 0;
  box-shadow: none;
}
.signed-out-state a {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  min-height: 42px;
  margin-top: 24px;
  padding: 0 20px;
  border-radius: 8px;
  background: #ffffff;
  border: 1px solid rgba(255, 255, 255, 0.92);
  color: #0f5872;
  box-shadow: 0 14px 28px -22px rgba(0, 0, 0, 0.55);
  font-size: 15px;
  font-weight: 850;
  text-decoration: none;
}
.signed-out-state a:hover {
  background: #eef8fa;
}

@media (max-width: 1200px) {
  .account-shell {
    width: calc(100% - 80px);
    max-width: 1180px;
    grid-template-columns: 320px minmax(0, 1fr);
  }
  .settings-content {
    padding: 38px 40px 48px;
  }
  .content-head h1 {
    font-size: clamp(30px, 3.2vw, 36px);
  }
  .settings-form {
    max-width: 620px;
  }
}

@media (max-width: 900px) {
  .account-shell {
    grid-template-columns: 1fr;
  }
  .account-sidebar {
    position: static;
    border-right: 0;
    border-bottom: 1px solid #d9e1eb;
  }
  .content-head {
    margin-top: 0;
  }
  .settings-nav {
    flex-direction: row;
    flex-wrap: wrap;
  }
  .nav-item {
    flex: 1 1 180px;
  }
}

@media (max-width: 640px) {
  .account-shell {
    width: calc(100% - 40px);
    margin: 24px auto 56px;
  }
  .settings-content {
    padding: 28px 20px 32px;
  }
  .identity-block {
    grid-template-columns: 48px minmax(0, 1fr);
    padding: 20px;
  }
  .identity-avatar {
    width: 48px;
    height: 48px;
    font-size: 18px;
  }
  .status-grid div {
    grid-template-columns: 1fr;
    gap: 4px;
    padding: 12px 20px;
  }
  .settings-nav {
    padding: 10px;
  }
  .nav-item {
    min-height: 52px;
    flex-basis: 148px;
  }
  .content-head h1 {
    font-size: 30px;
  }
  .panel-head {
    padding: 24px 0 18px;
  }
  .panel-copy {
    padding: 18px 0 0;
  }
  .settings-form {
    max-width: none;
    padding: 22px 0 0;
  }
  .btn-primary,
  .btn-danger {
    width: 100%;
  }
}
</style>
