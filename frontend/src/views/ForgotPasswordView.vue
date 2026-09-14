<template>
  <div class="auth-split">
    <div class="auth-visual">
      <DataGlobe class="hologram" />
    </div>

    <div class="auth-form-panel">
      <div class="auth-card">
        <h1 class="page-title">Reset your password</h1>
        <p class="subtitle">Enter your account email and we'll send you a link to set a new password.</p>

        <form class="auth-form" @submit.prevent="submit">
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

          <button type="submit" class="submit-btn" :disabled="loading || cooldown > 0">
            {{ submitLabel }}
          </button>

          <p v-if="message" class="notice success">
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M20 6 9 17l-5-5" /></svg>
            <span>{{ message }}</span>
          </p>
          <p v-if="error" class="notice error">
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
              <circle cx="12" cy="12" r="9" /><path d="M12 8v5M12 16h.01" />
            </svg>
            <span>{{ error }}</span>
          </p>
        </form>
        <p class="switch">Remembered it? <router-link to="/login">Sign in</router-link></p>
      </div>
    </div>
  </div>
</template>

<script setup>
import { computed, onUnmounted, ref } from 'vue'
import { forgotPassword } from '../api.js'
import DataGlobe from '../components/DataGlobe.vue'

const COOLDOWN_SECONDS = 60

const email = ref('')
const loading = ref(false)
const sent = ref(false)
const message = ref('')
const error = ref('')
const cooldown = ref(0)
let cooldownTimer = null

const submitLabel = computed(() => {
  if (loading.value) return 'Sending...'
  if (cooldown.value > 0) return `Resend in ${cooldown.value}s`
  return sent.value ? 'Resend reset link' : 'Send reset link'
})

function startCooldown() {
  cooldown.value = COOLDOWN_SECONDS
  clearInterval(cooldownTimer)
  cooldownTimer = setInterval(() => {
    cooldown.value -= 1
    if (cooldown.value <= 0) clearInterval(cooldownTimer)
  }, 1000)
}

onUnmounted(() => clearInterval(cooldownTimer))

async function submit() {
  loading.value = true
  error.value = ''
  message.value = ''
  try {
    const res = await forgotPassword(email.value)
    message.value = res.message
    sent.value = true
    startCooldown()
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

.auth-visual {
  position: relative;
  overflow: hidden;
  flex: 0 0 42%;
  background:
    radial-gradient(ellipse at 50% 45%, rgba(34, 211, 238, 0.16) 0%, rgba(34, 211, 238, 0) 55%),
    linear-gradient(135deg, #0b1120 0%, #151b3a 45%, #1c2350 100%);
  display: flex;
  align-items: center;
  justify-content: center;
}
.hologram {
  width: min(92%, 720px);
  aspect-ratio: 1 / 1;
  height: auto;
}

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
  margin-bottom: 8px;
}
.subtitle {
  margin: 0 0 22px;
  font-size: 13.5px;
  line-height: 1.5;
  color: #6b7280;
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
.input-with-icon input:focus {
  outline: none;
  border-color: #3949ab;
  background: #fff;
}

.submit-btn {
  margin-top: 4px;
  padding: 12px 18px;
  border-radius: 10px;
  border: none;
  background: #3949ab;
  color: #fff;
  font-weight: 700;
  font-size: 15px;
  cursor: pointer;
  transition: background 0.15s ease;
}
.submit-btn:hover:not(:disabled) {
  background: #2f3c8f;
}
.submit-btn:disabled {
  background: #b6bdda;
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
