import { reactive } from 'vue'
import {
  apiChangePassword,
  apiDeleteAccount,
  apiLogIn,
  apiLogOut,
  apiSignUp,
  apiUpdateEmail,
  apiUpdateProfile,
  fetchCurrentUser,
  getAppConfig,
} from './api.js'

// A small reactive singleton instead of pulling in Pinia for one object.
// Any component that imports authState gets the same live reference.
export const authState = reactive({
  user: null,
  loading: true,
  // false on deployments started with AUTH_ENABLED=false (the lab-internal
  // server): no sign in, no account pages, no Community submissions, and
  // every analysis page is open without an account.
  enabled: true,
})

export async function refreshCurrentUser() {
  try {
    if (authState.loading) {
      // Only asked once, on first load. If /api/config can't be reached,
      // keep the default (accounts on) rather than opening pages up.
      try {
        const config = await getAppConfig()
        authState.enabled = config.auth_enabled !== false
      } catch (e) {
        authState.enabled = true
      }
    }
    if (!authState.enabled) {
      authState.user = null
      return
    }
    authState.user = await fetchCurrentUser()
  } catch (e) {
    authState.user = null
  } finally {
    authState.loading = false
  }
}

export async function login(email, password) {
  const user = await apiLogIn({ email, password })
  authState.user = user
  return user
}

export function signUp(email, password, displayName, institution, country) {
  return apiSignUp({ email, password, display_name: displayName, institution, country })
}

export async function logout() {
  await apiLogOut()
  authState.user = null
}

// Doesn't sign the user out or remove anything yet -- the account is only
// deleted once the confirmation link emailed to the account's address is
// clicked. Returns { message } from the backend.
export async function deleteAccount(password) {
  return apiDeleteAccount({ password })
}

export async function updateProfile(displayName, institution, country) {
  const user = await apiUpdateProfile({ display_name: displayName, institution, country })
  authState.user = user
  return user
}

// Doesn't change authState.user -- the email only updates once the user
// clicks the confirmation link sent to the new address. Returns
// { message } from the backend.
export async function updateEmail(newEmail, password) {
  return apiUpdateEmail({ new_email: newEmail, password })
}

export async function changePassword(currentPassword, newPassword) {
  await apiChangePassword({ current_password: currentPassword, new_password: newPassword })
}

// Kicked off once, on first import of this module. Route guards and other
// callers can `await authReady` to know authState.user/loading has settled.
export const authReady = refreshCurrentUser()
